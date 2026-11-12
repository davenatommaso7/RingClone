import Foundation

public enum Fitness {
    public struct Estimate: Sendable, Equatable {
        public var name: String
        /// VO2max in ml/kg/min
        public var value: Double
        /// errore standard della stima (ml/kg/min)
        public var see: Double
    }

    public enum PAFrequency: Sendable, CaseIterable {
        case never, lessThanWeekly, weekly, twoOrThreeWeekly, almostDaily
    }

    public enum PAIntensity: Double, Sendable, CaseIterable {
        case light = 1, moderate = 2, vigorous = 3
    }

    public enum PADuration: Double, Sendable, CaseIterable {
        case under15Minutes = 0.1, from15To29Minutes = 0.38
        case from30To60Minutes = 0.75, over60Minutes = 1
    }

    /// Due codifiche pubblicate per la risposta "meno di una volta a settimana".
    public enum PALessThanWeeklyPolicy: Double, Sendable, CaseIterable {
        case zero = 0, half = 0.5
    }

    /// PA-index da questionario: frequenza x intensità x durata, scala 0-15.
    /// Il default .zero adotta il protocollo HUNT 2012: https://pmc.ncbi.nlm.nih.gov/articles/PMC3445602/
    /// La variante .half è esplicita: https://pmc.ncbi.nlm.nih.gov/articles/PMC3524509/
    /// Questa scelta non certifica la codifica del full text Nes 2011, qui non verificato.
    public static func paIndex(frequency: PAFrequency, intensity: PAIntensity, duration: PADuration,
                               lessThanWeeklyPolicy: PALessThanWeeklyPolicy = .zero) -> Double {
        let f: Double
        switch frequency {
        case .never: f = 0
        case .lessThanWeekly: f = lessThanWeeklyPolicy.rawValue
        case .weekly: f = 1
        case .twoOrThreeWeekly: f = 2.5
        case .almostDaily: f = 5
        }
        return f * intensity.rawValue * duration.rawValue
    }

    /// PROXY euristico del questionario dagli allenamenti, non un input HUNT direttamente misurato.
    /// Conserva gli allenamenti di almeno 10 min; la frequenza settimanale e le soglie FCmax
    /// 0,64/0,85 sono una nostra mappatura ai codici del questionario, non soglie validate HUNT.
    /// La categoria rara usa esplicitamente la policy .zero del protocollo HUNT 2012.
    public static func paIndex(workouts: [WorkoutRecord], days: Double = 28, hrMax: Double) -> Double {
        guard days.isFinite, days > 0, hrMax.isFinite, hrMax > 0 else { return 0 }
        let w = workouts.filter { $0.minutes >= 10 }
        guard !w.isEmpty else { return 0 }
        let perWeek = Double(w.count) / (days / 7)
        let frequency: PAFrequency = perWeek < 1 ? .lessThanWeekly : perWeek < 2 ? .weekly
            : perWeek < 4 ? .twoOrThreeWeekly : .almostDaily
        let rel = Stats.median(w.map { $0.avgHR / hrMax })
        let intensity: PAIntensity = rel < 0.64 ? .light : rel < 0.85 ? .moderate : .vigorous
        let minutes = Stats.median(w.map { $0.minutes })
        let duration: PADuration = minutes < 15 ? .under15Minutes : minutes < 30 ? .from15To29Minutes
            : minutes <= 60 ? .from30To60Minutes : .over60Minutes
        return paIndex(frequency: frequency, intensity: intensity, duration: duration, lessThanWeeklyPolicy: .zero)
    }

    /// Modello senza esercizio di Nes et al. 2011, versione con indice di massa corporea.
    /// L'abstract riporta 4637 partecipanti iniziali: https://pubmed.ncbi.nlm.nih.gov/21502897/
    public static func nes(profile p: UserProfile, rhr: Double, paIndex: Double) -> Estimate {
        p.sex == .male
            ? Estimate(name: "Nes", value: 92.05 - 0.327 * p.age - 0.933 * p.bmi - 0.167 * rhr + 0.257 * paIndex, see: 5.8)
            : Estimate(name: "Nes", value: 70.77 - 0.244 * p.age - 0.749 * p.bmi - 0.107 * rhr + 0.213 * paIndex, see: 5.1)
    }

    /// Uth et al. 2004: VO2max ≈ 15,3 x FCmax / FC a riposo. Ha senso solo con FC massima misurata.
    public static func uth(hrMax: Double, rhr: Double) -> Estimate {
        Estimate(name: "Uth", value: 15.3 * hrMax / rhr, see: 7.0)
    }

    /// Fusione a varianza inversa delle stime disponibili (chi è più preciso pesa di più).
    /// Nota: Nes e Uth condividono la FC a riposo, quindi non sono del tutto indipendenti.
    public static func fuse(_ e: [Estimate]) -> (value: Double, see: Double, source: String)? {
        let v = e.filter { $0.value.isFinite && $0.value > 10 && $0.value < 95 && $0.see > 0 }
        guard !v.isEmpty else { return nil }
        var num = 0.0, den = 0.0
        for x in v { num += x.value / (x.see * x.see); den += 1 / (x.see * x.see) }
        return (num / den, (1 / den).squareRoot(), v.map { $0.name }.joined(separator: " + "))
    }

    public static func vo2max(profile p: UserProfile, rhr: Double, hrMax: Double, hrMaxMeasured: Bool, paIndex: Double,
                              appleVO2: Double?, appleAgeDays: Double?) -> (value: Double, see: Double, source: String) {
        var e = [nes(profile: p, rhr: rhr, paIndex: paIndex)]
        if hrMaxMeasured, rhr > 30 { e.append(uth(hrMax: hrMax, rhr: rhr)) }
        if let a = appleVO2, let d = appleAgeDays, d <= 60 { e.append(Estimate(name: "Apple", value: a, see: d <= 30 ? 3.5 : 5.0)) }
        if let l = p.labVO2max { e.append(Estimate(name: "Laboratorio", value: l, see: 2.0)) }
        return fuse(e) ?? (e[0].value, e[0].see, "Nes")
    }

    // Mediane di VO2max su tapis roulant per decennio (registro FRIEND, Kaminsky et al. 2015), età centrali 25...75
    static let ages: [Double] = [25, 35, 45, 55, 65, 75]
    static let male: [Double] = [48.0, 42.4, 37.8, 32.6, 28.2, 24.4]
    static let female: [Double] = [37.6, 30.2, 26.7, 23.4, 20.0, 18.3]

    /// VO2max mediano atteso a una certa età
    public static func expectedVO2(age: Double, sex: Sex) -> Double {
        let t = sex == .male ? male : female
        var k = 0
        while k < ages.count - 2 && age > ages[k + 1] { k += 1 }
        return t[k] + (t[k + 1] - t[k]) * (age - ages[k]) / (ages[k + 1] - ages[k])
    }

    /// Cardio Age: l'età a cui il VO2max stimato coincide con la mediana della popolazione dello stesso sesso
    /// (interpolazione lineare, estrapolata oltre gli estremi con la pendenza dell'ultimo tratto), limitata a 18-90.
    public static func cardioAge(vo2: Double, sex: Sex) -> Double {
        let t = sex == .male ? male : female
        var k = 0
        while k < ages.count - 2 && vo2 < t[k + 1] { k += 1 }
        let age = ages[k] + (vo2 - t[k]) * (ages[k + 1] - ages[k]) / (t[k + 1] - t[k])
        return Stats.clamp(age, 18, 90)
    }

    /// Lisciatura esponenziale: la Cardio Age si muove lentamente (85 % valore precedente, 15 % nuovo)
    public static func smooth(previous: Double?, raw: Double) -> Double {
        previous.map { 0.85 * $0 + 0.15 * raw } ?? raw
    }
}
