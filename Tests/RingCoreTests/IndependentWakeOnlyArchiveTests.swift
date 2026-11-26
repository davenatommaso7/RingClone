import Foundation
import RingCore
import XCTest

/// RC6. Una lettura di sola veglia può aggiornare la riconciliazione senza sostituire il report del risveglio.
final class IndependentWakeOnlyArchiveTests: XCTestCase {
    func testProviderOnlyRefreshPreservesExistingNightAndUnrelatedFieldsAcrossRestart() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9)))
        let previous = day.addingTimeInterval(-86_400)
        let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65, sleepNeedH: 8)
        let source = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 1, count: 32)))
        let otherSource = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 2, count: 32)))
        func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }
        func pulse(on date: Date) -> [TimedValue] {
            (Array(1440..<1460) + Array(2860..<2880)).map {
                TimedValue(date: date.addingTimeInterval(Double($0) * 30), value: 75)
            }
        }
        var history: [DailyReport] = []
        for offset in (1...4).reversed() {
            let date = at(-Double(offset) * 1440)
            let input = DayInput.make(day: date, calendar: calendar, now: date.addingTimeInterval(86_400),
                                      hr: pulse(on: date), steps: [], motion: [])
            history = History.upsert(DailyPipeline.run(input, profile: profile, history: history),
                                     into: history, calendar: calendar)
        }
        let night = SleepSegment(start: at(-20), end: at(240), stage: .light, source: source)
        var initial = DayInput.make(day: day, calendar: calendar, now: at(780), hr: pulse(on: day),
                                    steps: [], motion: [], appleSleep: [night])
        initial.appleSleepSource = source
        initial.hkActiveKcal = 200
        initial.hkBasalKcal = 1_500
        let first = DailyPipeline.run(initial, profile: profile, history: history)
        let confirmed = try History.decode(History.encode(History.upsert(first, into: history, calendar: calendar)))
        func current(_ archive: [DailyReport]) throws -> DailyReport {
            try XCTUnwrap(archive.first { $0.date == day })
        }
        func states(_ archive: [DailyReport]) throws -> [Bool?] {
            let report = try XCTUnwrap(archive.first { $0.date == previous })
            return [-15.0, -8.0, -2.0].map { minute in
                report.sleepObservations?.first { $0.span.start <= at(minute) && at(minute) < $0.span.end }?.asleep
            }
        }
        let kept = try current(confirmed)
        XCTAssertNotNil(kept.night)
        XCTAssertEqual(kept.dailySleepMin, 260)
        XCTAssertEqual(kept.sleepDebtH, 220.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(kept.kcalActive, 200)
        XCTAssertEqual(kept.kcalTotal, 1_700)
        XCTAssertEqual(kept.computedAt, at(780))
        XCTAssertEqual(try XCTUnwrap(kept.sri), -100 + 200 * 60.0 / 70.0, accuracy: 1e-9)
        XCTAssertEqual(try states(confirmed), [nil, true, true])

        let awake = SleepSourceSample(id: UUID(), segment: SleepSegment(start: at(-10), end: at(-5), stage: .wake))
        let contradictory = SleepSourceSample(id: UUID(), segment: SleepSegment(start: at(-10), end: at(-5), stage: .light))
        let unknown = SleepSourceSample(id: UUID(), segment: SleepSegment(
            start: at(-10), end: at(-5), reportedStage: .unknown))
        let right = SleepProviderEvidence(source: source, samples: [awake])
        let foreign = SleepProviderEvidence(source: otherSource, samples: [awake])
        let ambiguous = SleepProviderEvidence(source: source, samples: [unknown])
        let conflicting = SleepProviderEvidence(source: source, samples: [awake, contradictory])

        func refresh(_ provider: SleepProviderEvidence) throws -> [DailyReport] {
            // Stesso percorso di Store. La query di revisione non restituisce campioni ordinari.
            var partial = DayInput.make(day: day, calendar: calendar, now: at(840), hr: [], steps: [], motion: [])
            partial.explicitSleepProviders = [provider]
            let revised = DailyPipeline.applyingIsolatedWake(partial, to: confirmed)
            return try History.decode(History.encode(revised))
        }
        func assertOriginalDayRetained(_ archive: [DailyReport], file: StaticString = #filePath,
                                       line: UInt = #line) throws {
            let report = try current(archive)
            XCTAssertEqual(archive.filter { $0.date == day }.count, 1, file: file, line: line)
            XCTAssertEqual(report.night?.sleepOnset, kept.night?.sleepOnset, file: file, line: line)
            XCTAssertEqual(report.night?.tstMin, kept.night?.tstMin, file: file, line: line)
            XCTAssertEqual(report.dailySleepMin, kept.dailySleepMin, file: file, line: line)
            XCTAssertEqual(report.sleepDebtH, kept.sleepDebtH, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(report.kcalActive, kept.kcalActive, file: file, line: line)
            XCTAssertEqual(report.kcalTotal, kept.kcalTotal, file: file, line: line)
            XCTAssertEqual(report.rhr, kept.rhr, file: file, line: line)
            XCTAssertEqual(report.computedAt, kept.computedAt, file: file, line: line)
        }

        let updated = try refresh(right)
        XCTAssertEqual(try states(updated), [nil, false, true])
        try assertOriginalDayRetained(updated)
        let revisedPrior = try XCTUnwrap(updated.first { $0.date == previous })
        XCTAssertEqual(try XCTUnwrap(revisedPrior.sri), -100 + 200 * 55.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(current(updated).sri), -100 + 200 * 65.0 / 70.0, accuracy: 1e-9)
        for rejected in [foreign, ambiguous, conflicting] {
            let unchanged = try refresh(rejected)
            XCTAssertEqual(try states(unchanged), [nil, true, true])
            try assertOriginalDayRetained(unchanged)
            XCTAssertEqual(try current(unchanged).sri, kept.sri)
        }
    }

    func testCorrectionSourceDoesNotChangeExistingSleepSelection() throws {
        let deviceA = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 1, count: 32)))
        let deviceB = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 2, count: 32)))
        let otherApp = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 3, count: 32)))
        let start = Date(timeIntervalSince1970: 1_783_468_800)
        func span(_ from: Double, _ to: Double, _ stage: SleepStage?, _ source: SleepSourceKey?) -> SleepSegment {
            SleepSegment(start: start.addingTimeInterval(from * 60), end: start.addingTimeInterval(to * 60),
                         stage: stage, source: source)
        }
        // Lo stesso autore vince con 140 minuti totali. Suddividere per orologio farebbe vincere il concorrente a 100.
        let competitors = ["com.audit.other": [span(0, 100, .light, otherApp)]]
        var mixed = competitors
        mixed["com.audit.sleep"] = [span(70, 140, .light, deviceB), span(0, 70, .light, deviceA)]
        let actual = SleepSources.selectForReconciliation(mixed)
        let ordinary = SleepSources.pick(mixed)
        XCTAssertEqual(actual.selected.map(\.start), ordinary.map(\.start))
        XCTAssertEqual(actual.selected.map(\.end), ordinary.map(\.end))
        XCTAssertEqual(actual.selected.map(\.source), [deviceA, deviceB])
        XCTAssertNil(actual.source)

        var missingDevice = competitors
        missingDevice["com.audit.sleep"] = [span(0, 70, .light, deviceA), span(70, 140, .light, nil)]
        XCTAssertNil(SleepSources.selectForReconciliation(missingDevice).source)

        var identifiable = competitors
        identifiable["com.audit.sleep"] = [span(-10, 150, nil, nil), span(0, 140, .light, deviceA)]
        let consistent = SleepSources.selectForReconciliation(identifiable)
        XCTAssertEqual(consistent.selected.map(\.start), SleepSources.pick(identifiable).map(\.start))
        XCTAssertEqual(consistent.source, deviceA)
    }
}
