import Foundation

/// Generatore deterministico di giornate realistiche con verità nota (stadi, orari, passi, respiro).
/// Serve per i test automatici e per la modalità dimostrativa dell'app: NON sostituisce la validazione su dati reali.
public enum Synthetic {
    public struct Options: Sendable {
        public var seed: UInt64 = 1
        /// ora di andata a letto, contata dalla mezzanotte del giorno precedente (23 = 23:00, 24,5 = 00:30)
        public var bedH = 23.0
        /// ore a letto
        public var inBedH = 7.9
        public var rhr = 54.0
        /// RMSSD notturno indicativo (ms)
        public var rmssd = 55.0
        public var respRate = 14.5
        public var steps = 9000.0
        public var workout = true
        public var nap = false
        /// aggiunge stadi "Apple" con circa l'80 % di accordo con la verità
        public var appleStages = false
        public var beats = true
        public var tempSeries = true
        /// scostamento della temperatura cutanea (°C) e della FC diurna (bpm), per simulare malessere o stress
        public var tempOffset = 0.0
        public var dayHROffset = 0.0
        public init() {}
    }

    public struct Day: Sendable {
        public var input: DayInput
        /// stadio vero per ogni epoca di `input.epochs` (veglia di giorno)
        public var truth: [SleepStage]
        public var lightsOut: Date
        public var onset: Date
        public var wake: Date
        /// passi veri del giorno di calendario
        public var steps: Double
    }

    public static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private enum Act { case sleep, bedWake, sedentary, walk, run }

    public static func day(_ day: Date, calendar: Calendar = Synthetic.utc, profile: UserProfile, options o: Options = Options()) -> Day {
        var rng = SeededRNG(seed: o.seed)
        let ep = RingConst.epoch
        let start = day.addingTimeInterval(-DayInput.lookback)
        let n = 3600                                          // 30 ore
        var stage = [SleepStage](repeating: .wake, count: n)
        var act = [Act](repeating: .sedentary, count: n)
        func idx(_ hoursFromMidnight: Double) -> Int { Int(((hoursFromMidnight + 6) * 120).rounded()) }

        // ── notte: latenza, cicli da ~90 min (profondo all'inizio, REM alla fine), brevi risvegli ──
        let lights = idx(o.bedH - 24), out = min(lights + Int(o.inBedH * 120), n - 1)
        let sol = 16 + Int(rng.uniform(0, 14))
        var i = lights
        while i < lights + sol { act[i] = .bedWake; i += 1 }
        let onset = i
        let deepMin: [Double] = [34, 26, 14, 6, 2, 0, 0], remMin: [Double] = [8, 17, 24, 30, 34, 34, 34]
        var c = 0
        let lastSleep = out - 6
        func fill(_ s: SleepStage, _ minutes: Double) {
            var k = Int(max(minutes, 0) * 2)
            while k > 0 && i < lastSleep { stage[i] = s; act[i] = .sleep; i += 1; k -= 1 }
        }
        while i < lastSleep {
            let k = min(c, deepMin.count - 1)
            fill(.light, rng.uniform(12, 20))
            fill(.deep, deepMin[k] * rng.uniform(0.85, 1.15))
            fill(.light, rng.uniform(14, 24))
            fill(.rem, remMin[k] * rng.uniform(0.85, 1.15))
            if rng.uniform() < 0.55 && i < lastSleep - 40 {                       // breve risveglio tra i cicli
                var w = 2 + Int(rng.uniform(0, 5))
                while w > 0 && i < lastSleep { stage[i] = .wake; act[i] = .bedWake; i += 1; w -= 1 }
            }
            c += 1
        }
        let wakeIdx = i
        while i < out { act[i] = .bedWake; i += 1 }

        // ── giorno: camminate, allenamento, sonnellino ──
        func mark(_ a: Act, fromH: Double, minutes: Double) {
            let s = idx(fromH)
            for k in s..<min(s + Int(minutes * 2), n) where act[k] == .sedentary { act[k] = a }
        }
        let wakeH = Double(wakeIdx) / 120 - 6
        let walkTotal = max(o.steps - 400 - (o.workout ? 6640 : 0), 0) / 110                             // minuti di cammino a ~110 passi/min
        let shares: [(Double, Double)] = [(wakeH + 1.2, 0.30), (12.6, 0.25), (15.5, 0.15), (17.4, 0.30)]
        for (h, f) in shares { mark(.walk, fromH: h + rng.uniform(-0.2, 0.2), minutes: walkTotal * f) }
        if o.workout { mark(.run, fromH: 18.5, minutes: 40) }
        var napRange: Range<Int>?
        if o.nap {
            let s = idx(14.0), e = s + 80
            for k in s..<e { stage[k] = .light; act[k] = .sleep }
            napRange = s..<e
        }

        // ── segnali ──
        let hrMax = HeartRate.tanaka(age: profile.age)
        var epochs: [Epoch] = []; epochs.reserveCapacity(n)
        var hr = o.rhr + 18, stepsTotal = 0.0
        var hrTrace = [Double](repeating: 0, count: n)
        let nightLen = Double(max(wakeIdx - onset, 1))
        for k in 0..<n {
            let inNight = k >= onset && k < wakeIdx
            let f = inNight ? Double(k - onset) / nightLen : 0
            // andamento "ad amaca" della FC notturna: scende fino a metà notte, risale poco prima del risveglio
            let hammock = inNight ? 6 * pow(1 - min(f / 0.55, 1), 2) + 2.5 * pow(max(f - 0.75, 0) / 0.25, 2) : 0
            var target: Double, sigma: Double, motion: Double, angle: Double, steps = 0.0
            switch act[k] {
            case .sleep:
                let twitchP: Double
                switch stage[k] {
                case .deep: target = o.rhr + hammock; sigma = 0.4; twitchP = 0.004
                case .rem: target = o.rhr + 5 + hammock + 2.5 * sin(Double(k) / 7); sigma = 1.6; twitchP = 0.02
                default: target = o.rhr + 2 + hammock; sigma = 0.7; twitchP = 0.03
                }
                if napRange?.contains(k) == true { target += 5 }
                let shift = k > 0 && stage[k] != stage[k - 1]
                if rng.uniform() < twitchP || (shift && rng.uniform() < 0.6) {
                    motion = rng.uniform(25, 90); angle = rng.uniform(8, 50)
                } else { motion = 1.5 + abs(rng.normal()) * 0.8; angle = abs(rng.normal()) * 0.7 }
            case .bedWake:
                target = o.rhr + 10 + hammock; sigma = 1.8
                motion = rng.uniform() < 0.75 ? rng.uniform(20, 110) : rng.uniform(3, 10)
                angle = rng.uniform() < 0.7 ? rng.uniform(6, 45) : rng.uniform(0, 3)
            case .sedentary:
                target = o.rhr + 17 + o.dayHROffset + 4 * sin(Double(k) / 240); sigma = 1.5
                motion = exp(rng.normal() * 0.6 + 3.0); angle = rng.uniform(2, 35)
                if rng.uniform() < 0.06 { steps = Double(Int(rng.uniform(2, 14))) }
            case .walk:
                target = o.rhr + 46 + o.dayHROffset; sigma = 2
                motion = rng.uniform(190, 340); angle = rng.uniform(15, 60); steps = (110 + rng.normal() * 4) / 2
            case .run:
                target = 0.84 * hrMax; sigma = 2
                motion = rng.uniform(550, 900); angle = rng.uniform(20, 70); steps = (166 + rng.normal() * 3) / 2
            }
            let rate = act[k] == .run || act[k] == .walk ? 0.22 : 0.3
            hr += rate * (target - hr) + sigma * rng.normal() * 0.5
            hr = Stats.clamp(hr, 38, hrMax)
            hrTrace[k] = hr
            if k >= 720 && k < 3600 { stepsTotal += steps }
            epochs.append(Epoch(start: start.addingTimeInterval(Double(k) * ep), hr: hr, motion: motion, angleChange: angle, steps: steps))
        }

        // ── battiti: aritmia sinusale respiratoria più ampia nel sonno profondo, ridotta in REM e in veglia ──
        var series: [IBISeries] = []
        if o.beats {
            let amp0 = o.rmssd / 1050 / 1.05
            var t = 0.0, phase = 0.0
            var times: [Double] = [], seriesStart = 0.0
            func close() {
                if times.count > 30 { series.append(IBISeries(start: start.addingTimeInterval(seriesStart), beatTimes: times)) }
                times.removeAll(keepingCapacity: true)
            }
            let total = Double(n) * ep
            while t < total {
                let k = min(Int(t / ep), n - 1)
                if act[k] == .walk || act[k] == .run { close(); t = Double(k + 1) * ep; continue }   // movimento: nessun battito affidabile
                if times.isEmpty { seriesStart = t; times.append(0) }
                let mult: Double
                switch (act[k], stage[k]) {
                case (.sleep, .deep): mult = 1.25
                case (.sleep, .rem): mult = 0.65
                case (.sleep, _): mult = 1.0
                case (.bedWake, _): mult = 0.55
                default: mult = 0.8
                }
                let base = 60 / hrTrace[k]
                let f = (o.respRate + (stage[k] == .rem ? 1.2 * sin(t / 37) : 0.3 * sin(t / 90))) / 60
                phase += 2 * Double.pi * f * base
                // onde lente (≈ 0,08 Hz, barocettive): allargano la distribuzione degli intervalli senza toccare molto l'RMSSD
                let lf = (act[k] == .sleep ? (stage[k] == .deep ? 0.008 : 0.018) : 0.028) * sin(2 * Double.pi * 0.08 * t + 1.3 * sin(t / 53))
                let ibi = base * (1 + amp0 * mult * sin(phase) + lf) + 0.004 * rng.normal()
                t += max(ibi, 0.3)
                times.append(t - seriesStart)
            }
            close()
        }

        // ── temperatura cutanea: transitorio iniziale, minimo circa 2 ore prima del risveglio ──
        var temp: [TimedValue] = []
        if o.tempSeries {
            let tMin = Double(wakeIdx) * ep - 2 * 3600
            var s = Double(lights) * ep
            while s < Double(out) * ep {
                let warm = -1.0 * exp(-(s - Double(lights) * ep) / 600)
                let dip = -0.45 * exp(-pow((s - tMin) / 5400, 2))
                temp.append(TimedValue(date: start.addingTimeInterval(s), value: 35.0 + o.tempOffset + warm + dip + 0.03 * rng.normal()))
                s += 120
            }
        }

        var input = DayInput(day: day, calendar: calendar, now: start.addingTimeInterval(Double(n) * ep), epochs: epochs)
        input.ibiSeries = series
        input.skinTempSeries = temp
        input.daylightMin = 45

        // ── stadi "Apple": verità con errori a blocchi ──
        if o.appleStages {
            var seg: [SleepSegment] = []
            var k = lights
            while k < out {
                var j = k
                while j < out && stage[j] == stage[k] && j - k < 20 { j += 1 }
                var s = stage[k]
                if rng.uniform() < 0.2 {
                    switch s {
                    case .deep, .rem: s = .light
                    case .light: s = rng.uniform() < 0.5 ? .deep : .rem
                    case .wake: s = .light
                    }
                }
                seg.append(SleepSegment(start: start.addingTimeInterval(Double(k) * ep), end: start.addingTimeInterval(Double(j) * ep), stage: s))
                for q in k..<j { input.epochs[q].appleStage = s }
                k = j
            }
            input.appleSleep = seg
        }
        return Day(input: input, truth: stage, lightsOut: start.addingTimeInterval(Double(lights) * ep),
                   onset: start.addingTimeInterval(Double(onset) * ep), wake: start.addingTimeInterval(Double(wakeIdx) * ep), steps: stepsTotal)
    }

    /// Opzioni variate di giorno in giorno: orari più tardi nel fine settimana (social jetlag), piccole oscillazioni di FC e HRV
    public static func options(for day: Date, calendar: Calendar, seed: UInt64) -> Options {
        let d = Int((day.timeIntervalSince1970 / 86_400).rounded())
        var rng = SeededRNG(seed: seed &+ UInt64(truncatingIfNeeded: d) &* 7919)
        var o = Options()
        o.seed = seed &+ UInt64(truncatingIfNeeded: d)
        let wd = calendar.component(.weekday, from: day)
        let free = wd == 1 || wd == 7                         // la notte termina di sabato o domenica
        o.bedH = 23.0 + (free ? 1.1 : 0) + rng.uniform(-0.25, 0.25)
        o.inBedH = (free ? 9.0 : 8.2) + rng.uniform(-0.25, 0.25)
        o.rhr = 54 + rng.normal() * 1.2
        o.rmssd = 55 * exp(rng.normal() * 0.07)
        o.steps = 8500 + rng.uniform(-2500, 3500)
        o.workout = d % 2 == 0
        return o
    }

    /// Storico di `days` giorni che terminano il giorno prima di `end`, elaborati in sequenza dalla pipeline
    public static func history(days: Int, before end: Date, calendar: Calendar = Synthetic.utc, profile: UserProfile, seed: UInt64 = 7) -> [DailyReport] {
        var h: [DailyReport] = []
        for k in stride(from: days, through: 1, by: -1) {
            guard let d = calendar.date(byAdding: .day, value: -k, to: end) else { continue }
            let s = day(d, calendar: calendar, profile: profile, options: options(for: d, calendar: calendar, seed: seed))
            h = History.upsert(DailyPipeline.run(s.input, profile: profile, history: h), into: h, calendar: calendar)
        }
        return h
    }
}
