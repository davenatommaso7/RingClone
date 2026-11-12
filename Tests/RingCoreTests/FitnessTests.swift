import XCTest
@testable import RingCore

final class FitnessTests: XCTestCase {
    private func workouts(_ count: Int, minutes: Double = 40, relativeHR: Double = 0.75) -> [WorkoutRecord] {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return (0..<count).map { k in
            let date = start.addingTimeInterval(Double(k) * 86_400)
            return WorkoutRecord(start: date, end: date.addingTimeInterval(minutes * 60),
                                 avgHR: relativeHR * 200, maxHR: 200, zoneMinutes: [],
                                 kcal: 0, autoDetected: false)
        }
    }

    func testQuestionnaireCodeTableAndRange() {
        let frequencies: [(Fitness.PAFrequency, Double)] = [
            (.never, 0), (.lessThanWeekly, 0), (.weekly, 1),
            (.twoOrThreeWeekly, 2.5), (.almostDaily, 5)
        ]
        let intensities: [(Fitness.PAIntensity, Double)] = [(.light, 1), (.moderate, 2), (.vigorous, 3)]
        let durations: [(Fitness.PADuration, Double)] = [
            (.under15Minutes, 0.1), (.from15To29Minutes, 0.38),
            (.from30To60Minutes, 0.75), (.over60Minutes, 1)
        ]
        for (frequency, f) in frequencies {
            for (intensity, i) in intensities {
                for (duration, d) in durations {
                    let value = Fitness.paIndex(frequency: frequency, intensity: intensity, duration: duration)
                    XCTAssertEqual(value, f * i * d, accuracy: 1e-12)
                    XCTAssertGreaterThanOrEqual(value, 0)
                    XCTAssertLessThanOrEqual(value, 15)
                }
            }
        }
        XCTAssertEqual(Fitness.paIndex(frequency: .almostDaily, intensity: .vigorous, duration: .over60Minutes), 15)
    }

    func testLessThanWeeklyPolicyIsExplicit() {
        for policy in Fitness.PALessThanWeeklyPolicy.allCases {
            XCTAssertEqual(Fitness.paIndex(frequency: .never, intensity: .vigorous,
                                          duration: .over60Minutes, lessThanWeeklyPolicy: policy), 0)
        }
        XCTAssertEqual(Fitness.paIndex(frequency: .lessThanWeekly, intensity: .moderate,
                                      duration: .from30To60Minutes), 0)
        XCTAssertEqual(Fitness.paIndex(frequency: .lessThanWeekly, intensity: .moderate,
                                      duration: .from30To60Minutes, lessThanWeeklyPolicy: .zero), 0)
        XCTAssertEqual(Fitness.paIndex(frequency: .lessThanWeekly, intensity: .moderate,
                                      duration: .from30To60Minutes, lessThanWeeklyPolicy: .half), 0.75)
        for frequency in Fitness.PAFrequency.allCases where frequency != .lessThanWeekly {
            XCTAssertEqual(Fitness.paIndex(frequency: frequency, intensity: .light, duration: .under15Minutes,
                                          lessThanWeeklyPolicy: .zero),
                           Fitness.paIndex(frequency: frequency, intensity: .light, duration: .under15Minutes,
                                          lessThanWeeklyPolicy: .half))
        }
    }

    func testProxyDurationBoundaries() {
        // Una volta a settimana, intensità leggera: il risultato coincide con il codice durata.
        let cases: [(Double, Double)] = [
            (10, 0.1), (14.999, 0.1), (15, 0.38), (29.999, 0.38),
            (30, 0.75), (60, 0.75), (60.001, 1)
        ]
        for (minutes, expected) in cases {
            XCTAssertEqual(Fitness.paIndex(workouts: workouts(1, minutes: minutes, relativeHR: 0.5),
                                           days: 7, hrMax: 200), expected, accuracy: 1e-12)
        }
        XCTAssertEqual(Fitness.paIndex(workouts: workouts(1, minutes: 9), days: 7, hrMax: 200), 0)
    }

    func testProxyFrequencyAndIntensityBoundaries() {
        for (count, expected) in [(0, 0.0), (1, 1.0), (2, 2.5), (3, 2.5), (4, 5.0), (7, 5.0)] {
            XCTAssertEqual(Fitness.paIndex(workouts: workouts(count, minutes: 61, relativeHR: 0.5),
                                           days: 7, hrMax: 200), expected, accuracy: 1e-12)
        }
        XCTAssertEqual(Fitness.paIndex(workouts: workouts(1), days: 28, hrMax: 200), 0)
        for (relativeHR, expected) in [(0.639, 1.0), (0.64, 2.0), (0.849, 2.0), (0.85, 3.0)] {
            XCTAssertEqual(Fitness.paIndex(workouts: workouts(1, minutes: 61, relativeHR: relativeHR),
                                           days: 7, hrMax: 200), expected, accuracy: 1e-12)
        }
        XCTAssertEqual(Fitness.paIndex(workouts: workouts(12), hrMax: 200), 3.75)
        XCTAssertEqual(Fitness.paIndex(workouts: workouts(28, minutes: 61, relativeHR: 0.9), hrMax: 200), 15)
    }

    func testCorrectedPAIndexChangesOnlyNesActivityTerm() {
        let corrected = Fitness.paIndex(workouts: workouts(12), hrMax: 200)
        XCTAssertEqual(corrected, 3.75)
        for (sex, expectedDelta) in [(Sex.male, -2.89125), (Sex.female, -2.39625)] {
            let p = UserProfile(age: 40, sex: sex, heightCm: 175, weightKg: 70)
            let old = Fitness.nes(profile: p, rhr: 60, paIndex: 15).value
            let new = Fitness.nes(profile: p, rhr: 60, paIndex: corrected).value
            XCTAssertEqual(new - old, expectedDelta, accuracy: 1e-10)
        }
    }

    func testProxyRejectsInvalidDaysAndHRMax() {
        let w = workouts(12)
        let invalid: [Double] = [0, -1, .nan, .infinity, -.infinity]
        for value in invalid {
            XCTAssertEqual(Fitness.paIndex(workouts: w, days: value, hrMax: 200), 0)
            XCTAssertEqual(Fitness.paIndex(workouts: w, days: 28, hrMax: value), 0)
        }
        XCTAssertEqual(Fitness.paIndex(workouts: [], days: 28, hrMax: 200), 0)
    }
}
