import Foundation
import RingCore
import XCTest

/// RC7. Una notte calcolabile non attesta che la rilettura copra la notte archiviata.
final class IndependentFragmentaryNightTests: XCTestCase {
    func testInternallyClosedFragmentWithoutObservedOldTailKeepsArchivedNight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9)))
        let source = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 7, count: 32)))
        let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65, sleepNeedH: 8)
        func at(_ minute: Double) -> Date { day.addingTimeInterval(minute * 60) }
        func segment(_ start: Double, _ end: Double, _ stage: SleepStage?) -> SleepSegment {
            SleepSegment(start: at(start), end: at(end), stage: stage, source: source)
        }
        func input(_ now: Double, energy: Double, samples: [SleepSegment]) -> DayInput {
            let pulse = (1440..<1460).map { TimedValue(date: at(Double($0) / 2), value: 78) }
            var reportInput = DayInput.make(day: day, calendar: calendar, now: at(now), hr: pulse,
                                            steps: [], motion: [], appleSleep: samples)
            reportInput.appleSleepSource = source
            reportInput.hkActiveKcal = energy
            reportInput.hkBasalKcal = 1_500
            return reportInput
        }

        let fullInput = input(780, energy: 140, samples: [
            segment(-30, 250, nil), segment(-20, 100, .light), segment(100, 240, .rem)
        ])
        let full = DailyPipeline.run(fullInput, profile: profile, history: [])
        let archived = try History.decode(History.encode(History.upsert(full, into: [], calendar: calendar)))
        let old = try XCTUnwrap(archived.first?.night)
        XCTAssertEqual(old.sleepOnset, at(-20))
        XCTAssertEqual(old.finalWake, at(240))
        XCTAssertEqual(old.tstMin, 260, accuracy: 1e-9)

        // Una rilettura a metà giornata vede 195 minuti di sonno, un risveglio interno
        // e un inBed più breve. La coda [03:05, 04:00) archiviata non è osservata.
        let fragmentInput = input(840, energy: 185, samples: [
            segment(-30, 195, nil), segment(-20, 85, .light),
            segment(85, 95, .wake), segment(95, 185, .light)
        ])
        let fragment = DailyPipeline.run(fragmentInput, profile: profile, history: archived)
        let raw = try XCTUnwrap(fragment.night)
        XCTAssertEqual(raw.tstMin, 195, accuracy: 1e-9)
        XCTAssertEqual(raw.finalWake, at(185))
        XCTAssertEqual(raw.wasoMin, 10, accuracy: 1e-9)
        XCTAssertEqual(raw.bedTimingOrigin, .inBedObservation)

        let updated = History.upsert(fragment, into: archived, calendar: calendar)
        let report = try XCTUnwrap(History.decode(History.encode(updated)).first)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(report.computedAt, at(840))
        XCTAssertEqual(report.kcalActive, 185)
        XCTAssertEqual(report.kcalTotal, 1_685)
        XCTAssertEqual(report.dailySleepMin, 260)
        XCTAssertEqual(report.sleepDebtH, 220.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(report.night?.finalWake, old.finalWake)
        XCTAssertEqual(report.night?.sleepRuns, old.sleepRuns)
        XCTAssertEqual(report.night?.stages, old.stages)
    }
}
