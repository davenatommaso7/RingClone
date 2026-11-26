import Foundation
import RingCore
import XCTest

/// RC6. Identità fittizie e griglia UTC di 30 s, senza campioni HealthKit reali.
final class IndependentIsolatedWakeProvenanceTests: XCTestCase {
    private struct Scenario {
        let calendar: Calendar
        let day: Date
        let source: SleepSourceKey
        let otherDevice: SleepSourceKey
        let otherApp: SleepSourceKey
        let profile = UserProfile(age: 30, sex: .female, heightCm: 170, weightKg: 65)

        init() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
            self.calendar = calendar
            day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9)))
            source = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 1, count: 32)))
            otherDevice = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 2, count: 32)))
            otherApp = try XCTUnwrap(SleepSourceKey(fingerprint: Data(repeating: 3, count: 32)))
        }

        func at(_ minute: Double) -> Date { day.addingTimeInterval(minute * 60) }

        func pulse(on date: Date) -> [TimedValue] {
            (Array(1440..<1460) + Array(2860..<2880)).map {
                TimedValue(date: date.addingTimeInterval(Double($0) * 30), value: 75)
            }
        }

        func priorReport(in history: [DailyReport]) throws -> DailyReport {
            try XCTUnwrap(history.first { $0.date == at(-1440) })
        }

        func initial() -> [DailyReport] {
            var history: [DailyReport] = []
            for offset in (1...4).reversed() {
                let date = at(Double(-offset) * 1440)
                let input = DayInput.make(day: date, calendar: calendar, now: date.addingTimeInterval(86_400),
                                          hr: pulse(on: date), steps: [], motion: [])
                history.append(DailyPipeline.run(input, profile: profile, history: history))
            }
            return history
        }

        func states(_ minutes: [Double], in history: [DailyReport]) throws -> [Bool?] {
            let report = try priorReport(in: history)
            return minutes.map { minute in
                report.sleepObservations?.first { $0.span.start <= at(minute) && at(minute) < $0.span.end }?.asleep
            }
        }

        func sleep() -> SleepSegment {
            SleepSegment(start: at(-20), end: at(240), stage: .light)
        }

        func update(_ history: [DailyReport], now: Double, night: SleepSourceSample? = nil,
                    otherSegments: [SleepSegment] = [], providers: [SleepProviderEvidence] = []) -> [DailyReport] {
            let selected = night.map { _ in [sleep()] } ?? otherSegments
            var input = DayInput.make(day: day, calendar: calendar, now: at(now), hr: pulse(on: day),
                                      steps: [], motion: [], appleSleep: selected)
            input.appleSleepSource = night == nil ? nil : source
            input.explicitSleepProviders = providers + (night.map {
                [SleepProviderEvidence(source: source, samples: [$0])]
            } ?? [])
            let report = DailyPipeline.run(input, profile: profile, history: history)
            return History.upsert(report, into: history, calendar: calendar)
        }
    }

    func testSameProviderIsolatedWakeRevisesOnlyFullyObservedEpochs() throws {
        let f = try Scenario()
        let night = SleepSourceSample(id: UUID(), segment: f.sleep())
        let confirmed = f.update(f.initial(), now: 780, night: night)
        let minutes = [-9.8, -9.25, -8.0, -5.25, -2.0]
        XCTAssertEqual(try f.states(minutes, in: confirmed), [true, true, true, true, true])
        // [23:50:15, 23:54:45) contiene otto epoche complete, da 23:50:30 fino a 23:54:30 escluso.
        let awake = SleepSegment(start: f.at(-9.75), end: f.at(-5.25), stage: .wake)
        let sample = SleepSourceSample(id: UUID(), segment: awake)
        let same = SleepProviderEvidence(source: f.source, samples: [sample, sample])
        let result = f.update(confirmed, now: 840, providers: [same])
        XCTAssertEqual(try f.states(minutes, in: result), [true, false, false, true, true])
        // Prima c'erano dieci minuti discordanti su sessanta. Quattro tornano a concordare.
        XCTAssertEqual(try XCTUnwrap(f.priorReport(in: result).sri), -100 + 200 * 54.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(result.filter { $0.date == f.day }.count, 1)
    }

    func testForeignAnonymousUnknownAndConflictingEvidenceDoesNotWithdrawSleep() throws {
        let f = try Scenario()
        let night = SleepSourceSample(id: UUID(), segment: f.sleep())
        let confirmed = f.update(f.initial(), now: 780, night: night)
        func segment(_ from: Double, _ to: Double, _ stage: SleepStage?) -> SleepSegment {
            SleepSegment(start: f.at(from), end: f.at(to), stage: stage)
        }
        let awake = segment(-10, -5, .wake)
        let observed = SleepSourceSample(id: UUID(), segment: awake)
        let inBed = SleepSourceSample(id: UUID(), segment: segment(-10, -5, nil))
        let unknown = SleepSourceSample(id: UUID(), segment: SleepSegment(
            start: f.at(-10), end: f.at(-5), reportedStage: .unknown))
        let ambiguousSleep = SleepSourceSample(id: UUID(), segment: segment(-10, -5, .light))
        let results = [
            f.update(confirmed, now: 840),
            f.update(confirmed, now: 840, otherSegments: [awake]),
            f.update(confirmed, now: 840, providers: [
                SleepProviderEvidence(source: f.otherDevice, samples: [observed])
            ]),
            f.update(confirmed, now: 840, providers: [
                SleepProviderEvidence(source: f.otherApp, samples: [observed])
            ]),
            f.update(confirmed, now: 840, providers: [
                SleepProviderEvidence(source: f.source, samples: [inBed, unknown])
            ]),
            f.update(confirmed, now: 840, providers: [
                SleepProviderEvidence(source: f.source, samples: [observed, ambiguousSleep])
            ])
        ]
        for (index, result) in results.enumerated() {
            XCTAssertEqual(try f.states([-15, -8, -2], in: result), [nil, true, true], "Lettura \(index)")
        }
    }

    func testPreviouslyReadWakeUUIDDoesNotBecomeNewerThanAConfirmationAfterRestart() throws {
        let f = try Scenario()
        let first = SleepSourceSample(id: UUID(), segment: f.sleep())
        let renewed = SleepSourceSample(id: UUID(), segment: f.sleep())
        let awake = SleepSourceSample(id: UUID(), segment: SleepSegment(
            start: f.at(-10), end: f.at(-5), stage: .wake))
        let provider = SleepProviderEvidence(source: f.source, samples: [awake])
        let base = f.update(f.initial(), now: 780, night: first)
        func roundTrip(_ history: [DailyReport]) throws -> [DailyReport] {
            try History.decode(History.encode(history))
        }

        let withdrawn = f.update(base, now: 840, providers: [provider])
        XCTAssertEqual(try f.states([-8], in: withdrawn), [false])
        let reaffirmed = f.update(try roundTrip(withdrawn), now: 900, night: renewed)
        let afterReread = f.update(try roundTrip(reaffirmed), now: 960, providers: [provider])
        XCTAssertEqual(try f.states([-15, -8, -2], in: afterReread), [nil, true, true])
        let repeated = f.update(afterReread, now: 960, providers: [provider])
        XCTAssertEqual(try History.encode(repeated), try History.encode(afterReread))

        let previous = f.at(-1440)
        let asOf = DayInput.make(day: previous, calendar: f.calendar, now: f.at(840),
                                 hr: f.pulse(on: previous), steps: [], motion: [])
        let earlierView = DailyPipeline.run(asOf, profile: f.profile, history: afterReread)
        XCTAssertEqual(earlierView.sleepObservations?.first {
            $0.span.start <= f.at(-8) && f.at(-8) < $0.span.end
        }?.asleep, false)

        let outOfOrder = f.update(try roundTrip(f.update(base, now: 900, night: renewed)),
                                  now: 840, providers: [provider])
        XCTAssertEqual(try f.states([-15, -8, -2], in: outOfOrder), [nil, true, true])
        XCTAssertEqual(try f.priorReport(in: outOfOrder).sri, try f.priorReport(in: afterReread).sri)
    }
}
