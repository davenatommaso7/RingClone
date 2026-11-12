import Foundation

// Contratto di provenienza, versione 1 (traguardo M1, voce PLT-08).
// Solo tipi di dati: nessuna formula del motore.

/// Origine di un valore mostrato. In M1 l'unica origine ammessa a schermo e' `importedFromHealth`.
public enum ValueOrigin: String, Codable, Sendable, CaseIterable {
    case importedFromHealth, computed, estimated
}

public struct ImportInterval: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
}

/// Tre stati distinti per ogni tipo di dato. L'app non attribuisce mai una causa all'assenza di campioni.
public enum ImportState: Codable, Sendable, Equatable {
    case present
    case noSamplesOrAccessUndeterminable
    case error(domain: String, code: Int)
}

public enum Coverage: Codable, Sendable, Equatable {
    case notApplicable
    case fraction(Double)
}

public enum ProvenanceError: Error, Sendable, Equatable {
    case invalid(String)
}

public struct Provenance: Codable, Sendable, Equatable {
    public static let currentContractVersion = 1

    public var contractVersion: Int
    public var origin: ValueOrigin
    public var typeIdentifier: String
    public var unit: String
    /// Nomi delle sorgenti come li riporta Salute, senza duplicati, in ordine alfabetico
    public var sources: [String]
    public var requested: ImportInterval
    public var timeZoneIdentifier: String
    /// Dal primo inizio all'ultima fine dei campioni; assente se non ci sono campioni
    public var observed: ImportInterval?
    public var sampleCount: Int
    /// Campioni con valore non numerico oppure fuori dall'intervallo ammesso: contati, mai scartati
    public var outOfRangeCount: Int
    public var coverage: Coverage
    public var state: ImportState
    public var readAt: Date

    public init(contractVersion: Int = Provenance.currentContractVersion, origin: ValueOrigin, typeIdentifier: String,
                unit: String, sources: [String], requested: ImportInterval, timeZoneIdentifier: String,
                observed: ImportInterval?, sampleCount: Int, outOfRangeCount: Int, coverage: Coverage,
                state: ImportState, readAt: Date) {
        self.contractVersion = contractVersion; self.origin = origin; self.typeIdentifier = typeIdentifier
        self.unit = unit; self.sources = sources; self.requested = requested
        self.timeZoneIdentifier = timeZoneIdentifier; self.observed = observed; self.sampleCount = sampleCount
        self.outOfRangeCount = outOfRangeCount; self.coverage = coverage; self.state = state; self.readAt = readAt
    }

    public func validate() throws {
        guard contractVersion == Self.currentContractVersion else { throw ProvenanceError.invalid("contractVersion") }
        guard !typeIdentifier.isEmpty else { throw ProvenanceError.invalid("typeIdentifier") }
        guard !timeZoneIdentifier.isEmpty else { throw ProvenanceError.invalid("timeZoneIdentifier") }
        guard requested.end >= requested.start else { throw ProvenanceError.invalid("requested") }
        guard sampleCount >= 0, outOfRangeCount >= 0, outOfRangeCount <= sampleCount else {
            throw ProvenanceError.invalid("sampleCount")
        }
        if case .fraction(let f) = coverage {
            guard f.isFinite, f >= 0, f <= 1 else { throw ProvenanceError.invalid("coverage") }
        }
        switch state {
        case .present:
            guard sampleCount > 0, observed != nil, !sources.isEmpty else { throw ProvenanceError.invalid("state") }
        case .noSamplesOrAccessUndeterminable, .error:
            guard sampleCount == 0, observed == nil, sources.isEmpty else { throw ProvenanceError.invalid("state") }
        }
    }

    public func encoded() throws -> Data {
        try validate()
        return try JSONEncoder().encode(self)
    }

    /// Rifiuta un valore senza un campo obbligatorio o non coerente con il contratto.
    public static func decode(_ data: Data) throws -> Provenance {
        let p = try JSONDecoder().decode(Provenance.self, from: data)
        try p.validate()
        return p
    }
}
