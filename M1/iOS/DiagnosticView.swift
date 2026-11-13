import RingCore
import SwiftUI

// Schermata di diagnostica di M1 (voce ACQ-19).
// Mostra lo stato dell'ultima lettura per tipo e il registro diagnostico: mai valori sanitari.

struct DiagnosticView: View {
    @ObservedObject private var registry = DiagnosticRegistry.shared

    private var recent: [DiagnosticEntry] {
        Array(registry.log.entries.reversed().prefix(200))
    }

    var body: some View {
        NavigationStack {
            List {
                if !registry.notices.isEmpty {
                    Section(header: Text("Avvisi del registro")) {
                        ForEach(registry.notices.indices, id: \.self) { index in
                            Text(registry.notices[index])
                        }
                    }
                }
                Section(header: Text("Ultima lettura")) {
                    if registry.lastRead.isEmpty {
                        Text("Nessuna lettura da quando l'app è stata aperta.")
                    }
                    ForEach(registry.lastRead.indices, id: \.self) { index in
                        ValueLine(label: registry.lastRead[index].typeIdentifier,
                                  value: ImportText.state(registry.lastRead[index].state))
                    }
                }
                Section(header: Text("Registro: \(registry.log.entries.count) voci")) {
                    if recent.isEmpty {
                        Text("Il registro è vuoto.")
                    }
                    ForEach(recent.indices, id: \.self) { index in
                        ValueLine(label: ImportText.date(recent[index].at),
                                  value: DiagnosticView.text(recent[index]))
                    }
                }
                Section {
                    Text("Il registro annota, per ogni tipo di dato, solo i cambi di stato e i codici d'errore: non contiene valori né conteggi. Le voci sono conservate \(DiagnosticLog.defaultRetentionDays) giorni. Il file è protetto a dispositivo bloccato ed è escluso dalle copie di sicurezza.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Diagnostica")
        }
        .onAppear { registry.loadIfNeeded() }
    }

    static func text(_ entry: DiagnosticEntry) -> String {
        let type = entry.typeIdentifier ?? "registro"
        switch entry.event {
        case .readPresent:
            return "\(type): presente"
        case .readNoSamplesOrAccessUndeterminable:
            return "\(type): nessun campione o accesso non determinabile"
        case .readError:
            let domain = entry.errorDomain ?? "dominio non indicato"
            let code = entry.errorCode.map { String($0) } ?? "codice non indicato"
            return "\(type): errore \(domain) \(code)"
        case .fileQuarantined:
            return "File del registro non leggibile: conservato con un altro nome"
        }
    }
}
