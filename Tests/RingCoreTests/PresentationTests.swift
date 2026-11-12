import XCTest
@testable import RingCore

final class PresentationTests: XCTestCase {
    func testDurationsAndLabels() {
        XCTAssertEqual(Presentation.duration(432), "7 h 12 min")
        XCTAssertEqual(Presentation.duration(425), "7 h 05 min")
        XCTAssertEqual(Presentation.duration(44.6), "45 min")
        XCTAssertEqual(Presentation.signedHours(1.5), "+1 h 30 min")
        XCTAssertEqual(Presentation.signedHours(-0.5), "−30 min")
        XCTAssertEqual(Presentation.zoneNames.count, 5)
        XCTAssertEqual(Presentation.stressLabel(20), "rilassato")
        XCTAssertEqual(Presentation.stressLabel(90), "alto")
        let parts = Presentation.parts(["vitali": 0.8, "durata": 1, "chiave_nuova": 0.5])
        XCTAssertEqual(parts.map { $0.name }, ["Chiave Nuova", "Durata", "Parametri vitali"])
    }

    func testHypnogramRunsCoverTheNightWithoutGaps() throws {
        let s = Synthetic.day(testDay(12), calendar: testCal, profile: testProfile)
        let r = DailyPipeline.run(s.input, profile: testProfile, history: [])
        let n = try XCTUnwrap(r.night)
        let runs = Presentation.hypnogram(n)
        XCTAssertEqual(runs.first?.startMin, 0)
        XCTAssertEqual(try XCTUnwrap(runs.last).endMin, Double(n.stages.count) / 2, accuracy: 1e-9)
        for (a, b) in zip(runs, runs.dropFirst()) {
            XCTAssertEqual(a.endMin, b.startMin, accuracy: 1e-9)
            XCTAssertNotEqual(a.stage, b.stage)
        }
        let asleep = runs.filter { $0.stage.isSleep }.map { $0.endMin - $0.startMin }.reduce(0, +)
        XCTAssertEqual(asleep, n.tstMin, accuracy: 0.5)
        // curva dello stress: solo finestre valutate, ore dentro il giorno
        let pts = Presentation.stressPoints(r.stressTimeline)
        XCTAssertEqual(pts.count, r.stressTimeline.compactMap { $0 }.count)
        XCTAssertTrue(pts.allSatisfy { $0.hour > 0 && $0.hour < 24 && $0.value >= 0 && $0.value <= 100 })
        // impostazioni per il Watch
        let w = WatchSettings(report: r)
        XCTAssertEqual(w.zoneBounds, r.zoneBounds)
        XCTAssertEqual(HeartRate.zone(of: w.zoneBounds[2] + 1, bounds: w.zoneBounds), 3)
    }

    func testNumbersUseItalianFormat() {
        XCTAssertEqual(Presentation.number(14.46, digits: 1, unit: "atti/min"), "14,5 atti/min")
        XCTAssertEqual(Presentation.number(0.049, digits: 2, unit: "°C", signed: true), "+0,05 °C")
        XCTAssertEqual(Presentation.number(-0.304, digits: 2, signed: true), "−0,30")
        XCTAssertEqual(Presentation.number(-0.001, digits: 2, signed: true), "0,00")
        XCTAssertEqual(Presentation.number(9.96, digits: 1), "10,0")
        XCTAssertEqual(Presentation.number(8999.6), "9000")
        XCTAssertEqual(Presentation.number(nil), "n.d.")
        XCTAssertEqual(Presentation.number(.nan), "n.d.")
    }

    func testCardLinesUseTheRightUnits() throws {
        let s = Synthetic.day(testDay(12), calendar: testCal, profile: testProfile)
        let r = DailyPipeline.run(s.input, profile: testProfile, history: [])
        let n = try XCTUnwrap(r.night)
        func value(_ lines: [Presentation.Line], _ name: String) -> String? { lines.first { $0.name == name }?.value }
        let sleep = Presentation.sleepLines(r)
        XCTAssertEqual(Set(sleep.map { $0.id }).count, sleep.count)          // nomi unici: servono da identificatori
        XCTAssertEqual(value(sleep, "Efficienza"), "\(Int(n.efficiency.rounded())) %")
        XCTAssertTrue(n.efficiency > 50 && n.efficiency <= 100)             // percentuale, non frazione
        XCTAssertEqual(value(sleep, "Sonno ristoratore"), "\(Int((100 * n.restorativeShare).rounded())) %")
        XCTAssertEqual(value(sleep, "Sonno totale"), Presentation.duration(n.tstMin))
        XCTAssertEqual(value(sleep, "Regolarità (SRI)"), "servono più notti")
        let heart = Presentation.heartLines(r)
        XCTAssertEqual(value(heart, "Temperatura cutanea"), "in calibrazione")   // primo giorno: nessuna baseline
        XCTAssertEqual(value(heart, "FC a riposo"), "\(Int(r.rhr.rounded())) bpm")
        XCTAssertTrue(value(heart, "FC massima")?.hasSuffix("(stimata)") == true)
        XCTAssertEqual(Presentation.zoneRange(r, 0), "\(Int(r.zoneBounds[0].rounded()))–\(Int(r.zoneBounds[1].rounded())) bpm")
        XCTAssertEqual(Presentation.zoneRange(r, 5), "")
        XCTAssertEqual(Presentation.activityLines(r).count, 8)
        XCTAssertEqual(value(Presentation.circadianLines(r), "Social Jetlag"), "servono più notti")
        XCTAssertEqual(Presentation.fitnessLines(r).count, 3)
        XCTAssertEqual(Presentation.stressLines(r).count, 2)
        let w = WorkoutRecord(start: testDay(12).addingTimeInterval(18.5 * 3600), end: testDay(12).addingTimeInterval(19.25 * 3600),
                              avgHR: 150.4, maxHR: 171, zoneMinutes: [0, 5, 20, 20, 0], kcal: 512.3, autoDetected: true, activity: "corsa")
        XCTAssertEqual(Presentation.workoutTitle(w, calendar: testCal), "Corsa · 18:30 · 45 min")
        XCTAssertEqual(Presentation.workoutDetail(w), "FC media 150 · max 171 · 512 kcal · rilevato automaticamente")
    }

    func testSleepSourcePrefersAppleWatchAndNeverMixesSources() {
        let t = testDay(12)
        func seg(_ a: Double, _ b: Double, _ s: SleepStage?) -> SleepSegment {
            SleepSegment(start: t.addingTimeInterval(a * 3600), end: t.addingTimeInterval(b * 3600), stage: s)
        }
        let watch = [seg(1, 3, .light), seg(0, 1, .light)]
        let other = [seg(-1, 7, .light)]
        let phoneInBed = [seg(-2, 8, nil)]
        let a = SleepSources.pick(["com.apple.health.ABC": watch, "com.altra.app": other, "com.apple.Health": phoneInBed])
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a.first?.start, t)                                   // ordinati per inizio
        let b = SleepSources.pick(["com.altra.app": other, "com.terza.app": watch])
        XCTAssertEqual(b.count, 1)                                          // senza Apple Watch: la sorgente con più sonno
        XCTAssertTrue(SleepSources.pick(["x": phoneInBed]).isEmpty)         // solo "a letto": niente stadi, decide il sensore
        XCTAssertTrue(SleepSources.pick([:]).isEmpty)
    }
}
