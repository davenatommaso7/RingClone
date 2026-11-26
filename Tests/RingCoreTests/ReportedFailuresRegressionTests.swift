import Foundation
import XCTest
@testable import RingCore

final class ReportedFailuresRegressionTests: XCTestCase {
    private func observation(_ day: Date, epoch: Int, asleep: Bool) -> SleepObservation {
        let start = day.addingTimeInterval(Double(epoch) * 30)
        return SleepObservation(span: DateSpan(start: start, end: start.addingTimeInterval(30)), asleep: asleep)
    }

    func testSRIUsesOnlyPairsWhereBothEpochsAreClassified() throws {
        let days = (1...4).map(testDay)
        var records = Dictionary(uniqueKeysWithValues: days.map { day in
            (day, (0..<4).map { observation(day, epoch: $0, asleep: true) })
        })
        records[days[1]]?[1] = observation(days[1], epoch: 1, asleep: false)
        records[days[2]]?.remove(at: 1)
        // Coppie comparabili: 4+3+3. Un solo disaccordo, quindi −100+200×9/10 = 80.
        XCTAssertEqual(try XCTUnwrap(SleepMetrics.sri(observationsByDay: records, calendar: testCal)), 80, accuracy: 1e-9)
        let empty: [Date: [SleepObservation]] = Dictionary(uniqueKeysWithValues: days.map { ($0, []) })
        XCTAssertNil(SleepMetrics.sri(observationsByDay: empty, calendar: testCal))
        XCTAssertNil(SleepMetrics.sri(days: days, sleep: [], calendar: testCal))
        let belowResolution = DateSpan(start: days[1], end: days[1].addingTimeInterval(1))
        XCTAssertNil(SleepMetrics.sri(days: days, sleep: [belowResolution], calendar: testCal))
    }

    func testSRIComparesActualTwentyFourHoursAcrossRepeatedClockHour() throws {
        var rome = Calendar(identifier: .gregorian)
        rome.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Rome"))
        let before = try XCTUnwrap(rome.date(from: DateComponents(year: 2026, month: 10, day: 25)))
        let after = try XCTUnwrap(rome.date(byAdding: .day, value: 1, to: before))
        XCTAssertEqual(after.timeIntervalSince(before), 90_000)
        let a = observation(before, epoch: 240, asleep: true)
        let b = observation(after, epoch: 120, asleep: false)
        XCTAssertEqual(b.span.start.timeIntervalSince(a.span.start), 86_400)
        let paired = [before: [a], after: [b]]
        XCTAssertEqual(SleepMetrics.sri(observationsByDay: paired, calendar: rome, minPairs: 1), -100)
        let wrongHour = [before: [a], after: [observation(after, epoch: 240, asleep: true)]]
        XCTAssertNil(SleepMetrics.sri(observationsByDay: wrongHour, calendar: rome, minPairs: 1))
    }

    func testNapGapRemainsUnknownEvenWithHeartSamplesAndLegacyIsNotInferred() throws {
        func report(_ day: Date, explicitWake: Bool, history: [DailyReport]) -> DailyReport {
            func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }
            var apple = [SleepSegment(start: at(-60), end: at(360), stage: .light),
                         SleepSegment(start: at(780), end: at(800), stage: .light),
                         SleepSegment(start: at(810), end: at(830), stage: .light)]
            if explicitWake { apple.append(SleepSegment(start: at(800), end: at(810), stage: .wake)) }
            let hr = (0..<2880).map { TimedValue(date: at(Double($0) / 2), value: 80) }
            let input = DayInput.make(day: day, calendar: testCal, now: at(1440), hr: hr, steps: [], motion: [], appleSleep: apple)
            return DailyPipeline.run(input, profile: testProfile, history: history)
        }
        let day = testDay(4), middle = day.addingTimeInterval(805 * 60)
        let unknown = report(day, explicitWake: false, history: [])
        let awake = report(day, explicitWake: true, history: [])
        func state(_ r: DailyReport) -> Bool? {
            r.sleepObservations?.first { $0.span.start <= middle && middle < $0.span.end }?.asleep
        }
        XCTAssertEqual(unknown.napsMin, 40)
        XCTAssertEqual(awake.napsMin, 40)
        XCTAssertNil(state(unknown))
        XCTAssertEqual(state(awake), false)
        XCTAssertEqual(try History.decode(History.encode([awake]))[0].sleepObservations, awake.sleepObservations)

        let legacy = (1...3).map { number -> DailyReport in
            var previous = report(testDay(number), explicitWake: false, history: [])
            previous.sleepObservations = nil
            return previous
        }
        let restored = try History.decode(History.encode(legacy))
        XCTAssertTrue(restored.allSatisfy { $0.sleepObservations == nil && $0.naps.count == 1 })
        XCTAssertNil(report(day, explicitWake: false, history: restored).sri)
    }

    func testTIBUsesNarrowestCompatibleObservationAndUnknownDoesNotCountAsWake() throws {
        let day = testDay(8), start = day.addingTimeInterval(-3600)
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
        let apple = [SleepSegment(start: at(-10), end: at(220), stage: nil),
                     SleepSegment(start: at(0), end: at(210), stage: nil),
                     SleepSegment(start: at(10), end: at(100), stage: .light),
                     SleepSegment(start: at(105), end: at(200), reportedStage: .asleepUnspecified)]
        func report(_ segments: [SleepSegment]) -> DailyReport {
            let input = DayInput.make(day: day, calendar: testCal, now: at(300), hr: [], steps: [], motion: [], appleSleep: segments)
            return DailyPipeline.run(input, profile: testProfile, history: [])
        }
        let r = report(apple)
        let n = try XCTUnwrap(r.night)
        XCTAssertEqual(n.bedTimingOrigin, .inBedObservation)
        XCTAssertEqual(n.inBed, at(0))
        XCTAssertEqual(n.outOfBed, at(210))
        XCTAssertEqual(n.tibMin, 210)
        XCTAssertEqual(n.solMin, 10)
        XCTAssertEqual(n.tstMin, 185)
        XCTAssertEqual(n.wasoMin, 0)
        XCTAssertEqual(n.efficiency, 100 * 185.0 / 210, accuracy: 1e-9)
        let runs = Presentation.hypnogram(n)
        XCTAssertEqual(runs.map(\.stage), [.unknown, .light, .unknown, .asleepUnspecified, .unknown])
        XCTAssertEqual(runs.map(\.endMin), [10, 100, 105, 200, 210])
        XCTAssertNil(report(Array(apple.prefix(3))).night) // A letto per oltre tre ore, ma solo 90 min di sonno.
        let fallback = try XCTUnwrap(report(Array(apple.suffix(2))).night)
        XCTAssertEqual(fallback.bedTimingOrigin, .estimatedFromEpisode)
        XCTAssertEqual(fallback.inBed, at(10))
    }

    func testUnknownLegacyStageKeepsItsPlaceAndRemainsDistinctFromUnspecifiedSleep() throws {
        let day = testDay(8)
        let e = (0..<80).map { Epoch(start: day.addingTimeInterval(Double($0) * 30)) }
        var n = try XCTUnwrap(SleepMetrics.night(e, stages: Array(repeating: .light, count: 80), beats: [], calendar: testCal))
        n.stages = [0, 999, 4, 3]
        XCTAssertEqual(n.stageEncodingVersion, 1)
        let current = Presentation.hypnogram(n)
        XCTAssertEqual(current.map(\.stage), [.wake, .unknown, .asleepUnspecified, .rem])
        XCTAssertEqual(current.map(\.startMin), [0, 0.5, 1, 1.5])
        XCTAssertTrue(current[2].stage.isSleep)

        n.bedTimingOrigin = nil
        n.stageEncodingVersion = nil
        let restored = try JSONDecoder().decode(NightReport.self, from: JSONEncoder().encode(n))
        XCTAssertNil(restored.bedTimingOrigin)
        XCTAssertNil(restored.stageEncodingVersion)
        XCTAssertEqual(restored.stages, [0, 999, 4, 3])
        let runs = Presentation.hypnogram(restored)
        XCTAssertEqual(runs.map(\.stage), [.wake, .unknown, .rem])
        XCTAssertEqual(runs.map(\.startMin), [0, 0.5, 1.5])
        XCTAssertFalse(runs[1].stage.isSleep)
    }

    func testProvenanceAcceptsPointAndObservedExtentAcrossRequest() throws {
        let start = testDay(8), end = start.addingTimeInterval(60)
        var p = Provenance(origin: .importedFromHealth, typeIdentifier: "fixture", unit: "count", sources: ["Test"],
                           requested: ImportInterval(start: start, end: end), timeZoneIdentifier: "UTC",
                           observed: ImportInterval(start: start, end: start), sampleCount: 1,
                           outOfRangeCount: 0, coverage: .fraction(0), state: .present, readAt: end)
        XCTAssertEqual(try Provenance.decode(p.encoded()), p)
        p.observed = ImportInterval(start: start.addingTimeInterval(-30), end: end.addingTimeInterval(30))
        XCTAssertEqual(try Provenance.decode(p.encoded()), p)
        p.observed = ImportInterval(start: end, end: start)
        XCTAssertThrowsError(try p.validate()) { XCTAssertEqual($0 as? ProvenanceError, .invalid("observed")) }
    }

    func testStressUsesRealWindowsAndDisplaysBothRepeatedLocalTimes() throws {
        var rome = Calendar(identifier: .gregorian)
        rome.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Rome"))
        for (month, date, hours) in [(3, 29, 23), (7, 8, 24), (10, 25, 25)] {
            let day = try XCTUnwrap(rome.date(from: DateComponents(year: 2026, month: month, day: date)))
            let end = try XCTUnwrap(rome.date(byAdding: .day, value: 1, to: day))
            let epochs = (0..<(hours * 120)).map { Epoch(start: day.addingTimeInterval(Double($0) * 30), hr: 80) }
            let input = DayInput(day: day, calendar: rome, now: end, epochs: epochs)
            var report = DailyPipeline.run(input, profile: testProfile, history: [])
            XCTAssertEqual(report.stressTimeline.count, hours * 12)
            let restored = try XCTUnwrap(History.decode(History.encode([report])).first)
            let points = Presentation.stressPoints(restored)
            XCTAssertEqual(points.count, hours * 12)
            XCTAssertEqual(points.first?.timestamp, day.addingTimeInterval(150))
            XCTAssertEqual(points.last?.timestamp, end.addingTimeInterval(-150))
            XCTAssertEqual(points[1].timestamp?.timeIntervalSince(try XCTUnwrap(points[0].timestamp)), 300)
            if hours == 23 { XCTAssertEqual(points[24].clockLabel, "03:02 UTC+02:00") }
            if hours == 25 {
                XCTAssertEqual(points[24].clockLabel, "02:02 UTC+02:00")
                XCTAssertEqual(points[36].clockLabel, "02:02 UTC+01:00")
                XCTAssertEqual(points[36].timestamp?.timeIntervalSince(try XCTUnwrap(points[24].timestamp)), 3600)
            }
            if hours == 24 {
                report.stressAxis = nil
                XCTAssertNil(Presentation.stressPoints(report).first?.timestamp)
                XCTAssertEqual(try XCTUnwrap(Presentation.stressPoints(report).last).hour, 24 - 1.0 / 24, accuracy: 1e-9)
            }
        }
    }
}
