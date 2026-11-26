import Foundation
import XCTest
@testable import RingCore

/// RC-AUD-02, terzo ciclo. Controlli sintetici indipendenti sulle osservazioni effettive.
final class IndependentResidualP0Tests: XCTestCase {
    func testSeparatedBurstsDoNotCoverTheIntervalBetweenTheirEndpoints() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let epoch = Epoch(start: start.addingTimeInterval(135))
        let intervals = (0..<72).map { $0.isMultiple(of: 2) ? 320.0 : 340.0 }
        // I due burst occupano [0, 23,76] e [276, 299,76] nella finestra [0, 300).
        // Durata osservata totale ≤ 47,52 s, anche con primi e ultimi battiti vicini agli estremi.
        let beats = HRV.beats(from: [
            IBISeries(start: start, ibiMs: intervals),
            IBISeries(start: start.addingTimeInterval(276), ibiMs: intervals)
        ])
        let values = SleepMetrics.lnRMSSDPerEpoch([epoch], beats: beats)
        XCTAssertEqual(values.count, 1)
        XCTAssertNil(values.first ?? nil)
    }

    func testExactObservedCoverageBoundaryAccepts240Seconds() throws {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let epoch = Epoch(start: start.addingTimeInterval(135))
        // La policy tecnica RC3 v1 richiede 240 s osservati nella finestra di 300 s.
        let prefix = (0..<224).map { $0.isMultiple(of: 2) ? 1_000.0 : 1_125.0 }
        func feature(lastInterval: Double) -> Double? {
            let series = IBISeries(start: start, ibiMs: prefix + [1_000, lastInterval])
            return SleepMetrics.lnRMSSDPerEpoch([epoch], beats: HRV.beats(from: series)).first ?? nil
        }
        // 112 × 2,125 s = 238 s, poi 1 s e 1 s. Una differenza nulla su 225.
        let expected = log(125 * sqrt(224.0 / 225.0))
        XCTAssertEqual(try XCTUnwrap(feature(lastInterval: 1_000)), expected, accuracy: 1e-9)
        XCTAssertNil(feature(lastInterval: 875)) // 239,875 s
    }

    func testMeasuredZeroMotionCanSupportANightWhereMissingMotionCannot() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = Date(timeIntervalSince1970: 1_728_000_000)
        let now = day.addingTimeInterval(8 * 3600)
        let indexAtMidnight = Int(day.timeIntervalSince1970 / 30)
        let quiet = 120..<600
        let offsets = -720..<960
        let measured = offsets.map { offset in
            let still = quiet.contains(offset)
            return MotionEpoch(index: indexAtMidnight + offset, counts: still ? 0 : 30,
                               angleChange: still ? 0 : 16, steps: 0, samples: 1_500)
        }
        let withGap = zip(offsets, measured).compactMap { offset, epoch in
            quiet.contains(offset) ? nil : epoch
        }
        func periods(_ motion: [MotionEpoch]) -> SleepPeriods {
            let input = DayInput.make(day: day, calendar: calendar, now: now, hr: [], steps: [], motion: motion)
            return SleepDetection.detect(input.epochs, apple: [], mainEnd: day...now, napWindow: day..<now)
        }
        // Stesse osservazioni di movimento prima e dopo. Tra 01:00 e 05:00
        // le 480 epoche sono misurate ferme oppure sono interamente assenti.
        XCTAssertNotNil(periods(measured).main)
        let missing = periods(withGap)
        XCTAssertNil(missing.main)
        XCTAssertTrue(missing.naps.isEmpty)
    }
}
