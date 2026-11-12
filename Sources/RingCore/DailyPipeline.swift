import Foundation

/// Campione cumulativo su un intervallo (es. passi contati tra `start` e `end`)
public struct QuantitySpan: Sendable, Equatable {
    public var start: Date, end: Date, value: Double
    public init(start: Date, end: Date, value: Double) { self.start = start; self.end = end; self.value = value }
}

/// Tutti i dati di un giorno, indipendenti dalla piattaforma (nessun tipo HealthKit).
///
/// Due orizzonti temporali:
/// - la NOTTE è quella che termina nel giorno `day` (per questo le epoche partono 6 ore prima della mezzanotte);
/// - ATTIVITÀ e STRESS riguardano il giorno di calendario [day, day + 24 h).
public struct DayInput: Sendable {
    public static let lookback: TimeInterval = 6 * 3600

    /// inizio del giorno di calendario locale
    public var day: Date
    public var calendar: Calendar
    /// istante fino a cui i dati sono disponibili (il giorno può essere ancora in corso)
    public var now: Date
    /// epoche contigue da 30 s a partire da `day - 6 h`, sulla griglia allineata al tempo Unix
    public var epochs: [Epoch]
    public var appleSleep: [SleepSegment] = []
    public var ibiSeries: [IBISeries] = []
    /// campioni grezzi di FC (opzionali): usati per i minuti in zona degli allenamenti
    public var hrSamples: [TimedValue] = []
    /// temperatura cutanea: un valore per notte (Apple Watch) e/o serie continua (anello o sensore esterno)
    public var skinTempNight: Double?
    public var skinTempSeries: [TimedValue] = []
    public var hkRespRate: Double?
    public var spo2: Double?
    public var hkWorkouts: [WorkoutRecord] = []
    public var hkActiveKcal: Double?
    public var hkBasalKcal: Double?
    public var appleVO2: Double?
    public var appleVO2AgeDays: Double?
    public var daylightMin: Double?

    public init(day: Date, calendar: Calendar, now: Date, epochs: [Epoch]) {
        self.day = day; self.calendar = calendar; self.now = now; self.epochs = epochs
    }

    public var dayEnd: Date { calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400) }

    /// Costruisce le epoche a partire dai campioni così come arrivano dai sensori o da HealthKit.
    /// - FC: media dei campioni nell'epoca; i buchi fino a 15 min sono interpolati, oltre restano nil (orologio non indossato)
    /// - passi: ogni campione è ripartito sulle epoche che copre; senza contapassi di sistema si usano i passi del Watch
    /// - movimento: epoche calcolate dal Watch (`MotionEpoch`), agganciate per indice
    public static func make(day: Date, calendar: Calendar, now: Date, hr: [TimedValue], steps: [QuantitySpan],
                            motion: [MotionEpoch], appleSleep: [SleepSegment] = []) -> DayInput {
        let ep = RingConst.epoch
        let i0 = Int(((day.timeIntervalSince1970 - lookback) / ep).rounded(.down))
        let end = min(calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400), now)
        let n = max(Int(((end.timeIntervalSince1970 / ep).rounded(.down))) - i0, 0)
        var e = (0..<n).map { Epoch(start: Date(timeIntervalSince1970: Double(i0 + $0) * ep)) }
        guard n > 0 else { return DayInput(day: day, calendar: calendar, now: now, epochs: []) }

        var sum = [Double](repeating: 0, count: n), cnt = [Int](repeating: 0, count: n)
        for s in hr where s.value > 25 && s.value < 240 {
            let i = Int((s.date.timeIntervalSince1970 / ep).rounded(.down)) - i0
            if i >= 0 && i < n { sum[i] += s.value; cnt[i] += 1 }
        }
        let means = (0..<n).filter { cnt[$0] > 0 }.map { TimedValue(date: e[$0].start.addingTimeInterval(ep / 2), value: sum[$0] / Double(cnt[$0])) }
        let interp = Stats.interpolate(means, at: e.map { $0.start.addingTimeInterval(ep / 2) }, maxGap: 900)
        for i in 0..<n { e[i].hr = interp[i] }

        for m in motion {
            let i = m.index - i0
            guard i >= 0 && i < n else { continue }
            e[i].motion = Double(m.counts); e[i].angleChange = Double(m.angleChange)
            if steps.isEmpty { e[i].steps = Double(m.steps) }
        }
        let t0 = Double(i0) * ep
        for s in steps where s.value > 0 {
            let a = s.start.timeIntervalSince1970 - t0, b = max(s.end.timeIntervalSince1970 - t0, a + 1)
            let ia = max(Int((a / ep).rounded(.down)), 0), ib = min(Int((b / ep).rounded(.down)), n - 1)
            guard ia <= ib else { continue }
            for i in ia...ib {
                let ov = min(b, Double(i + 1) * ep) - max(a, Double(i) * ep)
                if ov > 0 { e[i].steps += s.value * ov / (b - a) }
            }
        }
        for s in appleSleep {
            guard let st = s.stage else { continue }
            let ia = max(Int(((s.start.timeIntervalSince1970 - t0) / ep).rounded()), 0)
            let ib = min(Int(((s.end.timeIntervalSince1970 - t0) / ep).rounded()), n)
            if ia < ib { for i in ia..<ib { e[i].appleStage = st } }
        }
        var d = DayInput(day: day, calendar: calendar, now: now, epochs: e)
        d.appleSleep = appleSleep
        d.hrSamples = hr
        return d
    }
}

/// Dal giorno grezzo al report. Funzione pura: stessi ingressi, stesso risultato; nessuna lettura dell'orologio
/// di sistema, nessuno stato nascosto. `history` = report già calcolati (servono solo quelli precedenti a `day`).
public enum DailyPipeline {
    public static func run(_ input: DayInput, profile: UserProfile, history: [DailyReport],
                           staging: StagingModel = .standard) -> DailyReport {
        let cal = input.calendar, day = input.day, dayEnd = input.dayEnd
        let b = Baselines(history: history, before: day, calendar: cal)
        let e = input.epochs
        let beats = HRV.beats(from: input.ibiSeries)
        let ep = RingConst.epoch

        // ───────── 1. Sonno: periodo principale, stadi, metriche ─────────
        let periods = SleepDetection.detect(e, apple: input.appleSleep, mainEnd: day...day.addingTimeInterval(18 * 3600),
                                            napWindow: day..<dayEnd)
        var night: NightReport?
        if var m = periods.main {
            // con i soli sensori il periodo coincide con l'immobilità: si allarga un po' per vedere addormentamento e risveglio
            // se l'immobilità arriva fino agli ultimi 30 min di dati, la persona sta probabilmente ancora dormendo:
            // la notte viene riportata solo a risveglio avvenuto (l'elaborazione successiva la completa)
            let inProgress = periods.source == "sensori" && m.upperBound >= e.count - 60 && input.now < dayEnd
            if periods.source == "sensori" { m = max(m.lowerBound - 40, 0)..<min(m.upperBound + 20, e.count) }
            if !inProgress {
                let seg = Array(e[m])
                let st = SleepStaging.stage(seg, lnRMSSD: SleepMetrics.lnRMSSDPerEpoch(seg, beats: beats), model: staging)
                night = SleepMetrics.night(seg, stages: st, beats: beats, calendar: cal, tempSeries: input.skinTempSeries,
                                           tempNight: input.skinTempNight, respRate: input.hkRespRate, spo2: input.spo2)
            }
        }
        let week = cal.date(byAdding: .day, value: -7, to: day) ?? day.addingTimeInterval(-7 * 86_400)
        let lastWeek = b.recent.filter { $0.date >= week }
        var consistency: Double?
        if var n = night {
            if let t = n.skinTemp, b.temp.ready { n.skinTempDev = t - b.temp.center }
            let prev = lastWeek.compactMap { $0.night }.suffix(6)
            consistency = SleepMetrics.consistency(onsetH: prev.map { $0.onsetH } + [n.onsetH], wakeH: prev.map { $0.wakeH } + [n.wakeH])
            let si = SleepMetrics.sleepIndex(n, profile: profile, baselines: b, consistency: consistency)
            n.sleepIndex = si.score; n.sleepIndexParts = si.parts
            night = n
        }
        let naps = periods.naps.map { DateSpan(start: e[$0.lowerBound].start, end: e[$0.upperBound - 1].start.addingTimeInterval(ep)) }
        let napsMin = naps.map { $0.minutes }.reduce(0, +)
        let dailySleep = night.map { $0.tstMin + napsMin }
        let debt = SleepMetrics.sleepDebtH(b.previousDebtDays.map { $0.sleepMin } + [dailySleep], needH: profile.sleepNeedH)
        var sriDays = lastWeek.map { $0.date }, sriSpans = lastWeek.flatMap { ($0.night?.sleepRuns ?? []) + $0.naps }
        if let n = night { sriDays.append(day); sriSpans += n.sleepRuns + naps }
        let sri = SleepMetrics.sri(days: sriDays, sleep: sriSpans, calendar: cal)

        // ───────── 2. Giorno di calendario al minuto ─────────
        let t0 = e.first?.start ?? day
        let minutes = max(Int(dayEnd.timeIntervalSince(day) / 60), 0)
        var hrMin = [Double?](repeating: nil, count: minutes)
        var stepsMin = [Double](repeating: 0, count: minutes), motMin = stepsMin
        var hasData = [Bool](repeating: false, count: minutes)
        let off = Int((day.timeIntervalSince(t0) / ep).rounded())
        for m in 0..<minutes {
            let i = off + 2 * m
            guard i >= 0, i + 1 < e.count else { continue }
            let h = [e[i].hr, e[i + 1].hr].compactMap { $0 }
            hrMin[m] = h.isEmpty ? nil : Stats.mean(h)
            stepsMin[m] = e[i].steps + e[i + 1].steps
            motMin[m] = (e[i].motion + e[i + 1].motion) / 2
            hasData[m] = true
        }
        func minuteRange(_ s: DateSpan) -> Range<Int> {
            let a = Int((s.start.timeIntervalSince(day) / 60).rounded(.down)), z = Int((s.end.timeIntervalSince(day) / 60).rounded(.up))
            let lo = min(max(a, 0), minutes)
            return lo..<max(min(z, minutes), lo)
        }
        var inBed = [Bool](repeating: false, count: minutes)
        if let n = night { for m in minuteRange(DateSpan(start: n.inBed, end: n.outOfBed)) { inBed[m] = true } }
        for s in naps { for m in minuteRange(s) { inBed[m] = true } }
        let awake = (0..<minutes).map { hasData[$0] && !inBed[$0] && (hrMin[$0] != nil || stepsMin[$0] > 0) }

        // ───────── 3. Cuore: FC a riposo, FC massima, zone ─────────
        let dayHR = hrMin.compactMap { $0 }
        let rhr = night?.rhr ?? (b.rhr.n >= 3 ? b.rhr.center : nil) ?? (dayHR.count >= 60 ? Stats.percentile(dayHR, 5) : 60)
        let hk = input.hkWorkouts.filter { $0.start >= day && $0.start < dayEnd }
        let mx = HeartRate.hrMax(profile: profile, workoutPeaks: b.workouts.map { $0.maxHR } + hk.map { $0.maxHR })
        let bounds = HeartRate.zoneBounds(model: profile.zoneModel, rhr: rhr, hrMax: mx.value)
        let zoneDay = HeartRate.zoneMinutes(perMinute: hrMin, bounds: bounds)

        // ───────── 4. Allenamenti ─────────
        let samples = input.hrSamples.sorted { $0.date < $1.date }
        var workouts: [WorkoutRecord] = hk.map { w in
            var w = w
            let r = minuteRange(DateSpan(start: w.start, end: w.end))
            let s = samples.filter { $0.date >= w.start && $0.date <= w.end }
            let perMin = r.compactMap { hrMin[$0] }
            if s.count >= max(5, Int(w.minutes)) {
                w.zoneMinutes = HeartRate.zoneMinutes(samples: s, bounds: bounds)
                if w.avgHR <= 0 { w.avgHR = Stats.mean(s.map { $0.value }) }
                if w.maxHR <= 0 { w.maxHR = s.map { $0.value }.max() ?? 0 }
            } else {
                w.zoneMinutes = HeartRate.zoneMinutes(perMinute: r.map { hrMin[$0] }, bounds: bounds)
                if w.avgHR <= 0, !perMin.isEmpty { w.avgHR = Stats.mean(perMin) }
                if w.maxHR <= 0 { w.maxHR = perMin.max() ?? 0 }
            }
            if w.kcal <= 0 {
                let bmr = Energy.bmr(profile) / 1440
                w.kcal = perMin.map { max(Energy.keytelPerMin(hr: $0, profile: profile) - bmr, 0) }.reduce(0, +)
            }
            return w
        }
        let thr = max(0.6 * mx.value, rhr + 0.4 * (mx.value - rhr))
        let masked = (0..<minutes).map { awake[$0] ? hrMin[$0] : nil }
        for a in Activity.detectWorkouts(dayStart: day, hrPerMin: masked, stepsPerMin: stepsMin, motionPerMin: motMin,
                                         thrHR: thr, bounds: bounds, profile: profile)
        where !workouts.contains(where: { $0.start < a.end && a.start < $0.end }) {
            workouts.append(a)
        }
        workouts.sort { $0.start < $1.start }
        var inWorkout = [Bool](repeating: false, count: minutes)
        for w in workouts { for m in minuteRange(DateSpan(start: w.start, end: w.end)) { inWorkout[m] = true } }
        let trimp = workouts.map { $0.trimp }.reduce(0, +)

        // ───────── 5. Attività ed energia ─────────
        let steps = stepsMin.reduce(0, +)
        let act = Activity.dayActivity(stepsPerMin: stepsMin, hrPerMin: hrMin, awake: awake, moderateHR: thr)
        var stepsOutside = 0.0
        for m in 0..<minutes where !inWorkout[m] { stepsOutside += stepsMin[m] }
        let elapsed = min(max(input.now.timeIntervalSince(day), 0), dayEnd.timeIntervalSince(day))
        let kcal = Energy.daily(profile, dayFraction: elapsed / max(dayEnd.timeIntervalSince(day), 1), hkActive: input.hkActiveKcal,
                                hkBasal: input.hkBasalKcal, workouts: workouts, stepsOutside: stepsOutside)
        let w7 = b.workouts.filter { $0.start >= week.addingTimeInterval(86_400) }.count + workouts.count
        let mov = Activity.movementIndex(steps: steps, stepGoal: profile.stepGoal, activeHours: act.activeHours, workouts7d: w7)

        // ───────── 6. Stress e recupero ─────────
        let wakeRef = night?.wakeH ?? b.wakeCenter ?? 7
        let bedRef = b.onsetCenter ?? night?.onsetH ?? 23
        let timeline = Stress.timeline(hrPerMin: hrMin, stepsPerMin: stepsMin, awake: awake, inWorkout: inWorkout, dayStart: day,
                                       beats: beats, rhr: rhr, baselines: b, nightLnRMSSD: night?.rmssd.map { log($0) })
        let valid = timeline.compactMap { $0 }
        let rhythm = Stress.rhythm(timeline, wakeH: wakeRef, bedH: bedRef)
        let acwr = b.days28 >= 21 ? Recovery.acwr(b.trimp28 + [trimp]) : nil
        let rec = Recovery.score(sleepIndex: night?.sleepIndex, night: night, stressRhythm: valid.count >= 12 ? rhythm : nil,
                                 acwr: acwr, sleepDebtH: debt, baselines: b)

        // ───────── 7. Ritmo circadiano ─────────
        var nights28 = b.recent.compactMap { r in r.night.map { (date: r.date, night: $0) } }
        if let n = night { nights28.append((date: day, night: n)) }
        let jet = Circadian.socialJetlag(nights28, workdays: profile.workdays, calendar: cal)
        let tMins = (lastWeek.compactMap { $0.night?.tempMinH } + [night?.tempMinH].compactMap { $0 })
        let tMin = tMins.isEmpty ? Stats.wrap24(wakeRef - 2) : Stats.circularMeanHours(tMins)
        let alignment = Circadian.alignment(lastMidH: night?.midpointH, referenceMidH: jet?.msfSc ?? b.midpointCenter, sri: sri,
                                            daylightMin: input.daylightMin, sjlH: jet?.sjlSc)
        let windows = Circadian.windows(tMinH: tMin, wakeH: wakeRef, bedH: bedRef)

        // ───────── 8. Fitness ─────────
        let from28 = cal.date(byAdding: .day, value: -27, to: day) ?? day.addingTimeInterval(-27 * 86_400)
        let pa = Fitness.paIndex(workouts: b.workouts.filter { $0.start >= from28 } + workouts, hrMax: mx.value)
        let vo2 = Fitness.vo2max(profile: profile, rhr: rhr, hrMax: mx.value, hrMaxMeasured: mx.measured, paIndex: pa,
                                 appleVO2: input.appleVO2, appleAgeDays: input.appleVO2AgeDays)
        let ageRaw = Fitness.cardioAge(vo2: vo2.value, sex: profile.sex)

        return DailyReport(
            date: day, night: night, naps: naps, napsMin: napsMin, dailySleepMin: dailySleep, sleepDebtH: debt, sri: sri,
            sleepConsistency: consistency,
            rhr: rhr, hrMax: mx.value, hrMaxMeasured: mx.measured, zoneBounds: bounds, zoneMinutesDay: zoneDay,
            steps: steps, activeHours: act.activeHours, activeMinutes: act.activeMinutes, inactiveMin: act.inactiveMin,
            longestSedentaryMin: act.longestSedentary, workouts: workouts, trimp: trimp, kcalTotal: kcal.total, kcalActive: kcal.active,
            movementIndex: mov.score, movementParts: mov.parts,
            stressTimeline: timeline, stressAvg: valid.isEmpty ? nil : Stats.mean(valid), stressRhythm: rhythm,
            recovery: rec.score, recoveryLabel: rec.label, recoveryParts: rec.parts, flags: rec.flags,
            circadianAlignment: alignment, socialJetlagH: jet?.sjl, socialJetlagScH: jet?.sjlSc, chronotypeMSFsc: jet?.msfSc,
            tempMinH: tMin, windows: windows,
            vo2max: vo2.value, vo2Source: vo2.source, cardioAgeRaw: ageRaw, cardioAge: Fitness.smooth(previous: b.previousCardioAge, raw: ageRaw),
            baselineNights: b.nights)
    }
}
