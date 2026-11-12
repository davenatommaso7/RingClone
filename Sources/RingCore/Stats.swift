import Foundation

public enum Stats {
    public static func mean(_ x: [Double]) -> Double { x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count) }

    public static func sd(_ x: [Double]) -> Double {
        guard x.count > 1 else { return .nan }
        let m = mean(x)
        var s = 0.0
        for v in x { s += (v - m) * (v - m) }
        return sqrt(s / Double(x.count - 1))
    }

    /// percentile con interpolazione lineare su un array GIÀ ordinato
    public static func percentileSorted(_ s: [Double], _ p: Double) -> Double {
        guard !s.isEmpty else { return .nan }
        let r = min(max(p, 0), 100) / 100 * Double(s.count - 1)
        let lo = Int(r.rounded(.down)), hi = Int(r.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (r - Double(lo))
    }
    public static func percentile(_ x: [Double], _ p: Double) -> Double { percentileSorted(x.sorted(), p) }
    public static func median(_ x: [Double]) -> Double { percentile(x, 50) }

    /// deviazione assoluta mediana scalata (stima robusta della deviazione standard)
    public static func mad(_ x: [Double]) -> Double {
        let m = median(x)
        return 1.4826 * median(x.map { abs($0 - m) })
    }

    /// z-score robusto (mediana / IQR) per normalizzare le feature sulla singola notte.
    /// `minScale` evita che una notte molto tranquilla trasformi micro-variazioni in valori estremi.
    public static func robustZ(_ x: [Double?], minScale: Double = 1e-6, minCount: Int = 10) -> [Double?] {
        let v = x.compactMap { $0 }.sorted()
        guard v.count > minCount else { return x.map { _ in nil } }
        let m = percentileSorted(v, 50)
        let s = max((percentileSorted(v, 75) - percentileSorted(v, 25)) / 1.349, minScale)
        return x.map { $0.map { ($0 - m) / s } }
    }

    /// media mobile centrata (finestra 2*half+1, troncata ai bordi), O(n)
    public static func rollingMean(_ x: [Double], half: Int) -> [Double] {
        guard !x.isEmpty else { return [] }
        var pre = [Double](repeating: 0, count: x.count + 1)
        for i in x.indices { pre[i + 1] = pre[i] + x[i] }
        return x.indices.map { i in
            let a = max(0, i - half), b = min(x.count, i + half + 1)
            return (pre[b] - pre[a]) / Double(b - a)
        }
    }

    /// deviazione standard mobile su valori opzionali, O(n) con somme cumulate
    public static func rollingSD(_ x: [Double?], half: Int, minCount: Int = 4) -> [Double?] {
        let n = x.count
        guard n > 0 else { return [] }
        var c = [Double](repeating: 0, count: n + 1), s = c, q = c
        for i in 0..<n {
            let v = x[i]
            c[i + 1] = c[i] + (v == nil ? 0 : 1)
            s[i + 1] = s[i] + (v ?? 0)
            q[i + 1] = q[i] + (v ?? 0) * (v ?? 0)
        }
        return (0..<n).map { i in
            let a = max(0, i - half), b = min(n, i + half + 1)
            let k = c[b] - c[a]
            guard k >= Double(minCount) else { return nil }
            let m = (s[b] - s[a]) / k
            return sqrt(max((q[b] - q[a]) / k - m * m, 0) * k / (k - 1))
        }
    }

    public static func circularMeanHours(_ h: [Double]) -> Double {
        guard !h.isEmpty else { return .nan }
        var ss = 0.0, cc = 0.0
        for x in h { let a = x * 2 * .pi / 24; ss += sin(a); cc += cos(a) }
        let m = atan2(ss, cc) * 24 / (2 * .pi)
        return (m + 24).truncatingRemainder(dividingBy: 24)
    }

    /// deviazione standard circolare in ore (per orari che attraversano la mezzanotte)
    public static func circularSDHours(_ h: [Double]) -> Double {
        guard h.count > 1 else { return .nan }
        var ss = 0.0, cc = 0.0
        for x in h { let a = x * 2 * .pi / 24; ss += sin(a); cc += cos(a) }
        let r = min(sqrt(ss * ss + cc * cc) / Double(h.count), 1)
        return r <= 1e-12 ? 12 : sqrt(-2 * log(r)) * 24 / (2 * .pi)
    }

    /// differenza a - b in ore, nell'intervallo [-12, 12)
    public static func circDiff(_ a: Double, _ b: Double) -> Double {
        let d = (a - b).truncatingRemainder(dividingBy: 24)
        return ((d + 36).truncatingRemainder(dividingBy: 24)) - 12
    }

    public static func wrap24(_ h: Double) -> Double {
        ((h.truncatingRemainder(dividingBy: 24)) + 24).truncatingRemainder(dividingBy: 24)
    }

    public static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }

    /// 0 sotto `lo`, 1 sopra `hi`, lineare in mezzo
    public static func scale(_ x: Double, _ lo: Double, _ hi: Double) -> Double { clamp((x - lo) / (hi - lo), 0, 1) }

    public static func logistic(_ z: Double) -> Double { 1 / (1 + exp(-z)) }

    public static func gaussLog(_ x: Double, _ m: Double, _ s: Double) -> Double {
        -0.5 * ((x - m) / s) * ((x - m) / s) - log(s) - 0.918_938_533_204_672_7
    }

    public static func hourOfDay(_ d: Date, _ cal: Calendar) -> Double {
        let c = cal.dateComponents([.hour, .minute, .second], from: d)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
    }

    /// Interpolazione lineare di campioni sparsi (ordinati per data) su una griglia crescente.
    /// Restituisce nil dove il buco tra i due campioni vicini supera `maxGap` (dato mancante).
    public static func interpolate(_ s: [TimedValue], at grid: [Date], maxGap: TimeInterval) -> [Double?] {
        guard !s.isEmpty else { return grid.map { _ in nil } }
        var j = 0
        return grid.map { t in
            while j + 1 < s.count && s[j + 1].date <= t { j += 1 }
            let a = s[j]
            if t < a.date { return a.date.timeIntervalSince(t) <= maxGap / 2 ? a.value : nil }
            guard j + 1 < s.count else { return t.timeIntervalSince(a.date) <= maxGap / 2 ? a.value : nil }
            let b = s[j + 1]
            let gap = b.date.timeIntervalSince(a.date)
            guard gap <= maxGap else {
                // vicino a uno dei due estremi il campione resta rappresentativo
                if t.timeIntervalSince(a.date) <= 60 { return a.value }
                if b.date.timeIntervalSince(t) <= 60 { return b.value }
                return nil
            }
            let f = gap > 0 ? t.timeIntervalSince(a.date) / gap : 0
            return a.value + f * (b.value - a.value)
        }
    }

    /// tratti consecutivi di `true` come intervalli semi-aperti [start, end)
    public static func runs(_ m: [Bool]) -> [Range<Int>] {
        var out: [Range<Int>] = [], i = 0
        while i < m.count {
            if m[i] { var j = i; while j < m.count && m[j] { j += 1 }; out.append(i..<j); i = j } else { i += 1 }
        }
        return out
    }

    /// unisce tratti separati da buchi <= maxGap
    public static func merge(_ p: [Range<Int>], maxGap: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for b in p {
            if let l = out.last, b.lowerBound - l.upperBound <= maxGap { out[out.count - 1] = l.lowerBound..<max(l.upperBound, b.upperBound) }
            else { out.append(b) }
        }
        return out
    }
}

/// Generatore deterministico (SplitMix64) per simulazioni e test riproducibili
public struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * uniform() }
    /// normale standard (Box-Muller)
    public mutating func normal() -> Double {
        let u = max(uniform(), 1e-12), v = uniform()
        return sqrt(-2 * log(u)) * cos(2 * .pi * v)
    }
}
