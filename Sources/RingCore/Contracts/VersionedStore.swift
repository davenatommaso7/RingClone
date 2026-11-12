import Foundation

// Archivio versionato (voce PLT-09) e registro diagnostico (voce ACQ-19).
// Un file illeggibile o di versione sconosciuta non viene mai sovrascritto:
// viene conservato con un altro nome e segnalato a chi chiama.

public enum QuarantineReason: Error, Sendable, Equatable {
    case unreadable
    case unknownVersion(Int)
}

public enum VersionedLoad<Payload: Sendable>: Sendable {
    case missing
    case loaded(Payload)
    case quarantined(reason: QuarantineReason, preservedAt: URL)
}

public enum VersionedStoreError: Error, Sendable, Equatable {
    case cannotPreserveUnreadableFile
}

public enum VersionedStore {
    private struct Header: Decodable {
        let schemaVersion: Int
    }

    private struct Envelope<P: Codable>: Codable {
        let schemaVersion: Int
        let payload: P
    }

    public static func load<P: Codable & Sendable>(_ type: P.Type, from url: URL,
                                                   schemaVersion: Int) throws -> VersionedLoad<P> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        switch inspect(type, at: url, schemaVersion: schemaVersion) {
        case .success(let payload):
            return .loaded(payload)
        case .failure(let reason):
            let kept = try preserve(url)
            return .quarantined(reason: reason, preservedAt: kept)
        }
    }

    /// Scrive il file. Se al suo posto c'e' un file illeggibile o di un'altra versione, prima lo conserva
    /// con un altro nome e ne restituisce il percorso.
    @discardableResult
    public static func save<P: Codable & Sendable>(_ payload: P, to url: URL, schemaVersion: Int,
                                                   options: Data.WritingOptions = [.atomic]) throws -> URL? {
        var kept: URL? = nil
        if FileManager.default.fileExists(atPath: url.path) {
            if case .failure = inspect(P.self, at: url, schemaVersion: schemaVersion) {
                kept = try preserve(url)
            }
        }
        let data = try JSONEncoder().encode(Envelope(schemaVersion: schemaVersion, payload: payload))
        try data.write(to: url, options: options)
        return kept
    }

    private static func inspect<P: Codable>(_ type: P.Type, at url: URL,
                                            schemaVersion: Int) -> Result<P, QuarantineReason> {
        guard let data = try? Data(contentsOf: url),
              let header = try? JSONDecoder().decode(Header.self, from: data) else {
            return .failure(.unreadable)
        }
        guard header.schemaVersion == schemaVersion else {
            return .failure(.unknownVersion(header.schemaVersion))
        }
        guard let envelope = try? JSONDecoder().decode(Envelope<P>.self, from: data) else {
            return .failure(.unreadable)
        }
        return .success(envelope.payload)
    }

    private static func preserve(_ url: URL) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        for n in 1...10_000 {
            let target = folder.appendingPathComponent("\(name).illeggibile-\(n)")
            if FileManager.default.fileExists(atPath: target.path) { continue }
            do {
                try FileManager.default.moveItem(at: url, to: target)
                return target
            } catch {
                throw VersionedStoreError.cannotPreserveUnreadableFile
            }
        }
        throw VersionedStoreError.cannotPreserveUnreadableFile
    }
}

/// Voci ammesse nel registro diagnostico: un elenco chiuso, senza valori sanitari.
public enum DiagnosticEvent: String, Codable, Sendable, CaseIterable {
    case readPresent, readNoSamplesOrAccessUndeterminable, readError, fileQuarantined
}

public struct DiagnosticEntry: Codable, Sendable, Equatable {
    public var at: Date
    public var event: DiagnosticEvent
    public var typeIdentifier: String?
    public var errorDomain: String?
    public var errorCode: Int?
    public init(at: Date, event: DiagnosticEvent, typeIdentifier: String? = nil,
                errorDomain: String? = nil, errorCode: Int? = nil) {
        self.at = at; self.event = event; self.typeIdentifier = typeIdentifier
        self.errorDomain = errorDomain; self.errorCode = errorCode
    }
}

public struct DiagnosticLog: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public static let defaultRetentionDays = 30

    public private(set) var entries: [DiagnosticEntry]

    public init(entries: [DiagnosticEntry] = []) { self.entries = entries }

    public mutating func append(_ entry: DiagnosticEntry) { entries.append(entry) }

    /// Registra l'esito di una lettura: solo tipo, stato e codice d'errore. Nessun valore, nessun conteggio.
    public mutating func record(_ provenance: Provenance) {
        switch provenance.state {
        case .present:
            append(DiagnosticEntry(at: provenance.readAt, event: .readPresent,
                                   typeIdentifier: provenance.typeIdentifier))
        case .noSamplesOrAccessUndeterminable:
            append(DiagnosticEntry(at: provenance.readAt, event: .readNoSamplesOrAccessUndeterminable,
                                   typeIdentifier: provenance.typeIdentifier))
        case .error(let domain, let code):
            append(DiagnosticEntry(at: provenance.readAt, event: .readError,
                                   typeIdentifier: provenance.typeIdentifier, errorDomain: domain, errorCode: code))
        }
    }

    public mutating func prune(now: Date, retentionDays: Int = DiagnosticLog.defaultRetentionDays) {
        let limit = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        entries.removeAll { $0.at < limit }
    }
}
