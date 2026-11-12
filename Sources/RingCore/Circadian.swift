import Foundation

public enum Circadian {
    public struct Jetlag: Sendable {
        /// punto medio del sonno nei giorni lavorativi e liberi (ore decimali)
        public var msw: Double, msf: Double
        /// social jetlag = |MSF - MSW|
        public var sjl: Double
        /// versione corretta per il debito di sonno (Jankowski 2017)
        public var sjlSc: Double
        /// cronotipo: punto medio nei giorni liberi corretto per il recupero di sonno (MSFsc)
        public var msfSc: Double
    }

    /// Social jetlag (Roenneberg, questionario MCTQ) ricavato dai dati misurati.
    /// La notte "lavorativa" è quella che termina in un giorno lavorativo.
    /// MSFsc = MSF - (SDf - SDsettimana) / 2 se nei giorni liberi si dorme di più.
    /// SJLsc: differenza degli orari di addormentamento se SDf > SDw, altrimenti dei risvegli.
    public static func socialJetlag(_ nights: [(date: Date, night: NightReport)], workdays: Set<Int>, calendar: Calendar) -> Jetlag? {
        var w: [NightReport] = [], f: [NightReport] = []
        for r in nights {
            if workdays.contains(calendar.component(.weekday, from: r.date)) { w.append(r.night) } else { f.append(r.night) }
        }
        guard w.count >= 3, f.count >= 2 else { return nil }
        let msw = Stats.circularMeanHours(w.map { $0.midpointH }), msf = Stats.circularMeanHours(f.map { $0.midpointH })
        let sdw = Stats.mean(w.map { $0.tstMin / 60 }), sdf = Stats.mean(f.map { $0.tstMin / 60 })
        let nw = Double(workdays.count), sdWeek = (nw * sdw + (7 - nw) * sdf) / 7
        let msfsc = sdf > sdw ? msf - (sdf - sdWeek) / 2 : msf
        let sjlsc = sdf > sdw
            ? abs(Stats.circDiff(Stats.circularMeanHours(f.map { $0.onsetH }), Stats.circularMeanHours(w.map { $0.onsetH })))
            : abs(Stats.circDiff(Stats.circularMeanHours(f.map { $0.wakeH }), Stats.circularMeanHours(w.map { $0.wakeH })))
        return Jetlag(msw: msw, msf: msf, sjl: abs(Stats.circDiff(msf, msw)), sjlSc: sjlsc, msfSc: Stats.wrap24(msfsc))
    }

    /// Allineamento circadiano 0-100: fase (sonno dell'ultima notte rispetto al proprio cronotipo o al centro
    /// abituale), regolarità (SRI), luce diurna, social jetlag. Una componente mancante vale 0,7 (neutra).
    public static func alignment(lastMidH: Double?, referenceMidH: Double?, sri: Double?, daylightMin: Double?, sjlH: Double?)
        -> Double {
        var s = 0.0, w = 0.0
        if let m = lastMidH, let r = referenceMidH { s += 0.40 * (1 - Stats.scale(abs(Stats.circDiff(m, r)), 0.5, 3.0)); w += 0.40 }
        if let x = sri { s += 0.35 * Stats.scale(x, 40, 90); w += 0.35 }
        if let d = daylightMin { s += 0.15 * Stats.scale(d, 10, 90); w += 0.15 }
        if let j = sjlH { s += 0.10 * (1 - Stats.scale(j, 0.5, 2.5)); w += 0.10 }
        return 100 * (s + 0.7 * (1 - w))
    }

    /// Finestre della giornata ancorate al minimo di temperatura (Tmin), come nel PowerPlug "Circadian Alignment":
    /// zona del minimo (30 min attorno a Tmin), avanzamento di fase (dopo Tmin), zona morta (di giorno),
    /// ritardo di fase (da 8 a 4 ore prima di Tmin). Le durate di avanzamento e zona morta non sono pubblicate:
    /// qui 4 ore di avanzamento, il resto zona morta. In coda i consigli pratici (euristiche note di igiene del sonno).
    public static func windows(tMinH: Double, wakeH: Double, bedH: Double) -> [CircadianWindow] {
        func after(_ h: Double, _ ref: Double) -> Double { var x = Stats.wrap24(h); while x < ref { x += 24 }; return x }
        let t = Stats.wrap24(tMinH)
        let wake = after(wakeH, t)                       // risveglio successivo al minimo
        let bed = after(bedH, wake)                      // sera dello stesso giorno
        let delayStart = after(t - 8, wake), delayEnd = delayStart + 4
        let advEnd = t + 4.25
        let peak = Stats.clamp(t + 13, wake + 6, bed - 4)   // prestazione fisica migliore nel tardo pomeriggio
        return [
            CircadianWindow(name: "Zona del minimo", startH: t - 0.25, endH: t + 0.25,
                            hint: "Buio e quiete: luce e movimento qui frammentano il sonno."),
            CircadianWindow(name: "Avanzamento di fase", startH: t + 0.25, endH: advEnd,
                            hint: "Luce del mattino e movimento leggero anticipano l'orologio biologico."),
            CircadianWindow(name: "Zona morta circadiana", startH: advEnd, endH: max(delayStart, advEnd),
                            hint: "Luce, caffeina e sonnellini spostano poco l'orologio."),
            CircadianWindow(name: "Ritardo di fase", startH: delayStart, endH: delayEnd,
                            hint: "Luce intensa, schermi, pasti abbondanti e allenamenti qui ritardano il sonno."),
            CircadianWindow(name: "Luce", startH: wake, endH: wake + 1,
                            hint: "Luce naturale entro un'ora dal risveglio."),
            CircadianWindow(name: "Caffeina", startH: wake + 1.5, endH: max(wake + 1.5, min(bed - 10, wake + 8)),
                            hint: "Ultimo caffè almeno 10 ore prima di dormire (emivita ≈ 5 ore)."),
            CircadianWindow(name: "Allenamento", startH: peak - 1.5, endH: min(peak + 1.5, bed - 3),
                            hint: "Finestra di massima prestazione; allenamenti intensi non oltre 3 ore prima di dormire."),
            CircadianWindow(name: "Ultimo pasto", startH: bed - 4, endH: bed - 3,
                            hint: "Cena conclusa almeno 3 ore prima di dormire."),
            CircadianWindow(name: "Rallentamento", startH: bed - 1, endH: bed,
                            hint: "Luci basse, niente schermi, routine di rilassamento."),
        ]
    }
}
