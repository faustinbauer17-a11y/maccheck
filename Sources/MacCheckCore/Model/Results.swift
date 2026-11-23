import Foundation

// MARK: - Areas

/// The six whole-system diagnostic areas.
public enum DiagnosticArea: String, Codable, CaseIterable, Sendable, Identifiable {
    case battery, hardware, performance, thermals, network, storage

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .battery: return "Battery & Power"
        case .hardware: return "Hardware"
        case .performance: return "Performance"
        case .thermals: return "Thermals"
        case .network: return "Network"
        case .storage: return "Storage"
        }
    }

    /// SF Symbol name (used by the macOS UI only).
    public var symbolName: String {
        switch self {
        case .battery: return "battery.75percent"
        case .hardware: return "cpu"
        case .performance: return "gauge.with.dots.needle.33percent"
        case .thermals: return "thermometer.medium"
        case .network: return "network"
        case .storage: return "internaldrive"
        }
    }

    public var blurb: String {
        switch self {
        case .battery: return "Condition, capacity, cycle count and charging."
        case .hardware: return "Chip, memory, macOS version and model."
        case .performance: return "CPU load, memory pressure, swap and busy processes."
        case .thermals: return "Thermal pressure reported by macOS."
        case .network: return "Connection, DNS and reachability of test endpoints."
        case .storage: return "Free space, volumes and drive self-reported status."
        }
    }
}

// MARK: - Status / evidence

/// Outcome of a single check. Ordered from least to most severe for roll-ups.
public enum CheckStatus: String, Codable, Sendable, CaseIterable {
    /// Measured, nothing notable.
    case ok
    /// Measured, neutral information.
    case info
    /// Data is not exposed by macOS / not supported on this Mac. Not an error.
    case unavailable
    /// The check was cancelled or not applicable.
    case skipped
    /// The check itself failed or timed out. Says nothing about the Mac.
    case failed
    /// Measured, worth attention.
    case warning
    /// Measured, very likely a real issue.
    case problem

    public var title: String {
        switch self {
        case .ok: return "Looks good"
        case .info: return "Info"
        case .unavailable: return "Unavailable"
        case .skipped: return "Skipped"
        case .failed: return "Check failed"
        case .warning: return "Attention"
        case .problem: return "Problem"
        }
    }

    /// Severity used when combining results. Only measured outcomes carry weight.
    public var severity: Int {
        switch self {
        case .skipped: return 0
        case .unavailable: return 1
        case .info: return 2
        case .ok: return 3   // "all good" wins over neutral info in a roll-up
        case .failed: return 4
        case .warning: return 5
        case .problem: return 6
        }
    }

    /// Combine statuses: the most severe wins.
    public static func rollUp(_ statuses: [CheckStatus]) -> CheckStatus {
        guard let first = statuses.first else { return .skipped }
        return statuses.dropFirst().reduce(first) { $1.severity > $0.severity ? $1 : $0 }
    }
}

/// How a piece of information was obtained. Shown next to every finding.
public enum EvidenceLevel: String, Codable, Sendable {
    /// Read directly from a documented interface on this Mac.
    case measured
    /// A verdict reported by a macOS component (e.g. diskutil "Verified"); MacCheck cannot verify it.
    case reportedBySystem
    /// Computed by MacCheck from measured values (e.g. capacity % from mAh).
    case derived
    /// A possible explanation inferred from patterns. Never a confirmed diagnosis.
    case inferred
    /// Sample data for previews and demos. Not from this Mac.
    case sample

    public var label: String {
        switch self {
        case .measured: return "Measured"
        case .reportedBySystem: return "Reported by macOS"
        case .derived: return "Calculated"
        case .inferred: return "Possible explanation"
        case .sample: return "Sample data"
        }
    }
}

public enum Confidence: String, Codable, Sendable {
    case low, medium, high
}

public enum SourceKind: String, Codable, Sendable {
    case publicAPI, ioRegistry, systemTool, fileSystem, derived, sample, fake
}

/// Where a value came from, e.g. `IOKit AppleSmartBattery` / `.ioRegistry`.
public struct DataSource: Codable, Hashable, Sendable {
    public var name: String
    public var kind: SourceKind

    public init(_ name: String, kind: SourceKind) {
        self.name = name
        self.kind = kind
    }

    public static let sample = DataSource("Sample data", kind: .sample)
}

// MARK: - Measurement

public struct Measurement: Codable, Hashable, Sendable, Identifiable {
    public var id: String { key }
    /// Stable key, e.g. `battery.cycleCount`.
    public var key: String
    public var label: String
    /// Human-readable value as shown in the UI and reports.
    public var display: String
    /// Optional raw number for comparisons between scans.
    public var numeric: Double?
    public var source: DataSource
    public var evidence: EvidenceLevel
    /// Unique identifiers (serial number etc.). Excluded from history and exports unless opted in.
    public var isSensitive: Bool

    public init(key: String, label: String, display: String, numeric: Double? = nil,
                source: DataSource, evidence: EvidenceLevel = .measured, isSensitive: Bool = false) {
        self.key = key
        self.label = label
        self.display = display
        self.numeric = numeric
        self.source = source
        self.evidence = evidence
        self.isSensitive = isSensitive
    }
}

// MARK: - Findings

public enum FindingKind: String, Codable, Sendable {
    /// A measured fact worth calling out.
    case fact
    /// Something worth attention.
    case warning
    /// Very likely a real problem.
    case problem
    /// Data that could not be obtained, and why.
    case unavailable
    /// A possible explanation. Always carries a confidence level.
    case possibleExplanation
    /// What MacCheck can't tell you about this area.
    case limitation

    public var label: String {
        switch self {
        case .fact: return "Fact"
        case .warning: return "Attention"
        case .problem: return "Problem"
        case .unavailable: return "Unavailable"
        case .possibleExplanation: return "Possible explanation"
        case .limitation: return "Limit"
        }
    }
}

/// A link to a place in macOS where the user can act. MacCheck never changes these settings itself.
public struct SystemSettingsLink: Codable, Hashable, Sendable {
    public var title: String
    /// Plain-language path, always shown (deep links are best effort and can change between macOS versions).
    public var path: String
    /// `x-apple.systempreferences:` URL or app bundle identifier handoff.
    public var url: String?

    public init(title: String, path: String, url: String?) {
        self.title = title
        self.path = path
        self.url = url
    }
}

public struct Finding: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: FindingKind
    public var title: String
    public var detail: String
    public var evidence: EvidenceLevel
    public var confidence: Confidence?
    /// Plain-language next steps. Advice only — nothing is executed.
    public var advice: [String]
    public var links: [SystemSettingsLink]

    public init(id: String, kind: FindingKind, title: String, detail: String,
                evidence: EvidenceLevel, confidence: Confidence? = nil,
                advice: [String] = [], links: [SystemSettingsLink] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.evidence = evidence
        // A possible explanation must always state a confidence; default to low.
        if kind == .possibleExplanation && confidence == nil {
            self.confidence = .low
        } else {
            self.confidence = confidence
        }
        self.advice = advice
        self.links = links
    }
}

// MARK: - Check result

public struct CheckResult: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var area: DiagnosticArea?
    public var title: String
    public var status: CheckStatus
    /// One-sentence plain-language summary.
    public var summary: String
    public var startedAt: Date
    public var finishedAt: Date
    public var measurements: [Measurement]
    public var findings: [Finding]
    public var limitations: [String]
    public var sources: [DataSource]
    /// Set when status == .failed.
    public var errorDescription: String?

    public init(id: String, area: DiagnosticArea?, title: String, status: CheckStatus, summary: String,
                startedAt: Date, finishedAt: Date, measurements: [Measurement] = [], findings: [Finding] = [],
                limitations: [String] = [], sources: [DataSource] = [], errorDescription: String? = nil) {
        self.id = id
        self.area = area
        self.title = title
        self.status = status
        self.summary = summary
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.measurements = measurements
        self.findings = findings
        self.limitations = limitations
        self.sources = sources
        self.errorDescription = errorDescription
    }

    public var isSampleData: Bool { sources.contains { $0.kind == .sample } }

    public func measurement(_ key: String) -> Measurement? { measurements.first { $0.key == key } }

    /// Copy with unique identifiers removed (used for history and default exports).
    public func withoutSensitiveMeasurements() -> CheckResult {
        var copy = self
        copy.measurements.removeAll { $0.isSensitive }
        return copy
    }

    static func failed(id: String, area: DiagnosticArea?, title: String, started: Date, error: String) -> CheckResult {
        CheckResult(id: id, area: area, title: title, status: .failed,
                    summary: "This check could not complete. It says nothing about the health of your Mac.",
                    startedAt: started, finishedAt: Date(), errorDescription: error)
    }

    static func skipped(id: String, area: DiagnosticArea?, title: String, reason: String) -> CheckResult {
        let now = Date()
        return CheckResult(id: id, area: area, title: title, status: .skipped, summary: reason,
                           startedAt: now, finishedAt: now)
    }
}

// MARK: - Device summary & report

public struct DeviceSummary: Codable, Hashable, Sendable {
    public var modelName: String
    public var modelIdentifier: String?
    public var chip: String?
    public var memory: String?
    public var macOS: String?
    public var isFanless: Bool?

    public init(modelName: String, modelIdentifier: String?, chip: String?, memory: String?, macOS: String?, isFanless: Bool?) {
        self.modelName = modelName
        self.modelIdentifier = modelIdentifier
        self.chip = chip
        self.memory = memory
        self.macOS = macOS
        self.isFanless = isFanless
    }
}

public enum ScanKind: String, Codable, Sendable {
    case full, singleArea, appDoctor
}

public struct ScanReport: Codable, Hashable, Sendable, Identifiable {
    public static let formatVersion = 1

    public var id: UUID
    public var formatVersion: Int
    public var kind: ScanKind
    public var createdAt: Date
    public var finishedAt: Date
    public var appVersion: String
    public var device: DeviceSummary?
    public var results: [CheckResult]
    public var appDoctor: AppDoctorResult?
    /// True when produced from sample data. The UI and every export label this prominently.
    public var isSampleData: Bool
    public var wasCancelled: Bool

    public init(id: UUID = UUID(), kind: ScanKind, createdAt: Date, finishedAt: Date, appVersion: String,
                device: DeviceSummary?, results: [CheckResult], appDoctor: AppDoctorResult? = nil,
                isSampleData: Bool, wasCancelled: Bool = false) {
        self.id = id
        self.formatVersion = ScanReport.formatVersion
        self.kind = kind
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.appVersion = appVersion
        self.device = device
        self.results = results
        self.appDoctor = appDoctor
        self.isSampleData = isSampleData
        self.wasCancelled = wasCancelled
    }

    public var overallStatus: CheckStatus {
        var all = results.map(\.status)
        if let doc = appDoctor { all += doc.checks.map(\.status) }
        return CheckStatus.rollUp(all)
    }

    public func result(for area: DiagnosticArea) -> CheckResult? { results.first { $0.area == area } }

    public var counts: (problems: Int, warnings: Int, unavailable: Int, failed: Int) {
        var p = 0, w = 0, u = 0, f = 0
        for r in results {
            switch r.status {
            case .problem: p += 1
            case .warning: w += 1
            case .unavailable: u += 1
            case .failed: f += 1
            default: break
            }
        }
        return (p, w, u, f)
    }

    /// Copy with unique identifiers removed everywhere.
    public func withoutSensitiveData() -> ScanReport {
        var copy = self
        copy.results = results.map { $0.withoutSensitiveMeasurements() }
        if var doc = copy.appDoctor {
            doc.checks = doc.checks.map { $0.withoutSensitiveMeasurements() }
            copy.appDoctor = doc
        }
        return copy
    }
}
