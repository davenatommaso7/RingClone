import Foundation
import RingCore
import XCTest

/// RC7. Una veglia documentata fra due periodi di sonno può ridurre il TST.
final class IndependentAuthoritativeNightRevisionTests: XCTestCase {
    func testDocumentedShorterNightReplacesHistoryAndLaterPartialReadKeepsItsFreshness() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9)))
        let source = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 8, count: 32)))
        let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65, sleepNeedH: 8)
        func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }
        func segment(_ start: Double, _ end: Double, _ stage: SleepStage?) -> SleepSegment {
            SleepSegment(start: at(start), end: at(end), stage: stage, source: source)
        }
        func input(_ now: Double, samples: [SleepSegment], nightHR: Double?, active: Double) -> DayInput {
            let daytime = (1440..<1460).map { TimedValue(date: at(Double($0) / 2), value: 84) }
            let nocturnal = nightHR.map { value in
                (40..<160).map { TimedValue(date: at(Double($0) / 2), value: value) }
            } ?? []
            var reading = DayInput.make(day: day, calendar: calendar, now: at(now), hr: nocturnal + daytime,
                                        steps: [], motion: [], appleSleep: samples)
            reading.appleSleepSource = samples.isEmpty ? nil : source
            if !samples.isEmpty {
                reading.explicitSleepProviders = [SleepProviderEvidence(source: source, samples: samples.map {
                    SleepSourceSample(id: UUID(), segment: $0)
                })]
            }
            reading.hkActiveKcal = active
            reading.hkBasalKcal = 1_500
            return reading
        }
        func refresh(_ reading: DayInput, in history: [DailyReport]) -> [DailyReport] {
            let report = DailyPipeline.run(reading, profile: profile, history: history)
            return History.upsert(report, into: history, calendar: calendar)
        }
        func restart(_ history: [DailyReport]) throws -> [DailyReport] {
            try History.decode(History.encode(history))
        }

        let original = input(780, samples: [segment(-30, 250, nil), segment(-20, 240, .light)],
                             nightHR: 54, active: 160)
        let oldHistory = try restart(refresh(original, in: []))
        let old = try XCTUnwrap(oldHistory.first)
        XCTAssertEqual(old.night?.tstMin, 260)
        XCTAssertEqual(old.night?.avgHR, 54)

        // La fonte nota copre l'intero intervallo del sonno precedente. I 20 minuti
        // a metà notte sono esplicitamente svegli e hanno sonno a entrambi i lati.
        let correction = input(840, samples: [
            segment(-30, 250, nil), segment(-20, 100, .light),
            segment(100, 120, .wake), segment(120, 240, .rem)
        ], nightHR: 60, active: 190)
        let revisedHistory = try restart(refresh(correction, in: oldHistory))
        let revised = try XCTUnwrap(revisedHistory.first)
        let verified = try XCTUnwrap(revised.night)
        XCTAssertEqual(verified.sleepOnset, at(-20))
        XCTAssertEqual(verified.finalWake, at(240))
        XCTAssertEqual(verified.tstMin, 240, accuracy: 1e-9)
        XCTAssertEqual(verified.wasoMin, 20, accuracy: 1e-9)
        XCTAssertEqual(revised.dailySleepMin, 240)
        XCTAssertEqual(revised.sleepDebtH, 4, accuracy: 1e-9)
        XCTAssertEqual(verified.avgHR, 60)
        let revisedFreshness = try XCTUnwrap(revised.sectorFreshness)
        XCTAssertEqual(revisedFreshness.nightAt, at(840))
        XCTAssertFalse(revisedFreshness.nightPreserved)
        XCTAssertEqual(try History.encode(refresh(correction, in: revisedHistory)), try History.encode(revisedHistory))

        // La lettura successiva aggiorna settori ordinari, anche quando l'energia vera è zero.
        let partial = input(900, samples: [], nightHR: nil, active: 0)
        let latest = try restart(refresh(partial, in: revisedHistory))
        let saved = try XCTUnwrap(latest.first)
        let freshness = try XCTUnwrap(saved.sectorFreshness)
        XCTAssertEqual(latest.count, 1)
        XCTAssertEqual(saved.computedAt, at(900))
        XCTAssertEqual(freshness.nightAt, at(840))
        XCTAssertTrue(freshness.nightPreserved)
        XCTAssertEqual(freshness.daytimePulseAt, at(900))
        XCTAssertEqual(freshness.activeEnergyAt, at(900))
        XCTAssertEqual(freshness.totalEnergyAt, at(900))
        XCTAssertEqual(saved.kcalActive, 0)
        XCTAssertEqual(saved.kcalTotal, 1_500)
        XCTAssertEqual(saved.night?.tstMin, 240)
        XCTAssertEqual(saved.night?.avgHR, 60)
        XCTAssertEqual(saved.night?.sleepIndex, verified.sleepIndex)
        XCTAssertEqual(saved.sleepDebtH, 4, accuracy: 1e-9)
        XCTAssertNil(saved.sri)
        XCTAssertEqual(try History.encode(refresh(partial, in: latest)), try History.encode(latest))
    }
}
