import XCTest
@testable import MacCheckCore

private let src = DataSource("Test", kind: .fake)
private func v<T>(_ x: T) -> Reading<T> { .value(x, source: src) }

final class LiveOverviewTests: XCTestCase {

    func testSampleDataFillsEveryGauge() {
        let o = LiveOverview.make(battery: SampleData.battery, hardware: SampleData.hardware,
                                  performance: SampleData.performance, thermals: SampleData.thermals,
                                  storage: SampleData.storage, isSample: true)
        XCTAssertEqual(o.gauges.map(\.id), ["cpu", "memory", "storage", "battery", "thermal"])
        XCTAssertTrue(o.gauges.allSatisfy { $0.fraction != nil }, "sample data has every value")
        XCTAssertEqual(o.memoryText, "16 GB")
        XCTAssertEqual(o.device?.chip, "Apple M4")
        XCTAssertTrue(o.isSample)
    }

    func testMissingCollectorsShowDashNotAGuess() {
        let o = LiveOverview.make(battery: nil, hardware: nil, performance: nil, thermals: nil, storage: nil, isSample: false)
        for g in o.gauges {
            XCTAssertNil(g.fraction, g.id)
            XCTAssertEqual(g.value, "—", g.id)
            XCTAssertEqual(g.level, .neutral, g.id)
        }
        XCTAssertNil(o.device)
        XCTAssertNil(o.storageText)
    }

    func testUnavailableReadingKeepsTheReason() {
        let p = PerformanceSnapshot(sampleWindowSeconds: 1, cpuBusyPercent: .unavailable(reason: "host_statistics failed."))
        let g = LiveOverview.cpuGauge(p)
        XCTAssertNil(g.fraction)
        XCTAssertTrue(g.detail.contains("host_statistics failed."))
    }

    func testBatteryPrefersMacOSFigureAndFlagsWear() {
        let b = BatterySnapshot(hasBattery: true, designCapacityMAh: v(5000), fullChargeCapacityMAh: v(3500),
                                systemMaximumCapacityPercent: v(76), condition: v("Normal"))
        let g = LiveOverview.batteryGauge(b)
        XCTAssertEqual(g.value, "76")
        XCTAssertEqual(g.level, .attention)
        XCTAssertTrue(g.detail.contains("reported by macOS"))

        let service = BatterySnapshot(hasBattery: true, systemMaximumCapacityPercent: v(90), condition: v("Service Recommended"))
        XCTAssertEqual(LiveOverview.batteryGauge(service).level, .problem)

        let desktop = BatterySnapshot(hasBattery: false)
        XCTAssertNil(LiveOverview.batteryGauge(desktop).fraction)
    }

    func testDerivedBatteryCapacityIsCappedAndLabelled() {
        let b = BatterySnapshot(hasBattery: true, designCapacityMAh: v(4000), fullChargeCapacityMAh: v(4100))
        let g = LiveOverview.batteryGauge(b)
        XCTAssertEqual(g.value, "100")
        XCTAssertTrue(g.detail.contains("estimated"))
    }

    func testStorageUsesSameThresholdsAsStorageTest() {
        func gauge(free: Int64, total: Int64) -> LiveGauge {
            let vol = VolumeInfo(name: "Macintosh HD", isRoot: true, isInternal: true, isReadOnly: false, format: "apfs",
                                 totalBytes: total, availableBytes: free, availableForImportantUsageBytes: free)
            return LiveOverview.storageGauge(StorageSnapshot(volumes: v([vol])))
        }
        XCTAssertEqual(gauge(free: 200_000_000_000, total: 500_000_000_000).level, .good)
        XCTAssertEqual(gauge(free: 10_000_000_000, total: 500_000_000_000).level, .attention)
        XCTAssertEqual(gauge(free: 3_000_000_000, total: 500_000_000_000).level, .problem)
        let g = gauge(free: 200_000_000_000, total: 500_000_000_000)
        XCTAssertEqual(g.value, "200")
        XCTAssertEqual(g.unit, "GB free")
        XCTAssertEqual(g.fraction ?? 0, 0.6, accuracy: 0.001)
    }

    func testThermalGaugeNeverClaimsATemperature() {
        let g = LiveOverview.thermalGauge(ThermalSnapshot(thermalState: v(.serious)))
        XCTAssertEqual(g.value, "Serious")
        XCTAssertEqual(g.level, .attention)
        XCTAssertFalse(g.detail.contains("°"))
        XCTAssertTrue(g.detail.contains("not a temperature"))
    }

    func testMemoryLevelFollowsPressureNotPercentUsed() {
        let p = PerformanceSnapshot(sampleWindowSeconds: 1, memoryTotalBytes: v(16_000_000_000),
                                    memoryUsedBytes: v(15_000_000_000), memoryPressure: v(.normal))
        let g = LiveOverview.memoryGauge(p)
        XCTAssertEqual(g.level, .good, "high use with normal pressure is fine on macOS")
        XCTAssertEqual(g.value, "94")
    }
}
