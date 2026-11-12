import SwiftUI

// Guscio dell'app Watch di M1: dimostra che l'app incorporata si installa e mostra lo stato del collegamento.
// Nessun sensore, nessuna sessione di allenamento, nessuna registrazione del movimento.

@main
struct RingCloneM1WatchApp: App {
    @StateObject private var link = LinkMonitor()

    var body: some Scene {
        WindowGroup {
            LinkStatusView(
                link: link,
                note: "RingClone M1. Su Apple Watch questa app mostra solo lo stato del collegamento con l'iPhone: non legge sensori e non registra dati.")
                .onAppear { link.start() }
        }
    }
}
