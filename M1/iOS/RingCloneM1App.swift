import RingCore
import SwiftUI

// App iPhone di M1, primo passo: contiene l'app Watch incorporata e mostra lo stato del collegamento.
// La lettura da Salute e la schermata dei dati importati arrivano con i pacchetti P03 e P04.

@main
struct RingCloneM1App: App {
    @StateObject private var link = LinkMonitor()

    var body: some Scene {
        WindowGroup {
            LinkStatusView(
                link: link,
                note: "RingClone M1, contratto di provenienza versione \(Provenance.currentContractVersion). In questa versione l'app non legge ancora Salute e non mostra dati.")
                .onAppear { link.start() }
        }
    }
}
