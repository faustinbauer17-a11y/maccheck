import Foundation

/// Believable sample data for previews, the Windows CLI and "Sample mode" in the app.
/// Every value carries the `.sample` source, and every report built from it has `isSampleData == true`,
/// which the UI and exports display as "SAMPLE DATA — not from this Mac".
public enum SampleData {
    static let src = DataSource.sample

    public static let battery = BatterySnapshot(
        hasBattery: true,
        cycleCount: .value(142, source: src),
        designCapacityMAh: .value(4_560, source: src),
        fullChargeCapacityMAh: .value(4_390, source: src),
        systemMaximumCapacityPercent: .unavailable(reason: "Sample: macOS figure not included."),
        condition: .value("Normal", source: src),
        chargePercent: .value(78, source: src),
        isCharging: .value(false, source: src),
        externalPowerConnected: .value(true, source: src),
        adapterWatts: .value(35, source: src),
        adapterName: .value("35W USB-C Power Adapter", source: src))

    public static let hardware = HardwareSnapshot(
        modelIdentifier: .value("Mac16,12", source: src),
        chip: .value("Apple M4", source: src),
        cpuArchitecture: .value("arm64", source: src),
        performanceCores: .value(4, source: src),
        efficiencyCores: .value(6, source: src),
        totalCores: .value(10, source: src),
        gpuName: .value("Apple M4", source: src),
        gpuCores: .value(8, source: src),
        memoryBytes: .value(16 * 1_073_741_824, source: src),
        macOSVersion: .value("macOS 15.6", source: src),
        macOSBuild: .value("24G84", source: src),
        uptimeSeconds: .value(3 * 86_400 + 4 * 3600, source: src),
        rosettaInstalled: .value(false, source: src))

    public static let performance = PerformanceSnapshot(
        sampleWindowSeconds: 1.5,
        cpuBusyPercent: .value(23, source: src),
        loadAverage1m: .value(2.41, source: src),
        logicalCores: .value(10, source: src),
        memoryTotalBytes: .value(16 * 1_073_741_824, source: src),
        memoryUsedBytes: .value(11 * 1_073_741_824, source: src),
        memoryCompressedBytes: .value(1_800_000_000, source: src),
        memoryPressure: .value(.normal, source: src),
        swapUsedBytes: .value(612_000_000, source: src),
        swapTotalBytes: .value(2_147_483_648, source: src),
        topProcesses: .value([
            ProcessSample(name: "Safari", pid: 812, cpuPercent: 31.5, residentBytes: 1_240_000_000),
            ProcessSample(name: "Photos", pid: 1033, cpuPercent: 18.2, residentBytes: 690_000_000),
            ProcessSample(name: "WindowServer", pid: 155, cpuPercent: 9.7, residentBytes: 410_000_000),
        ], source: src))

    public static let thermals = ThermalSnapshot(
        thermalState: .value(.nominal, source: src),
        lowPowerMode: .value(false, source: src),
        modelIdentifier: .value("Mac16,12", source: src))

    public static let network = NetworkSnapshot(
        pathStatus: .value("satisfied", source: src),
        interfaceTypes: .value(["wifi"], source: src),
        isExpensive: .value(false, source: src),
        isConstrained: .value(false, source: src),
        dnsProbes: .value([ProbeResult(target: "www.apple.com", succeeded: true, durationMs: 24, detail: "2 addresses"),
                           ProbeResult(target: "one.one.one.one", succeeded: true, durationMs: 19, detail: "2 addresses")], source: src),
        httpsProbes: .value([ProbeResult(target: "Apple connectivity check", succeeded: true, durationMs: 88, detail: "HTTP 200"),
                             ProbeResult(target: "Cloudflare", succeeded: true, durationMs: 61, detail: "HTTP 200")], source: src),
        captivePortalSuspected: .value(false, source: src))

    public static let storage = StorageSnapshot(
        volumes: .value([VolumeInfo(name: "Macintosh HD", isRoot: true, isInternal: true, isReadOnly: false, format: "APFS",
                                    totalBytes: 494_384_795_648, availableBytes: 61_000_000_000,
                                    availableForImportantUsageBytes: 74_500_000_000)], source: src),
        smartStatus: .value("Verified", source: src),
        isSolidState: .value(true, source: src))

    /// Sample collectors with a small artificial delay so progress UI can be exercised.
    public static func collectors(delaySeconds: Double = 0.25) -> CollectorSet {
        CollectorSet(
            battery: Fake.returning(battery, name: "Sample battery", delay: delaySeconds),
            hardware: Fake.returning(hardware, name: "Sample hardware", delay: delaySeconds),
            performance: Fake.returning(performance, name: "Sample performance", delay: delaySeconds * 2),
            thermals: Fake.returning(thermals, name: "Sample thermals", delay: delaySeconds),
            network: Fake.returning(network, name: "Sample network", delay: delaySeconds * 2),
            storage: Fake.returning(storage, name: "Sample storage", delay: delaySeconds),
            isSample: true)
    }
}

/// Building blocks for fake collectors (tests, previews, sample mode).
public enum Fake {
    public static func returning<S: Sendable>(_ value: S, name: String = "Fake", delay: Double = 0) -> Collector<S> {
        Collector(name: name) { _ in
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            return value
        }
    }

    public static func failing<S: Sendable>(_ message: String, as: S.Type = S.self) -> Collector<S> {
        Collector(name: "Failing fake") { _ in throw CollectorUnavailableError(message) }
    }

    /// Never returns on its own (sleeps for an hour) — used to test deadlines and cancellation.
    public static func hanging<S: Sendable>(as: S.Type = S.self) -> Collector<S> {
        Collector(name: "Hanging fake") { _ in
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            throw CollectorUnavailableError("unreachable")
        }
    }

    /// A blocking fake that ignores cancellation (simulates a stuck system call).
    public static func blocking<S: Sendable>(seconds: Double, then value: S) -> Collector<S> {
        Collector(name: "Blocking fake") { _ in blockingSleep(seconds, then: value) }
    }

    private static func blockingSleep<S>(_ seconds: Double, then value: S) -> S {
        Thread.sleep(forTimeInterval: seconds)
        return value
    }
}
