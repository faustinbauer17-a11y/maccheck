#if os(macOS)
import AppKit
import SwiftUI
import MacCheckCore

@main
struct MacCheckApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("MacCheck") {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Check Computer") { model.runFullDiagnostic() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.scanState == .running)
                Button("Open App Doctor") { model.selection = .appDoctor }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Show Overview") { model.selection = .dashboard }
                    .keyboardShortcut("0", modifiers: [.command])
                Divider()
                Button("Export Latest Report…") { if let r = model.latestReport { model.beginExport(r) } }
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(model.latestReport == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(width: 560)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 300)
            } detail: {
                ZStack {
                    Theme.backdrop.ignoresSafeArea()
                    detail
                }
                .toolbar {
                    if model.isSample {
                        ToolbarItem(placement: .primaryAction) {
                            Button { model.selection = .settings } label: {
                                Label("Sample data", systemImage: "theatermasks")
                                    .labelStyle(.titleAndIcon)
                                    .foregroundStyle(Theme.sample)
                            }
                            .help("Results are sample data, not from this Mac. Click to switch to live data.")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("About This Mac") { model.open(SettingsLinks.aboutThisMac) }
                            .help("Opens \(SettingsLinks.aboutThisMac.path).")
                    }
                }
            }
            FooterBar()
        }
        .sheet(item: Binding(get: { model.exportDraft.map(DraftBox.init) },
                             set: { model.exportDraft = $0?.draft })) { box in
            ReportReviewSheet(draft: box.draft)
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .onAppear { NSApp.appearance = NSAppearance(named: .darkAqua) } // dark title bar + sidebar to match
        .task {
            if let dir = model.snapshotDirectory { await SnapshotDriver.run(model, into: dir) }
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection ?? .dashboard {
        case .dashboard: HomeView()
        case .fullScan: ScanView()
        case .appDoctor: AppDoctorView()
        case .history: HistoryView()
        case .reports: ReportsView()
        case .settings: SettingsPage()
        case let .area(area): AreaDetailView(area: area)
        }
    }
}

/// Identifiable wrapper so the draft can drive `.sheet(item:)`.
struct DraftBox: Identifiable {
    var draft: ReportDraft
    var id: UUID { draft.report.id }
}
#else
// MacCheck's interface is a native macOS app. On Windows/Linux this target only builds a stub so that
// `swift build` succeeds for the platform-independent core. Use `swift run maccheck-cli --sample` instead.
@main
enum MacCheckAppStub {
    static func main() {
        print("The MacCheck app requires macOS 14 or later. On this platform, try: swift run maccheck-cli --sample")
    }
}
#endif
