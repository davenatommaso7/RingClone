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
    /// allenamenti degli ultimi 180 giorni
    public var workouts: [WorkoutRecord]
    public var previousCardioAge: Double?
    public var previousDebtDays: [(date: Date, sleepMin: Double?)]
    public var nights: Int
    /// giorni con un report tra i 28 precedenti (per sapere se il carico cronico è attendibile)
    public var days28: Int

    public init(history: [DailyReport], before day: Date, calendar: Calendar) {
        let past = history.filter { $0.date < day }.sorted { $0.date < $1.date }
        func within(_ days: Int) -> [DailyReport] {
            let from = calendar.date(byAdding: .day, value: -days, to: day) ?? day.addingTimeInterval(Double(-days) * 86_400)
            return past.filter { $0.date >= from }
        }
        let w60 = within(60).compactMap { $0.night }
        rhr = RobustStat(w60.compactMap { $0.rhr }, minSpread: 1.5)
        lnRMSSD = RobustStat(w60.compactMap { $0.rmssd }.filter { $0 > 0 }.map { log($0) }, minSpread: 0.08)
        temp = RobustStat(w60.compactMap { $0.skinTemp }, minSpread: 0.15)
        resp = RobustStat(w60.compactMap { $0.respRate }, minSpread: 0.4)
        nights = w60.count
        let h7 = within(7).compactMap { $0.night?.rmssd }.filter { $0 > 0 }.map { log($0) }
        hrv7 = h7.count >= 3 ? Stats.mean(h7) : nil
        let n14 = within(14).compactMap { $0.night }
        midpointCenter = n14.count >= 3 ? Stats.circularMeanHours(n14.map { $0.midpointH }) : nil
        wakeCenter = n14.count >= 3 ? Stats.circularMeanHours(n14.map { $0.wakeH }) : nil
        onsetCenter = n14.count >= 3 ? Stats.circularMeanHours(n14.map { $0.onsetH }) : nil
        recent = within(28).filter { $0.night != nil }
        var t: [Double] = []
        for k in stride(from: 28, through: 1, by: -1) {
            let d = calendar.date(byAdding: .day, value: -k, to: day) ?? day.addingTimeInterval(Double(-k) * 86_400)
            t.append(past.first { calendar.isDate($0.date, inSameDayAs: d) }?.trimp ?? 0)
        }
        trimp28 = t
        days28 = within(28).count
        workouts = within(180).flatMap { $0.workouts }
        previousCardioAge = within(30).last?.cardioAge
        previousDebtDays = within(13).map { ($0.date, $0.dailySleepMin) }
    }
}

public enum History {
    /// Inserisce o sostituisce il report del giorno, mantiene l'ordine cronologico e al massimo `keepDays` giorni.
    public static func upsert(_ report: DailyReport, into history: [DailyReport], calendar: Calendar, keepDays: Int = 400) -> [DailyReport] {
        var h = history.filter { !calendar.isDate($0.date, inSameDayAs: report.date) }
        h.append(report)
        h.sort { $0.date < $1.date }
        if let last = h.last?.date, let limit = calendar.date(byAdding: .day, value: -keepDays, to: last) {
            h.removeAll { $0.date < limit }
        }
        return h
    }

    public static func encode(_ history: [DailyReport]) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]                 // uscita deterministica: stesso storico, stessi byte
        e.dateEncodingStrategy = .secondsSince1970
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try e.encode(history)
    }

    public static func decode(_ data: Data) throws -> [DailyReport] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try d.decode([DailyReport].self, from: data)
    }
}
