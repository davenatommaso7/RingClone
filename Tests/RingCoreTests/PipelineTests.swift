import XCTest
@testable import RingCore

final class PipelineTests: XCTestCase {
    /// 24 giorni di storico sintetico, calcolati una sola volta
    static let history: [DailyReport] = Synthetic.history(days: 24, before: testDay(25), calendar: testCal, profile: testProfile)

    static func typicalDay(_ edit: (inout Synthetic.Options) -> Void = { _ in }) -> Synthetic.Day {
        var o = Synthetic.options(for: testDay(25), calendar: testCal, seed: 7)
        o.rhr = 54; o.rmssd = 55; o.bedH = 23; o.inBedH = 8.2; o.steps = 9000; o.workout = false
        edit(&o)
        return Synthetic.day(testDay(25), calendar: testCal, profile: testProfile, options: o)
    }

    func testPipelineIsIdempotent() throws {
        let h = Self.history
        XCTAssertEqual(h.count, 24)
        let s = Self.typicalDay()
        let a = DailyPipeline.run(s.input, profile: testProfile, history: h)
        // rielaborare lo stesso giorno, anche con il suo stesso report già nello storico, non cambia nulla
        let h2 = History.upsert(a, into: h, calendar: testCal)
        let b = DailyPipeline.run(s.input, profile: testProfile, history: h2)
        let h3 = History.upsert(b, into: h2, calendar: testCal)
        XCTAssertEqual(try History.encode(h2), try History.encode(h3))
        XCTAssertEqual(h3.count, 25)
        XCTAssertEqual(a.cardioAge, b.cardioAge)
        XCTAssertEqual(a.workouts, b.workouts)
        // salvataggio e rilettura senza perdite
        let back = try History.decode(try History.encode(h3))
        XCTAssertEqual(try History.encode(back), try History.encode(h3))
        XCTAssertEqual(back.last?.stressTimeline.count, 288)
    }

    func testTypicalDayScoresAreInTheTypicalRange() throws {
        let r = DailyPipeline.run(Self.typicalDay().input, profile: testProfile, history: Self.history)
        XCTAssertFalse(r.calibrating)
        XCTAssertGreaterThanOrEqual(r.baselineNights, 20)
        let n = try XCTUnwrap(r.night)
        XCTAssertEqual(n.sleepIndex, 85, accuracy: 12)
        XCTAssertEqual(r.recovery, 80, accuracy: 15)
        XCTAssertTrue(["alto", "ottimale"].contains(r.recoveryLabel))
        XCTAssertTrue(r.flags.isEmpty, "\(r.flags)")
        XCTAssertEqual(try XCTUnwrap(n.skinTempDev), 0, accuracy: 0.2)
        XCTAssertEqual(try XCTUnwrap(r.stressAvg), 40, accuracy: 15)
        XCTAssertGreaterThan(r.stressRhythm, 80)
        XCTAssertEqual(r.steps, 9000, accuracy: 600)
        XCTAssertEqual(r.rhr, 54, accuracy: 3)
        XCTAssertEqual(r.zoneBounds.count, 6)
        XCTAssertEqual(r.zoneMinutesDay.count, 5)
        XCTAssertGreaterThan(r.kcalTotal, Energy.bmr(testProfile))
        XCTAssertGreaterThan(try XCTUnwrap(r.sri), 60)
        XCTAssertLessThan(r.sleepDebtH, 4)
    }

    func testRecoveryIsSeventyFiveWhenEverythingIsAtBaseline() {
        let b = Baselines(history: Self.history, before: testDay(25), calendar: testCal)
        XCTAssertTrue(b.rhr.ready && b.lnRMSSD.ready && b.temp.ready)
        var n = DailyPipeline.run(Self.typicalDay().input, profile: testProfile, history: Self.history).night!
        n.rhr = b.rhr.center; n.rmssd = exp(b.lnRMSSD.center); n.skinTempDev = 0
        var flat = b; flat.hrv7 = b.lnRMSSD.center
        let r = Recovery.score(sleepIndex: 80, night: n, stressRhythm: nil, acwr: nil, sleepDebtH: 0, baselines: flat)
        XCTAssertEqual(r.score, 100 * Stats.logistic(1.1), accuracy: 1e-6)     // ≈ 75
        XCTAssertEqual(r.label, "alto")
        // lo Stress Rhythm sposta al massimo di 10 punti
        let hi = Recovery.score(sleepIndex: 80, night: n, stressRhythm: 100, acwr: nil, sleepDebtH: 0, baselines: flat)
        let lo = Recovery.score(sleepIndex: 80, night: n, stressRhythm: 20, acwr: nil, sleepDebtH: 0, baselines: flat)
        XCTAssertEqual(hi.score - r.score, 10, accuracy: 1e-6)
        XCTAssertEqual(r.score - lo.score, 10, accuracy: 1e-6)
        XCTAssertEqual(Recovery.label(86), "ottimale")
        XCTAssertEqual(Recovery.label(60), "moderato")
        XCTAssertEqual(Recovery.label(40), "basso")
    }

    func testIllnessLowersRecoveryAndRaisesFlag() {
        let normal = DailyPipeline.run(Self.typicalDay().input, profile: testProfile, history: Self.history)
        let ill = DailyPipeline.run(Self.typicalDay { $0.rhr = 63; $0.rmssd = 30; $0.tempOffset = 0.9; $0.respRate = 17.5 }.input,
                                    profile: testProfile, history: Self.history)
        XCTAssertLessThan(ill.recovery, normal.recovery - 20)
        XCTAssertTrue(ill.flags.contains { $0.contains("Temperatura") }, "\(ill.flags)")
        XCTAssertGreaterThan(ill.night?.skinTempDev ?? 0, 0.6)
        XCTAssertLessThan(ill.night?.sleepIndex ?? 100, normal.night?.sleepIndex ?? 0)
    }

    func testDaytimeStressLowersStressRhythm() throws {
        let calm = DailyPipeline.run(Self.typicalDay().input, profile: testProfile, history: Self.history)
        let tense = DailyPipeline.run(Self.typicalDay { $0.dayHROffset = 18 }.input, profile: testProfile, history: Self.history)
        XCTAssertGreaterThan(try XCTUnwrap(tense.stressAvg), try XCTUnwrap(calm.stressAvg) + 15)
        XCTAssertLessThan(tense.stressRhythm, calm.stressRhythm - 30)
        XCTAssertLessThan(tense.recovery, calm.recovery)
        // la FC alta da seduti non diventa un allenamento
        XCTAssertTrue(tense.workouts.allSatisfy { $0.activity != "allenamento" })
        // di notte e durante le camminate lo stress non viene valutato
        XCTAssertNil(calm.stressTimeline[36])                              // 03:00
    }

    func testWorkoutDetectionEnergyAndMovement() throws {
        let r = DailyPipeline.run(Self.typicalDay { $0.workout = true; $0.steps = 12_000 }.input, profile: testProfile, history: Self.history)
        XCTAssertEqual(r.workouts.count, 1)
        let w = try XCTUnwrap(r.workouts.first)
        XCTAssertTrue(w.autoDetected)
        XCTAssertEqual(w.activity, "corsa")
        XCTAssertEqual(w.minutes, 40, accuracy: 6)
        XCTAssertEqual(Stats.hourOfDay(w.start, testCal), 18.5, accuracy: 0.1)
        XCTAssertEqual(w.avgHR, 0.84 * 191.2, accuracy: 8)
        XCTAssertEqual(w.zoneMinutes.reduce(0, +), w.minutes, accuracy: 3)
        XCTAssertEqual(r.trimp, w.trimp)
        XCTAssertGreaterThan(w.kcal, 350); XCTAssertLessThan(w.kcal, 750)
        XCTAssertEqual(r.steps, 12_000, accuracy: 700)
        XCTAssertGreaterThanOrEqual(r.activeHours, 4)
        XCTAssertGreaterThan(r.activeMinutes, 60)
        XCTAssertGreaterThan(r.movementIndex, 60)
        // con l'energia misurata da HealthKit si usa quella
        var input = Self.typicalDay().input
        input.hkActiveKcal = 512; input.hkBasalKcal = 1700
        let hk = DailyPipeline.run(input, profile: testProfile, history: Self.history)
        XCTAssertEqual(hk.kcalActive, 512); XCTAssertEqual(hk.kcalTotal, 2212)
    }

    func testHealthKitWorkoutIsNotDuplicated() {
        var input = Self.typicalDay { $0.workout = true }.input
        let start = testDay(25).addingTimeInterval(18.5 * 3600)
        input.hkWorkouts = [WorkoutRecord(start: start, end: start.addingTimeInterval(40 * 60), avgHR: 0, maxHR: 0, zoneMinutes: [],
                                          kcal: 480, autoDetected: false, activity: "corsa")]
        let r = DailyPipeline.run(input, profile: testProfile, history: Self.history)
        XCTAssertEqual(r.workouts.count, 1)
        XCTAssertFalse(r.workouts[0].autoDetected)
        XCTAssertEqual(r.workouts[0].kcal, 480)
        XCTAssertGreaterThan(r.workouts[0].avgHR, 140)                     // completato con la FC registrata
        XCTAssertEqual(r.workouts[0].zoneMinutes.count, 5)
    }

    func testSocialJetlag() throws {
        // lo storico sintetico va a letto ~1,1 h più tardi nei giorni liberi
        let r = DailyPipeline.run(Self.typicalDay().input, profile: testProfile, history: Self.history)
        XCTAssertEqual(try XCTUnwrap(r.socialJetlagH), 1.4, accuracy: 0.5)
        XCTAssertNotNil(r.chronotypeMSFsc)
        // caso costruito a mano: lavorativi 23:00-07:00, liberi 01:00-10:00
        func night(onset: Double, hours: Double) -> NightReport {
            var n = r.night!
            n.onsetH = Stats.wrap24(onset); n.wakeH = Stats.wrap24(onset + hours); n.midpointH = Stats.wrap24(onset + hours / 2); n.tstMin = hours * 60
            return n
        }
        var nights: [(date: Date, night: NightReport)] = []
        for d in 2...15 {                                                   // 2 novembre 2026 = lunedì
            let wd = testCal.component(.weekday, from: testDay(d))
            nights.append((testDay(d), wd == 1 || wd == 7 ? night(onset: 25, hours: 9) : night(onset: 23, hours: 8)))
        }
        let j = try XCTUnwrap(Circadian.socialJetlag(nights, workdays: [2, 3, 4, 5, 6], calendar: testCal))
        XCTAssertEqual(j.msw, 3, accuracy: 1e-6); XCTAssertEqual(j.msf, 5.5, accuracy: 1e-6)
        XCTAssertEqual(j.sjl, 2.5, accuracy: 1e-6)
        XCTAssertEqual(j.sjlSc, 2, accuracy: 1e-6)                          // differenza degli addormentamenti
        let sdWeek: Double = (5.0 * 8.0 + 2.0 * 9.0) / 7.0
        let expected: Double = 5.5 - (9.0 - sdWeek) / 2.0
        XCTAssertEqual(j.msfSc, expected, accuracy: 1e-6)
    }

    func testCircadianWindows() {
        let w = Circadian.windows(tMinH: 4.5, wakeH: 7, bedH: 23)
        func win(_ n: String) -> CircadianWindow { w.first { $0.name == n }! }
        XCTAssertEqual(win("Zona del minimo").label, "04:15–04:45")
        XCTAssertEqual(win("Avanzamento di fase").startH, 4.75)
        XCTAssertEqual(win("Ritardo di fase").label, "20:30–00:30")       // da 8 a 4 ore prima del minimo successivo
        XCTAssertEqual(win("Zona morta circadiana").endH, win("Ritardo di fase").startH)
        XCTAssertEqual(win("Luce").label, "07:00–08:00")
        XCTAssertEqual(win("Caffeina").label, "08:30–13:00")
        XCTAssertEqual(win("Rallentamento").label, "22:00–23:00")
        XCTAssertEqual(CircadianWindow.clock(25.5), "01:30")
        for x in w { XCTAssertLessThanOrEqual(x.startH, x.endH, x.name) }
        // allineamento: tutto in fase e regolare -> alto; fuori fase e irregolare -> basso
        XCTAssertGreaterThan(Circadian.alignment(lastMidH: 3.2, referenceMidH: 3, sri: 88, daylightMin: 80, sjlH: 0.4), 90)
        XCTAssertLessThan(Circadian.alignment(lastMidH: 6.5, referenceMidH: 3, sri: 45, daylightMin: 5, sjlH: 2.5), 15)
    }

    func testFitnessModels() {
        // esempio numerico del modello di Nes: uomo, 24 anni, BMI 23,8, FC a riposo 68, indice di attività 8,5
        let p = UserProfile(age: 24, sex: .male, heightCm: 180, weightKg: 23.8 * 1.8 * 1.8)
        XCTAssertEqual(Fitness.nes(profile: p, rhr: 68, paIndex: 8.5).value, 52.82, accuracy: 0.01)
        let f = UserProfile(age: 40, sex: .female, heightCm: 165, weightKg: 22 * 1.65 * 1.65)
        let nesF: Double = 70.77 - 9.76 - 16.478 - 6.42
        XCTAssertEqual(Fitness.nes(profile: f, rhr: 60, paIndex: 0).value, nesF, accuracy: 0.01)
        XCTAssertEqual(Fitness.uth(hrMax: 190, rhr: 50).value, 58.14, accuracy: 0.01)
        // fusione: la stima più precisa pesa di più, l'errore combinato è minore di ciascuno
        let fused = Fitness.fuse([.init(name: "a", value: 40, see: 2), .init(name: "b", value: 50, see: 4)])!
        XCTAssertEqual(fused.value, 42, accuracy: 1e-9)
        XCTAssertLessThan(fused.see, 2)
        // Cardio Age: il VO2max mediano della propria età restituisce l'età anagrafica
        for sex in Sex.allCases { for age in [25.0, 31, 48, 60, 75] {
            XCTAssertEqual(Fitness.cardioAge(vo2: Fitness.expectedVO2(age: age, sex: sex), sex: sex), age, accuracy: 1e-6)
        } }
        XCTAssertEqual(Fitness.cardioAge(vo2: 80, sex: .male), 18)
        XCTAssertEqual(Fitness.cardioAge(vo2: 10, sex: .female), 90)
        XCTAssertLessThan(Fitness.cardioAge(vo2: 45, sex: .male), Fitness.cardioAge(vo2: 38, sex: .male))
        XCTAssertEqual(Fitness.smooth(previous: 30, raw: 40), 31.5, accuracy: 1e-9)
        XCTAssertEqual(Fitness.smooth(previous: nil, raw: 40), 40)
        // proxy del questionario: 3 corse/settimana, 40 min moderate -> 2,5 x 2 x 0,75 = 3,75
        let t = testDay(1)
        let w = (0..<12).map { WorkoutRecord(start: t.addingTimeInterval(Double($0) * 2.3 * 86_400), end: t.addingTimeInterval(Double($0) * 2.3 * 86_400 + 2400),
                                             avgHR: 150, maxHR: 170, zoneMinutes: [0, 0, 20, 20, 0], kcal: 400, autoDetected: false) }
        XCTAssertEqual(Fitness.paIndex(workouts: w, hrMax: 190), 3.75)
        XCTAssertEqual(Fitness.paIndex(workouts: [], hrMax: 190), 0)
    }

    func testCardioAgeMovesSlowly() {
        let h = Self.history
        let ages = h.map { $0.cardioAge }
        for k in 1..<ages.count { XCTAssertLessThan(abs(ages[k] - ages[k - 1]), 2.5) }
        XCTAssertGreaterThan(h.last!.vo2max, 35); XCTAssertLessThan(h.last!.vo2max, 65)
        XCTAssertTrue(h.last!.vo2Source.contains("Nes"))
        // la stima Apple recente entra nella fusione
        var input = Self.typicalDay().input
        input.appleVO2 = 44; input.appleVO2AgeDays = 3
        let r = DailyPipeline.run(input, profile: testProfile, history: h)
        XCTAssertTrue(r.vo2Source.contains("Apple"))
        XCTAssertLessThan(r.vo2max, h.last!.vo2max)
    }

    func testDayInputAssembly() {
        let day = testDay(10), now = day.addingTimeInterval(12 * 3600)
        let hr = [TimedValue(date: day.addingTimeInterval(10), value: 60), TimedValue(date: day.addingTimeInterval(20), value: 64),
                  TimedValue(date: day.addingTimeInterval(300), value: 70),            // buco di 5 min: interpolato
                  TimedValue(date: day.addingTimeInterval(4000), value: 80)]           // buco di un'ora: resta vuoto
        let steps = [QuantitySpan(start: day.addingTimeInterval(45), end: day.addingTimeInterval(105), value: 120)]
        let i0 = Int(day.timeIntervalSince1970 / 30)
        let motion = [MotionEpoch(index: i0 + 3, counts: 42, angleChange: 7, steps: 55, samples: 1500)]
        let sleep = [SleepSegment(start: day.addingTimeInterval(-3600), end: day.addingTimeInterval(-1800), stage: .deep),
                     SleepSegment(start: day.addingTimeInterval(-7200), end: day, stage: nil)]
        let d = DayInput.make(day: day, calendar: testCal, now: now, hr: hr, steps: steps, motion: motion, appleSleep: sleep)
        XCTAssertEqual(d.epochs.count, 18 * 120)                                       // 6 ore prima + 12 ore del giorno
        XCTAssertEqual(d.epochs[0].start, day.addingTimeInterval(-6 * 3600))
        let m = 720                                                                    // indice della mezzanotte
        XCTAssertEqual(d.epochs[m].hr, 62)
        XCTAssertEqual(d.epochs[m + 5].hr ?? 0, 66, accuracy: 1.5)
        XCTAssertNil(d.epochs[m + 60].hr)
        XCTAssertEqual(d.epochs[m + 133].hr, 80)
        XCTAssertEqual(d.epochs.map { $0.steps }.reduce(0, +), 120, accuracy: 1e-9)    // i passi si conservano
        XCTAssertEqual(d.epochs[m + 1].steps, 30, accuracy: 1e-9)
        XCTAssertEqual(d.epochs[m + 2].steps, 60, accuracy: 1e-9)
        XCTAssertEqual(d.epochs[m + 3].motion, 42); XCTAssertEqual(d.epochs[m + 3].angleChange, 7)
        XCTAssertEqual(d.epochs[m - 100].appleStage, .deep)
        XCTAssertNil(d.epochs[m - 30].appleStage)
        // senza contapassi di sistema valgono i passi contati dal Watch
        let w = DayInput.make(day: day, calendar: testCal, now: now, hr: hr, steps: [], motion: motion)
        XCTAssertEqual(w.epochs.map { $0.steps }.reduce(0, +), 55)
        // un giorno senza alcun dato non fa cadere la pipeline
        let empty = DailyPipeline.run(DayInput.make(day: day, calendar: testCal, now: now, hr: [], steps: [], motion: []), profile: testProfile, history: [])
        XCTAssertTrue(empty.night == nil); XCTAssertEqual(empty.steps, 0); XCTAssertEqual(empty.rhr, 60)
        XCTAssertTrue(empty.calibrating)
    }

    func testHistoryUpsertKeepsOrderAndLimit() {
        var h: [DailyReport] = []
        let one = Self.history[0]
        for k in [5, 1, 3, 1] {
            var r = one; r.date = testDay(k); r.steps = Double(k)
            h = History.upsert(r, into: h, calendar: testCal, keepDays: 3)
        }
        XCTAssertEqual(h.map { $0.steps }, [3, 5])
    }
}
