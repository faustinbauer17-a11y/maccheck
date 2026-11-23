import Foundation

/// Turns raw snapshots into user-facing results. Pure functions: no I/O, fully unit-tested.
///
/// Thresholds are deliberately conservative and documented in docs/SUPPORTED-CHECKS.md.
public enum Interpret {

    // MARK: Battery

    /// Apple rates current Mac notebook batteries for 1000 full cycles.
    public static let ratedCycles = 1000

    public static func battery(_ s: BatterySnapshot, started: Date = Date(), isSample: Bool = false) -> CheckResult {
        var b = ResultBuilder(id: "battery", area: .battery, title: DiagnosticArea.battery.title, started: started, isSample: isSample)
        b.limit("MacCheck does not estimate remaining battery time: it depends on what you are doing.")
        b.limit("Battery temperature and per-cell data are not shown; there is no documented public API for them.")

        guard s.hasBattery else {
            b.finding("battery.none", .unavailable, "No internal battery found",
                      "macOS reports no internal battery. That is expected on desktop Macs.")
            return b.build(summary: "No internal battery found.")
        }

        b.add(s.chargePercent, key: "battery.charge", label: "Current charge", numeric: { Double($0) }) { "\($0)%" }
        b.add(s.externalPowerConnected, key: "battery.external", label: "Power source") { $0 ? "Power adapter" : "Battery" }
        b.add(s.isCharging, key: "battery.charging", label: "Charging") { $0 ? "Yes" : "No" }
        b.add(s.cycleCount, key: "battery.cycles", label: "Cycle count", numeric: { Double($0) }) { "\($0)" }
        b.add(s.designCapacityMAh, key: "battery.design", label: "Design capacity", reportUnavailable: false,
              numeric: { Double($0) }) { "\($0) mAh" }
        b.add(s.fullChargeCapacityMAh, key: "battery.fullCharge", label: "Full-charge capacity", reportUnavailable: false,
              numeric: { Double($0) }) { "\($0) mAh" }
        b.add(s.condition, key: "battery.condition", label: "Condition (macOS)", evidence: .reportedBySystem) { $0 }
        b.add(s.adapterWatts, key: "battery.adapterWatts", label: "Adapter", reportUnavailable: false,
              numeric: { Double($0) }) { "\($0) W" }
        b.add(s.adapterName, key: "battery.adapterName", label: "Adapter name", reportUnavailable: false) { $0 }

        // Maximum capacity: prefer the figure macOS itself reports; otherwise derive and say so.
        var capacity: Double?
        if let sys = s.systemMaximumCapacityPercent.value, let src = s.systemMaximumCapacityPercent.source {
            capacity = Double(sys)
            b.add(.value(sys, source: src), key: "battery.maxCapacity", label: "Maximum capacity",
                  evidence: .reportedBySystem, numeric: { Double($0) }) { "\($0)%" }
        } else if let full = s.fullChargeCapacityMAh.value, let design = s.designCapacityMAh.value, design > 0 {
            let pct = min(Double(full) / Double(design) * 100, 100)
            capacity = pct
            b.addDerived(key: "battery.maxCapacity", label: "Maximum capacity (estimated)", display: Fmt.percent(pct), numeric: pct)
            b.finding("battery.capacity.derived", .fact, "Capacity is an estimate",
                      "Calculated from the battery's raw full-charge and design capacity. System Settings → Battery may show a slightly different number.",
                      evidence: .derived)
        } else {
            b.finding("battery.capacity.unavailable", .unavailable, "Maximum capacity: not available",
                      "macOS did not expose the values needed to work out maximum capacity on this Mac.")
        }

        if let pct = capacity, pct < 80 {
            b.finding("battery.capacity.low", .warning, "Battery holds less than 80% of its original charge",
                      "Maximum capacity is about \(Int(pct.rounded()))%. Batteries wear with use; Apple designs Mac notebook batteries to keep up to 80% after \(ratedCycles) cycles. Expect shorter time on battery.",
                      evidence: s.systemMaximumCapacityPercent.value != nil ? .reportedBySystem : .derived,
                      advice: ["Check the condition shown in System Settings → Battery → Battery Health (ⓘ).",
                               "If battery life no longer meets your needs, Apple or an authorised provider can replace it."],
                      links: [SettingsLinks.battery])
        }

        if let cycles = s.cycleCount.value, cycles >= ratedCycles {
            b.finding("battery.cycles.high", .warning, "Battery has passed its rated cycle count",
                      "\(cycles) cycles, rated for \(ratedCycles). This is not a fault in itself, but capacity usually declines from here.",
                      links: [SettingsLinks.battery])
        }

        if let cond = s.condition.value {
            let normalized = cond.lowercased()
            let bad = ["service", "check battery", "replace", "poor"]
            if bad.contains(where: { normalized.contains($0) }) {
                b.finding("battery.condition.service", .problem, "macOS recommends battery service",
                          "macOS reports the battery condition as \"\(cond)\". This is macOS's own assessment.",
                          evidence: .reportedBySystem,
                          advice: ["Back up your Mac, then contact Apple Support or an authorised service provider.",
                                   "Until then, keep the Mac on power for demanding work."],
                          links: [SettingsLinks.battery])
            }
        }

        if s.externalPowerConnected.value == true, s.isCharging.value == false, let charge = s.chargePercent.value, charge < 95 {
            b.finding("battery.notCharging", .possibleExplanation, "Connected to power but not charging",
                      "This is usually intentional: Optimised Battery Charging or a charge limit can pause charging around 80% to reduce wear. A weak adapter or cable can also cause it.",
                      evidence: .inferred, confidence: .medium,
                      advice: ["If it stays this way for hours, try another cable or adapter."],
                      links: [SettingsLinks.battery])
        }

        if s.isCharging.value == true, let w = s.adapterWatts.value, w > 0, w < 30 {
            b.finding("battery.lowWattAdapter", .fact, "Low-wattage power adapter",
                      "The connected adapter reports \(w) W. Charging will be slower, especially while the Mac is busy.")
        }

        return b.build()
    }

    // MARK: Hardware

    public static func hardware(_ s: HardwareSnapshot, options: CollectionOptions = .standard,
                                started: Date = Date(), isSample: Bool = false) -> CheckResult {
        var b = ResultBuilder(id: "hardware", area: .hardware, title: DiagnosticArea.hardware.title, started: started, isSample: isSample)
        let model = s.modelIdentifier.value
        if let id = model, let src = s.modelIdentifier.source {
            b.add(.value(ModelCatalog.displayName(for: id), source: src), key: "hw.model", label: "Model") { $0 }
        }
        b.add(s.modelIdentifier, key: "hw.modelId", label: "Model identifier") { $0 }
        b.add(s.chip, key: "hw.chip", label: "Chip") { $0 }

        if let total = s.totalCores.value, let src = s.totalCores.source {
            var text = "\(total)"
            if let p = s.performanceCores.value, let e = s.efficiencyCores.value { text += " (\(p) performance + \(e) efficiency)" }
            b.add(.value(text, source: src), key: "hw.cpuCores", label: "CPU cores") { $0 }
        } else {
            b.add(s.totalCores, key: "hw.cpuCores", label: "CPU cores") { "\($0)" }
        }
        b.add(s.gpuName, key: "hw.gpu", label: "GPU", reportUnavailable: false) { $0 }
        b.add(s.gpuCores, key: "hw.gpuCores", label: "GPU cores", numeric: { Double($0) }) { "\($0)" }
        b.add(s.memoryBytes, key: "hw.memory", label: "Unified memory", numeric: { Double($0) }) { Fmt.memory($0) }
        b.add(s.macOSVersion, key: "hw.macos", label: "macOS") { $0 }
        b.add(s.macOSBuild, key: "hw.build", label: "macOS build", reportUnavailable: false) { $0 }
        b.add(s.cpuArchitecture, key: "hw.arch", label: "Architecture") { $0 }
        b.add(s.uptimeSeconds, key: "hw.uptime", label: "Time since restart", numeric: { $0 }) { Fmt.duration($0) }
        b.add(s.rosettaInstalled, key: "hw.rosetta", label: "Rosetta 2") { $0 ? "Installed" : "Not installed" }

        if options.includeIdentifiers {
            b.add(s.serialNumber, key: "hw.serial", label: "Serial number", sensitive: true) { $0 }
        }

        if let id = model, ModelCatalog.entry(for: id) == nil {
            b.limit("MacCheck doesn't have a friendly name for \(id); results are still valid.")
        }
        if let arch = s.cpuArchitecture.value, arch != "arm64" {
            b.finding("hw.notAppleSilicon", .fact, "Not an Apple Silicon Mac",
                      "MacCheck is tuned for Apple Silicon. Some checks may report less on this Mac.")
        }
        if let up = s.uptimeSeconds.value, up > 14 * 86_400 {
            b.finding("hw.longUptime", .fact, "Not restarted for \(Int(up / 86_400)) days",
                      "That's fine in general. If apps misbehave, a restart is a safe first step that clears temporary state.")
        }
        b.limit("Serial number and other unique identifiers are left out unless you turn them on in Settings.")
        return b.build(informational: true)
    }

    // MARK: Performance

    public static func performance(_ s: PerformanceSnapshot, started: Date = Date(), isSample: Bool = false) -> CheckResult {
        var b = ResultBuilder(id: "performance", area: .performance, title: DiagnosticArea.performance.title, started: started, isSample: isSample)
        b.limit("A \(String(format: "%.1f", s.sampleWindowSeconds))-second snapshot. A brief spike or a quiet moment can mislead — run it again while the problem is happening.")
        b.limit("Processes owned by macOS or other users may not be listed.")
        b.limit("MacCheck never quits processes or changes what starts at login.")

        b.add(s.cpuBusyPercent, key: "perf.cpu", label: "CPU busy", numeric: { $0 }) { Fmt.percent($0) }
        b.add(s.loadAverage1m, key: "perf.load", label: "Load average (1 min)", reportUnavailable: false,
              numeric: { $0 }) { String(format: "%.2f", $0) }
        b.add(s.memoryPressure, key: "perf.pressure", label: "Memory pressure") { $0.rawValue.capitalized }
        b.add(s.memoryUsedBytes, key: "perf.memUsed", label: "Memory used", numeric: { Double($0) }) { Fmt.memory($0) }
        b.add(s.memoryCompressedBytes, key: "perf.memCompressed", label: "Compressed memory", reportUnavailable: false,
              numeric: { Double($0) }) { Fmt.bytes($0) }
        b.add(s.swapUsedBytes, key: "perf.swap", label: "Swap used", numeric: { Double($0) }) { Fmt.bytes($0) }

        if let cpu = s.cpuBusyPercent.value, cpu >= 85 {
            b.finding("perf.cpu.high", .warning, "The processor was very busy",
                      "CPU was \(Int(cpu))% busy during the sample. Apps may feel slow and the battery drains faster.",
                      advice: ["Check the busiest processes listed below, or open Activity Monitor → CPU."],
                      links: [SettingsLinks.activityMonitor])
        }

        switch s.memoryPressure.value {
        case .warning?:
            b.finding("perf.pressure.warning", .warning, "Memory is under pressure",
                      "macOS reports memory pressure as Warning: it is compressing and swapping memory to keep up. Apps can pause or reload.",
                      advice: ["Close apps or browser tabs you're not using."], links: [SettingsLinks.activityMonitor])
        case .critical?:
            b.finding("perf.pressure.critical", .problem, "Memory pressure is critical",
                      "macOS reports memory pressure as Critical. Expect freezes and apps being closed by the system.",
                      advice: ["Save your work, then close large apps or many browser tabs.",
                               "Activity Monitor → Memory shows which apps use the most."],
                      links: [SettingsLinks.activityMonitor])
        default: break
        }

        if let swap = s.swapUsedBytes.value, let total = s.memoryTotalBytes.value, total > 0 {
            if Double(swap) > Double(total) * 0.5 && (s.memoryPressure.value ?? .normal) != .normal {
                b.finding("perf.swap.heavy", .warning, "Heavy swap use",
                          "\(Fmt.bytes(swap)) of swap with elevated memory pressure: memory demand is higher than this Mac's \(Fmt.memory(total)).")
            } else if swap > 0 {
                b.finding("perf.swap.normal", .fact, "Some swap in use",
                          "\(Fmt.bytes(swap)) of swap. Some swap is normal on macOS and not a problem by itself.")
            }
        }

        if let procs = s.topProcesses.value {
            let top = procs.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5)
            for (i, p) in top.enumerated() {
                b.addDerived(key: "perf.top.\(i)", label: "Busy: \(p.name)",
                             display: "\(Fmt.percent(p.cpuPercent)) CPU · \(Fmt.bytes(p.residentBytes))", numeric: p.cpuPercent)
            }
            if let hog = top.first, hog.cpuPercent >= 80 {
                b.finding("perf.hog", .fact, "\(hog.name) used a lot of CPU",
                          "\(hog.name) used about \(Int(hog.cpuPercent))% of one core during the sample. That can be normal (exporting video, compiling) or a sign the app is stuck.",
                          advice: ["If you're not expecting it, quit and reopen \(hog.name) yourself."])
            }
        } else if let reason = s.topProcesses.unavailableReason {
            b.finding("perf.top.unavailable", .unavailable, "Process list: not available", reason)
        }
        return b.build()
    }

    // MARK: Thermals

    public static func thermals(_ s: ThermalSnapshot, started: Date = Date(), isSample: Bool = false) -> CheckResult {
        var b = ResultBuilder(id: "thermals", area: .thermals, title: DiagnosticArea.thermals.title, started: started, isSample: isSample)

        switch ModelCatalog.isFanless(s.modelIdentifier.value) {
        case true?:
            b.finding("thermal.fanless", .fact, "No fan to report",
                      "This MacBook Air is fanless, so there is no fan speed. Under long heavy loads it lowers performance to stay cool — that is by design, not a fault.")
        case false?:
            b.limit("This Mac has fans, but fan speed isn't exposed through a documented API, so it isn't shown.")
        case nil:
            b.limit("MacCheck doesn't know whether this model has a fan, and doesn't read fan speed.")
        }
        b.limit("Temperatures aren't shown: Apple provides no documented API for sensor temperatures on Apple Silicon.")
        b.limit("The thermal state is a single macOS indicator, not a measured temperature or throttling percentage.")

        b.add(s.thermalState, key: "thermal.state", label: "Thermal state (macOS)", evidence: .reportedBySystem) { $0.rawValue.capitalized }
        b.add(s.lowPowerMode, key: "thermal.lowPower", label: "Low Power Mode") { $0 ? "On" : "Off" }

        switch s.thermalState.value {
        case .fair?:
            b.finding("thermal.fair", .fact, "Slightly elevated thermal state",
                      "macOS reports Fair. Common during heavy work or charging; no action needed.", evidence: .reportedBySystem)
        case .serious?:
            b.finding("thermal.serious", .warning, "The Mac is running hot",
                      "macOS reports a Serious thermal state. Performance is likely being reduced to cool down.",
                      evidence: .reportedBySystem,
                      advice: ["Use it on a hard surface, out of direct sun.", "Pause heavy tasks for a few minutes and check again."])
        case .critical?:
            b.finding("thermal.critical", .problem, "Critical thermal state",
                      "macOS reports a Critical thermal state. The Mac is significantly limiting performance.",
                      evidence: .reportedBySystem,
                      advice: ["Save your work and let the Mac cool down.", "If this happens with light use, contact Apple Support."])
        default: break
        }

        if s.lowPowerMode.value == true {
            b.finding("thermal.lowPower", .possibleExplanation, "Low Power Mode is on",
                      "Low Power Mode lowers performance to save energy. If the Mac feels slow, this may be part of the reason.",
                      evidence: .inferred, confidence: .medium, links: [SettingsLinks.battery])
        }
        return b.build()
    }

    // MARK: Network

    public static func network(_ s: NetworkSnapshot, started: Date = Date(), isSample: Bool = false) -> CheckResult {
        var b = ResultBuilder(id: "network", area: .network, title: DiagnosticArea.network.title, started: started, isSample: isSample)
        b.limit("Results reflect the current network and the test endpoints at this moment; they do not measure bandwidth.")
        b.limit("Wi-Fi network names and passwords are never read.")

        b.add(s.pathStatus, key: "net.status", label: "Connection") { status -> String in
            switch status {
            case "satisfied": return "Connected"
            case "unsatisfied": return "Not connected"
            case "requiresConnection": return "Waiting to connect"
            default: return status
            }
        }
        b.add(s.interfaceTypes, key: "net.interfaces", label: "Using") { types in
            types.isEmpty ? "None" : types.map(Self.interfaceName).joined(separator: ", ")
        }
        b.add(s.isExpensive, key: "net.expensive", label: "Personal Hotspot / metered", reportUnavailable: false) { $0 ? "Yes" : "No" }
        b.add(s.isConstrained, key: "net.constrained", label: "Low Data Mode", reportUnavailable: false) { $0 ? "On" : "Off" }

        let status = s.pathStatus.value
        if status == "unsatisfied" {
            b.finding("net.offline", .problem, "No network connection",
                      "macOS reports no usable network path.",
                      advice: ["Check Wi-Fi is on and connected, or plug in a cable."], links: [SettingsLinks.network])
        } else if status == "requiresConnection" {
            b.finding("net.waiting", .warning, "Network needs a connection step",
                      "macOS says a connection must be established first (for example a VPN on demand).",
                      links: [SettingsLinks.network])
        }

        let online = status == "satisfied"
        var dnsOK = true
        if let dns = s.dnsProbes.value {
            for (i, p) in dns.enumerated() {
                b.addDerived(key: "net.dns.\(i)", label: "DNS: \(p.target)",
                             display: p.succeeded ? (p.durationMs.map(Fmt.ms) ?? "OK") : "Failed — \(p.detail)",
                             numeric: p.durationMs)
            }
            let failures = dns.filter { !$0.succeeded }.count
            if online && !dns.isEmpty && failures == dns.count {
                dnsOK = false
                b.finding("net.dns.fail", .problem, "Names can't be looked up (DNS)",
                          "Connected, but none of the test names resolved. Websites and apps that go online will fail.",
                          advice: ["Turn Wi-Fi off and on, or restart the router.",
                                   "If you set custom DNS servers or use a VPN, try without them."],
                          links: [SettingsLinks.network])
            } else if failures > 0 {
                b.finding("net.dns.partial", .warning, "Some DNS lookups failed",
                          "\(failures) of \(dns.count) test names didn't resolve.")
            } else if let slow = dns.compactMap(\.durationMs).max(), slow > 500 {
                b.finding("net.dns.slow", .warning, "DNS lookups are slow",
                          "The slowest lookup took \(Fmt.ms(slow)). Pages may take a moment before they start loading.")
            }
        } else {
            b.add(s.dnsProbes, key: "net.dns", label: "DNS check") { _ in "" }
        }

        if let probes = s.httpsProbes.value {
            for (i, p) in probes.enumerated() {
                b.addDerived(key: "net.https.\(i)", label: "Reach: \(p.target)",
                             display: p.succeeded ? (p.durationMs.map(Fmt.ms) ?? "OK") : "Failed — \(p.detail)",
                             numeric: p.durationMs)
            }
            let ok = probes.filter(\.succeeded)
            if online && dnsOK && !probes.isEmpty && ok.isEmpty {
                b.finding("net.https.fail", .problem, "Test websites can't be reached",
                          "Names resolve, but secure connections to the test endpoints failed.",
                          advice: ["A firewall, VPN, proxy or network login page could be blocking traffic.",
                                   "Try opening any website in a browser."], links: [SettingsLinks.network])
            } else if let median = Self.median(ok.compactMap(\.durationMs)), median > 800 {
                b.finding("net.https.slow", .warning, "Connections are slow",
                          "Typical response time was \(Fmt.ms(median)) to the test endpoints.")
            }
        } else {
            b.add(s.httpsProbes, key: "net.https", label: "Reachability check") { _ in "" }
        }

        if s.captivePortalSuspected.value == true {
            b.finding("net.captive", .possibleExplanation, "Network login page suspected",
                      "A test page returned unexpected content. Hotel, café and airport Wi-Fi often require signing in first.",
                      evidence: .inferred, confidence: .medium,
                      advice: ["Open a browser — the login page usually appears."])
        }
        if s.isExpensive.value == true {
            b.finding("net.expensive.note", .fact, "On a metered connection",
                      "macOS flags this network as expensive (e.g. a phone's Personal Hotspot). Some apps limit background downloads.")
        }
        return b.build()
    }

    static func interfaceName(_ raw: String) -> String {
        switch raw {
        case "wifi": return "Wi-Fi"
        case "wiredEthernet": return "Ethernet"
        case "cellular": return "Cellular"
        case "loopback": return "Loopback"
        default: return raw.capitalized
        }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    // MARK: Storage

    public static func storage(_ s: StorageSnapshot, options: CollectionOptions = .standard,
                               started: Date = Date(), isSample: Bool = false) -> CheckResult {
        var b = ResultBuilder(id: "storage", area: .storage, title: DiagnosticArea.storage.title, started: started, isSample: isSample)
        b.limit("MacCheck never reads the contents of your files and never deletes anything.")
        b.limit("SSD wear level and remaining lifetime aren't exposed through public APIs for Apple's internal storage.")

        if let volumes = s.volumes.value, let src = s.volumes.source {
            var externalIndex = 0
            for v in volumes {
                let label: String
                if v.isRoot {
                    label = "Startup disk"
                } else if options.includeIdentifiers {
                    label = v.name
                } else {
                    externalIndex += 1
                    label = "Other volume \(externalIndex)"
                }
                let free = v.availableForImportantUsageBytes ?? v.availableBytes
                if let total = v.totalBytes, let free = free {
                    let fmt = v.format.map { " · \($0)" } ?? ""
                    b.add(.value("\(Fmt.bytes(free)) free of \(Fmt.bytes(total))\(fmt)", source: src),
                          key: v.isRoot ? "storage.root" : "storage.vol.\(externalIndex)", label: label) { $0 }
                }
            }
            if let root = s.rootVolume, let total = root.totalBytes, total > 0,
               let free = root.availableForImportantUsageBytes ?? root.availableBytes {
                let pct = Double(free) / Double(total) * 100
                b.addDerived(key: "storage.rootFreePercent", label: "Startup disk free", display: Fmt.percent(pct), numeric: pct)
                let gb = Double(free) / 1e9
                // Absolute free space matters more than % on large drives.
                if gb < 5 || pct < 2 {
                    b.finding("storage.low.critical", .problem, "Startup disk is almost full",
                              "Only \(Fmt.bytes(free)) is free. macOS needs free space for updates, memory swap and saving files; apps can crash or refuse to open.",
                              advice: ["Open Storage settings to see what uses space and review the recommendations.",
                                       "Empty the Trash and move large files you don't need on this Mac to an external drive."],
                              links: [SettingsLinks.storage])
                } else if gb < 15 || pct < 5 {
                    b.finding("storage.low", .warning, "Startup disk is getting full",
                              "\(Fmt.bytes(free)) free (\(Int(pct))%). Below about 15 GB, macOS updates and some apps can run into trouble.",
                              links: [SettingsLinks.storage])
                }
            } else {
                b.finding("storage.root.unknown", .unavailable, "Startup disk free space: not available",
                          "The startup volume wasn't reported with its capacity.")
            }
        } else {
            b.add(s.volumes, key: "storage.volumes", label: "Volumes") { _ in "" }
        }

        b.add(s.isSolidState, key: "storage.ssd", label: "Drive type", reportUnavailable: false) { $0 ? "Solid-state (SSD)" : "Rotational" }
        switch s.smartStatus {
        case let .value(status, src):
            b.add(.value(status, source: src), key: "storage.smart", label: "Drive self-reported status (SMART)",
                  evidence: .reportedBySystem) { $0 }
            let lower = status.lowercased()
            if lower == "verified" {
                b.finding("storage.smart.verified", .fact, "Drive reports Verified",
                          "This is the drive's own summary. It means no failure was flagged — it does not prove the SSD is healthy.",
                          evidence: .reportedBySystem)
            } else if lower.contains("fail") {
                b.finding("storage.smart.failing", .problem, "Drive reports it is failing",
                          "macOS reports the drive's self-test status as \"\(status)\".",
                          evidence: .reportedBySystem,
                          advice: ["Back up now (Time Machine or another copy).", "Contact Apple Support."])
            } else if lower.contains("not supported") {
                b.finding("storage.smart.unsupported", .unavailable, "SMART status not available",
                          "macOS reports SMART as not supported for this drive. That's common and not a problem by itself.")
            }
        case let .unavailable(reason):
            b.finding("storage.smart.unavailable", .unavailable, "SMART status not available",
                      reason + " SMART data is often unavailable for internal Apple storage through public interfaces.")
        }
        return b.build()
    }
}
