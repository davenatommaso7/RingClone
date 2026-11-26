import Foundation
import XCTest
@testable import RingCore

/// RC5. La revisione di una notte può rivedere soltanto gli intervalli che osserva.
final class IndependentMidnightPartialCoverageTests: XCTestCase {
    func testPartialNightCannotWithdrawKnownSleepAndNativeWakeOnlyRevisesObservedCells() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9)))
        let previous = day.addingTimeInterval(-86_400)
        let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65)
        func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }
        func segment(_ start: Double, _ end: Double, _ stage: SleepStage?) -> SleepSegment {
            SleepSegment(start: at(start), end: at(end), stage: stage)
        }
        let eveningPulse = (-40..<0).map { TimedValue(date: day.addingTimeInterval(Double($0) * 30), value: 75) }
        let earlier = DayInput.make(day: previous, calendar: calendar, now: day, hr: eveningPulse,
                                    steps: [], motion: [])
        let initial = DailyPipeline.run(earlier, profile: profile, history: [])
        let laterPulse = TimedValue(date: at(720), value: 75)
        func replace(readAt: Double, sleep: [SleepSegment], in history: [DailyReport]) -> [DailyReport] {
            let input = DayInput.make(day: day, calendar: calendar, now: at(readAt),
                                      hr: [laterPulse], steps: [], motion: [], appleSleep: sleep)
            let report = DailyPipeline.run(input, profile: profile, history: history)
            return History.upsert(report, into: history, calendar: calendar)
        }
        func states(_ history: [DailyReport]) throws -> [Bool?] {
            let prior = try XCTUnwrap(history.first { $0.date == previous })
            return [-15.0, -8.0, -2.0].map { minute in
                prior.sleepObservations?.first { $0.span.start <= at(minute) && at(minute) < $0.span.end }?.asleep
            }
        }

        let confirmed = replace(readAt: 780, sleep: [segment(-20, 245, nil), segment(-20, 240, .light)],
                                in: [initial])
        XCTAssertEqual(try states(confirmed), [true, true, true])

        // La notte è visibile e terminata, ma prima di mezzanotte questa lettura è vuota.
        let partial = replace(readAt: 840, sleep: [segment(15, 270, .light)], in: confirmed)
        XCTAssertNotNil(partial.last?.night)
        XCTAssertEqual(try states(partial), [true, true, true])

        // Solo 23:50–23:55 ha un nuovo stato osservato. Alle 23:45 e 23:58 resta il sonno confermato.
        let explicit = replace(readAt: 900, sleep: [segment(-10, -5, .wake), segment(15, 270, .light)], in: partial)
        XCTAssertEqual(try states(explicit), [true, false, true])
    }
}
