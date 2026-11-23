import Foundation

/// A single raw value from a collector: either a value with its source, or an explicit
/// reason it could not be read. Collectors never invent a value to fill a gap.
public enum Reading<T: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    case value(T, source: DataSource)
    case unavailable(reason: String)

    public var value: T? {
        if case let .value(v, _) = self { return v }
        return nil
    }

    public var source: DataSource? {
        if case let .value(_, s) = self { return s }
        return nil
    }

    public var unavailableReason: String? {
        if case let .unavailable(r) = self { return r }
        return nil
    }

    public static var notCollected: Reading<T> { .unavailable(reason: "Not collected.") }
}

// MARK: - Battery

public struct BatterySnapshot: Codable, Sendable, Equatable {
    public var hasBattery: Bool
    public var cycleCount: Reading<Int>
    public var designCapacityMAh: Reading<Int>
    /// Present full-charge capacity in mAh (IORegistry raw value).
    public var fullChargeCapacityMAh: Reading<Int>
    /// Percentage that macOS itself reports as "Maximum Capacity", when exposed.
    public var systemMaximumCapacityPercent: Reading<Int>
    /// Condition string reported by macOS, e.g. "Good", "Service Recommended".
    public var condition: Reading<String>
    public var chargePercent: Reading<Int>
    public var isCharging: Reading<Bool>
    public var externalPowerConnected: Reading<Bool>
    public var adapterWatts: Reading<Int>
    public var adapterName: Reading<String>

    public init(hasBattery: Bool,
                cycleCount: Reading<Int> = .notCollected,
                designCapacityMAh: Reading<Int> = .notCollected,
                fullChargeCapacityMAh: Reading<Int> = .notCollected,
                systemMaximumCapacityPercent: Reading<Int> = .notCollected,
                condition: Reading<String> = .notCollected,
                chargePercent: Reading<Int> = .notCollected,
                isCharging: Reading<Bool> = .notCollected,
                externalPowerConnected: Reading<Bool> = .notCollected,
                adapterWatts: Reading<Int> = .notCollected,
                adapterName: Reading<String> = .notCollected) {
        self.hasBattery = hasBattery
        self.cycleCount = cycleCount
        self.designCapacityMAh = designCapacityMAh
        self.fullChargeCapacityMAh = fullChargeCapacityMAh
        self.systemMaximumCapacityPercent = systemMaximumCapacityPercent
        self.condition = condition
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.externalPowerConnected = externalPowerConnected
        self.adapterWatts = adapterWatts
        self.adapterName = adapterName
    }
}

// MARK: - Hardware

public struct HardwareSnapshot: Codable, Sendable, Equatable {
    public var modelIdentifier: Reading<String>
    public var chip: Reading<String>
    public var cpuArchitecture: Reading<String>
    public var performanceCores: Reading<Int>
    public var efficiencyCores: Reading<Int>
    public var totalCores: Reading<Int>
    public var gpuName: Reading<String>
    public var gpuCores: Reading<Int>
    public var memoryBytes: Reading<Int64>
    public var macOSVersion: Reading<String>
    public var macOSBuild: Reading<String>
    public var uptimeSeconds: Reading<Double>
    public var rosettaInstalled: Reading<Bool>
    /// Only collected when the user opts in. Never stored in history.
    public var serialNumber: Reading<String>

    public init(modelIdentifier: Reading<String> = .notCollected, chip: Reading<String> = .notCollected,
                cpuArchitecture: Reading<String> = .notCollected,
                performanceCores: Reading<Int> = .notCollected, efficiencyCores: Reading<Int> = .notCollected,
                totalCores: Reading<Int> = .notCollected, gpuName: Reading<String> = .notCollected,
                gpuCores: Reading<Int> = .notCollected, memoryBytes: Reading<Int64> = .notCollected,
                macOSVersion: Reading<String> = .notCollected, macOSBuild: Reading<String> = .notCollected,
                uptimeSeconds: Reading<Double> = .notCollected, rosettaInstalled: Reading<Bool> = .notCollected,
                serialNumber: Reading<String> = .unavailable(reason: "Not collected (identifiers are off).")) {
        self.modelIdentifier = modelIdentifier
        self.chip = chip
        self.cpuArchitecture = cpuArchitecture
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.totalCores = totalCores
        self.gpuName = gpuName
        self.gpuCores = gpuCores
        self.memoryBytes = memoryBytes
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.uptimeSeconds = uptimeSeconds
        self.rosettaInstalled = rosettaInstalled
        self.serialNumber = serialNumber
    }
}

// MARK: - Performance

public enum MemoryPressure: String, Codable, Sendable {
    case normal, warning, critical

    /// Maps `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical).
    public init?(kernelLevel: Int) {
        switch kernelLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }
}

public struct ProcessSample: Codable, Sendable, Equatable, Hashable {
    /// Short process name only. Command-line arguments are never collected.
    public var name: String
    public var pid: Int32
    public var cpuPercent: Double
    public var residentBytes: Int64

    public init(name: String, pid: Int32, cpuPercent: Double, residentBytes: Int64) {
        self.name = name
        self.pid = pid
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
    }
}

public struct PerformanceSnapshot: Codable, Sendable, Equatable {
    public var sampleWindowSeconds: Double
    /// Whole-machine CPU busy % over the sample window (0–100).
    public var cpuBusyPercent: Reading<Double>
    public var loadAverage1m: Reading<Double>
    public var logicalCores: Reading<Int>
    public var memoryTotalBytes: Reading<Int64>
    public var memoryUsedBytes: Reading<Int64>
    public var memoryCompressedBytes: Reading<Int64>
    public var memoryPressure: Reading<MemoryPressure>
    public var swapUsedBytes: Reading<Int64>
    public var swapTotalBytes: Reading<Int64>
    /// Busiest processes visible to this user during the window.
    public var topProcesses: Reading<[ProcessSample]>

    public init(sampleWindowSeconds: Double, cpuBusyPercent: Reading<Double> = .notCollected,
                loadAverage1m: Reading<Double> = .notCollected, logicalCores: Reading<Int> = .notCollected,
                memoryTotalBytes: Reading<Int64> = .notCollected, memoryUsedBytes: Reading<Int64> = .notCollected,
                memoryCompressedBytes: Reading<Int64> = .notCollected,
                memoryPressure: Reading<MemoryPressure> = .notCollected,
                swapUsedBytes: Reading<Int64> = .notCollected, swapTotalBytes: Reading<Int64> = .notCollected,
                topProcesses: Reading<[ProcessSample]> = .notCollected) {
        self.sampleWindowSeconds = sampleWindowSeconds
        self.cpuBusyPercent = cpuBusyPercent
        self.loadAverage1m = loadAverage1m
        self.logicalCores = logicalCores
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryCompressedBytes = memoryCompressedBytes
        self.memoryPressure = memoryPressure
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.topProcesses = topProcesses
    }
}

// MARK: - Thermals

/// Mirrors `ProcessInfo.ThermalState`, the documented thermal indicator on macOS.
public enum ThermalPressure: String, Codable, Sendable {
    case nominal, fair, serious, critical
}

public struct ThermalSnapshot: Codable, Sendable, Equatable {
    public var thermalState: Reading<ThermalPressure>
    public var lowPowerMode: Reading<Bool>
    public var modelIdentifier: Reading<String>

    public init(thermalState: Reading<ThermalPressure> = .notCollected,
                lowPowerMode: Reading<Bool> = .notCollected,
                modelIdentifier: Reading<String> = .notCollected) {
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
        self.modelIdentifier = modelIdentifier
    }
}

// MARK: - Network

public struct ProbeResult: Codable, Sendable, Equatable, Hashable {
    public var target: String
    public var succeeded: Bool
    public var durationMs: Double?
    public var detail: String

    public init(target: String, succeeded: Bool, durationMs: Double?, detail: String) {
        self.target = target
        self.succeeded = succeeded
        self.durationMs = durationMs
        self.detail = detail
    }
}

public struct NetworkSnapshot: Codable, Sendable, Equatable {
    /// "satisfied", "unsatisfied" or "requiresConnection".
    public var pathStatus: Reading<String>
    /// Interface kinds in use, e.g. ["wifi"]. Network names (SSIDs) are never collected.
    public var interfaceTypes: Reading<[String]>
    public var isExpensive: Reading<Bool>
    public var isConstrained: Reading<Bool>
    public var dnsProbes: Reading<[ProbeResult]>
    public var httpsProbes: Reading<[ProbeResult]>
    /// True when the captive-portal style check got an unexpected body (e.g. a hotel login page).
    public var captivePortalSuspected: Reading<Bool>

    public init(pathStatus: Reading<String> = .notCollected, interfaceTypes: Reading<[String]> = .notCollected,
                isExpensive: Reading<Bool> = .notCollected, isConstrained: Reading<Bool> = .notCollected,
                dnsProbes: Reading<[ProbeResult]> = .notCollected, httpsProbes: Reading<[ProbeResult]> = .notCollected,
                captivePortalSuspected: Reading<Bool> = .notCollected) {
        self.pathStatus = pathStatus
        self.interfaceTypes = interfaceTypes
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.dnsProbes = dnsProbes
        self.httpsProbes = httpsProbes
        self.captivePortalSuspected = captivePortalSuspected
    }
}

// MARK: - Storage

public struct VolumeInfo: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var isRoot: Bool
    public var isInternal: Bool?
    public var isReadOnly: Bool?
    public var format: String?
    public var totalBytes: Int64?
    public var availableBytes: Int64?
    /// What macOS considers available for important data (includes purgeable space).
    public var availableForImportantUsageBytes: Int64?

    public init(name: String, isRoot: Bool, isInternal: Bool?, isReadOnly: Bool?, format: String?,
                totalBytes: Int64?, availableBytes: Int64?, availableForImportantUsageBytes: Int64?) {
        self.name = name
        self.isRoot = isRoot
        self.isInternal = isInternal
        self.isReadOnly = isReadOnly
        self.format = format
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes
    }
}

public struct StorageSnapshot: Codable, Sendable, Equatable {
    public var volumes: Reading<[VolumeInfo]>
    /// Drive self-reported status from `diskutil info` ("Verified", "Not Supported", "Failing").
    public var smartStatus: Reading<String>
    public var isSolidState: Reading<Bool>

    public init(volumes: Reading<[VolumeInfo]> = .notCollected, smartStatus: Reading<String> = .notCollected,
                isSolidState: Reading<Bool> = .notCollected) {
        self.volumes = volumes
        self.smartStatus = smartStatus
        self.isSolidState = isSolidState
    }

    public var rootVolume: VolumeInfo? { volumes.value?.first { $0.isRoot } }
}
