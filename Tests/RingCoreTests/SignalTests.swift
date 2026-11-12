import XCTest
@testable import RingCore

final class SignalTests: XCTestCase {
    /// Onda fotopletismografica sintetica: salita rapida, discesa lenta con incisura dicrota, deriva e rumore
    static func ppg(beats: [Double], fs: Double, seconds: Double, noise: Double, seed: UInt64) -> [Double] {
        var rng = SeededRNG(seed: seed)
        let n = Int(seconds * fs)
        var x = [Double](repeating: 0, count: n)
        for b in beats {
            let a = max(Int((b - 0.3) * fs), 0), z = min(Int((b + 0.9) * fs), n - 1)
            guard a < z else { continue }
            for i in a...z {
                let t = Double(i) / fs - b
                x[i] += exp(-pow(t / (t < 0 ? 0.07 : 0.16), 2)) + 0.25 * exp(-pow((t - 0.32) / 0.09, 2))
            }
        }
        for i in 0..<n {
            let t = Double(i) / fs
            x[i] = 1000 + 40 * x[i] + 60 * sin(2 * .pi * 0.05 * t) + noise * rng.normal()
        }
        return x
    }

    static func beatTrain(hr: Double, resp: Double, seconds: Double, seed: UInt64) -> [Double] {
        var rng = SeededRNG(seed: seed)
        var t = 1.0, out: [Double] = []
        while t < seconds - 1 {
            out.append(t)
            t += 60 / hr * (1 + 0.05 * sin(2 * .pi * resp / 60 * t)) + 0.003 * rng.normal()
        }
        return out
    }

    func testPPGBeatDetection() throws {
        let truth = Self.beatTrain(hr: 62, resp: 15, seconds: 180, seed: 3)
        let x = Self.ppg(beats: truth, fs: 50, seconds: 180, noise: 2, seed: 4)
        let r = PPG.detectBeats(x, fs: 50)
        XCTAssertFalse(r.inverted)
        XCTAssertLessThanOrEqual(abs(r.beatTimes.count - truth.count), 2)
        XCTAssertGreaterThan(r.sqi, 0.9)
        // errore sugli intervalli battito-battito
        func ibi(_ t: [Double]) -> [Double] { zip(t.dropFirst(), t).map { ($0 - $1) * 1000 } }
        let est = try XCTUnwrap(HRV.metrics(HRV.beats(from: r.series(start: Date(timeIntervalSince1970: 0)))))
        let ref = try XCTUnwrap(HRV.metrics(ibiMs: ibi(truth)))
        XCTAssertEqual(est.meanNN, ref.meanNN, accuracy: 3)
        XCTAssertEqual(est.rmssd, ref.rmssd, accuracy: 0.2 * ref.rmssd)
        XCTAssertEqual(try XCTUnwrap(PPG.heartRate(r)), 62, accuracy: 1.5)
        // respiro dall'aritmia sinusale
        let resp = try XCTUnwrap(HRV.respiratoryRate(HRV.beats(from: r.series(start: Date(timeIntervalSince1970: 0)))))
        XCTAssertEqual(resp.rate, 15, accuracy: 1)
    }

    func testPPGInvertedSignalIsHandled() {
        let truth = Self.beatTrain(hr: 70, resp: 14, seconds: 120, seed: 5)
        let x = Self.ppg(beats: truth, fs: 50, seconds: 120, noise: 2, seed: 6).map { 2000 - $0 }
        let r = PPG.detectBeats(x, fs: 50)
        XCTAssertTrue(r.inverted)
        XCTAssertLessThanOrEqual(abs(r.beatTimes.count - truth.count), 2)
    }

    func testRMSSDKnownValueAndEctopicBeat() throws {
        // intervalli alternati 800/850 ms: differenze successive sempre di 50 ms
        var ibi: [Double] = []
        for k in 0..<200 { ibi.append(k % 2 == 0 ? 800 : 850) }
        let clean = try XCTUnwrap(HRV.metrics(ibiMs: ibi))
        XCTAssertEqual(clean.rmssd, 50, accuracy: 0.01)
        XCTAssertEqual(clean.meanNN, 825, accuracy: 0.5)
        // un'extrasistole (battito anticipato + pausa compensatoria) va scartata senza creare differenze finte
        var ect = ibi
        ect[100] = 450; ect[101] = 1200
        let m = try XCTUnwrap(HRV.metrics(ibiMs: ect))
        XCTAssertEqual(m.rmssd, 50, accuracy: 1.0)
        XCTAssertEqual(m.n, 198)
    }

    func testGapBetweenSeriesIsNotADifference() {
        let a = IBISeries(start: Date(timeIntervalSince1970: 0), ibiMs: [Double](repeating: 1000, count: 40))
        let b = IBISeries(start: Date(timeIntervalSince1970: 600), ibiMs: [Double](repeating: 700, count: 40))
        let beats = HRV.beats(from: [b, a])
        XCTAssertEqual(beats.count, 80)
        XCTAssertEqual(beats.filter { $0.diff == nil }.count, 2)          // il primo di ciascuna serie
        XCTAssertEqual(HRV.metrics(beats)?.rmssd ?? -1, 0, accuracy: 1e-9)  // nessun salto 1000 -> 700
    }

    func testZones() {
        let b = HeartRate.zoneBounds(model: .percentMax, rhr: 60, hrMax: 190)
        XCTAssertEqual(b, [95, 114, 133, 152, 171, 190])
        XCTAssertEqual(HeartRate.zone(of: 94.9, bounds: b), 0)
        XCTAssertEqual(HeartRate.zone(of: 95, bounds: b), 1)
        XCTAssertEqual(HeartRate.zone(of: 114, bounds: b), 2)             // il limite appartiene alla zona superiore
        XCTAssertEqual(HeartRate.zone(of: 170.99, bounds: b), 4)
        XCTAssertEqual(HeartRate.zone(of: 205, bounds: b), 5)
        let k = HeartRate.zoneBounds(model: .karvonen, rhr: 60, hrMax: 190)
        XCTAssertEqual(k[0], 125, accuracy: 1e-9)
        // campioni irregolari: 60 s a 120 bpm (ogni 5 s) + un campione isolato a 180 bpm dopo 10 min
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var s = (0..<12).map { TimedValue(date: t0.addingTimeInterval(Double($0) * 5), value: 120) }
        s.append(TimedValue(date: t0.addingTimeInterval(660), value: 180))
        let z = HeartRate.zoneMinutes(samples: s, bounds: b)
        XCTAssertEqual(z[1], 55.0 / 60 + 15.0 / 60, accuracy: 1e-9)       // l'ultimo campione vale al massimo 15 s
        XCTAssertEqual(z[4], 5.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(HeartRate.trimp([10, 10, 10, 10, 10]), 150)
        XCTAssertEqual(HeartRate.tanaka(age: 40), 180)
    }

    func testHRMaxUsesObservedPeaksRobustly() {
        let p = UserProfile(age: 40, sex: .male, heightCm: 178, weightKg: 75)
        XCTAssertEqual(HeartRate.hrMax(profile: p, workoutPeaks: []).value, 180)
        XCTAssertFalse(HeartRate.hrMax(profile: p, workoutPeaks: [150, 155, 160]).measured)
        let m = HeartRate.hrMax(profile: p, workoutPeaks: [186, 188, 230.5, 184])   // 230,5 = artefatto, ignorato
        XCTAssertEqual(m.value, 186)
        XCTAssertTrue(m.measured)
        var q = p; q.hrMaxOverride = 192
        XCTAssertEqual(HeartRate.hrMax(profile: q, workoutPeaks: [186, 188, 184]).value, 192)
    }

    /// Accelerometro sintetico al polso: gravità + oscillazione del passo
    static func accel(seconds: Double, fs: Double, cadenceHz: Double, amp: Double, seed: UInt64) -> [(Double, Double, Double)] {
        var rng = SeededRNG(seed: seed)
        return (0..<Int(seconds * fs)).map { i in
            let t = Double(i) / fs
            let s = cadenceHz > 0 ? amp * (sin(2 * .pi * cadenceHz * t) + 0.3 * sin(4 * .pi * cadenceHz * t)) : 0
            return (0.02 * rng.normal() * 0.1, 0.01 * rng.normal() * 0.1, -1 - s + 0.002 * rng.normal())
        }
    }

    func testStepDetection() {
        let walk = Self.accel(seconds: 60, fs: 50, cadenceHz: 1.9, amp: 0.25, seed: 1)
        let steps = Activity.detectSteps(mag: walk.map { ($0.0 * $0.0 + $0.1 * $0.1 + $0.2 * $0.2).squareRoot() }, fs: 50)
        XCTAssertEqual(Double(steps.count), 114, accuracy: 5)
        let still = Self.accel(seconds: 60, fs: 50, cadenceHz: 0, amp: 0, seed: 2)
        XCTAssertEqual(Activity.detectSteps(mag: still.map { abs($0.2) }, fs: 50).count, 0)
        // tre gesti isolati non sono una camminata
        var g = still.map { abs($0.2) }
        for k in [500, 1400, 2300] { for j in 0..<10 { g[k + j] += 0.4 * sin(Double(j) / 10 * .pi) } }
        XCTAssertEqual(Activity.detectSteps(mag: g, fs: 50).count, 0)
    }

    func testMotionAccumulatorStreaming() {
        var acc = MotionAccumulator(fs: 50)
        var out: [MotionEpoch] = []
        let t0 = 1_800_000_000.0                                   // multiplo di 30 s
        let walk = Self.accel(seconds: 150, fs: 50, cadenceHz: 1.9, amp: 0.25, seed: 9)
        let still = Self.accel(seconds: 150, fs: 50, cadenceHz: 0, amp: 0, seed: 10)
        for (i, s) in (walk + still).enumerated() {
            // nel tratto fermo, a metà, il polso ruota di 90° (cambio di posizione)
            let rotated = i >= 11_000
            let v = rotated ? (s.2, s.1, s.0) : s
            if let e = acc.add(t: t0 + Double(i) / 50, x: v.0, y: v.1, z: v.2) { out.append(e) }
        }
        if let e = acc.flush() { out.append(e) }
        XCTAssertEqual(out.count, 10)
        XCTAssertEqual(out.map { $0.index }, Array((Int(t0) / 30)..<(Int(t0) / 30 + 10)))
        XCTAssertEqual(out.allSatisfy { $0.samples == 1500 }, true)
        let steps = out.map { Int($0.steps) }.reduce(0, +)
        XCTAssertEqual(Double(steps), 285, accuracy: 12)           // 150 s x 1,9 passi/s, contati una sola volta tra epoche
        XCTAssertGreaterThan(out[2].counts, 100)                   // cammino: movimento intenso
        XCTAssertLessThan(out[6].counts, 5)                        // fermo: solo rumore del sensore
        XCTAssertLessThan(out[6].angleChange, 2)
        XCTAssertGreaterThan(out[7].angleChange, 60)               // rotazione del polso
        XCTAssertLessThan(out[9].angleChange, 2)
    }

    func testTemperatureNight() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var s: [TimedValue] = []
        for k in 0..<240 {                                          // 8 ore, un campione ogni 2 min
            let h = Double(k) / 30
            s.append(TimedValue(date: t0.addingTimeInterval(Double(k) * 120), value: 35 - 0.5 * exp(-pow((h - 5.5) / 1.2, 2)) - (h < 0.3 ? 1 : 0)))
        }
        let n = try XCTUnwrap(Temperature.night(series: s, sleepStart: t0, sleepEnd: t0.addingTimeInterval(8 * 3600)))
        XCTAssertEqual(n.value, 35, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(n.minimumAt).timeIntervalSince(t0) / 3600, 5.5, accuracy: 0.2)
    }

    func testMotionArchivePersistsAndDeduplicates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ring-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = 60_000_000
        let chunk = MotionChunk(epochs: (0..<100).map { MotionEpoch(index: base + $0, counts: Float($0), angleChange: 1, steps: 3, samples: 1500) })
        let data = try chunk.encoded()
        let a = MotionArchive(directory: dir)
        a.merge(try MotionChunk.decode(data).epochs)
        a.merge(chunk.epochs)                                       // reinvio: nessun duplicato
        a.merge([MotionEpoch(index: base + 5, counts: 999, angleChange: 0, steps: 0, samples: 700)])   // epoca parziale: non sostituisce
        let from = Date(timeIntervalSince1970: Double(base) * 30), to = Date(timeIntervalSince1970: Double(base + 100) * 30)
        XCTAssertEqual(a.epochs(from: from, to: to).count, 100)
        let b = MotionArchive(directory: dir)                       // nuova istanza: rilegge da disco
        let e = b.epochs(from: from, to: to)
        XCTAssertEqual(e.count, 100)
        XCTAssertEqual(e[5].counts, 5)
        XCTAssertEqual(b.epochs(from: from.addingTimeInterval(300), to: from.addingTimeInterval(600)).count, 10)
        b.prune(olderThan: 1, now: to.addingTimeInterval(10 * 86_400))
        XCTAssertEqual(MotionArchive(directory: dir).epochs(from: from, to: to).count, 0)
    }
}
