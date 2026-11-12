import SwiftUI
import Charts
import RingCore

// MARK: - Schermata principale

struct DashboardView: View {
    @EnvironmentObject private var store: Store
    @State private var selected: Date?
    @State private var showProfile = false

    private var report: DailyReport? {
        if let s = selected, let r = store.reports.first(where: { $0.date == s }) { return r }
        return store.reports.last
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let m = store.message { Notice(text: m, symbol: "info.circle") }
                    if let r = report {
                        DayPicker(reports: store.reports, current: r, calendar: store.calendar, selected: $selected)
                        if r.calibrating {
                            Notice(text: "Calibrazione: \(r.baselineNights) notti su 7. Finché la baseline personale non è pronta, i confronti con i tuoi valori abituali sono neutri.", symbol: "hourglass")
                        }
                        ScoresCard(report: r)
                        if !r.flags.isEmpty { FlagsCard(flags: r.flags) }
                        SleepCard(report: r)
                        HeartCard(report: r)
                        StressCard(report: r)
                        ActivityCard(report: r, calendar: store.calendar)
                        CircadianCard(report: r)
                        FitnessCard(report: r)
                        TrendCard(reports: store.reports)
                    } else if !store.busy {
                        EmptyState()
                    }
                    Text("Stime a scopo informativo e di benessere. Non è un dispositivo medico e non sostituisce il parere di un medico.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("Ring")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.busy { ProgressView() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showProfile = true } label: { Image(systemName: "person.crop.circle") }
                        .accessibilityLabel("Profilo")
                }
            }
            .refreshable { await store.refresh() }
            .sheet(isPresented: $showProfile) { ProfileView(profile: store.profile).environmentObject(store) }
            .onAppear { if !store.hasProfile { showProfile = true } }
        }
    }
}

// MARK: - Elementi comuni

private struct Card<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct Row: View {
    let name: String
    let value: String
    var body: some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }
}

private struct Notice: View {
    let text: String
    let symbol: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct Score: View {
    let name: String
    let value: Double
    let tint: Color
    var body: some View {
        VStack(spacing: 4) {
            Gauge(value: min(max(value, 0), 100), in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                Text("\(Int(value.rounded()))")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(tint)
            Text(name).font(.caption).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(Int(value.rounded())) su 100")
    }
}

/// Scomposizione di un punteggio nei suoi contributi
private struct Parts: View {
    let title: String
    let parts: [String: Double]
    let format: (Double) -> String

    var body: some View {
        DisclosureGroup(title) {
            ForEach(Presentation.parts(parts)) { p in
                Row(name: p.name, value: format(p.value))
            }
        }
        .font(.subheadline)
    }
}

/// Elenco di righe preparate (e testate) in RingCore
private struct Lines: View {
    let lines: [Presentation.Line]
    var body: some View {
        ForEach(lines) { l in
            Row(name: l.name, value: l.value)
        }
    }
}

private func stageColor(_ s: SleepStage) -> Color {
    switch s {
    case .wake: return .orange
    case .light: return .cyan
    case .deep: return .indigo
    case .rem: return .purple
    }
}

private struct EmptyState: View {
    @EnvironmentObject private var store: Store
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "applewatch").font(.largeTitle)
            Text("Ancora nessun report").font(.headline)
            Text("Indossa l'Apple Watch di giorno e di notte. In alternativa puoi vedere l'app con dati sintetici.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Modalità dimostrativa") { Task { await store.loadDemo() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 40)
    }
}

// MARK: - Scelta del giorno

private struct DayPicker: View {
    let reports: [DailyReport]
    let current: DailyReport
    let calendar: Calendar
    @Binding var selected: Date?

    private var index: Int { reports.firstIndex { $0.date == current.date } ?? 0 }

    private var title: String {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "it_IT"); f.dateFormat = "EEEE d MMMM"
        return f.string(from: current.date).capitalized
    }

    var body: some View {
        HStack {
            Button { selected = reports[index - 1].date } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0)
                .accessibilityLabel("Giorno precedente")
            Spacer()
            Text(title).font(.headline)
            Spacer()
            Button { selected = reports[index + 1].date } label: { Image(systemName: "chevron.right") }
                .disabled(index >= reports.count - 1)
                .accessibilityLabel("Giorno successivo")
        }
    }
}

// MARK: - Punteggi

private struct ScoresCard: View {
    let report: DailyReport
    var body: some View {
        Card(title: "Punteggi", symbol: "circle.hexagongrid") {
            HStack(alignment: .top) {
                if let n = report.night { Score(name: "Sleep Index", value: n.sleepIndex, tint: .indigo) }
                Score(name: "Recupero", value: report.recovery, tint: .green)
                Score(name: "Movement Index", value: report.movementIndex, tint: .orange)
                Score(name: "Allineamento circadiano", value: report.circadianAlignment, tint: .teal)
            }
            Row(name: "Recupero", value: report.recoveryLabel)
            if let n = report.night { Row(name: "Sonno", value: SleepMetrics.label(n.sleepIndex)) }
            Parts(title: "Contributi al recupero (scarti dalla tua norma)", parts: report.recoveryParts) {
                Presentation.number($0, digits: 1, signed: true)
            }
        }
    }
}

private struct FlagsCard: View {
    let flags: [String]
    var body: some View {
        Card(title: "Da tenere d'occhio", symbol: "exclamationmark.triangle") {
            ForEach(flags, id: \.self) { f in
                Text(f).font(.subheadline)
            }
        }
    }
}

// MARK: - Sonno

private struct SleepCard: View {
    let report: DailyReport

    var body: some View {
        Card(title: "Sonno", symbol: "bed.double") {
            if let n = report.night {
                Hypnogram(night: n)
            } else {
                Text("Notte non registrata.").font(.subheadline).foregroundStyle(.secondary)
            }
            Lines(lines: Presentation.sleepLines(report))
            if let n = report.night {
                Parts(title: "Contributi allo Sleep Index", parts: n.sleepIndexParts) { Presentation.number($0 * 100, unit: "%") }
            }
        }
    }
}

private struct Hypnogram: View {
    let night: NightReport
    private let order = [SleepStage.wake, .rem, .light, .deep].map { Presentation.stageName($0) }

    var body: some View {
        Chart(Presentation.hypnogram(night)) { run in
            RectangleMark(xStart: .value("Inizio", run.startMin / 60),
                          xEnd: .value("Fine", run.endMin / 60),
                          y: .value("Fase", Presentation.stageName(run.stage)))
                .foregroundStyle(stageColor(run.stage))
        }
        .chartYScale(domain: order)
        .chartXAxisLabel("ore da quando sei andato a letto")
        .frame(height: 140)
        .accessibilityLabel("Ipnogramma della notte")
    }
}

// MARK: - Cuore

private struct ZoneBar: Identifiable {
    let id: Int
    let name: String
    let minutes: Double
}

private struct HeartCard: View {
    let report: DailyReport

    private var zones: [ZoneBar] {
        report.zoneMinutesDay.enumerated().map { i, m in
            ZoneBar(id: i, name: i < Presentation.zoneNames.count ? Presentation.zoneNames[i] : "Z\(i + 1)", minutes: m)
        }
    }

    var body: some View {
        Card(title: "Cuore", symbol: "heart") {
            Lines(lines: Presentation.heartLines(report))
            Chart(zones) { z in
                BarMark(x: .value("Minuti", z.minutes), y: .value("Zona", z.name))
                    .annotation(position: .trailing) {
                        Text(Presentation.number(z.minutes, unit: "min")).font(.caption2)
                    }
            }
            .chartXAxisLabel("minuti di oggi in ogni zona")
            .frame(height: 170)
            ForEach(zones) { z in
                Row(name: z.name, value: Presentation.zoneRange(report, z.id))
            }
        }
    }
}

// MARK: - Stress

private struct StressCard: View {
    let report: DailyReport
    var body: some View {
        Card(title: "Stress fisiologico", symbol: "waveform.path.ecg") {
            if report.stressAvg != nil {
                Lines(lines: Presentation.stressLines(report))
                Chart(Presentation.stressPoints(report.stressTimeline)) { p in
                    BarMark(x: .value("Ora", p.hour), y: .value("Stress", p.value), width: .fixed(2))
                        .foregroundStyle(p.value >= 60 ? Color.red : Color.green)
                }
                .chartXScale(domain: 0...24)
                .chartYScale(domain: 0...100)
                .chartXAxisLabel("ora del giorno")
                .frame(height: 140)
                Text("Valutato solo da svegli e da fermi: durante il movimento la frequenza cardiaca sale per lo sforzo, non per lo stress.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Dati insufficienti per oggi.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Attività

private struct ActivityCard: View {
    let report: DailyReport
    let calendar: Calendar

    var body: some View {
        Card(title: "Attività", symbol: "figure.walk") {
            Lines(lines: Presentation.activityLines(report))
            ForEach(Array(report.workouts.enumerated()), id: \.offset) { _, w in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Presentation.workoutTitle(w, calendar: calendar)).font(.subheadline.weight(.semibold))
                    Text(Presentation.workoutDetail(w)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Parts(title: "Contributi al Movement Index", parts: report.movementParts) { Presentation.number($0 * 100, unit: "%") }
        }
    }
}

// MARK: - Ritmo circadiano

private struct CircadianCard: View {
    let report: DailyReport
    var body: some View {
        Card(title: "Ritmo circadiano", symbol: "sun.max") {
            Lines(lines: Presentation.circadianLines(report))
            ForEach(Array(report.windows.enumerated()), id: \.offset) { _, w in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(w.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(w.label).font(.subheadline).monospacedDigit()
                    }
                    Text(w.hint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Fitness

private struct FitnessCard: View {
    let report: DailyReport
    var body: some View {
        Card(title: "Fitness", symbol: "lungs") {
            Lines(lines: Presentation.fitnessLines(report))
        }
    }
}

// MARK: - Andamento

private struct TrendPoint: Identifiable {
    let id: String
    let date: Date
    let series: String
    let value: Double
}

private struct TrendCard: View {
    let reports: [DailyReport]

    private var points: [TrendPoint] {
        reports.suffix(14).flatMap { r -> [TrendPoint] in
            var p = [TrendPoint(id: "r\(r.date.timeIntervalSince1970)", date: r.date, series: "Recupero", value: r.recovery)]
            if let n = r.night {
                p.append(TrendPoint(id: "s\(r.date.timeIntervalSince1970)", date: r.date, series: "Sleep Index", value: n.sleepIndex))
            }
            return p
        }
    }

    var body: some View {
        Card(title: "Ultime due settimane", symbol: "chart.xyaxis.line") {
            Chart(points) { p in
                LineMark(x: .value("Giorno", p.date), y: .value("Punteggio", p.value))
                    .foregroundStyle(by: .value("Serie", p.series))
                PointMark(x: .value("Giorno", p.date), y: .value("Punteggio", p.value))
                    .foregroundStyle(by: .value("Serie", p.series))
            }
            .chartYScale(domain: 0...100)
            .frame(height: 170)
        }
    }
}

// MARK: - Profilo

struct ProfileView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: UserProfile

    init(profile: UserProfile) { _draft = State(initialValue: profile) }

    private struct Weekday: Identifiable {
        let id: Int                                                  // Calendar.weekday: 1 = domenica
        let name: String
    }
    private let weekdays = [Weekday(id: 2, name: "Lun"), Weekday(id: 3, name: "Mar"), Weekday(id: 4, name: "Mer"),
                            Weekday(id: 5, name: "Gio"), Weekday(id: 6, name: "Ven"), Weekday(id: 7, name: "Sab"),
                            Weekday(id: 1, name: "Dom")]

    var body: some View {
        NavigationStack {
            Form {
                Section("Dati personali") {
                    Stepper("Età: \(Int(draft.age)) anni", value: $draft.age, in: 14...95, step: 1)
                    Picker("Sesso", selection: $draft.sex) {
                        Text("Uomo").tag(Sex.male)
                        Text("Donna").tag(Sex.female)
                    }
                    Stepper("Statura: \(Int(draft.heightCm)) cm", value: $draft.heightCm, in: 130...220, step: 1)
                    Stepper("Peso: \(Int(draft.weightKg)) kg", value: $draft.weightKg, in: 35...200, step: 1)
                }
                Section("Obiettivi") {
                    Stepper("Fabbisogno di sonno: \(Presentation.duration(draft.sleepNeedH * 60))", value: $draft.sleepNeedH, in: 6...10, step: 0.25)
                    Stepper("Passi al giorno: \(Int(draft.stepGoal))", value: $draft.stepGoal, in: 3000...25000, step: 500)
                }
                Section("Giorni lavorativi (per il Social Jetlag)") {
                    ForEach(weekdays) { day in
                        Toggle(day.name, isOn: Binding(
                            get: { draft.workdays.contains(day.id) },
                            set: { on in
                                if on { draft.workdays.insert(day.id) } else { draft.workdays.remove(day.id) }
                            }))
                    }
                }
                Section("Zone di frequenza cardiaca") {
                    Picker("Modello", selection: $draft.zoneModel) {
                        Text("% della FC massima").tag(ZoneModel.percentMax)
                        Text("Riserva cardiaca (Karvonen)").tag(ZoneModel.karvonen)
                    }
                    TextField("FC massima misurata (facoltativa)", value: $draft.hrMaxOverride, format: .number)
                        .keyboardType(.decimalPad)
                    TextField("VO₂ max di laboratorio (facoltativo)", value: $draft.labVO2max, format: .number)
                        .keyboardType(.decimalPad)
                }
                Section {
                    if store.demo {
                        Button("Esci dalla modalità dimostrativa") {
                            Task { await store.exitDemo() }
                            dismiss()
                        }
                    } else {
                        Button("Modalità dimostrativa") {
                            Task { await store.loadDemo() }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Profilo")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        let p = draft
                        Task { await store.update(profile: p) }
                        dismiss()
                    }
                }
            }
        }
    }
}
