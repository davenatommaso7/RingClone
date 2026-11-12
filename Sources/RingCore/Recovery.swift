import Foundation

public enum Recovery {
    public struct Result: Sendable {
        public var score: Double
        public var label: String
        /// contributi standardizzati (positivo = aiuta il recupero) più "stress_punti" in punti
        public var parts: [String: Double]
        public var flags: [String]
    }

    /// Recupero 0-100 dai contributori dichiarati da Ultrahuman: Sleep Index, FC a riposo e temperatura cutanea
    /// rispetto alla baseline, HRV Form (ultima notte + tendenza a 7 giorni) e Stress Rhythm (fino a ±10 punti).
    /// Una giornata perfettamente nella norma vale ≈ 75. I pesi sono un'ipotesi dichiarata.
    public static func score(sleepIndex: Double?, night: NightReport?, stressRhythm: Double?, acwr: Double?,
                             sleepDebtH: Double, baselines b: Baselines) -> Result {
        var z: [String: Double] = [:], w: [String: Double] = [:]
        if let s = sleepIndex { z["sonno"] = (s - 80) / 12; w["sonno"] = 0.30 }
        if let r = night?.rhr, b.rhr.ready { z["fc_riposo"] = -b.rhr.z(r); w["fc_riposo"] = 0.25 }
        if let r = night?.rmssd, r > 0, b.lnRMSSD.ready {
            let last = b.lnRMSSD.z(log(r))
            let trend = b.hrv7.map { b.lnRMSSD.z(0.7 * $0 + 0.3 * log(r)) } ?? last
            z["hrv_form"] = 0.6 * last + 0.4 * trend; w["hrv_form"] = 0.30
        }
        // la temperatura può solo togliere: dentro ±0,3 °C è neutra, oltre penalizza
        if let d = night?.skinTempDev { z["temperatura"] = -3 * Stats.scale(abs(d), 0.3, 1.0); w["temperatura"] = 0.15 }
        z = z.mapValues { Stats.clamp($0, -3, 3) }
        let tot = w.values.reduce(0, +)
        var zz = 0.0
        if tot > 0 { for (k, v) in z { zz += v * (w[k] ?? 0) / tot } }
        var score = 100 * Stats.logistic(1.1 + 0.9 * zz)
        var parts = z
        if let s = stressRhythm {
            let delta = 10 * Stats.clamp((s - 80) / 20, -1, 1)          // 100 -> +10, 80 -> 0, 60 o meno -> -10
            score += delta; parts["stress_punti"] = delta
        }
        score = Stats.clamp(score, 0, 100)

        var flags: [String] = []
        if let d = night?.skinTempDev, d > 0.5,
           b.resp.z(night?.respRate) > 1.5 || b.rhr.z(night?.rhr) > 1.5 {
            flags.append("Temperatura cutanea sopra la norma insieme a respiro o FC a riposo elevati: possibile malessere in arrivo")
        }
        if (z["hrv_form"] ?? 0) < -1.5 && (z["fc_riposo"] ?? 0) < -1.5 {
            flags.append("HRV bassa e FC a riposo alta: sistema nervoso autonomo sotto carico, meglio una giornata leggera")
        }
        if let a = acwr, a > 1.5 { flags.append("Carico degli ultimi 7 giorni oltre 1,5 volte quello abituale: rischio di sovraccarico") }
        if sleepDebtH > 5 { flags.append("Debito di sonno oltre 5 ore") }
        return Result(score: score, label: label(score), parts: parts, flags: flags)
    }

    public static func label(_ s: Double) -> String {
        s > 85 ? "ottimale" : s >= 67 ? "alto" : s >= 50 ? "moderato" : "basso"
    }

    /// Rapporto tra carico acuto (media TRIMP 7 giorni) e cronico (28 giorni). Indicatore grezzo, usato solo come avviso.
    public static func acwr(_ trimp: [Double]) -> Double? {
        guard trimp.count >= 21 else { return nil }
        let a = Stats.mean(Array(trimp.suffix(7))), c = Stats.mean(Array(trimp.suffix(28)))
        return c > 5 ? a / c : nil
    }
}
