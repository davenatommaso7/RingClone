import Foundation

/// Preparazione dei dati per l'interfaccia: testi e serie pronte da disegnare.
/// Sta nel Core (e non nelle viste) così è compilata e testata anche senza SwiftUI.
public enum Presentation {
    /// "7 h 05 min", "45 min"
    public static func duration(_ minutes: Double) -> String {
        let m = Int(max(minutes, 0).rounded())
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h " + (m % 60 < 10 ? "0" : "") + "\(m % 60) min"
    }

    /// "+1 h 24 min" / "−35 min" (per debito di sonno e social jetlag)
    public static func signedHours(_ h: Double) -> String {
        (h < 0 ? "−" : "+") + duration(abs(h) * 60)
    }

    public static func stageName(_ s: SleepStage) -> String {
        reportedStageName(ReportedSleepStage(s))
    }

    public static func reportedStageName(_ s: ReportedSleepStage) -> String {
        switch s {
        case .wake: return "Veglia"
        case .light: return "Leggero"
        case .deep: return "Profondo"
        case .rem: return "REM"
        case .asleepUnspecified: return "Sonno senza fase"
        case .unknown: return "Fase ignota"
        }
    }

    public static let zoneNames = ["Z1 recupero", "Z2 aerobica", "Z3 ritmo", "Z4 soglia", "Z5 massimale"]

    /// Tratto di ipnogramma: stadio costante da `startMin` a `endMin` (minuti da quando si è andati a letto)
    public struct StageRun: Sendable, Equatable, Identifiable {
        public var stage: ReportedSleepStage
        public var startMin: Double
        public var endMin: Double
        public var id: Double { startMin }
    }

    public static func hypnogram(_ night: NightReport) -> [StageRun] {
        var out: [StageRun] = []
        let k = RingConst.epoch / 60
        for (i, raw) in night.stages.enumerated() {
            let s = night.decodedStage(raw)
            if var last = out.last, last.stage == s {
                last.endMin = Double(i + 1) * k
                out[out.count - 1] = last
            } else {
                out.append(StageRun(stage: s, startMin: Double(i) * k, endMin: Double(i + 1) * k))
            }
        }
        return out
    }

    /// Punto al centro della finestra: ore trascorse e, se noto, istante reale con etichetta locale.
    public struct StressPoint: Sendable, Equatable, Identifiable {
        public var hour: Double
        public var value: Double
        public var timestamp: Date? = nil
        public var clockLabel: String? = nil
        public var id: Double { hour }
    }

    public static func stressPoints(_ timeline: [Double?]) -> [StressPoint] {
        guard !timeline.isEmpty else { return [] }
        let step = 24.0 / Double(timeline.count)
        return timeline.enumerated().compactMap { i, v in v.map { StressPoint(hour: (Double(i) + 0.5) * step, value: $0) } }
    }

    public static func stressAxis(_ report: DailyReport) -> StressDayAxis? {
        guard let axis = report.stressAxis, axis.start == report.date, axis.end > axis.start,
              TimeZone(identifier: axis.timeZoneIdentifier) != nil,
              Stress.windowCount(from: axis.start, to: axis.end) == report.stressTimeline.count else { return nil }
        return axis
    }

    public static func stressPoints(_ report: DailyReport) -> [StressPoint] {
        guard let axis = stressAxis(report) else { return stressPoints(report.stressTimeline) }
        return report.stressTimeline.enumerated().compactMap { i, value in
            guard let value else { return nil }
            let elapsed = (Double(i) + 0.5) * Stress.windowSeconds
            let instant = axis.start.addingTimeInterval(elapsed)
            return StressPoint(hour: elapsed / 3600, value: value, timestamp: instant,
                               clockLabel: stressClock(instant, axis: axis))
        }
    }

    public static func stressClock(_ instant: Date, axis: StressDayAxis) -> String {
        guard let zone = TimeZone(identifier: axis.timeZoneIdentifier) else { return "n.d." }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.hour, .minute], from: instant)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        let first = zone.secondsFromGMT(for: axis.start)
        let last = zone.secondsFromGMT(for: axis.end.addingTimeInterval(-1))
        guard first != last else { return time }
        let offset = zone.secondsFromGMT(for: instant)
        let sign = offset < 0 ? "−" : "+"
        return time + String(format: " UTC%@%02d:%02d", sign, abs(offset) / 3600, abs(offset) / 60 % 60)
    }

    public static func stressLabel(_ v: Double) -> String {
        v < 35 ? "rilassato" : v < 60 ? "normale" : v < 80 ? "elevato" : "alto"
    }

    /// Nome leggibile dei contributi di Sleep Index, Recovery e Movement Index
    public static func partName(_ key: String) -> String {
        let names = ["durata": "Durata", "tranquillita": "Tranquillità", "ristoratore": "Sonno ristoratore", "orario": "Orario",
                     "vitali": "Parametri vitali", "sonno": "Sonno", "fc_riposo": "FC a riposo", "hrv_form": "HRV Form",
                     "temperatura": "Temperatura cutanea", "stress_punti": "Stress Rhythm (punti)",
                     "passi": "Passi", "ore_attive": "Ore attive", "allenamenti": "Allenamenti"]
        return names[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Voce di una scomposizione (contributi di Sleep Index, Recovery, Movement Index)
    public struct Part: Sendable, Equatable, Identifiable {
        public var key: String
        public var value: Double
        public var id: String { key }
        public var name: String { Presentation.partName(key) }
    }

    /// Contributi ordinati per nome (ordine stabile da un giorno all'altro)
    public static func parts(_ p: [String: Double]) -> [Part] {
        p.sorted { $0.key < $1.key }.map { Part(key: $0.key, value: $0.value) }
    }

    // MARK: - Righe già pronte per le schede

    /// Riga "nome - valore" di una scheda
    public struct Line: Sendable, Equatable, Identifiable {
        public var name: String
        public var value: String
        public var id: String { name }
        public init(_ name: String, _ value: String) { self.name = name; self.value = value }
    }

    /// Numero con virgola decimale all'italiana; "n.d." se manca
    public static func number(_ v: Double?, digits: Int = 0, unit: String = "", signed: Bool = false) -> String {
        guard let v, v.isFinite else { return "n.d." }
        let p = pow(10, Double(digits))
        let r = (abs(v) * p).rounded() / p
        var t = String(Int(r))
        if digits > 0 {
            let frac = String(Int(((r - r.rounded(.down)) * p).rounded()))
            t += "," + String(repeating: "0", count: max(digits - frac.count, 0)) + frac
        }
        let sign = v < 0 && r > 0 ? "−" : (signed && r > 0 ? "+" : "")
        return sign + t + (unit.isEmpty ? "" : " " + unit)
    }

    public static func stateLabel(_ state: DailyMetricState) -> String {
        switch state {
        case .observed, .computed: return "Disponibile"
        case .estimated: return "Stima"
        case .unavailable: return "Non disponibile"
        case .insufficient: return "Dati insufficienti"
        case .calibrating: return "In calibrazione"
        case .stale: return "Dato non aggiornato"
        }
    }

    private static func display(_ state: DailyMetricState, value: @autoclosure () -> String) -> String {
        guard state.hasValue else { return stateLabel(state) }
        return state == .estimated ? value() + " (stima)" : value()
    }

    public static func sleepLines(_ r: DailyReport) -> [Line] {
        var out: [Line] = []
        if r.sectorFreshness?.nightPreserved == true {
            let timing = r.sectorFreshness?.nightAt.map { " Dati della lettura del " + reportTime($0, in: r) + "." } ?? ""
            out.append(Line("Aggiornamento del sonno", "Rilettura incompleta. La notte rimane quella già registrata." + timing))
        }
        if let n = r.night {
            let timing = n.bedTimingOrigin == .inBedObservation ? "" : " (stima)"
            out += [
                Line("Orari", "\(CircadianWindow.clock(n.onsetH)) – \(CircadianWindow.clock(n.wakeH))"),
                Line("Sonno totale", duration(n.tstMin)),
                Line("Tempo a letto", duration(n.tibMin) + timing),
                Line("Efficienza", number(n.efficiency, unit: "%")),
                Line("Leggero", duration(n.lightMin)),
                Line("Profondo", duration(n.deepMin)),
                Line("REM", duration(n.remMin)),
                Line("Sonno ristoratore", number(100 * n.restorativeShare, unit: "%")),
                Line("Addormentamento", duration(n.solMin) + timing),
                Line("Risvegli", "\(n.awakenings) (\(duration(n.wasoMin)))"),
                Line("Tratto continuo più lungo", duration(n.longestBoutMin)),
                Line("Cicli", "\(n.cycles)"),
            ]
            let onsetIndex = max(0, Int((n.solMin * 60 / RingConst.epoch).rounded()))
            let unspecified = n.stages.dropFirst(onsetIndex).filter { n.decodedStage($0) == .asleepUnspecified }.count
            if unspecified > 0 { out.append(Line("Sonno senza fase", duration(Double(unspecified) * RingConst.epoch / 60))) }
            if !timing.isEmpty { out.append(Line("Origine dell’efficienza", "Tempo a letto stimato dal periodo del sonno")) }
        }
        if r.napsMin > 0 { out.append(Line("Sonnellini", "\(r.naps.count) (\(duration(r.napsMin)))")) }
        out.append(Line("Debito di sonno", r.dailySleepMin == nil ? stateLabel(.insufficient) : duration(r.sleepDebtH * 60)))
        let sri = r.sriNeedsProvenance == true ? "Da verificare" : (r.sri == nil ? "servono più notti" : number(r.sri))
        out.append(Line("Regolarità (SRI)", sri))
        if let notice = regularityProvenanceNotice(r) { out.append(Line("Storico del sonno", notice)) }
        out.append(Line("Costanza degli orari", r.sleepConsistency == nil ? "servono più notti" : number(r.sleepConsistency)))
        return out
    }

    public static func heartLines(_ r: DailyReport) -> [Line] {
        var out = [Line("FC a riposo", display(r.state(\.rhr), value: number(r.rhr, unit: "bpm")))]
        if r.sectorFreshness?.nightPreserved == true, let date = r.sectorFreshness?.nightAt {
            out.append(Line("Dati notturni", "Lettura del " + reportTime(date, in: r)))
        }
        if r.sectorFreshness?.nightPreserved == true, let date = r.sectorFreshness?.daytimePulseAt {
            out.append(Line("FC diurna", "Lettura del " + reportTime(date, in: r)))
        }
        if let n = r.night {
            out += [
                Line("FC media nel sonno", number(n.avgHR, unit: "bpm")),
                Line("HRV (RMSSD)", number(n.rmssd, unit: "ms")),
                Line("HRV (SDNN)", number(n.sdnn, unit: "ms")),
                Line("Frequenza respiratoria", number(n.respRate, digits: 1, unit: "atti/min")),
                Line("Temperatura cutanea", n.skinTempDev == nil ? (n.skinTemp == nil ? stateLabel(.unavailable) : "in calibrazione") : number(n.skinTempDev, digits: 2, unit: "°C", signed: true)),
            ]
            if n.spo2 != nil { out.append(Line("SpO₂", number(n.spo2, unit: "%"))) }
        }
        out.append(Line("FC massima", number(r.hrMax, unit: "bpm") + (r.hrMaxMeasured ? " (misurata)" : " (stimata)")))
        return out
    }

    /// Intervallo in bpm della zona `i` (0 = Z1)
    public static func zoneRange(_ r: DailyReport, _ i: Int) -> String {
        guard r.zoneBounds.count == 6, i >= 0, i < 5 else { return "" }
        return "\(Int(r.zoneBounds[i].rounded()))–\(Int(r.zoneBounds[i + 1].rounded())) bpm"
    }

    public static func activityLines(_ r: DailyReport) -> [Line] {
        func energy(_ key: KeyPath<DailyEvidence, DailyMetricState>, amount: Double, at: Date?) -> String {
            let value = display(r.state(key), value: number(amount, unit: "kcal"))
            guard let at, let computedAt = r.computedAt, at < computedAt else { return value }
            return value + " · Lettura del " + reportTime(at, in: r)
        }
        return [
            Line("Passi", display(r.state(\.steps), value: number(r.steps))),
            Line("Ore attive", display(r.state(\.activity), value: "\(r.activeHours)")),
            Line("Minuti attivi", display(r.state(\.activity), value: duration(r.activeMinutes))),
            Line("Tempo inattivo", display(r.state(\.activity), value: duration(r.inactiveMin))),
            Line("Periodo sedentario più lungo", display(r.state(\.activity), value: duration(r.longestSedentaryMin))),
            Line("Calorie totali", energy(\.energyTotal, amount: r.kcalTotal, at: r.sectorFreshness?.totalEnergyAt)),
            Line("Calorie attive", energy(\.energyActive, amount: r.kcalActive, at: r.sectorFreshness?.activeEnergyAt)),
            Line("Carico di allenamento (TRIMP)", display(r.state(\.trimp), value: number(r.trimp))),
        ]
    }

    public static func workoutTitle(_ w: WorkoutRecord, calendar: Calendar) -> String {
        let name = w.activity.prefix(1).uppercased() + w.activity.dropFirst()
        return "\(name) · \(CircadianWindow.clock(Stats.hourOfDay(w.start, calendar))) · \(duration(w.minutes))"
    }

    public static func workoutDetail(_ w: WorkoutRecord) -> String {
        let energy = Energy.observedEnergy(w.importedKcal) ?? (w.kcal > 0 ? w.kcal : nil)
        return "FC media \(number(w.avgHR > 0 ? w.avgHR : nil)) · max \(number(w.maxHR > 0 ? w.maxHR : nil)) · \(number(energy, unit: "kcal"))"
            + (w.autoDetected ? " · rilevato automaticamente" : "")
    }

    public static func stressLines(_ r: DailyReport) -> [Line] {
        guard let avg = r.stressAvg, r.state(\.stress).hasValue else { return [] }
        return [Line("Media del giorno", "\(number(avg)) (\(stressLabel(avg)), stima)"),
                Line("Stress Rhythm", display(r.state(\.rhythm), value: number(r.stressRhythm)))]
    }

    public static func circadianLines(_ r: DailyReport) -> [Line] {
        let alignment = r.sriNeedsProvenance == true ? "Da verificare" : display(r.state(\.alignment), value: number(r.circadianAlignment))
        var out = [Line("Allineamento circadiano", alignment),
                   Line("Social Jetlag", r.socialJetlagH.map { duration(abs($0) * 60) } ?? "servono più notti")]
        if let c = r.chronotypeMSFsc { out.append(Line("Metà del sonno nei giorni liberi", CircadianWindow.clock(c))) }
        let state = r.state(\.tempMinimum)
        let name = state == .estimated ? "Minimo di temperatura (stima da orari)" : "Minimo di temperatura"
        out.append(Line(name, state.hasValue && r.tempMinH.isFinite ? CircadianWindow.clock(r.tempMinH) : stateLabel(state)))
        return out
    }

    public static func regularityProvenanceNotice(_ r: DailyReport) -> String? {
        guard r.sriNeedsProvenance == true else { return nil }
        return "Regolarità da verificare. Per correggere la sera nello storico serve una rilettura dei dati di sonno e veglia."
    }

    private static func reportTime(_ date: Date, in report: DailyReport) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        let zone = report.stressAxis.flatMap { TimeZone(identifier: $0.timeZoneIdentifier) }
        formatter.timeZone = zone ?? TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .short; formatter.timeStyle = .short
        return formatter.string(from: date) + (zone == nil ? " UTC" : "")
    }

    public static func fitnessLines(_ r: DailyReport) -> [Line] {
        let state = r.state(\.fitness)
        return [Line("VO₂ max", display(state, value: number(r.vo2max, digits: 1, unit: "ml/kg/min"))),
                Line("Origine della stima", state.hasValue ? r.vo2Source : stateLabel(state)),
                Line("Cardio Age", display(state.hasValue ? .estimated : state, value: number(r.cardioAge, unit: "anni")))]
    }
}

public extension WatchSettings {
    /// Zone personali da mostrare al polso, prese dall'ultimo report
    init(report r: DailyReport) {
        self.init(rhr: r.rhr, hrMax: r.hrMax, zoneBounds: r.zoneBounds)
    }
}

/// Scelta della sorgente del sonno quando in Apple Salute scrivono più app (i loro intervalli si sovrappongono
/// e non vanno sommati): prima l'Apple Watch, altrimenti la sorgente con più sonno registrato.
public enum SleepSources {
    public static func selectForReconciliation(_ byBundle: [String: [SleepSegment]])
        -> (selected: [SleepSegment], source: SleepSourceKey?) {
        let selected = pick(byBundle)
        let sleep = selected.filter { $0.reportedStage?.isSleep == true }
        guard let source = sleep.first?.source, sleep.allSatisfy({ $0.source == source }) else { return (selected, nil) }
        return (selected, source)
    }

    public static func pick(_ bySource: [String: [SleepSegment]], preferredPrefix: String = "com.apple.health") -> [SleepSegment] {
        func asleepMin(_ s: [SleepSegment]) -> Double {
            s.filter { $0.reportedStage?.isSleep == true }.map { $0.end.timeIntervalSince($0.start) / 60 }.reduce(0, +)
        }
        let staged = bySource.filter { asleepMin($0.value) > 0 }
        let preferred = staged.filter { $0.key.hasPrefix(preferredPrefix) }
        let pool = preferred.isEmpty ? staged : preferred
        // a parità di minuti decide il nome: la scelta non dipende dall'ordine del dizionario
        let best = pool.max { a, b in
            let ma = asleepMin(a.value), mb = asleepMin(b.value)
            return ma != mb ? ma < mb : a.key > b.key
        }
        return (best?.value ?? []).sorted { $0.start < $1.start }
    }
}
