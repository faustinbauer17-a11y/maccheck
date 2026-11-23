import Foundation

/// Turns the evidence about one app into findings, plain-language explanations and safe proposals.
/// Pure logic: every rule here is covered by unit tests that run on Windows.
public enum AppDoctorAnalyzer {

    public static func analyze(_ input: AppDoctorInput) -> AppDoctorResult {
        let started = Date()
        let app = input.app
        let mine = matchingReports(input)
        let week = mine.filter { ($0.date.map { input.now.timeIntervalSince($0) } ?? .infinity) <= 7 * 86_400 }

        var checks: [CheckResult] = [
            details(input, started: started),
            reportsCheck(input, mine: mine, week: week, started: started),
            compatibility(input, started: started),
            integrity(input, mine: mine, started: started),
            logsCheck(input, started: started),
        ]
        if input.symptom == .permissions || input.symptom == .somethingElse {
            checks.append(permissions(input, started: started))
        }
        checks.append(systemContext(input, started: started))

        return AppDoctorResult(
            appName: app.name, bundleIdentifier: app.bundleIdentifier, appVersion: app.version,
            symptom: input.symptom, investigatedAt: input.now, checks: checks,
            repairs: proposals(input, week: week),
            crashCount7d: input.reports.value == nil ? nil : week.filter { $0.kind == .crash }.count,
            hangCount7d: input.reports.value == nil ? nil : week.filter { $0.kind == .hang }.count,
            lastReportDate: mine.compactMap(\.date).max(),
            logExcerpts: input.logs.value ?? [])
    }

    public static func matchingReports(_ input: AppDoctorInput) -> [CrashReportSummary] {
        (input.reports.value ?? [])
            .filter { DiagnosticReportParser.matches($0, bundleIdentifier: input.app.bundleIdentifier,
                                                     executableName: input.app.executableName, appName: input.app.name) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: Checks

    static func builder(_ id: String, _ title: String, _ input: AppDoctorInput, _ started: Date) -> ResultBuilder {
        ResultBuilder(id: "app.\(id)", area: nil, title: title, started: started, isSample: input.isSample)
    }

    static func src(_ input: AppDoctorInput, _ name: String, _ kind: SourceKind) -> DataSource {
        input.isSample ? .sample : DataSource(name, kind: kind)
    }

    static func details(_ input: AppDoctorInput, started: Date) -> CheckResult {
        let app = input.app
        var b = builder("details", "About this app", input, started)
        let bundle = src(input, "App bundle Info.plist", .fileSystem)
        b.add(.value(app.name, source: bundle), key: "app.name", label: "App") { $0 }
        if let v = app.version {
            b.add(.value(app.build.map { "\(v) (\(String($0.prefix(20))))" } ?? v, source: bundle), key: "app.version", label: "Version") { $0 }
        }
        if let id = app.bundleIdentifier { b.add(.value(id, source: bundle), key: "app.bundleId", label: "Bundle ID") { $0 } }
        b.add(.value(Redactor()(app.path), source: bundle), key: "app.path", label: "Location") { $0 }
        b.add(app.architectures, key: "app.arch", label: "Built for") { archs in
            Array(Set(archs.map(\.display))).sorted().joined(separator: " + ")
        }
        b.add(app.isFromAppStore, key: "app.appStore", label: "From the App Store", reportUnavailable: false) { $0 ? "Yes" : "No" }
        b.add(app.isRunning, key: "app.running", label: "Running now", reportUnavailable: false) { $0 ? "Yes" : "No" }
        return b.build(informational: true)
    }

    static func reportsCheck(_ input: AppDoctorInput, mine: [CrashReportSummary], week: [CrashReportSummary], started: Date) -> CheckResult {
        var b = builder("reports", "Crash and hang reports", input, started)
        b.limit("Only reports macOS saved for your user account are read (Library/Logs/DiagnosticReports). Reports are summarised; full contents are not stored or exported.")
        b.limit("macOS deletes old reports on its own, so an empty list doesn't prove the app never crashed.")

        guard let src = input.reports.source else {
            b.add(input.reports, key: "app.reports", label: "Diagnostic reports") { _ in "" }
            return b.build()
        }
        let crashes7 = week.filter { $0.kind == .crash }
        let hangs7 = week.filter { $0.kind == .hang }
        b.add(.value(crashes7.count, source: src), key: "app.crashes7d", label: "Crashes, last 7 days", numeric: { Double($0) }) { "\($0)" }
        b.add(.value(hangs7.count, source: src), key: "app.hangs7d", label: "Hangs, last 7 days", numeric: { Double($0) }) { "\($0)" }
        b.add(.value(mine.count, source: src), key: "app.reportsTotal", label: "All saved reports for this app", numeric: { Double($0) }) { "\($0)" }
        if let last = mine.first, let d = last.date {
            b.add(.value("\(last.kind.title), \(Fmt.isoDate(d))", source: src), key: "app.lastReport", label: "Most recent") { $0 }
        }

        if crashes7.count >= 3 {
            b.finding("app.crashes.many", .problem, "Crashed \(crashes7.count) times this week",
                      "macOS saved \(crashes7.count) crash reports for \(input.app.name) in the last 7 days.")
        } else if !crashes7.isEmpty {
            b.finding("app.crashes.some", .warning, "Crashed \(crashes7.count) time\(crashes7.count == 1 ? "" : "s") this week",
                      "macOS saved crash reports for \(input.app.name) in the last 7 days.")
        } else if input.symptom == .crashes {
            b.finding("app.crashes.none", .fact, "No crash reports this week",
                      "No crash report was found for \(input.app.name) in the last 7 days. If it closes without a report, it may be quitting on purpose, or being closed by macOS for low memory.")
        }

        if !hangs7.isEmpty {
            b.finding("app.hangs", .warning, "Stopped responding \(hangs7.count) time\(hangs7.count == 1 ? "" : "s") this week",
                      "macOS recorded the app as not responding (spinning beachball).",
                      advice: ["Note what you were doing when it froze — opening a big file, syncing, printing — it helps narrow it down."])
        } else if input.symptom == .freezes {
            b.finding("app.hangs.none", .fact, "No hang reports found",
                      "macOS writes hang reports only for longer freezes. Short stalls are usually caused by memory pressure, a slow disk or the network — see System context.")
        }

        // Repeats with the same signature
        let groups = Dictionary(grouping: week.filter { $0.kind == .crash && !$0.signature.isEmpty }, by: \.signature)
        if let (sig, group) = groups.max(by: { $0.value.count < $1.value.count }), group.count >= 2 {
            b.finding("app.crashes.repeat", .fact, "The same crash keeps repeating",
                      "\(group.count) crashes this week share the same cause (\(sig)). A repeating crash points to one consistent trigger rather than random bad luck.")
        }

        // Explain the most recent crash in plain language
        if let latest = week.first(where: { $0.kind == .crash }) ?? mine.first(where: { $0.kind == .crash }) {
            if let explanation = explain(latest) {
                b.findings.append(Finding(id: "app.crashes.explain", kind: .possibleExplanation, title: explanation.title,
                                          detail: explanation.detail, evidence: input.isSample ? .sample : .inferred,
                                          confidence: explanation.confidence, advice: explanation.advice))
            }
            if let reportVersion = latest.appVersion, let current = input.app.version, reportVersion != current {
                b.finding("app.crashes.oldVersion", .fact, "Latest crash was in an older version",
                          "The most recent crash happened in version \(reportVersion); version \(current) is installed now. It may already be fixed.")
            }
        }
        return b.build()
    }

    struct Explanation {
        var title: String
        var detail: String
        var confidence: Confidence
        var advice: [String]
    }

    /// Plain-language reading of a crash summary. Always phrased as a possibility.
    static func explain(_ r: CrashReportSummary) -> Explanation? {
        let term = (r.terminationReason ?? "").uppercased()
        let detail = r.detail ?? ""
        let exc = (r.exceptionType ?? "").uppercased()
        let sig = (r.signal ?? "").uppercased()

        if term.contains("CODESIGNING") {
            return Explanation(title: "macOS stopped the app because its code signature didn't check out",
                               detail: "This usually means the app's files were changed or damaged after it was installed.",
                               confidence: .high,
                               advice: ["Delete the app and reinstall it from the App Store or the developer's website."])
        }
        if term.contains("DYLD") || detail.contains("Library not loaded") || detail.contains("Symbol not found") {
            return Explanation(title: "A component the app needs couldn't be loaded",
                               detail: "The app tried to load a part of itself or of macOS that is missing or incompatible. Common after an incomplete update, or when the app needs a newer macOS.",
                               confidence: .high,
                               advice: ["Reinstall the latest version of the app.", "Check the app's macOS requirements."])
        }
        if exc == "EXC_RESOURCE" {
            return Explanation(title: "The app went over a resource limit",
                               detail: "macOS recorded the app using more CPU, memory or disk writes than allowed for a while.",
                               confidence: .medium, advice: ["Update the app; check whether a particular file or project triggers it."])
        }
        if sig == "SIGKILL" || term.contains("JETSAM") || term.contains("RUNNINGBOARD") {
            return Explanation(title: "The app was stopped by the system",
                               detail: "SIGKILL means something stopped it from outside — often macOS freeing memory, a watchdog after a long freeze, or a Force Quit.",
                               confidence: .medium, advice: ["Check memory pressure in Performance while the app is in use."])
        }
        if exc == "EXC_BAD_ACCESS" || sig == "SIGSEGV" || sig == "SIGBUS" {
            return Explanation(title: "The app tried to use memory it shouldn't have",
                               detail: "This is almost always a bug in the app or in a plug-in/extension it loads — not a hardware fault.",
                               confidence: .medium,
                               advice: ["Update the app.", "If it started after installing a plug-in or extension, try without it.",
                                        "Send the crash report to the developer (from the crash dialog)."])
        }
        if exc == "EXC_BAD_INSTRUCTION" || exc == "EXC_BREAKPOINT" || sig == "SIGTRAP" || sig == "SIGILL" {
            return Explanation(title: "The app hit one of its own safety checks",
                               detail: "The app detected an impossible situation and stopped on purpose. This points to a bug in the app, sometimes triggered by unusual data or settings.",
                               confidence: .medium, advice: ["Update the app.", "Report it to the developer."])
        }
        if sig == "SIGABRT" || exc == "EXC_CRASH" {
            return Explanation(title: "The app stopped itself after an error",
                               detail: "An 'abort' usually means the app found a problem it couldn't handle. Corrupted preferences or saved data can occasionally trigger it.",
                               confidence: .low, advice: ["Update the app.", "Report it to the developer."])
        }
        if exc == "EXC_GUARD" {
            return Explanation(title: "The app misused a protected system resource",
                               detail: "This is a bug in the app.", confidence: .medium, advice: ["Update the app."])
        }
        return nil
    }

    static func compatibility(_ input: AppDoctorInput, started: Date) -> CheckResult {
        let app = input.app
        var b = builder("compat", "Compatibility", input, started)
        if let os = input.macOSVersion {
            b.add(.value(os, source: src(input, "ProcessInfo", .publicAPI)), key: "app.macos", label: "This Mac runs") { $0 }
        }
        if let min = app.minimumSystemVersion {
            b.add(.value("macOS \(min) or later", source: src(input, "App bundle Info.plist", .fileSystem)),
                  key: "app.minOS", label: "App requires") { $0 }
            if let os = input.macOSVersion.flatMap(VersionCompare.numeric), VersionCompare.isLower(os, than: min) {
                b.finding("app.minOS.unmet", .problem, "Needs a newer macOS",
                          "The app requires macOS \(min) or later; this Mac runs \(os). It may refuse to open or misbehave.",
                          advice: ["Update macOS if this Mac supports it, or install an older version of the app."],
                          links: [SettingsLinks.softwareUpdate])
            }
        }
        if let archs = app.architectures.value {
            let native = archs.contains { $0.isAppleSilicon }
            let intel = archs.contains(.x86_64)
            if !native && intel {
                if input.rosettaInstalled == false {
                    b.finding("app.rosetta.missing", .problem, "Intel-only app, and Rosetta isn't installed",
                              "This app is built only for Intel Macs. Apple Silicon Macs run such apps through Rosetta 2, which isn't installed.",
                              advice: ["Open the app once: macOS offers to install Rosetta. Accept only if you trust the app.",
                                       "Check whether the developer offers an Apple Silicon version."])
                } else {
                    b.finding("app.rosetta", .warning, "Runs through Rosetta (Intel-only app)",
                              "The app is built only for Intel and runs translated. It usually works but can be slower, and some plug-ins or drivers won't work.",
                              advice: ["Check for an Apple Silicon or Universal version from the developer."])
                }
            } else if !native && !intel {
                b.finding("app.arch.unknown", .warning, "Unusual architecture",
                          "The app's executable isn't built for Apple Silicon or Intel 64-bit; it probably can't run on this Mac.")
            } else {
                b.finding("app.arch.native", .fact, "Runs natively on Apple Silicon", "No translation needed.")
            }
        } else {
            b.add(app.architectures, key: "app.arch", label: "Architecture") { _ in "" }
        }
        return b.build()
    }

    static func integrity(_ input: AppDoctorInput, mine: [CrashReportSummary], started: Date) -> CheckResult {
        let app = input.app
        var b = builder("integrity", "Installation", input, started)
        b.limit("MacCheck checks the signature and bundle structure read-only. It never removes quarantine or changes security settings.")

        b.add(app.signature, key: "app.signature", label: "Code signature") { s -> String in
            switch s {
            case let .valid(notarized, team, apple):
                if apple { return "Valid (Apple)" }
                let n = notarized == true ? ", notarized" : (notarized == false ? ", not notarized" : "")
                return "Valid\(n)" + (team.map { " · team \($0)" } ?? "")
            case .adHoc: return "Ad-hoc (no developer identity)"
            case .unsigned: return "Not signed"
            case let .invalid(reason): return "Invalid — \(reason)"
            }
        }
        b.add(app.isQuarantined, key: "app.quarantine", label: "Downloaded-file flag (quarantine)", reportUnavailable: false) { $0 ? "Present" : "None" }
        b.add(app.isTranslocated, key: "app.translocated", label: "Running from a temporary location", reportUnavailable: false) { $0 ? "Yes" : "No" }

        switch app.signature.value {
        case let .invalid(reason)?:
            b.finding("app.signature.invalid", .problem, "The app's signature is broken",
                      "macOS reports: \(reason). The app's files may be damaged or modified, which can stop it from opening or cause crashes.",
                      advice: ["Delete the app and reinstall it from the App Store or the developer's website.",
                               "Do not try to bypass the check — reinstalling is the safe fix."])
        case .unsigned?:
            b.finding("app.signature.unsigned", .warning, "The app isn't signed",
                      "macOS may block it from opening. Only open unsigned apps you fully trust.",
                      links: [SettingsLinks.privacySecurity])
        case let .valid(notarized, _, apple)? where !apple && notarized == false && app.isFromAppStore.value != true:
            b.finding("app.notarized.no", .possibleExplanation, "Not notarized by Apple",
                      "Apps from outside the App Store are normally notarized. Without it, macOS may block the first launch with a warning.",
                      evidence: .inferred, confidence: .medium,
                      advice: ["If macOS blocked it and you trust the source, System Settings → Privacy & Security shows an 'Open Anyway' button for the app."],
                      links: [SettingsLinks.privacySecurity])
        default: break
        }

        if app.isTranslocated.value == true {
            b.finding("app.translocated.yes", .warning, "Opened from a temporary, read-only location",
                      "macOS is running this app from a randomised location because it was opened straight from the download. Updates and settings may not stick.",
                      advice: ["Quit the app, drag it into the Applications folder, then open it from there."])
        } else if !app.isInApplicationsFolder {
            b.finding("app.location", .fact, "Not in the Applications folder",
                      "Apps generally work best from Applications. Some updaters fail elsewhere.",
                      advice: ["Consider moving it to Applications (quit it first)."])
        }

        for (i, problem) in app.bundleProblems.enumerated() {
            b.finding("app.bundle.\(i)", .problem, "Damaged app bundle", problem,
                      advice: ["Reinstall the app from its original source."])
        }

        if mine.contains(where: { ($0.terminationReason ?? "").uppercased().contains("CODESIGNING") }) {
            b.finding("app.codesign.crash", .problem, "A crash report mentions a code-signing failure",
                      "macOS stopped the app because its signature didn't validate at that time.",
                      advice: ["Reinstall the app from its original source."])
        }
        return b.build()
    }

    static func logsCheck(_ input: AppDoctorInput, started: Date) -> CheckResult {
        var b = builder("logs", "Recent errors in the system log", input, started)
        b.limit("Reads errors and faults the app logged in the last hour, using macOS's own log tool without extra permissions. Private values are hidden by macOS and further redacted by MacCheck.")
        b.limit("Many apps log harmless errors all the time; a count alone isn't a diagnosis.")
        guard let entries = input.logs.value, let src = input.logs.source else {
            b.add(input.logs, key: "app.logs", label: "Log entries") { _ in "" }
            return b.build()
        }
        let faults = entries.filter { $0.level.lowercased() == "fault" }.count
        b.add(.value(entries.count, source: src), key: "app.logs.errors", label: "Errors & faults (last hour, max 25 read)",
              numeric: { Double($0) }) { "\($0)" }
        if faults > 0 {
            b.finding("app.logs.faults", .fact, "\(faults) fault message\(faults == 1 ? "" : "s") logged",
                      "Faults are the most serious log level. Redacted excerpts are shown below and are left out of exported reports unless you include them.")
        }
        return b.build(informational: true)
    }

    static func permissions(_ input: AppDoctorInput, started: Date) -> CheckResult {
        var b = builder("permissions", "Permissions", input, started)
        b.limit("macOS doesn't let other apps read which permissions an app has been granted without Full Disk Access, which MacCheck doesn't ask for. These are the usual places to look.")
        for pane in SettingsLinks.PrivacyPane.allCases where pane != .fullDiskAccess || input.symptom == .permissions {
            b.findings.append(Finding(id: "app.perm.\(pane.rawValue)", kind: .fact,
                                      title: "If the \(pane.title.lowercased()) doesn't work",
                                      detail: "Typical sign: \(pane.symptom). Check that \(input.app.name) is listed and switched on.",
                                      evidence: input.isSample ? .sample : .inferred,
                                      advice: ["After switching a permission on, quit and reopen the app."],
                                      links: [SettingsLinks.privacy(pane)]))
        }
        return b.build(summary: "Guidance: where to check \(input.app.name)'s permissions.", informational: true)
    }

    static func systemContext(_ input: AppDoctorInput, started: Date) -> CheckResult {
        var b = builder("system", "System context", input, started)
        b.limit("A snapshot of the whole Mac right now. If the problem only happens sometimes, run this while it's happening.")
        if let perf = input.performance {
            b.add(perf.memoryPressure, key: "sys.pressure", label: "Memory pressure") { $0.rawValue.capitalized }
            b.add(perf.cpuBusyPercent, key: "sys.cpu", label: "CPU busy", numeric: { $0 }) { Fmt.percent($0) }
            if let p = perf.memoryPressure.value, p != .normal {
                b.finding("sys.pressure", p == .critical ? .problem : .warning, "Memory is tight",
                          "Memory pressure is \(p.rawValue). Apps can freeze, reload or be closed by macOS.",
                          advice: ["Close apps and browser tabs you don't need."], links: [SettingsLinks.activityMonitor])
            }
            if let top = perf.topProcesses.value?.first(where: { $0.name.caseInsensitiveCompare(input.app.executableName ?? input.app.name) == .orderedSame }) {
                b.addDerived(key: "sys.appCPU", label: "\(input.app.name) CPU now", display: Fmt.percent(top.cpuPercent), numeric: top.cpuPercent)
                if top.cpuPercent >= 90 && (input.symptom == .freezes || input.symptom == .slow) {
                    b.finding("sys.appBusy", .possibleExplanation, "\(input.app.name) is working very hard right now",
                              "It's using about \(Int(top.cpuPercent))% of a core. It may be busy with a large task, or stuck in a loop.",
                              evidence: .inferred, confidence: .low,
                              advice: ["Give it a minute. If it doesn't recover, save what you can and quit it yourself."])
                }
            }
        }
        if let root = input.storage?.rootVolume, let total = root.totalBytes, total > 0,
           let free = root.availableForImportantUsageBytes ?? root.availableBytes {
            let src = input.storage?.volumes.source ?? self.src(input, "Volume info", .publicAPI)
            b.add(.value(free, source: src), key: "sys.free", label: "Free on startup disk", numeric: { Double($0) }) { Fmt.bytes($0) }
            if Double(free) / 1e9 < 10 {
                b.finding("sys.lowDisk", .warning, "Low disk space",
                          "Only \(Fmt.bytes(free)) free. Apps may fail to open, save or update when space runs out.",
                          links: [SettingsLinks.storage])
            }
        }
        if let t = input.thermals?.thermalState.value, t == .serious || t == .critical {
            b.finding("sys.thermal", .warning, "The Mac is running hot",
                      "macOS reports a \(t.rawValue) thermal state and is reducing performance.", evidence: .reportedBySystem)
        }
        if input.performance == nil && input.storage == nil && input.thermals == nil {
            b.finding("sys.none", .unavailable, "System context not collected", "System context wasn't collected for this investigation.")
        }
        return b.build()
    }

    // MARK: Proposals

    static func proposals(_ input: AppDoctorInput, week: [CrashReportSummary]) -> [RepairProposal] {
        let app = input.app
        var out: [RepairProposal] = []

        if (input.symptom == .crashes || input.symptom == .wontOpen),
           input.savedStateExists == true,
           let id = app.bundleIdentifier, RepairProposal.isSafeBundleIdentifier(id) {
            let crashes = week.filter { $0.kind == .crash }.count
            var evidence = ["You reported: \(input.symptom.title.lowercased())."]
            if crashes > 0 { evidence.append("\(crashes) crash report\(crashes == 1 ? "" : "s") in the last 7 days.") }
            evidence.append("\(app.name) has saved window state that macOS restores at launch.")
            out.append(RepairProposal(
                id: "reset-saved-state:\(id)", kind: .change, action: .moveSavedStateToTrash(bundleIdentifier: id),
                title: "Reset \(app.name)'s saved windows",
                issue: "Sometimes the information macOS keeps to reopen an app's windows gets into a bad state, and the app crashes while restoring it. This is one possible cause, not a confirmed one.",
                evidence: evidence,
                whatHappens: "MacCheck moves one folder — ~/\(RepairProposal.savedStateRelativePath(for: id)) — to the Trash. Nothing else is touched.",
                sideEffects: ["Next time you open \(app.name), it won't reopen the windows it had open before.",
                              "Your documents, settings and account data are not affected.",
                              "\(app.name) must be quit first."],
                howToUndo: "Open the Trash in Finder, select \(id).savedState and choose File → Put Back (while \(app.name) is quit).",
                verification: "After you've used \(app.name) again, MacCheck looks for new crash reports dated after the change.",
                confidence: .low))
        }

        if input.symptom == .permissions {
            out.append(RepairProposal(
                id: "open-privacy", kind: .handoff, action: .openLink(SettingsLinks.privacySecurity),
                title: "Open Privacy & Security",
                issue: "A feature that needs permission may have been denied or never asked for.",
                evidence: ["You reported a feature not working."],
                whatHappens: "Opens System Settings. You decide what to switch on; MacCheck changes nothing.",
                sideEffects: [], howToUndo: "Nothing to undo.",
                verification: "Try the feature again after switching it on and reopening the app.", confidence: .medium))
        }

        if app.isTranslocated.value == true || (!app.isInApplicationsFolder && app.isFromAppStore.value != true) {
            out.append(RepairProposal(
                id: "reveal:\(app.path)", kind: .handoff, action: .revealInFinder(path: app.path),
                title: "Show \(app.name) in Finder",
                issue: "The app isn't in the Applications folder.",
                evidence: [app.isTranslocated.value == true ? "macOS is running it from a temporary location." : "It's outside Applications."],
                whatHappens: "Opens a Finder window with the app selected, so you can drag it to Applications yourself.",
                sideEffects: [], howToUndo: "Nothing to undo.",
                verification: "Run App Doctor again: the location check should pass.", confidence: .medium))
        }

        if !week.isEmpty {
            out.append(RepairProposal(
                id: "open-console", kind: .handoff, action: .openLink(SettingsLinks.console),
                title: "Open full reports in Console",
                issue: "The full crash reports contain technical detail a developer may ask for.",
                evidence: ["\(week.count) report\(week.count == 1 ? "" : "s") this week."],
                whatHappens: "Opens Apple's Console app. Look under Crash Reports.",
                sideEffects: [], howToUndo: "Nothing to undo.",
                verification: "Not applicable.", confidence: .high))
        }
        return out
    }
}
