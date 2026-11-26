import Foundation

fileprivate struct NNSpan: Hashable, Sendable {
    let start: Double
    let end: Double
}

fileprivate struct NNWitness: Sendable {
    let group: Int
    let ibi: Double
    let previous: NNSpan?
    let diff: Double?
}

/// Battito normale (NN) con tempo assoluto. `diff` è la differenza con l'intervallo precedente
/// SOLO se i due intervalli sono davvero consecutivi e entrambi validi: così RMSSD e pNN50
/// non vengono gonfiati dai battiti scartati o dai buchi tra serie diverse.
public struct Beat: Sendable {
    /// secondi (timeIntervalSinceReferenceDate) alla fine dell'intervallo
    public let t: Double
    /// intervallo battito-battito in ms
    public var ibi: Double { witness.ibi }
    public var diff: Double? { witness.diff }
    var predecessorTime: Double? { witness.previous?.end }
    fileprivate let span: NNSpan
    fileprivate var witness: NNWitness
    fileprivate var alternateWitnesses: [NNWitness] = []

    fileprivate init(span: NNSpan, witness: NNWitness) {
        self.t = span.end
        self.span = span
        self.witness = witness
    }

    fileprivate mutating func addWitness(_ other: NNWitness) {
        if alternateWitnesses.isEmpty { alternateWitnesses.append(witness) }
        if let index = alternateWitnesses.firstIndex(where: { $0.group == other.group }) {
            if alternateWitnesses[index].previous == nil, other.previous != nil { alternateWitnesses[index] = other }
        } else {
            alternateWitnesses.append(other)
        }
        let pairs = alternateWitnesses.filter { $0.previous != nil }
        if let first = pairs.first, pairs.allSatisfy({ $0.previous == first.previous }) {
            witness = first
        } else {
            witness = NNWitness(group: witness.group, ibi: witness.ibi, previous: nil, diff: nil)
        }
    }
}

/// HRV e respiro dagli intervalli battito-battito (IBI).
/// Sorgenti: fotopletismografia grezza (`PPG`), serie HealthKit del Watch, ECG.
public enum HRV {
    private static let maximumNNMilliseconds = 2000.0
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
            guard x[i] >= 300, x[i] <= maximumNNMilliseconds else { return false }
            let w = x[max(0, i - 5)...min(n - 1, i + 5)].filter { $0 >= 300 && $0 <= maximumNNMilliseconds }
            guard w.count >= 3 else { return true }
            let med = Stats.median(Array(w))
            return abs(x[i] - med) < 0.2 * med
        }
    }

    /// Converte una serie in battiti NN conservando l'adiacenza
    public static func beats(from s: IBISeries) -> [Beat] {
        beats(from: s, group: 0, blocked: [])
    }

    private static func beats(from s: IBISeries, group: Int, blocked: Set<NNSpan>) -> [Beat] {
        let t = s.beatTimes, n = t.count
        guard n >= 2, s.precededByGap.count == n,
              (1..<n).allSatisfy({ t[$0 - 1].isFinite && t[$0].isFinite && t[$0] > t[$0 - 1] }) else { return [] }
        var ibi = [Double](repeating: 0, count: n), present = [Bool](repeating: false, count: n)
        let absolute = t.map { s.start.timeIntervalSinceReferenceDate + $0 }
        func span(_ k: Int) -> NNSpan { NNSpan(start: absolute[k - 1], end: absolute[k]) }
        for k in 1..<n where !s.precededByGap[k] && absolute[k - 1].isFinite && absolute[k].isFinite && absolute[k] > absolute[k - 1] {
            guard !blocked.contains(span(k)) else { continue }
            ibi[k] = (t[k] - t[k - 1]) * 1000
            present[k] = true
        }
        let idx = (1..<n).filter { present[$0] }
        let mask = validMask(idx.map { ibi[$0] })
        var ok = [Bool](repeating: false, count: n)
        for (j, k) in idx.enumerated() { ok[k] = mask[j] }
        var out: [Beat] = []; out.reserveCapacity(idx.count)
        for k in 1..<n where ok[k] {
            let adjacent = ok[k - 1]
            let witness = NNWitness(group: group, ibi: ibi[k], previous: adjacent ? span(k - 1) : nil,
                                    diff: adjacent ? ibi[k] - ibi[k - 1] : nil)
            out.append(Beat(span: span(k), witness: witness))
        }
        return out
    }

    /// Tutte le serie in un unico flusso ordinato nel tempo
    public static func beats(from series: [IBISeries]) -> [Beat] {
        struct Content: Hashable {
            let start: Date
            let times: [UInt64]
            let gaps: [Bool]

            init(_ s: IBISeries) {
                start = s.start; times = s.beatTimes.map(\.bitPattern); gaps = s.precededByGap
            }
        }
        enum Source: Hashable {
            case stream(UUID), record(UUID), anonymous(Int)

            var isAnonymous: Bool { if case .anonymous = self { return true }; return false }
        }
        struct Key: Hashable { let source: Source?; let span: NNSpan }
        var contentByID: [UUID: (Content, UUID?)] = [:]
        var conflicts = Set<UUID>()
        let indexed = series.map { ($0, Content($0)) }
        for (s, content) in indexed {
            if let id = s.sourceID, let prior = contentByID.updateValue((content, s.streamID), forKey: id),
               prior.0 != content || prior.1 != s.streamID {
                conflicts.insert(id)
            }
        }
        let identified = Set(indexed.compactMap { s, content -> Content? in
            if let id = s.sourceID { return conflicts.contains(id) ? nil : content }
            return s.streamID != nil ? content : nil
        })
        var ids = Set<UUID>(), anonymous = Set<Content>()
        let unique = indexed.compactMap { s, content -> IBISeries? in
            if let id = s.sourceID {
                return !conflicts.contains(id) && ids.insert(id).inserted ? s : nil
            }
            if s.streamID != nil { return s }
            return !identified.contains(content) && anonymous.insert(content).inserted ? s : nil
        }
        var groups: [Source: Int] = [:]
        var sources: [Source] = []
        var fragments: [[IBISeries]] = []
        for (i, fragment) in unique.enumerated() {
            let source = fragment.streamID.map(Source.stream) ?? fragment.sourceID.map(Source.record) ?? .anonymous(i)
            if let group = groups[source] { fragments[group].append(fragment) }
            else {
                groups[source] = fragments.count
                sources.append(source)
                fragments.append([fragment])
            }
        }
        var result: [Beat] = []
        var bySpan: [Key: Int] = [:]
        for (group, samples) in fragments.enumerated() {
            let source = sources[group]
            let blocked = samples.count > 1 ? conflictingSpans(samples) : []
            for sample in samples {
                for beat in beats(from: sample, group: group, blocked: blocked) {
                    // Un duplicato anonimo è una singola osservazione, con i testimoni separati.
                    let key = Key(source: source.isAnonymous ? nil : source, span: beat.span)
                    if let index = bySpan[key] { result[index].addWitness(beat.witness) }
                    else {
                        bySpan[key] = result.count
                        result.append(beat)
                    }
                }
            }
        }
        return result.sorted { $0.t != $1.t ? $0.t < $1.t : $0.span.start < $1.span.start }
    }

    /// Nello stesso stream, intervalli discordanti o un gap sovrapposto non dimostrano adiacenza.
    private static func conflictingSpans(_ fragments: [IBISeries]) -> Set<NNSpan> {
        struct RawInterval: Hashable { let span: NNSpan; let gap: Bool }
        var intervals = Set<RawInterval>()
        for s in fragments where s.beatTimes.count >= 2 && s.precededByGap.count == s.beatTimes.count {
            let absolute = s.beatTimes.map { s.start.timeIntervalSinceReferenceDate + $0 }
            for i in 1..<absolute.count where absolute[i - 1].isFinite && absolute[i].isFinite && absolute[i] > absolute[i - 1] {
                intervals.insert(RawInterval(span: NNSpan(start: absolute[i - 1], end: absolute[i]), gap: s.precededByGap[i]))
            }
        }
        let ordered = intervals.sorted {
            $0.span.start != $1.span.start ? $0.span.start < $1.span.start : $0.span.end < $1.span.end
        }
        var blocked = Set<NNSpan>(), frontier = -Double.infinity
        for i in ordered.indices {
            let span = ordered[i].span
            if span.start < frontier || (i + 1 < ordered.count && ordered[i + 1].span.start < span.end) { blocked.insert(span) }
            frontier = max(frontier, span.end)
        }
        return blocked
    }

    /// Restituisce un solo gruppo che dimostri copertura sufficiente. Nessuna somma fra acquisizioni.
    static func coveredWindow(_ beats: [Beat], from: Double, to: Double, minimumSeconds: Double,
                              minBeats: Int) -> (beats: [Beat], metrics: Metrics)? {
        // Anche un NN che termina al margine destro o subito oltre può coprire parte della finestra.
        let candidates = beats[range(beats, from: from, to: to + maximumNNMilliseconds / 1000)]
        var groups: [Int: [Beat]] = [:]
        for beat in candidates where beat.span.start < to {
            if beat.alternateWitnesses.isEmpty {
                groups[beat.witness.group, default: []].append(beat)
            } else {
                for witness in beat.alternateWitnesses {
                    groups[witness.group, default: []].append(Beat(span: beat.span, witness: witness))
                }
            }
        }
        var qualifying: (beats: [Beat], metrics: Metrics)?
        for group in groups.values {
            var through = from, seconds = 0.0
            for beat in group {
                let end = min(beat.span.end, to)
                seconds += max(0, end - max(through, beat.span.start))
                through = max(through, end)
            }
            guard seconds >= minimumSeconds else { continue }
            let within = group.prefix { $0.t < to }
            if let result = metrics(within, minBeats: minBeats) {
                guard qualifying == nil else { return nil }
                qualifying = (Array(within), result)
            }
        }
        return qualifying
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

    /// Metriche su una finestra contigua del flusso di battiti ordinato per tempo.
    public static func metrics<C: Collection>(_ b: C, minBeats: Int = 20) -> Metrics? where C.Element == Beat {
        guard let windowStart = b.first?.t else { return nil }
        var n = 0, sum = 0.0, sq = 0.0, nd = 0, dsq = 0.0, n50 = 0
        for x in b {
            n += 1; sum += x.ibi; sq += x.ibi * x.ibi
            if let d = x.diff, let predecessor = x.predecessorTime, predecessor >= windowStart {
                nd += 1; dsq += d * d; if abs(d) > 50 { n50 += 1 }
            }
        }
        guard n >= 2, n >= minBeats, nd > 0, nd >= minBeats * 3 / 4 else { return nil }
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
