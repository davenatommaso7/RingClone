import Foundation

public enum SleepMetrics {
    static let ep = RingConst.epoch / 60

    /// lnRMSSD per epoca su una finestra di ±2,5 min del flusso di battiti (nil se i battiti sono troppo pochi)
    public static func lnRMSSDPerEpoch(_ e: [Epoch], beats: [Beat]) -> [Double?] {
        guard !beats.isEmpty else { return e.map { _ in nil } }
        return e.map { x in
            let c = x.start.timeIntervalSinceReferenceDate + RingConst.epoch / 2
            let r = HRV.range(beats, from: c - 150, to: c + 150)
            guard let m = HRV.metrics(beats[r], minBeats: 60), m.rmssd > 0 else { return nil }
            return log(m.rmssd)
        }
    }

    /// Metriche della notte secondo le definizioni AASM:
    /// TIB = tempo a letto, TST = tempo di sonno, SOL = latenza di addormentamento, WASO = veglia dopo l'addormentamento,
    /// efficienza = TST / TIB. `e` e `stages` coprono lo stesso periodo a letto.
    public static func night(_ e: [Epoch], stages st: [SleepStage], beats: [Beat], calendar cal: Calendar,
                             tempSeries: [TimedValue] = [], tempNight: Double? = nil,
                             respRate hkResp: Double? = nil, spo2: Double? = nil) -> NightReport? {
        let n = e.count
        guard n > 0, st.count == n else { return nil }
        let asleep = st.map { $0.isSleep }
        // addormentamento = primo tratto con almeno 18 epoche di sonno su 20 (10 min quasi continui)
        var pre = [Int](repeating: 0, count: n + 1)
        for i in 0..<n { pre[i + 1] = pre[i] + (asleep[i] ? 1 : 0) }
        guard let onset = (0..<n).first(where: { i in
            let j = min(i + 20, n)
            return asleep[i] && pre[j] - pre[i] >= min(18, (j - i) * 9 / 10)
        }), let last = asleep.lastIndex(of: true), last > onset else { return nil }

        let core = Array(st[onset...last])
        let tst = Double(core.filter { $0.isSleep }.count) * ep
        guard tst >= 30 else { return nil }
        let wakeRuns = Stats.runs(core.map { $0 == .wake })
        let waso = Double(wakeRuns.map { $0.count }.reduce(0, +)) * ep
        let awak = wakeRuns.filter { $0.count >= 2 }.count                              // risveglio ≥ 1 min
        let longest = Double(Stats.runs(core.map { $0.isSleep }).map { $0.count }.max() ?? 0) * ep
        var shifts = 0
        for i in 1..<core.count where core[i] != core[i - 1] { shifts += 1 }
        func minutes(_ s: SleepStage) -> Double { Double(core.filter { $0 == s }.count) * ep }
        let remLat = core.firstIndex(of: .rem).map { Double($0) * ep }

        // cicli = episodi di REM (tratti REM separati da meno di 15 min contano come uno, durata ≥ 3 min)
        let remBouts = Stats.merge(Stats.runs(core.map { $0 == .rem }), maxGap: 30).filter { $0.count >= 6 }
        let cycles = remBouts.isEmpty ? Int(tst / 100) : remBouts.count

        // movimenti: cambi di postura (angolo ≥ 5°) o picchi di accelerazione durante il periodo di sonno
        let slice = Array(e[onset...last])
        let mot = slice.map { $0.motion }
        let thr = max(4 * Stats.median(mot), 15)
        let moving = slice.map { x in (x.angleChange ?? 0) >= 5 || x.motion > thr }
        let movements = Stats.runs(moving).count

        let onsetD = e[onset].start, wakeD = e[last].start.addingTimeInterval(RingConst.epoch)
        let mid = onsetD.addingTimeInterval(wakeD.timeIntervalSince(onsetD) / 2)
        let tib = Double(n) * ep

        // parametri vitali in sonno
        let rest = HeartRate.restingNight(e.map { $0.hr }, asleep: asleep)
        var ln: [Double] = [], sdnn: [Double] = [], resp: [Double] = []
        if !beats.isEmpty {
            var i = onset
            while i + 10 <= last + 1 {                                                  // finestre di 5 min
                let w = i..<(i + 10)
                i += 10
                guard asleep[w].filter({ $0 }).count >= 9 else { continue }
                let a = e[w.lowerBound].start.timeIntervalSinceReferenceDate
                let b = HRV.range(beats, from: a, to: a + 300)
                guard let m = HRV.metrics(beats[b], minBeats: 120), m.rmssd > 0 else { continue }
                ln.append(log(m.rmssd)); sdnn.append(m.sdnn)
                if let r = HRV.respiratoryRate(beats[b]), r.quality >= 0.25 { resp.append(r.rate) }
            }
        }
        // respiro: valore del sistema se c'è (misurato dall'accelerometro del Watch), altrimenti stima dal battito
        let respRate = hkResp ?? (resp.count >= 6 ? Stats.median(resp) : nil)
        let t = Temperature.night(series: tempSeries, sleepStart: onsetD, sleepEnd: wakeD)

        var runs: [DateSpan] = []
        for r in Stats.runs(asleep) {
            runs.append(DateSpan(start: e[r.lowerBound].start, end: e[r.upperBound - 1].start.addingTimeInterval(RingConst.epoch)))
        }
        return NightReport(
            inBed: e[0].start, sleepOnset: onsetD, finalWake: wakeD, outOfBed: e[n - 1].start.addingTimeInterval(RingConst.epoch),
            tibMin: tib, tstMin: tst, solMin: Double(onset) * ep, wasoMin: waso, efficiency: 100 * tst / tib,
            awakenings: awak, longestBoutMin: longest, fragmentationIdx: Double(awak + shifts / 4) / max(tst / 60, 0.5),
            movements: movements, cycles: cycles,
            lightMin: minutes(.light), deepMin: minutes(.deep), remMin: minutes(.rem), remLatencyMin: remLat,
            midpointH: Stats.hourOfDay(mid, cal), onsetH: Stats.hourOfDay(onsetD, cal), wakeH: Stats.hourOfDay(wakeD, cal),
            rhr: rest?.rhr, avgHR: rest?.avg, hrNadirFrac: rest?.nadirFrac,
            rmssd: ln.count >= 3 ? exp(Stats.mean(ln)) : nil, sdnn: sdnn.count >= 3 ? Stats.mean(sdnn) : nil,
            respRate: respRate, spo2: spo2,
            skinTemp: tempNight ?? t?.value, skinTempDev: nil, tempMinH: t?.minimumAt.map { Stats.hourOfDay($0, cal) },
            stages: st.map { $0.rawValue }, sleepRuns: runs, sleepIndex: 0, sleepIndexParts: [:])
    }

    /// Punteggio di durata: pieno tra il fabbisogno personale (meno mezz'ora) e 9,5 h (8,5 h dopo i 65 anni).
    /// La consensus AASM/SRS raccomanda ≥ 7 h per gli adulti.
    public static func durationScore(_ tstMin: Double, age: Double, need: Double) -> Double {
        let h = tstMin / 60, lo = max(min(7, need), need - 0.5), hi = age >= 65 ? 8.5 : 9.5
        if h < lo { return Stats.scale(h, 4, lo) }
        if h <= hi { return 1 }
        return 1 - 0.2 * Stats.scale(h, hi, hi + 2)
    }

    /// Quota attesa di sonno ristoratore (profondo + REM) per età: ≈ 40 % a 25 anni, ≈ 34 % a 65
    public static func restorativeTarget(age: Double) -> Double {
        0.40 - 0.06 * Stats.scale(age, 25, 65)
    }

    /// Regolarità degli orari 0-100: deviazione standard circolare di addormentamento e risveglio
    /// (≤ 30 min = 100, ≥ 90 min = 0). Servono almeno 3 notti.
    public static func consistency(onsetH: [Double], wakeH: [Double]) -> Double? {
        guard onsetH.count >= 3, wakeH.count >= 3 else { return nil }
        let sdMin = 60 * (Stats.circularSDHours(onsetH) + Stats.circularSDHours(wakeH)) / 2
        return 100 * (1 - Stats.scale(sdMin, 30, 90))
    }

    /// Sleep Index 0-100 sulle cinque dimensioni dichiarate da Ultrahuman: durata, tranquillità del sonno,
    /// sonno ristoratore, orario, parametri vitali notturni. Pesi e soglie sono un'ipotesi (l'originale non è pubblico).
    public static func sleepIndex(_ n: NightReport, profile: UserProfile, baselines b: Baselines, consistency: Double?)
        -> (score: Double, parts: [String: Double]) {
        let duration = durationScore(n.tstMin, age: profile.age, need: profile.sleepNeedH)
        let settled = 0.55 * Stats.scale(n.efficiency, 75, 92) + 0.25 * (1 - Stats.scale(Double(n.awakenings), 2, 10))
                    + 0.20 * (1 - Stats.scale(n.solMin, 20, 60))
        let target = restorativeTarget(age: profile.age)
        let restorative = Stats.scale(n.restorativeShare, 0.45 * target, target)
        var timing = b.midpointCenter.map { 1 - Stats.scale(abs(Stats.circDiff(n.midpointH, $0)), 0.5, 2.5) } ?? 0.8
        if let c = consistency { timing = 0.6 * timing + 0.4 * c / 100 }
        var vit = 0.0, wsum = 0.0
        if let r = n.rhr, b.rhr.ready { vit += 0.4 * (1 - Stats.scale(b.rhr.z(r), 0.5, 2.5)); wsum += 0.4 }
        if let f = n.hrNadirFrac { vit += 0.3 * (1 - Stats.scale(f, 0.6, 1.0)); wsum += 0.3 }
        if let d = n.skinTempDev { vit += 0.3 * (1 - Stats.scale(abs(d), 0.3, 1.0)); wsum += 0.3 }
        let vitals = wsum > 0 ? vit / wsum : 0.8
        let p = ["durata": duration, "tranquillita": settled, "ristoratore": restorative, "orario": timing, "vitali": vitals]
        let score = 100 * (0.30 * duration + 0.20 * settled + 0.20 * restorative + 0.15 * timing + 0.15 * vitals)
        return (score, p)
    }

    public static func label(_ index: Double) -> String {
        index > 85 ? "molto ristoratore" : index >= 70 ? "solido" : index >= 60 ? "discreto" : "insufficiente"
    }

    /// Debito di sonno (ore): debito = max(0, 0,85 x debito precedente + fabbisogno - sonno del giorno).
    /// Il fattore 0,85 fa "scadere" il debito vecchio; i sonnellini contano; i giorni senza registrazione
    /// vengono saltati (non equivalgono a zero ore di sonno). Si considerano gli ultimi 14 giorni.
    public static func sleepDebtH(_ dailySleepMin: [Double?], needH: Double) -> Double {
        var debt = 0.0
        for s in dailySleepMin.suffix(14) {
            guard let s else { continue }
            debt = max(0, 0.85 * debt + needH - s / 60)
        }
        return debt
    }

    /// Sleep Regularity Index (Phillips et al. 2017): probabilità di essere nello stesso stato (sonno/veglia)
    /// in due istanti a 24 h di distanza, riscalata tra -100 e 100.
    /// `days` = giorni (inizio del giorno di calendario) con la notte registrata; `sleep` = tutti i tratti di sonno.
    /// Si confrontano, minuto per minuto, le finestre [giorno - 12 h, giorno + 12 h) di coppie di giorni consecutivi.
    public static func sri(days: [Date], sleep: [DateSpan], calendar: Calendar, minPairs: Int = 3) -> Double? {
        let d = days.sorted()
        guard d.count > minPairs else { return nil }
        let spans = sleep.sorted { $0.start < $1.start }
        func mask(_ day: Date) -> [Bool] {
            let t0 = day.addingTimeInterval(-12 * 3600)
            var m = [Bool](repeating: false, count: 1440)
            for s in spans {
                let a = Int((s.start.timeIntervalSince(t0) / 60).rounded()), b = Int((s.end.timeIntervalSince(t0) / 60).rounded())
                guard b > 0, a < 1440 else { continue }
                for i in max(a, 0)..<min(b, 1440) { m[i] = true }
            }
            return m
        }
        var agree = 0, total = 0, pairs = 0
        for k in 1..<d.count {
            guard let next = calendar.date(byAdding: .day, value: 1, to: d[k - 1]), calendar.isDate(next, inSameDayAs: d[k]) else { continue }
            let a = mask(d[k - 1]), b = mask(d[k])
            for i in 0..<1440 where a[i] == b[i] { agree += 1 }
            total += 1440; pairs += 1
        }
        return pairs >= minPairs ? -100 + 200 * Double(agree) / Double(total) : nil
    }
}
