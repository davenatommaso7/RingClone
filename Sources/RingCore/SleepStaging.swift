import Foundation

/// Parametri del modello di stadiazione. Sono priori fisiologici dichiarati, non valori addestrati:
/// vanno ri-stimati (EM o supervisionato) su notti con polisonnografia prima di qualunque uso serio.
public struct StagingModel: Sendable {
    /// medie delle feature [movimento, FC, lnRMSSD, instabilità FC] per stato (veglia, leggero, profondo, REM).
    /// Gli z-score sono relativi alla notte (in maggioranza sonno): gli stadi di sonno stanno vicino a 0,
    /// la veglia è la coda alta del movimento.
    public var mu: [[Double]] = [[2.5, 1.2, -0.8, 0.6], [0.0, 0.0, 0.0, 0.0], [-0.2, -0.9, 0.9, -0.7], [-0.1, 0.5, -0.4, 0.7]]
    public var sd: [[Double]] = [[1.5, 1.5, 1.2, 1.5], [1.0, 0.7, 0.8, 0.8], [0.8, 0.6, 0.7, 0.6], [0.9, 0.7, 0.8, 0.8]]
    /// probabilità di transizione ogni 30 s (da riga a colonna): profondo <-> REM diretti quasi impossibili
    public var trans: [[Double]] = [[0.90, 0.09, 0.001, 0.009], [0.02, 0.95, 0.02, 0.01],
                                    [0.01, 0.04, 0.949, 0.001], [0.02, 0.03, 0.001, 0.949]]
    public var start: [Double] = [0.70, 0.28, 0.01, 0.01]
    /// probabilità che lo stadio della sorgente esterna (Apple) coincida con quello vero
    public var externalAgreement = 0.75
    /// forza del priore "profondo nella prima metà, REM nella seconda"
    public var timeOfNight = 1.2
    /// passate di adattamento alla notte in esame (stima MAP delle medie e delle dispersioni a partire dai priori);
    /// 0 = usa solo i priori
    public var adaptPasses = 2
    /// peso dei priori nell'adattamento, espresso in numero di epoche equivalenti
    public var priorStrength = 120.0
    /// correzione costante (logaritmica, per epoca) della plausibilità di ogni stato: valori negativi rendono lo stato più raro.
    /// Serve a tenere le quote degli stadi in un intervallo fisiologico (le quattro osservazioni non sono indipendenti
    /// e, sommate, tendono a favorire lo stato con le dispersioni più strette).
    public var stageBias: [Double] = [0, 0, -0.2, 0]
    /// un singolo movimento che occupa una sola epoca in mezzo al sonno è un micro-risveglio, non una veglia:
    /// l'epoca resta nello stadio precedente (a meno che la sorgente esterna dica esplicitamente "sveglio")
    public var absorbSingleWakeEpochs = true
    public init() {}
    public static let standard = StagingModel()
}

/// Stadiazione a 4 classi con modello di Markov nascosto + algoritmo di Viterbi.
/// Osservazioni per epoca: movimento, FC, lnRMSSD, instabilità della FC (z-score robusti sulla notte),
/// più lo stadio di una sorgente esterna come osservazione rumorosa e un priore sul momento della notte.
public enum SleepStaging {
    public static func features(_ e: [Epoch], lnRMSSD: [Double?]) -> [[Double?]] {
        func cap(_ z: [Double?]) -> [Double?] { z.map { $0.map { Stats.clamp($0, -6, 6) } } }
        let hasMotion = e.contains { $0.motion > 0 }
        let motion: [Double?] = hasMotion ? cap(Stats.robustZ(e.map { log1p($0.motion) }, minScale: 0.25)) : e.map { _ in nil }
        let hr = cap(Stats.robustZ(e.map { $0.hr }, minScale: 1.5))
        let hrv = cap(Stats.robustZ(lnRMSSD, minScale: 0.1))
        let inst = cap(Stats.robustZ(Stats.rollingSD(hr, half: 6), minScale: 0.1))
        return e.indices.map { [motion[$0], hr[$0], $0 < hrv.count ? hrv[$0] : nil, inst[$0]] }
    }

    public static func stage(_ e: [Epoch], lnRMSSD: [Double?] = [], model: StagingModel = .standard) -> [SleepStage] {
        guard !e.isEmpty else { return [] }
        let x = features(e, lnRMSSD: lnRMSSD)
        var m = model
        var path = viterbi(e, x, m)
        // Adattamento alla persona e alla notte: le medie/dispersioni dei priori vengono corrette con i dati
        // assegnati a ciascuno stato (EM "rigido" con priori coniugati), poi si decodifica di nuovo.
        for _ in 0..<max(model.adaptPasses, 0) {
            for s in 0..<4 {
                for k in 0..<4 {
                    var n = 0.0, sum = 0.0
                    for i in e.indices where path[i] == s { if let v = x[i][k] { n += 1; sum += v } }
                    guard n > 0 else { continue }
                    let mu = (model.priorStrength * model.mu[s][k] + sum) / (model.priorStrength + n)
                    var ss = 0.0
                    for i in e.indices where path[i] == s { if let v = x[i][k] { ss += (v - mu) * (v - mu) } }
                    m.mu[s][k] = mu
                    m.sd[s][k] = max(((model.priorStrength * model.sd[s][k] * model.sd[s][k] + ss) / (model.priorStrength + n)).squareRoot(), 0.3)
                }
            }
            path = viterbi(e, x, m)
        }
        if model.absorbSingleWakeEpochs, path.count >= 3 {
            for i in 1..<(path.count - 1) where path[i] == 0 && path[i - 1] != 0 && path[i + 1] != 0 && e[i].appleStage != .wake {
                path[i] = path[i - 1]
            }
        }
        return path.map { SleepStage(rawValue: $0) ?? .light }
    }

    static func viterbi(_ e: [Epoch], _ x: [[Double?]], _ m: StagingModel) -> [Int] {
        let n = e.count
        let lt = m.trans.map { $0.map { log(max($0, 1e-6)) } }
        let agree = log(m.externalAgreement), disagree = log((1 - m.externalAgreement) / 3)
        // costanti delle gaussiane precalcolate
        let logSd = m.sd.map { $0.map { log($0) + 0.918_938_533_204_672_7 } }
        func emit(_ i: Int, _ s: Int) -> Double {
            var l = 0.0
            for k in 0..<4 {
                if let v = x[i][k] { let d = (v - m.mu[s][k]) / m.sd[s][k]; l += -0.5 * d * d - logSd[s][k] }
            }
            if let a = e[i].appleStage { l += a.rawValue == s ? agree : disagree }
            l += m.stageBias[s]
            let f = Double(i) / Double(max(n - 1, 1))
            if s == 2 { l += m.timeOfNight * (0.5 - f) }
            else if s == 3 { l += m.timeOfNight * (f - 0.5) - (i < 120 ? 1.0 : 0) }     // REM raro nella prima ora
            return l
        }
        var prev = (0..<4).map { log(m.start[$0]) + emit(0, $0) }
        var bp = [UInt8](repeating: 0, count: n * 4)
        var cur = [Double](repeating: 0, count: 4)
        if n > 1 {
            for i in 1..<n {
                for s in 0..<4 {
                    var best = -Double.infinity, arg = 0
                    for p in 0..<4 { let v = prev[p] + lt[p][s]; if v > best { best = v; arg = p } }
                    cur[s] = best + emit(i, s); bp[i * 4 + s] = UInt8(arg)
                }
                swap(&prev, &cur)
            }
        }
        var path = [Int](repeating: 0, count: n)
        path[n - 1] = (0..<4).max { prev[$0] < prev[$1] } ?? 0
        if n > 1 { for i in stride(from: n - 1, to: 0, by: -1) { path[i - 1] = Int(bp[i * 4 + path[i]]) } }
        return path
    }
}
