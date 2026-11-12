import Foundation
import Combine
import HealthKit
import RingCore

/// Sessione di allenamento sul Watch: frequenza cardiaca ogni pochi secondi, zona in tempo reale con i limiti
/// personali ricevuti dall'iPhone, salvataggio dell'allenamento in Apple Salute.
/// Durante la sessione si attivano anche giroscopio e accelerometro ad alta frequenza (`WorkoutMotion`).
/// Lo stato pubblicato viene modificato solo sulla coda principale (per questo la classe è dichiarata Sendable a mano).
final class WorkoutManager: NSObject, ObservableObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, @unchecked Sendable {
    @Published private(set) var hr: Double = 0
    @Published private(set) var zone = 0
    @Published private(set) var kcal: Double = 0
    @Published private(set) var running = false
    @Published private(set) var startDate: Date?
    @Published private(set) var error: String?
    @Published var settings: WatchSettings

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private let motion = WorkoutMotion()

    private static let bpm = HKUnit.count().unitDivided(by: .minute())

    override init() {
        settings = WatchLink.shared.settings
        super.init()
    }

    /// Permessi di Salute sul Watch: senza questa richiesta la sessione non parte e la FC live non arriva
    func authorize() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned), HKObjectType.workoutType()]
        do { try await store.requestAuthorization(toShare: share, read: read) } catch {
            await MainActor.run { self.error = "Permessi di Salute non concessi" }
        }
    }

    func start(_ activity: HKWorkoutActivityType, location: HKWorkoutSessionLocationType = .outdoor) {
        guard session == nil else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = activity
        config.locationType = location
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            s.delegate = self
            b.delegate = self
            session = s
            builder = b
            let now = Date()
            s.startActivity(with: now)
            b.beginCollection(withStart: now) { ok, err in
                let failure = err?.localizedDescription
                DispatchQueue.main.async {
                    if ok {
                        self.running = true; self.startDate = now; self.error = nil
                    } else {
                        self.error = failure ?? "Impossibile avviare l'allenamento"
                        self.cleanup()
                    }
                }
            }
            motion.start()
        } catch {
            self.error = error.localizedDescription
            cleanup()
        }
    }

    /// Chiude la sessione; il salvataggio avviene quando il sistema conferma lo stato "terminata" (vedi delegato)
    func stop() {
        guard let s = session else { return }
        motion.stop()
        s.end()
    }

    private func cleanup() {
        session = nil
        builder = nil
        running = false
        startDate = nil
        hr = 0
        zone = 0
        kcal = 0
    }

    // MARK: HKLiveWorkoutBuilderDelegate

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hrType = HKQuantityType(.heartRate), energyType = HKQuantityType(.activeEnergyBurned)
        let bpm = workoutBuilder.statistics(for: hrType)?.mostRecentQuantity()?.doubleValue(for: Self.bpm)
        let energy = workoutBuilder.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie())
        DispatchQueue.main.async {
            if let bpm {
                self.hr = bpm
                self.zone = HeartRate.zone(of: bpm, bounds: self.settings.zoneBounds)
            }
            if let energy { self.kcal = energy }
        }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    // MARK: HKWorkoutSessionDelegate

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended, let b = builder else { return }
        b.endCollection(withEnd: date) { _, _ in
            b.finishWorkout { _, err in                              // scrive l'allenamento in Apple Salute
                let failure = err?.localizedDescription
                DispatchQueue.main.async {
                    if let failure { self.error = failure }
                    self.cleanup()
                }
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let failure = error.localizedDescription
        DispatchQueue.main.async {
            self.motion.stop()
            self.error = failure
            self.cleanup()
        }
    }
}
