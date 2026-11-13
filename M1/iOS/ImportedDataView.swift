import RingCore
import SwiftUI

// Schermata dei dati importati di M1 (voci UI-01, UI-05, UI-06).
// Mostra solo valori importati da Salute, ciascuno con stato e provenienza.
// Non usa l'elaborazione giornaliera, la presentazione ne' l'archivio della BL-0.

@MainActor
final class ImportModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        case needsPermission
        case reading
        case done
        case unavailable
        case permissionError(String)
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var result: ImportResult?

    private let importer = HealthImporter()

    func open() async {
        guard HealthImporter.isAvailable else {
            phase = .unavailable
            return
        }
        if await importer.needsAuthorizationRequest() {
            phase = .needsPermission
        } else {
            await read()
        }
    }

    func requestPermissionAndRead() async {
        do {
            try await importer.requestAuthorization()
        } catch {
            let failure = error as NSError
            phase = .permissionError("\(failure.domain) \(failure.code)")
            return
        }
        await read()
    }

    func read() async {
        phase = .reading
        result = await importer.read()
        phase = .done
    }
}

enum ImportText {
    static func state(_ state: ImportState) -> String {
        switch state {
        case .present:
            return "Presente"
        case .noSamplesOrAccessUndeterminable:
            return "Nessun campione nell'intervallo. L'app non può sapere se la lettura è stata negata."
        case .error(let domain, let code):
            return "Errore di lettura: \(domain) \(code)"
        }
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    static func interval(_ interval: ImportInterval) -> String {
        "\(date(interval.start)) - \(date(interval.end))"
    }

    static func coverage(_ coverage: Coverage) -> String {
        switch coverage {
        case .notApplicable:
            return "non applicabile"
        case .fraction(let fraction):
            return ImportedFormat.number(fraction * 100) + " %"
        }
    }
}

struct ValueLine: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

struct ProvenanceRows: View {
    let provenance: Provenance

    var body: some View {
        ValueLine(label: "Stato", value: ImportText.state(provenance.state))
        if provenance.state == .present {
            ValueLine(label: "Numero di campioni", value: "\(provenance.sampleCount)")
            if let observed = provenance.observed {
                ValueLine(label: "Primo e ultimo campione", value: ImportText.interval(observed))
            }
            ValueLine(label: "Sorgenti", value: provenance.sources.joined(separator: ", "))
            ValueLine(label: "Copertura dell'intervallo richiesto", value: ImportText.coverage(provenance.coverage))
        }
        ValueLine(label: "Intervallo richiesto (\(provenance.timeZoneIdentifier))",
                  value: ImportText.interval(provenance.requested))
        ValueLine(label: "Origine e momento della lettura",
                  value: "Importato da Salute, \(ImportText.date(provenance.readAt))")
    }
}

struct SeriesRows: View {
    let item: ImportedItem

    var body: some View {
        ProvenanceRows(provenance: item.summary.provenance)
        if item.summary.provenance.state == .present {
            if item.showsRange {
                ValueLine(label: "Minimo e massimo (\(item.summary.provenance.unit))",
                          value: "\(ImportedFormat.number(item.summary.minimum, decimals: item.decimals)) - \(ImportedFormat.number(item.summary.maximum, decimals: item.decimals))")
            }
            if let note = item.admissibleNote {
                ValueLine(label: note, value: "\(item.summary.provenance.outOfRangeCount)")
            }
            if item.showsTotals {
                ForEach(item.summary.perSourceSum.keys.sorted(), id: \.self) { source in
                    ValueLine(label: "Totale della sorgente \(source) (\(item.summary.provenance.unit))",
                              value: ImportedFormat.number(item.summary.perSourceSum[source], decimals: item.decimals))
                }
                ValueLine(label: "Totale secondo la statistica di Salute (\(item.summary.provenance.unit))",
                          value: item.statisticNote
                              ?? ImportedFormat.number(item.summary.healthStatisticTotal, decimals: item.decimals))
            }
            if item.summary.duplicateUUIDCount > 0 {
                ValueLine(label: "Campioni con identificativo ripetuto", value: "\(item.summary.duplicateUUIDCount)")
            }
            ForEach(item.details.indices, id: \.self) { index in
                ValueLine(label: item.details[index].label, value: item.details[index].value)
            }
        }
    }
}

struct SleepRows: View {
    let series: ImportedSleepSeries

    var body: some View {
        ProvenanceRows(provenance: series.provenance)
        if series.unknownCategoryCount > 0 {
            ValueLine(label: "Campioni con categoria non nota", value: "\(series.unknownCategoryCount)")
        }
        ForEach(series.samples.indices, id: \.self) { index in
            ValueLine(label: SleepRows.title(series.samples[index]),
                      value: ImportText.interval(ImportInterval(start: series.samples[index].start,
                                                                end: series.samples[index].end)))
        }
    }

    static func title(_ sample: ImportedSleepSample) -> String {
        let name = sample.category?.nativeName ?? "Categoria non nota (valore \(sample.categoryRawValue))"
        return "\(name), \(sample.source)"
    }
}

struct ImportedDataView: View {
    @StateObject private var model = ImportModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Dati importati")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Rileggi") {
                            Task { await model.read() }
                        }
                        .disabled(model.phase != .done)
                    }
                }
        }
        .task { await model.open() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active, model.phase == .done {
                Task { await model.read() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .starting, .reading:
            ProgressView("Lettura da Salute")
        case .unavailable:
            Text("Salute non è disponibile su questo dispositivo.").padding()
        case .needsPermission:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("RingClone legge da Salute questi tipi di dati: frequenza cardiaca e frequenza a riposo, variabilità SDNN e RMSSD, serie battito-battito, passi, sonno, frequenza respiratoria, saturazione di ossigeno, temperatura al polso nel sonno, energia attiva e basale, VO2 max, tempo alla luce diurna e allenamenti.")
                    Text("Li mostra così come sono, con la loro provenienza. Non conserva copie dei valori e non scrive in Salute.")
                    Text("Nel prossimo passaggio iOS ti chiede quali tipi consentire: puoi scegliere tipo per tipo.")
                    Button("Continua") {
                        Task { await model.requestPermissionAndRead() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        case .permissionError(let text):
            VStack(alignment: .leading, spacing: 16) {
                Text("Errore nella richiesta dei permessi: \(text)")
                Button("Riprova") {
                    Task { await model.requestPermissionAndRead() }
                }
            }
            .padding()
        case .done:
            if let result = model.result {
                List {
                    ForEach(result.sections) { section in
                        Section(header: Text(section.title)) {
                            switch section {
                            case .series(let item):
                                SeriesRows(item: item)
                            case .sleep(let series):
                                SleepRows(series: series)
                            }
                        }
                    }
                    Section {
                        Text("Valori importati da Salute, mostrati senza elaborazioni. Questa app non è un dispositivo medico.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Nessuna lettura disponibile.").padding()
            }
        }
    }
}
