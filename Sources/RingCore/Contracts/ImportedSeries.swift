import Foundation

// Riepilogo di una serie importata da Salute e istantanea dell'importazione (voci PLT-08 e PLT-15).
// Nessuna media, nessun valore "della notte", nessuna unione fra sorgenti.
// I campioni non sono Codable di proposito: M1 non conserva copie dei valori importati (decisione D-18).

/// Esito di una lettura: campioni (anche nessuno) oppure errore con dominio e codice.
public enum ImportRead<Sample: Sendable>: Sendable {
    case samples([Sample])
    case failure(domain: String, code: Int)
}

public struct ImportedSample: Sendable, Equatable {
    public var uuid: String
    public var start: Date
    public var end: Date
    public var value: Double
    public var source: String
    public init(uuid: String, start: Date, end: Date, value: Double, source: String) {
        self.uuid = uuid; self.start = start; self.end = end; self.value = value; self.source = source
    }
}

public struct ImportedSeriesSummary: Sendable, Equatable {
    public var provenance: Provenance
    /// Minimo e massimo fra i valori numerici, compresi quelli fuori dall'intervallo ammesso
    public var minimum: Double?
    public var maximum: Double?
    public var nonFiniteCount: Int
    /// Campioni che ripetono un identificativo gia' visto: dichiarati, non rimossi
    public var duplicateUUIDCount: Int
    public var perSourceCount: [String: Int]
    /// Somma dei valori numerici per sorgente. Non esiste una somma fra sorgenti diverse.
    public var perSourceSum: [String: Double]
    /// Totale secondo la statistica di Salute, tenuto separato. nil = non disponibile, diverso da zero.
    public var healthStatisticTotal: Double?
}

public enum ImportedSeries {
    public static func summarize(typeIdentifier: String, unit: String, read: ImportRead<ImportedSample>,
                                 requested: ImportInterval, timeZoneIdentifier: String,
                                 admissible: ClosedRange<Double>? = nil, hasDuration: Bool,
                                 healthStatisticTotal: Double? = nil, readAt: Date) -> ImportedSeriesSummary {
        let samples: [ImportedSample]
        let failure: ImportState?
        switch read {
        case .samples(let list):
            samples = list
            failure = nil
        case .failure(let domain, let code):
            samples = []
            failure = .error(domain: domain, code: code)
        }
        let finite = samples.map { $0.value }.filter { $0.isFinite }
        var outOfRange = 0
        var counts: [String: Int] = [:]
        var sums: [String: Double] = [:]
        for s in samples {
            counts[s.source, default: 0] += 1
            if s.value.isFinite {
                sums[s.source, default: 0] += s.value
                if let range = admissible, !range.contains(s.value) { outOfRange += 1 }
            } else {
                outOfRange += 1
            }
        }
        let provenance = makeProvenance(
            typeIdentifier: typeIdentifier, unit: unit,
            spans: samples.map { ImportInterval(start: $0.start, end: $0.end) },
            sources: samples.map { $0.source }, outOfRangeCount: outOfRange, failure: failure,
            requested: requested, timeZoneIdentifier: timeZoneIdentifier, hasDuration: hasDuration, readAt: readAt)
        return ImportedSeriesSummary(
            provenance: provenance, minimum: finite.min(), maximum: finite.max(),
            nonFiniteCount: samples.count - finite.count,
            duplicateUUIDCount: samples.count - Set(samples.map { $0.uuid }).count,
            perSourceCount: counts, perSourceSum: sums,
            healthStatisticTotal: failure == nil ? healthStatisticTotal : nil)
    }

    static func makeProvenance(typeIdentifier: String, unit: String, spans: [ImportInterval], sources: [String],
                               outOfRangeCount: Int, failure: ImportState?, requested: ImportInterval,
                               timeZoneIdentifier: String, hasDuration: Bool, readAt: Date) -> Provenance {
        var observed: ImportInterval? = nil
        if let first = spans.map({ $0.start }).min(), let last = spans.map({ $0.end }).max() {
            observed = ImportInterval(start: first, end: last)
        }
        let state: ImportState = failure ?? (spans.isEmpty ? .noSamplesOrAccessUndeterminable : .present)
        let coverage: Coverage = (hasDuration && failure == nil)
            ? .fraction(coveredFraction(spans, within: requested)) : .notApplicable
        return Provenance(origin: .importedFromHealth, typeIdentifier: typeIdentifier, unit: unit,
                          sources: Array(Set(sources)).sorted(), requested: requested,
                          timeZoneIdentifier: timeZoneIdentifier, observed: observed, sampleCount: spans.count,
                          outOfRangeCount: outOfRangeCount, coverage: coverage, state: state, readAt: readAt)
    }

    /// Parte dell'intervallo richiesto coperta dall'unione dei campioni: le sovrapposizioni contano una volta.
    public static func coveredFraction(_ spans: [ImportInterval], within requested: ImportInterval) -> Double {
        let total = requested.end.timeIntervalSince(requested.start)
        guard total > 0 else { return 0 }
        var pieces: [(a: Double, b: Double)] = []
        for s in spans {
            let a = max(s.start, requested.start).timeIntervalSince(requested.start)
            let b = min(s.end, requested.end).timeIntervalSince(requested.start)
            if b > a { pieces.append((a: a, b: b)) }
        }
        pieces.sort { $0.a < $1.a }
        var covered = 0.0
        var current: (a: Double, b: Double)? = nil
        for p in pieces {
            if let c = current, p.a <= c.b {
                current = (a: c.a, b: max(c.b, p.b))
            } else {
                if let c = current { covered += c.b - c.a }
                current = p
            }
        }
        if let c = current { covered += c.b - c.a }
        return min(1, max(0, covered / total))
    }
}

/// Categorie del sonno con il significato originale di Salute (HKCategoryValueSleepAnalysis). Nessuna conversione.
public enum NativeSleepCategory: String, Codable, Sendable, CaseIterable {
    case inBed, asleepUnspecified, awake, asleepCore, asleepDeep, asleepREM

    public init?(healthKitRawValue: Int) {
        switch healthKitRawValue {
        case 0: self = .inBed
        case 1: self = .asleepUnspecified
        case 2: self = .awake
        case 3: self = .asleepCore
        case 4: self = .asleepDeep
        case 5: self = .asleepREM
        default: return nil
        }
    }

    public var nativeName: String {
        switch self {
        case .inBed: return "A letto"
        case .asleepUnspecified: return "Sonno non specificato"
        case .awake: return "Sveglio"
        case .asleepCore: return "Sonno core"
        case .asleepDeep: return "Sonno profondo"
        case .asleepREM: return "Sonno REM"
        }
    }
}

public struct ImportedSleepSample: Sendable, Equatable {
    public var uuid: String
    public var start: Date
    public var end: Date
    /// Valore originale di Salute, conservato anche quando la categoria non e' nota a questa versione
    public var categoryRawValue: Int
    public var source: String
    public var category: NativeSleepCategory? { NativeSleepCategory(healthKitRawValue: categoryRawValue) }
    public init(uuid: String, start: Date, end: Date, categoryRawValue: Int, source: String) {
        self.uuid = uuid; self.start = start; self.end = end
        self.categoryRawValue = categoryRawValue; self.source = source
    }
}

public struct ImportedSleepSeries: Sendable, Equatable {
    public var provenance: Provenance
    /// Tutti i campioni, in ordine di inizio: nessuno unito, nessuno scartato
    public var samples: [ImportedSleepSample]
    public var unknownCategoryCount: Int
}

public enum ImportedSleep {
    public static let typeIdentifier = "HKCategoryTypeIdentifierSleepAnalysis"

    public static func summarize(read: ImportRead<ImportedSleepSample>, requested: ImportInterval,
                                 timeZoneIdentifier: String, readAt: Date) -> ImportedSleepSeries {
        var samples: [ImportedSleepSample] = []
        var failure: ImportState? = nil
        switch read {
        case .samples(let list):
            samples = list.sorted { ($0.start, $0.end, $0.uuid) < ($1.start, $1.end, $1.uuid) }
        case .failure(let domain, let code):
            failure = .error(domain: domain, code: code)
        }
        let unknown = samples.filter { $0.category == nil }.count
        let provenance = ImportedSeries.makeProvenance(
            typeIdentifier: typeIdentifier, unit: "categoria",
            spans: samples.map { ImportInterval(start: $0.start, end: $0.end) },
            sources: samples.map { $0.source }, outOfRangeCount: unknown, failure: failure,
            requested: requested, timeZoneIdentifier: timeZoneIdentifier, hasDuration: true, readAt: readAt)
        return ImportedSleepSeries(provenance: provenance, samples: samples, unknownCategoryCount: unknown)
    }
}

/// Istantanea di una lettura da Salute. Vive solo in memoria e non passa dall'elaborazione giornaliera.
public struct ImportSnapshot: Sendable, Equatable {
    public var readAt: Date
    public var requested: ImportInterval
    public var timeZoneIdentifier: String
    public var series: [ImportedSeriesSummary]
    public var sleep: ImportedSleepSeries?
    public init(readAt: Date, requested: ImportInterval, timeZoneIdentifier: String,
                series: [ImportedSeriesSummary], sleep: ImportedSleepSeries?) {
        self.readAt = readAt; self.requested = requested; self.timeZoneIdentifier = timeZoneIdentifier
        self.series = series; self.sleep = sleep
    }
}

/// Formati dei valori importati: un valore assente o non numerico non causa mai un arresto.
public enum ImportedFormat {
    public static let unavailable = "non disponibile"

    public static func number(_ value: Double?, decimals: Int = 0) -> String {
        guard let v = value, v.isFinite else { return unavailable }
        let digits = max(0, min(6, decimals))
        return String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }
}
