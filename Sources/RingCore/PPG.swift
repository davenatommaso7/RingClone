import Foundation

/// Dal segnale ottico grezzo (fotopletismografia) ai battiti.
///
/// È lo strato che un anello esegue sul proprio sensore. Su Apple Watch il segnale ottico grezzo NON è
/// esposto alle app di terze parti (HealthKit fornisce solo FC e serie battito-battito già elaborate),
/// quindi questo modulo serve con sensori che lo espongono (fasce/anelli BLE, schede di sviluppo) e per i test.
///
/// Metodo: passa-banda 0.5-4 Hz a fase zero -> rilevazione dei picchi sistolici con due medie mobili
/// (Elgendi et al., 2013) -> rifinitura sub-campione (parabola) -> qualità per battito (correlazione con
/// il modello medio dell'onda) + eventuale esclusione dei tratti con movimento.
public enum PPG {
    public struct Result: Sendable {
        /// istanti dei picchi (s dall'inizio del segnale)
        public let beatTimes: [Double]
        /// qualità 0...1 di ciascun battito
        public let quality: [Double]
        /// quota dei battiti con qualità sufficiente
        public let sqi: Double
        /// true se il segnale è stato invertito per avere i picchi sistolici verso l'alto
        public let inverted: Bool

        /// serie battito-battito pronta per `HRV`: gli intervalli che toccano un battito di bassa qualità sono marcati come buchi
        public func series(start: Date, minQuality: Double = 0.8) -> IBISeries {
            var gap = [Bool](repeating: false, count: beatTimes.count)
            for k in beatTimes.indices where k > 0 { gap[k] = quality[k] < minQuality || quality[k - 1] < minQuality }
            return IBISeries(start: start, beatTimes: beatTimes, precededByGap: gap)
        }
    }

    /// - Parameters:
    ///   - x: campioni grezzi (unità arbitrarie)
    ///   - fs: frequenza di campionamento (≥ 20 Hz)
    ///   - motion: opzionale, ENMO in g alla stessa frequenza: i battiti con movimento > `motionLimit` sono declassati
    public static func detectBeats(_ x: [Double], fs: Double, motion: [Double]? = nil, motionLimit: Double = 0.08) -> Result {
        let empty = Result(beatTimes: [], quality: [], sqi: 0, inverted: false)
        guard fs >= 20, x.count >= Int(5 * fs) else { return empty }
        var s = DSP.bandpass(x, fs: fs, lo: 0.5, hi: 4)

        // orientamento automatico: la salita sistolica è più rapida della discesa -> derivata con asimmetria positiva
        var m3 = 0.0, m2 = 0.0
        for i in 1..<s.count { let d = s[i] - s[i - 1]; m2 += d * d; m3 += d * d * d }
        let inverted = m3 < 0 && m2 > 0
        if inverted { for i in s.indices { s[i] = -s[i] } }

        // Elgendi: y = (parte positiva)^2; blocchi dove la media "di picco" (111 ms) supera quella "di battito" (667 ms)
        let y = s.map { $0 > 0 ? $0 * $0 : 0 }
        let w1 = max(Int((0.111 * fs).rounded()), 1), w2 = max(Int((0.667 * fs).rounded()), 2)
        let maPeak = Stats.rollingMean(y, half: w1 / 2), maBeat = Stats.rollingMean(y, half: w2 / 2)
        let alpha = 0.02 * Stats.mean(y)
        let blocks = Stats.runs(s.indices.map { maPeak[$0] > maBeat[$0] + alpha }).filter { $0.count >= w1 }
        let refractory = 0.3 * fs
        var peaks: [Int] = []
        for b in blocks {
            guard let p = b.max(by: { s[$0] < s[$1] }) else { continue }
            if let l = peaks.last, Double(p - l) < refractory { if s[p] > s[l] { peaks[peaks.count - 1] = p }; continue }
            peaks.append(p)
        }
        guard peaks.count >= 4 else { return empty }

        // rifinitura sub-campione
        let times = peaks.map { p -> Double in
            guard p > 0, p < s.count - 1 else { return Double(p) / fs }
            let a = s[p - 1], b = s[p], c = s[p + 1], den = a - 2 * b + c
            return (Double(p) + (den < 0 ? 0.5 * (a - c) / den : 0)) / fs
        }

        // qualità: correlazione di ogni onda con il modello medio
        let pre = Int(0.25 * fs), post = Int(0.45 * fs), len = pre + post + 1
        var template = [Double](repeating: 0, count: len), used = 0
        for p in peaks where p - pre >= 0 && p + post < s.count {
            for k in 0..<len { template[k] += s[p - pre + k] }
            used += 1
        }
        var quality = [Double](repeating: 0, count: peaks.count)
        if used >= 3 {
            for k in 0..<len { template[k] /= Double(used) }
            let tm = Stats.mean(template)
            let tv = template.map { ($0 - tm) * ($0 - tm) }.reduce(0, +)
            for (j, p) in peaks.enumerated() where p - pre >= 0 && p + post < s.count {
                var mean = 0.0
                for k in 0..<len { mean += s[p - pre + k] }
                mean /= Double(len)
                var num = 0.0, den = 0.0
                for k in 0..<len { let a = s[p - pre + k] - mean; num += a * (template[k] - tm); den += a * a }
                quality[j] = den > 0 && tv > 0 ? max(num / sqrt(den * tv), 0) : 0
            }
        }
        if let motion, motion.count == x.count {
            let half = Int(0.5 * fs)
            let mm = Stats.rollingMean(motion, half: half)
            for (j, p) in peaks.enumerated() where mm[p] > motionLimit { quality[j] = min(quality[j], 0.3) }
        }
        let good = quality.filter { $0 >= 0.8 }.count
        return Result(beatTimes: times, quality: quality, sqi: Double(good) / Double(peaks.count), inverted: inverted)
    }

    /// FC media (bpm) dai battiti di buona qualità
    public static func heartRate(_ r: Result) -> Double? {
        HRV.metrics(HRV.beats(from: r.series(start: Date(timeIntervalSinceReferenceDate: 0))), minBeats: 5).map { $0.hr }
    }
}
