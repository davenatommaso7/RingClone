import Foundation
import RingCore
import XCTest

final class IndependentKarvonenObservedMinutesTests: XCTestCase {
    func testArchivedRHRAllowsExactKarvonenMinutesWithoutCountingTheDaytimeGap() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9)))
        let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65,
                                  zoneModel: .karvonen, hrMaxOverride: 190)
        let source = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 6, count: 32)))
        func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }
        func pulse(_ halfMinutes: [Int], bpm: Double) -> [TimedValue] {
            halfMinutes.map { TimedValue(date: at(Double($0) / 2), value: bpm) }
        }
        func update(_ input: DayInput, in history: [DailyReport]) throws -> [DailyReport] {
            let report = DailyPipeline.run(input, profile: profile, history: history)
            return try History.decode(History.encode(History.upsert(report, into: history, calendar: calendar)))
        }

        let sleep = SleepSegment(start: at(-20), end: at(240), stage: .light, source: source)
        var full = DayInput.make(day: day, calendar: calendar, now: at(780),
                                 hr: pulse(Array(60..<140) + Array(1440..<1450), bpm: 54),
                                 steps: [], motion: [], appleSleep: [sleep])
        full.appleSleepSource = source
        let archive = try update(full, in: [])
        let initial = try XCTUnwrap(archive.first)
        XCTAssertEqual(initial.night?.rhr, 54)
        XCTAssertEqual(initial.zoneBounds.count, 6)

        // [12:00, 12:05) e [12:10, 12:15) sono direttamente osservati.
        // La frequenza di 140 bpm appartiene a Z2: 54 + [0,6; 0,7) × (190−54).
        let shortDaytime = DayInput.make(day: day, calendar: calendar, now: at(840),
                                         hr: pulse(Array(1440..<1450) + Array(1460..<1470), bpm: 140),
                                         steps: [], motion: [])
        let report = try XCTUnwrap(try update(shortDaytime, in: archive).first)
        XCTAssertTrue(report.state(\.zones).hasValue)
        XCTAssertEqual(report.zoneMinutesDay, [0, 10, 0, 0, 0])
        XCTAssertEqual(report.zoneBounds, initial.zoneBounds)
        XCTAssertEqual(report.sectorFreshness?.daytimePulseAt, at(840))
        XCTAssertEqual(report.sectorFreshness?.nightAt, at(780))
        XCTAssertEqual(report.night?.rhr, 54)
    }
}
