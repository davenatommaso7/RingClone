import Combine
import Foundation
import SwiftUI
import WatchConnectivity

// Stato del collegamento fra iPhone e Apple Watch (traguardo M1, voce UI-07).
// Nessun trasferimento di dati: l'app legge solo lo stato della sessione.

struct LinkRow: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
}

final class LinkMonitor: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var rows: [LinkRow] = [LinkRow(label: "Sessione", value: "non avviata")]

    func start() {
        guard WCSession.isSupported() else {
            rows = [LinkRow(label: "Sessione", value: "non disponibile su questo dispositivo")]
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private func publish(_ session: WCSession, error: Error?) {
        var list = [LinkRow(label: "Sessione", value: Self.text(session.activationState))]
        if session.activationState == .activated {
            list.append(LinkRow(label: "Altro dispositivo raggiungibile", value: Self.yesNo(session.isReachable)))
            #if os(watchOS)
            list.append(LinkRow(label: "App iPhone installata", value: Self.yesNo(session.isCompanionAppInstalled)))
            #else
            list.append(LinkRow(label: "Apple Watch abbinato", value: Self.yesNo(session.isPaired)))
            list.append(LinkRow(label: "App Watch installata", value: Self.yesNo(session.isWatchAppInstalled)))
            #endif
        }
        if let failure = error as NSError? {
            list.append(LinkRow(label: "Errore", value: "\(failure.domain) \(failure.code)"))
        }
        let result = list
        DispatchQueue.main.async { self.rows = result }
    }

    private static func yesNo(_ value: Bool) -> String { value ? "sì" : "no" }

    private static func text(_ state: WCSessionActivationState) -> String {
        switch state {
        case .activated: return "attiva"
        case .inactive: return "inattiva"
        case .notActivated: return "non attivata"
        @unknown default: return "stato sconosciuto"
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        publish(session, error: error)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        publish(session, error: nil)
    }

    #if os(watchOS)
    func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        publish(session, error: nil)
    }
    #else
    func sessionDidBecomeInactive(_ session: WCSession) {
        publish(session, error: nil)
    }

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        publish(session, error: nil)
    }
    #endif
}

struct LinkStatusView: View {
    @ObservedObject var link: LinkMonitor
    let note: String

    var body: some View {
        List {
            Section(header: Text("Collegamento")) {
                ForEach(link.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label).font(.caption).foregroundStyle(.secondary)
                        Text(row.value)
                    }
                }
            }
            Section {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
