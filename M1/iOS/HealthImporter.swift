import Foundation
import HealthKit
import RingCore

// Importatore di M1 (voci ACQ-01, ACQ-02, ACQ-03, ACQ-04, PLT-15).
// Legge Salute in sola lettura e produce riepiloghi con provenienza.
// Non passa dall'elaborazione giornaliera della BL-0 e non conserva nulla: ogni apertura rilegge.
// Primo passo: frequenza cardiaca, passi e sonno.

struct ImportedItem: Identifiable {
    let id: String
    let title: String
    let summary: ImportedSeriesSummary
    let showsRange: Bool
    let showsTotals: Bool
    let admissibleNote: String?
    let statisticNote: String?
}

struct ImportResult {
    let items: [ImportedItem]
    let sleep: ImportedSleepSeries
}

enum StatisticTotal {
    case value(Double)
    case noData
    case failure(domain: String, code: Int)
}

final class HealthImporter: @unchecked Sendable {
    private let store = HKHealthStore()

    static let bpm = HKUnit.count().unitDivided(by: .minute())

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        types.insert(HKQuantityType(.heartRate))
        types.insert(HKQuantityType(.stepCount))
        types.insert(HKCategoryType(.sleepAnalysis))
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

    /// Giorno di calendario corrente, dalla mezzanotte a ora. Per il sonno dalle 18 del giorno prima.
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

        let heartRead = await quantity(.heartRate, unit: Self.bpm, in: day)
        let heart = ImportedSeries.summarize(
            typeIdentifier: HKQuantityTypeIdentifier.heartRate.rawValue, unit: "battiti/min", read: heartRead,
            requested: day, timeZoneIdentifier: zone, admissible: 30...210, hasDuration: false, readAt: Date())

        let stepsRead = await quantity(.stepCount, unit: .count(), in: day)
        var stepsTotal: Double? = nil
        var stepsNote: String? = nil
        switch await statisticSum(.stepCount, unit: .count(), in: day) {
        case .value(let total):
            stepsTotal = total
        case .noData:
            break
        case .failure(let domain, let code):
            stepsNote = "Errore di lettura: \(domain) \(code)"
        }
        let steps = ImportedSeries.summarize(
            typeIdentifier: HKQuantityTypeIdentifier.stepCount.rawValue, unit: "passi", read: stepsRead,
            requested: day, timeZoneIdentifier: zone, hasDuration: true, healthStatisticTotal: stepsTotal,
            readAt: Date())

        let sleepRead = await sleepSamples(in: night)
        let sleep = ImportedSleep.summarize(read: sleepRead, requested: night, timeZoneIdentifier: zone, readAt: Date())

        let items = [
            ImportedItem(id: heart.provenance.typeIdentifier, title: "Frequenza cardiaca", summary: heart,
                         showsRange: true, showsTotals: false,
                         admissibleNote: "Campioni non numerici o fuori da 30-210 battiti/min", statisticNote: nil),
            ImportedItem(id: steps.provenance.typeIdentifier, title: "Passi", summary: steps,
                         showsRange: false, showsTotals: true, admissibleNote: nil, statisticNote: stepsNote),
        ]
        return ImportResult(items: items, sleep: sleep)
    }

    private func quantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                          in interval: ImportInterval) async -> ImportRead<ImportedSample> {
        await withCheckedContinuation { (continuation: CheckedContinuation<ImportRead<ImportedSample>, Never>) in
            let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            let query = HKSampleQuery(sampleType: HKQuantityType(id), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, found, error in
                if let failure = error as NSError? {
                    continuation.resume(returning: .failure(domain: failure.domain, code: failure.code))
                    return
                }
                let list = (found ?? []).compactMap { $0 as? HKQuantitySample }.map { sample in
                    ImportedSample(uuid: sample.uuid.uuidString, start: sample.startDate, end: sample.endDate,
                                   value: sample.quantity.doubleValue(for: unit),
                                   source: sample.sourceRevision.source.name)
                }
                continuation.resume(returning: .samples(list))
            }
            store.execute(query)
        }
    }

    private func sleepSamples(in interval: ImportInterval) async -> ImportRead<ImportedSleepSample> {
        await withCheckedContinuation { (continuation: CheckedContinuation<ImportRead<ImportedSleepSample>, Never>) in
            let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            let query = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, found, error in
                if let failure = error as NSError? {
                    continuation.resume(returning: .failure(domain: failure.domain, code: failure.code))
                    return
                }
                let list = (found ?? []).compactMap { $0 as? HKCategorySample }.map { sample in
                    ImportedSleepSample(uuid: sample.uuid.uuidString, start: sample.startDate, end: sample.endDate,
                                        categoryRawValue: sample.value, source: sample.sourceRevision.source.name)
                }
                continuation.resume(returning: .samples(list))
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
