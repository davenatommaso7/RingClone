import Foundation

/// Statistica robusta di una grandezza personale: mediana e dispersione (MAD) sulle ultime notti.
public struct RobustStat: Sendable, Equatable {
    public var center: Double
    public var spread: Double
    public var n: Int
    /// servono almeno 7 valori per confrontarsi con la propria baseline
    public var ready: Bool { n >= 7 }

    public init(_ values: [Double], minSpread: Double) {
        n = values.count
        center = values.isEmpty ? .nan : Stats.median(values)
        spread = values.count >= 3 ? max(Stats.mad(values), minSpread) : minSpread
    }
    /// scostamento standardizzato; 0 (neutro) finché la baseline non è pronta
    public func z(_ x: Double?) -> Double {
        guard ready, let x, x.isFinite else { return 0 }
        return (x - center) / spread
    }
}

/// Baseline personali ricavate, quando servono, dai report dei giorni PRECEDENTI a quello in elaborazione.
/// Non esiste stato mutabile salvato a parte: rielaborare lo stesso giorno dà sempre lo stesso risultato
/// (pipeline idempotente) e la notte in esame non entra nella baseline con cui viene giudicata.
public struct Baselines: Sendable {
    public var rhr: RobustStat
    public var lnRMSSD: RobustStat
    public var temp: RobustStat
    public var resp: RobustStat
    /// media di lnRMSSD delle ultime 7 notti (per l'HRV Form)
    public var hrv7: Double?
    /// centro abituale del sonno (media circolare, ultime 14 notti)
    public var midpointCenter: Double?
    public var wakeCenter: Double?
    public var onsetCenter: Double?
    /// report con notte valida degli ultimi 28 giorni (dal più vecchio)
    public var recent: [DailyReport]
    /// TRIMP dei 28 giorni precedenti (0 per i giorni senza dati), dal più vecchio
    public var trimp28: [Double]
    /// Carico osservabile dei 28 giorni precedenti. nil indica copertura sconosciuta.
    public var observedTrimp28: [Double?]
    /// allenamenti degli ultimi 180 giorni
    public var workouts: [WorkoutRecord]
    public var previousCardioAge: Double?
    public var previousDebtDays: [(date: Date, sleepMin: Double?)]
    public var nights: Int
    /// giorni con un report tra i 28 precedenti (per sapere se il carico cronico è attendibile)
    public var days28: Int

    public init(history: [DailyReport], before day: Date, calendar: Calendar) {
        let start = calendar.startOfDay(for: day)
        let past = History.onePerDay(history, calendar: calendar).filter { $0.date < start }
        func within(_ days: Int) -> [DailyReport] {
            let from = calendar.date(byAdding: .day, value: -days, to: start) ?? start.addingTimeInterval(Double(-days) * 86_400)
            return past.filter { $0.date >= from }
        }
        let w60 = within(60).compactMap { $0.night }
        rhr = RobustStat(w60.compactMap { $0.rhr }.filter { $0.isFinite && $0 > 0 }, minSpread: 1.5)
        lnRMSSD = RobustStat(w60.compactMap { $0.rmssd }.filter { $0.isFinite && $0 > 0 }.map { log($0) }, minSpread: 0.08)
        temp = RobustStat(w60.compactMap { $0.skinTemp }.filter(\.isFinite), minSpread: 0.15)
        resp = RobustStat(w60.compactMap { $0.respRate }.filter { $0.isFinite && $0 > 0 }, minSpread: 0.4)
        nights = w60.count
        let h7 = within(7).compactMap { $0.night?.rmssd }.filter { $0.isFinite && $0 > 0 }.map { log($0) }
        hrv7 = h7.count >= 3 ? Stats.mean(h7) : nil
        let n14 = within(14).compactMap { $0.night }
        midpointCenter = n14.count >= 3 ? Stats.circularMeanHours(n14.map { $0.midpointH }) : nil
        wakeCenter = n14.count >= 3 ? Stats.circularMeanHours(n14.map { $0.wakeH }) : nil
        onsetCenter = n14.count >= 3 ? Stats.circularMeanHours(n14.map { $0.onsetH }) : nil
        recent = within(28).filter { $0.night != nil }
        var dayByWorkoutID: [UUID: Date] = [:], workoutsOnMultipleDays = Set<UUID>()
        for report in within(28) {
            for id in report.workouts.compactMap(\.sourceID) {
                if let previous = dayByWorkoutID.updateValue(report.date, forKey: id), previous != report.date {
                    workoutsOnMultipleDays.insert(id)
                }
            }
        }
        var t: [Double] = [], observed: [Double?] = []
        for k in stride(from: 28, through: 1, by: -1) {
            let d = calendar.date(byAdding: .day, value: -k, to: start) ?? start.addingTimeInterval(Double(-k) * 86_400)
            let r = past.first { calendar.isDate($0.date, inSameDayAs: d) }
            t.append(r?.trimp ?? 0)
            observed.append(r.flatMap { report in
                guard report.state(\.trimp).hasValue,
                      !report.workouts.compactMap(\.sourceID).contains(where: { workoutsOnMultipleDays.contains($0) }) else { return nil }
                return report.trimp
            })
        }
        trimp28 = t
        observedTrimp28 = observed
        days28 = within(28).count
        workouts = History.uniqueWorkouts(within(180).flatMap { $0.workouts })
        previousCardioAge = within(30).last { $0.state(\.fitness).hasValue }?.cardioAge
        previousDebtDays = within(13).map { ($0.date, $0.dailySleepMin) }
    }
}

public enum History {
    /// Giorno civile nel calendario del report. Vince la revisione acquisita più tardi.
    /// In assenza di precedenza temporale, l'ordine dei byte canonici rompe il pareggio.
    static func onePerDay(_ history: [DailyReport], calendar: Calendar) -> [DailyReport] {
        var days: [Date: DailyReport] = [:]
        for report in history {
            let day = calendar.startOfDay(for: report.date)
            if let old = days[day] {
                let oldTime = old.computedAt ?? .distantPast, newTime = report.computedAt ?? .distantPast
                if oldTime > newTime { continue }
                if oldTime == newTime {
                    guard let a = try? encode([old]), let b = try? encode([report]), a.lexicographicallyPrecedes(b) else { continue }
                }
            }
            days[day] = report
        }
        return days.values.sorted { $0.date < $1.date }
    }

    /// Le revisioni dallo stesso UUID occupano una sola voce. Per i record legacy vale l'identità esatta.
    static func uniqueWorkouts(_ workouts: [WorkoutRecord]) -> [WorkoutRecord] {
        var result: [WorkoutRecord] = []
        var indexByID: [UUID: Int] = [:]
        for workout in workouts {
            guard let id = workout.sourceID else {
                if !result.contains(workout) { result.append(workout) }
                continue
            }
            if let i = indexByID[id] {
                let old = result[i]
                if old != workout, let a = try? encoder().encode(old), let b = try? encoder().encode(workout),
                   a.lexicographicallyPrecedes(b) { result[i] = workout }
            } else {
                indexByID[id] = result.count
                result.append(workout)
            }
        }
        return result.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end < b.end }
            return (a.sourceID?.uuidString ?? "") < (b.sourceID?.uuidString ?? "")
        }
    }

    /// Inserisce o sostituisce il report del giorno, mantiene l'ordine cronologico e al massimo `keepDays` giorni.
    public static func upsert(_ report: DailyReport, into history: [DailyReport], calendar: Calendar, keepDays: Int = 400) -> [DailyReport] {
        var h = onePerDay(history + [report], calendar: calendar)
        if let last = h.last?.date, let limit = calendar.date(byAdding: .day, value: -keepDays, to: last) {
            h.removeAll { $0.date < limit }
        }
        return h
    }

    public static func encode(_ history: [DailyReport]) throws -> Data {
        try encoder().encode(history)
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]                 // uscita deterministica: stesso storico, stessi byte
        e.dateEncodingStrategy = .secondsSince1970
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    public static func decode(_ data: Data) throws -> [DailyReport] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try d.decode([DailyReport].self, from: data)
    }

    public static func load(from url: URL) throws -> [DailyReport] {
        do { return try decode(Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    public static func save(_ history: [DailyReport], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(history).write(to: url, options: .atomic)
    }
}
