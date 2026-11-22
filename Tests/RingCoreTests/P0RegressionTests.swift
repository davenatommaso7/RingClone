import Foundation
import XCTest
@testable import RingCore

final class P0RegressionTests: XCTestCase {
    private func estimate(_ day: Date, now: Date? = nil) -> DailyReport {
        DailyPipeline.run(DayInput(day: day, calendar: testCal, now: now ?? day, epochs: []),
                          profile: testProfile, history: [])
    }

    private func night(_ day: Date, pulse: Double) throws -> DailyReport {
        var result = estimate(day)
        let epochs = (0..<80).map { Epoch(start: day.addingTimeInterval(Double($0) * 30), hr: pulse) }
        result.night = try XCTUnwrap(SleepMetrics.night(epochs, stages: Array(repeating: .light, count: 80),
                                                     beats: [], calendar: testCal))
        result.dailySleepMin = 40
        return result
    }

    func testZeroStepsAndEnergyAreObservedWhileMissingMetricsRemainUnavailable() {
        let day = testDay(16), now = day.addingTimeInterval(300)
        var input = DayInput.make(day: day, calendar: testCal, now: now, hr: [],
                                  steps: [QuantitySpan(start: day, end: now, value: 0)], motion: [])
        input.hkActiveKcal = 0
        input.hkBasalKcal = 0
        let result = DailyPipeline.run(input, profile: testProfile, history: [])
        XCTAssertEqual(result.state(\.steps), .observed)
        XCTAssertEqual(result.state(\.energyActive), .observed)
        XCTAssertEqual(result.state(\.energyTotal), .observed)
        XCTAssertEqual(Presentation.activityLines(result).first?.value, "0")
        XCTAssertEqual(result.kcalTotal, 0)
        XCTAssertEqual(result.state(\.rhr), .unavailable)
        XCTAssertEqual(result.state(\.fitness), .insufficient)
        XCTAssertEqual(result.state(\.alignment), .insufficient)
        XCTAssertEqual(result.state(\.tempMinimum), .unavailable)
        XCTAssertEqual(result.state(\.trimp), .insufficient)
        XCTAssertTrue(result.recovery.isNaN)
        XCTAssertTrue(result.windows.isEmpty)
    }

    func testStressNeedsObservedMinutesEvenWhenInterpolationAndAwakeContextExist() throws {
        let day = testDay(16), start = day.addingTimeInterval(12 * 3600 + 30 * 60), end = start.addingTimeInterval(300)
        let history = try (13...15).map { try night(testDay($0), pulse: 60) }
        func report(_ sampleMinutes: [Double]) -> DailyReport {
            let input = DayInput.make(day: day, calendar: testCal, now: end,
                                      hr: sampleMinutes.map { TimedValue(date: start.addingTimeInterval($0 * 60), value: 78) },
                                      steps: [QuantitySpan(start: start, end: end, value: 0)], motion: [])
            return DailyPipeline.run(input, profile: testProfile, history: history)
        }

        let isolated = report([1])
        XCTAssertEqual(isolated.state(\.rhr), .estimated) // Baseline a 60 bpm, nessun segnaposto.
        XCTAssertNil(isolated.stressAvg)
        XCTAssertTrue(isolated.stressTimeline.allSatisfy { $0 == nil })

        let observed = report([0, 1, 2])
        // FC = 1,30 × RHR. Il contributo FC vale zero, perciò si valuta la logistica in −0,4.
        XCTAssertEqual(try XCTUnwrap(observed.stressAvg), 100 / (1 + exp(0.4)), accuracy: 1e-9)
        XCTAssertEqual(observed.stressTimeline.compactMap { $0 }.count, 1)
        XCTAssertEqual(observed.state(\.rhythm), .insufficient)
        XCTAssertTrue(observed.stressRhythm.isNaN)
        XCTAssertTrue(observed.recovery.isNaN)
    }

    func testHistoryRevisionUsesWriteTimeAndLegacyRoundTripDoesNotCreateEvidence() throws {
        let day = testDay(15), tomorrow = testDay(16)
        let original = try night(day, pulse: 54)
        var corrected = try night(day, pulse: 57)
        corrected.date = day.addingTimeInterval(60)
        corrected.computedAt = day.addingTimeInterval(120)
        for reports in [[original, corrected], [corrected, original, corrected]] {
            let baseline = Baselines(history: reports, before: tomorrow, calendar: testCal)
            XCTAssertEqual(baseline.rhr.n, 1)
            XCTAssertEqual(baseline.rhr.center, 57)
            XCTAssertEqual(baseline.days28, 1)
            XCTAssertNil(baseline.observedTrimp28.last ?? nil)
            XCTAssertEqual(History.upsert(original, into: reports, calendar: testCal).map(\.date), [corrected.date])
        }

        var legacy = original
        legacy.evidence = nil
        legacy.computedAt = nil
        let recovered = try XCTUnwrap(History.decode(try History.encode([legacy])).first)
        XCTAssertEqual(recovered.night?.rhr, 54)
        XCTAssertNil(recovered.evidence)
        XCTAssertEqual(recovered.state(\.rhr), .stale)
    }

    func testHeartbeatIdentityKeepsSeparateSourcesAndRejectsConflictingReadOfOneID() throws {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let times = (0...11).map(Double.init)
        let a = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let b = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let first = IBISeries(start: start, beatTimes: times, sourceID: a)
        let second = IBISeries(start: start, beatTimes: times, sourceID: b)
        let revision = IBISeries(start: start, beatTimes: times.map { $0 * 1.1 }, sourceID: a)
        XCTAssertEqual(HRV.beats(from: [first, first]).count, 11)
        XCTAssertEqual(HRV.beats(from: [first, first, second]).count, 22)
        XCTAssertEqual(HRV.beats(from: [revision, first, second]).count, 11)
        XCTAssertEqual(HRV.beats(from: [first, second, revision]).count, 11)
    }

    func testWorkoutUUIDCountsOnceAndRetainsObservedZeroEnergy() throws {
        let day = testDay(16), end = day.addingTimeInterval(600)
        let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let epochs = (0..<20).map { Epoch(start: day.addingTimeInterval(Double($0) * 30), hr: 155) }
        let first = WorkoutRecord(start: day, end: end, avgHR: 155, maxHR: 155, zoneMinutes: [], kcal: 0,
                                  autoDetected: false, sourceID: id, importedKcal: 0)
        var revision = first
        revision.avgHR = 156
        var input = DayInput(day: day, calendar: testCal, now: end, epochs: epochs)
        var profile = testProfile
        profile.hrMaxOverride = 200
        input.hkWorkouts = [first, revision]
        let result = DailyPipeline.run(input, profile: profile, history: [])
        input.hkWorkouts.reverse()
        let reversed = DailyPipeline.run(input, profile: profile, history: [])
        XCTAssertEqual(result.workouts, reversed.workouts)
        XCTAssertEqual(result.workouts.count, 1)
        XCTAssertEqual(result.trimp, 30)
        XCTAssertEqual(result.kcalActive, 0)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("p0-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    func testMotionQueueSurvivesFailureAndOnlyMatchingAcknowledgmentRemovesPacket() throws {
        try withDirectory { dir in
            let blocked = dir.appendingPathComponent("archive")
            try Data([0x42]).write(to: blocked)
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            let epoch = MotionEpoch(index: Int(base.timeIntervalSince1970 / 30), counts: 4, angleChange: 2, steps: 12, samples: 80)
            let directory = dir.appendingPathComponent("queue", isDirectory: true)
            let outbox = MotionOutbox(directory: directory)
            let file = try outbox.enqueue([epoch])
            let bytes = try Data(contentsOf: file)
            let archive = MotionArchive(directory: blocked)
            XCTAssertFalse(archive.merge([epoch]))
            XCTAssertTrue(archive.epochs(from: base, to: base.addingTimeInterval(30)).isEmpty)
            XCTAssertEqual(try MotionOutbox(directory: directory).packets(), [file])
            try outbox.acknowledge(file.lastPathComponent) { $0 == Data([0]) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

            try FileManager.default.removeItem(at: blocked)
            XCTAssertTrue(archive.merge(try MotionChunk.decode(bytes).epochs))
            let reopened = MotionArchive(directory: blocked)
            XCTAssertTrue(reopened.merge([epoch]))
            XCTAssertEqual(try reopened.readEpochs(from: base, to: base.addingTimeInterval(30)), [epoch])
            try outbox.acknowledge(file.lastPathComponent) { $0 == bytes }
            try outbox.acknowledge(file.lastPathComponent) { $0 == bytes }
            XCTAssertTrue(try outbox.packets().isEmpty)
        }
    }

    func testReportFileWriteFailureAllowsRetryAndCorruptionIsNotReadAsEmpty() throws {
        try withDirectory { dir in
            let blocked = dir.appendingPathComponent("reports")
            try Data([0x42]).write(to: blocked)
            let url = blocked.appendingPathComponent("history.json")
            let day = testDay(16)
            let saved = [estimate(day)]
            XCTAssertThrowsError(try History.save(saved, to: url))
            XCTAssertEqual(try Data(contentsOf: blocked), Data([0x42]))
            try FileManager.default.removeItem(at: blocked)
            try History.save(saved, to: url)
            let persisted = try History.load(from: url)
            XCTAssertEqual(try History.encode(persisted), try History.encode(saved))
            try Data([0x42]).write(to: url)
            XCTAssertThrowsError(try History.load(from: url))
        }
    }
}
