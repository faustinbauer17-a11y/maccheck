import Foundation

/// Platform hooks App Doctor needs. Native in MacCheckMac; sample/fake versions for tests and previews.
public struct AppDoctorSources: Sendable {
    public var listApps: @Sendable () async -> [AppListing]
    public var inspectApp: @Sendable (_ path: String) async throws -> AppInfo
    /// Parsed, recent diagnostic reports for this user (all apps; App Doctor filters).
    public var diagnosticReports: @Sendable () async -> Reading<[CrashReportSummary]>
    public var recentLogs: @Sendable (_ app: AppInfo) async -> Reading<[LogEntrySummary]>
    public var savedStateExists: @Sendable (_ bundleIdentifier: String) -> Bool?
    public var isSample: Bool

    public init(listApps: @escaping @Sendable () async -> [AppListing],
                inspectApp: @escaping @Sendable (String) async throws -> AppInfo,
                diagnosticReports: @escaping @Sendable () async -> Reading<[CrashReportSummary]>,
                recentLogs: @escaping @Sendable (AppInfo) async -> Reading<[LogEntrySummary]>,
                savedStateExists: @escaping @Sendable (String) -> Bool?,
                isSample: Bool) {
        self.listApps = listApps
        self.inspectApp = inspectApp
        self.diagnosticReports = diagnosticReports
        self.recentLogs = recentLogs
        self.savedStateExists = savedStateExists
        self.isSample = isSample
    }
}

public enum AppDoctorStep: String, Sendable, CaseIterable {
    case readingApp = "Reading the app's details"
    case reports = "Looking for crash and hang reports"
    case logs = "Reading recent errors from the system log"
    case system = "Checking memory, disk and thermal state"
    case analysing = "Putting it together"
}

/// Runs one investigation with bounded steps. Each step degrades to "unavailable" instead of failing the whole run.
public struct AppDoctorRunner: Sendable {
    public var sources: AppDoctorSources
    public var collectors: CollectorSet

    public init(sources: AppDoctorSources, collectors: CollectorSet) {
        self.sources = sources
        self.collectors = collectors
    }

    public func investigate(appPath: String, symptom: Symptom, note: String? = nil,
                            options: CollectionOptions = .standard,
                            onStep: @escaping @Sendable (AppDoctorStep) -> Void = { _ in }) async throws -> ScanReport {
        let created = Date()
        let timeout = options.perCheckTimeoutSeconds
        onStep(.readingApp)
        let inspect = sources.inspectApp
        let app = try await withDeadline(seconds: timeout) { try await inspect(appPath) }

        try Task.checkCancellation()
        onStep(.reports)
        let reportsFn = sources.diagnosticReports
        let reports: Reading<[CrashReportSummary]>
        do { reports = try await withDeadline(seconds: timeout) { await reportsFn() } }
        catch is CancellationError { throw CancellationError() }
        catch { reports = .unavailable(reason: "Reading reports took too long or failed: \(error)") }

        try Task.checkCancellation()
        onStep(.logs)
        let logsFn = sources.recentLogs
        let logs: Reading<[LogEntrySummary]>
        do { logs = try await withDeadline(seconds: timeout) { await logsFn(app) } }
        catch is CancellationError { throw CancellationError() }
        catch { logs = .unavailable(reason: "Reading the log took too long or failed: \(error)") }

        try Task.checkCancellation()
        onStep(.system)
        let c = collectors
        var quick = options
        quick.sampleWindowSeconds = min(options.sampleWindowSeconds, 1.0)
        let q = quick
        let perf = try? await withDeadline(seconds: timeout) { try await c.performance.collect(q) }
        let storage = try? await withDeadline(seconds: timeout) { try await c.storage.collect(q) }
        let thermals = try? await withDeadline(seconds: timeout) { try await c.thermals.collect(q) }
        let hw = try? await withDeadline(seconds: timeout) { try await c.hardware.collect(q) }
        let saved = app.bundleIdentifier.flatMap { RepairProposal.isSafeBundleIdentifier($0) ? sources.savedStateExists($0) : nil }

        try Task.checkCancellation()
        onStep(.analysing)
        let input = AppDoctorInput(app: app, symptom: symptom, userNote: note, reports: reports, logs: logs,
                                   macOSVersion: hw?.macOSVersion.value, rosettaInstalled: hw?.rosettaInstalled.value,
                                   performance: perf, storage: storage, thermals: thermals,
                                   savedStateExists: saved, now: Date(), isSample: sources.isSample)
        let result = AppDoctorAnalyzer.analyze(input)
        return ScanReport(kind: .appDoctor, createdAt: created, finishedAt: Date(), appVersion: MacCheckInfo.version,
                          device: hw.map(DeviceSummary.from), results: [], appDoctor: result,
                          isSampleData: sources.isSample || collectors.isSample)
    }

    /// Reports for one app only (used when verifying a repair).
    public func reports(for app: AppInfo) async -> [CrashReportSummary] {
        let all = await sources.diagnosticReports().value ?? []
        return all.filter { DiagnosticReportParser.matches($0, bundleIdentifier: app.bundleIdentifier,
                                                           executableName: app.executableName, appName: app.name) }
    }
}

extension SampleData {
    public static let apps: [AppListing] = [
        AppListing(name: "Photos", path: "/System/Applications/Photos.app", bundleIdentifier: "com.apple.Photos", isRunning: true),
        AppListing(name: "Notes Pro", path: "/Applications/Notes Pro.app", bundleIdentifier: "com.example.notespro", isRunning: false),
        AppListing(name: "Zoom", path: "/Applications/zoom.us.app", bundleIdentifier: "us.zoom.xos", isRunning: false),
        AppListing(name: "Legacy Scanner", path: "/Users/Shared/Legacy Scanner.app", bundleIdentifier: "com.example.scanner", isRunning: false),
    ]

    static func sampleApp(_ path: String) -> AppInfo {
        let s = DataSource.sample
        let listing = apps.first { $0.path == path } ?? apps[1]
        var app = AppInfo(name: listing.name, path: listing.path, bundleIdentifier: listing.bundleIdentifier,
                          executableName: listing.name, version: "3.2.1", build: "321", minimumSystemVersion: "13.0",
                          architectures: .value([.arm64, .x86_64], source: s),
                          signature: .value(.valid(notarized: true, teamIdentifier: "SAMPLE1234", isAppleSigned: false), source: s),
                          isQuarantined: .value(false, source: s), isTranslocated: .value(false, source: s),
                          isFromAppStore: .value(false, source: s), isRunning: .value(listing.isRunning, source: s))
        if listing.name == "Legacy Scanner" {
            app.architectures = .value([.x86_64], source: s)
            app.signature = .value(.valid(notarized: false, teamIdentifier: "SAMPLE9876", isAppleSigned: false), source: s)
        }
        if listing.path.hasPrefix("/System/") {
            app.signature = .value(.valid(notarized: nil, teamIdentifier: nil, isAppleSigned: true), source: s)
        }
        return app
    }

    static func sampleReports(now: Date = Date()) -> [CrashReportSummary] {
        func ago(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
        return [
            CrashReportSummary(fileName: "Notes Pro-sample-1.ips", date: ago(5), kind: .crash, processName: "Notes Pro",
                               bundleIdentifier: "com.example.notespro", appVersion: "3.2.1", osVersion: "macOS 15.6",
                               exceptionType: "EXC_BAD_ACCESS", signal: "SIGSEGV", terminationReason: "SIGNAL: Segmentation fault: 11"),
            CrashReportSummary(fileName: "Notes Pro-sample-2.ips", date: ago(30), kind: .crash, processName: "Notes Pro",
                               bundleIdentifier: "com.example.notespro", appVersion: "3.2.1", osVersion: "macOS 15.6",
                               exceptionType: "EXC_BAD_ACCESS", signal: "SIGSEGV", terminationReason: "SIGNAL: Segmentation fault: 11"),
            CrashReportSummary(fileName: "Notes Pro-sample-3.ips", date: ago(70), kind: .crash, processName: "Notes Pro",
                               bundleIdentifier: "com.example.notespro", appVersion: "3.1.0", osVersion: "macOS 15.6",
                               exceptionType: "EXC_BAD_ACCESS", signal: "SIGSEGV", terminationReason: "SIGNAL: Segmentation fault: 11"),
            CrashReportSummary(fileName: "Photos-sample.hang", date: ago(20), kind: .hang, processName: "Photos",
                               bundleIdentifier: "com.apple.Photos"),
        ]
    }

    /// Sample App Doctor sources: clearly fake apps and reports.
    public static func appDoctorSources() -> AppDoctorSources {
        AppDoctorSources(
            listApps: { apps },
            inspectApp: { path in
                try await Task.sleep(nanoseconds: 200_000_000)
                return sampleApp(path)
            },
            diagnosticReports: {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return .value(sampleReports(), source: .sample)
            },
            recentLogs: { app in
                .value([LogEntrySummary(date: Date().addingTimeInterval(-600), level: "Error", subsystem: app.bundleIdentifier,
                                        message: "Sample: failed to open document at /Users/<user>/Documents/<redacted>")],
                       source: .sample)
            },
            savedStateExists: { _ in true },
            isSample: true)
    }
}
