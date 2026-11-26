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
}
