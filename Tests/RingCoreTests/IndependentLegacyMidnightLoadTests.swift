import Foundation
import RingCore
import XCTest

/// RC6. Apertura di un archivio completo precedente alla riconciliazione.
final class IndependentLegacyMidnightLoadTests: XCTestCase {
    func testOpeningOldArchiveExplainsOnlyAConfirmedConflictAcrossAKnownBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9)))
        let previous = day.addingTimeInterval(-86_400)
        let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65, sleepNeedH: 8)
        func at(_ minute: Double) -> Date { day.addingTimeInterval(minute * 60) }
        var history: [DailyReport] = []
        for offset in (1...4).reversed() {
            let date = day.addingTimeInterval(Double(-offset) * 86_400)
            let pulse = (Array(1440..<1460) + Array(2860..<2880)).map {
                TimedValue(date: date.addingTimeInterval(Double($0) * 30), value: 75)
            }
            let input = DayInput.make(day: date, calendar: calendar, now: date.addingTimeInterval(86_400),
                                      hr: pulse, steps: [], motion: [])
            history.append(DailyPipeline.run(input, profile: profile, history: history))
        }
        let original = try XCTUnwrap(history.last)
        XCTAssertEqual(original.sri, 100)

        func archive(_ segment: SleepSegment?, removeCivilAxis: Bool = false) throws -> Data {
            let daytimeSleep = SleepSegment(start: at(0), end: at(240), stage: .light)
            let sleep = [segment, daytimeSleep].compactMap { $0 }
            let input = DayInput.make(day: day, calendar: calendar, now: at(780),
                                      hr: [TimedValue(date: at(720), value: 75)], steps: [], motion: [],
                                      appleSleep: sleep)
            let successor = DailyPipeline.run(input, profile: profile, history: history)
            var records = try XCTUnwrap(JSONSerialization.jsonObject(with: History.encode(history + [successor]))
                                        as? [[String: Any]])
            for index in records.indices {
                // Questi campi sono successivi a RC4. Manteniamo in particolare night.sleepRuns e stressAxis.
                for key in ["eveningSleepRevisions", "sleepObservationsBeforeReconciliation",
                            "regularityAlignmentInputs", "sriReconciledAt"] {
                    records[index].removeValue(forKey: key)
                }
                if var observed = records[index]["sleepObservations"] as? [[String: Any]] {
                    for sample in observed.indices { observed[sample].removeValue(forKey: "contextualWake") }
                    records[index]["sleepObservations"] = observed
                }
            }
            if removeCivilAxis { records[records.count - 2].removeValue(forKey: "stressAxis") }
            return try JSONSerialization.data(withJSONObject: records)
        }
        func prior(_ loaded: [DailyReport]) throws -> DailyReport {
            try XCTUnwrap(loaded.first { $0.date == previous })
        }
        func needsReread(_ report: DailyReport) -> Bool {
            Presentation.sleepLines(report).contains { line in
                let copy = (line.name + " " + line.value).lowercased()
                return ["rilegg", "rilett", "ricostr", "provenienz", "ricaric"].contains { copy.contains($0) }
            }
        }

        let sleep = SleepSegment(start: at(-8), end: at(0), stage: .light)
        let loaded = try History.decode(archive(sleep))
        let lastNight = try XCTUnwrap(loaded.last?.night)
        XCTAssertTrue(lastNight.sleepRuns.contains { $0.start <= at(-7) && at(-7) < $0.end })
        let conflicting = try prior(loaded)
        XCTAssertEqual(conflicting.sleepObservations?.first {
            $0.span.start <= at(-7) && at(-7) < $0.span.end
        }?.asleep, false)
        XCTAssertTrue(needsReread(conflicting))
        XCTAssertNotEqual(Presentation.sleepLines(conflicting).first { $0.name.contains("SRI") }?.value, "100")

        let inBed = SleepSegment(start: at(-8), end: at(0), stage: nil)
        let unknown = SleepSegment(start: at(-8), end: at(0), reportedStage: .unknown)
        for unconfirmed in [inBed, unknown] {
            let archiveWithoutSleepConflict = try History.decode(archive(unconfirmed))
            XCTAssertFalse(needsReread(try prior(archiveWithoutSleepConflict)))
        }
        let withoutAxis = try History.decode(archive(sleep, removeCivilAxis: true))
        XCTAssertFalse(needsReread(try prior(withoutAxis)))
    }
}
