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

/// Etichette del report. I valori 0–3 mantengono la codifica storica delle quattro fasi HMM.
public enum ReportedSleepStage: Int, Codable, CaseIterable, Sendable {
    case wake = 0, light, deep, rem, asleepUnspecified, unknown

    init(_ stage: SleepStage) { self = Self(rawValue: stage.rawValue) ?? .unknown }
    public var isSleep: Bool { self != .wake && self != .unknown }
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
    // Le epoche da campioni grezzi registrano esplicitamente la copertura.
    var hrObserved: Bool?
    var stepsObserved: Bool?
    var motionObserved: Bool?
    var observedHR: Double? { hrObserved == false ? nil : hr.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
    var hasSteps: Bool { stepsObserved ?? (steps > 0) }
    var hasMotion: Bool { motionObserved ?? (angleChange != nil || motion > 0) }
    var observedMotion: Double? { hasMotion && motion.isFinite && motion >= 0 ? motion : nil }

    public init(start: Date, hr: Double? = nil, motion: Double = 0, angleChange: Double? = nil, steps: Double = 0,
                appleStage: SleepStage? = nil, motionObserved: Bool? = nil) {
        self.start = start; self.hr = hr; self.motion = motion; self.angleChange = angleChange
        self.steps = steps; self.appleStage = appleStage
        self.motionObserved = motionObserved
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
    /// Identità del record alla sorgente, per esempio UUID di un campione HealthKit.
    public let sourceID: UUID?
    /// Identità dell'acquisizione, se nota a chi produce i frammenti. Un dispositivo comune non basta.
    public let streamID: UUID?
    public init(start: Date, beatTimes: [Double], precededByGap: [Bool]? = nil, sourceID: UUID? = nil, streamID: UUID? = nil) {
        self.start = start; self.beatTimes = beatTimes
        self.precededByGap = precededByGap ?? [Bool](repeating: false, count: beatTimes.count)
        self.sourceID = sourceID
        self.streamID = streamID
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
    /// nil identifica un intervallo a letto. `.unknown` identifica un'osservazione non classificabile.
    public let reportedStage: ReportedSleepStage?
    public let source: SleepSourceKey?
    public var stage: SleepStage? { reportedStage.flatMap { SleepStage(rawValue: $0.rawValue) } }
    public init(start: Date, end: Date, stage: SleepStage?, source: SleepSourceKey? = nil) {
        self.start = start; self.end = end; self.reportedStage = stage.map(ReportedSleepStage.init); self.source = source
    }
    public init(start: Date, end: Date, reportedStage: ReportedSleepStage, source: SleepSourceKey? = nil) {
        self.start = start; self.end = end; self.reportedStage = reportedStage; self.source = source
    }
}

/// Identità locale opaca e verificata dall'adattatore. Un UUID di campione da solo non identifica la sorgente.
public struct SleepSourceKey: Codable, Sendable, Hashable {
    public let fingerprint: Data
    public init?(fingerprint: Data) {
        guard fingerprint.count == 32 else { return nil }
        self.fingerprint = fingerprint
    }
}

public struct SleepSourceSample: Sendable {
    public let id: UUID
    public let segment: SleepSegment
    public init(id: UUID, segment: SleepSegment) { self.id = id; self.segment = segment }
}

public struct SleepProviderEvidence: Sendable {
    public let source: SleepSourceKey
    public let samples: [SleepSourceSample]
    public init(source: SleepSourceKey, samples: [SleepSourceSample]) { self.source = source; self.samples = samples }
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
    /// Identità del campione presso la sorgente. Assente nei report legacy e nelle rilevazioni locali.
    public var sourceID: UUID?
    /// Energia osservata nel workout. Uno zero esplicito è un valore valido.
    public var importedKcal: Double?
    public init(start: Date, end: Date, avgHR: Double, maxHR: Double, zoneMinutes: [Double], kcal: Double,
                autoDetected: Bool, activity: String = "altro", sourceID: UUID? = nil, importedKcal: Double? = nil) {
        self.start = start; self.end = end; self.avgHR = avgHR; self.maxHR = maxHR
        self.zoneMinutes = zoneMinutes; self.kcal = kcal; self.autoDetected = autoDetected; self.activity = activity
        self.sourceID = sourceID; self.importedKcal = importedKcal
    }
    public var minutes: Double { end.timeIntervalSince(start) / 60 }
    public var trimp: Double { HeartRate.trimp(zoneMinutes) }
}

public struct DateSpan: Codable, Sendable, Hashable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
    public var minutes: Double { end.timeIntervalSince(start) / 60 }
}

public struct SleepObservation: Codable, Sendable, Equatable {
    public let span: DateSpan
    public let asleep: Bool
    /// Vero soltanto per la veglia inferita dal segnale fuori dagli episodi noti. nil negli archivi precedenti.
    public let contextualWake: Bool?
    public init(span: DateSpan, asleep: Bool, contextualWake: Bool? = nil) {
        self.span = span; self.asleep = asleep; self.contextualWake = contextualWake
    }
}

struct EveningSleepRevision: Codable, Sendable, Hashable {
    let eveningDay: StressDayAxis
    let confirmedAt: Date
    /// Solo i tratti rivalutati. Le porzioni assenti da entrambi gli array restano invariate.
    let runs: [DateSpan]
    let awakeRuns: [DateSpan]
    var source: SleepSourceKey? = nil
    var nativeWakes: [EarlyWakeObservation]? = nil
    var hasClassification: Bool { !runs.isEmpty || !awakeRuns.isEmpty }
}

struct EarlyWakeObservation: Codable, Sendable, Hashable {
    let source: SleepSourceKey
    let sampleID: UUID
    let runs: [DateSpan]
}

struct RegularityAlignmentInputs: Codable, Sendable {
    let referenceMidH: Double?
    let daylightMin: Double?

    func score(midpoint: Double?, sri: Double?, socialJetlag: Double?) -> Double? {
        guard (midpoint != nil && referenceMidH != nil) || sri != nil || daylightMin != nil || socialJetlag != nil else { return nil }
        return Circadian.alignment(lastMidH: midpoint, referenceMidH: referenceMidH, sri: sri,
                                   daylightMin: daylightMin, sjlH: socialJetlag)
    }
}

public enum BedTimingOrigin: String, Codable, Sendable, Equatable {
    case inBedObservation, estimatedFromEpisode
}

public struct NightReport: Codable, Sendable {
    static let currentStageEncodingVersion = 1
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
    public internal(set) var bedTimingOrigin: BedTimingOrigin? = nil
    /// nil nei report storici, che riconoscono soltanto le quattro fasi 0–3.
    public internal(set) var stageEncodingVersion: Int? = nil

    func decodedStage(_ rawValue: Int) -> ReportedSleepStage {
        if let modeled = SleepStage(rawValue: rawValue) { return ReportedSleepStage(modeled) }
        guard stageEncodingVersion == Self.currentStageEncodingVersion else { return .unknown }
        return ReportedSleepStage(rawValue: rawValue) ?? .unknown
    }

    public var restorativeMin: Double { deepMin + remMin }
    public var restorativeShare: Double { tstMin > 0 ? restorativeMin / tstMin : 0 }
}

public struct StressDayAxis: Codable, Sendable, Hashable {
    public let start: Date
    public let end: Date
    public let timeZoneIdentifier: String
    public init(start: Date, end: Date, timeZoneIdentifier: String) {
        self.start = start; self.end = end; self.timeZoneIdentifier = timeZoneIdentifier
    }
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

public enum DailyMetricState: String, Codable, Sendable, Equatable {
    case observed, computed, estimated, unavailable, insufficient, calibrating, stale

    public var hasValue: Bool {
        self == .observed || self == .computed || self == .estimated
    }
}

/// Stato dei risultati derivati nel report. L'assenza della struttura identifica un report legacy.
public struct DailyEvidence: Codable, Sendable {
    public static let currentVersion = 1
    public var version = DailyEvidence.currentVersion
    public var rhr: DailyMetricState
    public var zones: DailyMetricState
    public var steps: DailyMetricState
    public var activity: DailyMetricState
    public var energyActive: DailyMetricState
    public var energyTotal: DailyMetricState
    public var trimp: DailyMetricState
    public var movement: DailyMetricState
    public var stress: DailyMetricState
    public var rhythm: DailyMetricState
    public var recovery: DailyMetricState
    public var alignment: DailyMetricState
    public var tempMinimum: DailyMetricState
    public var fitness: DailyMetricState
    public var baselineReady: Bool
}

public struct ReportSectorFreshness: Codable, Sendable {
    public internal(set) var nightAt: Date?
    public internal(set) var daytimePulseAt: Date?
    public internal(set) var activeEnergyAt: Date?
    public internal(set) var totalEnergyAt: Date?
    public internal(set) var nightPreserved = false
}

struct NightReadProof: Codable, Sendable, Hashable {
    let closed: Bool
    let source: SleepSourceKey?
    let explicitWake: [DateSpan]
}

struct ArchivedNight: Codable, Sendable {
    let at: Date?
    let night: NightReport
    let proof: NightReadProof?
    let naps: [DateSpan]
    let napsMin: Double
    let total: Double?
    let debt: Double
    let consistency: Double?
    let rhr: Double
    let rhrState: DailyMetricState
    let observations: [SleepObservation]?
    let alignmentInputs: RegularityAlignmentInputs?

    init?(_ report: DailyReport) {
        guard let night = report.night else { return nil }
        at = report.sectorFreshness?.nightPreserved == true ? report.sectorFreshness?.nightAt
            : (report.sectorFreshness?.nightAt ?? report.computedAt)
        self.night = night; proof = report.nightReadProof
        naps = report.naps; napsMin = report.napsMin; total = report.dailySleepMin
        debt = report.sleepDebtH; consistency = report.sleepConsistency
        rhr = report.rhr; rhrState = report.state(\.rhr)
        observations = report.originalSleepObservations
        alignmentInputs = report.regularityAlignmentInputs
    }
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
    public var stressTimeline: [Double?]         // finestre di 5 min trascorsi nel giorno civile
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
    /// notti valide nella baseline
    public var baselineNights: Int
    public internal(set) var evidence: DailyEvidence? = nil
    /// Istante di acquisizione del report, usato per scegliere una revisione dello stesso giorno.
    public internal(set) var computedAt: Date? = nil
    /// Tratti classificati; i buchi sono ignoti. nil nei report antecedenti al contratto di osservabilità.
    public internal(set) var sleepObservations: [SleepObservation]? = nil
    /// Presente soltanto se il report materializza una correzione. I tratti originali restano immutati.
    var sleepObservationsBeforeReconciliation: [SleepObservation]? = nil
    var originalSleepObservations: [SleepObservation]? { sleepObservationsBeforeReconciliation ?? sleepObservations }
    public internal(set) var stressAxis: StressDayAxis? = nil
    var eveningSleepRevisions: [EveningSleepRevision]? = nil
    var regularityAlignmentInputs: RegularityAlignmentInputs? = nil
    /// Istante del riesame retroattivo del solo SRI e del relativo allineamento.
    public internal(set) var sriReconciledAt: Date? = nil
    public internal(set) var sriNeedsProvenance: Bool? = nil
    public internal(set) var sectorFreshness: ReportSectorFreshness? = nil
    var nightReadProof: NightReadProof? = nil
    var archivedNightVariants: [ArchivedNight]? = nil
    /// Minuti civili trascorsi. 0 = assente, 1 = sotto Z1, 2...6 = zone 1...5, 7 = osservato senza zona verificabile.
    var pulseZoneCells: Data? = nil
    public var calibrating: Bool { state(\.recovery) == .stale || evidence?.baselineReady != true }

    public func state(_ metric: KeyPath<DailyEvidence, DailyMetricState>) -> DailyMetricState {
        if metric == \DailyEvidence.alignment, sriNeedsProvenance == true { return .stale }
        guard let evidence, evidence.version == DailyEvidence.currentVersion else { return .stale }
        return evidence[keyPath: metric]
    }
}
