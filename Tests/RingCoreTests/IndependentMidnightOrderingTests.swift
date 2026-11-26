import Foundation
import XCTest
@testable import RingCore

/// RC5. Le date di acquisizione devono governare il risultato anche dopo una consegna tardiva.
final class IndependentMidnightOrderingTests: XCTestCase {
    func testChronologicallyNewestEvidenceWinsRegardlessOfArrivalOrderAndReplay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 5)))
        let day = start.addingTimeInterval(4 * 86_400)
        let prior = day.addingTimeInterval(-86_400)
        let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65)
        let noon = 1440..<1460
        var history: [DailyReport] = []
        for offset in 0..<4 {
            let date = start.addingTimeInterval(Double(offset) * 86_400)
            let samples = (Array(noon) + Array(2840..<2880)).map {
                TimedValue(date: date.addingTimeInterval(Double($0) * 30), value: 75)
            }
            let input = DayInput.make(day: date, calendar: calendar, now: date.addingTimeInterval(86_400),
                                      hr: samples, steps: [], motion: [])
            let report = DailyPipeline.run(input, profile: profile, history: history)
            history = History.upsert(report, into: history, calendar: calendar)
        }

        func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }
        func segment(_ start: Double, _ end: Double, _ stage: SleepStage?) -> SleepSegment {
            SleepSegment(start: at(start), end: at(end), stage: stage)
        }
        let samples = noon.map { TimedValue(date: day.addingTimeInterval(Double($0) * 30), value: 75) }
        let sleep = [segment(-20, 245, nil), segment(-20, 240, .light)]
        let awake = [segment(-10, -5, .wake), segment(15, 270, .light)]
        func input(readAt: Double, stages: [SleepSegment]) -> DayInput {
            DayInput.make(day: day, calendar: calendar, now: at(readAt),
                          hr: samples, steps: [], motion: [], appleSleep: stages)
        }
        let first = input(readAt: 780, stages: sleep)
        let middle = input(readAt: 840, stages: awake)
        let latest = input(readAt: 900, stages: sleep)
        func apply(_ update: DayInput, to archive: [DailyReport]) throws -> [DailyReport] {
            let report = DailyPipeline.run(update, profile: profile, history: archive)
            let next = History.upsert(report, into: archive, calendar: calendar)
            return try History.decode(History.encode(next))
        }
        func previous(_ reports: [DailyReport]) throws -> DailyReport {
            try XCTUnwrap(reports.first { $0.date == prior })
        }
        func state(_ reports: [DailyReport]) throws -> Bool? {
            let time = at(-8)
            let report = try previous(reports)
            return report.sleepObservations?.first { $0.span.start <= time && time < $0.span.end }?.asleep
        }

        let firstSaved = try apply(first, to: history)
        XCTAssertEqual(try state(firstSaved), true)
        let chronologicalMiddle = try apply(middle, to: firstSaved)
        XCTAssertEqual(try state(chronologicalMiddle), false)
        let chronological = try apply(latest, to: chronologicalMiddle)
        let newestFirst = try apply(latest, to: firstSaved)
        let delayed = try apply(middle, to: newestFirst)

        for archive in [chronological, delayed] {
            XCTAssertEqual(try state(archive), true)
            let evening = try previous(archive)
            // 70 accordi su 90 min nel report precedente, 80 su 100 al risveglio.
            XCTAssertEqual(try XCTUnwrap(evening.sri), -100 + 200 * 70.0 / 90.0, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(archive.last?.sri), 60, accuracy: 1e-9)
            XCTAssertEqual(archive.compactMap(\.dailySleepMin), [260])
            let replayed = try apply(latest, to: archive)
            XCTAssertEqual(try History.encode(replayed), try History.encode(archive))
        }
        XCTAssertEqual(try previous(chronological).sleepObservations, try previous(delayed).sleepObservations)
    }
}
