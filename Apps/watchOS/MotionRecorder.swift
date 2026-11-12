import Foundation
import CoreMotion
import RingCore

extension CMSensorDataList: @retroactive Sequence {
    public func makeIterator() -> NSFastEnumerationIterator { NSFastEnumerationIterator(self) }
}

/// Movimento del polso 24 ore su 24.
///
/// `CMSensorRecorder` fa registrare al sistema l'accelerometro a 50 Hz anche ad app chiusa (fino a 12 ore per
/// richiesta, dati conservati 3 giorni). Quando l'app viene svegliata legge i campioni arretrati e li riduce
/// sul Watch a epoche di 30 s (`MotionEpoch`: intensità, cambi di postura, passi): circa 2880 righe al giorno
/// invece di 4,3 milioni di campioni. Il punto di ripresa è salvato, quindi nessun intervallo viene saltato
/// o contato due volte.
final class MotionRecorder: @unchecked Sendable {
    static let shared = MotionRecorder()

    private let recorder = CMSensorRecorder()
    private let queue = DispatchQueue(label: "it.ringclone.motion", qos: .utility)
    private let cursorKey = "motionCursor"
    private static let retention: TimeInterval = 3 * 86_400
    private static let slice: TimeInterval = 15 * 60                 // lettura a blocchi: memoria limitata

    private init() {}

    static var isAvailable: Bool { CMSensorRecorder.isAccelerometerRecordingAvailable() }

    /// istante (multiplo di 30 s) fino a cui i campioni sono già stati elaborati
    private var cursor: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: cursorKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: cursorKey) }
    }

    /// Chiede al sistema altre 12 ore di registrazione. Va richiamata a ogni risveglio: le richieste si sovrappongono
    /// senza problemi e così la registrazione non si interrompe mai. La prima volta compare la richiesta di permesso.
    func arm() {
        guard Self.isAvailable else { return }
        queue.async { self.recorder.recordAccelerometer(forDuration: 12 * 3600) }
    }

    /// Elabora i campioni arretrati e li mette in coda verso l'iPhone.
    /// - Parameters:
    ///   - maxSpan: quanta registrazione elaborare al massimo in questa chiamata (in background il tempo è poco)
    ///   - completion: chiamata al termine, su una coda di servizio
    func process(maxSpan: TimeInterval = 4 * 3600, now: Date = Date(), completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            self.run(maxSpan: maxSpan, now: now)
            completion?()
        }
    }

    private func run(maxSpan: TimeInterval, now: Date) {
        guard Self.isAvailable else { return }
        let ep = RingConst.epoch
        // i campioni possono arrivare con qualche minuto di ritardo: ci si ferma 3 minuti prima di adesso
        let limit = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 - 180) / ep).rounded(.down) * ep)
        let oldest = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 - Self.retention) / ep).rounded(.up) * ep)
        // primo avvio: si parte da adesso (prima non c'era nessuna registrazione in corso)
        guard let saved = cursor else { cursor = limit; return }
        var from = max(saved, oldest)
        let end = min(limit, from.addingTimeInterval(maxSpan))
        guard end > from else { return }

        var acc = MotionAccumulator(fs: 50)
        var out: [MotionEpoch] = []
        var lastT = from.timeIntervalSince1970 - 1
        while from < end {
            let to = min(from.addingTimeInterval(Self.slice), end)
            if let list = recorder.accelerometerData(from: from, to: to) {
                for case let d as CMRecordedAccelerometerData in list {
                    let t = d.startDate.timeIntervalSince1970
                    // scarta doppioni e campioni fuori dal blocco richiesto
                    guard t > lastT, t >= from.timeIntervalSince1970, t < to.timeIntervalSince1970 else { continue }
                    lastT = t
                    let a = d.acceleration
                    if let e = acc.add(t: t, x: a.x, y: a.y, z: a.z) { out.append(e) }
                }
            }
            from = to
        }
        if let e = acc.flush() { out.append(e) }
        // pacchetti da 2 ore al massimo: file piccoli, reinvio poco costoso
        var i = 0
        while i < out.count {
            let j = min(i + 240, out.count)
            WatchLink.shared.enqueue(Array(out[i..<j]))
            i = j
        }
        cursor = end
    }
}

/// Accelerazione e rotazione ad alta frequenza durante un allenamento.
///
/// Il giroscopio non è registrabile in background: `CMBatchedSensorManager` lo fornisce solo mentre è attiva una
/// sessione di allenamento. Le epoche prodotte qui contengono anche la velocità di rotazione media e sostituiscono
/// nell'archivio dell'iPhone quelle a 50 Hz dello stesso intervallo (vince l'epoca con più campioni).
final class WorkoutMotion: @unchecked Sendable {
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil, CMBatchedSensorManager.isDeviceMotionSupported else { return }
        task = Task.detached(priority: .utility) {
            let manager = CMBatchedSensorManager()
            // i campioni portano il tempo dall'accensione: si converte in tempo Unix
            let bootOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
            let fs = Double(max(manager.deviceMotionDataFrequency, 50))
            var acc = MotionAccumulator(fs: fs)
            var out: [MotionEpoch] = []
            // le epoche incomplete (inizio e fine sessione) si scartano: per quei 30 s resta valida quella a 50 Hz
            let minSamples = 0.9 * fs * RingConst.epoch
            do {
                for try await batch in manager.deviceMotionUpdates() {
                    for m in batch {
                        let g = m.gravity, u = m.userAcceleration, r = m.rotationRate
                        let rot = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
                        if let e = acc.add(t: bootOffset + m.timestamp, x: g.x + u.x, y: g.y + u.y, z: g.z + u.z, rotationRate: rot),
                           Double(e.samples) >= minSamples {
                            out.append(e)
                        }
                    }
                    if out.count >= 20 {                              // ogni 10 minuti circa
                        WatchLink.shared.enqueue(out)
                        out.removeAll()
                    }
                    if Task.isCancelled { break }
                }
            } catch {
                // sensore non disponibile o sessione terminata: si consegna quello che c'è
            }
            if let e = acc.flush(), Double(e.samples) >= minSamples { out.append(e) }
            if !out.isEmpty { WatchLink.shared.enqueue(out) }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
