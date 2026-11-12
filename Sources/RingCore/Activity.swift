import Foundation

public enum Activity {
    /// Contapassi dall'accelerometro (modulo in g): toglie la gravità (media mobile 1 s), liscia (0,1 s),
    /// cerca picchi sopra soglia adattiva distanti ≥ 0,3 s e conta solo sequenze regolari di almeno 6 passi
    /// (coefficiente di variazione dell'intervallo < 0,35), così i gesti isolati non diventano passi.
    /// Restituisce gli indici dei campioni in cui cade ogni passo.
    public static func detectSteps(mag: [Double], fs: Double) -> [Int] {
        guard mag.count > Int(4 * fs) else { return [] }
        let base = Stats.rollingMean(mag, half: Int(fs / 2))
        var hp = [Double](repeating: 0, count: mag.count)
        for i in mag.indices { hp[i] = mag[i] - base[i] }
        let lp = Stats.rollingMean(hp, half: max(Int(fs / 25), 1))
        let local = Stats.rollingMean(lp.map { $0 * $0 }, half: Int(fs)).map { $0.squareRoot() }
        let minGap = 0.3 * fs, maxGap = 2.0 * fs
        var peaks: [Int] = []
        for i in 1..<(lp.count - 1) where lp[i] > max(0.04, 0.6 * local[i]) && lp[i] >= lp[i - 1] && lp[i] > lp[i + 1] {
            if let l = peaks.last, Double(i - l) < minGap { if lp[i] > lp[l] { peaks[peaks.count - 1] = i }; continue }
            peaks.append(i)
        }
        var out: [Int] = [], seq: [Int] = []
        func flush() {
            if seq.count >= 6 {
                var d: [Double] = []
                for k in 1..<seq.count { d.append(Double(seq[k] - seq[k - 1])) }
                if Stats.sd(d) / Stats.mean(d) < 0.35 { out.append(contentsOf: seq) }
            }
            seq.removeAll(keepingCapacity: true)
        }
        for p in peaks {
            if let l = seq.last, Double(p - l) > maxGap { flush() }
            seq.append(p)
        }
        flush()
        return out
    }

    public struct DayActivity: Sendable {
        public var activeHours: Int
        public var activeMinutes: Double
        public var inactiveMin: Double
        public var longestSedentary: Double
    }

    /// Ore attive: ore di orologio (in veglia per almeno 30 min) con ≥ 250 passi oppure ≥ 5 min a intensità moderata.
    /// Minuti attivi: cadenza ≥ 100 passi/min (soglia di intensità moderata, studio CADENCE-Adults) o FC ≥ `moderateHR`.
    /// Inattivo: minuti di veglia con < 10 passi e FC sotto la soglia moderata.
    /// Gli array partono dalla mezzanotte locale, un valore al minuto.
    public static func dayActivity(stepsPerMin: [Double], hrPerMin: [Double?], awake: [Bool], moderateHR: Double) -> DayActivity {
        let n = min(stepsPerMin.count, hrPerMin.count, awake.count)
        var active = 0, activeMin = 0.0
        var sed = [Bool](repeating: false, count: n)
        for i in 0..<n where awake[i] {
            let moving = stepsPerMin[i] >= 100 || (hrPerMin[i] ?? 0) >= moderateHR
            if moving { activeMin += 1 }
            sed[i] = stepsPerMin[i] < 10 && (hrPerMin[i] ?? 0) < moderateHR
        }
        var h = 0
        while h * 60 < n {
            let r = (h * 60)..<min((h + 1) * 60, n)
            h += 1
            guard r.filter({ awake[$0] }).count >= 30 else { continue }
            var steps = 0.0, mv = 0
            for i in r where awake[i] { steps += stepsPerMin[i]; if (hrPerMin[i] ?? 0) >= moderateHR { mv += 1 } }
            if steps >= 250 || mv >= 5 { active += 1 }
        }
        let longest = Stats.runs(sed).map { $0.count }.max() ?? 0
        return DayActivity(activeHours: active, activeMinutes: activeMin, inactiveMin: Double(sed.filter { $0 }.count),
                           longestSedentary: Double(longest))
    }

    /// Rilevamento automatico degli allenamenti: ≥ 10 min con FC sopra `thrHR` (buchi ≤ 2 min tollerati)
    /// E movimento reale per almeno metà del tempo (passi o accelerazione), così la FC alta da stress,
    /// caldo o caffeina non diventa un allenamento.
    public static func detectWorkouts(dayStart: Date, hrPerMin: [Double?], stepsPerMin: [Double], motionPerMin: [Double],
                                      thrHR: Double, bounds: [Double], profile: UserProfile) -> [WorkoutRecord] {
        let n = min(hrPerMin.count, stepsPerMin.count, motionPerMin.count)
        guard n > 0 else { return [] }
        let moving = motionPerMin.prefix(n).filter { $0 > 0 }
        let thrMot = moving.isEmpty ? Double.infinity : max(Stats.percentile(Array(moving), 75), 40)
        let cand = (0..<n).map { (hrPerMin[$0] ?? 0) >= thrHR }
        let runs = Stats.merge(Stats.runs(cand), maxGap: 2).filter { $0.count >= 10 }
        let bmrMin = Energy.bmr(profile) / 1440
        return runs.compactMap { r in
            let hr = r.compactMap { hrPerMin[$0] }
            let mv = r.filter { stepsPerMin[$0] > 20 || motionPerMin[$0] > thrMot }.count
            guard Double(mv) >= 0.5 * Double(r.count), let peak = hr.max() else { return nil }
            let steps = r.map { stepsPerMin[$0] }.reduce(0, +) / Double(r.count)
            let kind = steps >= 140 ? "corsa" : steps >= 70 ? "camminata" : "allenamento"
            var kcal = 0.0
            for v in hr { kcal += max(Energy.keytelPerMin(hr: v, profile: profile) - bmrMin, 0) }
            return WorkoutRecord(start: dayStart.addingTimeInterval(Double(r.lowerBound) * 60),
                                 end: dayStart.addingTimeInterval(Double(r.upperBound) * 60),
                                 avgHR: Stats.mean(hr), maxHR: peak,
                                 zoneMinutes: HeartRate.zoneMinutes(perMinute: r.map { hrPerMin[$0] }, bounds: bounds),
                                 kcal: kcal, autoDetected: true, activity: kind)
        }
    }

    /// Movement Index 0-100 dai tre ingredienti dichiarati da Ultrahuman: volume (passi), distribuzione
    /// (ore attive nella giornata) e allenamenti dell'ultima settimana. I pesi sono un'ipotesi dichiarata.
    public static func movementIndex(steps: Double, stepGoal: Double, activeHours: Int, workouts7d: Int)
        -> (score: Double, parts: [String: Double]) {
        let s = pow(Stats.scale(steps, 0, max(stepGoal, 1000)), 0.8)
        let a = Stats.scale(Double(activeHours), 0, 9)
        let w = Stats.scale(Double(workouts7d), 0, 4)
        return (100 * (0.45 * s + 0.35 * a + 0.20 * w), ["passi": s, "ore_attive": a, "allenamenti": w])
    }
}

public enum Energy {
    /// Metabolismo basale, Mifflin-St Jeor (kcal/giorno)
    public static func bmr(_ p: UserProfile) -> Double {
        10 * p.weightKg + 6.25 * p.heightCm - 5 * p.age + (p.sex == .male ? 5 : -161)
    }

    /// Dispendio totale durante l'esercizio da FC, Keytel et al. 2005 (kJ/min -> kcal/min).
    /// Valida in esercizio (indicativamente 90-180 bpm): sotto i 90 bpm non va usata.
    public static func keytelPerMin(hr: Double, profile p: UserProfile) -> Double {
        guard hr >= 90 else { return 0 }
        let kj = p.sex == .male ? -55.0969 + 0.6309 * hr + 0.1988 * p.weightKg + 0.2017 * p.age
                                : -20.4022 + 0.4472 * hr - 0.1263 * p.weightKg + 0.074 * p.age
        return max(kj, 0) / 4.184
    }

    /// Costo netto del cammino ≈ 0,5 kcal per kg per km; un passo ≈ 0,415 x statura
    public static func kcalPerStep(_ p: UserProfile) -> Double { 0.5 * p.weightKg * p.stepLengthM / 1000 }

    /// Calorie del giorno. Se HealthKit fornisce l'energia attiva (misurata dal Watch) la si preferisce;
    /// altrimenti: allenamenti (Keytel) + passi fuori allenamento. Il basale è proporzionale alla parte di giorno trascorsa.
    public static func daily(_ p: UserProfile, dayFraction: Double, hkActive: Double?, hkBasal: Double?,
                             workouts: [WorkoutRecord], stepsOutside: Double) -> (total: Double, active: Double) {
        let basal = hkBasal.flatMap { $0 > 0 ? $0 : nil } ?? bmr(p) * Stats.clamp(dayFraction, 0, 1)
        if let a = hkActive, a > 0 { return (basal + a, a) }
        let act = workouts.map { $0.kcal }.reduce(0, +) + stepsOutside * kcalPerStep(p)
        return (basal + act, act)
    }
}
