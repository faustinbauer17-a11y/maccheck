#if os(macOS)
import Foundation
import IOKit
import IOKit.ps
import Metal
import Network
import MacCheckCore

// Native collectors for the six areas. Read-only. Every value is either read from a documented
// interface or returned as `.unavailable(reason:)` — nothing is guessed.
//
// STATUS: written on Windows, NOT yet compiled or run on a Mac. See docs/MAC-TEST-CHECKLIST.md.

// MARK: - Battery

enum BatteryCollector {
    static func collect() -> BatterySnapshot {
        let smart = IORegistry.properties(ofClass: "AppleSmartBattery")
        let ioSrc = DataSource.ioreg("IORegistry AppleSmartBattery")
        let psSrc = DataSource.api("IOKit Power Sources (IOPS)")

        // Power Sources: the documented interface for charge and power state.
        var ps: [String: Any]?
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for item in list {
                if let d = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any],
                   (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType {
                    ps = d
                }
            }
        }
        guard smart != nil || ps != nil else { return BatterySnapshot(hasBattery: false) }

        func int(_ key: String, _ dict: [String: Any]?, _ src: DataSource, _ why: String) -> Reading<Int> {
            if let v = dict?[key] as? Int { return .value(v, source: src) }
            return .unavailable(reason: why)
        }

        var snap = BatterySnapshot(hasBattery: true)
        snap.cycleCount = int("CycleCount", smart, ioSrc, "Cycle count not exposed by this Mac.")
        snap.designCapacityMAh = int("DesignCapacity", smart, ioSrc, "Design capacity not exposed.")
        // Apple Silicon: AppleRawMaxCapacity is mAh; MaxCapacity may be a percentage there, so it is not used as mAh.
        if let raw = smart?["AppleRawMaxCapacity"] as? Int {
            snap.fullChargeCapacityMAh = .value(raw, source: ioSrc)
        } else if let nominal = smart?["NominalChargeCapacity"] as? Int {
            snap.fullChargeCapacityMAh = .value(nominal, source: ioSrc)
        } else {
            snap.fullChargeCapacityMAh = .unavailable(reason: "Full-charge capacity not exposed.")
        }
        // Newer macOS versions may publish the Settings figure; use it only if present.
        if let pct = ps?["Maximum Capacity Percent"] as? Int {
            snap.systemMaximumCapacityPercent = .value(pct, source: psSrc)
        } else {
            snap.systemMaximumCapacityPercent = .unavailable(reason: "macOS didn't publish its own maximum-capacity figure through IOPS.")
        }
        if let cond = (ps?["BatteryHealthCondition"] as? String) ?? (ps?[kIOPSBatteryHealthKey] as? String) {
            snap.condition = .value(cond, source: psSrc)
        } else {
            snap.condition = .unavailable(reason: "macOS didn't report a battery condition through IOPS. System Settings → Battery shows it.")
        }
        if let cur = ps?[kIOPSCurrentCapacityKey] as? Int, let max = ps?[kIOPSMaxCapacityKey] as? Int, max > 0 {
            snap.chargePercent = .value(Int((Double(cur) / Double(max) * 100).rounded()), source: psSrc)
        } else {
            snap.chargePercent = .unavailable(reason: "Charge level not reported.")
        }
        if let charging = ps?[kIOPSIsChargingKey] as? Bool {
            snap.isCharging = .value(charging, source: psSrc)
        } else if let charging = smart?["IsCharging"] as? Bool {
            snap.isCharging = .value(charging, source: ioSrc)
        }
        if let state = ps?[kIOPSPowerSourceStateKey] as? String {
            snap.externalPowerConnected = .value(state == kIOPSACPowerValue, source: psSrc)
        } else if let ext = smart?["ExternalConnected"] as? Bool {
            snap.externalPowerConnected = .value(ext, source: ioSrc)
        }
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            let aSrc = DataSource.api("IOPSCopyExternalPowerAdapterDetails")
            if let w = adapter[kIOPSPowerAdapterWattsKey] as? Int { snap.adapterWatts = .value(w, source: aSrc) }
            if let name = adapter["Name"] as? String ?? adapter["Description"] as? String {
                snap.adapterName = .value(name, source: aSrc)
            }
        } else {
            snap.adapterWatts = .unavailable(reason: "No power adapter connected.")
        }
        return snap
    }
}

// MARK: - Hardware

enum HardwareCollector {
    static func collect(_ options: CollectionOptions) -> HardwareSnapshot {
        let sys = DataSource.api("sysctl")
        func str(_ name: String, _ why: String) -> Reading<String> {
            Sysctl.string(name).map { .value($0, source: sys) } ?? .unavailable(reason: why)
        }
        func int(_ name: String, _ why: String) -> Reading<Int> {
            Sysctl.int(name).map { .value($0, source: sys) } ?? .unavailable(reason: why)
        }
        var s = HardwareSnapshot()
        s.modelIdentifier = str("hw.model", "Model identifier not available.")
        s.chip = str("machdep.cpu.brand_string", "Chip name not available.")
        var uts = utsname()
        if uname(&uts) == 0 {
            let machine = withUnsafeBytes(of: &uts.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            s.cpuArchitecture = .value(machine, source: .api("uname"))
        }
        s.performanceCores = int("hw.perflevel0.physicalcpu", "Performance-core count not exposed.")
        s.efficiencyCores = int("hw.perflevel1.physicalcpu", "Efficiency-core count not exposed.")
        s.totalCores = int("hw.physicalcpu", "Core count not available.")
        if let mem = Sysctl.value("hw.memsize", as: UInt64.self) { s.memoryBytes = .value(Int64(mem), source: sys) }

        if let device = MTLCreateSystemDefaultDevice() { s.gpuName = .value(device.name, source: .api("Metal")) }
        if let cores = IORegistry.property(ofClass: "AGXAccelerator", key: "gpu-core-count") as? Int {
            s.gpuCores = .value(cores, source: .ioreg("IORegistry AGXAccelerator"))
        } else {
            s.gpuCores = .unavailable(reason: "GPU core count isn't exposed on this Mac.")
        }

        let v = ProcessInfo.processInfo.operatingSystemVersion
        let patch = v.patchVersion > 0 ? ".\(v.patchVersion)" : ""
        s.macOSVersion = .value("macOS \(v.majorVersion).\(v.minorVersion)\(patch)", source: .api("ProcessInfo"))
        s.macOSBuild = str("kern.osversion", "Build number not available.")
        s.uptimeSeconds = .value(ProcessInfo.processInfo.systemUptime, source: .api("ProcessInfo"))
        s.rosettaInstalled = .value(FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta/rosetta"),
                                    source: .files("Rosetta runtime file"))
        if options.includeIdentifiers {
            if let serial = IORegistry.property(ofClass: "IOPlatformExpertDevice", key: kIOPlatformSerialNumberKey) as? String {
                s.serialNumber = .value(serial, source: .ioreg("IORegistry IOPlatformExpertDevice"))
            } else {
                s.serialNumber = .unavailable(reason: "Serial number not readable.")
            }
        }
        return s
    }
}

// MARK: - Performance

enum PerformanceCollector {
    struct CPUTicks { var busy: UInt64; var total: UInt64 }

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return CPUTicks(busy: user + system + nice, total: user + system + idle + nice)
    }

    struct ProcTime { var name: String; var cpuNs: UInt64; var resident: UInt64 }

    /// Processes this user may inspect. Others (root, other users) are skipped — documented limitation.
    static func processTimes() -> [pid_t: ProcTime] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [:] }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        var out: [pid_t: ProcTime] = [:]
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            var nameBuf = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            let name = String(cString: nameBuf)
            guard !name.isEmpty else { continue }
            // pti_total_* are in Mach absolute time units; convert to nanoseconds.
            let machTime = info.pti_total_user + info.pti_total_system
            let ns = machTime * UInt64(tb.numer) / UInt64(max(tb.denom, 1))
            out[pid] = ProcTime(name: name, cpuNs: ns, resident: info.pti_resident_size)
        }
        return out
    }

    static func collect(_ options: CollectionOptions) async throws -> PerformanceSnapshot {
        let sys = DataSource.api("Mach host statistics")
        var s = PerformanceSnapshot(sampleWindowSeconds: options.sampleWindowSeconds)

        let t0 = cpuTicks()
        let p0 = processTimes()
        let start = DispatchTime.now().uptimeNanoseconds
        try await Task.sleep(nanoseconds: UInt64(options.sampleWindowSeconds * 1_000_000_000))
        let t1 = cpuTicks()
        let p1 = processTimes()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)

        if let a = t0, let b = t1, b.total > a.total {
            s.cpuBusyPercent = .value(Double(b.busy - a.busy) / Double(b.total - a.total) * 100, source: sys)
        } else {
            s.cpuBusyPercent = .unavailable(reason: "CPU counters not available.")
        }

        var samples: [ProcessSample] = []
        for (pid, after) in p1 {
            guard let before = p0[pid], after.cpuNs >= before.cpuNs, elapsed > 0 else { continue }
            let pct = Double(after.cpuNs - before.cpuNs) / elapsed * 100
            samples.append(ProcessSample(name: after.name, pid: pid, cpuPercent: pct, residentBytes: Int64(after.resident)))
        }
        if samples.isEmpty {
            s.topProcesses = .unavailable(reason: "No process information was readable.")
        } else {
            s.topProcesses = .value(Array(samples.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(8)), source: .api("libproc"))
        }

        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { s.loadAverage1m = .value(load[0], source: .api("getloadavg")) }
        s.logicalCores = .value(ProcessInfo.processInfo.activeProcessorCount, source: .api("ProcessInfo"))

        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        s.memoryTotalBytes = .value(total, source: .api("ProcessInfo"))
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        if kr == KERN_SUCCESS, pageSize > 0 {
            let page = Int64(pageSize)
            // Same formula Activity Monitor uses for "Memory Used": app + wired + compressed.
            let app = (Int64(vm.internal_page_count) - Int64(vm.purgeable_count)) * page
            let wired = Int64(vm.wire_count) * page
            let compressed = Int64(vm.compressor_page_count) * page
            s.memoryUsedBytes = .value(max(0, app + wired + compressed), source: sys)
            s.memoryCompressedBytes = .value(compressed, source: sys)
        } else {
            s.memoryUsedBytes = .unavailable(reason: "VM statistics not available.")
        }

        if let level = Sysctl.int("kern.memorystatus_vm_pressure_level"), let p = MemoryPressure(kernelLevel: level) {
            s.memoryPressure = .value(p, source: .api("sysctl kern.memorystatus_vm_pressure_level"))
        } else {
            s.memoryPressure = .unavailable(reason: "Memory pressure level not readable.")
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            s.swapUsedBytes = .value(Int64(swap.xsu_used), source: .api("sysctl vm.swapusage"))
            s.swapTotalBytes = .value(Int64(swap.xsu_total), source: .api("sysctl vm.swapusage"))
        } else {
            s.swapUsedBytes = .unavailable(reason: "Swap usage not readable.")
        }
        return s
    }
}

// MARK: - Thermals

enum ThermalCollector {
    static func collect() -> ThermalSnapshot {
        let src = DataSource.api("ProcessInfo.thermalState")
        let state: ThermalPressure
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: state = .nominal
        case .fair: state = .fair
        case .serious: state = .serious
        case .critical: state = .critical
        @unknown default: return ThermalSnapshot(thermalState: .unavailable(reason: "Unknown thermal state value."))
        }
        return ThermalSnapshot(
            thermalState: .value(state, source: src),
            lowPowerMode: .value(ProcessInfo.processInfo.isLowPowerModeEnabled, source: .api("ProcessInfo")),
            modelIdentifier: Sysctl.string("hw.model").map { .value($0, source: .api("sysctl")) }
                ?? .unavailable(reason: "Model identifier not available."))
    }
}

// MARK: - Network

enum NetworkCollector {
    static func currentPath() async -> NWPath {
        await withCheckedContinuation { (cont: CheckedContinuation<NWPath, Never>) in
            let monitor = NWPathMonitor()
            let once = Once()
            monitor.pathUpdateHandler = { path in
                if once.claim() {
                    monitor.cancel()
                    cont.resume(returning: path)
                }
            }
            monitor.start(queue: DispatchQueue(label: "maccheck.path"))
        }
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    /// Blocking getaddrinfo, run off the main thread and bounded by the caller's deadline.
    static func resolve(_ host: String) -> ProbeResult {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let start = DispatchTime.now().uptimeNanoseconds
        let rc = getaddrinfo(host, "443", &hints, &res)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        guard rc == 0, let first = res else {
            return ProbeResult(target: host, succeeded: false, durationMs: nil,
                               detail: String(cString: gai_strerror(rc)))
        }
        var count = 0
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let cur = p { count += 1; p = cur.pointee.ai_next }
        freeaddrinfo(first)
        return ProbeResult(target: host, succeeded: true, durationMs: ms, detail: "\(count) address\(count == 1 ? "" : "es")")
    }

    static func collect(_ options: CollectionOptions) async -> NetworkSnapshot {
        let pathSrc = DataSource.api("Network.framework NWPathMonitor")
        let path = await currentPath()
        var s = NetworkSnapshot()
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requiresConnection"
        @unknown default: status = "unknown"
        }
        s.pathStatus = .value(status, source: pathSrc)
        let kinds: [(NWInterface.InterfaceType, String)] = [(.wifi, "wifi"), (.wiredEthernet, "wiredEthernet"),
                                                             (.cellular, "cellular"), (.other, "other")]
        s.interfaceTypes = .value(kinds.filter { path.usesInterfaceType($0.0) }.map { $0.1 }, source: pathSrc)
        s.isExpensive = .value(path.isExpensive, source: pathSrc)
        s.isConstrained = .value(path.isConstrained, source: pathSrc)

        guard options.networkProbesEnabled else {
            let off = "Network probes are turned off in Settings."
            s.dnsProbes = .unavailable(reason: off)
            s.httpsProbes = .unavailable(reason: off)
            s.captivePortalSuspected = .unavailable(reason: off)
            return s
        }
        guard status == "satisfied" else {
            let why = "Skipped: no network connection."
            s.dnsProbes = .unavailable(reason: why)
            s.httpsProbes = .unavailable(reason: why)
            return s
        }

        // DNS: one lookup per endpoint host, 4 s each.
        var dns: [ProbeResult] = []
        for host in Set(options.probeEndpoints.compactMap(\.host)).sorted() {
            do {
                dns.append(try await withDeadline(seconds: 4) { resolve(host) })
            } catch {
                dns.append(ProbeResult(target: host, succeeded: false, durationMs: nil, detail: "no answer within 4 s"))
            }
        }
        s.dnsProbes = .value(dns, source: .api("getaddrinfo"))

        // HTTPS: one small request per endpoint. Ephemeral session: no cookies, no cache, nothing stored.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var https: [ProbeResult] = []
        var captive = false
        for endpoint in options.probeEndpoints {
            guard let url = URL(string: endpoint.url), url.scheme == "https" else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = endpoint.expectBodyContains == nil ? "HEAD" : "GET"
            request.setValue("MacCheck connectivity check", forHTTPHeaderField: "User-Agent")
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                let (data, response) = try await session.data(for: request)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let expected = endpoint.expectBodyContains,
                   !(String(data: data.prefix(4096), encoding: .utf8) ?? "").contains(expected) {
                    captive = true
                }
                https.append(ProbeResult(target: endpoint.name, succeeded: code > 0 && code < 500, durationMs: ms, detail: "HTTP \(code)"))
            } catch {
                https.append(ProbeResult(target: endpoint.name, succeeded: false, durationMs: nil,
                                         detail: (error as NSError).localizedDescription))
            }
        }
        s.httpsProbes = .value(https, source: .api("URLSession (ephemeral)"))
        s.captivePortalSuspected = .value(captive, source: .api("URLSession (ephemeral)"))
        return s
    }
}

// MARK: - Storage

enum StorageCollector {
    static func collect() -> StorageSnapshot {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedFormatDescriptionKey,
                                      .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey,
                                      .volumeIsBrowsableKey]
        var s = StorageSnapshot()
        let src = DataSource.api("FileManager volume resource values")
        if let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) {
            var volumes: [VolumeInfo] = []
            for url in urls {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { continue }
                volumes.append(VolumeInfo(
                    name: v.volumeName ?? url.lastPathComponent,
                    isRoot: v.volumeIsRootFileSystem ?? (url.path == "/"),
                    isInternal: v.volumeIsInternal, isReadOnly: v.volumeIsReadOnly,
                    format: v.volumeLocalizedFormatDescription,
                    totalBytes: v.volumeTotalCapacity.map(Int64.init),
                    availableBytes: v.volumeAvailableCapacity.map(Int64.init),
                    availableForImportantUsageBytes: v.volumeAvailableCapacityForImportantUsage))
            }
            s.volumes = .value(volumes, source: src)
        } else {
            s.volumes = .unavailable(reason: "macOS did not list mounted volumes.")
        }

        // diskutil is Apple's documented tool; output is a property list. Read-only `info` verb only.
        do {
            let data = try BoundedTool.run(.diskutil, ["info", "-plist", "/"], timeout: 8)
            if let info = DiskutilInfoParser.parse(plistData: data) {
                let dsrc = DataSource.tool("diskutil info")
                s.smartStatus = info.smartStatus.map { .value($0, source: dsrc) }
                    ?? .unavailable(reason: "diskutil reported no SMART status for the startup disk.")
                if let ssd = info.isSolidState { s.isSolidState = .value(ssd, source: dsrc) }
            } else {
                s.smartStatus = .unavailable(reason: "diskutil output could not be read.")
            }
        } catch {
            s.smartStatus = .unavailable(reason: "diskutil could not be run: \(error).")
        }
        return s
    }
}

// MARK: - Entry point

public enum MacPlatform {
    /// Native collectors. Each call runs off the main thread.
    public static func collectors() -> CollectorSet {
        CollectorSet(
            battery: Collector(name: "IOKit battery") { _ in BatteryCollector.collect() },
            hardware: Collector(name: "sysctl/IOKit hardware") { opts in HardwareCollector.collect(opts) },
            performance: Collector(name: "Mach/libproc performance") { opts in try await PerformanceCollector.collect(opts) },
            thermals: Collector(name: "ProcessInfo thermals") { _ in ThermalCollector.collect() },
            network: Collector(name: "Network.framework") { opts in await NetworkCollector.collect(opts) },
            storage: Collector(name: "FileManager/diskutil storage") { _ in StorageCollector.collect() },
            isSample: false)
    }
}
#endif
