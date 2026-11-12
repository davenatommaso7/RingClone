import Foundation

public enum RingConst {
    /// Unità di analisi: 30 s (standard AASM per lo scoring del sonno)
    public static let epoch: TimeInterval = 30
    public static let epochsPerDay = 2880
}

public enum Sex: String, Codable, Sendable, CaseIterable { case male, female }

public enum SleepStage: Int, Codable, CaseIterable, Sendable {
    case wake = 0, light, deep, rem
    public var isSleep: Bool { self != .wake }
}

/// Modello delle zone di frequenza cardiaca.
/// `.percentMax` = 50-60-70-80-90-100 % della FC massima (quello descritto da Ultrahuman, HRmax di Tanaka);
/// `.karvonen`   = stesse bande ma sulla riserva cardiaca (HRR), più personale se la FC a riposo è nota.
public enum ZoneModel: String, Codable, Sendable, CaseIterable { case percentMax, karvonen }

public struct UserProfile: Codable, Sendable, Equatable {
    public var age: Double
    public var sex: Sex
    public var heightCm: Double
    public var weightKg: Double
    public var sleepNeedH: Double
    /// Calendar.weekday dei giorni lavorativi (1 = domenica)
    public var workdays: Set<Int>
    public var stepGoal: Double
    public var zoneModel: ZoneModel
    /// FC massima misurata (test da campo/laboratorio): se presente ha la precedenza
    public var hrMaxOverride: Double?
    /// VO2max di laboratorio (ml/kg/min): se presente entra nella fusione con errore piccolo
    public var labVO2max: Double?

    public init(age: Double, sex: Sex, heightCm: Double, weightKg: Double, sleepNeedH: Double = 8.0,
                workdays: Set<Int> = [2, 3, 4, 5, 6], stepGoal: Double = 10_000, zoneModel: ZoneModel = .percentMax,
                hrMaxOverride: Double? = nil, labVO2max: Double? = nil) {
        self.age = age; self.sex = sex; self.heightCm = heightCm; self.weightKg = weightKg
        self.sleepNeedH = sleepNeedH; self.workdays = workdays; self.stepGoal = stepGoal; self.zoneModel = zoneModel
        self.hrMaxOverride = hrMaxOverride; self.labVO2max = labVO2max
    }
    public var bmi: Double { weightKg / pow(heightCm / 100, 2) }
    /// Lunghezza del passo stimata (m): 0.415 x statura
    public var stepLengthM: Double { 0.415 * heightCm / 100 }
}

/// Epoca di 30 s sulla griglia allineata al tempo Unix (indice = floor(unix / 30))
public struct Epoch: Sendable {
    public var start: Date
    /// bpm (interpolata dai campioni; nil = dato mancante / orologio non indossato)
    public var hr: Double?
    /// intensità del movimento nell'epoca in milli-g (metrica MAD, vedi `MotionEpoch.counts`; ≈ 0 = fermo)
    public var motion: Double
    /// massima variazione dell'angolo del braccio tra finestre di 5 s (gradi); nil se non disponibile
    public var angleChange: Double?
    public var steps: Double
    /// stadio di una sorgente esterna (Apple Salute): osservazione aggiuntiva per l'HMM
    public var appleStage: SleepStage?

    public init(start: Date, hr: Double? = nil, motion: Double = 0, angleChange: Double? = nil, steps: Double = 0,
                appleStage: SleepStage? = nil) {
        self.start = start; self.hr = hr; self.motion = motion; self.angleChange = angleChange
        self.steps = steps; self.appleStage = appleStage
    }
}

public struct TimedValue: Codable, Sendable, Equatable {
    public let date: Date
    public let value: Double
    public init(date: Date, value: Double) { self.date = date; self.value = value }
}

/// Serie battito-battito. `beatTimes` = istanti dei battiti in secondi da `start`;
/// `precededByGap[k]` = true se tra il battito k-1 e k il sensore ha perso il segnale (intervallo non valido).
public struct IBISeries: Sendable {
    public let start: Date
    public let beatTimes: [Double]
    public let precededByGap: [Bool]
    public init(start: Date, beatTimes: [Double], precededByGap: [Bool]? = nil) {
        self.start = start; self.beatTimes = beatTimes
        self.precededByGap = precededByGap ?? [Bool](repeating: false, count: beatTimes.count)
    }
    /// Costruisce la serie da una lista di intervalli (ms) contigui
    public init(start: Date, ibiMs: [Double]) {
        var t = 0.0, times = [0.0]
        for x in ibiMs { t += x / 1000; times.append(t) }
        self.init(start: start, beatTimes: times)
    }
}

/// Intervallo di sonno rilevato da una sorgente esterna (HealthKit sleepAnalysis)
public struct SleepSegment: Sendable {
    public let start: Date, end: Date
    /// nil = "a letto" senza stadio
    public let stage: SleepStage?
    public init(start: Date, end: Date, stage: SleepStage?) { self.start = start; self.end = end; self.stage = stage }
}

public struct WorkoutRecord: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var avgHR: Double
    public var maxHR: Double
    /// minuti in Z1...Z5
    public var zoneMinutes: [Double]
    /// kcal attive
    public var kcal: Double
    public var autoDetected: Bool
    public var activity: String
    public init(start: Date, end: Date, avgHR: Double, maxHR: Double, zoneMinutes: [Double], kcal: Double,
                autoDetected: Bool, activity: String = "altro") {
        self.start = start; self.end = end; self.avgHR = avgHR; self.maxHR = maxHR
        self.zoneMinutes = zoneMinutes; self.kcal = kcal; self.autoDetected = autoDetected; self.activity = activity
    }
    public var minutes: Double { end.timeIntervalSince(start) / 60 }
    public var trimp: Double { HeartRate.trimp(zoneMinutes) }
}

public struct DateSpan: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
    public var minutes: Double { end.timeIntervalSince(start) / 60 }
}

public struct NightReport: Codable, Sendable {
    public var inBed: Date
    public var sleepOnset: Date
    public var finalWake: Date
    public var outOfBed: Date
    // durate (min) e continuità
    public var tibMin: Double
    public var tstMin: Double
    public var solMin: Double
    public var wasoMin: Double
    public var efficiency: Double
    public var awakenings: Int
    public var longestBoutMin: Double
    public var fragmentationIdx: Double
    public var movements: Int
    public var cycles: Int
    // architettura
    public var lightMin: Double
    public var deepMin: Double
    public var remMin: Double
    public var remLatencyMin: Double?
    // orari (ore locali decimali)
    public var midpointH: Double
    public var onsetH: Double
    public var wakeH: Double
    // parametri vitali notturni
    public var rhr: Double?
    public var avgHR: Double?
    public var hrNadirFrac: Double?
    public var rmssd: Double?
    public var sdnn: Double?
    public var respRate: Double?
    public var spo2: Double?
    /// temperatura cutanea notturna assoluta (°C) e scostamento dalla baseline personale
    public var skinTemp: Double?
    public var skinTempDev: Double?
    /// istante del minimo di temperatura cutanea (solo con serie di temperatura)
    public var tempMinH: Double?
    /// ipnogramma (SleepStage.rawValue per epoca da `inBed`) e tratti di sonno effettivo (per la regolarità)
    public var stages: [Int]
    public var sleepRuns: [DateSpan]
    public var sleepIndex: Double
    public var sleepIndexParts: [String: Double]

    public var restorativeMin: Double { deepMin + remMin }
    public var restorativeShare: Double { tstMin > 0 ? restorativeMin / tstMin : 0 }
}

public struct CircadianWindow: Codable, Sendable, Equatable {
    public var name: String
    /// ore locali decimali; `end` può superare 24 (finestra a cavallo di mezzanotte)
    public var startH: Double
    public var endH: Double
    public var hint: String
    public init(name: String, startH: Double, endH: Double, hint: String) {
        self.name = name; self.startH = startH; self.endH = endH; self.hint = hint
    }
    public static func clock(_ h: Double) -> String {
        let x = ((h.truncatingRemainder(dividingBy: 24)) + 24).truncatingRemainder(dividingBy: 24)
        let total = Int((x * 60).rounded()) % 1440
        let hh = total / 60, mm = total % 60
        return (hh < 10 ? "0" : "") + "\(hh):" + (mm < 10 ? "0" : "") + "\(mm)"
    }
    public var label: String { "\(Self.clock(startH))–\(Self.clock(endH))" }
}

public struct DailyReport: Codable, Sendable, Identifiable {
    /// inizio del giorno di calendario locale
    public var date: Date
    public var id: Date { date }
    public var night: NightReport?
    public var naps: [DateSpan]
    public var napsMin: Double
    /// sonno totale del giorno (notte + sonnellini); nil se la notte non è stata registrata
    public var dailySleepMin: Double?
    public var sleepDebtH: Double
    public var sri: Double?
    public var sleepConsistency: Double?
    // cuore
    public var rhr: Double
    public var hrMax: Double
    public var hrMaxMeasured: Bool
    public var zoneBounds: [Double]              // 6 limiti: Z1 basso ... Z5 alto
    public var zoneMinutesDay: [Double]          // minuti del giorno in Z1...Z5
    // attività
    public var steps: Double
    public var activeHours: Int
    public var activeMinutes: Double
    public var inactiveMin: Double
    public var longestSedentaryMin: Double
    public var workouts: [WorkoutRecord]
    public var trimp: Double
    public var kcalTotal: Double
    public var kcalActive: Double
    public var movementIndex: Double
    public var movementParts: [String: Double]
    // stress e recupero
    public var stressTimeline: [Double?]         // 288 finestre da 5 min sul giorno di calendario
    public var stressAvg: Double?
    public var stressRhythm: Double
    public var recovery: Double
    public var recoveryLabel: String
    public var recoveryParts: [String: Double]
    public var flags: [String]
    // ritmo circadiano
    public var circadianAlignment: Double
    public var socialJetlagH: Double?
    public var socialJetlagScH: Double?
    public var chronotypeMSFsc: Double?
    public var tempMinH: Double
    public var windows: [CircadianWindow]
    // fitness
    public var vo2max: Double
    public var vo2Source: String
    public var cardioAgeRaw: Double
    public var cardioAge: Double
    /// notti valide nella baseline (sotto 7 = calibrazione: i confronti con la baseline sono neutri)
    public var baselineNights: Int
    public var calibrating: Bool { baselineNights < 7 }
}
