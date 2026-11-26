import Foundation
import XCTest
@testable import RingCore

final class MidnightProvenanceRegressionTests: XCTestCase {
    private let previous = testDay(7), successor = testDay(8)

    private func report(_ day: Date, now: Date? = nil, observedPulse: Bool = true, stages: [SleepSegment] = [],
                        source: SleepSourceKey? = nil, providers: [SleepProviderEvidence] = [],
                        history: [DailyReport] = []) -> DailyReport {
        let hr: [TimedValue] = observedPulse ? (0..<2880).map {
            TimedValue(date: day.addingTimeInterval(Double($0) * 30), value: 80)
        } : []
        var input = DayInput.make(day: day, calendar: testCal, now: now ?? day.addingTimeInterval(86_400),
                                  hr: hr, steps: [], motion: [], appleSleep: stages)
        input.appleSleepSource = source
        input.explicitSleepProviders = providers
        return DailyPipeline.run(input, profile: testProfile, history: history)
    }

    private func history() -> [DailyReport] {
        (4...7).reduce(into: [DailyReport]()) { archive, day in
            let r = report(testDay(day), history: archive)
            archive = History.upsert(r, into: archive, calendar: testCal)
        }
    }

    private func at(_ minutes: Double) -> Date { successor.addingTimeInterval(minutes * 60) }

    private func night(_ key: SleepSourceKey?) -> [SleepSegment] {
        [SleepSegment(start: at(-30), end: at(240), stage: .light, source: key)]
    }

    private func wakeInput(_ provider: SleepProviderEvidence, now: Date) -> DayInput {
        var input = DayInput.make(day: successor, calendar: testCal, now: now, hr: [], steps: [], motion: [])
        input.explicitSleepProviders = [provider]
        return input
    }

    private func preceding(_ history: [DailyReport]) throws -> DailyReport {
        try XCTUnwrap(history.first { $0.date == previous })
    }

    private func asleep(_ report: DailyReport, at date: Date) -> Bool? {
        report.sleepObservations?.first { $0.span.start <= date && date < $0.span.end }?.asleep
    }

    private func legacy(_ original: DailyReport) -> DailyReport {
        var report = original
        report.eveningSleepRevisions = nil
        report.regularityAlignmentInputs = nil
        report.sriReconciledAt = nil
        report.sriNeedsProvenance = nil
        report.sleepObservations = original.originalSleepObservations?.map { SleepObservation(span: $0.span, asleep: $0.asleep) }
        report.sleepObservationsBeforeReconciliation = nil
        return report
    }

    func testOpeningLegacyArchiveWarnsOnlyWithDecodableRelevantConflictAndReloadClearsIt() throws {
        let days = history()
        let next = report(successor, stages: night(nil), history: days)
        let old = (days + [next]).map(legacy)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent(".build", isDirectory: true).appendingPathComponent("rc6-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        try History.save(old, to: file)
        let before = try Data(contentsOf: file)
        let loaded = try History.load(from: file)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let marked = try preceding(loaded)
        XCTAssertEqual(marked.sri, 100) // Il valore archivistico resta decodificabile, la UI non lo conferma.
        XCTAssertEqual(asleep(marked, at: at(-15)), false)
        XCTAssertNotNil(Presentation.regularityProvenanceNotice(marked))
        XCTAssertEqual(Presentation.sleepLines(marked).first { $0.name == "Regolarità (SRI)" }?.value, "Da verificare")
        XCTAssertTrue(Presentation.sleepLines(marked).contains { $0.value.contains("rilettura dei dati di sonno e veglia") })
        XCTAssertEqual(Presentation.circadianLines(marked).first?.value, "Da verificare")
        XCTAssertEqual(marked.state(\.alignment), .stale)
        XCTAssertNotNil(Presentation.regularityProvenanceNotice(try XCTUnwrap(loaded.last)))
        XCTAssertNil(Presentation.regularityProvenanceNotice(loaded[0]))

        var unsortedZone = try XCTUnwrap(old.last)
        unsortedZone.stressAxis = nil
        let noScope = try History.decode(History.encode(Array(old.dropLast()) + [unsortedZone]))
        XCTAssertNil(Presentation.regularityProvenanceNotice(try preceding(noScope)))
        let knownLater = report(successor, stages: [SleepSegment(start: at(30), end: at(270), stage: .light)], history: days)
        let noOverlap = try History.decode(History.encode(Array(old.dropLast()) + [legacy(knownLater)]))
        XCTAssertNil(Presentation.regularityProvenanceNotice(try preceding(noOverlap)))

        let key = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 5, count: 32)))
        let isolated = SleepProviderEvidence(source: key, samples: [
            SleepSourceSample(id: UUID(), segment: SleepSegment(start: at(-30), end: at(0), stage: .wake))
        ])
        let stillAmbiguous = DailyPipeline.applyingIsolatedWake(wakeInput(isolated, now: at(1450)), to: loaded)
        let again = try History.decode(History.encode(stillAmbiguous))
        XCTAssertNotNil(Presentation.regularityProvenanceNotice(try preceding(again)))
        XCTAssertNotNil(Presentation.regularityProvenanceNotice(try XCTUnwrap(again.last)))

        let now = at(1500)
        let reread = report(previous, now: now, history: loaded)
        var corrected = History.upsert(reread, into: loaded, calendar: testCal)
        corrected = History.upsert(report(successor, now: now, stages: night(nil), history: corrected), into: corrected, calendar: testCal)
        try History.save(corrected, to: file)
        let reopened = try History.load(from: file)
        let resolved = try preceding(reopened)
        XCTAssertNil(Presentation.regularityProvenanceNotice(resolved))
        XCTAssertNil(Presentation.regularityProvenanceNotice(try XCTUnwrap(reopened.last)))
        XCTAssertEqual(asleep(resolved, at: at(-15)), true)
        XCTAssertEqual(try XCTUnwrap(resolved.sri), 100 - 200 * 30.0 / (3 * 1440), accuracy: 1e-9)
    }

    func testIsolatedWakeOnlyRemovesCoveredCellsFromMatchingSource() throws {
        let a = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 1, count: 32)))
        let b = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 2, count: 32)))
        let days = history()
        let first = report(successor, stages: night(a), source: a, history: days)
        let archived = History.upsert(first, into: days, calendar: testCal)
        XCTAssertNil(Presentation.regularityProvenanceNotice(try preceding(archived)))
        let wakeStart = at(-15).addingTimeInterval(1), wakeEnd = at(0).addingTimeInterval(-1)
        let sample = SleepSourceSample(id: UUID(), segment: SleepSegment(start: wakeStart, end: wakeEnd, stage: .wake))
        let wrong = report(successor, now: at(1450), observedPulse: false,
                           providers: [SleepProviderEvidence(source: b, samples: [sample])], history: archived)
        let elsewhere = History.upsert(wrong, into: archived, calendar: testCal)
        XCTAssertEqual(asleep(try preceding(elsewhere), at: at(-10)), true)

        let valid = SleepSourceSample(id: UUID(), segment: sample.segment)
        let isolated = report(successor, now: at(1460), observedPulse: false,
                              providers: [SleepProviderEvidence(source: a, samples: [valid, valid])], history: elsewhere)
        XCTAssertNil(isolated.night)
        let h = History.upsert(isolated, into: elsewhere, calendar: testCal)
        let r = try preceding(h)
        XCTAssertEqual(asleep(r, at: at(-15)), true) // Epoca al margine iniziale coperta solo in parte.
        XCTAssertEqual(asleep(r, at: at(-10)), false)
        XCTAssertEqual(asleep(r, at: at(0).addingTimeInterval(-30)), true)
        // Ritirati 14 dei 30 minuti: restano 16 min di disaccordo.
        XCTAssertEqual(try XCTUnwrap(r.sri), 100 - 200 * 16.0 / (3 * 1440), accuracy: 1e-9)
        XCTAssertEqual(try History.encode(History.upsert(isolated, into: h, calendar: testCal)), try History.encode(h))
    }

    func testContradictionInSnapshotAndUnknownSourceCannotWithdrawSleep() throws {
        let key = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 3, count: 32)))
        let days = history()
        let wake = SleepSourceSample(id: UUID(), segment: SleepSegment(start: at(-20), end: at(-5), stage: .wake))
        let disputed = SleepSourceSample(id: UUID(), segment: SleepSegment(start: at(-20), end: at(-5), stage: .deep))
        for source in [key, nil] {
            let first = report(successor, stages: night(source), source: source, history: days)
            let archived = History.upsert(first, into: days, calendar: testCal)
            let packet = SleepProviderEvidence(source: key, samples: source == nil ? [wake] : [wake, disputed])
            let update = report(successor, now: at(1460), observedPulse: false, providers: [packet], history: archived)
            XCTAssertEqual(asleep(try preceding(History.upsert(update, into: archived, calendar: testCal)), at: at(-10)), true)
        }
    }

    func testWakeUUIDKeepsFirstObservationAcrossRetriesAndLateDelivery() throws {
        let key = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 4, count: 32)))
        let days = history()
        let awake = SleepSourceSample(id: UUID(), segment: SleepSegment(start: at(-30), end: at(0), stage: .wake))
        let provider = SleepProviderEvidence(source: key, samples: [awake])
        let first = report(successor, now: at(1440), stages: night(key), source: key, history: days)
        let admitted = History.upsert(first, into: days, calendar: testCal)
        for order in [[1, 2], [2, 1]] {
            var h = admitted
            for i in order {
                let r = i == 1 ? report(successor, now: at(1450), observedPulse: false, providers: [provider], history: h)
                    : report(successor, now: at(1460), stages: night(key), source: key, history: h)
                h = History.upsert(r, into: h, calendar: testCal)
            }
            h = try History.decode(History.encode(h))
            XCTAssertEqual(asleep(try preceding(h), at: at(-10)), true)
            let historical = report(previous, now: at(1450), history: h)
            XCTAssertEqual(asleep(historical, at: at(-10)), false)
            let polled = report(successor, now: at(1470), observedPulse: false, providers: [provider], history: h)
            h = History.upsert(polled, into: h, calendar: testCal)
            XCTAssertEqual(asleep(try preceding(h), at: at(-10)), true, "La rilettura non riapplica il campione.")
        }
    }

    func testOrdinaryBundleSelectionRetainsMixedAndUnattributedSegments() throws {
        let a = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 1, count: 32)))
        let b = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 2, count: 32)))
        let bundle = "com.apple.health.synthetic"
        let bed = SleepSegment(start: at(-50), end: at(210), stage: nil)
        let one = SleepSegment(start: at(-30), end: at(30), stage: .light, source: a)
        let mixed = SleepSegment(start: at(30), end: at(90), stage: .deep, source: b)
        let unknown = SleepSegment(start: at(90), end: at(150), reportedStage: .asleepUnspecified)
        let otherApple = SleepSegment(start: at(-30), end: at(120), stage: .rem, source: b)
        let phone = SleepSegment(start: at(-30), end: at(400), stage: .light)
        let byBundle = [bundle: [unknown, mixed, one, bed], "com.apple.health.other": [otherApple], "synthetic.phone": [phone]]
        let selected = SleepSources.selectForReconciliation(byBundle)
        XCTAssertEqual(selected.selected.map(\.start), [bed.start, one.start, mixed.start, unknown.start])
        XCTAssertEqual(selected.selected.map(\.reportedStage), [nil, .light, .deep, .asleepUnspecified])
        XCTAssertNil(selected.source)
        XCTAssertEqual(SleepSources.selectForReconciliation([bundle: [bed, one]]).source, a)
        XCTAssertNil(SleepSources.selectForReconciliation([bundle: [one, unknown]]).source)
    }

    func testIsolatedWakePreservesNightAndCanArriveBeforeItsReport() throws {
        let key = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 6, count: 32)))
        let days = history()
        let original = report(successor, now: at(1440), stages: night(key), source: key, history: days)
        let archived = History.upsert(original, into: days, calendar: testCal)
        let wake = SleepSourceSample(id: UUID(), segment: SleepSegment(start: at(-15), end: at(0), stage: .wake))
        let provider = SleepProviderEvidence(source: key, samples: [wake])
        let input = wakeInput(provider, now: at(1450))
        let late = DailyPipeline.applyingIsolatedWake(input, to: archived)
        let originalFirst = try XCTUnwrap(late.last)
        XCTAssertEqual(late.count, archived.count)
        XCTAssertEqual(originalFirst.computedAt, original.computedAt)
        XCTAssertEqual(originalFirst.night?.tstMin, 270)
        XCTAssertEqual(originalFirst.dailySleepMin, 270)
        XCTAssertEqual(originalFirst.sleepDebtH, 3.5, accuracy: 1e-9)
        XCTAssertEqual(asleep(try preceding(late), at: at(-20)), true)
        XCTAssertEqual(asleep(try preceding(late), at: at(-10)), false)
        let early = DailyPipeline.applyingIsolatedWake(input, to: days)
        XCTAssertEqual(early.count, days.count)
        XCTAssertNil(early.first { $0.date == successor })
        let outOfOrder = History.upsert(original, into: early, calendar: testCal)
        XCTAssertEqual(try History.encode(late), try History.encode(outOfOrder))
        let reopened = try History.decode(History.encode(late))
        XCTAssertEqual(try History.encode(DailyPipeline.applyingIsolatedWake(input, to: reopened)), try History.encode(late))
    }

    func testWakeBackfillKeepsEarliestEventAndSameSnapshotCannotReaffirmConflictingSleep() throws {
        let key = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 7, count: 32)))
        let days = history()
        let original = report(successor, now: at(1440), stages: night(key), source: key, history: days)
        let archived = History.upsert(original, into: days, calendar: testCal)
        let wake = SleepSourceSample(id: UUID(), segment: SleepSegment(start: at(-15), end: at(0), stage: .wake))
        let provider = SleepProviderEvidence(source: key, samples: [wake])
        let earlier = wakeInput(provider, now: at(1450)), later = wakeInput(provider, now: at(1470))
        let first = DailyPipeline.applyingIsolatedWake(earlier, to: archived)
        let chronological = DailyPipeline.applyingIsolatedWake(later, to: first)
        let backwards = DailyPipeline.applyingIsolatedWake(earlier, to: DailyPipeline.applyingIsolatedWake(later, to: archived))
        XCTAssertEqual(try History.encode(chronological), try History.encode(backwards))
        let revisions = History.eveningRevisions(in: backwards, successor: successor)
        XCTAssertEqual(revisions.filter { $0.nativeWakes?.contains(where: { $0.sampleID == wake.id }) == true }.map(\.confirmedAt), [earlier.now])
        let both = report(successor, now: at(1480), stages: night(key), source: key, providers: [provider], history: backwards)
        let unchanged = History.upsert(both, into: backwards, calendar: testCal)
        XCTAssertEqual(asleep(try preceding(unchanged), at: at(-20)), true)
        XCTAssertEqual(asleep(try preceding(unchanged), at: at(-10)), false)
    }
}
