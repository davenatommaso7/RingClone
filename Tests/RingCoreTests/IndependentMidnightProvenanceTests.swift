import Foundation
import RingCore
import XCTest

/// RC6. I report precedenti alla provenienza sono costruiti come JSON sintetico.
final class IndependentMidnightProvenanceTests: XCTestCase {
    private let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65, sleepNeedH: 8)

    func testLegacyOverlapRequiresAnExplanationUntilThePreviousDayCanBeReadAgain() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9)))
        let previous = day.addingTimeInterval(-86_400)
        let instant = day.addingTimeInterval(-7 * 60)

        func pulse(on date: Date) -> [TimedValue] {
            (Array(1440..<1460) + Array(2860..<2880)).map {
                TimedValue(date: date.addingTimeInterval(Double($0) * 30), value: 75)
            }
        }
        var modern: [DailyReport] = []
        for offset in (1...4).reversed() {
            let date = day.addingTimeInterval(Double(-offset) * 86_400)
            let input = DayInput.make(day: date, calendar: calendar, now: date.addingTimeInterval(86_400),
                                      hr: pulse(on: date), steps: [], motion: [])
            let report = DailyPipeline.run(input, profile: profile, history: modern)
            modern = History.upsert(report, into: modern, calendar: calendar)
        }

        func replacingSuccessor(_ history: [DailyReport], onset: Double) -> [DailyReport] {
            let sample = SleepSegment(start: day.addingTimeInterval(onset * 60),
                                      end: day.addingTimeInterval(240 * 60), stage: .light)
            let input = DayInput.make(day: day, calendar: calendar, now: day.addingTimeInterval(780 * 60),
                                      hr: pulse(on: day), steps: [], motion: [], appleSleep: [sample])
            let report = DailyPipeline.run(input, profile: profile, history: history)
            return History.upsert(report, into: history, calendar: calendar)
        }
        func priorReport(_ history: [DailyReport]) throws -> DailyReport {
            try XCTUnwrap(history.first { $0.date == previous })
        }
        func state(_ report: DailyReport) -> Bool? {
            report.sleepObservations?.first { $0.span.start <= instant && instant < $0.span.end }?.asleep
        }
        func rereadPrompt(_ report: DailyReport) -> Bool {
            Presentation.sleepLines(report).contains { line in
                let copy = (line.name + " " + line.value).lowercased()
                return ["rilegg", "rilett", "ricostr", "provenienz", "ricaric"].contains { copy.contains($0) }
            }
        }
        func visibleSRI(_ report: DailyReport) throws -> String {
            try XCTUnwrap(Presentation.sleepLines(report).first { $0.name.contains("SRI") }).value
        }

        let original = try XCTUnwrap(modern.last)
        XCTAssertEqual(state(original), false)
        XCTAssertEqual(original.sri, 100)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: History.encode(modern)) as? [[String: Any]])
        let last = json.count - 1
        var observations = try XCTUnwrap(json[last]["sleepObservations"] as? [[String: Any]])
        XCTAssertTrue(observations.contains { $0["contextualWake"] as? Bool == true })
        for index in observations.indices {
            observations[index].removeValue(forKey: "contextualWake")
        }
        json[last]["sleepObservations"] = observations
        json[last].removeValue(forKey: "regularityAlignmentInputs")
        let legacy = try History.decode(JSONSerialization.data(withJSONObject: json))

        // La notte fuori dalla sera archiviata non rende necessaria una rilettura.
        let unrelated = try priorReport(replacingSuccessor(legacy, onset: 15))
        XCTAssertEqual(try visibleSRI(unrelated), "100")
        XCTAssertFalse(rereadPrompt(unrelated))

        // [23:52, 24:00) è sonno confermato, ma la veglia legacy non ha origine verificabile.
        let archived = replacingSuccessor(legacy, onset: -8)
        let restarted = try History.decode(History.encode(archived))
        let unresolved = try priorReport(restarted)
        XCTAssertNotNil(restarted.last?.night)
        XCTAssertEqual(state(unresolved), false)
        XCTAssertTrue(rereadPrompt(unresolved))
        XCTAssertNotEqual(try visibleSRI(unresolved), "100")

        // Prima di archiviare la notte, un report moderno dello stesso giorno non ha avvisi.
        XCTAssertFalse(rereadPrompt(original))
        let corrected = try priorReport(replacingSuccessor(modern, onset: -8))
        XCTAssertEqual(state(corrected), true)
        XCTAssertFalse(rereadPrompt(corrected))

        // Un nuovo report a partire dai campioni originali ricostruisce la provenienza.
        let reread = DayInput.make(day: previous, calendar: calendar, now: day.addingTimeInterval(840 * 60),
                                   hr: pulse(on: previous), steps: [], motion: [])
        let fresh = DailyPipeline.run(reread, profile: profile, history: restarted)
        let restored = try priorReport(History.upsert(fresh, into: restarted, calendar: calendar))
        XCTAssertEqual(state(restored), true)
        XCTAssertFalse(rereadPrompt(restored))
        // 8 dei 60 confronti osservabili risultano discordanti.
        XCTAssertEqual(try XCTUnwrap(restored.sri), -100 + 200 * 52.0 / 60.0, accuracy: 1e-9)
    }

    func testAnonymousAwakeAndInBedWithoutANightDoNotWithdrawConfirmedSleep() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9)))
        let previous = day.addingTimeInterval(-86_400)
        func at(_ minute: Double) -> Date { day.addingTimeInterval(minute * 60) }
        let eveningPulse = (-40..<0).map { TimedValue(date: at(Double($0) / 2), value: 75) }
        let initial = DayInput.make(day: previous, calendar: calendar, now: day,
                                    hr: eveningPulse, steps: [], motion: [])
        let initialReport = DailyPipeline.run(initial, profile: profile, history: [])
        func reading(_ history: [DailyReport], now: Double, samples: [SleepSegment]) -> DailyReport {
            let input = DayInput.make(day: day, calendar: calendar, now: at(now),
                                      hr: [TimedValue(date: at(720), value: 75)], steps: [], motion: [],
                                      appleSleep: samples)
            return DailyPipeline.run(input, profile: profile, history: history)
        }
        func update(_ history: [DailyReport], now: Double, samples: [SleepSegment]) -> [DailyReport] {
            History.upsert(reading(history, now: now, samples: samples), into: history, calendar: calendar)
        }
        func states(_ history: [DailyReport]) throws -> [Bool?] {
            let prior = try XCTUnwrap(history.first { $0.date == previous })
            return [-15.0, -8.0, -2.0].map { minute in
                prior.sleepObservations?.first { $0.span.start <= at(minute) && at(minute) < $0.span.end }?.asleep
            }
        }
        let confirmed = update([initialReport], now: 780, samples: [
            SleepSegment(start: at(-20), end: at(240), stage: .light)
        ])
        XCTAssertEqual(try states(confirmed), [true, true, true])

        let anonymous = [
            SleepSegment(start: at(-10), end: at(-5), stage: .wake),
            SleepSegment(start: at(-4), end: at(0), stage: nil)
        ]
        let incomplete = reading(confirmed, now: 840, samples: anonymous)
        XCTAssertNil(incomplete.night)
        let partial = History.upsert(incomplete, into: confirmed, calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(partial.last?.night).tstMin, 260)
        let restarted = try History.decode(History.encode(partial))
        XCTAssertEqual(try states(restarted), [true, true, true])
        let replayed = update(restarted, now: 840, samples: anonymous)
        XCTAssertEqual(try History.encode(replayed), try History.encode(restarted))
    }
}
