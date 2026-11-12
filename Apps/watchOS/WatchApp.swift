import SwiftUI
import WatchKit
import HealthKit
import RingCore

@main
struct RingWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchDelegate
    @StateObject private var workout = WorkoutManager()

    var body: some Scene {
        WindowGroup {
            WatchHome()
                .environmentObject(workout)
                .task {
                    WatchLink.shared.onSettings = { workout.settings = $0 }
                    await workout.authorize()
                }
        }
    }
}

/// Ciclo di vita: registrazione continua del movimento e risvegli periodici in background
final class WatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WatchLink.shared.activate()
        MotionRecorder.shared.arm()
        scheduleRefresh()
    }

    func applicationDidBecomeActive() {
        MotionRecorder.shared.arm()
        // in primo piano c'è tempo: si recupera tutto l'arretrato
        MotionRecorder.shared.process(maxSpan: 72 * 3600) { WatchLink.shared.flush() }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard let refresh = task as? WKApplicationRefreshBackgroundTask else {
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
            MotionRecorder.shared.arm()
            scheduleRefresh()
            MotionRecorder.shared.process(maxSpan: 4 * 3600) {
                DispatchQueue.main.async { refresh.setTaskCompletedWithSnapshot(false) }
            }
        }
    }

    /// watchOS concede i risvegli quando vuole (di solito circa uno all'ora se l'app ha una complicazione attiva):
    /// i 3 giorni di memoria del sensore coprono i ritardi.
    private func scheduleRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: Date().addingTimeInterval(60 * 60), userInfo: nil) { _ in }
    }
}

private struct WatchHome: View {
    @EnvironmentObject private var workout: WorkoutManager

    private struct Choice: Identifiable {
        let id: String
        let type: HKWorkoutActivityType
        let location: HKWorkoutSessionLocationType
    }
    private let activities = [
        Choice(id: "Corsa", type: .running, location: .outdoor), Choice(id: "Camminata", type: .walking, location: .outdoor),
        Choice(id: "Bici", type: .cycling, location: .outdoor), Choice(id: "Forza", type: .traditionalStrengthTraining, location: .indoor),
    ]

    var body: some View {
        if workout.running { live } else { menu }
    }

    private var live: some View {
        VStack(spacing: 6) {
            Text("\(Int(workout.hr.rounded()))")
                .font(.system(size: 52, weight: .semibold, design: .rounded)).monospacedDigit()
                .accessibilityLabel("Frequenza cardiaca \(Int(workout.hr.rounded())) battiti al minuto")
            Text(workout.zone == 0 ? "Sotto la zona 1" : "Zona \(workout.zone)")
                .font(.headline)
            if let start = workout.startDate {
                Text(start, style: .timer).monospacedDigit()
            }
            Text("\(Int(workout.kcal.rounded())) kcal").font(.footnote).foregroundStyle(.secondary)
            Button("Termina", role: .destructive) { workout.stop() }
        }
    }

    private var menu: some View {
        List {
            if let e = workout.error {
                Text(e).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(activities) { a in
                Button(a.id) { workout.start(a.type, location: a.location) }
            }
            Text("Il movimento del polso viene registrato da solo, giorno e notte.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("Ring")
    }
}
