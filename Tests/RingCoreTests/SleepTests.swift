import XCTest
@testable import RingCore

let testCal = Synthetic.utc
let testProfile = UserProfile(age: 24, sex: .male, heightCm: 180, weightKg: 75)
func testDay(_ d: Int) -> Date { testCal.date(from: DateComponents(year: 2026, month: 11, day: d))! }

final class SleepTests: XCTestCase {
    func testSensorOnlyNightMatchesGroundTruth() throws {
        for seed in [1, 2, 3] as [UInt64] {
            var o = Synthetic.Options(); o.seed = seed; o.bedH = 22.8 + Double(seed) * 0.4
            let s = Synthetic.day(testDay(4), profile: testProfile, options: o)
            let r = DailyPipeline.run(s.input, profile: testProfile, history: [])
            let n = try XCTUnwrap(r.night, "notte non rilevata (seed \(seed))")
            XCTAssertEqual(n.sleepOnset.timeIntervalSince(s.onset) / 60, 0, accuracy: 10, "addormentamento, seed \(seed)")
            XCTAssertEqual(n.finalWake.timeIntervalSince(s.wake) / 60, 0, accuracy: 10, "risveglio, seed \(seed)")
            // identità delle metriche
            XCTAssertEqual(n.lightMin + n.deepMin + n.remMin, n.tstMin, accuracy: 1e-6)
            XCTAssertEqual(n.tstMin + n.wasoMin, n.finalWake.timeIntervalSince(n.sleepOnset) / 60, accuracy: 1e-6)
            XCTAssertEqual(n.efficiency, 100 * n.tstMin / n.tibMin, accuracy: 1e-9)
            XCTAssertEqual(n.stages.count, Int(n.tibMin * 2))
            XCTAssertEqual(n.sleepRuns.map { $0.minutes }.reduce(0, +), n.tstMin, accuracy: 1e-6)
            // stadiazione contro la verità
            let i0 = Int(n.inBed.timeIntervalSince(s.input.epochs[0].start) / 30)
            var ok = 0
            for (k, st) in n.stages.enumerated() where s.truth[i0 + k].rawValue == st { ok += 1 }
            XCTAssertGreaterThan(Double(ok) / Double(n.stages.count), 0.65, "accuratezza a 4 classi, seed \(seed)")
            let truthSleep = Double(s.truth[0..<2400].filter { $0.isSleep }.count) / 2
            XCTAssertEqual(n.tstMin, truthSleep, accuracy: 25)
            // parametri vitali
            XCTAssertEqual(try XCTUnwrap(n.rhr), 54, accuracy: 3)
            XCTAssertEqual(try XCTUnwrap(n.respRate), 14.5, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(n.rmssd), 50, accuracy: 15)
            XCTAssertLessThan(try XCTUnwrap(n.hrNadirFrac), 0.85)
            XCTAssertNotNil(n.tempMinH)
            XCTAssertTrue(r.naps.isEmpty)
        }
    }

    func testDeepSleepEarlyAndREMLate() throws {
        let s = Synthetic.day(testDay(4), profile: testProfile)
        let n = try XCTUnwrap(DailyPipeline.run(s.input, profile: testProfile, history: []).night)
        let half = n.stages.count / 2
        func count(_ st: SleepStage, _ r: Range<Int>) -> Int { n.stages[r].filter { $0 == st.rawValue }.count }
        XCTAssertGreaterThan(count(.deep, 0..<half), count(.deep, half..<n.stages.count))
        XCTAssertGreaterThan(count(.rem, half..<n.stages.count), count(.rem, 0..<half))
        XCTAssertGreaterThanOrEqual(n.cycles, 3)
        XCTAssertLessThanOrEqual(n.cycles, 8)
    }

    /// Solo sensori: concordanza a 4 classi e quota di sonno profondo restano in un intervallo ragionevole
    /// (dati sintetici: è un controllo di regressione, non una misura di accuratezza reale).
    func testSensorOnlyStagingAgreementAndDeepShare() throws {
        var ok = 0, tot = 0, deepEst = 0, deepTruth = 0
        for seed in [5, 6, 7, 8] as [UInt64] {
            var o = Synthetic.Options(); o.seed = seed
            let s = Synthetic.day(testDay(12), profile: testProfile, options: o)
            let n = try XCTUnwrap(DailyPipeline.run(s.input, profile: testProfile, history: []).night)
            let i0 = Int((n.inBed.timeIntervalSince(s.input.epochs[0].start) / 30).rounded())
            for (k, st) in n.stages.enumerated() where i0 + k >= 0 && i0 + k < s.truth.count {
                tot += 1
                if s.truth[i0 + k].rawValue == st { ok += 1 }
                if st == SleepStage.deep.rawValue { deepEst += 1 }
                if s.truth[i0 + k] == .deep { deepTruth += 1 }
            }
        }
        XCTAssertGreaterThan(Double(ok) / Double(tot), 0.68)
        XCTAssertEqual(Double(deepEst) / Double(deepTruth), 1, accuracy: 0.35)
    }

    func testAppleStagesImproveStagingAndDefineThePeriod() throws {
        var o = Synthetic.Options(); o.appleStages = true
        let s = Synthetic.day(testDay(4), profile: testProfile, options: o)
        let n = try XCTUnwrap(DailyPipeline.run(s.input, profile: testProfile, history: []).night)
        XCTAssertEqual(n.inBed.timeIntervalSince(s.lightsOut), 0, accuracy: 60)
        let i0 = Int(n.inBed.timeIntervalSince(s.input.epochs[0].start) / 30)
        var ok = 0
        for (k, st) in n.stages.enumerated() where s.truth[i0 + k].rawValue == st { ok += 1 }
        XCTAssertGreaterThan(Double(ok) / Double(n.stages.count), 0.78)
    }

    func testNapIsSeparateFromTheNight() throws {
        var o = Synthetic.Options(); o.nap = true
        let s = Synthetic.day(testDay(4), profile: testProfile, options: o)
        let r = DailyPipeline.run(s.input, profile: testProfile, history: [])
        let n = try XCTUnwrap(r.night)
        XCTAssertEqual(n.finalWake.timeIntervalSince(s.wake) / 60, 0, accuracy: 10)      // il sonnellino non allunga la notte
        XCTAssertEqual(r.naps.count, 1)
        XCTAssertEqual(r.napsMin, 40, accuracy: 12)
        XCTAssertEqual(try XCTUnwrap(r.dailySleepMin), n.tstMin + r.napsMin, accuracy: 1e-9)
        let h = Stats.hourOfDay(r.naps[0].start, testCal)
        XCTAssertEqual(h, 14, accuracy: 0.3)
    }

    func testWatchNotWornIsNotSleep() {
        // orologio in carica tutta la notte: nessuna FC e nessun movimento -> nessuna notte inventata
        var s = Synthetic.day(testDay(4), profile: testProfile).input
        for i in 0..<1680 { s.epochs[i].hr = nil; s.epochs[i].motion = 0; s.epochs[i].angleChange = 0 }
        s.ibiSeries = []
        let r = DailyPipeline.run(s, profile: testProfile, history: [])
        XCTAssertTrue(r.night == nil)
        XCTAssertNil(r.dailySleepMin)
        XCTAssertEqual(r.sleepDebtH, 0)                                                   // un giorno senza dati non crea debito
    }

    func testSleepStillInProgressIsNotReported() {
        var s = Synthetic.day(testDay(4), profile: testProfile).input
        let cut = 720 + 4 * 120                                                           // elaborazione alle 04:00
        s.epochs = Array(s.epochs.prefix(cut)); s.now = s.epochs.last!.start.addingTimeInterval(30)
        let r = DailyPipeline.run(s, profile: testProfile, history: [])
        XCTAssertTrue(r.night == nil)
        XCTAssertEqual(r.kcalTotal, Energy.bmr(testProfile) * 4 / 24, accuracy: 30)       // basale proporzionale alle ore trascorse
    }

    func testSleepDebt() {
        // 3 notti da 6 h con fabbisogno 8 h: 2 -> 3,7 -> 5,145
        XCTAssertEqual(SleepMetrics.sleepDebtH([360, 360, 360], needH: 8), 5.145, accuracy: 1e-9)
        XCTAssertEqual(SleepMetrics.sleepDebtH([360, nil, 360], needH: 8), 3.7, accuracy: 1e-9)   // giorno senza dati saltato
        XCTAssertEqual(SleepMetrics.sleepDebtH([360, 600, 600], needH: 8), 0)                      // recuperato
        XCTAssertEqual(SleepMetrics.sleepDebtH([], needH: 8), 0)
    }

    func testSleepRegularityIndex() throws {
        let days = (1...6).map { testDay($0) }
        func night(_ d: Date, bed: Double, hours: Double) -> DateSpan {
            DateSpan(start: d.addingTimeInterval((bed - 24) * 3600), end: d.addingTimeInterval((bed - 24 + hours) * 3600))
        }
        let regular = days.map { night($0, bed: 23, hours: 8) }
        XCTAssertEqual(try XCTUnwrap(SleepMetrics.sri(days: days, sleep: regular, calendar: testCal)), 100, accuracy: 1e-9)
        // orari sfalsati di 4 ore a giorni alterni: 8 ore su 24 in disaccordo -> SRI = 100 - 200 * 8/24
        let shifted = days.enumerated().map { night($1, bed: $0 % 2 == 0 ? 23 : 27, hours: 8) }
        XCTAssertEqual(try XCTUnwrap(SleepMetrics.sri(days: days, sleep: shifted, calendar: testCal)), 100 - 200 * 8 / 24, accuracy: 0.5)
        // con un giorno mancante le coppie non consecutive non vengono confrontate
        XCTAssertNil(SleepMetrics.sri(days: [days[0], days[2], days[4]], sleep: regular, calendar: testCal))
    }

    func testConsistency() throws {
        XCTAssertEqual(try XCTUnwrap(SleepMetrics.consistency(onsetH: [23, 23.1, 22.9, 23], wakeH: [7, 7.1, 6.9, 7])), 100, accuracy: 1e-9)
        let poor = try XCTUnwrap(SleepMetrics.consistency(onsetH: [22, 1, 23.5, 2.5], wakeH: [6, 9.5, 7, 10]))
        XCTAssertLessThan(poor, 10)
        XCTAssertNil(SleepMetrics.consistency(onsetH: [23, 23.5], wakeH: [7, 7.5]))
        // a cavallo della mezzanotte: 23:50 e 00:10 distano 20 minuti, non 23 ore
        XCTAssertEqual(try XCTUnwrap(SleepMetrics.consistency(onsetH: [23.83, 0.17, 0, 23.9], wakeH: [7, 7, 7, 7])), 100, accuracy: 1e-9)
    }

    func testDurationAndRestorativeTargets() {
        XCTAssertEqual(SleepMetrics.durationScore(480, age: 30, need: 8), 1)
        XCTAssertEqual(SleepMetrics.durationScore(240, age: 30, need: 8), 0)
        XCTAssertLessThan(SleepMetrics.durationScore(360, age: 30, need: 8), 0.6)
        XCTAssertLessThan(SleepMetrics.durationScore(690, age: 30, need: 8), 1)           // sonno molto lungo: lieve penalità
        XCTAssertEqual(SleepMetrics.restorativeTarget(age: 25), 0.40, accuracy: 1e-9)
        XCTAssertEqual(SleepMetrics.restorativeTarget(age: 65), 0.34, accuracy: 1e-9)
        XCTAssertEqual(SleepMetrics.label(90), "molto ristoratore")
        XCTAssertEqual(SleepMetrics.label(75), "solido")
        XCTAssertEqual(SleepMetrics.label(55), "insufficiente")
    }
}
