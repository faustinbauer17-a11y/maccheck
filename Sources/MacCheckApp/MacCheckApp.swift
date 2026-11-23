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
                .frame(minWidth: 880, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Run Full Diagnostic") { model.runFullDiagnostic() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.scanState == .running)
                Button("Open App Doctor") { model.selection = .appDoctor }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
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
            if model.isSample { SampleBanner() }
            NavigationSplitView {
                List(selection: $model.selection) {
                    Section {
                        Label("Overview", systemImage: "square.grid.2x2").tag(SidebarItem.dashboard)
                        Label("Full Diagnostic", systemImage: "stethoscope").tag(SidebarItem.fullScan)
                        Label("App Doctor", systemImage: "cross.case").tag(SidebarItem.appDoctor)
                    }
                    Section("Areas") {
                        ForEach(DiagnosticArea.allCases) { area in
                            HStack {
                                Label(area.title, systemImage: area.symbolName)
                                Spacer()
                                if let status = model.latestReport?.result(for: area)?.status {
                                    Image(systemName: status.symbol).foregroundStyle(status.color)
                                        .accessibilityLabel(status.title)
                                }
                            }
                            .tag(SidebarItem.area(area))
                        }
                    }
                    Section {
                        Label("History", systemImage: "clock.arrow.circlepath").tag(SidebarItem.history)
                    }
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            } detail: {
                ZStack {
                    Theme.background.ignoresSafeArea()
                    detail
                }
            }
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
        case .dashboard: DashboardView()
        case .fullScan: ScanView()
        case .appDoctor: AppDoctorView()
        case .history: HistoryView()
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
