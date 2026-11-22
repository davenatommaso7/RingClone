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
        for i in 0..<n {
            e[i].hr = interp[i]
            e[i].hrObserved = cnt[i] > 0
            e[i].stepsObserved = false
            e[i].motionObserved = false
        }

        let stepSpans = steps.filter { $0.value.isFinite && $0.value >= 0 && $0.start < $0.end }
        for m in motion where m.samples > 0 {
            let i = m.index - i0
            guard i >= 0 && i < n else { continue }
            e[i].motion = Double(m.counts); e[i].angleChange = Double(m.angleChange); e[i].motionObserved = true
            if stepSpans.isEmpty { e[i].steps = Double(m.steps); e[i].stepsObserved = true }
        }
        let t0 = Double(i0) * ep
        for s in stepSpans {
            let a = s.start.timeIntervalSince1970 - t0, b = max(s.end.timeIntervalSince1970 - t0, a + 1)
            let ia = max(Int((a / ep).rounded(.down)), 0), ib = min(Int((b / ep).rounded(.down)), n - 1)
            guard ia <= ib else { continue }
            for i in ia...ib {
                let ov = min(b, Double(i + 1) * ep) - max(a, Double(i) * ep)
                if ov > 0 { e[i].steps += s.value * ov / (b - a); e[i].stepsObserved = true }
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
                if let onset = night?.sleepOnset {
                    let asleep = seg.indices.map { seg[$0].start >= onset && st[$0].isSleep }
                    let vitals = HeartRate.restingNight(seg.map(\.observedHR), asleep: asleep)
                    night?.rhr = vitals?.rhr; night?.avgHR = vitals?.avg; night?.hrNadirFrac = vitals?.nadirFrac
                }
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
        let napsMin = Double(periods.napSleepEpochs) * ep / 60
        let dailySleep = night.map { $0.tstMin + napsMin }
        let debt = SleepMetrics.sleepDebtH(b.previousDebtDays.map { $0.sleepMin } + [dailySleep], needH: profile.sleepNeedH)
        var sriDays = lastWeek.map { $0.date }, sriSpans = lastWeek.flatMap { ($0.night?.sleepRuns ?? []) + $0.naps }
        if let n = night { sriDays.append(day); sriSpans += n.sleepRuns + naps }
        let sri = SleepMetrics.sri(days: sriDays, sleep: sriSpans, calendar: cal)

        // ───────── 2. Giorno di calendario al minuto ─────────
        let t0 = e.first?.start ?? day
        let minutes = max(Int(dayEnd.timeIntervalSince(day) / 60), 0)
        var hrMin = [Double?](repeating: nil, count: minutes)
        var observedHRMin = hrMin
        var stepsMin = [Double](repeating: 0, count: minutes), motMin = stepsMin
        var stepCoverage = [Bool](repeating: false, count: minutes), motionCoverage = stepCoverage
        let off = Int((day.timeIntervalSince(t0) / ep).rounded())
        for m in 0..<minutes {
            let i = off + 2 * m
            guard i >= 0, i + 1 < e.count else { continue }
            let h = [e[i].hr, e[i + 1].hr].compactMap { $0 }
            hrMin[m] = h.isEmpty ? nil : Stats.mean(h)
            let observed = [e[i].observedHR, e[i + 1].observedHR].compactMap { $0 }
            observedHRMin[m] = observed.isEmpty ? nil : Stats.mean(observed)
            stepsMin[m] = e[i].steps + e[i + 1].steps
            motMin[m] = (e[i].motion + e[i + 1].motion) / 2
            stepCoverage[m] = e[i].hasSteps || e[i + 1].hasSteps
            motionCoverage[m] = e[i].hasMotion || e[i + 1].hasMotion
        }
        func minuteRange(_ s: DateSpan) -> Range<Int> {
            let a = Int((s.start.timeIntervalSince(day) / 60).rounded(.down)), z = Int((s.end.timeIntervalSince(day) / 60).rounded(.up))
            let lo = min(max(a, 0), minutes)
            return lo..<max(min(z, minutes), lo)
        }
        var inBed = [Bool](repeating: false, count: minutes)
        if let n = night { for m in minuteRange(DateSpan(start: n.inBed, end: n.outOfBed)) { inBed[m] = true } }
        for s in naps { for m in minuteRange(s) { inBed[m] = true } }
        let awake = (0..<minutes).map { !inBed[$0] && (observedHRMin[$0] != nil || stepCoverage[$0] || motionCoverage[$0]) }

        // ───────── 3. Cuore: FC a riposo, FC massima, zone ─────────
        let dayHR = observedHRMin.compactMap { $0 }
        let restingPulse = night?.rhr ?? (b.rhr.n >= 3 ? b.rhr.center : nil) ?? (dayHR.count >= 60 ? Stats.percentile(dayHR, 5) : nil)
        let hk = History.uniqueWorkouts(input.hkWorkouts.filter { $0.start >= day && $0.start < dayEnd && $0.end > $0.start })
        let currentIDs = Set(hk.compactMap(\.sourceID))
        let replayAcrossDays = b.workouts.contains { $0.sourceID.map { currentIDs.contains($0) } == true }
        let pastWorkouts = b.workouts.filter { workout in
            guard let id = workout.sourceID else { return true }
            return !currentIDs.contains(id)
        }
        let mx = HeartRate.hrMax(profile: profile, workoutPeaks: pastWorkouts.map(\.maxHR) + hk.map(\.maxHR))
        let bounds = profile.zoneModel == .karvonen && restingPulse == nil ? [] :
            HeartRate.zoneBounds(model: profile.zoneModel, rhr: restingPulse ?? 0, hrMax: mx.value)
        let zoneDay = HeartRate.zoneMinutes(perMinute: observedHRMin, bounds: bounds)

        // ───────── 4. Allenamenti ─────────
        let samples = input.hrSamples.filter { $0.value > 25 && $0.value < 240 }.sorted { $0.date < $1.date }
        var workouts: [WorkoutRecord] = hk.map { w in
            var w = w
            let r = minuteRange(DateSpan(start: w.start, end: w.end))
            let s = samples.filter { $0.date >= w.start && $0.date <= w.end }
            let perMin = r.compactMap { observedHRMin[$0] }
            if s.count >= max(5, Int(w.minutes)) {
                w.zoneMinutes = HeartRate.zoneMinutes(samples: s, bounds: bounds)
                if w.avgHR <= 0 { w.avgHR = Stats.mean(s.map { $0.value }) }
                if w.maxHR <= 0 { w.maxHR = s.map { $0.value }.max() ?? 0 }
            } else {
                w.zoneMinutes = HeartRate.zoneMinutes(perMinute: r.map { observedHRMin[$0] }, bounds: bounds)
                if w.avgHR <= 0, !perMin.isEmpty { w.avgHR = Stats.mean(perMin) }
                if w.maxHR <= 0 { w.maxHR = perMin.max() ?? 0 }
            }
            if let imported = Energy.observedEnergy(w.importedKcal) { w.kcal = imported }
            else if w.kcal <= 0 || !w.kcal.isFinite {
                let bmr = Energy.bmr(profile) / 1440
                w.kcal = perMin.map { max(Energy.keytelPerMin(hr: $0, profile: profile) - bmr, 0) }.reduce(0, +)
            }
            return w
        }
        let thr = restingPulse.map { max(0.6 * mx.value, $0 + 0.4 * (mx.value - $0)) } ?? 0.6 * mx.value
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
        let completeDay = minutes > 0 && dayHR.count == minutes && input.now >= dayEnd
        let loadKnown = !bounds.isEmpty && (workouts.isEmpty ? completeDay : workouts.allSatisfy {
            minuteRange(DateSpan(start: $0.start, end: $0.end)).contains { observedHRMin[$0] != nil }
        })

        // ───────── 5. Attività ed energia ─────────
        let steps = stepsMin.reduce(0, +)
        let act = Activity.dayActivity(stepsPerMin: stepsMin, hrPerMin: hrMin, awake: awake, moderateHR: thr)
        var stepsOutside = 0.0
        for m in 0..<minutes where !inWorkout[m] { stepsOutside += stepsMin[m] }
        let elapsed = min(max(input.now.timeIntervalSince(day), 0), dayEnd.timeIntervalSince(day))
        let kcal = Energy.daily(profile, dayFraction: elapsed / max(dayEnd.timeIntervalSince(day), 1), hkActive: input.hkActiveKcal,
                                hkBasal: input.hkBasalKcal, workouts: workouts, stepsOutside: stepsOutside)
        let w7 = pastWorkouts.filter { $0.start >= week.addingTimeInterval(86_400) }.count + workouts.count
        let mov = Activity.movementIndex(steps: steps, stepGoal: profile.stepGoal, activeHours: act.activeHours, workouts7d: w7)
        let stepsKnown = stepCoverage.contains(true)
        let activityKnown = stepsKnown || motionCoverage.contains(true)
        let activeEnergy: DailyMetricState = Energy.observedEnergy(input.hkActiveKcal) != nil ? .observed :
            (stepsKnown || workouts.contains { Energy.observedEnergy($0.importedKcal) != nil || $0.kcal > 0 } ? .estimated : .insufficient)
        let totalEnergy: DailyMetricState = activeEnergy == .observed && Energy.observedEnergy(input.hkBasalKcal) != nil ? .observed :
            (activeEnergy.hasValue ? .estimated : .insufficient)

        // ───────── 6. Stress e recupero ─────────
        let wakeRef = night?.wakeH ?? b.wakeCenter ?? 7
        let bedRef = b.onsetCenter ?? night?.onsetH ?? 23
        let timeline = restingPulse.map { pulse in
            Stress.timeline(hrPerMin: observedHRMin, stepsPerMin: stepsMin, awake: awake, inWorkout: inWorkout, dayStart: day,
                            beats: beats, rhr: pulse, baselines: b, nightLnRMSSD: night?.rmssd.map { log($0) })
        } ?? Array(repeating: nil, count: 288)
        let valid = timeline.compactMap { $0 }
        let rhythm = valid.count >= 12 ? Stress.rhythm(timeline, wakeH: wakeRef, bedH: bedRef) : nil
        let observedLoad = Array(b.observedTrimp28.suffix(27)) + [loadKnown ? trimp : nil]
        let acwr = !replayAcrossDays && observedLoad.allSatisfy { $0 != nil } ? Recovery.acwr(observedLoad.compactMap { $0 }) : nil
        let rec = Recovery.score(sleepIndex: night?.sleepIndex, night: night, stressRhythm: rhythm,
                                 acwr: acwr, sleepDebtH: debt, baselines: b)

        // ───────── 7. Ritmo circadiano ─────────
        var nights28 = b.recent.compactMap { r in r.night.map { (date: r.date, night: $0) } }
        if let n = night { nights28.append((date: day, night: n)) }
        let jet = Circadian.socialJetlag(nights28, workdays: profile.workdays, calendar: cal)
        let tMins = (lastWeek.compactMap { $0.night?.tempMinH } + [night?.tempMinH].compactMap { $0 })
        let tMin = tMins.isEmpty ? (night?.wakeH ?? b.wakeCenter).map { Stats.wrap24($0 - 2) } : Stats.circularMeanHours(tMins)
        let daylight = input.daylightMin.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let midpointReference = jet?.msfSc ?? b.midpointCenter
        let alignmentKnown = (night != nil && midpointReference != nil) || sri != nil || daylight != nil || jet != nil
        let alignment = alignmentKnown ? Circadian.alignment(lastMidH: night?.midpointH, referenceMidH: midpointReference, sri: sri,
                                                             daylightMin: daylight, sjlH: jet?.sjlSc) : .nan
        let windows = tMin.map { Circadian.windows(tMinH: $0, wakeH: wakeRef, bedH: bedRef) } ?? []

        // ───────── 8. Fitness ─────────
        let from28 = cal.date(byAdding: .day, value: -27, to: day) ?? day.addingTimeInterval(-27 * 86_400)
        let p28 = (pastWorkouts.filter { $0.start >= from28 } + workouts).filter { $0.avgHR > 0 && $0.avgHR.isFinite }
        let pa = Fitness.paIndex(workouts: p28, hrMax: mx.value)
        let fit = fitness(profile: profile, input: input, rhr: restingPulse, hrMax: mx.value, pa: pa,
                          canEstimatePA: activityKnown || !p28.isEmpty)
        let ageRaw = fit.map { Fitness.cardioAge(vo2: $0.value, sex: profile.sex) }
        let baselineReady = b.rhr.ready && b.lnRMSSD.ready && b.temp.ready
        let recoveryState: DailyMetricState = rec.score.isFinite ? (baselineReady ? .computed : .calibrating) : .insufficient
        let evidence = DailyEvidence(
            rhr: night?.rhr != nil ? .computed : (restingPulse != nil ? .estimated : (dayHR.isEmpty ? .unavailable : .insufficient)),
            zones: !bounds.isEmpty && !dayHR.isEmpty ? .computed : .insufficient,
            steps: stepsKnown ? .observed : .unavailable, activity: activityKnown ? .computed : .insufficient,
            energyActive: activeEnergy, energyTotal: totalEnergy, trimp: loadKnown ? .computed : .insufficient,
            movement: activityKnown || !workouts.isEmpty ? .estimated : .insufficient,
            stress: valid.isEmpty ? .insufficient : .estimated, rhythm: rhythm != nil ? .estimated : .insufficient,
            recovery: recoveryState, alignment: alignmentKnown ? .estimated : .insufficient,
            tempMinimum: !tMins.isEmpty ? .computed : (tMin != nil ? .estimated : .unavailable),
            fitness: fit?.state ?? .insufficient, baselineReady: baselineReady)

        return DailyReport(
            date: day, night: night, naps: naps, napsMin: napsMin, dailySleepMin: dailySleep, sleepDebtH: debt, sri: sri,
            sleepConsistency: consistency,
            rhr: restingPulse ?? 60, hrMax: mx.value, hrMaxMeasured: mx.measured, zoneBounds: bounds, zoneMinutesDay: zoneDay,
            steps: steps, activeHours: act.activeHours, activeMinutes: act.activeMinutes, inactiveMin: act.inactiveMin,
            longestSedentaryMin: act.longestSedentary, workouts: workouts, trimp: trimp, kcalTotal: kcal.total, kcalActive: kcal.active,
            movementIndex: mov.score, movementParts: mov.parts,
            stressTimeline: timeline, stressAvg: valid.isEmpty ? nil : Stats.mean(valid), stressRhythm: rhythm ?? .nan,
            recovery: rec.score, recoveryLabel: recoveryState == .calibrating ? "In calibrazione" : rec.label,
            recoveryParts: rec.parts, flags: rec.flags,
            circadianAlignment: alignment, socialJetlagH: jet?.sjl, socialJetlagScH: jet?.sjlSc, chronotypeMSFsc: jet?.msfSc,
            tempMinH: tMin ?? .nan, windows: windows,
            vo2max: fit?.value ?? .nan, vo2Source: fit?.source ?? "Dati insufficienti", cardioAgeRaw: ageRaw ?? .nan,
            cardioAge: ageRaw.map { Fitness.smooth(previous: b.previousCardioAge, raw: $0) } ?? .nan,
            baselineNights: b.nights, evidence: evidence, computedAt: input.now)
    }

    private static func fitness(profile: UserProfile, input: DayInput, rhr: Double?, hrMax: Double, pa: Double,
                                canEstimatePA: Bool) -> (value: Double, source: String, state: DailyMetricState)? {
        let lab = profile.labVO2max.flatMap { $0 > 10 && $0 < 95 ? $0 : nil }
        let apple = input.appleVO2.flatMap { $0 > 10 && $0 < 95 ? $0 : nil }
        let age = input.appleVO2AgeDays
        let freshApple = age.map { $0 >= 0 && $0 <= 60 } == true ? apple : nil
        if let rhr, canEstimatePA {
            let overrideConfirmed = profile.hrMaxOverride.map { $0 > 100 && $0 < 230 } == true
            let fit = Fitness.vo2max(profile: profile, rhr: rhr, hrMax: hrMax, hrMaxMeasured: overrideConfirmed,
                                     paIndex: pa, appleVO2: freshApple, appleAgeDays: age)
            return fit.value.isFinite ? (fit.value, fit.source, .estimated) : nil
        }
        if let lab { return (lab, "Laboratorio", .observed) }
        if let freshApple { return (freshApple, "Apple", .estimated) }
        return nil
    }
}
