import Foundation

/// Battito normale (NN) con tempo assoluto. `diff` è la differenza con l'intervallo precedente
/// SOLO se i due intervalli sono davvero consecutivi e entrambi validi: così RMSSD e pNN50
/// non vengono gonfiati dai battiti scartati o dai buchi tra serie diverse.
public struct Beat: Sendable {
    /// secondi (timeIntervalSinceReferenceDate) alla fine dell'intervallo
    public let t: Double
    /// intervallo battito-battito in ms
    public let ibi: Double
    public let diff: Double?
}

/// HRV e respiro dagli intervalli battito-battito (IBI).
/// Sorgenti: fotopletismografia grezza (`PPG`), serie HealthKit del Watch, ECG.
public enum HRV {
    public struct Metrics: Sendable {
        public let n: Int
        public let meanNN: Double, rmssd: Double, sdnn: Double, pnn50: Double
        /// assi dell'ellisse di Poincaré (grafico di Lorenz): SD1 breve termine, SD2 lungo termine
        public let sd1: Double, sd2: Double
        public var hr: Double { 60_000 / meanNN }
    }

    /// Maschera degli intervalli fisiologici: 300-2000 ms e entro ±20 % dalla mediana locale (11 battiti)
    public static func validMask(_ x: [Double]) -> [Bool] {
        let n = x.count
        return (0..<n).map { i in
            guard x[i] >= 300, x[i] <= 2000 else { return false }
            let w = x[max(0, i - 5)...min(n - 1, i + 5)].filter { $0 >= 300 && $0 <= 2000 }
            guard w.count >= 3 else { return true }
            let med = Stats.median(Array(w))
            return abs(x[i] - med) < 0.2 * med
        }
    }

    /// Converte una serie in battiti NN conservando l'adiacenza
    public static func beats(from s: IBISeries) -> [Beat] {
        let t = s.beatTimes, n = t.count
        guard n >= 2 else { return [] }
        var ibi = [Double](repeating: 0, count: n), present = [Bool](repeating: false, count: n)
        for k in 1..<n where !s.precededByGap[k] && t[k] > t[k - 1] { ibi[k] = (t[k] - t[k - 1]) * 1000; present[k] = true }
        let idx = (1..<n).filter { present[$0] }
        let mask = validMask(idx.map { ibi[$0] })
        var ok = [Bool](repeating: false, count: n)
        for (j, k) in idx.enumerated() { ok[k] = mask[j] }
        let t0 = s.start.timeIntervalSinceReferenceDate
        var out: [Beat] = []; out.reserveCapacity(idx.count)
        for k in 1..<n where ok[k] {
            out.append(Beat(t: t0 + t[k], ibi: ibi[k], diff: ok[k - 1] ? ibi[k] - ibi[k - 1] : nil))
        }
        return out
    }

    /// Tutte le serie in un unico flusso ordinato nel tempo
    public static func beats(from series: [IBISeries]) -> [Beat] {
        series.sorted { $0.start < $1.start }.flatMap { beats(from: $0) }.sorted { $0.t < $1.t }
    }

    /// Indici [lo, hi) dei battiti con t in [from, to) (ricerca binaria su flusso ordinato)
    public static func range(_ b: [Beat], from: Double, to: Double) -> Range<Int> {
        func lower(_ x: Double) -> Int {
            var lo = 0, hi = b.count
            while lo < hi { let m = (lo + hi) / 2; if b[m].t < x { lo = m + 1 } else { hi = m } }
            return lo
        }
        let a = lower(from)
        return a..<max(a, lower(to))
    }

    public static func metrics<C: Collection>(_ b: C, minBeats: Int = 20) -> Metrics? where C.Element == Beat {
        var n = 0, sum = 0.0, sq = 0.0, nd = 0, dsq = 0.0, n50 = 0
        for x in b {
            n += 1; sum += x.ibi; sq += x.ibi * x.ibi
            if let d = x.diff { nd += 1; dsq += d * d; if abs(d) > 50 { n50 += 1 } }
        }
        guard n >= minBeats, nd >= minBeats * 3 / 4 else { return nil }
        let mean = sum / Double(n)
        let sdnn = sqrt(max(sq / Double(n) - mean * mean, 0) * Double(n) / Double(n - 1))
        let rmssd = sqrt(dsq / Double(nd))
        let sd1 = rmssd / 2.0.squareRoot()
        let sd2 = sqrt(max(2 * sdnn * sdnn - sd1 * sd1, 0))
        return Metrics(n: n, meanNN: mean, rmssd: rmssd, sdnn: sdnn, pnn50: 100 * Double(n50) / Double(nd), sd1: sd1, sd2: sd2)
    }

    /// Comodità: metriche da una lista di intervalli contigui (ms)
    public static func metrics(ibiMs: [Double], minBeats: Int = 20) -> Metrics? {
        metrics(beats(from: IBISeries(start: Date(timeIntervalSinceReferenceDate: 0), ibiMs: ibiMs)), minBeats: minBeats)
    }

    /// Indice di stress di Baevsky: SI = AMo / (2 * Mo * MxDMn), istogramma a classi di 50 ms
    public static func baevsky<C: Collection>(_ b: C) -> Double? where C.Element == Beat {
        var h: [Int: Int] = [:], n = 0, mn = Double.infinity, mx = -Double.infinity
        for x in b { h[Int(x.ibi / 50), default: 0] += 1; n += 1; mn = min(mn, x.ibi); mx = max(mx, x.ibi) }
        guard n >= 30, let top = h.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { return nil }
        let amo = 100 * Double(top.value) / Double(n), mo = (Double(top.key) * 50 + 25) / 1000
        return amo / (2 * mo * max((mx - mn) / 1000, 0.01))
    }

    /// Frequenza respiratoria dall'aritmia sinusale respiratoria (modulazione di frequenza del battito):
    /// IBI ricampionati a 4 Hz, rimozione del trend (media mobile 10 s), picco spettrale in 0.1-0.5 Hz
    /// (6-30 atti/min), limitato alla frequenza di Nyquist del battito. `quality` 0...1 = nitidezza del picco.
    public static func respiratoryRate<C: Collection>(_ b: C) -> (rate: Double, quality: Double)? where C.Element == Beat {
        let t = b.map { $0.t }, v = b.map { $0.ibi }
        guard t.count >= 40, let t0 = t.first, let t1 = t.last, t1 - t0 >= 50 else { return nil }
        // serve una serie quasi contigua: scarta finestre con troppi battiti mancanti
        let expected = (t1 - t0) / (Stats.mean(v) / 1000)
        guard Double(t.count) >= 0.85 * expected else { return nil }
        let fs = 4.0
        var y = DSP.resample(t: t, v: v, fs: fs)
        guard y.count >= 160 else { return nil }
        let trend = Stats.rollingMean(y, half: Int(fs * 5))
        for i in y.indices { y[i] -= trend[i] }
        let nyq = 0.5 * 1000 / Stats.mean(v)
        guard let pk = DSP.spectralPeak(y, fs: fs, fLo: 0.1, fHi: min(0.5, nyq)) else { return nil }
        return (pk.f * 60, pk.concentration)
    }

    /// Picchi R (Pan-Tompkins semplificato) su ECG a singola derivazione -> serie di battiti.
    /// Passa-banda 5-18 Hz, derivata, quadrato, integrazione su 120 ms, soglia adattiva, refrattarietà 250 ms.
    public static func beatsFromECG(_ v: [Double], fs: Double, start: Date) -> IBISeries {
        guard v.count > Int(2 * fs) else { return IBISeries(start: start, beatTimes: []) }
        let bp = DSP.bandpass(v, fs: fs, lo: 5, hi: 18)
        var d = [Double](repeating: 0, count: bp.count)
        for i in 1..<bp.count { let x = bp[i] - bp[i - 1]; d[i] = x * x }
        let half = max(Int(0.06 * fs), 1)
        let mwa = Stats.rollingMean(d, half: half)
        let thr = 0.3 * Stats.percentile(mwa, 98)
        let refr = 0.25 * fs
        var peaks: [Int] = []
        for i in 1..<(mwa.count - 1) where mwa[i] > thr && mwa[i] >= mwa[i - 1] && mwa[i] > mwa[i + 1] {
            if let l = peaks.last, Double(i - l) < refr { if mwa[i] > mwa[l] { peaks[peaks.count - 1] = i }; continue }
            peaks.append(i)
        }
        // rifinitura: massimo di |ECG filtrato| attorno al picco dell'energia
        let times = peaks.map { p -> Double in
            let a = max(0, p - half), b = min(bp.count - 1, p + half)
            let k = (a...b).max { abs(bp[$0]) < abs(bp[$1]) } ?? p
            return Double(k) / fs
        }
        return IBISeries(start: start, beatTimes: times)
    }
}
