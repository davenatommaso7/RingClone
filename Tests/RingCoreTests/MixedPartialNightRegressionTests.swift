import Foundation
import XCTest
@testable import RingCore

final class MixedPartialNightRegressionTests: XCTestCase {
    private let day = testDay(8)
    private let clock = testCal

    private func at(_ minutes: Double, on date: Date? = nil) -> Date {
        (date ?? day).addingTimeInterval(minutes * 60)
    }

    private func pulse(_ minutes: Range<Int>, bpm: Double, on date: Date? = nil) -> [TimedValue] {
        minutes.map { TimedValue(date: at(Double($0), on: date), value: bpm) }
    }

    private func segment(_ start: Double, _ end: Double, _ stage: SleepStage?, source: SleepSourceKey? = nil) -> SleepSegment {
        SleepSegment(start: at(start), end: at(end), stage: stage, source: source)
    }

    private func snapshot(at time: Double, stages: [SleepSegment] = [], key: SleepSourceKey? = nil,
                          pulse samples: [TimedValue] = [], active: Double? = nil, basal: Double? = nil,
                          providers: [SleepProviderEvidence] = [], history: [DailyReport] = []) -> DailyReport {
        var input = DayInput.make(day: day, calendar: clock, now: at(time), hr: samples, steps: [], motion: [], appleSleep: stages)
        input.appleSleepSource = key; input.explicitSleepProviders = providers
        input.hkActiveKcal = active; input.hkBasalKcal = basal
        return DailyPipeline.run(input, profile: testProfile, history: history)
    }

    private func initial(key: SleepSourceKey, history: [DailyReport] = []) -> DailyReport {
        let overnight = pulse(20..<65, bpm: 54).flatMap { sample in
            [sample, TimedValue(date: sample.date.addingTimeInterval(30), value: sample.value)]
        }
        return snapshot(at: 780, stages: [segment(-25, 245, nil), segment(-20, 240, .light, source: key)], key: key,
                        pulse: overnight, active: 200, basal: 1500, history: history)
    }

    private func reread(_ snapshot: DailyReport, in history: [DailyReport]) throws -> [DailyReport] {
        try History.decode(History.encode(History.upsert(snapshot, into: history, calendar: clock)))
    }

    private func current(_ history: [DailyReport]) throws -> DailyReport {
        try XCTUnwrap(history.first { $0.date == day })
    }

    func testObservedZeroUpdatesEnergyWithoutErasingNightOrItsVitals() throws {
        let key = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 1, count: 32)))
        let first = initial(key: key)
        let read = snapshot(at: 840, active: 0, basal: 1500)
        XCTAssertNil(read.night)
        let saved = try current(reread(read, in: [first]))
        XCTAssertEqual(saved.night?.tstMin, 260)
        XCTAssertEqual(saved.night?.finalWake, at(240))
        XCTAssertEqual(saved.dailySleepMin, 260)
        XCTAssertEqual(saved.sleepDebtH, 220.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(saved.originalSleepObservations, first.originalSleepObservations)
        XCTAssertEqual(saved.night?.rhr, 54)
        XCTAssertEqual(saved.rhr, 54)
        XCTAssertEqual(saved.kcalActive, 0)
        XCTAssertEqual(saved.kcalTotal, 1500)
        XCTAssertEqual(saved.state(\.energyActive), .observed)
        XCTAssertEqual(saved.computedAt, at(840))
        XCTAssertEqual(saved.sectorFreshness?.nightAt, at(780))
        XCTAssertEqual(saved.sectorFreshness?.activeEnergyAt, at(840))
        XCTAssertEqual(saved.sectorFreshness?.nightPreserved, true)
        XCTAssertEqual(saved.state(\.recovery), .stale)
        XCTAssertTrue(Presentation.sleepLines(saved).contains { $0.value.contains("Rilettura incompleta") })

        let estimatingRead = snapshot(at: 900, pulse: pulse(720..<750, bpm: 130))
        let again = try current(reread(estimatingRead, in: [saved]))
        XCTAssertEqual(again.kcalActive, 0)
        XCTAssertEqual(again.kcalTotal, 1500)
        XCTAssertEqual(again.sectorFreshness?.activeEnergyAt, at(840))
        // HRmax = 208 - 0,7×24 = 191,2; 130 bpm rientra tra 60% e 70% (Z2).
        XCTAssertEqual(again.zoneMinutesDay, [0, 30, 0, 0, 0])
        XCTAssertEqual(again.sectorFreshness?.daytimePulseAt, at(900))
        XCTAssertEqual(again.night?.rhr, 54)
    }

    func testFragmentAndContradictoryStagesCannotReplaceTheDocumentedNight() throws {
        let key = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 2, count: 32)))
        let first = initial(key: key)
        let fragment = [segment(-25, 185, nil), segment(-20, 60, .light, source: key),
                        segment(60, 65, .wake, source: key), segment(65, 180, .light, source: key)]
        let incomplete = snapshot(at: 840, stages: fragment, key: key, active: 5, basal: 1500)
        XCTAssertEqual(incomplete.night?.tstMin, 195)
        let after = try reread(incomplete, in: [first])
        let retained = try current(after)
        XCTAssertEqual(retained.night?.tstMin, 260)
        XCTAssertEqual(retained.sleepDebtH, 220.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(retained.kcalActive, 5)

        let contradictory = [segment(-25, 245, nil), segment(-20, 240, .light, source: key), segment(60, 75, .wake, source: key)]
        let conflict = snapshot(at: 900, stages: contradictory, key: key, active: 10, basal: 1500)
        XCTAssertNotNil(conflict.night)
        let unmodified = try current(reread(conflict, in: after))
        XCTAssertEqual(unmodified.night?.tstMin, 260)
        XCTAssertEqual(unmodified.sectorFreshness?.nightAt, at(780))
        XCTAssertEqual(unmodified.kcalActive, 10)
    }

    func testClosedShorterNightRequiresSameSourceObservedWake() throws {
        let source = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 3, count: 32)))
        let other = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 4, count: 32)))
        let first = initial(key: source)
        func shorter(_ key: SleepSourceKey) -> DailyReport {
            let wake = segment(60, 85, .wake, source: key)
            let stages = [segment(-25, 245, nil), segment(-20, 60, .light, source: key), wake,
                          segment(85, 240, .light, source: key)]
            let identified = SleepSourceSample(id: UUID(), segment: wake)
            return snapshot(at: 840, stages: stages, key: key,
                            providers: [SleepProviderEvidence(source: key, samples: [identified])])
        }
        let rejected = try current(reread(shorter(other), in: [first]))
        XCTAssertEqual(rejected.night?.tstMin, 260)
        let supported = shorter(source)
        let revised = try current(reread(supported, in: [first]))
        XCTAssertEqual(revised.night?.tstMin, 235)
        XCTAssertEqual(revised.night?.wasoMin, 25)
        XCTAssertEqual(revised.sleepDebtH, 245.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(revised.sectorFreshness?.nightAt, at(840))
        XCTAssertEqual(revised.sectorFreshness?.nightPreserved, false)
    }

    func testMixedWakeStillCorrectsEveningAndMergesInEitherOrderAcrossRestart() throws {
        let source = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 5, count: 32)))
        let previous = testDay(7)
        let history = (4...7).reduce(into: [DailyReport]()) { reports, d in
            let date = testDay(d)
            let input = DayInput.make(day: date, calendar: clock, now: at(1440, on: date),
                                      hr: pulse(1430..<1440, bpm: 75, on: date), steps: [], motion: [])
            reports = History.upsert(DailyPipeline.run(input, profile: testProfile, history: reports), into: reports, calendar: clock)
        }
        let original = initial(key: source, history: history)
        let wake = SleepSourceSample(id: UUID(), segment: segment(-10, -5, .wake, source: source))
        let mixed = snapshot(at: 840, pulse: pulse(720..<750, bpm: 130), active: 0, basal: 1500,
                             providers: [SleepProviderEvidence(source: source, samples: [wake])], history: history)
        XCTAssertNil(mixed.night)
        let chronological = try reread(mixed, in: reread(original, in: history))
        let delayed = try reread(original, in: reread(mixed, in: history))
        func state(_ archive: [DailyReport], at time: Double) -> Bool? {
            archive.first { $0.date == previous }?.sleepObservations?.first {
                $0.span.start <= at(time) && at(time) < $0.span.end
            }?.asleep
        }
        for archive in [chronological, delayed] {
            XCTAssertNil(state(archive, at: -15)) // Il buco senza FC resta ignoto.
            XCTAssertEqual(state(archive, at: -8), false)
            XCTAssertEqual(state(archive, at: -2), true)
            let merged = try current(archive)
            XCTAssertEqual(merged.night?.tstMin, 260)
            XCTAssertEqual(merged.zoneMinutesDay, [0, 30, 0, 0, 0])
            XCTAssertEqual(merged.kcalActive, 0)
            XCTAssertEqual(merged.sectorFreshness?.nightAt, at(780))
            XCTAssertEqual(merged.sectorFreshness?.daytimePulseAt, at(840))
            XCTAssertEqual(try History.encode(reread(mixed, in: archive)), try History.encode(archive))
        }
        XCTAssertEqual(try History.encode(chronological), try History.encode(delayed))
    }
}
