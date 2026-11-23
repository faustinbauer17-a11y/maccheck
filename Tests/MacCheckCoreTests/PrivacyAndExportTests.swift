import XCTest
@testable import MacCheckCore

final class RedactionTests: XCTestCase {
    let r = Redactor(knownValues: ["Anna Example", "Annas-MacBook-Air"])

    func testHomeFolderUserNameRedacted() {
        XCTAssertEqual(r("/Users/anna/Documents/x.pdf"), "/Users/<user>/Documents/x.pdf")
        XCTAssertEqual(r("/Users/Shared/file"), "/Users/Shared/file")
    }

    func testEmailsIPsMacsUUIDs() {
        let out = r.redact("mail anna@example.com from 192.168.1.23 mac a4:83:e7:11:22:33 id 9F8E7D6C-AAAA-BBBB-CCCC-DDDDEEEEFFFF v6 fe80::1c2b:3cff:fe4d:5e6f")
        XCTAssertFalse(out.text.contains("anna@example.com"))
        XCTAssertFalse(out.text.contains("192.168.1.23"))
        XCTAssertFalse(out.text.contains("a4:83:e7"))
        XCTAssertFalse(out.text.contains("9F8E7D6C"))
        XCTAssertFalse(out.text.contains("fe80::1c2b"))
        XCTAssertEqual(out.counts[.email], 1)
        XCTAssertGreaterThanOrEqual(out.total, 5)
    }

    func testSecretsKeepKeyHideValue() {
        XCTAssertEqual(r("token=abc123SECRET&x=1"), "token=<redacted>&x=1")
        XCTAssertEqual(r("password: hunter2"), "password: <redacted>")
        XCTAssertEqual(r("Authorization: Bearer eyJhbGciOi.payload.sig"), "Authorization: <redacted>")
        XCTAssertTrue(r("header Bearer abc.def").contains("Bearer <redacted>"))
        XCTAssertEqual(r("api_key=\"sk-live-1234\""), "api_key=<redacted>")
    }

    func testSerialLabelledIdentifiersAndKnownValues() {
        XCTAssertEqual(r("Serial Number: C02XK0ABJGH5"), "Serial Number: <redacted>")
        XCTAssertTrue(r(#""crashReporterKey":"9F8E7D6C""#).contains("<redacted>"))
        XCTAssertEqual(r("Owner Anna Example on Annas-MacBook-Air.local"), "Owner <redacted> on <redacted>.local")
    }

    func testKnownValuesMatchWholeWordsOnly() {
        let short = Redactor(knownValues: ["anna"])
        XCTAssertEqual(short("anna opened Annapurna.app"), "<redacted> opened Annapurna.app")
        XCTAssertEqual(short("ANNA's notes"), "<redacted>'s notes")
    }

    func testQueryStringsAndLongTokensButNotPathsOrTimes() {
        XCTAssertEqual(r("https://example.com/cb?code=XYZ&state=1"), "https://example.com/cb?<redacted>")
        XCTAssertEqual(r("key 0123456789abcdef0123456789abcdef01"), "key <token>")
        let path = "/Applications/SomeVeryLongApplicationName.app/Contents/Frameworks/AnotherVeryLongFrameworkName.framework"
        XCTAssertEqual(r(path), path)
        XCTAssertEqual(r("at 10:11:12.123 +0200"), "at 10:11:12.123 +0200")
        XCTAssertEqual(r("EXC_BAD_ACCESS (SIGSEGV)"), "EXC_BAD_ACCESS (SIGSEGV)")
    }
}

final class ExportTests: XCTestCase {
    func sampleReport() async -> ScanReport {
        var set = SampleData.collectors(delaySeconds: 0)
        var hw = SampleData.hardware
        hw.serialNumber = .value("C02SERIAL123", source: .sample)
        set.hardware = Fake.returning(hw)
        return await ScanOrchestrator(collectors: set).run(options: CollectionOptions(includeIdentifiers: true))
    }

    func testExportRequiresReview() async throws {
        var draft = ReportDraft(report: await sampleReport())
        XCTAssertThrowsError(try ReportExporter.data(for: draft)) { XCTAssertEqual($0 as? ExportError, .notReviewed) }
        draft.markReviewed()
        XCTAssertNoThrow(try ReportExporter.data(for: draft))
        draft.options.format = .json
        XCTAssertFalse(draft.reviewed, "changing options must require a fresh review")
        XCTAssertThrowsError(try ReportExporter.data(for: draft))
    }

    func testIdentifiersExcludedByDefaultAndIncludedOnlyWhenOptedIn() async throws {
        var draft = ReportDraft(report: await sampleReport())
        XCTAssertFalse(draft.render().contains("C02SERIAL123"))
        draft.options.includeIdentifiers = true
        XCTAssertTrue(draft.render().contains("Serial number"))
    }

    func testSampleReportsAreStampedAndNamed() async {
        let report = await sampleReport()
        for format in ReportFormat.allCases where format != .json {
            var o = ReportOptions(); o.format = format
            XCTAssertTrue(ReportDraft(report: report, options: o).render().contains("SAMPLE DATA"))
        }
        XCTAssertTrue(ReportExporter.suggestedFileName(for: report, format: .markdown).hasPrefix("MacCheck-SAMPLE-"))
        var o = ReportOptions(); o.format = .json
        XCTAssertTrue(ReportDraft(report: report, options: o).render().contains("\"isSampleData\" : true"))
    }

    func testRenderedReportIsRedacted() {
        let now = Date()
        let check = CheckResult(id: "x", area: .storage, title: "Storage", status: .ok, summary: "Path /Users/anna/x mail anna@example.com",
                                startedAt: now, finishedAt: now)
        let report = ScanReport(kind: .full, createdAt: now, finishedAt: now, appVersion: "t", device: nil,
                                results: [check], isSampleData: false)
        let text = ReportDraft(report: report).render()
        XCTAssertFalse(text.contains("anna"))
        XCTAssertTrue(text.contains("/Users/<user>/x"))
    }

    func testLogExcerptsExcludedByDefault() {
        let now = Date()
        let doc = AppDoctorResult(appName: "Notes", bundleIdentifier: "com.example.Notes", appVersion: "1", symptom: .crashes,
                                  investigatedAt: now, checks: [], repairs: [], crashCount7d: 0, hangCount7d: 0,
                                  lastReportDate: nil,
                                  logExcerpts: [LogEntrySummary(date: now, level: "Fault", subsystem: nil, message: "UNIQUE-LOG-LINE")])
        let report = ScanReport(kind: .appDoctor, createdAt: now, finishedAt: now, appVersion: "t", device: nil,
                                results: [], appDoctor: doc, isSampleData: false)
        var draft = ReportDraft(report: report)
        XCTAssertFalse(draft.render().contains("UNIQUE-LOG-LINE"))
        draft.options.includeLogExcerpts = true
        XCTAssertTrue(draft.render().contains("UNIQUE-LOG-LINE"))
    }

    func testWriteToFile() async throws {
        var draft = ReportDraft(report: await sampleReport())
        draft.markReviewed()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maccheck-test-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try ReportExporter.write(draft, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# MacCheck report"))
        XCTAssertTrue(text.contains("Nothing was uploaded"))
    }
}

final class HistoryTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("maccheck-history-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func report(at date: Date, serial: Bool = false) -> ScanReport {
        var m = [Measurement(key: "hw.chip", label: "Chip", display: "Apple M4", source: .sample)]
        if serial { m.append(Measurement(key: "hw.serial", label: "Serial", display: "C02SECRET", source: .sample, isSensitive: true)) }
        let c = CheckResult(id: "hardware", area: .hardware, title: "Hardware", status: .info, summary: "",
                            startedAt: date, finishedAt: date, measurements: m)
        return ScanReport(kind: .full, createdAt: date, finishedAt: date, appVersion: "t", device: nil,
                          results: [c], isSampleData: true)
    }

    func testSaveListLoadDeleteRoundTrip() throws {
        let store = HistoryStore(directory: dir)
        let r = report(at: Date())
        try store.save(r)
        XCTAssertEqual(store.list().map(\.id), [r.id])
        XCTAssertEqual(try store.load(r.id).results.first?.measurement("hw.chip")?.display, "Apple M4")
        try store.delete(r.id)
        XCTAssertTrue(store.list().isEmpty)
    }

    func testIdentifiersNeverStored() throws {
        let store = HistoryStore(directory: dir)
        let r = report(at: Date(), serial: true)
        let url = try store.save(r)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("C02SECRET"))
    }

    func testRetentionByCountAndAge() throws {
        let store = HistoryStore(directory: dir, retention: RetentionPolicy(maxEntries: 3, maxAgeDays: 30))
        let now = Date()
        try store.save(report(at: now.addingTimeInterval(-40 * 86_400)), now: now) // too old: pruned
        for i in 0..<5 { try store.save(report(at: now.addingTimeInterval(Double(-i) * 60)), now: now) }
        let list = store.list()
        XCTAssertEqual(list.count, 3)
        XCTAssertTrue(list.allSatisfy { now.timeIntervalSince($0.createdAt) < 30 * 86_400 })
    }

    func testClearAllOnlyRemovesScanFiles() throws {
        let store = HistoryStore(directory: dir)
        try store.save(report(at: Date()))
        let other = dir.appendingPathComponent("keep-me.txt")
        try Data("x".utf8).write(to: other)
        try store.clearAll()
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
}
