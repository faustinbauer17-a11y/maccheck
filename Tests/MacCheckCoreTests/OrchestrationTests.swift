import XCTest
@testable import MacCheckCore

final class OrchestrationTests: XCTestCase {

    func testSampleScanCoversAllSixAreasAndIsLabelledSample() async {
        let orchestrator = ScanOrchestrator(collectors: SampleData.collectors(delaySeconds: 0))
        let report = await orchestrator.run()
        XCTAssertEqual(Set(report.results.compactMap(\.area)), Set(DiagnosticArea.allCases))
        XCTAssertTrue(report.isSampleData)
        XCTAssertTrue(report.results.allSatisfy(\.isSampleData))
        XCTAssertEqual(report.device?.modelName, "MacBook Air (13-inch, M4, 2025)")
        XCTAssertEqual(report.device?.isFanless, true)
        XCTAssertFalse(report.wasCancelled)
    }

    func testFailingCheckDoesNotStopTheScan() async {
        var set = SampleData.collectors(delaySeconds: 0)
        set.network = Fake.failing("No route", as: NetworkSnapshot.self)
        set.isSample = false
        let report = await ScanOrchestrator(collectors: set).run()
        XCTAssertEqual(report.results.count, 6)
        let net = report.result(for: .network)
        XCTAssertEqual(net?.status, .failed)
        XCTAssertEqual(net?.errorDescription, "No route")
        XCTAssertTrue(net?.summary.contains("says nothing about the health") ?? false)
        XCTAssertEqual(report.result(for: .storage)?.status, .ok)
    }

    func testHangingCheckTimesOut() async {
        var set = SampleData.collectors(delaySeconds: 0)
        set.performance = Fake.hanging(as: PerformanceSnapshot.self)
        let start = Date()
        let report = await ScanOrchestrator(collectors: set).run(options: CollectionOptions(perCheckTimeoutSeconds: 1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(report.result(for: .performance)?.status, .failed)
        XCTAssertTrue(report.result(for: .performance)?.errorDescription?.contains("Timed out") ?? false)
    }

    func testBlockingCallThatIgnoresCancellationStillHitsDeadline() async throws {
        let start = Date()
        do {
            _ = try await withDeadline(seconds: 0.3) { () async throws -> Int in blockingSleep(2) }
            XCTFail("expected timeout")
        } catch is TimeoutError {
            XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        }
    }

    func testCancellationSkipsRemainingChecksAndStillReturnsReport() async {
        var set = SampleData.collectors(delaySeconds: 0)
        set.battery = Fake.hanging(as: BatterySnapshot.self) // 2nd check
        let orchestrator = ScanOrchestrator(collectors: set)
        let task = Task { await orchestrator.run(options: CollectionOptions(perCheckTimeoutSeconds: 30)) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let report = await task.value
        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.results.count, 6)
        XCTAssertEqual(report.result(for: .hardware)?.status, .info)
        XCTAssertEqual(report.result(for: .battery)?.status, .skipped)
        XCTAssertEqual(report.result(for: .storage)?.status, .skipped)
    }

    func testProgressEventsAreOrdered() async {
        final class Box: @unchecked Sendable { var events: [String] = []; let lock = NSLock() }
        let box = Box()
        _ = await ScanOrchestrator(collectors: SampleData.collectors(delaySeconds: 0)).run { e in
            box.lock.lock(); defer { box.lock.unlock() }
            switch e {
            case let .started(id, _, _, _): box.events.append("start:\(id)")
            case let .finished(r, _, _): box.events.append("end:\(r.id)")
            }
        }
        XCTAssertEqual(box.events.count, 12)
        XCTAssertEqual(box.events.first, "start:hardware")
        XCTAssertEqual(box.events.last, "end:storage")
    }

    func testSingleAreaScan() async {
        let report = await ScanOrchestrator(collectors: SampleData.collectors(delaySeconds: 0), areas: [.storage]).run(kind: .singleArea)
        XCTAssertEqual(report.results.map(\.id), ["storage"])
    }

    func testOptionsAreClamped() {
        let o = CollectionOptions(sampleWindowSeconds: 100, perCheckTimeoutSeconds: 0)
        XCTAssertEqual(o.sampleWindowSeconds, 5)
        XCTAssertEqual(o.perCheckTimeoutSeconds, 1)
        XCTAssertFalse(CollectionOptions.standard.includeIdentifiers, "identifiers must be off by default")
    }
}

/// A synchronous sleep that ignores cancellation (simulates a stuck system call).
private func blockingSleep(_ seconds: Double) -> Int {
    Thread.sleep(forTimeInterval: seconds)
    return 1
}
