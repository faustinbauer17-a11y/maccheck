import Foundation

/// How long scan history is kept. Documented in docs/PRIVACY.md.
public struct RetentionPolicy: Equatable, Sendable {
    public var maxEntries: Int
    public var maxAgeDays: Int

    public init(maxEntries: Int = 50, maxAgeDays: Int = 90) {
        self.maxEntries = max(1, maxEntries)
        self.maxAgeDays = max(1, maxAgeDays)
    }

    public static let standard = RetentionPolicy()
}

public struct HistoryEntry: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var kind: ScanKind
    public var overall: CheckStatus
    public var isSampleData: Bool
    public var title: String
    public var fileURL: URL
}

/// Stores scan reports as JSON files in one local folder
/// (`~/Library/Application Support/MacCheck/History` on macOS).
///
/// - Unique identifiers are stripped before saving, whatever the export settings.
/// - Retention is applied on every save; `clearAll()` deletes only files this store created.
public final class HistoryStore: @unchecked Sendable {
    public let directory: URL
    public let retention: RetentionPolicy
    private let lock = NSLock()
    private let fm = FileManager.default
    static let filePrefix = "scan-"

    public init(directory: URL, retention: RetentionPolicy = .standard) {
        self.directory = directory
        self.retention = retention
    }

    /// `~/Library/Application Support/MacCheck/History` (or the platform equivalent).
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MacCheck", isDirectory: true).appendingPathComponent("History", isDirectory: true)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    @discardableResult
    public func save(_ report: ScanReport, now: Date = Date()) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = report.withoutSensitiveData()
        let url = directory.appendingPathComponent("\(Self.filePrefix)\(safe.id.uuidString).json")
        try Self.encoder.encode(safe).write(to: url, options: [.atomic])
        try applyRetentionLocked(now: now)
        return url
    }

    public func list() -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return listLocked()
    }

    public func load(_ id: UUID) throws -> ScanReport {
        let url = directory.appendingPathComponent("\(Self.filePrefix)\(id.uuidString).json")
        return try Self.decoder.decode(ScanReport.self, from: Data(contentsOf: url))
    }

    public func delete(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let url = directory.appendingPathComponent("\(Self.filePrefix)\(id.uuidString).json")
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }

    /// Deletes every scan file this store wrote. Other files in the folder are left alone.
    public func clearAll() throws {
        lock.lock(); defer { lock.unlock() }
        for url in scanFiles() { try fm.removeItem(at: url) }
    }

    private func scanFiles() -> [URL] {
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.lastPathComponent.hasPrefix(Self.filePrefix) && $0.pathExtension == "json" }
    }

    private func listLocked() -> [HistoryEntry] {
        scanFiles().compactMap { url -> HistoryEntry? in
            guard let data = try? Data(contentsOf: url),
                  let r = try? Self.decoder.decode(ScanReport.self, from: data) else { return nil }
            let title: String
            switch r.kind {
            case .full: title = "Full diagnostic"
            case .singleArea: title = r.results.first?.title ?? "Single check"
            case .appDoctor: title = "App Doctor: \(r.appDoctor?.appName ?? "app")"
            }
            return HistoryEntry(id: r.id, createdAt: r.createdAt, kind: r.kind, overall: r.overallStatus,
                                isSampleData: r.isSampleData, title: title, fileURL: url)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private func applyRetentionLocked(now: Date) throws {
        let entries = listLocked()
        let cutoff = now.addingTimeInterval(-Double(retention.maxAgeDays) * 86_400)
        for (index, e) in entries.enumerated() where index >= retention.maxEntries || e.createdAt < cutoff {
            try? fm.removeItem(at: e.fileURL)
        }
        // Unreadable scan files (e.g. from a future format) are left in place rather than deleted silently.
    }
}
