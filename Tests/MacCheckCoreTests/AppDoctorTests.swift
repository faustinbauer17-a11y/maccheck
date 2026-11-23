import XCTest
@testable import MacCheckCore

private let src = DataSource("Test", kind: .fake)

func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw XCTSkip("fixture \(name) missing")
    }
    return try Data(contentsOf: url)
}

final class ParserTests: XCTestCase {

    func testParsesIPSCrash() throws {
        let name = "Notes-2025-06-02-101112.ips"
        let r = try XCTUnwrap(DiagnosticReportParser.parse(fileName: name, data: try fixture(name)))
        XCTAssertEqual(r.kind, .crash)
        XCTAssertEqual(r.processName, "Notes")
        XCTAssertEqual(r.bundleIdentifier, "com.example.Notes")
        XCTAssertEqual(r.appVersion, "4.12")
        XCTAssertEqual(r.exceptionType, "EXC_BAD_ACCESS")
        XCTAssertEqual(r.signal, "SIGSEGV")
        XCTAssertEqual(r.terminationReason, "SIGNAL: Segmentation fault: 11")
        XCTAssertNotNil(r.date)
    }

    func testParsesIPSLaunchFailureWithDyldHint() throws {
        let name = "Launcher-2025-06-01-080000.ips"
        let r = try XCTUnwrap(DiagnosticReportParser.parse(fileName: name, data: try fixture(name)))
        XCTAssertEqual(r.terminationReason, "DYLD: Library missing")
        XCTAssertTrue(r.detail?.contains("Library not loaded") ?? false)
    }

    func testParsesLegacyTextCrashAndHang() throws {
        let crashName = "OldApp_2024-01-05-120000_MacBook-Air.crash"
        let c = try XCTUnwrap(DiagnosticReportParser.parse(fileName: crashName, data: try fixture(crashName)))
        XCTAssertEqual(c.kind, .crash)
        XCTAssertEqual(c.processName, "OldApp")
        XCTAssertEqual(c.exceptionType, "EXC_BAD_INSTRUCTION")
        XCTAssertEqual(c.signal, "SIGILL")
        XCTAssertEqual(c.appVersion, "1.3")

        let hangName = "Mail_2025-06-02-090000_MacBook-Air.hang"
        let h = try XCTUnwrap(DiagnosticReportParser.parse(fileName: hangName, data: try fixture(hangName)))
        XCTAssertEqual(h.kind, .hang)
        XCTAssertEqual(h.processName, "Mail")
        XCTAssertEqual(h.bundleIdentifier, "com.apple.mail")
    }

    func testGarbageIsRejected() {
        XCTAssertNil(DiagnosticReportParser.parse(fileName: "x.ips", data: Data("not a report".utf8)))
        XCTAssertNil(DiagnosticReportParser.parse(fileName: "x.ips", data: Data()))
    }

    func testMatching() {
        let r = CrashReportSummary(fileName: "Notes-2025.ips", date: nil, kind: .crash, processName: "Notes", bundleIdentifier: nil)
        XCTAssertTrue(DiagnosticReportParser.matches(r, bundleIdentifier: "com.example.Notes", executableName: "Notes", appName: "Notes"))
        let other = CrashReportSummary(fileName: "x.ips", date: nil, kind: .crash, processName: "Notes", bundleIdentifier: "com.other")
        XCTAssertFalse(DiagnosticReportParser.matches(other, bundleIdentifier: "com.example.Notes", executableName: "Notes", appName: "Notes"))
    }

    func testMachOArchitectures() {
        func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        func be(_ v: UInt32) -> [UInt8] { le(v).reversed() }
        let thinArm = Data(le(0xFEED_FACF) + le(0x0100_000C) + le(0) + [UInt8](repeating: 0, count: 20))
        XCTAssertEqual(MachOReader.architectures(of: thinArm), [.arm64])
        let thinIntel = Data(le(0xFEED_FACF) + le(0x0100_0007) + le(3) + [UInt8](repeating: 0, count: 20))
        XCTAssertEqual(MachOReader.architectures(of: thinIntel), [.x86_64])
        var fat = be(0xCAFE_BABE) + be(2)
        fat += be(0x0100_0007) + be(3) + be(0x4000) + be(0x1000) + be(14)
        fat += be(0x0100_000C) + be(2) + be(0x8000) + be(0x1000) + be(14)
        XCTAssertEqual(MachOReader.architectures(of: Data(fat)), [.x86_64, .arm64e])
        XCTAssertNil(MachOReader.architectures(of: Data("#!/bin/sh\necho".utf8)))
        // Java class file shares the 0xCAFEBABE magic but has a large "count"
        XCTAssertNil(MachOReader.architectures(of: Data(be(0xCAFE_BABE) + be(0x0000_0034))))
    }

    func testInfoPlistAndDiskutil() throws {
        let info = try XCTUnwrap(BundleInfoReader.read(plistData: try fixture("Sample-Info.plist")))
        XCTAssertEqual(info.bundleIdentifier, "com.example.Notes")
        XCTAssertEqual(info.minimumSystemVersion, "14.0")
        let disk = try XCTUnwrap(DiskutilInfoParser.parse(plistData: try fixture("diskutil-info.plist")))
        XCTAssertEqual(disk.smartStatus, "Verified")
        XCTAssertEqual(disk.isSolidState, true)
    }

    func testLogNDJSONKeepsErrorsOnlyAndRedacts() throws {
        let text = String(decoding: try fixture("log-show.ndjson"), as: UTF8.self)
        let entries = UnifiedLogParser.parse(ndjson: text, redactor: Redactor())
        XCTAssertEqual(entries.map(\.level), ["Error", "Fault"])
        XCTAssertFalse(entries[0].message.contains("anna"))
        XCTAssertFalse(entries[0].message.contains("abc123SECRET"))
        XCTAssertFalse(entries[1].message.contains("192.168.1.23"))
    }

    func testPredicateValuesAreRestricted() {
        XCTAssertTrue(UnifiedLogParser.isSafePredicateValue("Google Chrome Helper"))
        XCTAssertFalse(UnifiedLogParser.isSafePredicateValue(#"x" OR 1==1 OR "y"#))
        XCTAssertFalse(UnifiedLogParser.isSafePredicateValue(""))
    }

    func testVersionCompare() {
        XCTAssertTrue(VersionCompare.isLower("14.2", than: "14.10"))
        XCTAssertFalse(VersionCompare.isLower("15.0", than: "14.6"))
        XCTAssertEqual(VersionCompare.numeric("macOS 15.6.1 (24G90)"), "15.6.1")
    }
}

final class AppDoctorAnalyzerTests: XCTestCase {
    let now = DiagnosticReportParser.parseDate("2025-06-03 12:00:00 +0200")!

    func app(_ mutate: (inout AppInfo) -> Void = { _ in }) -> AppInfo {
        var a = AppInfo(name: "Notes", path: "/Applications/Notes.app", bundleIdentifier: "com.example.Notes",
                        executableName: "Notes", version: "4.13", minimumSystemVersion: "14.0",
                        architectures: .value([.arm64, .x86_64], source: src),
                        signature: .value(.valid(notarized: true, teamIdentifier: "ABCDE12345", isAppleSigned: false), source: src),
                        isQuarantined: .value(false, source: src), isTranslocated: .value(false, source: src),
                        isFromAppStore: .value(false, source: src), isRunning: .value(false, source: src))
        mutate(&a)
        return a
    }

    func crash(_ daysAgo: Double, exc: String = "EXC_BAD_ACCESS", sig: String = "SIGSEGV", term: String? = nil, version: String = "4.13") -> CrashReportSummary {
        CrashReportSummary(fileName: "Notes-x.ips", date: now.addingTimeInterval(-daysAgo * 86_400), kind: .crash,
                           processName: "Notes", bundleIdentifier: "com.example.Notes", appVersion: version,
                           exceptionType: exc, signal: sig, terminationReason: term)
    }

    func input(_ app: AppInfo, _ symptom: Symptom = .crashes, reports: [CrashReportSummary] = [],
               savedState: Bool? = nil, os: String = "macOS 15.5") -> AppDoctorInput {
        AppDoctorInput(app: app, symptom: symptom, reports: .value(reports, source: src),
                       logs: .value([], source: src), macOSVersion: os, rosettaInstalled: true,
                       savedStateExists: savedState, now: now)
    }

    func check(_ r: AppDoctorResult, _ id: String) -> CheckResult? { r.checks.first { $0.id == "app.\(id)" } }

    func testRepeatedCrashesAreProblemWithExplanationNotDiagnosis() {
        let r = AppDoctorAnalyzer.analyze(input(app(), reports: [crash(1), crash(2), crash(3), crash(40)]))
        let reports = check(r, "reports")!
        XCTAssertEqual(reports.status, .problem)
        XCTAssertEqual(r.crashCount7d, 3)
        XCTAssertTrue(reports.findings.contains { $0.id == "app.crashes.repeat" })
        let explain = reports.findings.first { $0.id == "app.crashes.explain" }
        XCTAssertEqual(explain?.kind, .possibleExplanation)
        XCTAssertNotNil(explain?.confidence)
    }

    func testNoReportsIsHonest() {
        let r = AppDoctorAnalyzer.analyze(input(app()))
        let reports = check(r, "reports")!
        XCTAssertTrue(reports.findings.contains { $0.id == "app.crashes.none" })
        XCTAssertTrue(reports.limitations.contains { $0.contains("doesn't prove") })
    }

    func testUnavailableReportsAreNotZero() {
        var i = input(app())
        i.reports = .unavailable(reason: "Folder not readable.")
        let r = AppDoctorAnalyzer.analyze(i)
        XCTAssertNil(r.crashCount7d)
        XCTAssertEqual(check(r, "reports")?.status, .unavailable)
    }

    func testCodesigningAndDyldExplanations() {
        let cs = AppDoctorAnalyzer.explain(crash(1, exc: "EXC_CRASH", sig: "SIGKILL", term: "CODESIGNING: Invalid Page"))
        XCTAssertEqual(cs?.confidence, .high)
        let dyld = AppDoctorAnalyzer.explain(CrashReportSummary(fileName: "x", date: nil, kind: .crash,
                                                                terminationReason: "DYLD: Library missing",
                                                                detail: "Library not loaded: @rpath/X.framework"))
        XCTAssertTrue(dyld?.title.contains("couldn't be loaded") ?? false)
    }

    func testOlderVersionCrashNoted() {
        let r = AppDoctorAnalyzer.analyze(input(app(), reports: [crash(1, version: "4.12")]))
        XCTAssertTrue(check(r, "reports")!.findings.contains { $0.id == "app.crashes.oldVersion" })
    }

    func testIntelOnlyAppWithoutRosetta() {
        var i = input(app { $0.architectures = .value([.x86_64], source: src) })
        i.rosettaInstalled = false
        XCTAssertEqual(check(AppDoctorAnalyzer.analyze(i), "compat")?.status, .problem)
        i.rosettaInstalled = true
        XCTAssertEqual(check(AppDoctorAnalyzer.analyze(i), "compat")?.status, .warning)
    }

    func testMinimumMacOSUnmet() {
        let r = AppDoctorAnalyzer.analyze(input(app { $0.minimumSystemVersion = "26.0" }, os: "macOS 15.5"))
        XCTAssertTrue(check(r, "compat")!.findings.contains { $0.id == "app.minOS.unmet" })
    }

    func testDamagedInstallClues() {
        let r = AppDoctorAnalyzer.analyze(input(app {
            $0.signature = .value(.invalid(reason: "a sealed resource is missing or invalid"), source: src)
            $0.isTranslocated = .value(true, source: src)
            $0.bundleProblems = ["The app's executable is missing."]
        }, .wontOpen))
        let integrity = check(r, "integrity")!
        XCTAssertEqual(integrity.status, .problem)
        XCTAssertTrue(integrity.findings.contains { $0.id == "app.signature.invalid" })
        XCTAssertTrue(integrity.findings.contains { $0.id == "app.translocated.yes" })
        XCTAssertTrue(r.repairs.contains { $0.action == .revealInFinder(path: "/Applications/Notes.app") })
        // Never suggests removing quarantine or bypassing Gatekeeper
        let text = r.repairs.map { "\($0.title) \($0.whatHappens)" }.joined().lowercased()
        XCTAssertFalse(text.contains("xattr") || text.contains("spctl") || text.contains("disable gatekeeper"))
    }

    func testPermissionsGuidanceLinksToPanes() {
        let r = AppDoctorAnalyzer.analyze(input(app(), .permissions))
        let perms = check(r, "permissions")!
        XCTAssertTrue(perms.findings.contains { $0.links.first?.url?.contains("Privacy_Camera") ?? false })
        XCTAssertTrue(r.repairs.contains { $0.id == "open-privacy" && $0.kind == .handoff })
    }

    func testSavedStateResetOnlyProposedWhenRelevantAndSafe() {
        XCTAssertTrue(AppDoctorAnalyzer.analyze(input(app(), .crashes, savedState: true)).repairs
            .contains { $0.kind == .change })
        XCTAssertFalse(AppDoctorAnalyzer.analyze(input(app(), .crashes, savedState: false)).repairs.contains { $0.kind == .change })
        XCTAssertFalse(AppDoctorAnalyzer.analyze(input(app(), .slow, savedState: true)).repairs.contains { $0.kind == .change })
        XCTAssertFalse(AppDoctorAnalyzer.analyze(input(app { $0.bundleIdentifier = "../../etc" }, .crashes, savedState: true))
            .repairs.contains { $0.kind == .change })
        let p = AppDoctorAnalyzer.analyze(input(app(), .crashes, savedState: true)).repairs.first { $0.kind == .change }!
        XCTAssertFalse(p.sideEffects.isEmpty)
        XCTAssertFalse(p.howToUndo.isEmpty)
        XCTAssertEqual(p.confidence, .low)
    }

    func testSystemContextUsesSnapshots() {
        var i = input(app(), .freezes)
        i.performance = PerformanceSnapshot(sampleWindowSeconds: 1, memoryPressure: .value(.critical, source: src))
        let r = AppDoctorAnalyzer.analyze(i)
        XCTAssertEqual(check(r, "system")?.status, .problem)
    }
}

final class ConsentTests: XCTestCase {
    struct FakePerformer: RepairPerformer {
        let log: Log
        final class Log: @unchecked Sendable { var performed: [String] = [] }
        func perform(_ p: RepairProposal) async throws -> RepairExecution {
            log.performed.append(p.id)
            return RepairExecution(proposalID: p.id, performedAt: Date(), summary: "moved", undoHint: "Put Back", resultingPath: nil)
        }
    }

    let change = RepairProposal(id: "reset-saved-state:com.example.Notes", kind: .change,
                                action: .moveSavedStateToTrash(bundleIdentifier: "com.example.Notes"), title: "Reset",
                                issue: "i", evidence: [], whatHappens: "w", sideEffects: ["s"], howToUndo: "u",
                                verification: "v", confidence: .low)
    let other = RepairProposal(id: "reset-saved-state:com.other", kind: .change,
                               action: .moveSavedStateToTrash(bundleIdentifier: "com.other"), title: "Reset",
                               issue: "i", evidence: [], whatHappens: "w", sideEffects: ["s"], howToUndo: "u",
                               verification: "v", confidence: .low)

    func testConsentRequiresAcknowledgement() {
        let gate = ConsentGate()
        XCTAssertThrowsError(try gate.grant(for: change, acknowledgedSideEffects: false)) {
            XCTAssertEqual($0 as? ConsentError, .sideEffectsNotAcknowledged)
        }
    }

    func testTokenIsSingleUseBoundAndExpiring() async throws {
        let log = FakePerformer.Log()
        let coordinator = RepairCoordinator(gate: ConsentGate(validity: 60), performer: FakePerformer(log: log))
        let t0 = Date()
        let token = try coordinator.gate.grant(for: change, acknowledgedSideEffects: true, now: t0)

        do { _ = try await coordinator.execute(other, token: token, now: t0); XCTFail() }
        catch { XCTAssertEqual(error as? ConsentError, .tokenForDifferentAction) }

        do { _ = try await coordinator.execute(change, token: token, now: t0.addingTimeInterval(61)); XCTFail() }
        catch { XCTAssertEqual(error as? ConsentError, .expired) }

        let fresh = try coordinator.gate.grant(for: change, acknowledgedSideEffects: true, now: t0)
        _ = try await coordinator.execute(change, token: fresh, now: t0.addingTimeInterval(5))
        do { _ = try await coordinator.execute(change, token: fresh, now: t0.addingTimeInterval(6)); XCTFail() }
        catch { XCTAssertEqual(error as? ConsentError, .alreadyUsed) }

        XCTAssertEqual(log.performed, [change.id], "performer runs only with valid, unused consent")
    }

    func testHandoffsCannotGoThroughChangePath() {
        let handoff = RepairProposal(id: "open", kind: .handoff, action: .openLink(SettingsLinks.storage), title: "Open",
                                     issue: "", evidence: [], whatHappens: "", sideEffects: [], howToUndo: "",
                                     verification: "", confidence: .high)
        XCTAssertThrowsError(try ConsentGate().grant(for: handoff, acknowledgedSideEffects: true))
    }

    func testVerificationNeedsNewEvidence() {
        let at = Date()
        let exec = RepairExecution(proposalID: "x", performedAt: at, summary: "moved", undoHint: "Put Back", resultingPath: nil)
        let before = CrashReportSummary(fileName: "a", date: at.addingTimeInterval(-3600), kind: .crash)
        let after = CrashReportSummary(fileName: "b", date: at.addingTimeInterval(600), kind: .crash)
        let later = at.addingTimeInterval(1200)

        XCTAssertEqual(RepairVerifier.verify(execution: exec, symptom: .crashes, reportsForApp: [before],
                                             appUsedSinceChange: false, now: later).outcome, .inconclusive)
        let improved = RepairVerifier.verify(execution: exec, symptom: .crashes, reportsForApp: [before],
                                             appUsedSinceChange: true, now: later)
        XCTAssertEqual(improved.outcome, .improved)
        XCTAssertTrue(improved.details.contains { $0.contains("not proof") })
        let again = RepairVerifier.verify(execution: exec, symptom: .crashes, reportsForApp: [before, after],
                                          appUsedSinceChange: true, now: later)
        XCTAssertEqual(again.outcome, .noChange)
        XCTAssertTrue(again.details.contains { $0.contains("Put Back") })
    }

    func testBundleIdentifierSafety() {
        XCTAssertTrue(RepairProposal.isSafeBundleIdentifier("com.apple.Safari"))
        XCTAssertFalse(RepairProposal.isSafeBundleIdentifier("../x"))
        XCTAssertFalse(RepairProposal.isSafeBundleIdentifier("com/evil"))
        XCTAssertFalse(RepairProposal.isSafeBundleIdentifier(""))
    }
}
