import Foundation
import XCTest
@testable import RingCore

/// RC-AUD-02, quarto ciclo. Fixture complementari per i sei fallimenti già registrati.
final class IndependentReportedFailuresTests: XCTestCase {
    private let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65)

    private func calendar(_ zone: String) throws -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return result
    }

    private func date(_ month: Int, _ day: Int, calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
    }

    private func nightReport(day: Date, calendar: Calendar, segments: [(Double, Double, SleepStage?)],
                             history: [DailyReport] = []) -> DailyReport {
        let sleep = segments.map { start, end, stage in
            SleepSegment(start: day.addingTimeInterval(start * 60),
                         end: day.addingTimeInterval(end * 60), stage: stage)
        }
        let input = DayInput.make(day: day, calendar: calendar, now: day.addingTimeInterval(86_400),
                                  hr: [], steps: [], motion: [], appleSleep: sleep)
        return DailyPipeline.run(input, profile: profile, history: history)
    }

    func testSRIExcludesInternalUnknownFromBothSidesOfTheDenominator() throws {
        let cal = try calendar("UTC")
        let full: [(Double, Double, SleepStage?)] = [(60, 300, .light)]
        let gap: [(Double, Double, SleepStage?)] = [(60, 120, .light), (130, 300, .light)]
        let awake: [(Double, Double, SleepStage?)] = [(60, 180, .light), (180, 190, .wake), (190, 300, .light)]
        var history: [DailyReport] = []
        for (offset, segments) in [full, gap, awake, full].enumerated() {
            let day = try date(7, 5 + offset, calendar: cal)
            let report = nightReport(day: day, calendar: cal, segments: segments, history: history)
            XCTAssertNotNil(report.night)
            history.append(report)
        }
        // Soltanto 240 minuti per notte sono candidati al confronto. Il buco di 10 minuti
        // ne sottrae 10 a entrambe le coppie adiacenti. La veglia osservata crea 20 disaccordi.
        let expected = -100 + 200 * 680.0 / 700.0
        XCTAssertEqual(try XCTUnwrap(history.last?.sri), expected, accuracy: 1e-9)
    }

    func testHypnogramUsesTimeFromAssociatedInBedAndKeepsEdgesUnknown() throws {
        let cal = try calendar("UTC")
        let day = try date(7, 8, calendar: cal)
        let report = nightReport(day: day, calendar: cal, segments: [
            (0, 260, nil), (10, 250, .light), (780, 960, nil)
        ])
        let night = try XCTUnwrap(report.night)
        XCTAssertEqual(night.inBed, day)
        XCTAssertEqual(night.outOfBed, day.addingTimeInterval(260 * 60))
        XCTAssertEqual(night.stages.count, 520)
        let phases = Presentation.hypnogram(night)
        let light = try XCTUnwrap(phases.first { $0.stage == .light })
        XCTAssertEqual(light.startMin, 10, accuracy: 1e-9)
        XCTAssertEqual(light.endMin, 250, accuracy: 1e-9)
        XCTAssertFalse(phases.contains { $0.stage == .wake })
    }

    func testProvenanceAcceptsTimedPointsAndObservedIntervalsExtendingAcrossQueryBounds() throws {
        let t0 = Date(timeIntervalSince1970: 1_728_000_000)
        func interval(_ start: Double, _ end: Double) -> ImportInterval {
            ImportInterval(start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end))
        }
        for (observed, coverage) in [(interval(12, 12), Coverage.notApplicable), (interval(-20, 80), .fraction(1))] {
            let p = Provenance(origin: .importedFromHealth, typeIdentifier: "fixture", unit: "bpm",
                               sources: ["fixture"], requested: interval(0, 60), timeZoneIdentifier: "UTC",
                               observed: observed, sampleCount: 1, outOfRangeCount: 0, coverage: coverage,
                               state: .present, readAt: t0.addingTimeInterval(90))
            XCTAssertEqual(try Provenance.decode(p.encoded()), p)
        }
    }

    func testStressEvaluatesLastObservedWindowOnShortNormalAndLongCivilDays() throws {
        let cal = try calendar("Europe/Rome")
        for (month, dayOfMonth, count) in [(3, 29, 276), (6, 10, 288), (10, 25, 300)] {
            let day = try date(month, dayOfMonth, calendar: cal)
            let end = try date(month, dayOfMonth + 1, calendar: cal)
            let offsets = (0..<60).map { day.addingTimeInterval(Double($0 * 60)) }
                + (1...5).map { end.addingTimeInterval(Double(-$0 * 60)) }
            let hr = offsets.map { TimedValue(date: $0, value: 78) }
            let input = DayInput.make(day: day, calendar: cal, now: end, hr: hr, steps: [], motion: [])
            let report = DailyPipeline.run(input, profile: profile, history: [])
            XCTAssertEqual(report.stressTimeline.count, count)
            // 65 minuti osservati danno RHR 78 dalla regola diurna. Ultima finestra con sola FC.
            let expected = 100 / (1 + exp(-1.2 * (-0.30 / 0.13) + 0.4))
            guard let last = report.stressTimeline.last ?? nil else {
                XCTFail("Ultima finestra assente nel giorno con \(count) finestre")
                continue
            }
            XCTAssertEqual(last, expected, accuracy: 1e-9)
        }
    }

    func testArchivedNightWithoutCoverageMetadataDecodesButCannotSupportAnSRI() throws {
        let cal = try calendar("UTC")
        let full: [(Double, Double, SleepStage?)] = [(60, 300, .light)]
        let history = try (5...7).map {
            nightReport(day: try date(7, $0, calendar: cal), calendar: cal, segments: full)
        }
        // Campi disponibili negli archivi RC3. Il filtro rimuove eventuali campi nuovi
        // senza conoscere i loro nomi e preserva il vero ipnogramma e i tratti archiviati.
        let reportKeys: Set<String> = [
            "date", "night", "naps", "napsMin", "dailySleepMin", "sleepDebtH", "sri", "sleepConsistency",
            "rhr", "hrMax", "hrMaxMeasured", "zoneBounds", "zoneMinutesDay", "steps", "activeHours",
            "activeMinutes", "inactiveMin", "longestSedentaryMin", "workouts", "trimp", "kcalTotal",
            "kcalActive", "movementIndex", "movementParts", "stressTimeline", "stressAvg", "stressRhythm",
            "recovery", "recoveryLabel", "recoveryParts", "flags", "circadianAlignment", "socialJetlagH",
            "socialJetlagScH", "chronotypeMSFsc", "tempMinH", "windows", "vo2max", "vo2Source", "cardioAgeRaw",
            "cardioAge", "baselineNights", "evidence", "computedAt"
        ]
        let nightKeys: Set<String> = [
            "inBed", "sleepOnset", "finalWake", "outOfBed", "tibMin", "tstMin", "solMin", "wasoMin",
            "efficiency", "awakenings", "longestBoutMin", "fragmentationIdx", "movements", "cycles",
            "lightMin", "deepMin", "remMin", "remLatencyMin", "midpointH", "onsetH", "wakeH", "rhr", "avgHR",
            "hrNadirFrac", "rmssd", "sdnn", "respRate", "spo2", "skinTemp", "skinTempDev", "tempMinH", "stages",
            "sleepRuns", "sleepIndex", "sleepIndexParts"
        ]
        let evidenceKeys: Set<String> = [
            "version", "rhr", "zones", "steps", "activity", "energyActive", "energyTotal", "trimp",
            "movement", "stress", "rhythm", "recovery", "alignment", "tempMinimum", "fitness", "baselineReady"
        ]
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: History.encode(history)) as? [[String: Any]])
        let legacy = try rows.map { row in
            var result = row.filter { reportKeys.contains($0.key) }
            let night = try XCTUnwrap(result["night"] as? [String: Any])
            result["night"] = night.filter { nightKeys.contains($0.key) }
            if let evidence = result["evidence"] as? [String: Any] {
                var previous = evidence.filter { evidenceKeys.contains($0.key) }
                previous["version"] = 1
                result["evidence"] = previous
            }
            return result
        }
        let decoded = try History.decode(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.map(\.date), history.map(\.date))
        XCTAssertEqual(decoded.map { $0.stressTimeline.count }, [288, 288, 288])
        XCTAssertTrue(decoded.allSatisfy { $0.night?.tstMin == 240 })
        let current = nightReport(day: try date(7, 8, calendar: cal), calendar: cal, segments: full, history: decoded)
        XCTAssertNil(current.sri)
    }
}
