import Foundation

public struct SleepPeriods: Sendable {
    /// periodo principale come intervallo di indici di epoca [inizio, fine)
    public var main: Range<Int>?
    public var naps: [Range<Int>]
    /// "apple" se il periodo principale viene da HealthKit, "sensori" se da movimento + FC
    public var source: String
    /// Epoche di sonno nei sonnellini, al netto dei buchi tra i tratti della stessa sessione.
    var napSleepEpochs = 0
    /// Contesto di movimento effettivamente osservato attorno al periodo principale da sensori.
    var mainObservation: Range<Int>? = nil
    var observedBed = false
    var appleStages: [ReportedSleepStage?] = []
    var appleContext: [Bool] = []
    var estimatedNapSleep: [Range<Int>] = []
}

/// Individua il periodo di sonno principale e i sonnellini sulla finestra di epoche.
/// Priorità alle sessioni di sonno già registrate (Apple Salute); altrimenti immobilità prolungata + FC bassa.
public enum SleepDetection {
    static let minMain = 360          // 3 h
    static let napRange = 30...360    // 15 min - 3 h

    /// - Parameters:
    ///   - mainEnd: il sonno principale deve terminare in questo intervallo (la notte "appartiene" al giorno del risveglio)
    ///   - napWindow: i sonnellini devono iniziare in questo intervallo (giorno di calendario)
    public static func detect(_ e: [Epoch], apple: [SleepSegment], mainEnd: ClosedRange<Date>, napWindow: Range<Date>) -> SleepPeriods {
        guard let t0 = e.first?.start else { return SleepPeriods(main: nil, naps: [], source: "sensori") }
        let n = e.count
        func idx(_ d: Date) -> Int { Int((d.timeIntervalSince(t0) / RingConst.epoch).rounded()) }
        func date(_ i: Int) -> Date { t0.addingTimeInterval(Double(i) * RingConst.epoch) }
        func overlaps(_ a: Range<Int>, _ b: Range<Int>, margin: Int = 0) -> Bool {
            a.lowerBound < b.upperBound + margin && b.lowerBound - margin < a.upperBound
        }

        // 1) sessioni Apple: segmenti con stadio, uniti se separati da meno di 30 min
        var appleStages = [ReportedSleepStage?](repeating: nil, count: n)
        var appleContext = [Bool](repeating: false, count: n)
        var observedBeds: [Range<Int>] = []
        for s in apple where s.start < s.end {
            let a = max(0, idx(s.start)), b = min(n, idx(s.end))
            guard a < b else { continue }
            for i in a..<b { appleContext[i] = true }
            guard let stage = s.reportedStage else {
                if s.start >= t0, s.end <= date(n) { observedBeds.append(a..<b) }
                continue
            }
            for i in a..<b {
                if let previous = appleStages[i], previous != stage {
                    appleStages[i] = previous.isSleep && stage.isSleep ? .asleepUnspecified : .unknown
                } else {
                    appleStages[i] = stage
                }
            }
        }
        let staged = Stats.runs(appleStages.map { $0 != nil && $0 != .unknown })
        let sessions = Stats.merge(staged, maxGap: 60).map { range in
            for i in range { appleContext[i] = true }
            return (range: range, asleep: appleStages[range].filter { $0?.isSleep == true }.count)
        }
        let appleMain = sessions.filter { $0.asleep >= minMain && mainEnd.contains(date($0.range.upperBound)) }
            .max { $0.asleep < $1.asleep }?.range
        let appleNaps = sessions.filter { s in
            napRange.contains(s.asleep) && napWindow.contains(date(s.range.lowerBound)) && (appleMain.map { !overlaps(s.range, $0) } ?? true)
        }
        var naps = appleNaps.map { $0.range }
        var napSleepEpochs = appleNaps.map { $0.asleep }.reduce(0, +)
        var estimatedNapSleep: [Range<Int>] = []
        let bed = appleMain.flatMap { main in
            observedBeds.filter { candidate in
                candidate.lowerBound <= main.lowerBound && candidate.upperBound >= main.upperBound &&
                    !sessions.contains { $0.range != main && overlaps($0.range, candidate) }
            }.min { a, b in a.count == b.count ? a.lowerBound < b.lowerBound : a.count < b.count }
        }

        // 2) sensori: candidati = polso fermo + FC bassa, con orologio indossato
        let worn = e.map { $0.hr != nil }
        let hrs = e.compactMap { $0.hr }
        let useHR = Double(hrs.count) >= 0.2 * Double(n)
        let hrCeil = useHR ? Stats.median(hrs) + 2 : Double.infinity
        let motion = e.map(\.observedMotion)
        let counts = motion.compactMap { $0 }
        let angles = e.indices.filter { motion[$0] != nil && e[$0].angleChange?.isFinite == true }.count
        let hasAngle = Double(angles) >= 0.5 * Double(counts.count)
        let ref = e.indices.filter { !useHR || worn[$0] }.compactMap { motion[$0] }
        let thr = max(Stats.percentile(ref.isEmpty ? counts : ref, 40), 1e-6)
        var candidates = [Bool](repeating: false, count: n)
        let observedRuns = Stats.runs(motion.map { $0 != nil })
        let observedBouts = observedRuns.map { observed -> (observed: Range<Int>, bouts: [Range<Int>]) in
            // La media e le unioni si fermano dove manca l'osservazione di movimento.
            let smooth = Stats.rollingMean(motion[observed].compactMap { $0 }, half: 10) // ±5 min
            let local = observed.enumerated().map { offset, i -> Bool in
                guard !useHR || (worn[i] && e[i].hr! <= hrCeil) else { return false }
                // con l'angolo del braccio: nessuna rotazione > 5° (van Hees 2015); altrimenti soglia adattiva sul movimento
                if hasAngle, let a = e[i].angleChange, a.isFinite { return a < 5 && smooth[offset] <= 3 * thr }
                return smooth[offset] <= thr
            }
            candidates.replaceSubrange(observed, with: local)
            // Un breve movimento osservato (≤ 1 min) non interrompe il tratto; servono almeno 10 min.
            let bouts = Stats.merge(Stats.runs(local), maxGap: 2).filter { $0.count >= 20 }.map {
                ($0.lowerBound + observed.lowerBound)..<($0.upperBound + observed.lowerBound)
            }
            return (observed: observed, bouts: bouts)
        }
        let sensorMain = observedBouts.flatMap { part in
            Stats.merge(part.bouts, maxGap: 60).map { (range: $0, observation: part.observed) }
        }.filter { $0.range.count >= minMain && mainEnd.contains(date($0.range.upperBound)) }
            .max { $0.range.count < $1.range.count }
        let main = bed ?? appleMain ?? sensorMain?.range

        // sonnellini dai sensori: tratti brevi, molto fermi, con FC vicina a quella del sonno
        var napCeil = useHR ? Stats.percentile(hrs, 25) : Double.infinity
        if let m = main {
            let mh = e[m].compactMap { $0.hr }
            if mh.count >= 20 { napCeil = Stats.mean(mh) * 1.12 }
        }
        let napBouts = observedBouts.flatMap { Stats.merge($0.bouts, maxGap: 10) }
        for b in napBouts where napRange.contains(b.count) && napWindow.contains(date(b.lowerBound)) {
            if let m = main, overlaps(b, m, margin: 60) { continue }
            if naps.contains(where: { overlaps(b, $0, margin: 20) }) || sessions.contains(where: { overlaps(b, $0.range, margin: 20) }) { continue }
            let h = e[b].compactMap { $0.hr }
            if useHR && (h.count < b.count / 2 || Stats.mean(h) > napCeil) { continue }
            let quiet = motion[b].compactMap { $0 }.filter { $0 <= thr }.count
            guard Double(quiet) >= 0.85 * Double(b.count) else { continue }
            naps.append(b)
            let runs = Stats.runs(Array(candidates[b]))
            napSleepEpochs += runs.map(\.count).reduce(0, +)
            estimatedNapSleep += runs.map { ($0.lowerBound + b.lowerBound)..<($0.upperBound + b.lowerBound) }
        }
        naps.sort { $0.lowerBound < $1.lowerBound }
        return SleepPeriods(main: main, naps: naps, source: appleMain != nil ? "apple" : "sensori",
                            napSleepEpochs: napSleepEpochs, mainObservation: appleMain == nil ? sensorMain?.observation : nil,
                            observedBed: bed != nil, appleStages: appleStages, appleContext: appleContext,
                            estimatedNapSleep: estimatedNapSleep)
    }
}
