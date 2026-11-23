import Foundation

/// What the user says is wrong. Drives which checks App Doctor emphasises.
public enum Symptom: String, Codable, CaseIterable, Sendable, Identifiable {
    case crashes, freezes, wontOpen, slow, permissions, somethingElse

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .crashes: return "It quits unexpectedly"
        case .freezes: return "It freezes or beachballs"
        case .wontOpen: return "It won't open"
        case .slow: return "It's slow"
        case .permissions: return "A feature doesn't work (camera, mic, files…)"
        case .somethingElse: return "Something else"
        }
    }

    public var symbolName: String {
        switch self {
        case .crashes: return "xmark.octagon"
        case .freezes: return "hourglass"
        case .wontOpen: return "lock.app.dashed"
        case .slow: return "tortoise"
        case .permissions: return "hand.raised"
        case .somethingElse: return "questionmark.circle"
        }
    }
}

public enum CPUArch: String, Codable, Sendable, Hashable {
    case arm64, arm64e, x86_64, i386, other

    public var display: String {
        switch self {
        case .arm64, .arm64e: return "Apple Silicon"
        case .x86_64: return "Intel (64-bit)"
        case .i386: return "Intel (32-bit)"
        case .other: return "Other"
        }
    }

    public var isAppleSilicon: Bool { self == .arm64 || self == .arm64e }
}

public enum SignatureStatus: Codable, Sendable, Equatable {
    /// Valid signature. `notarized` is nil when it couldn't be determined.
    case valid(notarized: Bool?, teamIdentifier: String?, isAppleSigned: Bool)
    case adHoc
    case unsigned
    case invalid(reason: String)
}

/// A light-weight entry for the app picker.
public struct AppListing: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var bundleIdentifier: String?
    public var isRunning: Bool

    public init(name: String, path: String, bundleIdentifier: String?, isRunning: Bool) {
        self.name = name
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.isRunning = isRunning
    }
}

/// Facts about one installed app, read without launching or modifying it.
public struct AppInfo: Codable, Sendable, Equatable {
    public var name: String
    public var path: String
    public var bundleIdentifier: String?
    public var executableName: String?
    public var version: String?
    public var build: String?
    public var minimumSystemVersion: String?
    public var architectures: Reading<[CPUArch]>
    public var signature: Reading<SignatureStatus>
    public var isQuarantined: Reading<Bool>
    /// App Translocation: running from a randomized read-only path because it wasn't moved after download.
    public var isTranslocated: Reading<Bool>
    public var isFromAppStore: Reading<Bool>
    public var isRunning: Reading<Bool>
    /// Bundle structure problems found (missing executable, unreadable Info.plist …).
    public var bundleProblems: [String]

    public init(name: String, path: String, bundleIdentifier: String? = nil, executableName: String? = nil,
                version: String? = nil, build: String? = nil, minimumSystemVersion: String? = nil,
                architectures: Reading<[CPUArch]> = .notCollected, signature: Reading<SignatureStatus> = .notCollected,
                isQuarantined: Reading<Bool> = .notCollected, isTranslocated: Reading<Bool> = .notCollected,
                isFromAppStore: Reading<Bool> = .notCollected, isRunning: Reading<Bool> = .notCollected,
                bundleProblems: [String] = []) {
        self.name = name
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
        self.version = version
        self.build = build
        self.minimumSystemVersion = minimumSystemVersion
        self.architectures = architectures
        self.signature = signature
        self.isQuarantined = isQuarantined
        self.isTranslocated = isTranslocated
        self.isFromAppStore = isFromAppStore
        self.isRunning = isRunning
        self.bundleProblems = bundleProblems
    }

    public var isInApplicationsFolder: Bool {
        path.hasPrefix("/Applications/") || path.range(of: #"^/Users/[^/]+/Applications/"#, options: .regularExpression) != nil
            || path.hasPrefix("/System/Applications/")
    }
}

public enum DiagnosticReportKind: String, Codable, Sendable {
    case crash, hang, resource, jetsam, other

    public var title: String {
        switch self {
        case .crash: return "Crash"
        case .hang: return "Hang / not responding"
        case .resource: return "Resource limit"
        case .jetsam: return "Closed for low memory"
        case .other: return "Other report"
        }
    }
}

/// A parsed diagnostic report, already reduced to what App Doctor needs (no thread dumps).
public struct CrashReportSummary: Codable, Sendable, Equatable, Hashable {
    public var fileName: String
    public var date: Date?
    public var kind: DiagnosticReportKind
    public var processName: String?
    public var bundleIdentifier: String?
    public var appVersion: String?
    public var osVersion: String?
    public var exceptionType: String?
    public var signal: String?
    public var terminationReason: String?
    /// Short, redacted hint such as "Library not loaded: @rpath/Foo.framework".
    public var detail: String?

    public init(fileName: String, date: Date?, kind: DiagnosticReportKind, processName: String? = nil,
                bundleIdentifier: String? = nil, appVersion: String? = nil, osVersion: String? = nil,
                exceptionType: String? = nil, signal: String? = nil, terminationReason: String? = nil,
                detail: String? = nil) {
        self.fileName = fileName
        self.date = date
        self.kind = kind
        self.processName = processName
        self.bundleIdentifier = bundleIdentifier
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.exceptionType = exceptionType
        self.signal = signal
        self.terminationReason = terminationReason
        self.detail = detail
    }

    /// Groups "the same crash" for repeat detection.
    public var signature: String {
        [exceptionType, signal, terminationReason].compactMap { $0 }.joined(separator: " · ")
    }
}

public struct LogEntrySummary: Codable, Sendable, Equatable, Hashable {
    public var date: Date?
    /// "Error" or "Fault".
    public var level: String
    public var subsystem: String?
    /// Redacted and truncated message.
    public var message: String

    public init(date: Date?, level: String, subsystem: String?, message: String) {
        self.date = date
        self.level = level
        self.subsystem = subsystem
        self.message = message
    }
}

/// Everything App Doctor looks at for one investigation.
public struct AppDoctorInput: Sendable {
    public var app: AppInfo
    public var symptom: Symptom
    public var userNote: String?
    public var reports: Reading<[CrashReportSummary]>
    public var logs: Reading<[LogEntrySummary]>
    public var macOSVersion: String?
    public var rosettaInstalled: Bool?
    public var performance: PerformanceSnapshot?
    public var storage: StorageSnapshot?
    public var thermals: ThermalSnapshot?
    /// Whether `~/Library/Saved Application State/<bundleID>.savedState` exists (nil = not checked).
    public var savedStateExists: Bool?
    public var now: Date
    public var isSample: Bool

    public init(app: AppInfo, symptom: Symptom, userNote: String? = nil, reports: Reading<[CrashReportSummary]>,
                logs: Reading<[LogEntrySummary]>, macOSVersion: String?, rosettaInstalled: Bool?,
                performance: PerformanceSnapshot? = nil, storage: StorageSnapshot? = nil,
                thermals: ThermalSnapshot? = nil, savedStateExists: Bool? = nil,
                now: Date = Date(), isSample: Bool = false) {
        self.savedStateExists = savedStateExists
        self.app = app
        self.symptom = symptom
        self.userNote = userNote
        self.reports = reports
        self.logs = logs
        self.macOSVersion = macOSVersion
        self.rosettaInstalled = rosettaInstalled
        self.performance = performance
        self.storage = storage
        self.thermals = thermals
        self.now = now
        self.isSample = isSample
    }
}

public struct AppDoctorResult: Codable, Sendable, Hashable {
    public var appName: String
    public var bundleIdentifier: String?
    public var appVersion: String?
    public var symptom: Symptom
    public var investigatedAt: Date
    public var checks: [CheckResult]
    public var repairs: [RepairProposal]
    /// Counts used to verify a repair later.
    public var crashCount7d: Int?
    public var hangCount7d: Int?
    public var lastReportDate: Date?
    /// Redacted log excerpts; excluded from exports unless the user opts in.
    public var logExcerpts: [LogEntrySummary]

    public var overallStatus: CheckStatus { CheckStatus.rollUp(checks.map(\.status)) }
}
