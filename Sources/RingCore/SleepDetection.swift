import Foundation

public struct SleepPeriods: Sendable {
    /// periodo principale come intervallo di indici di epoca [inizio, fine)
    public var main: Range<Int>?
    public var naps: [Range<Int>]
    /// "apple" se il periodo principale viene da HealthKit, "sensori" se da movimento + FC
    public var source: String
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
        var sessions: [(range: Range<Int>, asleep: Int)] = []
        for s in apple.filter({ $0.stage != nil }).sorted(by: { $0.start < $1.start }) {
            let a = max(0, idx(s.start)), b = min(n, idx(s.end))
            guard a < b else { continue }
            let sl = s.stage!.isSleep ? b - a : 0
            if let l = sessions.last, a - l.range.upperBound <= 60 {
                sessions[sessions.count - 1] = (l.range.lowerBound..<max(l.range.upperBound, b), l.asleep + sl)
            } else { sessions.append((a..<b, sl)) }
        }
        let appleMain = sessions.filter { $0.asleep >= minMain && mainEnd.contains(date($0.range.upperBound)) }
            .max { $0.asleep < $1.asleep }?.range
        var naps = sessions.filter { s in
            napRange.contains(s.asleep) && napWindow.contains(date(s.range.lowerBound)) && (appleMain.map { !overlaps(s.range, $0) } ?? true)
        }.map { $0.range }

        // 2) sensori: candidati = polso fermo + FC bassa, con orologio indossato
        let worn = e.map { $0.hr != nil }
        let hrs = e.compactMap { $0.hr }
        let useHR = Double(hrs.count) >= 0.2 * Double(n)
        let hrCeil = useHR ? Stats.median(hrs) + 2 : Double.infinity
        let hasAngle = Double(e.filter { $0.angleChange != nil }.count) >= 0.5 * Double(n)
        let counts = e.map { $0.motion }
        let hasMotion = counts.contains { $0 > 0 }
        var bouts: [Range<Int>] = []
        var thr = 0.0
        if hasMotion {
            let smooth = Stats.rollingMean(counts, half: 10)                          // ±5 min
            let ref = e.indices.filter { !useHR || worn[$0] }.map { counts[$0] }
            thr = max(Stats.percentile(ref.isEmpty ? counts : ref, 40), 1e-6)
            let cand = e.indices.map { i -> Bool in
                guard !useHR || (worn[i] && e[i].hr! <= hrCeil) else { return false }
                // con l'angolo del braccio: nessuna rotazione > 5° (van Hees 2015); altrimenti soglia adattiva sul movimento
                if hasAngle, let a = e[i].angleChange { return a < 5 && smooth[i] <= 3 * thr }
                return smooth[i] <= thr
            }
            // un singolo movimento (≤ 1 min) non interrompe il tratto; servono almeno 10 min
            bouts = Stats.merge(Stats.runs(cand), maxGap: 2).filter { $0.count >= 20 }
        }
        let merged = Stats.merge(bouts, maxGap: 60)                                    // buchi ≤ 30 min
        let sensorMain = merged.filter { $0.count >= minMain && mainEnd.contains(date($0.upperBound)) }.max { $0.count < $1.count }
        let main = appleMain ?? sensorMain

        // sonnellini dai sensori: tratti brevi, molto fermi, con FC vicina a quella del sonno
        var napCeil = useHR ? Stats.percentile(hrs, 25) : Double.infinity
        if let m = main {
            let mh = e[m].compactMap { $0.hr }
            if mh.count >= 20 { napCeil = Stats.mean(mh) * 1.12 }
        }
        for b in Stats.merge(bouts, maxGap: 10) where napRange.contains(b.count) && napWindow.contains(date(b.lowerBound)) {
            if let m = main, overlaps(b, m, margin: 60) { continue }
            if naps.contains(where: { overlaps(b, $0, margin: 20) }) || sessions.contains(where: { overlaps(b, $0.range, margin: 20) }) { continue }
            let h = e[b].compactMap { $0.hr }
            if useHR && (h.count < b.count / 2 || Stats.mean(h) > napCeil) { continue }
            let quiet = e[b].filter { $0.motion <= thr }.count
            guard Double(quiet) >= 0.85 * Double(b.count) else { continue }
            naps.append(b)
        }
        naps.sort { $0.lowerBound < $1.lowerBound }
        return SleepPeriods(main: main, naps: naps, source: appleMain != nil ? "apple" : "sensori")
    }
}
