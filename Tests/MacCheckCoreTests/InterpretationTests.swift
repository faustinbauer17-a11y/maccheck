import XCTest
@testable import MacCheckCore

private let src = DataSource("Test", kind: .fake)
private func v<T>(_ x: T) -> Reading<T> { .value(x, source: src) }

final class InterpretationTests: XCTestCase {

    // MARK: Battery

    func testHealthyBatteryIsOKAndCapacityIsMarkedAsEstimate() {
        let s = BatterySnapshot(hasBattery: true, cycleCount: v(120), designCapacityMAh: v(4560),
                                fullChargeCapacityMAh: v(4400), condition: v("Normal"), chargePercent: v(80),
                                isCharging: v(true), externalPowerConnected: v(true))
        let r = Interpret.battery(s)
        XCTAssertEqual(r.status, .ok)
        let cap = r.measurement("battery.maxCapacity")
        XCTAssertEqual(cap?.evidence, .derived, "capacity computed from mAh must be labelled as calculated")
        XCTAssertEqual(cap?.numeric ?? 0, 96.49, accuracy: 0.01)
        XCTAssertTrue(r.findings.contains { $0.id == "battery.capacity.derived" })
    }

    func testSystemReportedCapacityIsPreferredOverDerived() {
        let s = BatterySnapshot(hasBattery: true, designCapacityMAh: v(4560), fullChargeCapacityMAh: v(4400),
                                systemMaximumCapacityPercent: v(91))
        let r = Interpret.battery(s)
        XCTAssertEqual(r.measurement("battery.maxCapacity")?.display, "91%")
        XCTAssertEqual(r.measurement("battery.maxCapacity")?.evidence, .reportedBySystem)
    }

    func testWornBatteryAndServiceConditionEscalate() {
        let worn = Interpret.battery(BatterySnapshot(hasBattery: true, cycleCount: v(1100), designCapacityMAh: v(4560),
                                                     fullChargeCapacityMAh: v(3400), condition: v("Normal")))
        XCTAssertEqual(worn.status, .warning)
        XCTAssertTrue(worn.findings.contains { $0.id == "battery.capacity.low" })
        XCTAssertTrue(worn.findings.contains { $0.id == "battery.cycles.high" })

        let service = Interpret.battery(BatterySnapshot(hasBattery: true, condition: v("Service Recommended")))
        XCTAssertEqual(service.status, .problem)
    }

    func testNoBatteryAndAllUnavailableNeverReportsOK() {
        XCTAssertEqual(Interpret.battery(BatterySnapshot(hasBattery: false)).status, .unavailable)
        let empty = Interpret.battery(BatterySnapshot(hasBattery: true))
        XCTAssertEqual(empty.status, .unavailable, "no measured data must not read as 'looks good'")
        XCTAssertTrue(empty.findings.contains { $0.kind == .unavailable })
    }

    func testBatteryNeverEstimatesRemainingTime() {
        let r = Interpret.battery(SampleData.battery)
        XCTAssertFalse(r.measurements.contains { $0.label.lowercased().contains("remaining") })
        XCTAssertTrue(r.limitations.contains { $0.contains("does not estimate remaining battery time") })
    }

    func testPluggedInNotChargingIsAPossibleExplanationWithConfidence() {
        let r = Interpret.battery(BatterySnapshot(hasBattery: true, chargePercent: v(80), isCharging: v(false),
                                                  externalPowerConnected: v(true)))
        let f = r.findings.first { $0.id == "battery.notCharging" }
        XCTAssertEqual(f?.kind, .possibleExplanation)
        XCTAssertNotNil(f?.confidence)
        XCTAssertEqual(f?.evidence, .inferred)
    }

    // MARK: Hardware

    func testSerialOnlyIncludedWhenOptedInAndMarkedSensitive() {
        var hw = SampleData.hardware
        hw.serialNumber = .value("C02TESTSERIAL", source: src)
        let off = Interpret.hardware(hw, options: CollectionOptions(includeIdentifiers: false))
        XCTAssertNil(off.measurement("hw.serial"))
        let on = Interpret.hardware(hw, options: CollectionOptions(includeIdentifiers: true))
        XCTAssertEqual(on.measurement("hw.serial")?.isSensitive, true)
        XCTAssertNil(on.withoutSensitiveMeasurements().measurement("hw.serial"))
    }

    func testM4AirIsNamedAndUnknownModelHandled() {
        XCTAssertEqual(ModelCatalog.displayName(for: "Mac16,12"), "MacBook Air (13-inch, M4, 2025)")
        XCTAssertEqual(ModelCatalog.isFanless("Mac16,13"), true)
        XCTAssertEqual(ModelCatalog.displayName(for: "Mac99,1"), "Mac (Mac99,1)")
        XCTAssertNil(ModelCatalog.isFanless("Mac99,1"))
        let r = Interpret.hardware(HardwareSnapshot(modelIdentifier: v("Mac99,1")))
        XCTAssertTrue(r.limitations.contains { $0.contains("Mac99,1") })
    }

    // MARK: Performance

    func testMemoryPressureLevels() {
        func run(_ p: MemoryPressure) -> CheckStatus {
            Interpret.performance(PerformanceSnapshot(sampleWindowSeconds: 1, memoryPressure: v(p))).status
        }
        XCTAssertEqual(run(.normal), .ok)
        XCTAssertEqual(run(.warning), .warning)
        XCTAssertEqual(run(.critical), .problem)
        XCTAssertEqual(MemoryPressure(kernelLevel: 4), .critical)
        XCTAssertNil(MemoryPressure(kernelLevel: 3))
    }

    func testSwapAloneIsNotAWarning() {
        let r = Interpret.performance(PerformanceSnapshot(sampleWindowSeconds: 1, memoryTotalBytes: v(16 << 30),
                                                          memoryPressure: v(.normal), swapUsedBytes: v(12 << 30)))
        XCTAssertEqual(r.status, .ok)
        XCTAssertTrue(r.findings.contains { $0.id == "perf.swap.normal" })
    }

    func testTopProcessesListedAndLimitationsStated() {
        let r = Interpret.performance(SampleData.performance)
        XCTAssertEqual(r.measurement("perf.top.0")?.label, "Busy: Safari")
        XCTAssertTrue(r.limitations.contains { $0.contains("never quits processes") })
    }

    // MARK: Thermals

    func testFanlessAirSaysNoFanAndNeverClaimsTemperatures() {
        let r = Interpret.thermals(ThermalSnapshot(thermalState: v(.nominal), lowPowerMode: v(false), modelIdentifier: v("Mac16,12")))
        XCTAssertEqual(r.status, .ok)
        XCTAssertTrue(r.findings.contains { $0.id == "thermal.fanless" })
        XCTAssertFalse(r.measurements.contains { $0.label.lowercased().contains("°") || $0.label.lowercased().contains("fan speed") })
        XCTAssertTrue(r.limitations.contains { $0.contains("Temperatures aren't shown") })
    }

    func testThermalStates() {
        XCTAssertEqual(Interpret.thermals(ThermalSnapshot(thermalState: v(.serious))).status, .warning)
        XCTAssertEqual(Interpret.thermals(ThermalSnapshot(thermalState: v(.critical))).status, .problem)
        XCTAssertEqual(Interpret.thermals(ThermalSnapshot(thermalState: v(.fair))).status, .ok)
    }

    // MARK: Network

    func testOfflineIsProblem() {
        XCTAssertEqual(Interpret.network(NetworkSnapshot(pathStatus: v("unsatisfied"))).status, .problem)
    }

    func testDNSFailureWhileConnected() {
        let s = NetworkSnapshot(pathStatus: v("satisfied"),
                                dnsProbes: v([ProbeResult(target: "a", succeeded: false, durationMs: nil, detail: "timeout"),
                                              ProbeResult(target: "b", succeeded: false, durationMs: nil, detail: "timeout")]))
        let r = Interpret.network(s)
        XCTAssertEqual(r.status, .problem)
        XCTAssertTrue(r.findings.contains { $0.id == "net.dns.fail" })
    }

    func testHTTPSFailsButDNSWorks() {
        let s = NetworkSnapshot(pathStatus: v("satisfied"),
                                dnsProbes: v([ProbeResult(target: "a", succeeded: true, durationMs: 20, detail: "")]),
                                httpsProbes: v([ProbeResult(target: "x", succeeded: false, durationMs: nil, detail: "TLS")]))
        XCTAssertTrue(Interpret.network(s).findings.contains { $0.id == "net.https.fail" })
    }

    func testProbesDisabledAreUnavailableNotFailed() {
        let s = NetworkSnapshot(pathStatus: v("satisfied"), interfaceTypes: v(["wifi"]),
                                dnsProbes: .unavailable(reason: "Network probes are turned off in Settings."),
                                httpsProbes: .unavailable(reason: "Network probes are turned off in Settings."))
        let r = Interpret.network(s)
        XCTAssertEqual(r.status, .ok)
        XCTAssertTrue(r.findings.contains { $0.kind == .unavailable && $0.detail.contains("turned off") })
    }

    // MARK: Storage

    func testLowDiskThresholds() {
        func run(free: Int64, total: Int64 = 500_000_000_000) -> CheckStatus {
            Interpret.storage(StorageSnapshot(volumes: v([VolumeInfo(name: "Macintosh HD", isRoot: true, isInternal: true,
                                                                       isReadOnly: false, format: "APFS", totalBytes: total,
                                                                       availableBytes: free, availableForImportantUsageBytes: nil)]))).status
        }
        XCTAssertEqual(run(free: 100_000_000_000), .ok)
        XCTAssertEqual(run(free: 12_000_000_000), .warning)
        XCTAssertEqual(run(free: 3_000_000_000), .problem)
    }

    func testSmartVerifiedIsNotProofOfHealthAndUnavailableExplained() {
        let ok = Interpret.storage(SampleData.storage)
        let f = ok.findings.first { $0.id == "storage.smart.verified" }
        XCTAssertNotNil(f)
        XCTAssertTrue(f!.detail.contains("does not prove"))
        XCTAssertEqual(ok.measurement("storage.smart")?.evidence, .reportedBySystem)

        let na = Interpret.storage(StorageSnapshot(volumes: SampleData.storage.volumes,
                                                   smartStatus: .unavailable(reason: "diskutil gave no SMART field.")))
        XCTAssertTrue(na.findings.contains { $0.id == "storage.smart.unavailable" && $0.detail.contains("internal Apple storage") })
        XCTAssertEqual(na.status, .ok, "unavailable SMART must not be treated as a problem")
    }

    func testOtherVolumeNamesHiddenUnlessIdentifiersOn() {
        let vols = [VolumeInfo(name: "Macintosh HD", isRoot: true, isInternal: true, isReadOnly: false, format: "APFS",
                               totalBytes: 500_000_000_000, availableBytes: 100_000_000_000, availableForImportantUsageBytes: nil),
                    VolumeInfo(name: "Anna's Backup", isRoot: false, isInternal: false, isReadOnly: false, format: "APFS",
                               totalBytes: 1_000_000_000_000, availableBytes: 400_000_000_000, availableForImportantUsageBytes: nil)]
        let hidden = Interpret.storage(StorageSnapshot(volumes: v(vols)))
        XCTAssertFalse(hidden.measurements.contains { $0.label.contains("Anna") })
        let shown = Interpret.storage(StorageSnapshot(volumes: v(vols)), options: CollectionOptions(includeIdentifiers: true))
        XCTAssertTrue(shown.measurements.contains { $0.label.contains("Anna") })
    }

    // MARK: Status roll-up & sample labelling

    func testRollUp() {
        XCTAssertEqual(CheckStatus.rollUp([.ok, .unavailable, .warning]), .warning)
        XCTAssertEqual(CheckStatus.rollUp([.ok, .problem, .failed]), .problem)
        XCTAssertEqual(CheckStatus.rollUp([.unavailable, .skipped]), .unavailable)
        XCTAssertEqual(CheckStatus.rollUp([]), .skipped)
        XCTAssertEqual(CheckStatus.rollUp([.info, .ok, .unavailable]), .ok)
    }

    func testSampleResultsAreLabelledEverywhere() {
        let r = Interpret.battery(SampleData.battery, isSample: true)
        XCTAssertTrue(r.isSampleData)
        XCTAssertTrue(r.measurements.allSatisfy { $0.evidence == .sample })
        XCTAssertTrue(r.findings.allSatisfy { $0.evidence == .sample })
    }

    func testPossibleExplanationAlwaysHasConfidence() {
        let f = Finding(id: "x", kind: .possibleExplanation, title: "t", detail: "d", evidence: .inferred)
        XCTAssertEqual(f.confidence, .low)
    }
}
