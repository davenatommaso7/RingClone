import Foundation

/// Elaborazione numerica dei segnali grezzi (ottico, accelerometro, ECG)
public enum DSP {
    /// Sezione IIR del secondo ordine (Butterworth, formule "Audio EQ Cookbook")
    public struct Biquad: Sendable {
        let b0, b1, b2, a1, a2: Double

        public static func lowpass(fc: Double, fs: Double, q: Double = 0.707_106_781) -> Biquad {
            let w = 2 * Double.pi * fc / fs, alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
            return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
        }
        public static func highpass(fc: Double, fs: Double, q: Double = 0.707_106_781) -> Biquad {
            let w = 2 * Double.pi * fc / fs, alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
            return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
        }
        /// forma diretta II trasposta
        public func apply(_ x: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count), z1 = 0.0, z2 = 0.0
            for i in x.indices {
                let v = x[i], o = b0 * v + z1
                z1 = b1 * v - a1 * o + z2
                z2 = b2 * v - a2 * o
                y[i] = o
            }
            return y
        }
    }

    /// Filtraggio a fase zero (avanti-indietro) con estensione dispari dei bordi per ridurre i transitori
    public static func filtfilt(_ x: [Double], _ sections: [Biquad], pad: Int) -> [Double] {
        let n = x.count
        guard n > 2 else { return x }
        let p = min(pad, n - 1)
        var ext = [Double](); ext.reserveCapacity(n + 2 * p)
        for i in stride(from: p, to: 0, by: -1) { ext.append(2 * x[0] - x[i]) }
        ext.append(contentsOf: x)
        for i in 1...p { ext.append(2 * x[n - 1] - x[n - 1 - i]) }
        var y = ext
        for s in sections { y = s.apply(y) }
        y.reverse()
        for s in sections { y = s.apply(y) }
        y.reverse()
        return Array(y[p..<(p + n)])
    }

    /// passa-banda a fase zero (passa-alto + passa-basso Butterworth del 2° ordine, 4° ordine effettivo)
    public static func bandpass(_ x: [Double], fs: Double, lo: Double, hi: Double) -> [Double] {
        let hiC = min(hi, 0.45 * fs)
        return filtfilt(x, [.highpass(fc: lo, fs: fs), .lowpass(fc: hiC, fs: fs)], pad: Int(2 * fs / lo))
    }

    /// Picco spettrale di un segnale campionato uniformemente, cercato su una griglia di frequenze
    /// (DFT diretta: poche decine di frequenze, costo trascurabile). Finestra di Hann, media rimossa.
    /// `concentration` = quota della potenza in banda entro ±2 passi dal picco (0...1): misura la nitidezza.
    public static func spectralPeak(_ x: [Double], fs: Double, fLo: Double, fHi: Double, df: Double = 0.005)
        -> (f: Double, concentration: Double)? {
        let n = x.count
        guard n >= 16, fHi > fLo else { return nil }
        let m = Stats.mean(x)
        let y = (0..<n).map { (x[$0] - m) * (0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(n - 1))) }
        let freqs = Array(stride(from: fLo, through: fHi + 1e-9, by: df))
        guard freqs.count >= 3 else { return nil }
        var pw = [Double](repeating: 0, count: freqs.count)
        for (k, f) in freqs.enumerated() {
            // ricorrenza di Goertzel: una sola moltiplicazione trigonometrica per frequenza
            let w = 2 * Double.pi * f / fs, coeff = 2 * cos(w)
            var s1 = 0.0, s2 = 0.0
            for v in y { let s0 = v + coeff * s1 - s2; s2 = s1; s1 = s0 }
            pw[k] = s1 * s1 + s2 * s2 - coeff * s1 * s2
        }
        guard let kMax = pw.indices.max(by: { pw[$0] < pw[$1] }), pw[kMax] > 0 else { return nil }
        let total = pw.reduce(0, +)
        let near = pw[max(0, kMax - 2)...min(pw.count - 1, kMax + 2)].reduce(0, +)
        var f = freqs[kMax]
        if kMax > 0 && kMax < pw.count - 1 {            // interpolazione parabolica del picco
            let a = pw[kMax - 1], b = pw[kMax], c = pw[kMax + 1], den = a - 2 * b + c
            if den < 0 { f += 0.5 * (a - c) / den * df }
        }
        return (f, near / total)
    }

    /// ricampionamento lineare di punti (t, v) irregolari su griglia uniforme a `fs`
    public static func resample(t: [Double], v: [Double], fs: Double) -> [Double] {
        guard t.count == v.count, t.count >= 2, let t0 = t.first, let t1 = t.last, t1 > t0 else { return [] }
        var j = 0
        return stride(from: t0, to: t1, by: 1 / fs).map { g in
            while j + 2 < t.count && t[j + 1] <= g { j += 1 }
            let f = (g - t[j]) / max(t[j + 1] - t[j], 1e-6)
            return v[j] + min(max(f, 0), 1) * (v[j + 1] - v[j])
        }
    }
}
