import Combine
import Foundation
import RingCore
import UIKit

// Registro diagnostico di M1 (voci ACQ-19, PLT-04, PRV-02).
// Contiene solo tipo di dato, stato e codice d'errore: nessun valore e nessun conteggio.
// File con versione di schema, protezione completa (illeggibile a dispositivo bloccato),
// escluso dalle copie di sicurezza, voci conservate 30 giorni.
// Un file illeggibile non viene sovrascritto: resta nella stessa cartella con un altro nome.
// Per ogni tipo viene annotato solo il cambio di stato, non ogni lettura.

extension ImportedSection {
    var provenance: Provenance {
        switch self {
        case .series(let item): return item.summary.provenance
        case .sleep(let series): return series.provenance
        }
    }
}

@MainActor
final class DiagnosticRegistry: ObservableObject {
    static let shared = DiagnosticRegistry()

    @Published private(set) var log = DiagnosticLog()
    @Published private(set) var lastRead: [Provenance] = []
    @Published private(set) var notices: [String] = []

    private var loaded = false
    private let lockedText = "Dispositivo bloccato: il file del registro non è accessibile. Nulla è stato modificato."

    private init() {}

    func loadIfNeeded() {
        guard !loaded else { return }
        guard UIApplication.shared.isProtectedDataAvailable else {
            note(lockedText)
            return
        }
        loaded = true
        do {
            let url = try fileURL()
            switch try VersionedStore.load(DiagnosticLog.self, from: url, schemaVersion: DiagnosticLog.schemaVersion) {
            case .missing:
                break
            case .loaded(let saved):
                log = saved
            case .quarantined(let reason, let preservedAt):
                log.append(DiagnosticEntry(at: Date(), event: .fileQuarantined))
                note("Il file del registro non era leggibile (\(Self.text(reason))). È stato conservato come \(preservedAt.lastPathComponent) e non è stato sovrascritto.")
            }
        } catch {
            noteError(error)
        }
    }

    /// Annota l'esito di una lettura: per ogni tipo solo lo stato, e solo se e' cambiato.
    func record(_ provenances: [Provenance]) {
        lastRead = provenances
        loadIfNeeded()
        guard loaded else { return }
        let before = log
        for provenance in provenances where Self.isChange(provenance, in: log) {
            log.record(provenance)
        }
        log.prune(now: Date())
        if log != before {
            save()
        }
    }

    private static func isChange(_ provenance: Provenance, in log: DiagnosticLog) -> Bool {
        guard let last = log.entries.last(where: { $0.typeIdentifier == provenance.typeIdentifier }) else {
            return true
        }
        switch provenance.state {
        case .present:
            return last.event != .readPresent
        case .noSamplesOrAccessUndeterminable:
            return last.event != .readNoSamplesOrAccessUndeterminable
        case .error(let domain, let code):
            return last.event != .readError || last.errorDomain != domain || last.errorCode != code
        }
    }

    private func save() {
        guard UIApplication.shared.isProtectedDataAvailable else {
            note(lockedText)
            return
        }
        do {
            let url = try fileURL()
            let kept = try VersionedStore.save(log, to: url, schemaVersion: DiagnosticLog.schemaVersion,
                                               options: [.atomic, .completeFileProtection])
            if let kept {
                note("Al posto del registro c'era un file non leggibile: è stato conservato come \(kept.lastPathComponent).")
            }
        } catch {
            noteError(error)
        }
    }

    /// Cartella dedicata, con protezione completa ed esclusa dalle copie di sicurezza.
    private func fileURL() throws -> URL {
        let manager = FileManager.default
        let base = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
        var folder = base.appendingPathComponent("Diagnostica", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder.appendingPathComponent("registro-diagnostico.json")
    }

    private func note(_ text: String) {
        if notices.last != text {
            notices.append(text)
        }
    }

    private func noteError(_ error: Error) {
        let failure = error as NSError
        note("Errore del registro: \(failure.domain) \(failure.code)")
    }

    private static func text(_ reason: QuarantineReason) -> String {
        switch reason {
        case .unreadable:
            return "contenuto illeggibile"
        case .unknownVersion(let version):
            return "versione di schema \(version) non riconosciuta"
        }
    }
}
