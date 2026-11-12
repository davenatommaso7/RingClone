import Foundation

/// Stress fisiologico: attivazione del sistema nervoso autonomo a riposo (non stress psicologico percepito).
public enum Stress {
    /// Punteggio 0-100 di una finestra di 5 min in veglia, senza movimento né allenamento.
    /// Combina FC rispetto alla FC a riposo, indice di Baevsky e RMSSD rispetto alla baseline notturna
    /// (di giorno l'RMSSD è fisiologicamente più basso che di notte: si confronta con baseline - 0,5 in scala logaritmica, cioè ≈ -40 %).
    /// Senza battiti a sufficienza si usa la sola FC.
    public static func window<C: Collection>(hr: Double, beats: C, rhr: Double, lnRMSSDBase: Double?, lnRMSSDSpread: Double) -> Double
        where C.Element == Beat {
        let zHR = (hr - 1.30 * rhr) / (0.13 * rhr)
        var z = zHR
        if let m = HRV.metrics(beats, minBeats: 40), m.rmssd > 0, let si = HRV.baevsky(beats) {
            let zSI = (log(si) - log(150)) / 0.8
            if let base = lnRMSSDBase {
                let zHRV = (log(m.rmssd) - (base - 0.5)) / max(lnRMSSDSpread, 0.3)
                z = 0.40 * zHR + 0.30 * zSI - 0.30 * Stats.clamp(zHRV, -3, 3)
            } else {
                z = 0.55 * zHR + 0.45 * zSI
            }
        }
        return 100 * Stats.logistic(1.2 * Stats.clamp(z, -4, 4) - 0.4)
    }

    /// Linea dello stress sul giorno di calendario: 288 finestre da 5 min, nil dove non è valutabile
    /// (sonno, allenamento e 10 min successivi, camminata, orologio non indossato).
    public static func timeline(hrPerMin: [Double?], stepsPerMin: [Double], awake: [Bool], inWorkout: [Bool],
                                dayStart: Date, beats: [Beat], rhr: Double, baselines b: Baselines, nightLnRMSSD: Double?) -> [Double?] {
        let n = min(hrPerMin.count, stepsPerMin.count, awake.count, inWorkout.count) / 5
        let base = b.lnRMSSD.ready ? b.lnRMSSD.center : nightLnRMSSD
        let t0 = dayStart.timeIntervalSinceReferenceDate
        var out = [Double?](repeating: nil, count: 288)
        var prevSteps = 0.0
        for w in 0..<min(n, 288) {
            let r = (w * 5)..<(w * 5 + 5)
            let steps = r.map { stepsPerMin[$0] }.reduce(0, +)
            defer { prevSteps = steps }
            let hr = r.compactMap { hrPerMin[$0] }
            let recovering = ((max(w * 5 - 10, 0))..<(w * 5 + 5)).contains { inWorkout[$0] }
            guard r.allSatisfy({ awake[$0] }), !recovering, steps < 60, prevSteps < 150, hr.count >= 3 else { continue }
            let a = t0 + Double(w) * 300
            let br = beats.isEmpty ? 0..<0 : HRV.range(beats, from: a, to: a + 300)
            out[w] = window(hr: Stats.mean(hr), beats: beats[br], rhr: rhr, lnRMSSDBase: base, lnRMSSDSpread: b.lnRMSSD.spread)
        }
        return out
    }

    /// Stress Rhythm: parte da 100 a mezzanotte e perde punti per ogni finestra di stress alto (> 70) fuori
    /// dall'allenamento. Lo stress serale pesa di più (disturba il sonno), quello del mattino meno.
    /// `wakeH`/`bedH` = orari abituali di risveglio e di addormentamento (ore decimali).
    public static func rhythm(_ timeline: [Double?], wakeH: Double, bedH: Double) -> Double {
        var score = 100.0
        for (w, s) in timeline.enumerated() {
            guard let s, s > 70 else { continue }
            let h = (Double(w) + 0.5) / 12
            let sinceWake = Stats.wrap24(h - wakeH), toBed = Stats.wrap24(bedH - h)
            let weight = toBed <= 4 ? 1.5 : sinceWake <= 3 ? 0.5 : 1.0
            score -= weight * (0.6 + 0.4 * Stats.scale(s, 70, 100))
        }
        return max(score, 0)
    }
}
