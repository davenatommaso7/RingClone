import Foundation
import XCTest
@testable import RingCore

final class MidnightReconciliationRegressionTests: XCTestCase {
    private func makeReport(_ day: Date, calendar: Calendar = testCal, now: Date? = nil,
                            pulseSpans: [Range<Int>]? = nil, sleep: [SleepSegment] = [], history: [DailyReport]) -> DailyReport {
        let end = calendar.dateInterval(of: .day, for: day)?.end ?? day.addingTimeInterval(86_400)
        let spans = pulseSpans ?? [0..<Int(end.timeIntervalSince(day) / 30)]
        let hr = spans.flatMap { range in
            range.map { TimedValue(date: day.addingTimeInterval(Double($0) * 30), value: 80) }
        }
        let input = DayInput.make(day: day, calendar: calendar, now: now ?? end, hr: hr, steps: [], motion: [], appleSleep: sleep)
        return DailyPipeline.run(input, profile: testProfile, history: history)
    }

    private func night(_ day: Date, fromMin: Double, toMin: Double) -> SleepSegment {
        SleepSegment(start: day.addingTimeInterval(fromMin * 60), end: day.addingTimeInterval(toMin * 60), stage: .light)
    }

    private func state(_ report: DailyReport, at instant: Date) -> SleepObservation? {
        report.sleepObservations?.first { $0.span.start <= instant && instant < $0.span.end }
    }

    private func awakeHistory(ending: Int, pulseSpans: [Range<Int>]? = nil) -> [DailyReport] {
        var history: [DailyReport] = []
        for i in (ending - 3)...ending {
            let report = makeReport(testDay(i), pulseSpans: pulseSpans, history: history)
            history = History.upsert(report, into: history, calendar: testCal)
        }
        return history
    }

    func testHistoryReturnsAndPersistsReconciledEveningWithoutLeakingItToAnEarlierRun() throws {
        let first = awakeHistory(ending: 7)
        let previous = try XCTUnwrap(first.last), nextDay = testDay(8)
        let late = nextDay.addingTimeInterval(-900)
        XCTAssertEqual(previous.sri, 100)
        XCTAssertEqual(state(previous, at: late)?.contextualWake, true)

        let next = makeReport(nextDay, sleep: [night(nextDay, fromMin: -30, toMin: 240)], history: first)
        // Quattro coppie da 1.440 min. Disaccordi: 30 min nella serata corretta, poi 30+240 sull’ultima coppia.
        let expectedToday = 100 - 200 * 300.0 / (4 * 1440)
        XCTAssertEqual(try XCTUnwrap(next.sri), expectedToday, accuracy: 1e-9)
        XCTAssertEqual(next.night?.tstMin, 270)
        XCTAssertEqual(next.dailySleepMin, 270)
        let saved = History.upsert(next, into: first, calendar: testCal)
        let restored = try History.decode(History.encode(saved))
        let corrected = try XCTUnwrap(restored.first { $0.date == previous.date })
        XCTAssertEqual(corrected.computedAt, previous.computedAt)
        XCTAssertEqual(corrected.sriReconciledAt, next.computedAt)
        XCTAssertEqual(try XCTUnwrap(corrected.sri), 100 - 200 * 30.0 / (3 * 1440), accuracy: 1e-9)
        XCTAssertEqual(corrected.originalSleepObservations, previous.sleepObservations)
        XCTAssertEqual(state(corrected, at: late)?.asleep, true)
        XCTAssertNil(corrected.night)
        XCTAssertEqual(corrected.sleepDebtH, previous.sleepDebtH)
        XCTAssertEqual(try History.encode(History.upsert(next, into: restored, calendar: testCal)), try History.encode(saved))

        let replay = makeReport(previous.date, now: previous.computedAt, history: restored)
        XCTAssertEqual(replay.sri, 100)
        XCTAssertEqual(state(replay, at: late)?.asleep, false)
    }

    func testUnknownExplicitWakeAndLegacyContextAreNeverSubstituted() throws {
        let early = testDay(7), nextDay = testDay(8)
        let next = makeReport(nextDay, sleep: [night(nextDay, fromMin: -60, toMin: 240)], history: [])
        let axis = try XCTUnwrap(makeReport(early, history: []).stressAxis)
        func span(_ start: Double, _ end: Double) -> DateSpan {
            DateSpan(start: nextDay.addingTimeInterval(start * 60), end: nextDay.addingTimeInterval(end * 60))
        }
        let originals = [SleepObservation(span: span(-55, -45), asleep: false, contextualWake: true),
                         SleepObservation(span: span(-40, -30), asleep: false),
                         SleepObservation(span: span(-25, -15), asleep: true),
                         SleepObservation(span: span(-10, 0), asleep: false, contextualWake: true)]
        let time = try XCTUnwrap(next.computedAt)
        let projected = History.effectiveSleepObservations(originals, target: axis, revisions: next.eveningSleepRevisions ?? [], visibleAt: time)
        XCTAssertEqual(projected.map(\.span), originals.map(\.span)) // Le tre lacune restano assenti.
        XCTAssertEqual(projected.map(\.asleep), [true, false, true, true])
        XCTAssertEqual(projected[1], originals[1]) // Veglia esplicita o di provenienza legacy ignota.
    }

    func testOnlyExplicitEveningWakeCanWithdrawTheCorrespondingSleep() throws {
        let history = awakeHistory(ending: 7), previous = try XCTUnwrap(history.last), day = testDay(8)
        let first = makeReport(day, sleep: [night(day, fromMin: -30, toMin: 240)], history: history)
        let corrected = History.upsert(first, into: history, calendar: testCal)
        let now = try XCTUnwrap(first.computedAt)
        let partial = makeReport(day, now: now.addingTimeInterval(60), pulseSpans: [],
                                 sleep: [night(day, fromMin: -60, toMin: 240)], history: corrected)
        XCTAssertNotNil(partial.night) // Il solo NightReport non dimostra una conclusione osservata.
        let preserved = History.upsert(partial, into: corrected, calendar: testCal)
        let mid = day.addingTimeInterval(-900)
        XCTAssertEqual(state(try XCTUnwrap(preserved.first { $0.date == previous.date }), at: mid)?.asleep, true)
        XCTAssertEqual(preserved.last?.eveningSleepRevisions?.count, 1)

        let afterMidnight = night(day, fromMin: 30, toMin: 270)
        let withoutEvening = makeReport(day, now: now.addingTimeInterval(120), sleep: [afterMidnight], history: preserved)
        XCTAssertEqual(withoutEvening.night?.tstMin, 240)
        let unchanged = History.upsert(withoutEvening, into: preserved, calendar: testCal)
        let stillCorrected = try XCTUnwrap(unchanged.first { $0.date == previous.date })
        XCTAssertEqual(state(stillCorrected, at: mid)?.asleep, true)
        XCTAssertEqual(try XCTUnwrap(stillCorrected.sri), 100 - 200 * 30.0 / (3 * 1440), accuracy: 1e-9)
        XCTAssertEqual(stillCorrected.sriReconciledAt, first.computedAt)
        XCTAssertEqual(unchanged.last?.eveningSleepRevisions?.count, 1)

        let shorter = makeReport(day, now: now.addingTimeInterval(150),
                                 sleep: [night(day, fromMin: -10, toMin: 240)], history: unchanged)
        let partlyConfirmed = History.upsert(shorter, into: unchanged, calendar: testCal)
        XCTAssertEqual(partlyConfirmed.first { $0.date == previous.date }?.sleepObservations, stillCorrected.sleepObservations)

        let shortAwake = SleepSegment(start: mid, end: day, stage: .wake)
        let partiallyAwake = makeReport(day, now: now.addingTimeInterval(180), sleep: [shortAwake, afterMidnight], history: partlyConfirmed)
        let revised = History.upsert(partiallyAwake, into: partlyConfirmed, calendar: testCal)
        let split = try XCTUnwrap(revised.first { $0.date == previous.date })
        XCTAssertEqual(state(split, at: mid.addingTimeInterval(-60))?.asleep, true)
        XCTAssertEqual(state(split, at: mid)?.asleep, false)
        XCTAssertEqual(try XCTUnwrap(split.sri), 100 - 200 * 15.0 / (3 * 1440), accuracy: 1e-9)

        let fullAwake = SleepSegment(start: day.addingTimeInterval(-1800), end: day, stage: .wake)
        let replacement = makeReport(day, now: now.addingTimeInterval(240), sleep: [fullAwake, afterMidnight], history: revised)
        let withdrawn = History.upsert(replacement, into: revised, calendar: testCal)
        let restored = try XCTUnwrap(withdrawn.first { $0.date == previous.date })
        XCTAssertEqual(restored.sri, 100)
        XCTAssertEqual(restored.sleepObservations, previous.sleepObservations)
        XCTAssertNil(restored.sleepObservationsBeforeReconciliation)
        XCTAssertEqual(restored.sriReconciledAt, replacement.computedAt)
        XCTAssertEqual(withdrawn.last?.eveningSleepRevisions?.count, 4)
        XCTAssertEqual(withdrawn.last?.eveningSleepRevisions?.last?.runs, [])
        XCTAssertEqual(withdrawn.last?.eveningSleepRevisions?.last?.awakeRuns, [DateSpan(start: fullAwake.start, end: fullAwake.end)])
        XCTAssertEqual(try History.encode(History.upsert(first, into: withdrawn, calendar: testCal)), try History.encode(withdrawn))
    }

    func testHistoricalAlignmentUsesMaterializedSRIAndKeepsInputSnapshot() throws {
        // Per ciascun giorno sono osservati solo 30 min alle 18:00 e 30 min prima di mezzanotte.
        let history = awakeHistory(ending: 7, pulseSpans: [2160..<2220, 2820..<2880])
        let previous = try XCTUnwrap(history.last), day = testDay(8)
        XCTAssertEqual(previous.sri, 100)
        XCTAssertEqual(previous.circadianAlignment, 80.5, accuracy: 1e-9)

        let next = makeReport(day, sleep: [night(day, fromMin: -30, toMin: 240)], history: history)
        let h = History.upsert(next, into: history, calendar: testCal)
        let revised = try XCTUnwrap(h.first { $0.date == previous.date })
        // 150 accordi su 180 min. Unico componente presente: SRI; gli altri pesi conservano il neutro 0,7.
        let expected = 100 - 200 * 30.0 / 180.0
        XCTAssertEqual(try XCTUnwrap(revised.sri), expected, accuracy: 1e-9)
        XCTAssertEqual(revised.circadianAlignment, 100 * (0.35 * (expected - 40) / 50 + 0.65 * 0.7), accuracy: 1e-9)

        var legacy = previous
        legacy.regularityAlignmentInputs = nil
        let changed = History.upsert(next, into: Array(history.dropLast()) + [legacy], calendar: testCal)
        let old = try XCTUnwrap(changed.first { $0.date == previous.date })
        XCTAssertEqual(try XCTUnwrap(old.sri), expected, accuracy: 1e-9)
        XCTAssertEqual(old.circadianAlignment, 80.5, accuracy: 1e-9)
        XCTAssertEqual(old.state(\.alignment), .stale)
    }

    func testReaffirmationWinsOverLateIntermediateWakeRegardlessOfArrivalOrder() throws {
        let original = awakeHistory(ending: 7), previousDay = testDay(7), day = testDay(8)
        let evening = day.addingTimeInterval(-1800), duringEvening = day.addingTimeInterval(-900)
        let t1 = day.addingTimeInterval(86_400), t2 = t1.addingTimeInterval(60), t3 = t1.addingTimeInterval(120)
        let sleep = [night(day, fromMin: -30, toMin: 240)]
        let wake = [SleepSegment(start: evening, end: day, stage: .wake), night(day, fromMin: 30, toMin: 270)]
        let events = [(t1, sleep), (t2, wake), (t3, sleep)]
        for order in [[0, 2, 1], [0, 1, 2]] {
            var archive = original
            for i in order {
                let (instant, segments) = events[i]
                let revision = makeReport(day, now: instant, sleep: segments, history: archive)
                archive = History.upsert(revision, into: archive, calendar: testCal)
            }
            archive = try History.decode(History.encode(archive))
            let current = try XCTUnwrap(archive.first { $0.date == previousDay })
            XCTAssertEqual(state(current, at: duringEvening)?.asleep, true, "Ordine di arrivo: \(order)")
            XCTAssertEqual(try XCTUnwrap(current.sri), 100 - 200 * 30.0 / (3 * 1440), accuracy: 1e-9)

            let then = makeReport(previousDay, now: t2, history: archive)
            XCTAssertEqual(state(then, at: duringEvening)?.asleep, false)
            XCTAssertEqual(then.sri, 100)

            let replay = makeReport(day, now: t3, sleep: sleep, history: archive)
            XCTAssertEqual(try History.encode(History.upsert(replay, into: archive, calendar: testCal)), try History.encode(archive))
        }
    }

    func testEveningUsesActualCivilBoundaryAndRejectsMismatchedTimeZone() throws {
        var rome = Calendar(identifier: .gregorian)
        rome.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Rome"))
        let previousDay = try XCTUnwrap(rome.date(from: DateComponents(year: 2026, month: 10, day: 25)))
        let nextDay = try XCTUnwrap(rome.date(byAdding: .day, value: 1, to: previousDay))
        XCTAssertEqual(nextDay.timeIntervalSince(previousDay), 25 * 3600)
        let original = makeReport(previousDay, calendar: rome, history: [])
        let next = makeReport(nextDay, calendar: rome, sleep: [night(nextDay, fromMin: -45, toMin: 240)], history: [original])
        let h = History.upsert(next, into: [original], calendar: rome)
        let observed = try XCTUnwrap(h.first?.sleepObservations?.last)
        XCTAssertTrue(observed.asleep)
        XCTAssertEqual(observed.span.start, nextDay.addingTimeInterval(-45 * 60))
        XCTAssertEqual(observed.span.end, nextDay)

        var incompatible = original
        incompatible.stressAxis = StressDayAxis(start: previousDay, end: nextDay, timeZoneIdentifier: "UTC")
        let rejected = History.upsert(next, into: [incompatible], calendar: rome)
        XCTAssertEqual(rejected.first?.sleepObservations, original.sleepObservations)
        XCTAssertNil(rejected.first?.sriReconciledAt)
    }
}
