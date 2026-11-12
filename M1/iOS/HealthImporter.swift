import Foundation
import HealthKit
import RingCore

// Importatore di M1 (voci ACQ-01 ... ACQ-14, ACQ-20, PLT-15).
// Legge Salute in sola lettura e produce riepiloghi con provenienza.
// Non passa dall'elaborazione giornaliera della BL-0 e non conserva nulla: ogni apertura rilegge.
// La variabilita' RMSSD nativa non e' ancora letta: verra' aggiunta in un passo separato.

struct ImportedDetail {
    let label: String
    let value: String
}

struct ImportedItem: Identifiable {
    let id: String
    let title: String
    let summary: ImportedSeriesSummary
    let showsRange: Bool
    let showsTotals: Bool
    let decimals: Int
    let admissibleNote: String?
    let statisticNote: String?
    let details: [ImportedDetail]
}

enum ImportedSection: Identifiable {
    case series(ImportedItem)
    case sleep(ImportedSleepSeries)

    var id: String {
        switch self {
        case .series(let item): return item.id
        case .sleep: return ImportedSleep.typeIdentifier
        }
    }

    var title: String {
        switch self {
        case .series(let item): return item.title
        case .sleep: return "Sonno"
        }
    }
}

struct ImportResult {
    let sections: [ImportedSection]
}

enum StatisticTotal {
    case value(Double)
    case noData
    case failure(domain: String, code: Int)
}

private struct QuantityPlan {
    let id: HKQuantityTypeIdentifier
    let title: String
    let unitLabel: String
    let unit: HKUnit
    var scale: Double = 1
    var atNight = false
    var hasDuration = false
    var showsRange = false
    var showsTotals = false
    var listsSamples = false
    var decimals = 0
    var admissible: ClosedRange<Double>? = nil
    var admissibleNote: String? = nil
}

private struct WorkoutRow: Sendable {
    let sample: ImportedSample
    let activity: UInt
}

final class HealthImporter: @unchecked Sendable {
    private let store = HKHealthStore()

    static let bpm = HKUnit.count().unitDivided(by: .minute())
    static let vo2Unit = HKUnit.literUnit(with: .milli)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private static var plans: [QuantityPlan] {
        [
            QuantityPlan(id: .heartRate, title: "Frequenza cardiaca", unitLabel: "battiti/min", unit: bpm,
                         showsRange: true, admissible: 30...210,
                         admissibleNote: "Campioni non numerici o fuori da 30-210 battiti/min"),
            QuantityPlan(id: .restingHeartRate, title: "Frequenza cardiaca a riposo di Apple",
                         unitLabel: "battiti/min", unit: bpm, listsSamples: true),
            QuantityPlan(id: .stepCount, title: "Passi", unitLabel: "passi", unit: .count(),
                         hasDuration: true, showsTotals: true),
            QuantityPlan(id: .heartRateVariabilitySDNN, title: "Variabilità SDNN di Apple", unitLabel: "ms",
                         unit: .secondUnit(with: .milli), atNight: true, listsSamples: true, decimals: 1),
            QuantityPlan(id: .respiratoryRate, title: "Frequenza respiratoria", unitLabel: "respiri/min", unit: bpm,
                         atNight: true, showsRange: true, decimals: 1),
            QuantityPlan(id: .oxygenSaturation, title: "Saturazione di ossigeno", unitLabel: "%", unit: .percent(),
                         scale: 100, atNight: true, showsRange: true, decimals: 1),
            QuantityPlan(id: .appleSleepingWristTemperature, title: "Temperatura al polso nel sonno",
                         unitLabel: "°C", unit: .degreeCelsius(), atNight: true, hasDuration: true,
                         listsSamples: true, decimals: 2),
            QuantityPlan(id: .activeEnergyBurned, title: "Energia attiva", unitLabel: "kcal", unit: .kilocalorie(),
                         hasDuration: true, showsTotals: true),
            QuantityPlan(id: .basalEnergyBurned, title: "Energia basale", unitLabel: "kcal", unit: .kilocalorie(),
                         hasDuration: true, showsTotals: true),
            QuantityPlan(id: .vo2Max, title: "VO2 max stimato da Apple (stima importata)", unitLabel: "ml/kg/min",
                         unit: vo2Unit, listsSamples: true, decimals: 1),
            QuantityPlan(id: .timeInDaylight, title: "Tempo alla luce diurna", unitLabel: "min", unit: .minute(),
                         hasDuration: true, showsTotals: true),
        ]
    }

    static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>(plans.map { HKQuantityType($0.id) })
        types.insert(HKCategoryType(.sleepAnalysis))
        types.insert(HKSeriesType.heartbeat())
        types.insert(HKObjectType.workoutType())
        return types
    }

    /// true se il sistema deve ancora mostrare il foglio dei permessi per i tipi letti
    func needsAuthorizationRequest() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            store.getRequestStatusForAuthorization(toShare: [], read: Self.readTypes) { status, _ in
                continuation.resume(returning: status != .unnecessary)
            }
        }
    }

    /// Mostra il foglio dei permessi, con un interruttore per ogni tipo. L'app non chiede di scrivere.
    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    /// Giorno di calendario corrente, dalla mezzanotte a ora.
    /// Per il sonno e per i tipi misurati di notte, dalle 18 del giorno prima.
    func read(now: Date = Date(), calendar: Calendar = .current) async -> ImportResult {
        let midnight = calendar.startOfDay(for: now)
        let day = ImportInterval(start: midnight, end: now)
        var evening = midnight
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: midnight),
           let six = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: yesterday) {
            evening = six
        }
        let night = ImportInterval(start: evening, end: now)
        let zone = calendar.timeZone.identifier
        let plans = Self.plans
        var sections: [ImportedSection] = []

        for plan in plans.prefix(3) {
            let entry = await item(for: plan, day: day, night: night, zone: zone)
            sections.append(.series(entry))
        }

        let sleepRead = await sleepSamples(in: night)
        let sleep = ImportedSleep.summarize(read: sleepRead, requested: night, timeZoneIdentifier: zone, readAt: Date())
        sections.append(.sleep(sleep))

        let beats = await heartbeatItem(night: night, zone: zone)
        sections.append(.series(beats))

        for plan in plans.dropFirst(3) {
            let entry = await item(for: plan, day: day, night: night, zone: zone)
            sections.append(.series(entry))
        }

        let workouts = await workoutItem(day: day, zone: zone)
        sections.append(.series(workouts))
        return ImportResult(sections: sections)
    }

    private func item(for plan: QuantityPlan, day: ImportInterval, night: ImportInterval,
                      zone: String) async -> ImportedItem {
        let interval = plan.atNight ? night : day
        let read = await quantity(plan.id, unit: plan.unit, scale: plan.scale, in: interval)
        var total: Double? = nil
        var note: String? = nil
        if plan.showsTotals {
            switch await statisticSum(plan.id, unit: plan.unit, in: interval) {
            case .value(let value):
                total = value * plan.scale
            case .noData:
                break
            case .failure(let domain, let code):
                note = "Errore di lettura: \(domain) \(code)"
            }
        }
        let summary = ImportedSeries.summarize(
            typeIdentifier: plan.id.rawValue, unit: plan.unitLabel, read: read, requested: interval,
            timeZoneIdentifier: zone, admissible: plan.admissible, hasDuration: plan.hasDuration,
            healthStatisticTotal: total, readAt: Date())
        var details: [ImportedDetail] = []
        if plan.listsSamples, case .samples(let list) = read {
            details = list.map { sample in
                ImportedDetail(label: "\(Self.when(sample)), \(sample.source)",
                               value: "\(ImportedFormat.number(sample.value, decimals: plan.decimals)) \(plan.unitLabel)")
            }
        }
        return ImportedItem(id: plan.id.rawValue, title: plan.title, summary: summary,
                            showsRange: plan.showsRange, showsTotals: plan.showsTotals, decimals: plan.decimals,
                            admissibleNote: plan.admissibleNote, statisticNote: note, details: details)
    }

    /// Serie battito-battito: solo il numero di serie e l'intervallo coperto. I battiti non vengono letti.
    private func heartbeatItem(night: ImportInterval, zone: String) async -> ImportedItem {
        let read: ImportRead<ImportedSample> = await fetch(HKSeriesType.heartbeat(), in: night) { sample in
            ImportedSample(uuid: sample.uuid.uuidString, start: sample.startDate, end: sample.endDate,
                           value: 0, source: sample.sourceRevision.source.name)
        }
        let summary = ImportedSeries.summarize(
            typeIdentifier: "HKDataTypeIdentifierHeartbeatSeries", unit: "serie", read: read, requested: night,
            timeZoneIdentifier: zone, hasDuration: true, readAt: Date())
        return ImportedItem(id: summary.provenance.typeIdentifier, title: "Serie battito-battito", summary: summary,
                            showsRange: false, showsTotals: false, decimals: 0,
                            admissibleNote: nil, statisticNote: nil, details: [])
    }

    /// Allenamenti: tipo, inizio, durata e sorgente. Nessun altro valore viene letto.
    private func workoutItem(day: ImportInterval, zone: String) async -> ImportedItem {
        let read: ImportRead<WorkoutRow> = await fetch(HKObjectType.workoutType(), in: day) { sample in
            guard let workout = sample as? HKWorkout else { return nil }
            let imported = ImportedSample(uuid: workout.uuid.uuidString, start: workout.startDate,
                                          end: workout.endDate, value: workout.duration / 60,
                                          source: workout.sourceRevision.source.name)
            return WorkoutRow(sample: imported, activity: workout.workoutActivityType.rawValue)
        }
        var rows: [WorkoutRow] = []
        let plain: ImportRead<ImportedSample>
        switch read {
        case .samples(let list):
            rows = list
            plain = .samples(list.map { $0.sample })
        case .failure(let domain, let code):
            plain = .failure(domain: domain, code: code)
        }
        let summary = ImportedSeries.summarize(
            typeIdentifier: "HKWorkoutTypeIdentifier", unit: "min", read: plain, requested: day,
            timeZoneIdentifier: zone, hasDuration: true, readAt: Date())
        let details = rows.map { row in
            ImportedDetail(label: "\(Self.workoutName(row.activity)), \(row.sample.source)",
                           value: "\(Self.when(row.sample)), durata \(ImportedFormat.number(row.sample.value)) min")
        }
        return ImportedItem(id: summary.provenance.typeIdentifier, title: "Allenamenti", summary: summary,
                            showsRange: false, showsTotals: false, decimals: 0,
                            admissibleNote: nil, statisticNote: nil, details: details)
    }

    private static func when(_ sample: ImportedSample) -> String {
        if sample.start == sample.end { return ImportText.date(sample.start) }
        return ImportText.interval(ImportInterval(start: sample.start, end: sample.end))
    }

    private static func workoutName(_ raw: UInt) -> String {
        guard let type = HKWorkoutActivityType(rawValue: raw) else { return "Tipo n. \(raw)" }
        switch type {
        case .running: return "Corsa"
        case .walking: return "Camminata"
        case .cycling: return "Ciclismo"
        case .swimming: return "Nuoto"
        case .hiking: return "Escursionismo"
        case .yoga: return "Yoga"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "Allenamento di forza"
        case .highIntensityIntervalTraining: return "Allenamento a intervalli"
        case .other: return "Altro"
        default: return "Tipo n. \(raw)"
        }
    }

    private func quantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit, scale: Double,
                          in interval: ImportInterval) async -> ImportRead<ImportedSample> {
        await fetch(HKQuantityType(id), in: interval) { sample in
            guard let quantity = sample as? HKQuantitySample else { return nil }
            return ImportedSample(uuid: quantity.uuid.uuidString, start: quantity.startDate, end: quantity.endDate,
                                  value: quantity.quantity.doubleValue(for: unit) * scale,
                                  source: quantity.sourceRevision.source.name)
        }
    }

    private func sleepSamples(in interval: ImportInterval) async -> ImportRead<ImportedSleepSample> {
        await fetch(HKCategoryType(.sleepAnalysis), in: interval) { sample in
            guard let category = sample as? HKCategorySample else { return nil }
            return ImportedSleepSample(uuid: category.uuid.uuidString, start: category.startDate,
                                       end: category.endDate, categoryRawValue: category.value,
                                       source: category.sourceRevision.source.name)
        }
    }

    /// Lettura generica: un errore diventa lo stato "errore" con dominio e codice, mai un elenco vuoto.
    private func fetch<Row: Sendable>(_ type: HKSampleType, in interval: ImportInterval,
                                      map: @escaping @Sendable (HKSample) -> Row?) async -> ImportRead<Row> {
        await withCheckedContinuation { (continuation: CheckedContinuation<ImportRead<Row>, Never>) in
            let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, found, error in
                if let failure = error as NSError? {
                    continuation.resume(returning: .failure(domain: failure.domain, code: failure.code))
                    return
                }
                continuation.resume(returning: .samples((found ?? []).compactMap(map)))
            }
            store.execute(query)
        }
    }

    /// Totale secondo la statistica di Salute. L'assenza di dati non e' un errore e non e' zero.
    private func statisticSum(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                              in interval: ImportInterval) async -> StatisticTotal {
        await withCheckedContinuation { (continuation: CheckedContinuation<StatisticTotal, Never>) in
            let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
            let query = HKStatisticsQuery(quantityType: HKQuantityType(id), quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, statistics, error in
                if let known = error as? HKError, known.code == .errorNoData {
                    continuation.resume(returning: .noData)
                    return
                }
                if let failure = error as NSError? {
                    continuation.resume(returning: .failure(domain: failure.domain, code: failure.code))
                    return
                }
                if let sum = statistics?.sumQuantity() {
                    continuation.resume(returning: .value(sum.doubleValue(for: unit)))
                } else {
                    continuation.resume(returning: .noData)
                }
            }
            store.execute(query)
        }
    }
}
