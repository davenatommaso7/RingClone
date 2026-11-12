import Foundation

/// Riassunto del movimento in un'epoca di 30 s, calcolato sul dispositivo che ha il sensore.
/// È il formato che viaggia dal Watch all'iPhone (≈ 2880 righe al giorno invece di 4,3 milioni di campioni).
public struct MotionEpoch: Codable, Sendable, Equatable {
    /// indice dell'epoca sulla griglia Unix: floor(tempo Unix / 30)
    public var index: Int
    /// Intensità del movimento in milli-g: deviazione assoluta media del modulo dell'accelerazione su finestre
    /// di 5 s (metrica MAD, Vähä-Ypyä et al. 2015). A differenza di |a| - 1 g non risente degli errori di
    /// calibrazione del sensore: a polso fermo vale ≈ rumore del sensore, qualunque sia l'orientamento.
    public var counts: Float
    /// massima variazione dell'angolo del braccio tra finestre consecutive di 5 s (gradi): rotazioni/cambi di postura
    public var angleChange: Float
    /// passi rilevati (riserva se il contapassi di sistema non è disponibile)
    public var steps: UInt16
    /// campioni ricevuti (per capire se l'epoca è completa)
    public var samples: UInt16
    /// velocità di rotazione media (gradi/s) se è disponibile il giroscopio
    public var rotation: Float?

    public init(index: Int, counts: Float, angleChange: Float, steps: UInt16, samples: UInt16, rotation: Float? = nil) {
        self.index = index; self.counts = counts; self.angleChange = angleChange
        self.steps = steps; self.samples = samples; self.rotation = rotation
    }
    public var start: Date { Date(timeIntervalSince1970: Double(index) * RingConst.epoch) }
}

/// Accumulatore in streaming: riceve i campioni grezzi uno alla volta e restituisce un'epoca quando si chiude.
/// Memoria costante (un buffer di 34 s per i passi), nessun array dell'intera registrazione.
public struct MotionAccumulator: Sendable {
    private let fs: Double
    private var index: Int?
    private var sumRot = 0.0, nRot = 0, n = 0
    // angolo del braccio (van Hees et al. 2015): media su 5 s dei tre assi, poi atan2(z, sqrt(x²+y²))
    private var win: Int?, wx = 0.0, wy = 0.0, wz = 0.0, wn = 0
    private var lastAngle: Double?, maxDelta = 0.0
    // passi: modulo dell'accelerazione dell'epoca corrente + coda di 4 s della precedente
    private var mag: [Double] = [], tail: [Double] = []

    public init(fs: Double = 50) {
        self.fs = fs
        mag.reserveCapacity(Int(fs * 32))
    }

    /// - Parameters:
    ///   - t: tempo Unix del campione (s)
    ///   - x, y, z: accelerazione in g
    ///   - rotationRate: modulo della velocità angolare in rad/s (giroscopio), se disponibile
    /// - Returns: l'epoca appena conclusa, se questo campione ne apre una nuova
    public mutating func add(t: Double, x: Double, y: Double, z: Double, rotationRate: Double? = nil) -> MotionEpoch? {
        let i = Int((t / RingConst.epoch).rounded(.down))
        var done: MotionEpoch?
        if let cur = index, cur != i {
            done = close()
            if i != cur + 1 { tail.removeAll(keepingCapacity: true); lastAngle = nil }   // buco: niente continuità
        }
        index = i
        let m = (x * x + y * y + z * z).squareRoot()
        n += 1
        if let r = rotationRate { sumRot += r * 180 / .pi; nRot += 1 }
        mag.append(m)

        let w = Int((t / 5).rounded(.down))
        if let cw = win, cw != w { closeAngleWindow() }
        win = w
        wx += x; wy += y; wz += z; wn += 1
        return done
    }

    /// chiude l'epoca in corso (a fine registrazione)
    public mutating func flush() -> MotionEpoch? { index == nil ? nil : close() }

    private mutating func closeAngleWindow() {
        guard wn > 0 else { return }
        let ax = wx / Double(wn), ay = wy / Double(wn), az = wz / Double(wn)
        let angle = atan2(az, (ax * ax + ay * ay).squareRoot()) * 180 / .pi
        if let l = lastAngle { maxDelta = max(maxDelta, abs(angle - l)) }
        lastAngle = angle
        wx = 0; wy = 0; wz = 0; wn = 0
    }

    private mutating func close() -> MotionEpoch? {
        guard let i = index, n > 0 else { return nil }
        closeAngleWindow()
        let buf = tail + mag
        let steps = Activity.detectSteps(mag: buf, fs: fs).filter { $0 >= tail.count }.count
        // MAD su blocchi di 5 s
        let block = max(Int(5 * fs), 1)
        var madSum = 0.0, blocks = 0, a = 0
        while a < mag.count {
            let b = min(a + block, mag.count)
            if b - a >= block / 2 || blocks == 0 {
                var mean = 0.0
                for k in a..<b { mean += mag[k] }
                mean /= Double(b - a)
                var dev = 0.0
                for k in a..<b { dev += abs(mag[k] - mean) }
                madSum += dev / Double(b - a); blocks += 1
            }
            a = b
        }
        let e = MotionEpoch(index: i, counts: Float(1000 * madSum / Double(max(blocks, 1))), angleChange: Float(maxDelta),
                            steps: UInt16(clamping: steps), samples: UInt16(clamping: n),
                            rotation: nRot > 0 ? Float(sumRot / Double(nRot)) : nil)
        tail = Array(mag.suffix(Int(4 * fs)))
        mag.removeAll(keepingCapacity: true)
        sumRot = 0; nRot = 0; n = 0; maxDelta = 0
        index = nil
        return e
    }
}
