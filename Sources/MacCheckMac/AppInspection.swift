#if os(macOS)
import AppKit
import Foundation
import Security
import SystemConfiguration
import MacCheckCore

// App Doctor's native sources. Read-only: reads bundles, the user's diagnostic reports folder and
// the unified log via Apple's `log` tool. No Full Disk Access, no private APIs.
//
// STATUS: written on Windows, NOT yet compiled or run on a Mac. See docs/MAC-TEST-CHECKLIST.md.

enum AppInspector {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func listApps() -> [AppListing] {
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                     home.appendingPathComponent("Applications").path]
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        var seen = Set<String>()
        var out: [AppListing] = []

        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return }
            seen.insert(path)
            let info = (try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))).flatMap(BundleInfoReader.read)
            out.append(AppListing(name: info?.name ?? url.deletingPathExtension().lastPathComponent, path: path,
                                  bundleIdentifier: info?.bundleIdentifier, isRunning: running.contains(path)))
        }

        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, root == "/Applications" {
                    // One level of vendor folders (e.g. /Applications/Adobe Photoshop 2025/…)
                    for sub in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    where sub.pathExtension == "app" { add(sub) }
                }
            }
        }
        // Running regular apps from elsewhere (e.g. Downloads) too.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let url = app.bundleURL { add(url) }
        }
        return out.sorted { ($0.isRunning ? 0 : 1, $0.name.lowercased()) < ($1.isRunning ? 0 : 1, $1.name.lowercased()) }
    }

    static func inspect(path: String) async throws -> AppInfo {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue, url.pathExtension == "app" else {
            throw CollectorUnavailableError("That isn't an app bundle.")
        }
        let bundleSrc = DataSource.files("App bundle")
        var problems: [String] = []
        let info = (try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))).flatMap(BundleInfoReader.read)
        if info == nil { problems.append("The app's Info.plist is missing or unreadable.") }

        var app = AppInfo(name: info?.name ?? url.deletingPathExtension().lastPathComponent, path: url.standardizedFileURL.path,
                          bundleIdentifier: info?.bundleIdentifier, executableName: info?.executableName,
                          version: info?.version, build: info?.build, minimumSystemVersion: info?.minimumSystemVersion)

        // Architectures from the Mach-O header (first 4 KB only).
        if let exe = info?.executableName {
            let exeURL = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(exe)
            if let handle = try? FileHandle(forReadingFrom: exeURL) {
                let head = (try? handle.read(upToCount: 4096)) ?? Data()
                try? handle.close()
                app.architectures = MachOReader.architectures(of: head).map { .value($0, source: bundleSrc) }
                    ?? .unavailable(reason: "The executable's header couldn't be read as Mach-O.")
            } else {
                problems.append("The app's executable (\(exe)) is missing.")
                app.architectures = .unavailable(reason: "Executable missing.")
            }
        }

        app.signature = await signature(of: url)
        app.isQuarantined = .value(getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0,
                                   source: .files("Extended attributes (read-only)"))
        app.isFromAppStore = .value(fm.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path),
                                    source: bundleSrc)
        if let id = info?.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            app.isRunning = .value(!running.isEmpty, source: .api("NSRunningApplication"))
            let translocated = running.contains { $0.bundleURL?.path.contains("/AppTranslocation/") == true }
            app.isTranslocated = .value(translocated || path.contains("/AppTranslocation/"), source: .api("NSRunningApplication"))
        }
        app.bundleProblems = problems
        return app
    }

    /// Code signature, read-only, via the Security framework. Full validation is bounded in time.
    static func signature(of url: URL) async -> Reading<SignatureStatus> {
        let src = DataSource.api("Security framework (SecStaticCode)")
        var codeRef: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &codeRef) == errSecSuccess, let code = codeRef else {
            return .unavailable(reason: "The signature couldn't be read.")
        }
        // Full check (including sealed resources) can be slow for very large apps.
        let full: OSStatus
        do {
            full = try await withDeadline(seconds: 15) { SecStaticCodeCheckValidityWithErrors(code, [], nil, nil) }
        } catch {
            return .unavailable(reason: "The signature check took too long (very large app).")
        }
        if full == OSStatus(errSecCSUnsigned) { return .value(.unsigned, source: src) }
        if full != errSecSuccess {
            let message = (SecCopyErrorMessageString(full, nil) as String?) ?? "error \(full)"
            return .value(.invalid(reason: message), source: src)
        }

        var infoRef: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        let info = infoRef as? [String: Any] ?? [:]
        let flags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        if flags & 0x2 != 0 { return .value(.adHoc, source: src) } // kSecCodeSignatureAdhoc

        func satisfies(_ requirement: String) -> Bool {
            var req: SecRequirement?
            guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let r = req else { return false }
            return SecStaticCodeCheckValidity(code, [], r) == errSecSuccess
        }
        let apple = satisfies("anchor apple")
        // Note: macOS evaluates the "notarized" requirement against its own ticket store.
        let notarized: Bool? = apple ? nil : satisfies("notarized")
        return .value(.valid(notarized: notarized, teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
                             isAppleSigned: apple), source: src)
    }

    /// Recent diagnostic reports for this user. Bounded: last 30 days, newest 300 files, 512 KB each.
    static func diagnosticReports() -> Reading<[CrashReportSummary]> {
        let fm = FileManager.default
        let dirs = [home.appendingPathComponent("Library/Logs/DiagnosticReports"),
                    home.appendingPathComponent("Library/Logs/DiagnosticReports/Retired"),
                    URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")]
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        var files: [(URL, Date)] = []
        var readable = 0
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            readable += 1
            for item in items {
                let ext = item.pathExtension.lowercased()
                guard ["ips", "crash", "hang", "spin", "diag"].contains(ext),
                      let v = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      v.isRegularFile == true, let date = v.contentModificationDate, date >= cutoff else { continue }
                files.append((item, date))
            }
        }
        guard readable > 0 else {
            return .unavailable(reason: "The diagnostic reports folder couldn't be read.")
        }
        var out: [CrashReportSummary] = []
        for (url, modified) in files.sorted(by: { $0.1 > $1.1 }).prefix(300) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = (try? handle.read(upToCount: DiagnosticReportParser.maxBytes)) ?? Data()
            try? handle.close()
            if var summary = DiagnosticReportParser.parse(fileName: url.lastPathComponent, data: data) {
                if summary.date == nil { summary.date = modified }
                if let d = summary.detail { summary.detail = MacPlatform.redactor()(d) }
                out.append(summary)
            }
        }
        return .value(out, source: .files("~/Library/Logs/DiagnosticReports"))
    }

    /// Errors and faults from the last 30 minutes for this app's process, via `log show`.
    static func recentLogs(_ app: AppInfo) -> Reading<[LogEntrySummary]> {
        let process = app.executableName ?? app.name
        guard UnifiedLogParser.isSafePredicateValue(process) else {
            return .unavailable(reason: "The app's process name contains characters MacCheck won't put into a log query.")
        }
        let predicate = "process == \"\(process)\" AND (messageType == error OR messageType == fault)"
        do {
            let data = try BoundedTool.run(.log, ["show", "--style", "ndjson", "--last", "30m", "--predicate", predicate],
                                           timeout: 25, maxOutputBytes: 4 * 1024 * 1024)
            let entries = UnifiedLogParser.parse(ndjson: String(decoding: data, as: UTF8.self), redactor: MacPlatform.redactor())
            return .value(entries, source: .tool("log show (last 30 min)"))
        } catch {
            return .unavailable(reason: "The system log couldn't be read: \(error).")
        }
    }

    static func savedStateURL(_ bundleID: String) -> URL {
        home.appendingPathComponent(RepairProposal.savedStateRelativePath(for: bundleID), isDirectory: true)
    }

    static func savedStateExists(_ bundleID: String) -> Bool? {
        guard RepairProposal.isSafeBundleIdentifier(bundleID) else { return nil }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: savedStateURL(bundleID).path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// The only code in MacCheck that changes anything on disk. Reached only through RepairCoordinator (consent-gated).
public struct MacRepairPerformer: RepairPerformer {
    public init() {}

    public struct Refused: Error, CustomStringConvertible { public var description: String }

    public func perform(_ proposal: RepairProposal) async throws -> RepairExecution {
        guard case let .moveSavedStateToTrash(bundleID) = proposal.action else {
            throw Refused(description: "This action doesn't change anything and is opened directly.")
        }
        guard RepairProposal.isSafeBundleIdentifier(bundleID) else { throw Refused(description: "Unexpected app identifier.") }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            throw Refused(description: "Please quit the app first, then try again. MacCheck doesn't quit apps for you.")
        }
        let target = AppInspector.savedStateURL(bundleID)
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        guard (attrs[.type] as? FileAttributeType) == .typeDirectory else {
            throw Refused(description: "The saved-state item isn't a normal folder, so MacCheck left it alone.")
        }
        var resulting: NSURL?
        try FileManager.default.trashItem(at: target, resultingItemURL: &resulting)
        return RepairExecution(proposalID: proposal.id, performedAt: Date(),
                               summary: "Moved \(bundleID).savedState to the Trash.",
                               undoHint: proposal.howToUndo, resultingPath: (resulting as URL?)?.path)
    }
}

extension MacPlatform {
    /// Values specific to this Mac that are always redacted (account name, full name, computer name).
    public static func redactor() -> Redactor { cachedRedactor }

    // SCDynamicStoreCopyComputerName is fast; Host.current() can block on name lookups.
    private static let cachedRedactor = Redactor(knownValues: [
        NSUserName(), NSFullUserName(), (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "",
    ])

    public static func appDoctorSources() -> AppDoctorSources {
        AppDoctorSources(
            listApps: { AppInspector.listApps() },
            inspectApp: { path in try await AppInspector.inspect(path: path) },
            diagnosticReports: { AppInspector.diagnosticReports() },
            recentLogs: { app in AppInspector.recentLogs(app) },
            savedStateExists: { id in AppInspector.savedStateExists(id) },
            isSample: false)
    }

    /// Opens a Settings pane / app handoff. Changes nothing.
    @MainActor
    public static func open(_ link: SystemSettingsLink) {
        guard let raw = link.url else { return }
        if raw.hasPrefix("bundle:") {
            let id = String(raw.dropFirst("bundle:".count))
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            }
        } else if let url = URL(string: raw) {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    public static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
#endif
