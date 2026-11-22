import Foundation
import XCTest
@testable import RingCore

/// RC-AUD-02, secondo ciclo. Le fixture sono costruite senza dati reali.
final class IndependentP0AuditTests: XCTestCase {
    func testLegacyHistoryDecodesAndRoundTripsDatedWorkoutAndMissingNight() throws {
        // Il formato precedente conserva date Unix, report senza notte e allenamenti senza UUID.
        // Il JSON è esplicito per evitare che il codificatore moderno fabbrichi la propria fixture.
        let missingStress = Array(repeating: "null", count: 287).joined(separator: ",")
        let legacy = """
        [{
          "date":1728000000,"naps":[],"napsMin":0,"sleepDebtH":0,
          "rhr":60,"hrMax":187,"hrMaxMeasured":false,
          "zoneBounds":[93.5,112.2,130.9,149.6,168.3,187],"zoneMinutesDay":[0,0,10,0,0],
          "steps":321,"activeHours":1,"activeMinutes":10,"inactiveMin":0,"longestSedentaryMin":0,
          "workouts":[{"start":1728036000,"end":1728036600,"avgHR":155,"maxHR":160,
            "zoneMinutes":[0,0,10,0,0],"kcal":42,"autoDetected":false,"activity":"corsa"}],
          "trimp":30,"kcalTotal":1542,"kcalActive":42,"movementIndex":12,"movementParts":{},
          "stressTimeline":[42,\(missingStress)],"stressAvg":42,"stressRhythm":100,
          "recovery":75,"recoveryLabel":"alto","recoveryParts":{},"flags":[],
          "circadianAlignment":50,"tempMinH":5,"windows":[],
          "vo2max":30,"vo2Source":"stima","cardioAgeRaw":35,"cardioAge":35,"baselineNights":0
        }]
        """
        let firstRead = try History.decode(Data(legacy.utf8))
        let secondRead = try History.decode(History.encode(firstRead))
        for history in [firstRead, secondRead] {
            XCTAssertEqual(history.count, 1)
            let report = try XCTUnwrap(history.first)
            XCTAssertEqual(report.date.timeIntervalSince1970, 1_728_000_000)
            XCTAssertNil(report.night)
            XCTAssertNil(report.dailySleepMin)
            XCTAssertEqual(report.workouts.count, 1)
            let workout = try XCTUnwrap(report.workouts.first)
            XCTAssertEqual(workout.start.timeIntervalSince1970, 1_728_036_000)
            XCTAssertEqual(workout.minutes, 10)
            XCTAssertEqual(workout.activity, "corsa")
            XCTAssertEqual(workout.trimp, 30)
            XCTAssertEqual(workout.kcal, 42)
        }
    }

    func testObservedZeroStepsDiffersFromMissingAndOverridesMotionForTheSameMinute() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = Date(timeIntervalSince1970: 1_728_000_000)
        let end = day.addingTimeInterval(60)
        let index = Int(day.timeIntervalSince1970 / 30)
        let motion = [
            MotionEpoch(index: index, counts: 20, angleChange: 0, steps: 7, samples: 100),
            MotionEpoch(index: index + 1, counts: 20, angleChange: 0, steps: 5, samples: 100)
        ]
        let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65)
        func report(steps: [QuantitySpan], motion: [MotionEpoch]) -> DailyReport {
            let input = DayInput.make(day: day, calendar: calendar, now: end, hr: [], steps: steps, motion: motion)
            return DailyPipeline.run(input, profile: profile, history: [])
        }
        func display(for report: DailyReport) throws -> String {
            try XCTUnwrap(Presentation.activityLines(report).first { $0.name == "Passi" }).value
        }
        let missing = report(steps: [], motion: [])
        let fallback = report(steps: [], motion: motion)
        let measured = report(steps: [QuantitySpan(start: day, end: end, value: 0)], motion: motion)
        XCTAssertEqual(fallback.steps, 12)
        XCTAssertEqual(measured.steps, 0)
        XCTAssertTrue(try display(for: measured).hasPrefix("0"))
        let missingLabel = try display(for: missing).lowercased()
        XCTAssertTrue(["non disponibile", "dati insufficienti", "dato non aggiornato"]
            .contains { missingLabel.contains($0) }, missingLabel)
    }

    func testPersistenceFailureDoesNotExposeEpochOrAdvanceArchiveCursor() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("independent-p0-audit-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let blocked = dir.appendingPathComponent("archive", isDirectory: true)
        try Data([0x42]).write(to: blocked)
        let start = Date(timeIntervalSince1970: 1_728_000_000)
        let end = start.addingTimeInterval(30)
        let index = Int(start.timeIntervalSince1970 / 30)
        let epoch = MotionEpoch(index: index, counts: 12, angleChange: 3, steps: 5, samples: 100)
        let archive = MotionArchive(directory: blocked)

        _ = archive.merge([epoch])
        XCTAssertTrue(archive.epochs(from: start, to: end).isEmpty)
        XCTAssertNil(archive.lastIndex(now: end))

        try fm.removeItem(at: blocked)
        try fm.createDirectory(at: blocked, withIntermediateDirectories: false)
        _ = archive.merge([epoch])
        _ = archive.merge([epoch])
        let reopened = MotionArchive(directory: blocked)
        XCTAssertEqual(reopened.epochs(from: start, to: end), [epoch])
        XCTAssertEqual(reopened.lastIndex(now: end), index)
    }

    func testClusteredNNsCannotRepresentFiveMinutesOfObservedCoverage() throws {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let epoch = Epoch(start: start.addingTimeInterval(135))
        // Finestra [0, 300). 72 NN validi, raccolti in 23,76 s (<8% della finestra).
        let shortBurst = (0..<72).map { $0.isMultiple(of: 2) ? 320.0 : 340.0 }
        // 280 NN validi osservati lungo 297,5 s. Differenze di 125 ms.
        let fullWindow = (0..<280).map { $0.isMultiple(of: 2) ? 1_000.0 : 1_125.0 }
        func values(for intervals: [Double]) -> [Double?] {
            let series = IBISeries(start: start, ibiMs: intervals)
            return SleepMetrics.lnRMSSDPerEpoch([epoch], beats: HRV.beats(from: series))
        }
        let sparse = values(for: shortBurst)
        let covered = values(for: fullWindow)
        XCTAssertEqual(sparse.count, 1)
        XCTAssertEqual(covered.count, 1)
        XCTAssertNil(sparse.first ?? nil)
        XCTAssertEqual(try XCTUnwrap(covered.first ?? nil), log(125.0), accuracy: 1e-9)
    }

    func testOverlappingFragmentsOfOneHeartbeatStreamOnlyContributeUniqueNNs() throws {
        let origin = Date(timeIntervalSinceReferenceDate: 0)
        var timestamps = [0.0]
        for i in 0..<24 {
            timestamps.append((timestamps.last ?? 0) + (i.isMultiple(of: 2) ? 1 : 1.125))
        }
        let first = IBISeries(start: origin, beatTimes: Array(timestamps[0...16]))
        let overlapping = IBISeries(start: origin.addingTimeInterval(timestamps[8]),
                                    beatTimes: timestamps[8...24].map { $0 - timestamps[8] })
        // Gli 8 intervalli ripetuti non sono nuove osservazioni. 12 NN da 1000 e 12 da 1125 ms.
        let beats = HRV.beats(from: [overlapping, first])
        let m = try XCTUnwrap(HRV.metrics(beats))
        XCTAssertEqual(m.n, 24)
        XCTAssertEqual(m.meanNN, 1062.5, accuracy: 1e-9)
        XCTAssertEqual(m.rmssd, 125, accuracy: 1e-9)
        XCTAssertEqual(m.sdnn, 62.5 * sqrt(24.0 / 23.0), accuracy: 1e-9)
        XCTAssertEqual(m.pnn50, 100, accuracy: 1e-9)
    }
}
