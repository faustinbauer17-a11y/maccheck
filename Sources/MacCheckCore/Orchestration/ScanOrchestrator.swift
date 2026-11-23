import Foundation

public struct CheckOutcome: Sendable {
    public var result: CheckResult
    public var device: DeviceSummary?

    public init(result: CheckResult, device: DeviceSummary? = nil) {
        self.result = result
        self.device = device
    }
}

/// One runnable check: collect + interpret.
public struct DiagnosticCheck: Sendable {
    public var id: String
    public var area: DiagnosticArea?
    public var title: String
    public var run: @Sendable (CollectionOptions) async throws -> CheckOutcome

    public init(id: String, area: DiagnosticArea?, title: String,
                run: @escaping @Sendable (CollectionOptions) async throws -> CheckOutcome) {
        self.id = id
        self.area = area
        self.title = title
        self.run = run
    }
}

extension DeviceSummary {
    public static func from(_ hw: HardwareSnapshot) -> DeviceSummary {
        let id = hw.modelIdentifier.value
        return DeviceSummary(modelName: ModelCatalog.displayName(for: id), modelIdentifier: id,
                             chip: hw.chip.value, memory: hw.memoryBytes.value.map(Fmt.memory),
                             macOS: hw.macOSVersion.value, isFanless: ModelCatalog.isFanless(id))
    }
}

public enum StandardChecks {
    /// The six area checks, in display order.
    public static func make(_ c: CollectorSet) -> [DiagnosticCheck] {
        let sample = c.isSample
        return [
            DiagnosticCheck(id: "hardware", area: .hardware, title: "Reading hardware details") { opts in
                let started = Date()
                let snap = try await c.hardware.collect(opts)
                return CheckOutcome(result: Interpret.hardware(snap, options: opts, started: started, isSample: sample),
                                    device: DeviceSummary.from(snap))
            },
            DiagnosticCheck(id: "battery", area: .battery, title: "Checking battery and power") { opts in
                let started = Date()
                return CheckOutcome(result: Interpret.battery(try await c.battery.collect(opts), started: started, isSample: sample))
            },
            DiagnosticCheck(id: "performance", area: .performance, title: "Sampling CPU and memory") { opts in
                let started = Date()
                return CheckOutcome(result: Interpret.performance(try await c.performance.collect(opts), started: started, isSample: sample))
            },
            DiagnosticCheck(id: "thermals", area: .thermals, title: "Reading thermal state") { opts in
                let started = Date()
                return CheckOutcome(result: Interpret.thermals(try await c.thermals.collect(opts), started: started, isSample: sample))
            },
            DiagnosticCheck(id: "network", area: .network, title: "Testing network") { opts in
                let started = Date()
                return CheckOutcome(result: Interpret.network(try await c.network.collect(opts), started: started, isSample: sample))
            },
            DiagnosticCheck(id: "storage", area: .storage, title: "Checking storage") { opts in
                let started = Date()
                return CheckOutcome(result: Interpret.storage(try await c.storage.collect(opts), options: opts,
                                                              started: started, isSample: sample))
            },
        ]
    }
}

public enum ScanEvent: Sendable {
    case started(id: String, title: String, index: Int, total: Int)
    case finished(CheckResult, index: Int, total: Int)
}

/// Runs checks one after another, each with a hard deadline. A failing or hanging check never
/// stops the scan; cancelling marks the remaining checks as skipped and still returns a report.
public struct ScanOrchestrator: Sendable {
    public var checks: [DiagnosticCheck]
    public var isSample: Bool
    public var appVersion: String

    public init(checks: [DiagnosticCheck], isSample: Bool, appVersion: String = MacCheckInfo.version) {
        self.checks = checks
        self.isSample = isSample
        self.appVersion = appVersion
    }

    public init(collectors: CollectorSet, areas: Set<DiagnosticArea>? = nil) {
        let all = StandardChecks.make(collectors)
        self.init(checks: areas.map { a in all.filter { $0.area.map(a.contains) ?? false } } ?? all,
                  isSample: collectors.isSample)
    }

    public func run(kind: ScanKind = .full, options: CollectionOptions = .standard,
                    onEvent: @escaping @Sendable (ScanEvent) -> Void = { _ in }) async -> ScanReport {
        let created = Date()
        var results: [CheckResult] = []
        var device: DeviceSummary?
        var cancelled = false
        let total = checks.count

        for (index, check) in checks.enumerated() {
            if cancelled || Task.isCancelled {
                cancelled = true
                let r = CheckResult.skipped(id: check.id, area: check.area, title: check.area?.title ?? check.title,
                                            reason: "Scan was cancelled before this check ran.")
                results.append(r)
                onEvent(.finished(r, index: index, total: total))
                continue
            }
            onEvent(.started(id: check.id, title: check.title, index: index, total: total))
            let started = Date()
            let title = check.area?.title ?? check.title
            var result: CheckResult
            do {
                let run = check.run
                let outcome = try await withDeadline(seconds: options.perCheckTimeoutSeconds) { try await run(options) }
                result = outcome.result
                if let d = outcome.device { device = d }
            } catch is CancellationError {
                cancelled = true
                result = .skipped(id: check.id, area: check.area, title: title, reason: "Cancelled while running.")
            } catch let e as TimeoutError {
                result = .failed(id: check.id, area: check.area, title: title, started: started, error: e.description)
            } catch {
                result = .failed(id: check.id, area: check.area, title: title, started: started,
                                 error: String(describing: error))
            }
            if isSample && !result.sources.contains(.sample) { result.sources.insert(.sample, at: 0) }
            results.append(result)
            onEvent(.finished(result, index: index, total: total))
        }

        return ScanReport(kind: kind, createdAt: created, finishedAt: Date(), appVersion: appVersion,
                          device: device, results: results, isSampleData: isSample, wasCancelled: cancelled)
    }
}

public enum MacCheckInfo {
    public static let version = "0.1.0"
    public static let name = "MacCheck"
}
