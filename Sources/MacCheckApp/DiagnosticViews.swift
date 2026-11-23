#if os(macOS)
import SwiftUI
import MacCheckCore

// MARK: - Dashboard

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s6) {
                header
                if let report = model.latestReport {
                    overview(report)
                    areaGrid(report)
                } else {
                    Card {
                        EmptyState(symbol: "stethoscope", title: "No diagnostic yet",
                                   message: "Run a Full Diagnostic to check battery, hardware, performance, thermals, network and storage. It takes about 10 seconds and changes nothing on your Mac.",
                                   actionTitle: "Run Full Diagnostic") { model.runFullDiagnostic() }
                    }
                }
                appDoctorTeaser
            }
            .padding(Theme.s6)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .navigationTitle("Overview")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.s4) {
            Image(systemName: "laptopcomputer").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.latestReport?.device?.modelName ?? "This Mac").font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                if let d = model.latestReport?.device {
                    Text([d.chip, d.memory, d.macOS].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(Theme.muted)
                } else {
                    Text("Device details appear after the first scan.").font(.callout).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            Button {
                model.runFullDiagnostic()
            } label: {
                Label(model.scanState == .running ? "Scanning…" : "Run Full Diagnostic", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.scanState == .running)
            .keyboardShortcut(.defaultAction)
            .help("Read-only. Takes about 10 seconds.")
        }
    }

    private func overview(_ r: ScanReport) -> some View {
        let c = r.counts
        return Card {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: "Latest health overview",
                             subtitle: "\(r.createdAt.formatted(date: .abbreviated, time: .shortened))\(r.isSampleData ? " · sample data" : "")")
                Spacer()
                StatusPill(status: r.overallStatus)
            }
            Text(summaryLine(r)).foregroundStyle(Theme.text)
            HStack(spacing: Theme.s6) {
                stat("\(c.problems)", "problems", Theme.problem)
                stat("\(c.warnings)", "need attention", Theme.warning)
                stat("\(c.unavailable)", "unavailable", Theme.unavailable)
                if c.failed > 0 { stat("\(c.failed)", "checks failed", Theme.failed) }
                Spacer()
                Button("Review & Export…") { model.beginExport(r) }
            }
        }
    }

    private func summaryLine(_ r: ScanReport) -> String {
        let c = r.counts
        if c.problems == 0 && c.warnings == 0 {
            return "Nothing unusual in what MacCheck can measure. Unavailable items are listed in each area with the reason."
        }
        return "Some areas need a look. Open an area to see the evidence and what you can do."
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private func areaGrid(_ r: ScanReport) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Theme.s4)], spacing: Theme.s4) {
            ForEach(DiagnosticArea.allCases) { area in
                Button { model.selection = .area(area) } label: { AreaTile(area: area, result: r.result(for: area)) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens \(area.title) details")
            }
        }
    }

    private var appDoctorTeaser: some View {
        Card {
            HStack(spacing: Theme.s4) {
                Image(systemName: "cross.case").font(.title).foregroundStyle(Theme.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("An app misbehaving?").font(.headline).foregroundStyle(Theme.text)
                    Text("App Doctor looks at crash reports, compatibility, installation and recent errors for one app.")
                        .font(.callout).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Open App Doctor") { model.selection = .appDoctor }
            }
        }
    }
}

struct AreaTile: View {
    var area: DiagnosticArea
    var result: CheckResult?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack {
                Label(area.title, systemImage: area.symbolName).font(.headline).foregroundStyle(Theme.text)
                Spacer()
                if let r = result { StatusPill(status: r.status, compact: true) }
            }
            Text(result?.summary ?? area.blurb)
                .font(.callout).foregroundStyle(Theme.muted).lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        }
        .padding(Theme.s4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusLg))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg).strokeBorder(result.map { $0.status.color.opacity(0.35) } ?? Theme.border))
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusLg))
    }
}

// MARK: - Full diagnostic

struct ScanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s6) {
                HStack {
                    SectionTitle(title: "Full Diagnostic",
                                 subtitle: "Six read-only checks, each limited in time. Nothing on your Mac is changed.")
                    Spacer()
                    switch model.scanState {
                    case .running:
                        Button("Cancel", role: .cancel) { model.cancelScan() }.keyboardShortcut(.cancelAction)
                    default:
                        Button { model.runFullDiagnostic() } label: { Label("Run Full Diagnostic", systemImage: "play.fill") }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
                if model.networkProbesEnabled {
                    Text("The network check contacts: \(ProbeEndpoint.defaults.map { $0.host ?? $0.url }.joined(separator: ", ")). You can turn this off in Settings.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }

                if model.progress.isEmpty {
                    Card {
                        EmptyState(symbol: "stethoscope", title: "Ready when you are",
                                   message: "Start a scan to see each check's progress here.",
                                   actionTitle: "Run Full Diagnostic") { model.runFullDiagnostic() }
                    }
                } else {
                    Card {
                        ForEach(model.progress) { item in
                            ProgressRow(item: item)
                            if item.id != model.progress.last?.id { Divider().overlay(Theme.border) }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Scan progress")
                }

                if model.scanState == .cancelled {
                    Label("Scan cancelled. Checks that didn't run are marked Skipped.", systemImage: "stop.circle")
                        .foregroundStyle(Theme.warning)
                }
                if model.scanState == .finished || model.scanState == .cancelled, let report = model.latestReport {
                    Card {
                        HStack {
                            SectionTitle(title: "Result", subtitle: "Open any area for evidence and limits.")
                            Spacer()
                            StatusPill(status: report.overallStatus)
                        }
                        ForEach(report.results) { r in
                            Button { if let a = r.area { model.selection = .area(a) } } label: {
                                HStack {
                                    Text(r.title).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text(r.summary).font(.callout).foregroundStyle(Theme.muted).lineLimit(1)
                                    StatusPill(status: r.status, compact: true)
                                    Image(systemName: "chevron.right").foregroundStyle(Theme.muted).accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        HStack {
                            Spacer()
                            Button("Review & Export Report…") { model.beginExport(report) }
                        }
                    }
                }
            }
            .padding(Theme.s6)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .navigationTitle("Full Diagnostic")
    }
}

struct ProgressRow: View {
    var item: ProgressItem
    var body: some View {
        HStack(spacing: Theme.s3) {
            Group {
                switch item.state {
                case .pending: Image(systemName: "circle.dotted").foregroundStyle(Theme.muted)
                case .running: ProgressView().controlSize(.small)
                case let .done(status): Image(systemName: status.symbol).foregroundStyle(status.color)
                }
            }
            .frame(width: 20)
            Text(item.title).foregroundStyle(Theme.text)
            Spacer()
            switch item.state {
            case .pending: Text("Waiting").font(.caption).foregroundStyle(Theme.muted)
            case .running: Text("Running…").font(.caption).foregroundStyle(Theme.accent)
            case let .done(status): StatusPill(status: status, compact: true)
            }
        }
        .padding(.vertical, Theme.s1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Area detail

struct AreaDetailView: View {
    @Environment(AppModel.self) private var model
    var area: DiagnosticArea

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s6) {
                HStack(alignment: .top) {
                    Label(area.title, systemImage: area.symbolName).font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Button { model.runFullDiagnostic(areas: [area]) } label: {
                        Label(model.scanState == .running ? "Running…" : "Run this check", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.scanState == .running)
                }
                if let result = model.latestReport?.result(for: area) {
                    CheckResultView(result: result)
                } else if model.scanState == .running {
                    Card { HStack { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(Theme.muted) } }
                } else {
                    Card {
                        EmptyState(symbol: area.symbolName, title: "Not checked yet", message: area.blurb,
                                   actionTitle: "Run this check") { model.runFullDiagnostic(areas: [area]) }
                    }
                }
            }
            .padding(Theme.s6)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .navigationTitle(area.title)
    }
}

/// Shared presentation of one result: status, summary, measurements, findings by kind, limits, sources.
struct CheckResultView: View {
    @Environment(AppModel.self) private var model
    var result: CheckResult

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Text(result.summary).font(.headline).foregroundStyle(Theme.text)
                    Spacer()
                    StatusPill(status: result.status)
                }
                if let err = result.errorDescription {
                    Label("The check couldn't finish: \(err)", systemImage: "questionmark.diamond")
                        .foregroundStyle(Theme.failed).font(.callout)
                }
                Text("Checked \(result.finishedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(Theme.muted)
            }

            if !result.measurements.isEmpty {
                Card {
                    SectionTitle(title: "Measurements")
                    Grid(alignment: .leading, horizontalSpacing: Theme.s4, verticalSpacing: Theme.s2) {
                        ForEach(result.measurements) { m in
                            GridRow {
                                Text(m.label).foregroundStyle(Theme.muted)
                                Text(m.display).foregroundStyle(Theme.text).textSelection(.enabled).monospacedDigit()
                                    .gridColumnAlignment(.leading)
                                EvidenceTag(evidence: m.evidence).help("Source: \(m.source.name)")
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }

            ForEach(groups) { group in
                Card {
                    SectionTitle(title: heading(group.kind))
                    ForEach(group.findings) { f in FindingRow(finding: f) }
                }
            }

            if !result.limitations.isEmpty {
                Card {
                    SectionTitle(title: "What this check can't tell you")
                    ForEach(result.limitations, id: \.self) { l in
                        Label(l, systemImage: "ruler").font(.callout).foregroundStyle(Theme.muted)
                    }
                }
            }
            if !result.sources.isEmpty {
                Text("Sources: " + result.sources.map(\.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    struct FindingGroup: Identifiable {
        var kind: FindingKind
        var findings: [Finding]
        var id: FindingKind { kind }
    }

    private var groups: [FindingGroup] {
        let order: [FindingKind] = [.problem, .warning, .possibleExplanation, .fact, .unavailable, .limitation]
        return order.compactMap { k in
            let f = result.findings.filter { $0.kind == k }
            return f.isEmpty ? nil : FindingGroup(kind: k, findings: f)
        }
    }

    private func heading(_ k: FindingKind) -> String {
        switch k {
        case .problem: return "Problems"
        case .warning: return "Needs attention"
        case .possibleExplanation: return "Possible explanations (not confirmed)"
        case .fact: return "Good to know"
        case .unavailable: return "Not available on this Mac"
        case .limitation: return "Limits"
        }
    }
}

struct FindingRow: View {
    @Environment(AppModel.self) private var model
    var finding: Finding

    var body: some View {
        HStack(alignment: .top, spacing: Theme.s3) {
            Image(systemName: finding.kind.symbol).foregroundStyle(finding.kind.color).frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.s1) {
                HStack(spacing: Theme.s2) {
                    Text(finding.title).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                    EvidenceTag(evidence: finding.evidence)
                    if let c = finding.confidence {
                        Text("\(c.rawValue) confidence").font(.caption2).foregroundStyle(Theme.muted)
                    }
                }
                Text(finding.detail).font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(finding.advice, id: \.self) { a in
                    Label(a, systemImage: "arrow.turn.down.right").font(.callout).foregroundStyle(Theme.text)
                }
                if !finding.links.isEmpty {
                    HStack {
                        ForEach(finding.links, id: \.self) { link in
                            Button(link.title) { model.open(link) }
                                .help(link.path + " — opens it; MacCheck changes nothing.")
                        }
                    }
                    .padding(.top, Theme.s1)
                }
            }
        }
        .padding(.vertical, Theme.s1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(finding.kind.label): \(finding.title)")
    }
}
#endif
