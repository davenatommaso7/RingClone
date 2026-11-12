import Foundation
import HealthKit
import RingCore

/// Raccoglie i dati di un giorno da Apple Salute e dall'archivio del movimento e li consegna al Core
/// in forma indipendente dalla piattaforma (`DayInput`).
struct DayAssembler: Sendable {
    let hk: HealthRepository
    let archive: MotionArchive

    enum Failure: Error { case noData }

    func input(for day: Date, calendar: Calendar, now: Date) async throws -> DayInput {
        let from = day.addingTimeInterval(-DayInput.lookback)                       // la notte comincia la sera prima
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        let to = min(dayEnd, now)
        guard to > from else { throw Failure.noData }

        // Le letture indispensabili propagano l'errore (es. iPhone bloccato: i dati di Salute sono cifrati);
        // quelle facoltative, se falliscono, lasciano semplicemente il campo vuoto.
        async let hrQ = hk.values(.heartRate, from: from, to: to, unit: HealthRepository.bpm)
        async let stepsQ = hk.steps(from: from, to: to)
        async let sleepQ = hk.sleep(from: from, to: to)
        async let ibiQ = hk.heartbeatSeries(from: from, to: to)
        async let tempQ = hk.values(.appleSleepingWristTemperature, from: from, to: to, unit: .degreeCelsius())
        async let respQ = hk.values(.respiratoryRate, from: from, to: to, unit: HealthRepository.bpm)
        async let spo2Q = hk.values(.oxygenSaturation, from: from, to: to, unit: .percent())
        async let workoutsQ = hk.workouts(from: day, to: to)
        async let activeQ = hk.sum(.activeEnergyBurned, from: day, to: to, unit: .kilocalorie())
        async let basalQ = hk.sum(.basalEnergyBurned, from: day, to: to, unit: .kilocalorie())
        async let daylightQ = hk.sum(.timeInDaylight, from: day, to: to, unit: .minute())
        async let vo2Q = hk.values(.vo2Max, from: day.addingTimeInterval(-90 * 86_400), to: to, unit: HealthRepository.vo2Unit)

        let hr = try await hrQ
        let steps = (try? await stepsQ) ?? []
        let sleep = (try? await sleepQ) ?? []
        let motion = archive.epochs(from: from, to: to)

        var input = DayInput.make(day: day, calendar: calendar, now: now, hr: hr, steps: steps, motion: motion, appleSleep: sleep)
        guard !hr.isEmpty || !steps.isEmpty || !motion.isEmpty || !sleep.isEmpty else { throw Failure.noData }

        input.ibiSeries = (try? await ibiQ) ?? []
        input.hkWorkouts = (try? await workoutsQ) ?? []
        input.hkActiveKcal = try? await activeQ
        input.hkBasalKcal = try? await basalQ
        input.daylightMin = try? await daylightQ

        // Valori notturni: si considerano solo i campioni dentro il sonno che termina in questo giorno
        let asleep = sleep.filter { $0.stage?.isSleep == true && $0.end > day && $0.start < day.addingTimeInterval(18 * 3600) }
        let window: ClosedRange<Date>
        if let a = asleep.map({ $0.start }).min(), let b = asleep.map({ $0.end }).max(), a < b {
            window = a...b
        } else {
            window = from...day.addingTimeInterval(12 * 3600)
        }
        let resp = ((try? await respQ) ?? []).filter { window.contains($0.date) }.map { $0.value }
        if resp.count >= 3 { input.hkRespRate = Stats.median(resp) }
        let spo2 = ((try? await spo2Q) ?? []).filter { window.contains($0.date) }.map { $0.value * 100 }
        if !spo2.isEmpty { input.spo2 = Stats.mean(spo2) }
        // temperatura del polso nel sonno: Apple ne pubblica un solo valore per notte
        input.skinTempNight = ((try? await tempQ) ?? []).last?.value

        if let v = ((try? await vo2Q) ?? []).last {
            input.appleVO2 = v.value
            input.appleVO2AgeDays = max(to.timeIntervalSince(v.date) / 86_400, 0)
        }
        return input
    }
}
