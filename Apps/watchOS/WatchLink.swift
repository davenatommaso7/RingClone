import Foundation
import CryptoKit
import WatchConnectivity
import RingCore

/// Collegamento con l'iPhone: spedisce i pacchetti di movimento e riceve le zone personali.
/// I pacchetti restano in una cartella finché l'iPhone non ne conferma la ricezione: nessuna epoca va persa
/// se il telefono è lontano o spento.
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchLink()

    private let lock = NSLock()
    private let pending: MotionOutbox
    private var inFlight = Set<String>()
    /// chiamata sulla coda principale quando arrivano nuove impostazioni dall'iPhone
    var onSettings: ((WatchSettings) -> Void)?

    private static let settingsKey = "watchSettings"

    private override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        pending = MotionOutbox(directory: base.appendingPathComponent("pending", isDirectory: true))
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
    @discardableResult func enqueue(_ epochs: [MotionEpoch]) -> Bool {
        guard !epochs.isEmpty else { return false }
        let file: URL
        do { file = try pending.enqueue(epochs) } catch { return false }
        transfer([file])
        return true
    }

    /// Spedisce i pacchetti ancora in attesa (transferFile continua anche ad app sospesa)
    func flush() {
        transfer((try? pending.packets()) ?? [])
    }

    private func transfer(_ files: [URL]) {
        guard WCSession.isSupported(), !files.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let queued = Set(session.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent })
        for f in files {
            let name = f.lastPathComponent
            guard !queued.contains(name), !inFlight.contains(name), let data = try? Data(contentsOf: f) else { continue }
            inFlight.insert(name)
            let digest = Data(SHA256.hash(data: data))
            session.transferFile(f, metadata: ["kind": "motion", "motionPacket": name, "motionSHA256": digest])
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

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let name = userInfo["motionArchiveAck"] as? String, let digest = userInfo["motionSHA256"] as? Data else { return }
        lock.lock(); defer { lock.unlock() }
        try? pending.acknowledge(name) { Data(SHA256.hash(data: $0)) == digest }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        lock.lock(); inFlight.remove(url.lastPathComponent); lock.unlock()
        // La consegna del file libera il tentativo. Il file resta in coda fino all'ACK dell'archivio.
    }
}
