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
    private struct NativeWakeIdentity: Hashable {
        let evening: StressDayAxis
        let source: SleepSourceKey
        let id: UUID

        init(_ wake: EarlyWakeObservation, evening: StressDayAxis) {
            self.evening = evening; source = wake.source; id = wake.sampleID
        }
    }

    /// Giorno civile nel calendario del report. Vince la revisione acquisita più tardi.
    /// In assenza di precedenza temporale, l'ordine dei byte canonici rompe il pareggio.
    static func onePerDay(_ history: [DailyReport], calendar: Calendar) -> [DailyReport] {
        var days: [Date: DailyReport] = [:]
        var revisions: [Date: [EveningSleepRevision]] = [:]
        for report in history {
            let day = calendar.startOfDay(for: report.date)
            if report.eveningSleepRevisions != nil { revisions[day, default: []] += attachedEveningRevisions(report) }
            if let old = days[day] {
                let oldTime = old.computedAt ?? .distantPast, newTime = report.computedAt ?? .distantPast
                if oldTime > newTime { continue }
                if oldTime == newTime {
                    guard let a = try? reportKey(old), let b = try? reportKey(report) else { continue }
                    if a == b {
                        guard (old.sriReconciledAt ?? .distantPast) < (report.sriReconciledAt ?? .distantPast) else { continue }
                    } else if !a.lexicographicallyPrecedes(b) { continue }
                }
            }
            days[day] = report
        }
        let firstWake = firstWakeTimes(revisions.values.flatMap { $0 })
        let normalized = revisions.mapValues { $0.compactMap { keepingFirstWake(in: $0, firstWake: firstWake) } }
        let storedWithPredecessor = Set(normalized.flatMap { day, entries in
            entries.filter { $0.eveningDay.start == day && !$0.hasClassification }
        })
        return days.map { day, candidate in
            var report = candidate
            let entries = mergeEveningRevisions((normalized[day] ?? []).filter { revision in
                isAttached(revision, to: candidate.date) &&
                    (revision.eveningDay.start == candidate.date || !storedWithPredecessor.contains(revision))
            })
            report.eveningSleepRevisions = entries.isEmpty ? nil : entries
            return report
        }.sorted { $0.date < $1.date }
    }

    private static func isAttached(_ revision: EveningSleepRevision, to date: Date) -> Bool {
        revision.confirmedAt >= revision.eveningDay.end &&
            (revision.eveningDay.end == date || (revision.eveningDay.start == date && !revision.hasClassification))
    }

    private static func attachedEveningRevisions(_ report: DailyReport) -> [EveningSleepRevision] {
        (report.eveningSleepRevisions ?? []).filter { isAttached($0, to: report.date) }
    }

    private static func firstWakeTimes(_ revisions: [EveningSleepRevision]) -> [NativeWakeIdentity: Date] {
        var result: [NativeWakeIdentity: Date] = [:]
        for revision in revisions {
            for wake in revision.nativeWakes ?? [] {
                let identity = NativeWakeIdentity(wake, evening: revision.eveningDay)
                result[identity] = min(result[identity] ?? revision.confirmedAt, revision.confirmedAt)
            }
        }
        return result
    }

    private static func keepingFirstWake(in revision: EveningSleepRevision,
                                         firstWake: [NativeWakeIdentity: Date]) -> EveningSleepRevision? {
        guard let wakes = revision.nativeWakes else { return revision }
        let earliest = wakes.filter { firstWake[NativeWakeIdentity($0, evening: revision.eveningDay)] == revision.confirmedAt }
        if earliest.isEmpty && !revision.hasClassification { return nil }
        var normalized = revision
        normalized.nativeWakes = earliest.isEmpty ? nil : earliest
        return normalized
    }

    /// La rettifica dei valori derivati non cambia l'identità della revisione del report.
    private static func reportKey(_ report: DailyReport) throws -> Data {
        var source = report
        source.sri = nil
        source.circadianAlignment = .nan
        source.evidence?.alignment = .insufficient
        source.sriReconciledAt = nil
        source.sriNeedsProvenance = nil
        source.eveningSleepRevisions = nil
        source.archivedNightVariants = nil
        source.sleepObservations = report.originalSleepObservations
        source.sleepObservationsBeforeReconciliation = nil
        return try encode([source])
    }

    static func mergeEveningRevisions(_ revisions: [EveningSleepRevision]) -> [EveningSleepRevision] {
        let firstWake = firstWakeTimes(revisions)
        let normalized = revisions.compactMap { keepingFirstWake(in: $0, firstWake: firstWake) }
        return Set(normalized).sorted { a, b in
            if a.confirmedAt != b.confirmedAt { return a.confirmedAt < b.confirmedAt }
            let scopeA = (a.eveningDay.start, a.eveningDay.end, a.eveningDay.timeZoneIdentifier)
            let scopeB = (b.eveningDay.start, b.eveningDay.end, b.eveningDay.timeZoneIdentifier)
            if scopeA != scopeB { return scopeA < scopeB }
            if a.runs != b.runs {
                return a.runs.lexicographicallyPrecedes(b.runs) { ($0.start, $0.end) < ($1.start, $1.end) }
            }
            if a.awakeRuns != b.awakeRuns {
                return a.awakeRuns.lexicographicallyPrecedes(b.awakeRuns) { ($0.start, $0.end) < ($1.start, $1.end) }
            }
            guard let lhs = try? encoder().encode(a), let rhs = try? encoder().encode(b) else { return false }
            return lhs.lexicographicallyPrecedes(rhs)
        }
    }

    static func eveningRevisions(in history: [DailyReport], successor: Date) -> [EveningSleepRevision] {
        mergeEveningRevisions(history.flatMap(attachedEveningRevisions).filter { $0.eveningDay.end == successor })
    }

    static func visibleEveningRevisions(_ revisions: [EveningSleepRevision], target: StressDayAxis,
                                        visibleAt: Date) -> [EveningSleepRevision] {
        let eligible = mergeEveningRevisions(revisions.filter { $0.eveningDay == target && $0.confirmedAt <= visibleAt })
        let byTime = Dictionary(grouping: eligible, by: \.confirmedAt)
        // Una collisione allo stesso istante non è una conferma di quale versione sia corretta.
        return byTime.keys.sorted().compactMap { time in
            guard let proposals = byTime[time], proposals.count == 1 else { return nil }
            return proposals.first
        }
    }

    static func effectiveSleepObservations(_ original: [SleepObservation], target: StressDayAxis,
                                           revisions: [EveningSleepRevision], visibleAt: Date) -> [SleepObservation] {
        let visible = visibleEveningRevisions(revisions, target: target, visibleAt: visibleAt)
        let runs = eveningSleepRuns(after: visible)
        guard !runs.isEmpty else { return original }
        return original.flatMap { observation -> [SleepObservation] in
            guard !observation.asleep, observation.contextualWake == true else { return [observation] }
            var cursor = observation.span.start
            var parts: [SleepObservation] = []
            for run in runs {
                let start = max(cursor, run.start, target.start)
                let end = min(observation.span.end, run.end, target.end)
                guard end > start else { continue }
                if start > cursor {
                    parts.append(SleepObservation(span: DateSpan(start: cursor, end: start), asleep: false, contextualWake: true))
                }
                parts.append(SleepObservation(span: DateSpan(start: start, end: end), asleep: true))
                cursor = end
            }
            if cursor < observation.span.end {
                parts.append(SleepObservation(span: DateSpan(start: cursor, end: observation.span.end), asleep: false,
                                              contextualWake: true))
            }
            return parts
        }
    }

    private static func eveningSleepRuns(after revisions: [EveningSleepRevision]) -> [DateSpan] {
        struct OwnedSpan {
            let span: DateSpan
            let source: SleepSourceKey?
        }
        var sleep: [OwnedSpan] = []
        var observedWake = Set<NativeWakeIdentity>()
        func subtract(_ cut: DateSpan, matching: (SleepSourceKey?) -> Bool) {
            sleep = sleep.flatMap { item -> [OwnedSpan] in
                let span = item.span
                guard matching(item.source), span.start < cut.end, cut.start < span.end else { return [item] }
                var remaining: [OwnedSpan] = []
                if span.start < cut.start {
                    remaining.append(OwnedSpan(span: DateSpan(start: span.start, end: cut.start), source: item.source))
                }
                if cut.end < span.end {
                    remaining.append(OwnedSpan(span: DateSpan(start: cut.end, end: span.end), source: item.source))
                }
                return remaining
            }
        }
        for revision in revisions {
            for run in revision.runs {
                subtract(run) { _ in true }
                sleep.append(OwnedSpan(span: run, source: revision.source))
            }
            for awake in revision.awakeRuns { subtract(awake) { $0 == revision.source } }
            for wake in revision.nativeWakes ?? [] where observedWake.insert(NativeWakeIdentity(wake, evening: revision.eveningDay)).inserted {
                for run in wake.runs { subtract(run) { $0 == wake.source } }
            }
        }
        var merged: [DateSpan] = []
        for span in sleep.map(\.span).sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    static func reconciledSRI(for day: StressDayAxis, observations: [SleepObservation],
                              history: [DailyReport], calendar: Calendar, visibleAt: Date,
                              incomingRevisions: [EveningSleepRevision] = [], currentHasProvenance: Bool = true)
        -> (score: Double?, needsProvenance: Bool) {
        let from = calendar.date(byAdding: .day, value: -7, to: day.start) ?? day.start.addingTimeInterval(-7 * 86_400)
        let relevant = history.filter { $0.date >= from && $0.date <= day.end }
        let revisions = relevant.flatMap(attachedEveningRevisions) + incomingRevisions
        let prior = onePerDay(relevant.filter { report in
            let observationAt = report.sectorFreshness?.nightPreserved == true ? report.sectorFreshness?.nightAt : report.computedAt
            return report.date < day.start && (observationAt ?? .distantPast) <= visibleAt
        }, calendar: calendar)
        var days: [Date: [SleepObservation]] = [:]
        var conflicts: [Date: [DateSpan]] = [:]
        for r in prior {
            guard let original = r.originalSleepObservations else { continue }
            if let axis = r.stressAxis, axis.start == r.date, axis.timeZoneIdentifier == day.timeZoneIdentifier {
                days[r.date] = effectiveSleepObservations(original, target: axis, revisions: revisions, visibleAt: visibleAt)
                conflicts[r.date] = ambiguousWake(in: original, hasProvenance: r.regularityAlignmentInputs != nil,
                                                 target: axis, revisions: revisions, history: relevant, visibleAt: visibleAt)
            } else {
                days[r.date] = original
            }
        }
        days[day.start] = effectiveSleepObservations(observations, target: day, revisions: revisions, visibleAt: visibleAt)
        conflicts[day.start] = ambiguousWake(in: observations, hasProvenance: currentHasProvenance,
                                            target: day, revisions: revisions, history: relevant, visibleAt: visibleAt)
        return (SleepMetrics.sri(observationsByDay: days, calendar: calendar),
                hasRelevantConflict(conflicts, in: days, current: day.start, calendar: calendar))
    }

    private static func ambiguousWake(in original: [SleepObservation], hasProvenance: Bool, target: StressDayAxis,
                                      revisions: [EveningSleepRevision], history: [DailyReport], visibleAt: Date) -> [DateSpan] {
        // Il vecchio campo RC5 è stato scritto dalla stessa pipeline che distingueva la veglia contestuale.
        guard !hasProvenance else { return [] }
        let wake = original.filter { !$0.asleep && $0.contextualWake == nil }
        guard !wake.isEmpty else { return [] }
        let active = visibleEveningRevisions(revisions, target: target, visibleAt: visibleAt)
        let sleep = active.contains(where: \.hasClassification) ? eveningSleepRuns(after: active)
            : legacySleepRuns(for: target, in: history, visibleAt: visibleAt)
        return wake.flatMap { observation in
            sleep.compactMap { run -> DateSpan? in
                let start = max(observation.span.start, run.start, target.start)
                let end = min(observation.span.end, run.end, target.end)
                return start < end ? DateSpan(start: start, end: end) : nil
            }
        }
    }

    private static func legacySleepRuns(for target: StressDayAxis, in history: [DailyReport], visibleAt: Date) -> [DateSpan] {
        // Solo un conflitto leggibile: la notte RC4 non viene convertita in una conferma del ledger.
        guard let calendar = archivedCalendar(for: target) else { return [] }
        let next = history.filter { $0.date == target.end && ($0.computedAt ?? .distantPast) <= visibleAt }
        guard let source = onePerDay(next, calendar: calendar).first, source.regularityAlignmentInputs == nil,
              let axis = source.stressAxis, axis.start == target.end,
              axis.timeZoneIdentifier == target.timeZoneIdentifier, archivedCalendar(for: axis) != nil,
              let night = source.night, night.finalWake >= axis.start, night.finalWake < axis.end else { return [] }
        return night.sleepRuns.filter { $0.start >= night.sleepOnset && $0.end <= night.finalWake && $0.start < $0.end }
    }

    private static func archivedCalendar(for axis: StressDayAxis) -> Calendar? {
        guard let zone = TimeZone(identifier: axis.timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let actual = calendar.dateInterval(of: .day, for: axis.start), actual.start == axis.start, actual.end == axis.end else { return nil }
        return calendar
    }

    private static func hasRelevantConflict(_ conflicts: [Date: [DateSpan]], in days: [Date: [SleepObservation]],
                                            current: Date, calendar: Calendar) -> Bool {
        if conflicts[current]?.isEmpty == false { return true }
        for (date, spans) in conflicts where !spans.isEmpty {
            for step in [-1, 1] {
                guard let other = calendar.date(byAdding: .day, value: step, to: date), let compared = days[other] else { continue }
                let shift = Double(step) * 86_400
                if spans.contains(where: { conflict in
                    let start = conflict.start.addingTimeInterval(shift), end = conflict.end.addingTimeInterval(shift)
                    return compared.contains { $0.span.start < end && start < $0.span.end }
                }) { return true }
            }
        }
        return false
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
        if let index = h.firstIndex(where: { $0.date == report.date }),
           let prior = onePerDay(history.filter { $0.date == report.date }, calendar: calendar).first {
            h[index] = mergeRefresh(latest: h[index], prior: prior, incoming: report)
        }
        if let last = h.last?.date, let limit = calendar.date(byAdding: .day, value: -keepDays, to: last) {
            h.removeAll { $0.date < limit }
        }
        return reconcileArchive(h, replacing: report.date, previous: history, calendar: calendar)
    }

    private struct NightShape: Hashable {
        let inBed: Date
        let outOfBed: Date
        let sleep: [DateSpan]
        let proof: NightReadProof?

        init(_ sector: ArchivedNight) {
            inBed = sector.night.inBed; outOfBed = sector.night.outOfBed
            sleep = sector.night.sleepRuns; proof = sector.proof
        }
    }

    private static func nightVariants(_ prior: DailyReport, _ incoming: DailyReport) -> [ArchivedNight] {
        let candidates = (prior.archivedNightVariants ?? [ArchivedNight(prior)].compactMap { $0 }) +
            (incoming.archivedNightVariants ?? [ArchivedNight(incoming)].compactMap { $0 })
        let ordered = candidates.compactMap { value in (try? encoder().encode(value)).map { (value, $0) } }
            .sorted { a, b in
                let first = a.0.at ?? .distantPast, second = b.0.at ?? .distantPast
                return first == second ? a.1.lexicographicallyPrecedes(b.1) : first < second
            }.map(\.0)
        let retained = Dictionary(grouping: ordered.indices.filter { ordered[$0].proof?.closed == true },
                                  by: { NightShape(ordered[$0]) })
        var keep = Set(retained.values.flatMap { [$0.first, $0.last].compactMap { $0 } })
        if let initial = ordered.indices.first, ordered[initial].proof?.closed != true { keep.insert(initial) }
        // Le riletture identiche allo stesso istante sono un unico candidato.
        var seen = Set<Data>()
        return keep.sorted().compactMap { i in
            let value = ordered[i]
            guard let key = try? encoder().encode(value), seen.insert(key).inserted else { return nil }
            return value
        }
    }

    private static func covered(_ span: DateSpan, by coverage: [DateSpan]) -> Bool {
        var cursor = span.start
        for run in coverage where run.end > cursor {
            if run.start > cursor { return false }
            cursor = run.end
            if cursor >= span.end { return true }
        }
        return cursor >= span.end
    }

    private static func canReplace(_ old: ArchivedNight, with candidate: ArchivedNight) -> Bool {
        guard let proof = candidate.proof, proof.closed else { return false }
        if let previousSource = old.proof?.source, previousSource != proof.source { return false }
        if old.proof?.closed == false { return true }
        let previous = old.night.sleepRuns.isEmpty ? [DateSpan(start: old.night.sleepOnset, end: old.night.finalWake)]
            : old.night.sleepRuns
        let sameSource = proof.source != nil && proof.source == old.proof?.source
        let coverage = (candidate.night.sleepRuns + (sameSource ? proof.explicitWake : [])).sorted { $0.start < $1.start }
        return previous.allSatisfy { covered($0, by: coverage) }
    }

    private static func acceptedNight(_ ordered: [ArchivedNight]) -> ArchivedNight? {
        let byTime = Dictionary(grouping: ordered, by: { $0.at ?? .distantPast })
        var result: ArchivedNight?
        for time in byTime.keys.sorted() {
            guard let readings = byTime[time], Set(readings.map(NightShape.init)).count == 1,
                  let candidate = readings.last else { continue }
            if let previous = result, !canReplace(previous, with: candidate) { continue }
            result = candidate
        }
        return result
    }

    private static func sectorTime(_ report: DailyReport, at key: KeyPath<ReportSectorFreshness, Date?>,
                                   state: KeyPath<DailyEvidence, DailyMetricState>) -> Date? {
        if let acquired = report.sectorFreshness?[keyPath: key] { return acquired }
        return report.state(state) == .observed ? report.computedAt : nil
    }

    private static func preserveObservedEnergy(in report: inout DailyReport, from prior: DailyReport,
                                                and incoming: DailyReport, freshness: inout ReportSectorFreshness) {
        for (time, state, value) in [
            (\ReportSectorFreshness.activeEnergyAt, \DailyEvidence.energyActive, \DailyReport.kcalActive),
            (\ReportSectorFreshness.totalEnergyAt, \DailyEvidence.energyTotal, \DailyReport.kcalTotal),
        ] {
            let older = sectorTime(prior, at: time, state: state)
            let newer = sectorTime(incoming, at: time, state: state)
            guard older != nil || newer != nil else { continue }
            let usePrior = (older ?? .distantPast) >= (newer ?? .distantPast)
            let conflict = older == newer && prior[keyPath: value] != incoming[keyPath: value]
            let observed = usePrior ? prior[keyPath: value] : incoming[keyPath: value]
            report[keyPath: value] = conflict ? .nan : observed
            freshness[keyPath: time] = usePrior ? older : newer
            let energyState: DailyMetricState = report[keyPath: value].isFinite ? .observed : .stale
            report.evidence?[keyPath: state] = energyState
        }
        if let active = freshness.activeEnergyAt, let total = freshness.totalEnergyAt, active > total {
            report.evidence?.energyTotal = .stale
        }
    }

    private static func mergeRefresh(latest: DailyReport, prior: DailyReport, incoming: DailyReport) -> DailyReport {
        guard let axis = incoming.stressAxis, axis == prior.stressAxis, axis.start == incoming.date else {
            // Un vecchio report senza asse può essere letto, ma le sue misure non si uniscono a un nuovo asse.
            if prior.stressAxis == nil, prior.night != nil, incoming.nightReadProof?.closed != true {
                var unchanged = prior
                unchanged.sectorFreshness = unchanged.sectorFreshness ?? ReportSectorFreshness(nightAt: prior.computedAt)
                unchanged.sectorFreshness?.nightPreserved = true
                return unchanged
            }
            return latest
        }
        guard incoming.sectorFreshness != nil || prior.sectorFreshness != nil else { return latest }
        var report = latest
        var freshness = latest.sectorFreshness ?? ReportSectorFreshness()
        preserveObservedEnergy(in: &report, from: prior, and: incoming, freshness: &freshness)
        let variants = nightVariants(prior, incoming)
        report.archivedNightVariants = variants.count > 1 ? variants : nil
        if let night = acceptedNight(variants) {
            freshness.nightAt = night.at
            let matchesLatest = ArchivedNight(latest).map { NightShape($0) == NightShape(night) } ?? false
            freshness.nightPreserved = night.at == nil || night.at != latest.computedAt || !matchesLatest
            if freshness.nightPreserved {
                report.night = night.night; report.nightReadProof = night.proof
                report.naps = night.naps; report.napsMin = night.napsMin; report.dailySleepMin = night.total
                report.sleepDebtH = night.debt; report.sleepConsistency = night.consistency
                report.rhr = night.rhr; report.evidence?.rhr = night.rhrState
                report.sleepObservations = night.observations; report.sleepObservationsBeforeReconciliation = nil
                report.regularityAlignmentInputs = night.alignmentInputs
                report.evidence?.activity = .stale; report.evidence?.movement = .stale
                report.evidence?.stress = .stale; report.evidence?.rhythm = .stale
                report.evidence?.recovery = .stale; report.flags = []
                report.evidence?.alignment = .stale; report.evidence?.tempMinimum = .stale
                report.evidence?.fitness = .stale
                mergeDaytimePulse(in: &report, from: prior, and: incoming, freshness: &freshness, axis: axis, night: night)
            }
        } else if !variants.isEmpty {
            report.night = nil; report.nightReadProof = nil; report.dailySleepMin = nil
            freshness.nightAt = nil; freshness.nightPreserved = true
        }
        report.sectorFreshness = freshness
        return report
    }

    private static func mergeDaytimePulse(in report: inout DailyReport, from prior: DailyReport, and incoming: DailyReport,
                                          freshness: inout ReportSectorFreshness, axis: StressDayAxis, night: ArchivedNight) {
        let nightCarrier = [prior, incoming].first { reading in
            ArchivedNight(reading).map { $0.at == night.at && NightShape($0) == NightShape(night) } ?? false
        }
        let bounds = nightCarrier?.zoneBounds ?? []
        report.zoneBounds = bounds
        if let nightCarrier { report.hrMax = nightCarrier.hrMax; report.hrMaxMeasured = nightCarrier.hrMaxMeasured }
        let protected = [DateSpan(start: night.night.inBed, end: night.night.outOfBed)] + night.naps
        func belongsToNight(_ offset: Int) -> Bool {
            let start = axis.start.addingTimeInterval(Double(offset) * 60)
            let end = start.addingTimeInterval(60)
            return protected.contains { $0.start < end && start < $0.end }
        }
        let count = Int(axis.end.timeIntervalSince(axis.start) / 60)
        let readings = [prior, incoming].filter { $0.pulseZoneCells?.count == count }
            .sorted { daytimeReadAt($0) < daytimeReadAt($1) }
        guard let recent = readings.last(where: { reading in
            reading.pulseZoneCells?.enumerated().contains { $0.element > 0 && !belongsToNight($0.offset) } == true
        }), let daytime = recent.pulseZoneCells else {
            freshness.daytimePulseAt = nil
            report.pulseZoneCells = nightCarrier?.pulseZoneCells
            if let nightCarrier { report.zoneMinutesDay = nightCarrier.zoneMinutesDay }
            report.evidence?.zones = .stale
            return
        }
        let overnight = nightCarrier?.pulseZoneCells?.count == count ? nightCarrier?.pulseZoneCells : nil
        let compatible = !bounds.isEmpty && recent.zoneBounds == bounds
        let cells = Data(daytime.enumerated().map { offset, value -> UInt8 in
            if belongsToNight(offset) { return overnight?[offset] ?? 0 }
            return compatible || value == 0 ? value : 7
        })
        var totals = [Double](repeating: 0, count: 5)
        for value in cells where value >= 2 && value <= 6 { totals[Int(value) - 2] += 1 }
        report.zoneMinutesDay = totals; report.pulseZoneCells = cells
        let classifiedDay = cells.enumerated().contains { $0.element > 0 && $0.element < 7 && !belongsToNight($0.offset) }
        report.evidence?.zones = classifiedDay ? .computed : .insufficient
        freshness.daytimePulseAt = recent.sectorFreshness?.daytimePulseAt ?? recent.computedAt
    }

    private static func daytimeReadAt(_ report: DailyReport) -> Date {
        report.sectorFreshness?.daytimePulseAt ?? report.computedAt ?? .distantPast
    }

    private static func reconcileArchive(_ history: [DailyReport], replacing date: Date, previous: [DailyReport],
                                         calendar: Calendar) -> [DailyReport] {
        let timestamps = history.compactMap(\.computedAt) + history.flatMap(attachedEveningRevisions).map(\.confirmedAt)
        guard let visibleAt = timestamps.max() else { return history }
        var targetDays = [date]
        if let before = calendar.dateInterval(of: .day, for: date.addingTimeInterval(-1)), before.end == date {
            targetDays.append(before.start)
        }
        let old = onePerDay(previous.filter { targetDays.contains($0.date) }, calendar: calendar)
        var affected: [ClosedRange<Date>] = []
        for day in targetDays {
            guard let updated = history.first(where: { $0.date == day }), let axis = updated.stressAxis,
                  axis.start == day, axis.timeZoneIdentifier == calendar.timeZone.identifier,
                  let original = updated.originalSleepObservations else { continue }
            let newRevisions = eveningRevisions(in: history, successor: axis.end)
            let oldRevisions = eveningRevisions(in: previous, successor: axis.end)
            let previousTarget = old.first { $0.date == day }
            let observedBefore = previousTarget?.originalSleepObservations ?? []
            let before = effectiveSleepObservations(observedBefore, target: axis, revisions: oldRevisions, visibleAt: visibleAt)
            let after = effectiveSleepObservations(original, target: axis, revisions: newRevisions, visibleAt: visibleAt)
            let conflictsBefore = ambiguousWake(in: observedBefore, hasProvenance: previousTarget?.regularityAlignmentInputs != nil,
                                                target: axis, revisions: oldRevisions, history: previous, visibleAt: visibleAt)
            let conflictsAfter = ambiguousWake(in: original, hasProvenance: updated.regularityAlignmentInputs != nil,
                                               target: axis, revisions: newRevisions, history: history, visibleAt: visibleAt)
            let projectionChanged = before != after && (before != observedBefore || after != original)
            let supersededTime = oldRevisions != newRevisions && oldRevisions.contains { $0.confirmedAt > visibleAt }
            let nightChanged = day == date && previousTarget != nil &&
                (updated.sectorFreshness?.nightPreserved == true || original != observedBefore)
            guard projectionChanged || conflictsBefore != conflictsAfter || supersededTime || nightChanged,
                  let limit = calendar.date(byAdding: .day, value: 7, to: day) else { continue }
            affected.append(day...limit)
        }
        guard !affected.isEmpty else { return history }
        return history.map { candidate in
            guard affected.contains(where: { $0.contains(candidate.date) }),
                  let axis = candidate.stressAxis, axis.start == candidate.date, axis.timeZoneIdentifier == calendar.timeZone.identifier,
                  let original = candidate.originalSleepObservations else { return candidate }
            let revisions = eveningRevisions(in: history, successor: axis.end)
            let observations = effectiveSleepObservations(original, target: axis, revisions: revisions, visibleAt: visibleAt)
            let assessment = reconciledSRI(for: axis, observations: original, history: history, calendar: calendar,
                                          visibleAt: visibleAt, currentHasProvenance: candidate.regularityAlignmentInputs != nil)
            let sri = assessment.score
            let needsProvenance = assessment.needsProvenance ? true : nil
            guard sri != candidate.sri || observations != candidate.sleepObservations ||
                    (candidate.sriReconciledAt ?? .distantPast) > visibleAt ||
                    needsProvenance != candidate.sriNeedsProvenance else { return candidate }
            var revised = candidate
            revised.sleepObservations = observations
            revised.sleepObservationsBeforeReconciliation = observations == original ? nil : original
            revised.sri = sri
            revised.sriReconciledAt = visibleAt
            revised.sriNeedsProvenance = needsProvenance
            if sri == candidate.sri { return revised }
            if candidate.sectorFreshness?.nightPreserved == true {
                revised.evidence?.alignment = .stale
            } else if let inputs = candidate.regularityAlignmentInputs {
                let score = inputs.score(midpoint: candidate.night?.midpointH, sri: sri, socialJetlag: candidate.socialJetlagScH)
                revised.circadianAlignment = score ?? .nan
                revised.evidence?.alignment = score == nil ? .insufficient : .estimated
            } else {
                revised.evidence?.alignment = .stale
            }
            return revised
        }
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
        return annotateLegacyProvenance(try d.decode([DailyReport].self, from: data))
    }

    private static func annotateLegacyProvenance(_ history: [DailyReport]) -> [DailyReport] {
        var byZone: [String: [Date: [DateSpan]]] = [:]
        for report in history {
            guard report.regularityAlignmentInputs == nil, let original = report.originalSleepObservations,
                  let axis = report.stressAxis, axis.start == report.date,
                  let calendar = archivedCalendar(for: axis) else { continue }
            let runs = ambiguousWake(in: original, hasProvenance: false, target: axis,
                                     revisions: eveningRevisions(in: history, successor: axis.end), history: history,
                                     visibleAt: .distantFuture)
            if !runs.isEmpty { byZone[calendar.timeZone.identifier, default: [:]][axis.start] = runs }
        }
        guard !byZone.isEmpty else { return history }
        return history.map { report in
            guard let axis = report.stressAxis, axis.start == report.date, let calendar = archivedCalendar(for: axis),
                  let zoneConflicts = byZone[calendar.timeZone.identifier],
                  let from = calendar.date(byAdding: .day, value: -7, to: axis.start) else { return report }
            let dates = from...axis.start
            let conflicts = zoneConflicts.filter { dates.contains($0.key) }
            guard !conflicts.isEmpty else { return report }
            let reports = onePerDay(history.filter {
                dates.contains($0.date) && $0.stressAxis?.timeZoneIdentifier == axis.timeZoneIdentifier
            }, calendar: calendar)
            let days = Dictionary(uniqueKeysWithValues: reports.compactMap { r in r.sleepObservations.map { (r.date, $0) } })
            guard hasRelevantConflict(conflicts, in: days, current: axis.start, calendar: calendar) else { return report }
            var marked = report
            marked.sriNeedsProvenance = true
            return marked
        }
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
