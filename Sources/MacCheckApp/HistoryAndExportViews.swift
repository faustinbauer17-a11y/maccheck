#if os(macOS)
import SwiftUI
import MacCheckCore

// MARK: - History

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: UUID?
    @State private var loaded: ScanReport?
    @State private var loadError: String?
    @State private var confirmClear = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                if model.history.isEmpty {
                    EmptyState(symbol: "clock", title: "No history yet",
                               message: "Each scan and App Doctor investigation is saved here, on this Mac only.",
                               actionTitle: "Run Full Diagnostic") { model.runFullDiagnostic() }
                } else {
                    List(model.history, selection: $selected) { entry in
                        HStack {
                            Image(systemName: entry.overall.symbol).foregroundStyle(entry.overall.color)
                                .accessibilityLabel(entry.overall.title)
                            VStack(alignment: .leading) {
                                Text(entry.title).foregroundStyle(Theme.text)
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened) + (entry.isSampleData ? " · sample" : ""))
                                    .font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                        .contextMenu { Button("Delete", role: .destructive) { model.deleteHistory(entry.id) } }
                    }
                    .scrollContentBackground(.hidden)
                }
                Divider().overlay(Theme.border)
                VStack(alignment: .leading, spacing: Theme.s2) {
                    Text("Kept on this Mac: the latest \(model.store.retention.maxEntries) entries, up to \(model.store.retention.maxAgeDays) days. Serial numbers are never stored.")
                        .font(.caption).foregroundStyle(Theme.muted)
                    if let err = model.historyError { Text(err).font(.caption).foregroundStyle(Theme.problem) }
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                        .disabled(model.history.isEmpty)
                }
                .padding(Theme.s3)
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)

            Group {
                if let report = loaded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.s4) {
                            HStack {
                                SectionTitle(title: report.kind == .appDoctor ? "App Doctor: \(report.appDoctor?.appName ?? "")" : "Full diagnostic",
                                             subtitle: report.createdAt.formatted(date: .complete, time: .shortened))
                                Spacer()
                                Button("Review & Export…") { model.beginExport(report) }
                            }
                            if report.isSampleData { Label("Sample data — not from this Mac.", systemImage: "theatermasks").foregroundStyle(Theme.sample) }
                            ForEach(report.results + (report.appDoctor?.checks ?? [])) { r in
                                DisclosureGroup {
                                    CheckResultView(result: r).padding(.top, Theme.s2)
                                } label: {
                                    HStack { Text(r.title).foregroundStyle(Theme.text); Spacer(); StatusPill(status: r.status, compact: true) }
                                }
                                .padding(Theme.s3)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusLg))
                            }
                        }
                        .padding(Theme.s6)
                    }
                } else if let err = loadError {
                    EmptyState(symbol: "exclamationmark.triangle", title: "This entry couldn't be opened", message: err)
                } else {
                    EmptyState(symbol: "sidebar.left", title: "Select a scan", message: "Choose an entry to see its results.")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("History")
        .onAppear { model.loadHistory() }
        .onChange(of: selected) { _, id in
            loadError = nil
            loaded = nil
            guard let id else { return }
            do { loaded = try model.store.load(id) } catch { loadError = error.localizedDescription }
        }
        .confirmationDialog("Delete all scan history?", isPresented: $confirmClear) {
            Button("Delete All History", role: .destructive) { model.clearHistory(); loaded = nil; selected = nil }
            Button("Keep History", role: .cancel) {}
        } message: {
            Text("This removes \(model.history.count) saved scan\(model.history.count == 1 ? "" : "s") from this Mac. It can't be undone. Exported report files are not affected.")
        }
    }
}

// MARK: - Report review & export

struct ReportReviewSheet: View {
    @Environment(AppModel.self) private var model
    @State var draft: ReportDraft
    @State private var reviewedChecked = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            HStack {
                SectionTitle(title: "Review report before saving",
                             subtitle: "This is exactly what will be written. It stays on your Mac unless you share the file yourself.")
                Spacer()
            }
            HStack(alignment: .top, spacing: Theme.s6) {
                optionsPanel.frame(width: 250)
                VStack(alignment: .leading, spacing: Theme.s2) {
                    let summary = draft.redactionSummary()
                    Label(summary.total == 0 ? "No personal data patterns found to redact."
                          : "\(summary.total) item\(summary.total == 1 ? "" : "s") redacted (names, paths, addresses, identifiers).",
                          systemImage: "eye.slash")
                        .font(.callout).foregroundStyle(Theme.muted)
                    ScrollView {
                        Text(draft.render())
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.s3)
                    }
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border))
                    .accessibilityLabel("Report preview")
                }
            }
            Toggle("I've reviewed this report", isOn: $reviewedChecked).toggleStyle(.checkbox)
            if let e = saveError { Label(e, systemImage: "xmark.octagon").foregroundStyle(Theme.problem) }
            HStack {
                Button("Cancel", role: .cancel) { model.exportDraft = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Report…") {
                    var d = draft
                    d.markReviewed()
                    saveError = model.save(draft: d)
                    if saveError == nil { model.exportDraft = nil }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!reviewedChecked)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.s6)
        .frame(width: 920, height: 640)
        .background(Theme.raised)
        .onChange(of: draft.options) { _, _ in reviewedChecked = false } // any change needs a fresh review
    }

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            Picker("Format", selection: $draft.options.format) {
                ForEach(ReportFormat.allCases) { Text($0.title).tag($0) }
            }
            Divider().overlay(Theme.border)
            Text("Include").font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
            ForEach(DiagnosticArea.allCases) { area in
                Toggle(area.title, isOn: Binding(
                    get: { draft.options.areas.contains(area) },
                    set: { on in if on { draft.options.areas.insert(area) } else { draft.options.areas.remove(area) } }))
            }
            if draft.report.appDoctor != nil {
                Toggle("App Doctor findings", isOn: $draft.options.includeAppDoctor)
                Toggle("Log excerpts (redacted)", isOn: $draft.options.includeLogExcerpts)
                    .disabled(!draft.options.includeAppDoctor)
            }
            Toggle("Limits of each check", isOn: $draft.options.includeLimitations)
            Divider().overlay(Theme.border)
            Toggle("Serial number & identifiers", isOn: $draft.options.includeIdentifiers)
            Text("Off by default. Only present if you turned on identifier collection in Settings before scanning.")
                .font(.caption).foregroundStyle(Theme.muted)
            Spacer()
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Data") {
                Picker("Show results from", selection: $model.mode) {
                    ForEach(DataMode.allCases) { Text($0.title).tag($0) }
                }
                Text("Sample data is for trying the app and previews. It's labelled everywhere and never mixed with real results.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Section("Network check") {
                Toggle("Allow network probes", isOn: $model.networkProbesEnabled)
                Text("When on, the network check looks up and contacts: \(ProbeEndpoint.defaults.map { $0.url }.joined(separator: " and ")). One small request each; nothing about your Mac is sent beyond a normal web request.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Section("Privacy") {
                Toggle("Collect serial number (identifiers)", isOn: $model.includeIdentifiers)
                Text("Off by default. Even when on, identifiers are never saved in history and are left out of exports unless you include them on the review screen.")
                    .font(.caption).foregroundStyle(Theme.muted)
                Text("MacCheck has no analytics, no telemetry and no upload. Reports are saved only where you choose.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            Section("Optional extra access") {
                Text("MacCheck doesn't need Full Disk Access. Granting it would only let App Doctor read a few more system-wide logs. If you choose to, add MacCheck under Full Disk Access — you can remove it at any time.")
                    .font(.caption).foregroundStyle(Theme.muted)
                Button("Open Full Disk Access settings") { model.open(SettingsLinks.privacy(.fullDiskAccess)) }
            }
        }
        .formStyle(.grouped)
        .padding(Theme.s4)
    }
}
#endif
