import Foundation

/// Temperatura cutanea notturna. Con un sensore continuo (anello) si ha una serie; da Apple Watch
/// arriva un solo valore per notte (appleSleepingWristTemperature), usato così com'è.
public enum Temperature {
    public struct Night: Sendable {
        /// valore rappresentativo della notte (°C): mediana in sonno, esclusi i primi 20 min (transitorio di vasodilatazione)
        public let value: Double
        /// istante del minimo della curva lisciata (30 min), utile come àncora circadiana
        public let minimumAt: Date?
    }

    public static func night(series: [TimedValue], sleepStart: Date, sleepEnd: Date) -> Night? {
        let s = series.filter { $0.date >= sleepStart.addingTimeInterval(20 * 60) && $0.date <= sleepEnd && $0.value > 25 && $0.value < 42 }
            .sorted { $0.date < $1.date }
        guard s.count >= 6 else { return nil }
        let value = Stats.median(s.map { $0.value })
        // lisciatura a finestra temporale di ±15 min
        var best: (Double, Date)?
        var a = 0, b = 0, sum = 0.0
        for i in s.indices {
            while b < s.count && s[b].date.timeIntervalSince(s[i].date) <= 900 { sum += s[b].value; b += 1 }
            while s[i].date.timeIntervalSince(s[a].date) > 900 { sum -= s[a].value; a += 1 }
            let m = sum / Double(b - a)
            if b - a >= 3, best == nil || m < best!.0 { best = (m, s[i].date) }
        }
        return Night(value: value, minimumAt: best?.1)
    }
}
