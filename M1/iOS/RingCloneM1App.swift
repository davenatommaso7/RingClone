import RingCore
import SwiftUI

// App iPhone di M1: schermata dei dati importati da Salute e stato del collegamento con l'Apple Watch.
// Contiene l'app Watch incorporata. Nessun trasferimento di dati fra i due dispositivi.

@main
struct RingCloneM1App: App {
    @StateObject private var link = LinkMonitor()

    var body: some Scene {
        WindowGroup {
            TabView {
                ImportedDataView()
                    .tabItem { Label("Dati importati", systemImage: "list.bullet.rectangle") }
                LinkStatusView(
                    link: link,
                    note: "RingClone M1, contratto di provenienza versione \(Provenance.currentContractVersion). Fra iPhone e Apple Watch non viene trasferito alcun dato: qui compare solo lo stato del collegamento.")
                    .tabItem { Label("Collegamento", systemImage: "applewatch") }
            }
            .onAppear { link.start() }
        }
    }
}
