import Foundation

/// One ring gauge on the home screen. Built only from measured snapshot values; when a value can't
/// be read, `fraction` is nil and `value` is "—", with the reason in `detail`. Nothing is estimated
/// to fill a gap, and there is no temperature or clock-speed gauge because macOS doesn't expose them
/// through a documented interface.
public struct LiveGauge: Sendable, Equatable, Identifiable {
    public enum Level: String, Sendable {
        case good, attention, problem, neutral
    }

    public var id: String
    public var title: String
    /// Big number or word in the middle of the ring, e.g. "23" or "Normal".
    public var value: String
    /// Small text under the value, e.g. "% busy".
    public var unit: String
    /// How full the ring is, 0...1. Nil when the value is unavailable.
    public var fraction: Double?
    public var level: Level
    /// What the number means and where it came from. Used for tooltips and VoiceOver.
    public var detail: String
    /// The test that explains this gauge in depth.
    public var area: DiagnosticArea

    public init(id: String, title: String, value: String, unit: String, fraction: Double?, level: Level,
                detail: String, area: DiagnosticArea) {
        self.id = id
        self.title = title
        self.value = value
        self.unit = unit
        self.fraction = fraction.map { min(max($0, 0), 1) }
        self.level = level
        self.detail = detail
        self.area = area
    }

    static func unavailable(id: String, title: String, unit: String, reason: String, area: DiagnosticArea) -> LiveGauge {
        LiveGauge(id: id, title: title, value: "—", unit: unit, fraction: nil, level: .neutral,
                  detail: "\(title): not available. \(reason)", area: area)
    }
}

/// A quick, local, read-only look at this Mac for the home screen: device details plus five gauges.
/// No network access is involved.
public struct LiveOverview: Sendable, Equatable {
    public var takenAt: Date
    public var isSample: Bool
    public var device: DeviceSummary?
    public var macOSBuild: String?
    /// e.g. "16 GB"
    public var memoryText: String?
    /// Startup disk capacity, e.g. "512 GB"
    public var storageText: String?
    public var gauges: [LiveGauge]

    public init(takenAt: Date, isSample: Bool, device: DeviceSummary?, macOSBuild: String?,
                memoryText: String?, storageText: String?, gauges: [LiveGauge]) {
        self.takenAt = takenAt
        self.isSample = isSample
        self.device = device
        self.macOSBuild = macOSBuild
        self.memoryText = memoryText
        self.storageText = storageText
        self.gauges = gauges
    }

    /// Builds the overview. A nil snapshot means that collector failed or timed out.
    public static func make(battery: BatterySnapshot?, hardware: HardwareSnapshot?, performance: PerformanceSnapshot?,
                            thermals: ThermalSnapshot?, storage: StorageSnapshot?,
                            isSample: Bool, takenAt: Date = Date()) -> LiveOverview {
        let root = storage?.rootVolume
        return LiveOverview(
            takenAt: takenAt,
            isSample: isSample,
            device: hardware.map(DeviceSummary.from),
            macOSBuild: hardware?.macOSBuild.value,
            memoryText: (hardware?.memoryBytes.value ?? performance?.memoryTotalBytes.value).map(Fmt.memory),
            storageText: root?.totalBytes.map(Fmt.bytes),
            gauges: [cpuGauge(performance), memoryGauge(performance), storageGauge(storage),
                     batteryGauge(battery), thermalGauge(thermals)])
    }

    // MARK: Gauges

    static func cpuGauge(_ p: PerformanceSnapshot?) -> LiveGauge {
        let title = "Processor", unit = "% busy"
        guard let p else { return .unavailable(id: "cpu", title: title, unit: unit, reason: "The CPU sample didn't finish.", area: .performance) }
        guard let busy = p.cpuBusyPercent.value else {
            return .unavailable(id: "cpu", title: title, unit: unit,
                                reason: p.cpuBusyPercent.unavailableReason ?? "", area: .performance)
        }
        let window = String(format: "%.1f", p.sampleWindowSeconds)
        return LiveGauge(id: "cpu", title: title, value: String(Int(busy.rounded())), unit: unit, fraction: busy / 100,
                         level: busy >= 85 ? .attention : .good,
                         detail: "Processor: \(Int(busy.rounded()))% busy, measured over \(window) seconds. Short spikes are normal.",
                         area: .performance)
    }

    static func memoryGauge(_ p: PerformanceSnapshot?) -> LiveGauge {
        let title = "Memory", unit = "% used"
        guard let p else { return .unavailable(id: "memory", title: title, unit: unit, reason: "Memory couldn't be read.", area: .performance) }
        guard let used = p.memoryUsedBytes.value, let total = p.memoryTotalBytes.value, total > 0 else {
            return .unavailable(id: "memory", title: title, unit: unit,
                                reason: p.memoryUsedBytes.unavailableReason ?? p.memoryTotalBytes.unavailableReason ?? "",
                                area: .performance)
        }
        let fraction = Double(used) / Double(total)
        let level: LiveGauge.Level
        let pressureText: String
        switch p.memoryPressure.value {
        case .normal?: level = .good; pressureText = "Memory pressure is normal."
        case .warning?: level = .attention; pressureText = "Memory pressure is elevated."
        case .critical?: level = .problem; pressureText = "Memory pressure is critical."
        case nil: level = .neutral; pressureText = "Memory pressure wasn't available."
        }
        return LiveGauge(id: "memory", title: title, value: String(Int((fraction * 100).rounded())), unit: unit,
                         fraction: fraction, level: level,
                         detail: "Memory: \(Fmt.memory(used)) of \(Fmt.memory(total)) in use. \(pressureText) macOS uses spare memory as cache, so a high number alone is fine.",
                         area: .performance)
    }

    static func storageGauge(_ s: StorageSnapshot?) -> LiveGauge {
        let title = "Storage", unit = "free"
        guard let s else { return .unavailable(id: "storage", title: title, unit: unit, reason: "Volumes couldn't be read.", area: .storage) }
        guard let root = s.rootVolume, let total = root.totalBytes, total > 0,
              let free = root.availableForImportantUsageBytes ?? root.availableBytes else {
            return .unavailable(id: "storage", title: title, unit: unit,
                                reason: s.volumes.unavailableReason ?? "The startup disk wasn't reported with its capacity.",
                                area: .storage)
        }
        let pct = Double(free) / Double(total) * 100
        let gb = Double(free) / 1e9
        // Same thresholds as the Storage test.
        let level: LiveGauge.Level = (gb < 5 || pct < 2) ? .problem : (gb < 15 || pct < 5) ? .attention : .good
        let parts = Fmt.bytes(free).split(separator: " ", maxSplits: 1).map(String.init)
        return LiveGauge(id: "storage", title: title, value: parts.first ?? "—",
                         unit: parts.count > 1 ? "\(parts[1]) free" : unit,
                         fraction: 1 - Double(free) / Double(total), level: level,
                         detail: "Startup disk: \(Fmt.bytes(free)) free of \(Fmt.bytes(total)) (\(Int(pct.rounded()))% free). The ring shows space in use.",
                         area: .storage)
    }

    static func batteryGauge(_ b: BatterySnapshot?) -> LiveGauge {
        let title = "Battery", unit = "% health"
        guard let b else { return .unavailable(id: "battery", title: title, unit: unit, reason: "The battery couldn't be read.", area: .battery) }
        guard b.hasBattery else {
            return LiveGauge(id: "battery", title: title, value: "None", unit: "no battery", fraction: nil, level: .neutral,
                             detail: "This Mac has no built-in battery.", area: .battery)
        }
        let capacity: Double
        let how: String
        if let sys = b.systemMaximumCapacityPercent.value {
            capacity = Double(sys)
            how = "as reported by macOS"
        } else if let full = b.fullChargeCapacityMAh.value, let design = b.designCapacityMAh.value, design > 0 {
            capacity = min(Double(full) / Double(design) * 100, 100)
            how = "estimated from the battery's full-charge and design capacity"
        } else {
            return .unavailable(id: "battery", title: title, unit: unit,
                                reason: "macOS didn't expose the values needed for maximum capacity.", area: .battery)
        }
        let condition = b.condition.value
        let serviceFlag = condition.map { $0.localizedCaseInsensitiveContains("service") } ?? false
        let level: LiveGauge.Level = serviceFlag ? .problem : capacity < 80 ? .attention : .good
        var detail = "Battery maximum capacity: \(Int(capacity.rounded()))%, \(how)."
        if let condition { detail += " Condition: \(condition)." }
        if let charge = b.chargePercent.value { detail += " Currently charged to \(charge)%." }
        return LiveGauge(id: "battery", title: title, value: String(Int(capacity.rounded())), unit: unit,
                         fraction: capacity / 100, level: level, detail: detail, area: .battery)
    }

    static func thermalGauge(_ t: ThermalSnapshot?) -> LiveGauge {
        let title = "Thermal", unit = "pressure"
        guard let t else { return .unavailable(id: "thermal", title: title, unit: unit, reason: "The thermal state couldn't be read.", area: .thermals) }
        guard let state = t.thermalState.value else {
            return .unavailable(id: "thermal", title: title, unit: unit, reason: t.thermalState.unavailableReason ?? "", area: .thermals)
        }
        let (word, fraction, level): (String, Double, LiveGauge.Level) = {
            switch state {
            case .nominal: return ("Normal", 0.25, .good)
            case .fair: return ("Fair", 0.5, .good)
            case .serious: return ("Serious", 0.75, .attention)
            case .critical: return ("Critical", 1, .problem)
            }
        }()
        return LiveGauge(id: "thermal", title: title, value: word, unit: unit, fraction: fraction, level: level,
                         detail: "Thermal pressure reported by macOS: \(word). This is macOS's own heat indicator, not a temperature reading.",
                         area: .thermals)
    }
}
