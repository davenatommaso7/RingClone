import Foundation
import RingCore
import XCTest

/// RC7. Dati diurni e una rettifica serale autorizzata arrivano nella stessa lettura.
final class IndependentMixedEveningWakeTests: XCTestCase {
    func testMixedReadStoresQualifiedEveningWakeWithoutReplacingTheNight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9)))
        let source = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 9, count: 32)))
        let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65, sleepNeedH: 8)
        func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }
        func save(_ input: DayInput, in history: [DailyReport]) -> [DailyReport] {
            let report = DailyPipeline.run(input, profile: profile, history: history)
            return History.upsert(report, into: history, calendar: calendar)
        }
        func pulse(on date: Date) -> [TimedValue] {
            (Array(1440..<1460) + Array(2860..<2880)).map {
                TimedValue(date: date.addingTimeInterval(Double($0) * 30), value: 75)
            }
        }
        var history: [DailyReport] = []
        for offset in (1...4).reversed() {
            let date = at(Double(-offset) * 1440)
            let input = DayInput.make(day: date, calendar: calendar, now: date.addingTimeInterval(86_400),
                                      hr: pulse(on: date), steps: [], motion: [])
            history = save(input, in: history)
        }
        let night = SleepSegment(start: at(-20), end: at(240), stage: .light, source: source)
        let nocturnalPulse = (40..<160).map { TimedValue(date: at(Double($0) / 2), value: 54) }
        let before = (1440..<1460).map { TimedValue(date: at(Double($0) / 2), value: 75) }
        var initial = DayInput.make(day: day, calendar: calendar, now: at(780), hr: nocturnalPulse + before,
                                    steps: [], motion: [], appleSleep: [night])
        initial.appleSleepSource = source
        initial.hkActiveKcal = 100
        initial.hkBasalKcal = 1_500
        let confirmed = try History.decode(History.encode(save(initial, in: history)))
        let old = try XCTUnwrap(confirmed.last)
        let oldNight = try XCTUnwrap(old.night)
        XCTAssertEqual(oldNight.avgHR, 54)

        let after = (1440..<1460).map { TimedValue(date: at(Double($0) / 2), value: 88) }
        var mixed = DayInput.make(day: day, calendar: calendar, now: at(840), hr: after, steps: [], motion: [])
        mixed.hkActiveKcal = 75
        mixed.hkBasalKcal = 1_500
        let awake = SleepSegment(start: at(-10), end: at(-5), stage: .wake, source: source)
        mixed.explicitSleepProviders = [SleepProviderEvidence(source: source, samples: [
            SleepSourceSample(id: UUID(), segment: awake)
        ])]
        let raw = DailyPipeline.run(mixed, profile: profile, history: confirmed)
        XCTAssertNil(raw.night)
        let persisted = try History.decode(History.encode(History.upsert(raw, into: confirmed, calendar: calendar)))
        let previous = try XCTUnwrap(persisted.first { $0.date == at(-1440) })
        let current = try XCTUnwrap(persisted.last)
        let previousStates = [-15.0, -8.0, -2.0].map { minute in
            previous.sleepObservations?.first { $0.span.start <= at(minute) && at(minute) < $0.span.end }?.asleep
        }

        XCTAssertEqual(previousStates, [nil, false, true])
        XCTAssertEqual(try XCTUnwrap(previous.sri), -100 + 200 * 55.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(current.sri), -100 + 200 * 65.0 / 70.0, accuracy: 1e-9)
        XCTAssertEqual(current.night?.tstMin, 260)
        XCTAssertEqual(current.night?.avgHR, oldNight.avgHR)
        XCTAssertEqual(current.night?.rhr, oldNight.rhr)
        XCTAssertEqual(current.sleepDebtH, 220.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(current.kcalTotal, 1_575)
        XCTAssertEqual(current.computedAt, at(840))
        XCTAssertEqual(try History.encode(save(mixed, in: persisted)), try History.encode(persisted))
    }
}
