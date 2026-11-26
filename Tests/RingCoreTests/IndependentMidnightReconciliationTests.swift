import Foundation
import XCTest
@testable import RingCore

/// RC-AUD-02, quinto ciclo. Gli istanti sono UTC e i campioni sono sintetici.
final class IndependentMidnightReconciliationTests: XCTestCase {
    private let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65, sleepNeedH: 8)

    private func fixture() throws -> (prior: Date, history: [DailyReport], confirmation: DayInput) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 5)))
        let days = (0..<5).map { start.addingTimeInterval(Double($0) * 86_400) }
        let prior = days[3], current = days[4]
        var history: [DailyReport] = []
        for day in days.prefix(4) {
            // Copertura diretta: [12:00, 12:10) e [23:50, 24:00).
            // Nel giorno precedente la conferma, i due campioni delle 23:56 mancano.
            let offsets = Array(1440..<1460) + (2860..<2880).filter { day != prior || !(2872..<2874).contains($0) }
            let samples = offsets.map { TimedValue(date: day.addingTimeInterval(Double($0) * 30), value: 75) }
            let input = DayInput.make(day: day, calendar: calendar, now: day.addingTimeInterval(86_400),
                                      hr: samples, steps: [], motion: [])
            let report = DailyPipeline.run(input, profile: profile, history: history)
            history = History.upsert(report, into: history, calendar: calendar)
        }
        func at(_ minutes: Double) -> Date { current.addingTimeInterval(minutes * 60) }
        // Notte principale al risveglio: sonno [-8, -4) e [-3, 240).
        // L'intervallo [-4, -3) è ignoto anche dopo la conferma.
        let sleep = [
            SleepSegment(start: at(-10), end: at(245), stage: nil),
            SleepSegment(start: at(-8), end: at(-4), stage: .light),
            SleepSegment(start: at(-3), end: at(240), stage: .light)
        ]
        let samples = (1440..<1460).map { TimedValue(date: current.addingTimeInterval(Double($0) * 30), value: 75) }
        let input = DayInput.make(day: current, calendar: calendar, now: at(780),
                                  hr: samples, steps: [], motion: [], appleSleep: sleep)
        return (prior, history, input)
    }

    private func state(_ report: DailyReport, at instant: Date) -> Bool? {
        report.sleepObservations?.first { $0.span.start <= instant && instant < $0.span.end }?.asleep
    }

    func testConfirmedNightCorrectsOnlyObservedPriorDaySleepAndBothRegularityScores() throws {
        let f = try fixture()
        let next = f.confirmation.day
        func at(_ minutes: Double) -> Date { next.addingTimeInterval(minutes * 60) }

        let original = try XCTUnwrap(f.history.last)
        XCTAssertEqual(original.date, f.prior)
        XCTAssertEqual(state(original, at: at(-7)), false)
        XCTAssertNil(state(original, at: at(-3.5)))
        XCTAssertEqual(original.sri, 100)

        let nightDay = DailyPipeline.run(f.confirmation, profile: profile, history: f.history)
        XCTAssertEqual(try XCTUnwrap(nightDay.night).tstMin, 247, accuracy: 1e-9)
        XCTAssertEqual(nightDay.dailySleepMin, 247)
        XCTAssertEqual(nightDay.sleepDebtH, 233.0 / 60, accuracy: 1e-9)
        // Coppie comprensive di oggi: 20 + 20 + 19 + 10 min validi, 7 min discordanti.
        XCTAssertEqual(try XCTUnwrap(nightDay.sri), -100 + 200 * 62.0 / 69.0, accuracy: 1e-9)

        let persisted = History.upsert(nightDay, into: f.history, calendar: f.confirmation.calendar)
        XCTAssertEqual(persisted.count, 5)
        let revised = try XCTUnwrap(persisted.first { $0.date == f.prior })
        XCTAssertEqual(state(revised, at: at(-9)), false)
        XCTAssertEqual(state(revised, at: at(-7)), true)
        XCTAssertNil(state(revised, at: at(-3.5)))
        XCTAssertEqual(state(revised, at: at(-2)), true)
        XCTAssertNil(revised.night)
        XCTAssertNil(revised.dailySleepMin)
        XCTAssertEqual(revised.sleepDebtH, 0)
        // SRI storico: 20 + 20 + 19 min validi, 7 min discordanti.
        XCTAssertEqual(try XCTUnwrap(revised.sri), -100 + 200 * 52.0 / 59.0, accuracy: 1e-9)
    }

    func testReconciliationSurvivesReloadReplayAndPartialReplacement() throws {
        let f = try fixture()
        let input = f.confirmation, cal = input.calendar
        let point = input.day.addingTimeInterval(-7 * 60)
        let first = DailyPipeline.run(input, profile: profile, history: f.history)
        let saved = History.upsert(first, into: f.history, calendar: cal)
        let restarted = try History.decode(History.encode(saved))
        let restoredPrior = try XCTUnwrap(restarted.first { $0.date == f.prior })
        XCTAssertEqual(state(restoredPrior, at: point), true)

        let replay = DailyPipeline.run(input, profile: profile, history: restarted)
        let retried = History.upsert(replay, into: restarted, calendar: cal)
        XCTAssertEqual(try History.encode(retried), try History.encode(restarted))
        XCTAssertEqual(retried.compactMap(\.dailySleepMin), [247])

        // Una lettura più recente con sola FC diurna è parziale, senza evidenza di ritiro del sonno.
        let onlyPulse = TimedValue(date: input.day.addingTimeInterval(12 * 3600), value: 75)
        let partial = DayInput.make(day: input.day, calendar: cal, now: input.now.addingTimeInterval(3600),
                                    hr: [onlyPulse], steps: [], motion: [])
        let reread = DailyPipeline.run(partial, profile: profile, history: retried)
        let replaced = History.upsert(reread, into: retried, calendar: cal)
        let prior = try XCTUnwrap(replaced.first { $0.date == f.prior })
        XCTAssertEqual(state(prior, at: point), true)
        XCTAssertNil(state(prior, at: input.day.addingTimeInterval(-3.5 * 60)))
        XCTAssertEqual(prior.sri, restoredPrior.sri)
        XCTAssertEqual(replaced.filter { $0.date == input.day }.count, 1)
    }
}
