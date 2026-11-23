import Foundation

/// A network endpoint MacCheck probes. Shown to the user before probing.
public struct ProbeEndpoint: Codable, Hashable, Sendable {
    public var name: String
    public var url: String
    /// If set, the response body must contain this text; otherwise a captive portal is suspected.
    public var expectBodyContains: String?

    public init(name: String, url: String, expectBodyContains: String? = nil) {
        self.name = name
        self.url = url
        self.expectBodyContains = expectBodyContains
    }

    /// Defaults: Apple's connectivity-check page and Cloudflare's public resolver site.
    public static let defaults: [ProbeEndpoint] = [
        ProbeEndpoint(name: "Apple connectivity check", url: "https://www.apple.com/library/test/success.html",
                      expectBodyContains: "Success"),
        ProbeEndpoint(name: "Cloudflare", url: "https://one.one.one.one/"),
    ]

    public var host: String? { URL(string: url)?.host }
}

/// Options shared by all collectors for one scan.
public struct CollectionOptions: Codable, Hashable, Sendable {
    /// Collect unique identifiers such as the serial number. Off by default.
    public var includeIdentifiers: Bool
    /// Allow outbound DNS/HTTPS probes. On by default, disclosed in the UI.
    public var networkProbesEnabled: Bool
    public var probeEndpoints: [ProbeEndpoint]
    /// CPU/process sampling window, kept short.
    public var sampleWindowSeconds: Double
    /// Upper bound for any single check.
    public var perCheckTimeoutSeconds: Double

    public init(includeIdentifiers: Bool = false, networkProbesEnabled: Bool = true,
                probeEndpoints: [ProbeEndpoint] = ProbeEndpoint.defaults,
                sampleWindowSeconds: Double = 1.5, perCheckTimeoutSeconds: Double = 20) {
        self.includeIdentifiers = includeIdentifiers
        self.networkProbesEnabled = networkProbesEnabled
        self.probeEndpoints = probeEndpoints
        self.sampleWindowSeconds = min(max(sampleWindowSeconds, 0.2), 5)
        self.perCheckTimeoutSeconds = min(max(perCheckTimeoutSeconds, 1), 60)
    }

    public static let standard = CollectionOptions()
}

/// A platform collector: an async function that returns a raw snapshot.
/// Implemented natively in `MacCheckMac`, and by fakes in `Fakes.swift` for tests and sample mode.
public struct Collector<Snapshot: Sendable>: Sendable {
    public var name: String
    public var collect: @Sendable (CollectionOptions) async throws -> Snapshot

    public init(name: String, collect: @escaping @Sendable (CollectionOptions) async throws -> Snapshot) {
        self.name = name
        self.collect = collect
    }
}

/// All collectors needed for a full diagnostic.
public struct CollectorSet: Sendable {
    public var battery: Collector<BatterySnapshot>
    public var hardware: Collector<HardwareSnapshot>
    public var performance: Collector<PerformanceSnapshot>
    public var thermals: Collector<ThermalSnapshot>
    public var network: Collector<NetworkSnapshot>
    public var storage: Collector<StorageSnapshot>
    /// True for sample/fake data. Propagated to every report.
    public var isSample: Bool

    public init(battery: Collector<BatterySnapshot>, hardware: Collector<HardwareSnapshot>,
                performance: Collector<PerformanceSnapshot>, thermals: Collector<ThermalSnapshot>,
                network: Collector<NetworkSnapshot>, storage: Collector<StorageSnapshot>, isSample: Bool) {
        self.battery = battery
        self.hardware = hardware
        self.performance = performance
        self.thermals = thermals
        self.network = network
        self.storage = storage
        self.isSample = isSample
    }
}

public struct CollectorUnavailableError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}
