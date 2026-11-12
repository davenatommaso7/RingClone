import Foundation
import WatchConnectivity
import RingCore

/// Collegamento con l'iPhone: spedisce i pacchetti di movimento e riceve le zone personali.
/// I pacchetti restano in una cartella finché l'iPhone non ne conferma la ricezione: nessuna epoca va persa
/// se il telefono è lontano o spento.
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchLink()

    private let lock = NSLock()
    private let pending: URL
    private var inFlight = Set<String>()
    /// chiamata sulla coda principale quando arrivano nuove impostazioni dall'iPhone
    var onSettings: ((WatchSettings) -> Void)?

    private static let settingsKey = "watchSettings"

    private override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        pending = base.appendingPathComponent("pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Ultime impostazioni ricevute (salvate: valgono anche al riavvio e senza iPhone vicino)
    var settings: WatchSettings {
        if let d = UserDefaults.standard.data(forKey: Self.settingsKey), let s = try? JSONDecoder().decode(WatchSettings.self, from: d) {
            return s
        }
        return .fallback()
    }

    /// Mette in coda un pacchetto di epoche e prova a spedirlo
    func enqueue(_ epochs: [MotionEpoch]) {
        guard let first = epochs.first, let last = epochs.last, let data = try? MotionChunk(epochs: epochs).encoded() else { return }
        let url = pending.appendingPathComponent("motion-\(first.index)-\(last.index).json")
        try? data.write(to: url, options: .atomic)
        flush()
    }

    /// Spedisce i pacchetti ancora in attesa (transferFile continua anche ad app sospesa)
    func flush() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil)) ?? []
        lock.lock(); defer { lock.unlock() }
        for f in files where f.pathExtension == "json" && !inFlight.contains(f.lastPathComponent) {
            inFlight.insert(f.lastPathComponent)
            WCSession.default.transferFile(f, metadata: ["kind": "motion"])
        }
    }

    private func apply(_ context: [String: Any]) {
        guard let d = context["settings"] as? Data, let s = try? JSONDecoder().decode(WatchSettings.self, from: d) else { return }
        UserDefaults.standard.set(d, forKey: Self.settingsKey)
        DispatchQueue.main.async { self.onSettings?(s) }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        apply(session.receivedApplicationContext)
        flush()
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        lock.lock(); inFlight.remove(url.lastPathComponent); lock.unlock()
        // consegnato: si può cancellare. In caso di errore il file resta e verrà rispedito al prossimo flush
        if error == nil { try? FileManager.default.removeItem(at: url) }
    }
}
