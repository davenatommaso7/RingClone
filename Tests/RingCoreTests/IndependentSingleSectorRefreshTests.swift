import Foundation
import RingCore
import XCTest

/// RC7. Un dato nuovo di un solo settore non aggiorna l'età dei settori assenti.
final class IndependentSingleSectorRefreshTests: XCTestCase {
    func testDaytimePulseAloneAndObservedEnergyAloneKeepNightWithoutRefreshingAbsentSectors() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9)))
        let source = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 5, count: 32)))
        let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65)
        func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }
        func pulses(_ rate: Double) -> [TimedValue] {
            (1440..<1460).map { TimedValue(date: at(Double($0) / 2), value: rate) }
        }
        func save(_ input: DayInput, in history: [DailyReport]) throws -> [DailyReport] {
            let report = DailyPipeline.run(input, profile: profile, history: history)
            return try History.decode(History.encode(History.upsert(report, into: history, calendar: calendar)))
        }

        let night = SleepSegment(start: at(-20), end: at(240), stage: .light, source: source)
        let nighttime = (40..<160).map { TimedValue(date: at(Double($0) / 2), value: 54) }
        var initial = DayInput.make(day: day, calendar: calendar, now: at(780),
                                    hr: nighttime + pulses(75), steps: [], motion: [], appleSleep: [night])
        initial.appleSleepSource = source
        initial.hkActiveKcal = 180
        initial.hkBasalKcal = 1_500
        let history = try save(initial, in: [])
        let previous = try XCTUnwrap(history.first)
        let baseline = try XCTUnwrap(previous.sectorFreshness)
        XCTAssertEqual(baseline.nightAt, at(780))
        XCTAssertEqual(previous.night?.avgHR, 54)

        let pulseOnly = DayInput.make(day: day, calendar: calendar, now: at(840),
                                      hr: pulses(88), steps: [], motion: [])
        let pulseReport = try XCTUnwrap(try save(pulseOnly, in: history).first)
        let pulseFreshness = try XCTUnwrap(pulseReport.sectorFreshness)
        XCTAssertEqual(pulseReport.computedAt, at(840))
        XCTAssertEqual(pulseFreshness.daytimePulseAt, at(840))
        XCTAssertEqual(pulseFreshness.nightAt, at(780))
        XCTAssertTrue(pulseFreshness.nightPreserved)
        XCTAssertEqual(pulseReport.night?.tstMin, 260)
        XCTAssertEqual(pulseReport.night?.avgHR, 54)
        XCTAssertNotEqual(pulseFreshness.activeEnergyAt, at(840))
        XCTAssertNotEqual(pulseFreshness.totalEnergyAt, at(840))

        var energyOnly = DayInput.make(day: day, calendar: calendar, now: at(900),
                                       hr: [], steps: [], motion: [])
        energyOnly.hkActiveKcal = 0
        let energyReport = try XCTUnwrap(try save(energyOnly, in: history).first)
        let energyFreshness = try XCTUnwrap(energyReport.sectorFreshness)
        XCTAssertEqual(energyReport.computedAt, at(900))
        XCTAssertEqual(energyFreshness.activeEnergyAt, at(900))
        XCTAssertEqual(energyReport.kcalActive, 0)
        XCTAssertEqual(energyReport.state(\.energyActive), .observed)
        XCTAssertNotEqual(energyFreshness.daytimePulseAt, at(900))
        XCTAssertNotEqual(energyFreshness.totalEnergyAt, at(900))
        XCTAssertEqual(energyFreshness.nightAt, at(780))
        XCTAssertTrue(energyFreshness.nightPreserved)
        XCTAssertEqual(energyReport.night?.tstMin, 260)
        XCTAssertEqual(energyReport.night?.avgHR, 54)
    }
}
