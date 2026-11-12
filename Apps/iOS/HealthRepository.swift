import Foundation
import HealthKit
import RingCore

/// Lettura di Apple Salute sull'iPhone (i dati dell'Apple Watch arrivano qui da soli).
/// L'app non scrive nulla in Salute. Si usano le query classiche di HealthKit, stabili da molte versioni.
final class HealthRepository: @unchecked Sendable {
    let store = HKHealthStore()

    static let bpm = HKUnit.count().unitDivided(by: .minute())
    static let vo2Unit = HKUnit.literUnit(with: .milli)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static let quantityIDs: [HKQuantityTypeIdentifier] = [
        .heartRate, .stepCount, .respiratoryRate, .oxygenSaturation, .appleSleepingWristTemperature,
        .activeEnergyBurned, .basalEnergyBurned, .vo2Max, .timeInDaylight,
    ]

    static var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>(quantityIDs.map { HKQuantityType($0) })
        s.insert(HKCategoryType(.sleepAnalysis))
        s.insert(HKSeriesType.heartbeat())
        s.insert(HKObjectType.workoutType())
        return s
    }

    /// Mostra il foglio dei permessi (solo la prima volta). HealthKit non rivela se la lettura è stata negata:
    /// in quel caso le query restituiscono semplicemente zero campioni.
    func authorize() async throws {
        guard Self.isAvailable else { return }
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    // MARK: - Query di base

    private func samples<T: HKSample>(_ type: HKSampleType, from a: Date, to b: Date, as _: T.Type) async throws -> [T] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[T], Error>) in
            let pred = HKQuery.predicateForSamples(withStart: a, end: b, options: [])
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            let q = HKSampleQuery(sampleType: type, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, res, err in
                if let err { c.resume(throwing: err) } else { c.resume(returning: (res ?? []).compactMap { $0 as? T }) }
            }
            store.execute(q)
        }
    }

    /// Campioni puntuali (FC, frequenza respiratoria, ...) come coppie data-valore
    func values(_ id: HKQuantityTypeIdentifier, from a: Date, to b: Date, unit: HKUnit) async throws -> [TimedValue] {
        try await samples(HKQuantityType(id), from: a, to: b, as: HKQuantitySample.self)
            .map { TimedValue(date: $0.startDate, value: $0.quantity.doubleValue(for: unit)) }
    }

    /// Somma su un intervallo. La query statistica elimina i doppi conteggi tra iPhone e Watch.
    func sum(_ id: HKQuantityTypeIdentifier, from a: Date, to b: Date, unit: HKUnit) async throws -> Double? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Double?, Error>) in
            let pred = HKQuery.predicateForSamples(withStart: a, end: b, options: [])
            let q = HKStatisticsQuery(quantityType: HKQuantityType(id), quantitySamplePredicate: pred, options: .cumulativeSum) { _, stats, err in
                if let err = err as? HKError, err.code == .errorNoData { c.resume(returning: nil); return }
                if let err { c.resume(throwing: err) } else { c.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit)) }
            }
            store.execute(q)
        }
    }

    /// Passi per minuto (già deduplicati tra le sorgenti) come intervalli da ripartire sulle epoche
    func steps(from a: Date, to b: Date) async throws -> [QuantitySpan] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[QuantitySpan], Error>) in
            let pred = HKQuery.predicateForSamples(withStart: a, end: b, options: [])
            let q = HKStatisticsCollectionQuery(quantityType: HKQuantityType(.stepCount), quantitySamplePredicate: pred,
                                                options: .cumulativeSum, anchorDate: a, intervalComponents: DateComponents(minute: 1))
            q.initialResultsHandler = { _, coll, err in
                if let err { c.resume(throwing: err); return }
                var out: [QuantitySpan] = []
                coll?.enumerateStatistics(from: a, to: b) { s, _ in
                    let v = s.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    if v > 0 { out.append(QuantitySpan(start: s.startDate, end: s.endDate, value: v)) }
                }
                c.resume(returning: out)
            }
            store.execute(q)
        }
    }

    // MARK: - Sonno

    /// Intervalli di sonno di UNA sola sorgente (Apple Watch se c'è), mai mescolati tra app diverse
    func sleep(from a: Date, to b: Date) async throws -> [SleepSegment] {
        let raw = try await samples(HKCategoryType(.sleepAnalysis), from: a, to: b, as: HKCategorySample.self)
        var bySource: [String: [SleepSegment]] = [:]
        for s in raw {
            guard let v = HKCategoryValueSleepAnalysis(rawValue: s.value) else { continue }
            let stage: SleepStage?
            switch v {
            case .awake: stage = .wake
            case .asleepCore, .asleepUnspecified: stage = .light
            case .asleepDeep: stage = .deep
            case .asleepREM: stage = .rem
            default: stage = nil                                     // inBed
            }
            bySource[s.sourceRevision.source.bundleIdentifier, default: []]
                .append(SleepSegment(start: s.startDate, end: s.endDate, stage: stage))
        }
        return SleepSources.pick(bySource)
    }

    // MARK: - Battito-battito

    private final class BeatBox: @unchecked Sendable {
        var times: [Double] = [], gaps: [Bool] = [], finished = false
    }

    private func beats(of s: HKHeartbeatSeriesSample) async throws -> IBISeries {
        guard s.count > 0 else { return IBISeries(start: s.startDate, beatTimes: []) }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<IBISeries, Error>) in
            let box = BeatBox()
            // il gestore viene richiamato una volta per battito, in sequenza, su una coda di HealthKit
            let q = HKHeartbeatSeriesQuery(heartbeatSeries: s) { _, time, precededByGap, done, error in
                if box.finished { return }
                if let error { box.finished = true; c.resume(throwing: error); return }
                box.times.append(time); box.gaps.append(precededByGap)
                if done {
                    box.finished = true
                    c.resume(returning: IBISeries(start: s.startDate, beatTimes: box.times, precededByGap: box.gaps))
                }
            }
            store.execute(q)
        }
    }

    /// Serie battito-battito registrate dal Watch (di notte, a riposo e durante Mindfulness).
    /// I battiti dopo una perdita di segnale restano marcati: il Core non calcola intervalli a cavallo dei buchi.
    func heartbeatSeries(from a: Date, to b: Date) async throws -> [IBISeries] {
        let list = try await samples(HKSeriesType.heartbeat(), from: a, to: b, as: HKHeartbeatSeriesSample.self)
        var out: [IBISeries] = []
        for s in list {
            if let series = try? await beats(of: s), series.beatTimes.count >= 2 { out.append(series) }
        }
        return out
    }

    // MARK: - Allenamenti

    static func activityName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "corsa"
        case .walking, .hiking: return "camminata"
        case .cycling: return "ciclismo"
        case .swimming: return "nuoto"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "forza"
        case .highIntensityIntervalTraining: return "HIIT"
        case .yoga, .pilates, .mindAndBody: return "yoga"
        default: return "allenamento"
        }
    }

    func workouts(from a: Date, to b: Date) async throws -> [WorkoutRecord] {
        try await samples(HKObjectType.workoutType(), from: a, to: b, as: HKWorkout.self).map { w in
            let hr = w.statistics(for: HKQuantityType(.heartRate))
            let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
            // i minuti in zona restano a zero: li ricalcola il Core con le zone personali del giorno
            return WorkoutRecord(start: w.startDate, end: w.endDate,
                                 avgHR: hr?.averageQuantity()?.doubleValue(for: Self.bpm) ?? 0,
                                 maxHR: hr?.maximumQuantity()?.doubleValue(for: Self.bpm) ?? 0,
                                 zoneMinutes: [0, 0, 0, 0, 0], kcal: kcal ?? 0, autoDetected: false,
                                 activity: Self.activityName(w.workoutActivityType))
        }
    }

    // MARK: - Aggiornamenti in background

    private var observers: [HKObserverQuery] = []

    /// Avvisa quando arrivano nuovi dati di sonno o allenamento, anche ad app chiusa
    /// (serve la capability "HealthKit > Background Delivery").
    func startObservers(onChange: @escaping @Sendable () -> Void) {
        guard Self.isAvailable, observers.isEmpty else { return }
        let types: [HKSampleType] = [HKCategoryType(.sleepAnalysis), HKObjectType.workoutType()]
        for t in types {
            let q = HKObserverQuery(sampleType: t, predicate: nil) { _, done, error in
                if error == nil { onChange() }
                done()                                               // obbligatorio: senza, iOS sospende le consegne
            }
            store.execute(q)
            observers.append(q)
            store.enableBackgroundDelivery(for: t, frequency: .hourly) { _, _ in }
        }
    }
}
