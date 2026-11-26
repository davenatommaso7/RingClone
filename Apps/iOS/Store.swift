import Foundation
import Combine
import RingCore
import UIKit

/// Stato dell'app: profilo, storico dei report, aggiornamento. Tutto ciò che è calcolo sta in RingCore.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var reports: [DailyReport] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var demo = false
    @Published private(set) var hasProfile = false
    @Published private(set) var profile = UserProfile(age: 30, sex: .male, heightCm: 175, weightKg: 70)

    /// calendario con cui sono stati calcolati i report mostrati (UTC nella modalità dimostrativa)
    private(set) var calendar = Calendar.current

    let hk = HealthRepository()
    let archive: MotionArchive
    let link: PhoneConnectivity
    private let dir: URL
    private var started = false
    private var pendingDays: Int?

    private var historyURL: URL { dir.appendingPathComponent("history.json") }
    private var profileURL: URL { dir.appendingPathComponent("profile.json") }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("RingClone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        archive = MotionArchive(directory: dir.appendingPathComponent("motion", isDirectory: true))
        link = PhoneConnectivity(archive: archive)
        if let d = try? Data(contentsOf: profileURL), let p = try? JSONDecoder().decode(UserProfile.self, from: d) {
            profile = p; hasProfile = true
        }
        do { reports = try History.load(from: historyURL) }
        catch { message = "L’archivio dei report non è leggibile." }
    }

    // MARK: - Avvio

    /// Da chiamare una volta all'apertura: collegamento col Watch, permessi di Salute, primo aggiornamento
    func start() async {
        guard !started else { return }
        started = true
        link.onMotion = { Task { @MainActor in await Store.shared.refresh() } }
        link.activate()
        guard HealthRepository.isAvailable else {
            message = "Apple Salute non è disponibile su questo dispositivo: puoi usare la modalità dimostrativa."
            return
        }
        do { try await hk.authorize() } catch { message = "Permessi di Salute non concessi: \(error.localizedDescription)" }
        hk.startObservers { Task { @MainActor in await Store.shared.refresh() } }
        await refresh()
    }

    // MARK: - Profilo

    func update(profile p: UserProfile) async {
        guard p != profile || !hasProfile else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(p).write(to: profileURL, options: .atomic)
        } catch {
            message = "Il profilo non è stato salvato. Riprova quando l’archivio è accessibile."
            return
        }
        profile = p; hasProfile = true
        // età, peso, zone e fabbisogno di sonno entrano in quasi tutti i punteggi: si ricalcola lo storico recente
        if demo { await loadDemo() } else { await refresh(days: 30) }
    }

    // MARK: - Aggiornamento

    /// Rielabora gli ultimi giorni in ordine cronologico. È sicuro richiamarla quante volte si vuole:
    /// la pipeline è idempotente e ogni giorno usa come storico solo i giorni che lo precedono.
    /// - Parameter days: quanti giorni fino a oggi; nil = 30 al primo avvio, poi 3 (ieri e l'altro ieri
    ///   si completano quando arrivano in ritardo i dati del Watch).
    func refresh(days: Int? = nil) async {
        guard !demo, HealthRepository.isAvailable else { return }
        // una richiesta arrivata durante un aggiornamento non va persa: viene accodata (tenendo l'intervallo più lungo)
        if busy { pendingDays = max(pendingDays ?? 0, days ?? 0); return }
        busy = true
        defer { busy = false }
        var span = days ?? 0
        repeat {
            pendingDays = nil
            await refreshOnce(days: max(span, reports.isEmpty ? 30 : 3))
            span = pendingDays ?? 0
        } while pendingDays != nil
    }

    private func refreshOnce(days: Int) async {
        let cal = Calendar.current, now = Date()
        let today = cal.startOfDay(for: now)
        let assembler = DayAssembler(hk: hk, archive: archive, hardwareScope: UIDevice.current.identifierForVendor)
        let profile = self.profile
        var history: [DailyReport]
        do { history = try History.load(from: historyURL) }
        catch {
            message = "L’archivio dei report non è leggibile."
            return
        }
        var failure: String?
        var todayNotUpdated = false
        for k in stride(from: days - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -k, to: today) else { continue }
            do {
                let input = try await assembler.input(for: day, calendar: cal, now: now)
                let before = history
                let report = await Task.detached(priority: .utility) {
                    DailyPipeline.run(input, profile: profile, history: before)
                }.value
                history = History.upsert(report, into: history, calendar: cal)
            } catch DayAssembler.Failure.noData {
                if k == 0 { todayNotUpdated = true }
                continue // Una rilettura vuota non identifica una cancellazione.
            } catch {
                failure = "Dati non aggiornati. Riprova con l’iPhone sbloccato."
                break
            }
        }
        do { try History.save(history, to: historyURL) }
        catch {
            message = "I report non sono stati aggiornati sul dispositivo. Riprova quando l’archivio è accessibile."
            return
        }
        calendar = cal
        reports = history
        message = failure ?? (todayNotUpdated ? "Dati di oggi non disponibili. Salute non ha restituito campioni leggibili." : nil)
        archive.prune(olderThan: 40, now: now)
        if let last = history.last, last.state(\.zones).hasValue, last.state(\.rhr).hasValue {
            link.send(WatchSettings(report: last))
        }
    }

    // MARK: - Modalità dimostrativa

    /// Tre settimane di dati sintetici elaborati dalla stessa pipeline: serve a vedere l'app senza Apple Watch.
    /// Non viene salvato nulla su disco.
    func loadDemo() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let profile = self.profile
        let result = await Task.detached(priority: .userInitiated) { () -> [DailyReport] in
            let cal = Synthetic.utc
            let today = cal.startOfDay(for: Date())
            var h = Synthetic.history(days: 21, before: today, calendar: cal, profile: profile)
            let s = Synthetic.day(today, calendar: cal, profile: profile, options: Synthetic.options(for: today, calendar: cal, seed: 7))
            h = History.upsert(DailyPipeline.run(s.input, profile: profile, history: h), into: h, calendar: cal)
            return h
        }.value
        calendar = Synthetic.utc
        reports = result
        demo = true
        message = "Modalità dimostrativa: dati sintetici, non tuoi."
    }

    func exitDemo() async {
        demo = false
        message = nil
        calendar = Calendar.current
        do { reports = try History.load(from: historyURL) }
        catch {
            reports = []
            message = "L’archivio dei report non è leggibile."
            return
        }
        await refresh()
    }
}
