import Foundation
import RingCore
import XCTest

/// RC7. Il replay non attenua l'incertezza e una FC osservata ha un'età propria.
final class IndependentRefreshConflictAndPulseTests: XCTestCase {
    private struct Scenario {
        let calendar: Calendar
        let day: Date
        let source: SleepSourceKey
        let profile: UserProfile

        init(model: ZoneModel = .percentMax) throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
            self.calendar = calendar
            day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9)))
            source = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 2, count: 32)))
            profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65,
                                  sleepNeedH: 8, zoneModel: model, hrMaxOverride: 190)
        }

        func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }

        func current(_ history: [DailyReport]) throws -> DailyReport {
            try XCTUnwrap(history.first { $0.date == day })
        }

        func fresh(_ input: DayInput, in history: [DailyReport]) throws -> [DailyReport] {
            let report = DailyPipeline.run(input, profile: profile, history: history)
            return try History.decode(History.encode(History.upsert(report, into: history, calendar: calendar)))
        }

        func input(at time: Double, hr: [TimedValue] = [], active: Double? = nil) -> DayInput {
            var result = DayInput.make(day: day, calendar: calendar, now: at(time), hr: hr, steps: [], motion: [])
            result.hkActiveKcal = active
            result.hkBasalKcal = active.map { _ in 1_500 }
            return result
        }

        func daytime(_ rate: Double) -> [TimedValue] {
            (1440..<1460).map { TimedValue(date: at(Double($0) / 2), value: rate) }
        }

        func initial() throws -> [DailyReport] {
            let sleep = SleepSegment(start: at(-20), end: at(240), stage: .light, source: source)
            let nightPulse = (40..<160).map { TimedValue(date: at(Double($0) / 2), value: 54) }
            var reading = DayInput.make(day: day, calendar: calendar, now: at(780),
                                        hr: nightPulse + daytime(75), steps: [], motion: [], appleSleep: [sleep])
            reading.appleSleepSource = source
            reading.hkActiveKcal = 180
            reading.hkBasalKcal = 1_500
            return try fresh(reading, in: [])
        }
    }

    func testSameAcquisitionTimeEnergyConflictSurvivesReplayAndReloadUntilNewObservation() throws {
        let f = try Scenario()
        let original = try f.initial()
        let zero = f.input(at: 840, active: 0)
        let positive = f.input(at: 840, active: 140)
        func verifyConflict(_ archive: [DailyReport]) throws {
            let report = try f.current(archive)
            XCTAssertFalse(report.state(\.energyActive).hasValue)
            XCTAssertFalse(report.state(\.energyTotal).hasValue)
            let rows = Presentation.activityLines(report).filter { $0.name.hasPrefix("Calorie") }
            XCTAssertEqual(rows.count, 2)
            XCTAssertTrue(rows.allSatisfy { !$0.value.contains(" kcal") })
        }

        for pair in [(zero, positive), (positive, zero)] {
            let stored = try f.fresh(pair.0, in: original)
            let disputed = try f.fresh(pair.1, in: stored)
            try verifyConflict(disputed)
            let replay = try f.fresh(pair.0, in: disputed)
            try verifyConflict(replay)
            XCTAssertEqual(try History.encode(replay), try History.encode(disputed))

            let observed = try f.current(f.fresh(f.input(at: 900, active: 175), in: replay))
            XCTAssertEqual(observed.state(\.energyActive), .observed)
            XCTAssertEqual(observed.state(\.energyTotal), .observed)
            XCTAssertEqual(observed.kcalActive, 175)
            XCTAssertEqual(observed.kcalTotal, 1_675)
            XCTAssertEqual(observed.sectorFreshness?.activeEnergyAt, f.at(900))
        }
    }

    func testShortDaytimeOnlyPulseRetainsNightRHRAndIsRecognizedUnderKarvonen() throws {
        let f = try Scenario(model: .karvonen)
        let original = try f.initial()
        let night = try f.current(original)
        XCTAssertEqual(night.night?.rhr, 54)
        XCTAssertEqual(night.zoneBounds.count, 6)

        // 10 min osservati a 140 bpm. Con RHR 54 e FCmax 190, Z2 è [135,6;149,2).
        let input = f.input(at: 840, hr: f.daytime(140))
        let report = try f.current(f.fresh(input, in: original))
        XCTAssertEqual(report.computedAt, f.at(840))
        XCTAssertEqual(report.sectorFreshness?.nightAt, f.at(780))
        XCTAssertEqual(report.night?.rhr, 54)
        XCTAssertEqual(report.night?.avgHR, 54)
        XCTAssertEqual(report.sectorFreshness?.daytimePulseAt, f.at(840))
        if report.state(\.zones).hasValue {
            XCTAssertEqual(report.zoneMinutesDay, [0, 10, 0, 0, 0])
            XCTAssertEqual(report.zoneBounds, night.zoneBounds)
        } else {
            XCTAssertTrue(Presentation.heartLines(report).contains { row in
                let copy = (row.name + " " + row.value).lowercased()
                return copy.contains("zon") && ["ripos", "limiti", "insufficient", "disponibil"]
                    .contains { copy.contains($0) }
            })
        }
    }
}
