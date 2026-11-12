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
        switch s {
        case .wake: return "Veglia"
        case .light: return "Leggero"
        case .deep: return "Profondo"
        case .rem: return "REM"
        }
    }

    public static let zoneNames = ["Z1 recupero", "Z2 aerobica", "Z3 ritmo", "Z4 soglia", "Z5 massimale"]

    /// Tratto di ipnogramma: stadio costante da `startMin` a `endMin` (minuti da quando si è andati a letto)
    public struct StageRun: Sendable, Equatable, Identifiable {
        public var stage: SleepStage
        public var startMin: Double
        public var endMin: Double
        public var id: Double { startMin }
    }

    public static func hypnogram(_ night: NightReport) -> [StageRun] {
        var out: [StageRun] = []
        let k = RingConst.epoch / 60
        for (i, raw) in night.stages.enumerated() {
            let s = SleepStage(rawValue: raw) ?? .wake
            if var last = out.last, last.stage == s {
                last.endMin = Double(i + 1) * k
                out[out.count - 1] = last
            } else {
                out.append(StageRun(stage: s, startMin: Double(i) * k, endMin: Double(i + 1) * k))
            }
        }
        return out
    }

    /// Punto della curva dello stress: ora locale decimale (centro della finestra di 5 min) e valore 0-100
    public struct StressPoint: Sendable, Equatable, Identifiable {
        public var hour: Double
        public var value: Double
        public var id: Double { hour }
    }

    public static func stressPoints(_ timeline: [Double?]) -> [StressPoint] {
        guard !timeline.isEmpty else { return [] }
        let step = 24.0 / Double(timeline.count)
        return timeline.enumerated().compactMap { i, v in v.map { StressPoint(hour: (Double(i) + 0.5) * step, value: $0) } }
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

    public static func sleepLines(_ r: DailyReport) -> [Line] {
        var out: [Line] = []
        if let n = r.night {
            out += [
                Line("Orari", "\(CircadianWindow.clock(n.onsetH)) – \(CircadianWindow.clock(n.wakeH))"),
                Line("Sonno totale", duration(n.tstMin)),
                Line("Tempo a letto", duration(n.tibMin)),
                Line("Efficienza", number(n.efficiency, unit: "%")),
                Line("Leggero", duration(n.lightMin)),
                Line("Profondo", duration(n.deepMin)),
                Line("REM", duration(n.remMin)),
                Line("Sonno ristoratore", number(100 * n.restorativeShare, unit: "%")),
                Line("Addormentamento", duration(n.solMin)),
                Line("Risvegli", "\(n.awakenings) (\(duration(n.wasoMin)))"),
                Line("Tratto continuo più lungo", duration(n.longestBoutMin)),
                Line("Cicli", "\(n.cycles)"),
            ]
        }
        if r.napsMin > 0 { out.append(Line("Sonnellini", "\(r.naps.count) (\(duration(r.napsMin)))")) }
        out.append(Line("Debito di sonno", duration(r.sleepDebtH * 60)))
        out.append(Line("Regolarità (SRI)", r.sri == nil ? "servono più notti" : number(r.sri)))
        out.append(Line("Costanza degli orari", r.sleepConsistency == nil ? "servono più notti" : number(r.sleepConsistency)))
        return out
    }

    public static func heartLines(_ r: DailyReport) -> [Line] {
        var out = [Line("FC a riposo", number(r.rhr, unit: "bpm"))]
        if let n = r.night {
            out += [
                Line("FC media nel sonno", number(n.avgHR, unit: "bpm")),
                Line("HRV (RMSSD)", number(n.rmssd, unit: "ms")),
                Line("HRV (SDNN)", number(n.sdnn, unit: "ms")),
                Line("Frequenza respiratoria", number(n.respRate, digits: 1, unit: "atti/min")),
                Line("Temperatura cutanea", n.skinTempDev == nil ? "in calibrazione" : number(n.skinTempDev, digits: 2, unit: "°C", signed: true)),
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
        [
            Line("Passi", number(r.steps)),
            Line("Ore attive", "\(r.activeHours)"),
            Line("Minuti attivi", duration(r.activeMinutes)),
            Line("Tempo inattivo", duration(r.inactiveMin)),
            Line("Periodo sedentario più lungo", duration(r.longestSedentaryMin)),
            Line("Calorie totali", number(r.kcalTotal, unit: "kcal")),
            Line("Calorie attive", number(r.kcalActive, unit: "kcal")),
            Line("Carico di allenamento (TRIMP)", number(r.trimp)),
        ]
    }

    public static func workoutTitle(_ w: WorkoutRecord, calendar: Calendar) -> String {
        let name = w.activity.prefix(1).uppercased() + w.activity.dropFirst()
        return "\(name) · \(CircadianWindow.clock(Stats.hourOfDay(w.start, calendar))) · \(duration(w.minutes))"
    }

    public static func workoutDetail(_ w: WorkoutRecord) -> String {
        "FC media \(number(w.avgHR)) · max \(number(w.maxHR)) · \(number(w.kcal, unit: "kcal"))"
            + (w.autoDetected ? " · rilevato automaticamente" : "")
    }

    public static func stressLines(_ r: DailyReport) -> [Line] {
        guard let avg = r.stressAvg else { return [] }
        return [Line("Media del giorno", "\(number(avg)) (\(stressLabel(avg)))"), Line("Stress Rhythm", number(r.stressRhythm))]
    }

    public static func circadianLines(_ r: DailyReport) -> [Line] {
        var out = [Line("Allineamento circadiano", number(r.circadianAlignment)),
                   Line("Social Jetlag", r.socialJetlagH.map { duration(abs($0) * 60) } ?? "servono più notti")]
        if let c = r.chronotypeMSFsc { out.append(Line("Metà del sonno nei giorni liberi", CircadianWindow.clock(c))) }
        out.append(Line("Minimo di temperatura", CircadianWindow.clock(r.tempMinH)))
        return out
    }

    public static func fitnessLines(_ r: DailyReport) -> [Line] {
        [Line("VO₂ max", number(r.vo2max, digits: 1, unit: "ml/kg/min")), Line("Origine della stima", r.vo2Source),
         Line("Cardio Age", number(r.cardioAge, unit: "anni"))]
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
    public static func pick(_ bySource: [String: [SleepSegment]], preferredPrefix: String = "com.apple.health") -> [SleepSegment] {
        func asleepMin(_ s: [SleepSegment]) -> Double {
            s.filter { $0.stage?.isSleep == true }.map { $0.end.timeIntervalSince($0.start) / 60 }.reduce(0, +)
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
