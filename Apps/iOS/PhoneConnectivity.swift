import Foundation
import WatchConnectivity
import RingCore

/// Collegamento con l'Apple Watch: riceve i pacchetti di movimento e manda al polso le zone personali.
final class PhoneConnectivity: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let archive: MotionArchive
    private let lock = NSLock()
    private var pendingSettings: WatchSettings?
    /// chiamata (su una coda di sistema) quando sono arrivate nuove epoche di movimento
    var onMotion: (@Sendable () -> Void)?

    init(archive: MotionArchive) {
        self.archive = archive
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// L'application context conserva solo l'ultimo valore e lo consegna appena il Watch è raggiungibile
    func send(_ settings: WatchSettings) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            lock.lock(); pendingSettings = settings; lock.unlock()
            return
        }
        guard session.isPaired, session.isWatchAppInstalled, let data = try? JSONEncoder().encode(settings) else { return }
        try? session.updateApplicationContext(["settings": data])
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        lock.lock(); let p = pendingSettings; pendingSettings = nil; lock.unlock()
        if activationState == .activated, let p { send(p) }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()                                 // cambio di Watch: si riattiva la sessione
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // il file viene cancellato dal sistema al ritorno da questo metodo: va letto subito
        guard let data = try? Data(contentsOf: file.fileURL), let chunk = try? MotionChunk.decode(data) else { return }
        archive.merge(chunk.epochs)                                  // idempotente: i reinvii non duplicano nulla
        onMotion?()
    }
}
