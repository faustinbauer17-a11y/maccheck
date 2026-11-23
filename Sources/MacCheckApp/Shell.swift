#if os(macOS)
import SwiftUI
import MacCheckCore

// MARK: - Sidebar

/// One row in a sidebar tab. Every row opens a working page; there are no placeholder entries.
struct SidebarEntry: Identifiable {
    var item: SidebarItem
    var title: String
    var symbol: String
    var id: SidebarItem { item }

    static func entries(for tab: SidebarTab) -> [SidebarEntry] {
        switch tab {
        case .tests:
            return [
                SidebarEntry(item: .fullScan, title: "Check Computer", symbol: "play.rectangle"),
                SidebarEntry(item: .area(.battery), title: "Battery Check", symbol: "battery.75percent"),
                SidebarEntry(item: .area(.hardware), title: "Hardware Profile", symbol: "cpu"),
                SidebarEntry(item: .area(.performance), title: "Processor & Memory", symbol: "memorychip"),
                SidebarEntry(item: .area(.thermals), title: "Thermal State", symbol: "thermometer.medium"),
                SidebarEntry(item: .area(.network), title: "Network Interface", symbol: "network"),
                SidebarEntry(item: .area(.storage), title: "Storage & Drive", symbol: "internaldrive"),
            ]
        case .tools:
            return [
                SidebarEntry(item: .dashboard, title: "System Overview", symbol: "gauge.with.dots.needle.67percent"),
                SidebarEntry(item: .appDoctor, title: "App Doctor", symbol: "cross.case"),
                SidebarEntry(item: .settings, title: "Privacy & Settings", symbol: "gearshape"),
            ]
        case .reports:
            return [
                SidebarEntry(item: .reports, title: "Latest Report", symbol: "doc.text.magnifyingglass"),
                SidebarEntry(item: .history, title: "History", symbol: "clock.arrow.circlepath"),
            ]
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: Theme.s2) {
            SidebarTabBar(selection: $model.sidebarTab)
                .padding(.horizontal, Theme.s3)
                .padding(.top, Theme.s1)
            List(selection: $model.selection) {
                ForEach(SidebarEntry.entries(for: model.sidebarTab)) { entry in
                    SidebarRow(entry: entry, status: status(for: entry.item))
                        .tag(entry.item)
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// Status icon from the latest report, so finished tests show their result at a glance.
    private func status(for item: SidebarItem) -> CheckStatus? {
        guard let report = model.latestReport else { return nil }
        switch item {
        case .fullScan: return report.kind == .full ? report.overallStatus : nil
        case let .area(area): return report.result(for: area)?.status
        default: return nil
        }
    }
}

struct SidebarRow: View {
    var entry: SidebarEntry
    var status: CheckStatus?

    var body: some View {
        HStack(spacing: Theme.s3) {
            Image(systemName: entry.symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Theme.gauge)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(entry.title).foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            if let status {
                Image(systemName: status.symbol).foregroundStyle(status.color)
                    .accessibilityLabel(status.title)
                    .help(status.title)
            }
        }
        .padding(.vertical, 3)
    }
}

/// The Tests / Tools / Reports switcher at the top of the sidebar.
struct SidebarTabBar: View {
    @Binding var selection: SidebarTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarTab.allCases) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 19, weight: .light))
                        Text(tab.title).font(.caption)
                    }
                    .foregroundStyle(selected ? Theme.text : Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(selected ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                    .contentShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Color.white.opacity(0.06)))
    }
}

// MARK: - Footer

struct FooterBar: View {
    var body: some View {
        HStack {
            Text("Version \(MacCheckInfo.version) (\(MacCheckInfo.build))")
            Spacer()
            Text("Read-only · no telemetry · reports stay on this Mac")
        }
        .font(.caption2)
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(Theme.footer)
    }
}

// MARK: - Reports

/// The latest Check Computer result in one place, with export.
struct ReportsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s6) {
                if let report = model.latestReport {
                    content(report)
                } else {
                    Card {
                        EmptyState(symbol: "doc.text.magnifyingglass", title: "No report yet",
                                   message: "Run Check Computer to create a report. It takes about 10 seconds and changes nothing on your Mac.",
                                   actionTitle: "Check Computer") { model.runFullDiagnostic() }
                    }
                }
            }
            .padding(Theme.s6)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .navigationTitle("Latest Report")
    }

    @ViewBuilder private func content(_ r: ScanReport) -> some View {
        let c = r.counts
        HStack(alignment: .firstTextBaseline) {
            SectionTitle(title: "Latest report",
                         subtitle: r.createdAt.formatted(date: .abbreviated, time: .shortened) + (r.isSampleData ? " · sample data" : ""))
            Spacer()
            Button { model.runFullDiagnostic() } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                .disabled(model.scanState == .running)
            Button("Review & Export…") { model.beginExport(r) }
                .buttonStyle(.borderedProminent)
        }
        if r.isSampleData {
            Label("Sample data — not from this Mac.", systemImage: "theatermasks").foregroundStyle(Theme.sample)
        }
        Card {
            HStack {
                Text(c.problems == 0 && c.warnings == 0
                     ? "Nothing unusual in what MacCheck can measure. Unavailable items are listed in each test with the reason."
                     : "Some tests need a look. Open one to see the evidence and what you can do.")
                    .foregroundStyle(Theme.text)
                Spacer()
                StatusPill(status: r.overallStatus)
            }
            HStack(spacing: Theme.s6) {
                stat("\(c.problems)", "problems", Theme.problem)
                stat("\(c.warnings)", "need attention", Theme.warning)
                stat("\(c.unavailable)", "unavailable", Theme.unavailable)
                if c.failed > 0 { stat("\(c.failed)", "tests failed", Theme.failed) }
            }
        }
        Card {
            ForEach(r.results) { result in
                Button { if let a = result.area { model.selection = .area(a) } } label: {
                    HStack(spacing: Theme.s3) {
                        if let a = result.area {
                            Image(systemName: a.symbolName).foregroundStyle(Theme.gauge).frame(width: 22).accessibilityHidden(true)
                        }
                        Text(result.area?.title ?? result.title).foregroundStyle(Theme.text)
                        Spacer()
                        Text(result.summary).font(.callout).foregroundStyle(Theme.muted).lineLimit(1)
                        StatusPill(status: result.status, compact: true)
                        Image(systemName: "chevron.right").foregroundStyle(Theme.muted).accessibilityHidden(true)
                    }
                    .padding(.vertical, Theme.s1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens this test's details")
                if result.id != r.results.last?.id { Divider().overlay(Theme.border) }
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings inside the main window

struct SettingsPage: View {
    var body: some View {
        // SettingsView is a grouped Form, which scrolls by itself.
        SettingsView()
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Privacy & Settings")
    }
}
#endif
