import Foundation
import XCTest
@testable import RingCore

/// RC-AUD-02. Fixture manuali. Gli attesi derivano dalle specifiche, senza generatore del prodotto.
final class IndependentAuditTests: XCTestCase {
    private let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65, hrMaxOverride: 200)
    private let minute: TimeInterval = 60

    private func calendar(_ zone: String = "UTC") throws -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = try XCTUnwrap(TimeZone(identifier: zone), "Fuso IANA non disponibile: \(zone)")
        return result
    }

    private func date(_ month: Int, _ day: Int, calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
    }

    private func epochs(start: Date, count: Int, hr: Double? = nil) -> [Epoch] {
        (0..<count).map { Epoch(start: start.addingTimeInterval(Double($0) * 30), hr: hr) }
    }

    private func report(day: Date, calendar: Calendar, rhr: Double?, rmssd: Double? = nil) throws -> DailyReport {
        let input = DayInput(day: day, calendar: calendar, now: day.addingTimeInterval(86_400), epochs: [])
        var result = DailyPipeline.run(input, profile: profile, history: [])
        let nightEpochs = epochs(start: day, count: 80)
        var night = try XCTUnwrap(SleepMetrics.night(
            nightEpochs, stages: Array(repeating: .light, count: 80), beats: [], calendar: calendar))
        night.rhr = rhr
        night.rmssd = rmssd
        result.night = night
        result.dailySleepMin = 40
        return result
    }

    func testBaselineUsesSevenDistinctPreviousValuesInSixtyLocalDays() throws {
        let cal = try calendar()
        let day = try date(7, 1, calendar: cal)
        func previous(_ offset: Int) throws -> Date {
            try XCTUnwrap(cal.date(byAdding: .day, value: offset, to: day))
        }
        // Giorni -60 ... -1 e notte odierna estrema. RHR ordinata: [50,52,54,56,58,60,62].
        let offsets = [-60, -6, -5, -4, -3, -2, -1]
        var history = try offsets.enumerated().map { index, offset in
            try report(day: previous(offset), calendar: cal,
                       rhr: Double(50 + 2 * index), rmssd: index >= 5 ? 30 : nil)
        }
        history.append(try report(day: previous(-61), calendar: cal, rhr: 103, rmssd: 200))
        history.append(try report(day: day, calendar: cal, rhr: 105, rmssd: 180))
        let b = Baselines(history: Array(history.reversed()), before: day, calendar: cal)
        XCTAssertEqual(b.nights, 7)
        XCTAssertEqual(b.rhr.n, 7)
        XCTAssertEqual(b.rhr.center, 56, accuracy: 1e-9)
        XCTAssertTrue(b.rhr.ready)
        XCTAssertEqual(b.lnRMSSD.n, 2)
        XCTAssertFalse(b.lnRMSSD.ready)
        XCTAssertFalse(b.temp.ready)
        XCTAssertFalse(b.resp.ready)
        XCTAssertNil(b.hrv7)
        XCTAssertTrue(DailyPipeline.run(
            DayInput(day: day, calendar: cal, now: day, epochs: []),
            profile: profile, history: history
        ).calibrating, "Notti sufficienti per RHR, HRV e temperatura ancora in calibrazione")
    }

    func testDuplicatePastDayCannotCalibrateOrIncreaseHistoryCounters() throws {
        let cal = try calendar()
        let day = try date(7, 8, calendar: cal)
        var history = try (1...6).map { gap in
            try report(day: date(7, 8 - gap, calendar: cal), calendar: cal, rhr: 55, rmssd: 35)
        }
        history.append(try XCTUnwrap(history.first))
        let b = Baselines(history: history, before: day, calendar: cal)
        XCTAssertEqual(b.nights, 6)
        XCTAssertEqual(b.rhr.n, 6)
        XCTAssertEqual(b.lnRMSSD.n, 6)
        XCTAssertFalse(b.rhr.ready)
        XCTAssertFalse(b.lnRMSSD.ready)
        XCTAssertEqual(b.days28, 6)
        XCTAssertEqual(b.previousDebtDays.count, 6)
    }

    func testTwoRevisionsForOnePastDateStillProvideOneBaselineDay() throws {
        let cal = try calendar()
        let day = try date(7, 8, calendar: cal)
        let previous = try date(7, 7, calendar: cal)
        let first = try report(day: previous, calendar: cal, rhr: 54, rmssd: 35)
        var revision = first
        revision.night?.rhr = 57
        let b = Baselines(history: [first, revision], before: day, calendar: cal)
        XCTAssertEqual(b.nights, 1)
        XCTAssertEqual(b.rhr.n, 1)
        XCTAssertEqual(b.lnRMSSD.n, 1)
        XCTAssertEqual(b.days28, 1)
        XCTAssertEqual(b.previousDebtDays.count, 1)
    }

    func testDayRetryUpsertsOneReportAndDoesNotRebaseAgainstItself() throws {
        let cal = try calendar()
        let previous = try date(7, 7, calendar: cal)
        let day = try date(7, 8, calendar: cal)
        let input = DayInput(day: day, calendar: cal, now: day.addingTimeInterval(86_400), epochs: [])
        let prior = try report(day: previous, calendar: cal, rhr: 55, rmssd: 34)
        let first = DailyPipeline.run(input, profile: profile, history: [prior])
        let saved = History.upsert(first, into: [prior], calendar: cal)
        let second = DailyPipeline.run(input, profile: profile, history: saved)
        let retried = History.upsert(second, into: saved, calendar: cal)
        XCTAssertEqual(retried.map(\.date), [previous, day])
        XCTAssertEqual(second.baselineNights, 1)
        XCTAssertEqual(try History.encode(retried), try History.encode(saved))
    }

    func testIdenticalWorkoutReplayCountsOneWorkoutAndThirtyTRIMP() throws {
        let cal = try calendar()
        let day = try date(7, 8, calendar: cal)
        let end = day.addingTimeInterval(10 * minute)
        var input = DayInput(day: day, calendar: cal, now: end, epochs: epochs(start: day, count: 20, hr: 155))
        // 155 bpm con FCmax 200 = zona 3 (140–159); 10 min × 3 = 30 TRIMP.
        let workout = WorkoutRecord(start: day, end: end, avgHR: 155, maxHR: 155, zoneMinutes: [],
                                    kcal: 42, autoDetected: false, activity: "corsa sintetica")
        input.hkWorkouts = [workout, workout]
        let result = DailyPipeline.run(input, profile: profile, history: [])
        XCTAssertEqual(result.workouts.count, 1)
        XCTAssertEqual(result.trimp, 30, accuracy: 1e-9)
        XCTAssertEqual(result.kcalActive, 42, accuracy: 1e-9)
        let saved = History.upsert(result, into: [], calendar: cal)
        let tomorrow = try date(7, 9, calendar: cal)
        let b = Baselines(history: saved, before: tomorrow, calendar: cal)
        XCTAssertEqual(b.workouts.count, 1)
        XCTAssertEqual(try XCTUnwrap(b.trimp28.last), 30, accuracy: 1e-9)
    }

    func testMissingDataIsNotPresentedAsRestingPulseOrFavorableRecovery() throws {
        let cal = try calendar()
        let day = try date(7, 8, calendar: cal)
        let now = day.addingTimeInterval(18 * 3600)
        let missing = DayInput(day: day, calendar: cal, now: now, epochs: [])
        let partial = DayInput.make(day: day, calendar: cal, now: now,
                                    hr: [TimedValue(date: day.addingTimeInterval(12 * 3600), value: 132)],
                                    steps: [], motion: [])
        let reasons = ["non disponibile", "dati insufficienti", "in calibrazione", "dato non aggiornato"]
        for (label, input) in [("mancante", missing), ("parziale", partial)] {
            let result = DailyPipeline.run(input, profile: profile, history: [])
            XCTAssertNil(result.night, label)
            XCTAssertNil(result.dailySleepMin, label)
            XCTAssertNil(result.stressAvg, label)
            XCTAssertTrue(result.calibrating, label)
            let pulse = try XCTUnwrap(Presentation.heartLines(result).first { $0.name == "FC a riposo" })
            XCTAssertTrue(reasons.contains { pulse.value.lowercased().contains($0) }, "\(label): \(pulse.value)")
            let steps = try XCTUnwrap(Presentation.activityLines(result).first { $0.name == "Passi" })
            XCTAssertTrue(reasons.contains { steps.value.lowercased().contains($0) }, "\(label): \(steps.value)")
            XCTAssertTrue(reasons.contains { result.recoveryLabel.lowercased().contains($0) },
                          "\(label): \(result.recoveryLabel)")
        }
    }

    func testObservedZeroEnergyOverridesAPositiveFallback() {
        let workout = WorkoutRecord(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 600),
                                    avgHR: 120, maxHR: 140, zoneMinutes: [], kcal: 36,
                                    autoDetected: false, activity: "prova")
        let observedActive = Energy.daily(profile, dayFraction: 1, hkActive: 0, hkBasal: 1500,
                                          workouts: [workout], stepsOutside: 0)
        let missingActive = Energy.daily(profile, dayFraction: 1, hkActive: nil, hkBasal: 1500,
                                         workouts: [workout], stepsOutside: 0)
        let observedBasal = Energy.daily(profile, dayFraction: 1, hkActive: 12, hkBasal: 0,
                                         workouts: [], stepsOutside: 0)
        XCTAssertEqual(observedActive.active, 0)
        XCTAssertEqual(observedActive.total, 1500)
        XCTAssertEqual(missingActive.active, 36)
        XCTAssertEqual(missingActive.total, 1536)
        XCTAssertEqual(observedBasal.total, 12)
    }

    func testObservedInBedSpansLatenessAwakeningAndFinalRise() throws {
        let cal = try calendar()
        let day = try date(7, 8, calendar: cal)
        // A letto 23:00–02:42. Sonno 23:10–00:50 e 00:52–02:32, veglia 2 min fra i due.
        let bed = day.addingTimeInterval(-60 * minute)
        func at(_ offset: Double) -> Date { bed.addingTimeInterval(offset * minute) }
        let sleep = [
            SleepSegment(start: at(0), end: at(222), stage: nil),
            SleepSegment(start: at(10), end: at(110), stage: .light),
            SleepSegment(start: at(110), end: at(112), stage: .wake),
            SleepSegment(start: at(112), end: at(212), stage: .light)
        ]
        let input = DayInput.make(day: day, calendar: cal, now: at(300), hr: [], steps: [], motion: [], appleSleep: sleep)
        let result = DailyPipeline.run(input, profile: profile, history: [])
        let night = try XCTUnwrap(result.night)
        XCTAssertEqual(result.date, day)
        XCTAssertEqual(night.inBed, at(0))
        XCTAssertEqual(night.sleepOnset, at(10))
        XCTAssertEqual(night.finalWake, at(212))
        XCTAssertEqual(night.outOfBed, at(222))
        XCTAssertEqual(night.tibMin, 222, accuracy: 1e-9)
        XCTAssertEqual(night.tstMin, 200, accuracy: 1e-9)
        XCTAssertEqual(night.solMin, 10, accuracy: 1e-9)
        XCTAssertEqual(night.wasoMin, 2, accuracy: 1e-9)
        XCTAssertEqual(night.efficiency, 100 * 200.0 / 222, accuracy: 1e-9)
        XCTAssertEqual(night.awakenings, 1)
    }

    func testSleepRunsExcludeFiveMinutesBeforePersistentOnset() throws {
        let cal = try calendar()
        let day = try date(7, 8, calendar: cal)
        // Primi 5 min isolati, 10 min di veglia, poi 40 min di sonno: onset a 15 min.
        let stages = Array(repeating: SleepStage.light, count: 10)
            + Array(repeating: .wake, count: 20) + Array(repeating: .light, count: 80)
        let night = try XCTUnwrap(SleepMetrics.night(
            epochs(start: day, count: 110), stages: stages, beats: [], calendar: cal))
        XCTAssertEqual(night.solMin, 15, accuracy: 1e-9)
        XCTAssertEqual(night.tstMin, 40, accuracy: 1e-9)
        XCTAssertEqual(night.sleepRuns.first?.start, day.addingTimeInterval(15 * minute))
        XCTAssertEqual(night.sleepRuns.map(\.minutes).reduce(0, +), 40, accuracy: 1e-9)
    }

    func testDuplicateNinetyMinuteSleepSampleDoesNotBecomeMainNight() throws {
        let cal = try calendar()
        let day = try date(7, 8, calendar: cal)
        let start = day.addingTimeInterval(13 * 3600)
        let sleep = SleepSegment(start: start, end: start.addingTimeInterval(90 * minute), stage: .light)
        let input = DayInput.make(day: day, calendar: cal, now: day.addingTimeInterval(86_400),
                                  hr: [], steps: [], motion: [], appleSleep: [sleep, sleep])
        let result = DailyPipeline.run(input, profile: profile, history: [])
        XCTAssertNil(result.night)
        XCTAssertEqual(result.naps.count, 1)
        XCTAssertEqual(result.napsMin, 90, accuracy: 1e-9)
        XCTAssertNil(result.dailySleepMin)
    }

    func testNapWithTenMinuteGapCountsFortyMinutesOfSleep() throws {
        let cal = try calendar()
        let day = try date(7, 8, calendar: cal)
        func at(_ offset: Double) -> Date { day.addingTimeInterval(offset * minute) }
        // Notte 23:00–06:00 = 420 min. Sonnellino 13:00–13:50, con buco 13:20–13:30.
        let sleep = [
            SleepSegment(start: at(-60), end: at(360), stage: .light),
            SleepSegment(start: at(780), end: at(800), stage: .light),
            SleepSegment(start: at(810), end: at(830), stage: .light)
        ]
        let input = DayInput.make(day: day, calendar: cal, now: at(1440), hr: [], steps: [], motion: [],
                                  appleSleep: sleep)
        let result = DailyPipeline.run(input, profile: profile, history: [])
        XCTAssertEqual(try XCTUnwrap(result.night).tstMin, 420, accuracy: 1e-9)
        XCTAssertEqual(result.napsMin, 40, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.dailySleepMin), 460, accuracy: 1e-9)
        XCTAssertEqual(result.sleepDebtH, 1.0 / 3.0, accuracy: 1e-9)
    }

    func testObservedWakeInsideNapChangesSRIForBothAdjacentDayPairs() throws {
        let cal = try calendar()
        func sri(fragmented: Bool) throws -> Double {
            var history: [DailyReport] = []
            for d in 5...8 {
                let day = try date(7, d, calendar: cal)
                func at(_ offset: Double) -> Date { day.addingTimeInterval(offset * minute) }
                let napMiddle: SleepStage = (d == 6 && fragmented) ? .wake : .light
                let stages = [
                    SleepSegment(start: at(-60), end: at(360), stage: .light),
                    SleepSegment(start: at(780), end: at(800), stage: .light),
                    SleepSegment(start: at(800), end: at(810), stage: napMiddle),
                    SleepSegment(start: at(810), end: at(830), stage: .light)
                ]
                // Dati sintetici continui, senza un buco di copertura durante il sonnellino.
                let hr = (0..<3600).map { i in TimedValue(date: at(-360 + Double(i) / 2), value: 80) }
                let input = DayInput.make(day: day, calendar: cal, now: at(1440), hr: hr, steps: [],
                                          motion: [], appleSleep: stages)
                let result = DailyPipeline.run(input, profile: profile, history: history)
                history = History.upsert(result, into: history, calendar: cal)
            }
            return try XCTUnwrap(history.last?.sri)
        }
        let continuous = try sri(fragmented: false)
        let fragmented = try sri(fragmented: true)
        // La veglia di 10 min differisce da entrambe le finestre adiacenti.
        XCTAssertEqual(continuous - fragmented, 200.0 * 20 / (3 * 1440), accuracy: 1e-9)
    }

    func testUnknownArchivedStageDoesNotBecomeObservedWakeInHypnogram() throws {
        let cal = try calendar()
        let day = try date(7, 8, calendar: cal)
        var night = try XCTUnwrap(report(day: day, calendar: cal, rhr: nil).night)
        night.stages = [SleepStage.light.rawValue, 999, SleepStage.deep.rawValue]
        let runs = Presentation.hypnogram(night)
        XCTAssertFalse(runs.contains { $0.stage == .wake })
        XCTAssertTrue(runs.contains { $0.stage == .light })
        XCTAssertTrue(runs.contains { $0.stage == .deep })
    }

    func testUnobservedMovementGapBetweenTwoSamplesDoesNotBecomeSleep() throws {
        let cal = try calendar()
        let day = try date(7, 8, calendar: cal)
        let now = day.addingTimeInterval(8 * 3600)
        let index = Int(day.timeIntervalSince1970 / 30)
        let motion = [
            MotionEpoch(index: index, counts: 20, angleChange: 8, steps: 0, samples: 1),
            MotionEpoch(index: index + 839, counts: 20, angleChange: 8, steps: 0, samples: 1)
        ]
        let input = DayInput.make(day: day, calendar: cal, now: now, hr: [], steps: [], motion: motion)
        // Due epoche osservate e nessuna FC, quindi nessuna evidenza di tre ore di sonno.
        let periods = SleepDetection.detect(input.epochs, apple: [], mainEnd: day...now, napWindow: day..<now)
        XCTAssertNil(periods.main)
        XCTAssertTrue(periods.naps.isEmpty)
    }

    func testRomeDSTDaysHaveOwnLastMinuteAndCorrectStressWindowCount() throws {
        let cal = try calendar("Europe/Rome")
        // 29 marzo: 23 h / 276 finestre. 25 ottobre: 25 h / 300 finestre.
        for (month, dayOfMonth, hours, windows) in [(3, 29, 23, 276), (10, 25, 25, 300)] {
            let day = try date(month, dayOfMonth, calendar: cal)
            let next = try date(month, dayOfMonth + 1, calendar: cal)
            let spans = [
                QuantitySpan(start: next.addingTimeInterval(-60), end: next, value: 17),
                QuantitySpan(start: next, end: next.addingTimeInterval(60), value: 29)
            ]
            let input = DayInput.make(day: day, calendar: cal, now: next, hr: [], steps: spans, motion: [])
            let result = DailyPipeline.run(input, profile: profile, history: [])
            XCTAssertEqual(next.timeIntervalSince(day), Double(hours * 3600))
            XCTAssertEqual(input.dayEnd, next)
            XCTAssertEqual(input.epochs.count, (hours + 6) * 120)
            XCTAssertEqual(result.steps, 17, accuracy: 1e-9)
            XCTAssertEqual(result.stressTimeline.count, windows)
        }
    }

    func testNoObservedMinuteCannotProducePerfectRegularity() throws {
        let cal = try calendar()
        let days = try (5...8).map { try date(7, $0, calendar: cal) }
        // Le date rappresentano report presenti, senza alcun intervallo osservabile.
        XCTAssertNil(SleepMetrics.sri(days: days, sleep: [], calendar: cal))
    }

    func testRMSSDWindowExcludesDifferenceFromOutsideAndKeepsZeroObserved() throws {
        let origin = Date(timeIntervalSinceReferenceDate: 0)
        let series = IBISeries(start: origin, ibiMs: [900] + Array(repeating: 1000, count: 24))
        let beats = HRV.beats(from: series)
        // Finestra [1.5, 25.5): 24 NN di 1000 ms, 23 differenze tutte nulle.
        let slice = beats[HRV.range(beats, from: 1.5, to: 25.5)]
        let m = try XCTUnwrap(HRV.metrics(slice))
        XCTAssertEqual(m.n, 24)
        XCTAssertEqual(m.meanNN, 1000, accuracy: 1e-6)
        XCTAssertEqual(m.rmssd, 0, accuracy: 1e-6)
        XCTAssertEqual(m.sdnn, 0, accuracy: 1e-5)
        XCTAssertEqual(m.pnn50, 0, accuracy: 1e-9)
    }

    func testRMSSDDoesNotBridgeAnExplicitGapInsideOneSeries() throws {
        let times = (0...21).map { Double($0) }
            + (0...21).map { 100.0 + Double($0) * 0.8 }
        var gaps = Array(repeating: false, count: times.count)
        gaps[22] = true
        let series = IBISeries(start: Date(timeIntervalSinceReferenceDate: 0),
                               beatTimes: times, precededByGap: gaps)
        let beats = HRV.beats(from: series)
        let m = try XCTUnwrap(HRV.metrics(beats))
        XCTAssertEqual(m.n, 42)
        XCTAssertEqual(beats.filter { $0.diff == nil }.count, 2)
        XCTAssertEqual(m.meanNN, 900, accuracy: 1e-6)
        XCTAssertEqual(m.rmssd, 0, accuracy: 1e-6)
        XCTAssertEqual(m.sdnn, 100 * sqrt(42.0 / 41.0), accuracy: 1e-6)
        XCTAssertEqual(m.pnn50, 0, accuracy: 1e-9)
    }

    func testDuplicateHeartbeatSeriesDoesNotSatisfyMinimumCoverage() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let sample = IBISeries(start: start, ibiMs: (0..<11).map { $0.isMultiple(of: 2) ? 1000 : 1020 })
        let one = HRV.beats(from: [sample])
        let repeated = HRV.beats(from: [sample, sample])
        XCTAssertNil(HRV.metrics(one))
        XCTAssertNil(HRV.metrics(repeated), "11 NN e 10 differenze uniche, anche dopo il reinvio")
    }

    func testM1KeepsNativeUnspecifiedSleepAndUnknownCategoryAndCountsUnion() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * minute) }
        let samples = [
            ImportedSleepSample(uuid: "bed", start: at(-10), end: at(25), categoryRawValue: 0, source: "B"),
            ImportedSleepSample(uuid: "phase", start: at(10), end: at(35), categoryRawValue: 3, source: "A"),
            ImportedSleepSample(uuid: "unspecified", start: at(35), end: at(45), categoryRawValue: 1, source: "B"),
            ImportedSleepSample(uuid: "unknown", start: at(55), end: at(70), categoryRawValue: 999, source: "A")
        ]
        let requested = ImportInterval(start: at(0), end: at(60))
        let result = ImportedSleep.summarize(read: .samples(samples), requested: requested,
                                             timeZoneIdentifier: "Europe/Rome", readAt: at(80))
        XCTAssertEqual(result.samples.map(\.category), [.inBed, .asleepCore, .asleepUnspecified, nil])
        XCTAssertEqual(result.samples.last?.categoryRawValue, 999)
        XCTAssertEqual(result.unknownCategoryCount, 1)
        let p = result.provenance
        XCTAssertEqual(p.coverage, .fraction(50.0 / 60.0))
        XCTAssertEqual(p.sources, ["A", "B"])
        XCTAssertEqual(p.origin, .importedFromHealth)
        XCTAssertEqual(p.unit, "categoria")
        XCTAssertEqual(p.contractVersion, 1)
        XCTAssertEqual(p.requested, requested)
        XCTAssertEqual(p.timeZoneIdentifier, "Europe/Rome")
        XCTAssertEqual(try Provenance.decode(p.encoded()), p)
    }

    func testM1DistinguishesObservedZeroEmptyReadAndDuplicateIdentifiers() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let t1 = t0.addingTimeInterval(60)
        let z = ImportedSample(uuid: "same", start: t0, end: t1, value: 0, source: "Fixture")
        func summary(_ read: ImportRead<ImportedSample>, total: Double? = nil) -> ImportedSeriesSummary {
            ImportedSeries.summarize(typeIdentifier: "steps", unit: "passi", read: read,
                                     requested: ImportInterval(start: t0, end: t1), timeZoneIdentifier: "UTC",
                                     hasDuration: true, healthStatisticTotal: total, readAt: t1)
        }
        let empty = summary(.samples([]))
        let present = summary(.samples([z, z]), total: 0)
        let failed = summary(.failure(domain: "fixture", code: 27))
        XCTAssertEqual(empty.provenance.state, .noSamplesOrAccessUndeterminable)
        XCTAssertNil(empty.healthStatisticTotal)
        XCTAssertEqual(present.provenance.state, .present)
        XCTAssertEqual(present.healthStatisticTotal, 0)
        XCTAssertEqual(present.duplicateUUIDCount, 1)
        XCTAssertEqual(present.provenance.coverage, .fraction(1))
        XCTAssertEqual(failed.provenance.state, .error(domain: "fixture", code: 27))
        XCTAssertNil(failed.healthStatisticTotal)
    }

    func testProvenanceRejectsAnInvertedObservedInterval() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let t1 = t0.addingTimeInterval(60)
        let p = Provenance(origin: .importedFromHealth, typeIdentifier: "test", unit: "bpm",
                           sources: ["Fixture"], requested: ImportInterval(start: t0, end: t1),
                           timeZoneIdentifier: "UTC", observed: ImportInterval(start: t1, end: t0),
                           sampleCount: 1, outOfRangeCount: 0, coverage: .fraction(0.5),
                           state: .present, readAt: t1)
        XCTAssertThrowsError(try p.encoded())
    }

    private func withArchiveDirectory(_ test: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("independent-audit-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try test(dir)
    }

    func testMotionReplaySurvivesProcessRestartAndSelectsHigherSampleCount() throws {
        try withArchiveDirectory { dir in
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            let index = Int(base.timeIntervalSince1970 / 30)
            let low = MotionEpoch(index: index, counts: 1, angleChange: 1, steps: 2, samples: 20)
            let high = MotionEpoch(index: index, counts: 4, angleChange: 3, steps: 7, samples: 80)
            let archive = MotionArchive(directory: dir)
            archive.merge([low, high, high])
            archive.merge([low])
            let reopened = MotionArchive(directory: dir)
            XCTAssertEqual(reopened.epochs(from: base, to: base.addingTimeInterval(30)), [high])
        }
    }

    func testMotionRetryAfterWriteFailurePersistsBeforeRestart() throws {
        try withArchiveDirectory { dir in
            let fm = FileManager.default
            let blocked = dir.appendingPathComponent("archive", isDirectory: true)
            // A un percorso destinato a cartella sostituiamo temporaneamente un file normale.
            try Data([0x42]).write(to: blocked)
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            let index = Int(base.timeIntervalSince1970 / 30)
            let epoch = MotionEpoch(index: index, counts: 4, angleChange: 2, steps: 12, samples: 80)
            let archive = MotionArchive(directory: blocked)
            archive.merge([epoch])
            try fm.removeItem(at: blocked)
            try fm.createDirectory(at: blocked, withIntermediateDirectories: false)
            archive.merge([epoch])
            let reopened = MotionArchive(directory: blocked)
            XCTAssertEqual(reopened.epochs(from: base, to: base.addingTimeInterval(30)), [epoch])
        }
    }
}
