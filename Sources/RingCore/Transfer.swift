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

    private func load(_ bucket: Int) -> [Int: MotionEpoch] {
        if let c = cache[bucket] { return c }
        var m: [Int: MotionEpoch] = [:]
        if let d = try? Data(contentsOf: url(bucket)), let a = try? JSONDecoder().decode([MotionEpoch].self, from: d) {
            for e in a { m[e.index] = e }
        }
        cache[bucket] = m
        return m
    }

    /// Aggiunge epoche (idempotente: reinviare lo stesso pacchetto non duplica nulla)
    public func merge(_ epochs: [MotionEpoch]) {
        lock.lock(); defer { lock.unlock() }
        var touched = Set<Int>()
        for e in epochs {
            let b = e.index / RingConst.epochsPerDay
            var m = load(b)
            if let old = m[e.index], old.samples >= e.samples { continue }
            m[e.index] = e; cache[b] = m; touched.insert(b)
        }
        for b in touched {
            let a = (cache[b] ?? [:]).values.sorted { $0.index < $1.index }
            if let d = try? JSONEncoder().encode(a) { try? d.write(to: url(b), options: .atomic) }
        }
    }

    public func epochs(from: Date, to: Date) -> [MotionEpoch] {
        lock.lock(); defer { lock.unlock() }
        let a = Int((from.timeIntervalSince1970 / RingConst.epoch).rounded(.down))
        let z = Int((to.timeIntervalSince1970 / RingConst.epoch).rounded(.up))
        guard a < z else { return [] }
        var out: [MotionEpoch] = []
        for b in (a / RingConst.epochsPerDay)...(z / RingConst.epochsPerDay) {
            out += load(b).values.filter { $0.index >= a && $0.index < z }
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
            try? FileManager.default.removeItem(at: f)
            cache[b] = nil
        }
    }
}
