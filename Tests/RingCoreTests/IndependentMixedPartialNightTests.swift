import Foundation
import RingCore
import XCTest

/// RC7. La rilettura ordinaria può essere completa per l'energia e incompleta per la notte.
final class IndependentMixedPartialNightTests: XCTestCase {
    private struct Scenario {
        let calendar: Calendar
        let day: Date
        let source: SleepSourceKey
        let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65, sleepNeedH: 8)

        init() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
            self.calendar = calendar
            day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9)))
            source = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 1, count: 32)))
        }

        func at(_ minute: Double) -> Date { day.addingTimeInterval(minute * 60) }

        func pulse(on date: Date) -> [TimedValue] {
            (Array(1440..<1460) + Array(2860..<2880)).map {
                TimedValue(date: date.addingTimeInterval(Double($0) * 30), value: 75)
            }
        }

        func saved(_ input: DayInput, in history: [DailyReport]) -> [DailyReport] {
            let report = DailyPipeline.run(input, profile: profile, history: history)
            return History.upsert(report, into: history, calendar: calendar)
        }

        func restart(_ history: [DailyReport]) throws -> [DailyReport] {
            try History.decode(History.encode(history))
        }

        func report(in history: [DailyReport]) throws -> DailyReport {
            try XCTUnwrap(history.first { $0.date == day })
        }

        func previousEvening(in history: [DailyReport]) throws -> [Bool?] {
            let previous = try XCTUnwrap(history.first { $0.date == at(-1440) })
            return [-15.0, -8.0, -2.0].map { minute in
                previous.sleepObservations?.first { $0.span.start <= at(minute) && at(minute) < $0.span.end }?.asleep
            }
        }

        func confirmed() throws -> [DailyReport] {
            var history: [DailyReport] = []
            for offset in (1...4).reversed() {
                let date = at(-Double(offset) * 1440)
                let input = DayInput.make(day: date, calendar: calendar, now: date.addingTimeInterval(86_400),
                                          hr: pulse(on: date), steps: [], motion: [])
                history = saved(input, in: history)
            }
            let segments = [
                SleepSegment(start: at(-30), end: at(250), stage: nil, source: source),
                SleepSegment(start: at(-20), end: at(40), stage: .light, source: source),
                SleepSegment(start: at(40), end: at(160), stage: .deep, source: source),
                SleepSegment(start: at(160), end: at(240), stage: .rem, source: source)
            ]
            let nightPulse = (40..<160).map { TimedValue(date: at(Double($0) / 2), value: 54) }
            var initial = DayInput.make(day: day, calendar: calendar, now: at(780),
                                        hr: nightPulse + pulse(on: day), steps: [], motion: [], appleSleep: segments)
            initial.appleSleepSource = source
            initial.hkActiveKcal = 200
            initial.hkBasalKcal = 1_500
            return try restart(saved(initial, in: history))
        }
    }

    func testMixedRefreshUpdatesObservedZeroWithoutErasingConfirmedNight() throws {
        let f = try Scenario()
        let confirmed = try f.confirmed()
        let kept = try f.report(in: confirmed)
        let night = try XCTUnwrap(kept.night)
        XCTAssertEqual(night.tstMin, 260, accuracy: 1e-9)
        XCTAssertEqual(kept.sleepDebtH, 220.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(night.avgHR), 54, accuracy: 1e-9)
        XCTAssertEqual(try f.previousEvening(in: confirmed), [nil, true, true])

        let onlyDaytimePulse = (1440..<1460).map {
            TimedValue(date: f.at(Double($0) / 2), value: 88)
        }
        var mixed = DayInput.make(day: f.day, calendar: f.calendar, now: f.at(840),
                                  hr: onlyDaytimePulse, steps: [], motion: [])
        mixed.hkActiveKcal = 0
        mixed.hkBasalKcal = 1_500
        let archive = try f.restart(f.saved(mixed, in: confirmed))
        let report = try f.report(in: archive)

        XCTAssertEqual(archive.filter { $0.date == f.day }.count, 1)
        XCTAssertEqual(report.computedAt, f.at(840))
        XCTAssertEqual(report.kcalActive, 0)
        XCTAssertEqual(report.kcalTotal, 1_500)
        XCTAssertEqual(report.state(\.energyActive), .observed)
        XCTAssertEqual(report.dailySleepMin, 260)
        XCTAssertEqual(report.sleepDebtH, 220.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(report.night?.sleepOnset, night.sleepOnset)
        XCTAssertEqual(report.night?.finalWake, night.finalWake)
        XCTAssertEqual(report.night?.stages, night.stages)
        XCTAssertEqual(report.night?.sleepRuns, night.sleepRuns)
        XCTAssertEqual(report.night?.bedTimingOrigin, night.bedTimingOrigin)
        XCTAssertEqual(report.night?.avgHR, night.avgHR)
        XCTAssertEqual(report.sri, kept.sri)
        XCTAssertEqual(try f.previousEvening(in: archive), [nil, true, true])
        XCTAssertTrue(Presentation.sleepLines(report).contains { line in
            let text = (line.name + " " + line.value).lowercased()
            return ["lettura incompleta", "dati parziali", "notte precedente", "già salvata", "già archiviata", "non aggiornat"]
                .contains { text.contains($0) }
        })
        let replay = f.saved(mixed, in: archive)
        XCTAssertEqual(try History.encode(replay), try History.encode(archive))
    }
}
