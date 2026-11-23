#if os(macOS)
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import MacCheckCore
import MacCheckMac

enum SidebarItem: Hashable {
    case dashboard, fullScan, appDoctor, history
    case area(DiagnosticArea)
}

enum DataMode: String, CaseIterable, Identifiable {
    case live, sample
    var id: String { rawValue }
    var title: String { self == .live ? "This Mac (live data)" : "Sample data (demo)" }
}

struct ProgressItem: Identifiable, Equatable {
    enum State: Equatable { case pending, running, done(CheckStatus) }
    var id: String
    var title: String
    var state: State
}

enum ScanState: Equatable {
    case idle, running, finished, cancelled
}

enum DoctorPhase: Equatable {
    case choose
    case investigating(AppDoctorStep)
    case result
    case failed(String)
}

/// Sample-mode stand-in: proves the consent flow without touching the Mac.
struct SampleRepairPerformer: RepairPerformer {
    func perform(_ proposal: RepairProposal) async throws -> RepairExecution {
        try await Task.sleep(nanoseconds: 400_000_000)
        return RepairExecution(proposalID: proposal.id, performedAt: Date(),
                               summary: "Sample mode: nothing on this Mac was changed.",
                               undoHint: "Nothing to undo in sample mode.", resultingPath: nil)
    }
}

@MainActor
@Observable
final class AppModel {
    // MARK: Settings (persisted in UserDefaults)
    var mode: DataMode { didSet { defaults.set(mode.rawValue, forKey: "mode"); latestReport = nil; resetDoctor(); loadHistory() } }
    var includeIdentifiers: Bool { didSet { defaults.set(includeIdentifiers, forKey: "includeIdentifiers") } }
    var networkProbesEnabled: Bool { didSet { defaults.set(networkProbesEnabled, forKey: "networkProbes") } }

    // MARK: Navigation
    var selection: SidebarItem? = .dashboard

    // MARK: Full diagnostic
    var scanState: ScanState = .idle
    var progress: [ProgressItem] = []
    var latestReport: ScanReport?
    private var scanTask: Task<Void, Never>?

    // MARK: History
    var history: [HistoryEntry] = []
    var historyError: String?
    let store = HistoryStore(directory: HistoryStore.defaultDirectory())

    // MARK: App Doctor
    var apps: [AppListing] = []
    var appsLoading = false
    var selectedAppPath: String?
    var symptom: Symptom?
    var note = ""
    var doctorPhase: DoctorPhase = .choose
    var doctorReport: ScanReport?
    var lastExecution: RepairExecution?
    var verification: VerificationResult?
    var repairError: String?
    private var doctorTask: Task<Void, Never>?
    private let gate = ConsentGate(validity: 120)

    // MARK: Export
    var exportDraft: ReportDraft?

    private let defaults = UserDefaults.standard

    /// Set by `--ui-snapshot <dir>`: sample data only, nothing persisted, screenshots written to <dir>.
    @ObservationIgnored let snapshotDirectory: URL?

    init() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--ui-snapshot"), i + 1 < args.count {
            snapshotDirectory = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        } else {
            snapshotDirectory = nil
        }
        // Assignments in init don't trigger didSet, so snapshot mode never touches saved settings.
        mode = snapshotDirectory != nil ? .sample
            : DataMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .live
        includeIdentifiers = snapshotDirectory != nil ? false : UserDefaults.standard.bool(forKey: "includeIdentifiers")
        networkProbesEnabled = UserDefaults.standard.object(forKey: "networkProbes") as? Bool ?? true
        loadHistory()
        if let latest = history.first(where: { $0.kind == .full && $0.isSampleData == (mode == .sample) }) {
            latestReport = try? store.load(latest.id)
        }
    }

    var isSample: Bool { mode == .sample }

    var options: CollectionOptions {
        CollectionOptions(includeIdentifiers: includeIdentifiers, networkProbesEnabled: networkProbesEnabled)
    }

    var collectors: CollectorSet { isSample ? SampleData.collectors() : MacPlatform.collectors() }
    var doctorSources: AppDoctorSources { isSample ? SampleData.appDoctorSources() : MacPlatform.appDoctorSources() }
    var redactor: Redactor { isSample ? Redactor() : MacPlatform.redactor() }

    // MARK: Scans

    func runFullDiagnostic(areas: Set<DiagnosticArea>? = nil) {
        guard scanState != .running else { return }
        let orchestrator = ScanOrchestrator(collectors: collectors, areas: areas)
        progress = orchestrator.checks.map { ProgressItem(id: $0.id, title: $0.title, state: .pending) }
        scanState = .running
        selection = areas == nil ? .fullScan : selection
        let opts = options
        let kind: ScanKind = areas == nil ? .full : .singleArea
        scanTask = Task {
            let report = await orchestrator.run(kind: kind, options: opts) { event in
                Task { @MainActor [weak self] in self?.apply(event) }
            }
            self.finishScan(report)
        }
    }

    func cancelScan() { scanTask?.cancel() }

    private func apply(_ event: ScanEvent) {
        switch event {
        case let .started(id, _, _, _):
            if let i = progress.firstIndex(where: { $0.id == id }) { progress[i].state = .running }
        case let .finished(result, _, _):
            if let i = progress.firstIndex(where: { $0.id == result.id }) { progress[i].state = .done(result.status) }
        }
    }

    private func finishScan(_ report: ScanReport) {
        for r in report.results {
            if let i = progress.firstIndex(where: { $0.id == r.id }) { progress[i].state = .done(r.status) }
        }
        if report.kind == .singleArea, var merged = latestReport {
            // Update one area inside the latest full report so the dashboard stays coherent.
            for r in report.results {
                if let i = merged.results.firstIndex(where: { $0.area == r.area }) { merged.results[i] = r }
            }
            latestReport = merged
        } else {
            latestReport = report
        }
        scanState = report.wasCancelled ? .cancelled : .finished
        save(report)
    }

    // MARK: History

    func loadHistory() {
        history = snapshotDirectory == nil ? store.list() : []
    }

    private func save(_ report: ScanReport) {
        guard snapshotDirectory == nil else { return } // snapshot runs leave no history behind
        do { try store.save(report); historyError = nil } catch { historyError = "History couldn't be saved: \(error.localizedDescription)" }
        loadHistory()
    }

    func deleteHistory(_ id: UUID) {
        try? store.delete(id)
        loadHistory()
    }

    func clearHistory() {
        do { try store.clearAll(); historyError = nil } catch { historyError = "History couldn't be cleared: \(error.localizedDescription)" }
        loadHistory()
    }

    // MARK: App Doctor

    func loadApps() {
        guard !appsLoading else { return }
        appsLoading = true
        let sources = doctorSources
        Task {
            let list = await Task.detached { await sources.listApps() }.value
            self.apps = list
            self.appsLoading = false
        }
    }

    func chooseOtherApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose App"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.standardizedFileURL.path
            if !apps.contains(where: { $0.path == path }) {
                apps.insert(AppListing(name: url.deletingPathExtension().lastPathComponent, path: path,
                                       bundleIdentifier: Bundle(url: url)?.bundleIdentifier, isRunning: false), at: 0)
            }
            selectedAppPath = path
        }
    }

    func investigate() {
        guard let path = selectedAppPath, let symptom else { return }
        let runner = AppDoctorRunner(sources: doctorSources, collectors: collectors)
        let opts = options
        let note = self.note.isEmpty ? nil : self.note
        lastExecution = nil
        verification = nil
        repairError = nil
        doctorPhase = .investigating(.readingApp)
        doctorTask = Task {
            do {
                let report = try await runner.investigate(appPath: path, symptom: symptom, note: note, options: opts) { step in
                    Task { @MainActor [weak self] in
                        if case .investigating? = self?.doctorPhase { self?.doctorPhase = .investigating(step) }
                    }
                }
                self.doctorReport = report
                self.doctorPhase = .result
                self.save(report)
            } catch is CancellationError {
                self.doctorPhase = .choose
            } catch {
                self.doctorPhase = .failed(String(describing: error))
            }
        }
    }

    func cancelInvestigation() { doctorTask?.cancel() }

    func resetDoctor() {
        doctorTask?.cancel()
        doctorPhase = .choose
        doctorReport = nil
        lastExecution = nil
        verification = nil
        repairError = nil
    }

    func perform(handoff proposal: RepairProposal) {
        switch proposal.action {
        case let .openLink(link): MacPlatform.open(link)
        case let .revealInFinder(path): MacPlatform.revealInFinder(path)
        case .moveSavedStateToTrash: break // never via the handoff path
        }
    }

    func open(_ link: SystemSettingsLink) { MacPlatform.open(link) }

    /// Called by the confirmation sheet immediately after the user confirms.
    func perform(change proposal: RepairProposal, acknowledged: Bool) async {
        repairError = nil
        let performer: RepairPerformer = isSample ? SampleRepairPerformer() : MacRepairPerformer()
        let coordinator = RepairCoordinator(gate: gate, performer: performer)
        do {
            let token = try gate.grant(for: proposal, acknowledgedSideEffects: acknowledged)
            lastExecution = try await coordinator.execute(proposal, token: token)
            verification = nil
        } catch {
            repairError = String(describing: error)
        }
    }

    func verifyRepair(appUsed: Bool) async {
        guard let exec = lastExecution, let doc = doctorReport?.appDoctor else { return }
        let runner = AppDoctorRunner(sources: doctorSources, collectors: collectors)
        let app = AppInfo(name: doc.appName, path: selectedAppPath ?? "", bundleIdentifier: doc.bundleIdentifier)
        let reports = await runner.reports(for: app)
        verification = RepairVerifier.verify(execution: exec, symptom: doc.symptom, reportsForApp: reports, appUsedSinceChange: appUsed)
    }

    // MARK: Export

    func beginExport(_ report: ScanReport) {
        exportDraft = ReportDraft(report: report, redactor: redactor)
    }

    /// Saves via NSSavePanel. Returns an error message, or nil on success/cancel.
    func save(draft: ReportDraft) -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ReportExporter.suggestedFileName(for: draft.report, format: draft.options.format)
        switch draft.options.format {
        case .markdown: panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        case .json: panel.allowedContentTypes = [.json]
        case .text: panel.allowedContentTypes = [.plainText]
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try ReportExporter.write(draft, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return nil
        } catch {
            return String(describing: error)
        }
    }
}
#endif
