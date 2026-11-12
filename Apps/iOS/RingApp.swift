import SwiftUI
import BackgroundTasks

@main
struct RingApp: App {
    /// deve comparire anche in Info.plist, alla voce BGTaskSchedulerPermittedIdentifiers
    static let refreshID = "it.ringclone.refresh"

    @StateObject private var store = Store.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(store)
                .task { await store.start() }
        }
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .active: Task { await store.refresh() }
            case .background: Self.scheduleRefresh()
            default: break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshID)) {
            await Store.shared.refresh()
            Self.scheduleRefresh()
        }
    }

    /// Chiede a iOS un risveglio in background. È il sistema a decidere se e quando concederlo:
    /// l'aggiornamento certo avviene all'apertura dell'app.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date().addingTimeInterval(2 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
