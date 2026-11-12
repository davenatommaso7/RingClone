import XCTest
@testable import RingCore

/// Prove dei contratti dei dati di M1 (criteri CA-02 ... CA-07). Solo dati sintetici.
final class ContractsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var hour: ImportInterval { ImportInterval(start: t0, end: t0.addingTimeInterval(3600)) }

    private func sample(_ id: String, _ a: Double, _ b: Double, _ v: Double, _ source: String) -> ImportedSample {
        ImportedSample(uuid: id, start: t0.addingTimeInterval(a), end: t0.addingTimeInterval(b), value: v, source: source)
    }

    private func summary(_ read: ImportRead<ImportedSample>, admissible: ClosedRange<Double>? = nil,
                         hasDuration: Bool = true, total: Double? = nil) -> ImportedSeriesSummary {
        ImportedSeries.summarize(typeIdentifier: "prova", unit: "u", read: read, requested: hour,
                                 timeZoneIdentifier: "Europe/Rome", admissible: admissible, hasDuration: hasDuration,
                                 healthStatisticTotal: total, readAt: t0.addingTimeInterval(4000))
    }

    func testCA02_provenanceRoundTripAndMissingFieldRejected() throws {
        let p = summary(.samples([sample("a", 0, 600, 60, "Watch")])).provenance
        let data = try p.encoded()
        XCTAssertEqual(try Provenance.decode(data), p)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let required = ["contractVersion", "origin", "typeIdentifier", "unit", "sources", "requested",
                        "timeZoneIdentifier", "observed", "sampleCount", "outOfRangeCount", "coverage", "state", "readAt"]
        for key in required {
            var broken = object
            XCTAssertNotNil(broken.removeValue(forKey: key), "campo assente nel JSON: \(key)")
            let brokenData = try JSONSerialization.data(withJSONObject: broken)
            XCTAssertThrowsError(try Provenance.decode(brokenData), "accettato senza il campo \(key)")
        }
        var wrongVersion = object
        wrongVersion["contractVersion"] = 2
        let wrongData = try JSONSerialization.data(withJSONObject: wrongVersion)
        XCTAssertThrowsError(try Provenance.decode(wrongData))
    }

    func testCA03_versionedStoreNeverOverwritesUnreadableFiles() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ringclone-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("registro.json")
        let garbage = Data("questo non e' JSON".utf8)

        guard case .missing = try VersionedStore.load(DiagnosticLog.self, from: url, schemaVersion: 1) else {
            return XCTFail("atteso: file mancante")
        }
        var log = DiagnosticLog()
        log.append(DiagnosticEntry(at: t0, event: .readError, typeIdentifier: "prova", errorDomain: "HK", errorCode: 6))
        XCTAssertNil(try VersionedStore.save(log, to: url, schemaVersion: 1))
        guard case .loaded(let back) = try VersionedStore.load(DiagnosticLog.self, from: url, schemaVersion: 1) else {
            return XCTFail("atteso: file letto")
        }
        XCTAssertEqual(back, log)

        // Versione sconosciuta: conservato con un altro nome e segnalato
        guard case .quarantined(let reason1, let kept1) =
                try VersionedStore.load(DiagnosticLog.self, from: url, schemaVersion: 2) else {
            return XCTFail("atteso: file conservato")
        }
        XCTAssertEqual(reason1, .unknownVersion(1))
        XCTAssertFalse(fm.fileExists(atPath: url.path))
        XCTAssertTrue(fm.fileExists(atPath: kept1.path))

        // Illeggibile: conservato con un altro nome, contenuto intatto
        try garbage.write(to: url)
        guard case .quarantined(let reason2, let kept2) =
                try VersionedStore.load(DiagnosticLog.self, from: url, schemaVersion: 1) else {
            return XCTFail("atteso: file conservato")
        }
        XCTAssertEqual(reason2, .unreadable)
        XCTAssertNotEqual(kept1, kept2)
        XCTAssertEqual(try Data(contentsOf: kept2), garbage)

        // Salvataggio diretto sopra un file illeggibile: prima lo conserva, poi scrive
        try garbage.write(to: url)
        let kept3 = try XCTUnwrap(try VersionedStore.save(log, to: url, schemaVersion: 1))
        XCTAssertEqual(try Data(contentsOf: kept3), garbage)
        XCTAssertEqual(try Data(contentsOf: kept2), garbage)
        XCTAssertEqual(Set([kept1, kept2, kept3]).count, 3)
        guard case .loaded(let again) = try VersionedStore.load(DiagnosticLog.self, from: url, schemaVersion: 1) else {
            return XCTFail("atteso: file letto")
        }
        XCTAssertEqual(again, log)
    }

    func testCA04_seriesSummaryMatchesKnownResults() throws {
        let s = summary(.samples([
            sample("a", 0, 600, 60, "Watch"),
            sample("b", 300, 900, 250, "Watch"),
            sample("c", 1800, 2400, 48, "iPhone"),
            sample("d", 3000, 4200, .nan, "iPhone"),
        ]), admissible: 30...220)
        XCTAssertEqual(s.provenance.state, .present)
        XCTAssertEqual(s.provenance.origin, .importedFromHealth)
        XCTAssertEqual(s.provenance.sampleCount, 4)
        XCTAssertEqual(s.provenance.observed, ImportInterval(start: t0, end: t0.addingTimeInterval(4200)))
        XCTAssertEqual(s.minimum, 48)
        XCTAssertEqual(s.maximum, 250)
        XCTAssertEqual(s.provenance.outOfRangeCount, 2)
        XCTAssertEqual(s.nonFiniteCount, 1)
        XCTAssertEqual(s.provenance.sources, ["Watch", "iPhone"])
        guard case .fraction(let covered) = s.provenance.coverage else { return XCTFail("attesa una copertura") }
        XCTAssertEqual(covered, 2100.0 / 3600.0, accuracy: 1e-12)
        XCTAssertNoThrow(try s.provenance.validate())

        let instant = summary(.samples([sample("a", 0, 0, 60, "Watch")]), hasDuration: false)
        XCTAssertEqual(instant.provenance.coverage, .notApplicable)

        XCTAssertEqual(ImportedFormat.number(nil), "non disponibile")
        XCTAssertEqual(ImportedFormat.number(.nan), "non disponibile")
        XCTAssertEqual(ImportedFormat.number(.infinity, decimals: 2), "non disponibile")
        XCTAssertEqual(ImportedFormat.number(48.26, decimals: 1), "48,3")
        XCTAssertEqual(ImportedFormat.number(0), "0")
        XCTAssertFalse(ImportedFormat.number(1e300).isEmpty)
    }

    func testCA05_threeDistinctStatesAndMissingIsNotZero() throws {
        let empty = summary(.samples([]), total: nil)
        XCTAssertEqual(empty.provenance.state, .noSamplesOrAccessUndeterminable)
        XCTAssertEqual(empty.provenance.sampleCount, 0)
        XCTAssertNil(empty.provenance.observed)
        XCTAssertNil(empty.minimum)
        XCTAssertNil(empty.healthStatisticTotal)
        XCTAssertTrue(empty.perSourceSum.isEmpty)
        XCTAssertNoThrow(try empty.provenance.validate())

        let failed = summary(.failure(domain: "com.apple.healthkit", code: 6), total: 12)
        XCTAssertEqual(failed.provenance.state, .error(domain: "com.apple.healthkit", code: 6))
        XCTAssertEqual(failed.provenance.coverage, .notApplicable)
        XCTAssertNil(failed.minimum)
        XCTAssertNil(failed.healthStatisticTotal)
        XCTAssertNoThrow(try failed.provenance.validate())

        let zero = summary(.samples([sample("z", 0, 60, 0, "Watch")]), total: 0)
        XCTAssertEqual(zero.provenance.state, .present)
        XCTAssertEqual(zero.minimum, 0)
        XCTAssertEqual(zero.healthStatisticTotal, 0)
        XCTAssertEqual(zero.perSourceSum, ["Watch": 0])

        XCTAssertNotEqual(empty.provenance.state, failed.provenance.state)
        XCTAssertNotEqual(empty.provenance.state, zero.provenance.state)
        XCTAssertNotEqual(empty, zero)
    }

    func testCA06_sleepSamplesKeepTheNativeCategory() throws {
        let expected: [(Int, NativeSleepCategory)] = [(0, .inBed), (1, .asleepUnspecified), (2, .awake),
                                                      (3, .asleepCore), (4, .asleepDeep), (5, .asleepREM)]
        for (raw, category) in expected {
            XCTAssertEqual(NativeSleepCategory(healthKitRawValue: raw), category)
        }
        XCTAssertNil(NativeSleepCategory(healthKitRawValue: 99))
        XCTAssertEqual(NativeSleepCategory.inBed.nativeName, "A letto")
        XCTAssertEqual(NativeSleepCategory.asleepUnspecified.nativeName, "Sonno non specificato")
        XCTAssertEqual(Set(NativeSleepCategory.allCases.map { $0.nativeName }).count, 6)

        func night(_ id: String, _ a: Double, _ b: Double, _ raw: Int, _ source: String) -> ImportedSleepSample {
            ImportedSleepSample(uuid: id, start: t0.addingTimeInterval(a), end: t0.addingTimeInterval(b),
                                categoryRawValue: raw, source: source)
        }
        let series = ImportedSleep.summarize(
            read: .samples([night("s2", 600, 1200, 1, "Watch"), night("s1", 0, 3000, 0, "iPhone"),
                            night("s3", 1200, 1800, 99, "Watch")]),
            requested: hour, timeZoneIdentifier: "Europe/Rome", readAt: t0)
        let categories: [NativeSleepCategory?] = [.inBed, .asleepUnspecified, nil]
        XCTAssertEqual(series.samples.map { $0.uuid }, ["s1", "s2", "s3"])
        XCTAssertEqual(series.samples.map { $0.category }, categories)
        XCTAssertEqual(series.samples.map { $0.categoryRawValue }, [0, 1, 99])
        XCTAssertEqual(series.provenance.sampleCount, 3)
        XCTAssertEqual(series.unknownCategoryCount, 1)
        XCTAssertEqual(series.provenance.state, .present)
        guard case .fraction(let covered) = series.provenance.coverage else { return XCTFail("attesa una copertura") }
        XCTAssertEqual(covered, 3000.0 / 3600.0, accuracy: 1e-12)

        let failed = ImportedSleep.summarize(read: .failure(domain: "HK", code: 5), requested: hour,
                                             timeZoneIdentifier: "Europe/Rome", readAt: t0)
        XCTAssertEqual(failed.provenance.state, .error(domain: "HK", code: 5))
        XCTAssertTrue(failed.samples.isEmpty)
    }

    func testCA07_duplicatesAreNeitherMergedNorSummedSilently() throws {
        let s = summary(.samples([
            sample("w1", 0, 600, 100, "Watch"),
            sample("w2", 600, 1200, 50, "Watch"),
            sample("p1", 0, 1200, 120, "iPhone"),
            sample("p1", 0, 1200, 120, "iPhone"),
        ]), total: 170)
        XCTAssertEqual(s.provenance.sampleCount, 4)
        XCTAssertEqual(s.duplicateUUIDCount, 1)
        XCTAssertEqual(s.perSourceCount, ["Watch": 2, "iPhone": 2])
        XCTAssertEqual(s.perSourceSum, ["Watch": 150, "iPhone": 240])
        XCTAssertEqual(s.healthStatisticTotal, 170)
        guard case .fraction(let covered) = s.provenance.coverage else { return XCTFail("attesa una copertura") }
        XCTAssertEqual(covered, 1200.0 / 3600.0, accuracy: 1e-12)
    }

    func testDiagnosticLogHoldsOnlyStatesAndIsPruned() throws {
        var log = DiagnosticLog()
        log.record(summary(.samples([sample("a", 0, 600, 60, "Watch")])).provenance)
        log.record(summary(.samples([])).provenance)
        log.record(summary(.failure(domain: "HK", code: 6)).provenance)
        XCTAssertEqual(log.entries.map { $0.event }, [.readPresent, .readNoSamplesOrAccessUndeterminable, .readError])
        XCTAssertEqual(log.entries.last?.errorCode, 6)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(log)) as? [String: Any])
        let first = try XCTUnwrap((object["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(first.keys), ["at", "event", "typeIdentifier"])

        log.append(DiagnosticEntry(at: t0.addingTimeInterval(-40 * 86_400), event: .fileQuarantined))
        log.prune(now: t0.addingTimeInterval(4000))
        XCTAssertEqual(log.entries.count, 3)
        log.prune(now: t0.addingTimeInterval(4000 + 31 * 86_400))
        XCTAssertTrue(log.entries.isEmpty)
    }
}
