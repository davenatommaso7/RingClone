import Foundation
import XCTest
@testable import RingCore

final class ResidualP0RegressionTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 0)

    private func alternatingTimes(_ intervals: Int) -> [Double] {
        (0...intervals).map { i in Double(i / 2) * 2.125 + (i.isMultiple(of: 2) ? 0 : 1) }
    }

    func testTrackedStreamCanUseObservedOverlapWithoutPoolingDifferentRecords() throws {
        let ticks = alternatingTimes(280) // 140 × (1 + 1,125) s = 297,5 s.
        let stream = UUID()
        let firstID = UUID(), secondID = UUID()
        let epoch = Epoch(start: origin.addingTimeInterval(135))
        func fragments(shared: UUID?, identified: Bool) -> [IBISeries] {
            let split = ticks[100]
            return [IBISeries(start: origin, beatTimes: Array(ticks[0...175]),
                              sourceID: identified ? firstID : nil, streamID: shared),
                    IBISeries(start: origin.addingTimeInterval(split), beatTimes: ticks[100...280].map { $0 - split },
                              sourceID: identified ? secondID : nil, streamID: shared)]
        }

        let shared = HRV.beats(from: fragments(shared: stream, identified: true))
        XCTAssertEqual(shared.count, 280)
        XCTAssertEqual(try XCTUnwrap(HRV.metrics(shared)).n, 280)
        XCTAssertEqual(try XCTUnwrap(SleepMetrics.lnRMSSDPerEpoch([epoch], beats: shared)[0]), log(125), accuracy: 1e-9)

        let separate = HRV.beats(from: fragments(shared: nil, identified: true))
        XCTAssertEqual(separate.count, 355) // 175 + 180 osservazioni da due record distinti.
        XCTAssertNil(SleepMetrics.lnRMSSDPerEpoch([epoch], beats: separate)[0])

        let anonymous = HRV.beats(from: fragments(shared: nil, identified: false))
        XCTAssertEqual(anonymous.count, 280) // I 75 NN identici si contano una volta.
        XCTAssertEqual(try XCTUnwrap(HRV.metrics(anonymous)).rmssd, 125, accuracy: 1e-9)
        XCTAssertNil(SleepMetrics.lnRMSSDPerEpoch([epoch], beats: anonymous)[0])
    }

    func testConflictWithGapInOneVerifiedStreamDoesNotBecomeObservedContinuity() {
        let stream = UUID()
        let complete = IBISeries(start: origin, beatTimes: [0, 1, 2, 3, 4, 5, 6], streamID: stream)
        let gapped = IBISeries(start: origin, beatTimes: [0, 1, 2, 4, 5, 6],
                              precededByGap: [false, false, false, true, false, false], streamID: stream)
        for order in [[complete, gapped], [gapped, complete]] {
            let beats = HRV.beats(from: order)
            XCTAssertEqual(beats.map(\.t), [1, 2, 5, 6]) // [2, 4) è controverso.
            XCTAssertEqual(beats.map(\.diff), [nil, 0, nil, 0])
        }
    }

    func testNearFullEnvelopeWithInternalGapsCannotProduceNocturnalHRV() throws {
        let epochs = (0..<60).map { Epoch(start: origin.addingTimeInterval(Double($0) * 30)) }
        let stages = Array(repeating: SleepStage.light, count: epochs.count)
        func fixture(_ offsets: [Double], pairs: Int) -> [Beat] {
            var times: [Double] = [], gaps: [Bool] = []
            for window in 0..<6 {
                for offset in offsets {
                    for (i, t) in alternatingTimes(pairs).enumerated() {
                        gaps.append(i == 0 && !times.isEmpty)
                        times.append(Double(window) * 300 + offset + t)
                    }
                }
            }
            return HRV.beats(from: IBISeries(start: origin, beatTimes: times, precededByGap: gaps))
        }
        // Due fasce da 97,75 s, 184 NN e inviluppo largo 297,75 s in ogni finestra.
        let interrupted = fixture([0, 200], pairs: 92)
        XCTAssertEqual(HRV.metrics(interrupted[HRV.range(interrupted, from: 0, to: 300)], minBeats: 120)?.n, 184)
        let center = Epoch(start: origin.addingTimeInterval(135)) // Finestra [0, 300).
        XCTAssertNil(SleepMetrics.lnRMSSDPerEpoch([center], beats: interrupted)[0])
        let sparseNight = try XCTUnwrap(SleepMetrics.night(epochs, stages: stages, beats: interrupted, calendar: testCal))
        XCTAssertNil(sparseNight.rmssd)
        XCTAssertNil(sparseNight.sdnn)

        let covered = fixture([0], pairs: 280)
        let coveredNight = try XCTUnwrap(SleepMetrics.night(epochs, stages: stages, beats: covered, calendar: testCal))
        XCTAssertEqual(try XCTUnwrap(coveredNight.rmssd), 125, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(coveredNight.sdnn), 62.5 * sqrt(280.0 / 279.0), accuracy: 1e-9)
    }

    func testCoverageClipsRightEdgeWhileMetricsKeepHalfOpenBeatWindow() throws {
        let series = IBISeries(start: origin.addingTimeInterval(60), ibiMs: Array(repeating: 1000, count: 240))
        let beats = HRV.beats(from: series)
        let window = try XCTUnwrap(HRV.coveredWindow(beats, from: 0, to: 300, minimumSeconds: 240, minBeats: 60))
        XCTAssertEqual(window.metrics.n, 239) // Il NN [299, 300) copre un secondo, il suo termine resta fuori dai conteggi.
        XCTAssertEqual(window.metrics.rmssd, 0)
        XCTAssertNil(HRV.coveredWindow(beats, from: 0, to: 300, minimumSeconds: 241, minBeats: 60))
    }

    func testMissingMotionSeparatesBoutsEvenWhenPaddedSpanExceedsThreeHours() {
        let day = testDay(16), start = day.addingTimeInterval(-7200)
        let epochs = (0..<470).map { i -> Epoch in
            let date = start.addingTimeInterval(Double(i) * 30)
            if (220..<250).contains(i) { return Epoch(start: date) }
            return Epoch(start: date, motion: 5, angleChange: 0, motionObserved: true)
        }
        let end = start.addingTimeInterval(470 * 30)
        let result = SleepDetection.detect(epochs, apple: [], mainEnd: day...end, napWindow: day..<end)
        XCTAssertNil(result.main) // Due tratti da 110 min, intervallati da 15 min senza osservazioni.
        XCTAssertEqual(result.naps, [250..<470]) // Il tratto iniziato dopo mezzanotte rimane osservato.
        XCTAssertEqual(result.napSleepEpochs, 220)
    }

    func testObservedZeroRemainsUsableAndShortObservedMovementDoesNotSplitNight() {
        let day = testDay(16), start = day.addingTimeInterval(-3600)
        let epochs = (0..<380).map { i -> Epoch in
            let date = start.addingTimeInterval(Double(i) * 30)
            guard (5..<375).contains(i) else { return Epoch(start: date) }
            return Epoch(start: date, motion: 0, angleChange: (180..<182).contains(i) ? 6 : 0, motionObserved: true)
        }
        let end = start.addingTimeInterval(380 * 30)
        let result = SleepDetection.detect(epochs, apple: [], mainEnd: day...end, napWindow: day..<end)
        XCTAssertEqual(result.main, 5..<375)
        XCTAssertEqual(result.mainObservation, 5..<375)

        let features = SleepStaging.features(epochs, lnRMSSD: [])
        XCTAssertNil(features[4][0])
        XCTAssertEqual(features[5][0], 0)
        XCTAssertNil(features[375][0])
    }

    func testRecorderScansPastEmptyBlocksAndRetriesFirstBlockThatDidNotQueue() {
        let start = Date(timeIntervalSince1970: 1_800_000_000), span = 900.0
        let end = start.addingTimeInterval(4 * span)
        var cursor = start, readBlocks: [Int] = [], enqueued: [Int] = []
        var canQueue = false
        func replay() {
            MotionBlockScan.run(from: cursor, to: end, blockSpan: span, read: { block in
                let i = Int(block.lowerBound.timeIntervalSince(start) / span)
                readBlocks.append(i)
                if i == 0 { return nil }
                if i == 1 { return [] }
                return [MotionEpoch(index: Int(block.lowerBound.timeIntervalSince1970 / 30),
                                    counts: 0, angleChange: 0, steps: 0, samples: 1500)]
            }, enqueue: { epochs in
                guard canQueue else { return false }
                enqueued.append(contentsOf: epochs.map(\.index))
                return true
            }, didScan: { cursor = $0 })
        }
        replay()
        XCTAssertEqual(readBlocks, [0, 1, 2])
        XCTAssertEqual(cursor.timeIntervalSince(start), 1800)
        XCTAssertTrue(enqueued.isEmpty)
        canQueue = true
        replay()
        XCTAssertEqual(readBlocks, [0, 1, 2, 2, 3])
        XCTAssertEqual(cursor, end)
        XCTAssertEqual(enqueued, [60_000_060, 60_000_090])
    }
}
