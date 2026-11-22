import Foundation

/// Pacchetto di epoche di movimento inviato dal Watch all'iPhone (WatchConnectivity, transferFile o transferUserInfo)
public struct MotionChunk: Codable, Sendable, Equatable {
    public static let currentVersion = 2
    public var version: Int
    public var epochs: [MotionEpoch]
    public init(epochs: [MotionEpoch]) { version = Self.currentVersion; self.epochs = epochs }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> MotionChunk {
        let c = try JSONDecoder().decode(MotionChunk.self, from: data)
        guard c.version == currentVersion else { throw CocoaError(.coderReadCorrupt) }
        return c
    }
}

/// Coda locale del Watch. L'identità del file rimane stabile fra tentativi e riavvii.
public struct MotionOutbox: Sendable {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func isPacketName(_ name: String) -> Bool {
        guard name.hasPrefix("motion-"), name.hasSuffix(".json") else { return false }
        let id = String(name.dropFirst(7).dropLast(5))
        if UUID(uuidString: id) != nil { return true }
        // Accetta anche i file già in coda nel formato precedente (primo-ultimo indice).
        let indices = id.split(separator: "-", omittingEmptySubsequences: false)
        guard indices.count == 2, let first = Int(indices[0]), let last = Int(indices[1]) else { return false }
        return first >= 0 && last >= first && id == "\(first)-\(last)"
    }

    @discardableResult public func enqueue(_ epochs: [MotionEpoch]) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("motion-\(UUID().uuidString).json")
        try MotionChunk(epochs: epochs).encoded().write(to: file, options: .atomic)
        return file
    }

    public func packets() throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { Self.isPacketName($0.lastPathComponent) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
    }

    public func acknowledge(_ name: String, matches: (Data) -> Bool) throws {
        guard Self.isPacketName(name) else { throw CocoaError(.fileReadInvalidFileName) }
        let file = directory.appendingPathComponent(name)
        do {
            guard matches(try Data(contentsOf: file)) else { return }
            try FileManager.default.removeItem(at: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        }
    }
}

/// Impostazioni personali che l'iPhone manda al Watch, così le zone mostrate al polso sono quelle vere dell'utente
public struct WatchSettings: Codable, Sendable, Equatable {
    public var rhr: Double
    public var hrMax: Double
    public var zoneBounds: [Double]
    public init(rhr: Double, hrMax: Double, zoneBounds: [Double]) { self.rhr = rhr; self.hrMax = hrMax; self.zoneBounds = zoneBounds }
    /// valori provvisori finché l'iPhone non ha inviato quelli personali
    public static func fallback(age: Double = 30) -> WatchSettings {
        let m = HeartRate.tanaka(age: age)
        return WatchSettings(rhr: 60, hrMax: m, zoneBounds: HeartRate.zoneBounds(model: .percentMax, rhr: 60, hrMax: m))
    }
}

/// Archivio su disco delle epoche di movimento, sicuro rispetto ai thread (i dati arrivano da code di sistema diverse).
/// Un file JSON per giorno UTC; le epoche duplicate vengono fuse tenendo quella con più campioni.
public final class MotionArchive: @unchecked Sendable {
    private let lock = NSLock()
    private let dir: URL
    private var cache: [Int: [Int: MotionEpoch]] = [:]

    public init(directory: URL) {
        dir = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ bucket: Int) -> URL { dir.appendingPathComponent("motion-\(bucket).json") }

    private func load(_ bucket: Int) throws -> [Int: MotionEpoch] {
        if let c = cache[bucket] { return c }
        var m: [Int: MotionEpoch] = [:]
        do {
            let data = try Data(contentsOf: url(bucket))
            for e in try JSONDecoder().decode([MotionEpoch].self, from: data) { m[e.index] = e }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
        cache[bucket] = m
        return m
    }

    /// True dopo aver archiviato ogni epoca o trovato già archiviata una revisione equivalente o superiore.
    @discardableResult public func merge(_ epochs: [MotionEpoch]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let groups = Dictionary(grouping: epochs) { $0.index / RingConst.epochsPerDay }
            for b in groups.keys.sorted() {
                let original = try load(b)
                var updated = original
                for e in groups[b] ?? [] {
                    if let old = updated[e.index], !Self.precedes(old, e) { continue }
                    updated[e.index] = e
                }
                guard updated != original else { continue }
                let data = try JSONEncoder().encode(updated.values.sorted { $0.index < $1.index })
                try data.write(to: url(b), options: .atomic)
                cache[b] = updated
            }
            return true
        } catch {
            return false
        }
    }

    private static func precedes(_ old: MotionEpoch, _ new: MotionEpoch) -> Bool {
        if old.samples != new.samples { return old.samples < new.samples }
        // Risoluzione ripetibile dei pareggi indipendente dall'ordine di consegna.
        let a = [old.counts.bitPattern, old.angleChange.bitPattern, UInt32(old.steps), old.rotation?.bitPattern ?? 0]
        let b = [new.counts.bitPattern, new.angleChange.bitPattern, UInt32(new.steps), new.rotation?.bitPattern ?? 0]
        if a != b { return a.lexicographicallyPrecedes(b) }
        return old.rotation == nil && new.rotation != nil
    }

    public func epochs(from: Date, to: Date) -> [MotionEpoch] {
        (try? readEpochs(from: from, to: to)) ?? []
    }

    public func readEpochs(from: Date, to: Date) throws -> [MotionEpoch] {
        lock.lock(); defer { lock.unlock() }
        let a = Int((from.timeIntervalSince1970 / RingConst.epoch).rounded(.down))
        let z = Int((to.timeIntervalSince1970 / RingConst.epoch).rounded(.up))
        guard a < z else { return [] }
        var out: [MotionEpoch] = []
        for b in (a / RingConst.epochsPerDay)...(z / RingConst.epochsPerDay) {
            out += try load(b).values.filter { $0.index >= a && $0.index < z }
        }
        return out.sorted { $0.index < $1.index }
    }

    /// indice dell'ultima epoca archiviata negli ultimi `days` giorni
    public func lastIndex(now: Date, days: Int = 4) -> Int? {
        epochs(from: now.addingTimeInterval(Double(-days) * 86_400), to: now.addingTimeInterval(3600)).last?.index
    }

    /// cancella i file più vecchi di `days` giorni
    public func prune(olderThan days: Int, now: Date) {
        lock.lock(); defer { lock.unlock() }
        let limit = Int(now.timeIntervalSince1970 / 86_400) - days
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files {
            let name = f.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("motion-"), let b = Int(name.dropFirst(7)), b < limit else { continue }
            do {
                try FileManager.default.removeItem(at: f)
                cache[b] = nil
            } catch { continue }
        }
    }
}
