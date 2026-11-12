import Foundation

public enum HeartRate {
    /// Tanaka et al. 2001: HRmax = 208 - 0.7 x età
    public static func tanaka(age: Double) -> Double { 208 - 0.7 * age }

    /// FC a riposo notturna: la più bassa media su 5 minuti consecutivi di sonno.
    /// `nadirFrac` = posizione del minimo nella notte (0 inizio, 1 fine): un minimo precoce indica buon recupero.
    public static func restingNight(_ hr: [Double?], asleep: [Bool]) -> (rhr: Double, nadirFrac: Double, avg: Double)? {
        let n = min(hr.count, asleep.count)
        var c = [Double](repeating: 0, count: n + 1), s = c
        var first: Int?, last = 0
        for i in 0..<n {
            let ok = asleep[i] && hr[i] != nil
            c[i + 1] = c[i] + (ok ? 1 : 0); s[i + 1] = s[i] + (ok ? hr[i]! : 0)
            if ok { if first == nil { first = i }; last = i }
        }
        guard let f = first, c[n] >= 40 else { return nil }
        let w = 10
        var best = Double.infinity, at = f
        for i in 0..<max(n - w + 1, 1) {
            let j = min(i + w, n), k = c[j] - c[i]
            guard k >= 6 else { continue }
            let m = (s[j] - s[i]) / k
            if m < best { best = m; at = i + w / 2 }
        }
        guard best.isFinite else { return nil }
        let frac = last > f ? Stats.clamp(Double(at - f) / Double(last - f), 0, 1) : 0
        return (best, frac, s[n] / c[n])
    }

    /// HRmax: valore inserito dall'utente, altrimenti il più alto tra Tanaka e i picchi osservati negli allenamenti.
    /// Si usa il SECONDO picco più alto (robusto a un artefatto ottico isolato).
    /// `measured` = l'utente ha davvero raggiunto l'area del massimo (serve per la stima di Uth).
    public static func hrMax(profile: UserProfile, workoutPeaks: [Double]) -> (value: Double, measured: Bool) {
        if let o = profile.hrMaxOverride, o > 100, o < 230 { return (o, true) }
        let t = tanaka(age: profile.age)
        let peaks = workoutPeaks.filter { $0 > 100 && $0 < 230 }.sorted(by: >)
        guard peaks.count >= 3 else { return (t, false) }
        let observed = peaks[1]
        return (max(t, observed), observed >= 0.95 * t)
    }

    /// 6 limiti (bpm): inizio Z1, Z2, Z3, Z4, Z5 e fine Z5, alle frazioni 50-60-70-80-90-100 %
    public static func zoneBounds(model: ZoneModel, rhr: Double, hrMax: Double) -> [Double] {
        (5...10).map { k in
            let f = Double(k) / 10
            return model == .karvonen ? rhr + f * (hrMax - rhr) : f * hrMax
        }
    }

    /// 0 = sotto Z1, 1...5
    public static func zone(of hr: Double, bounds: [Double]) -> Int {
        guard bounds.count == 6, hr >= bounds[0] else { return 0 }
        var z = 1
        for k in 1...4 where hr >= bounds[k] { z = k + 1 }
        return z
    }

    /// Minuti in zona da FC al minuto
    public static func zoneMinutes(perMinute hr: [Double?], bounds: [Double]) -> [Double] {
        var z = [Double](repeating: 0, count: 5)
        for v in hr { if let v { let k = zone(of: v, bounds: bounds); if k > 0 { z[k - 1] += 1 } } }
        return z
    }

    /// Minuti in zona pesati sul tempo reale tra i campioni (che su Apple Watch non sono equispaziati).
    /// Ogni campione vale fino al successivo, al massimo `maxHold` secondi.
    public static func zoneMinutes(samples: [TimedValue], bounds: [Double], maxHold: TimeInterval = 15) -> [Double] {
        var z = [Double](repeating: 0, count: 5)
        for i in samples.indices {
            let dt = i + 1 < samples.count ? min(samples[i + 1].date.timeIntervalSince(samples[i].date), maxHold) : min(5, maxHold)
            let k = zone(of: samples[i].value, bounds: bounds)
            if k > 0, dt > 0 { z[k - 1] += dt / 60 }
        }
        return z
    }

    /// TRIMP di Edwards: somma dei minuti moltiplicati per il numero della zona
    public static func trimp(_ zoneMin: [Double]) -> Double {
        var t = 0.0
        for (i, m) in zoneMin.enumerated() { t += Double(i + 1) * m }
        return t
    }
}
