#if os(macOS)
import SwiftUI
import MacCheckCore

// MARK: - Full diagnostic

struct ScanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s6) {
                HStack {
                    SectionTitle(title: "Check Computer",
                                 subtitle: "Six read-only tests, each limited in time. Nothing on your Mac is changed.")
                    Spacer()
                    switch model.scanState {
                    case .running:
                        Button("Cancel", role: .cancel) { model.cancelScan() }.keyboardShortcut(.cancelAction)
                    default:
                        Button { model.runFullDiagnostic() } label: { Label("Start Check", systemImage: "play.fill") }
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
                                   message: "Runs every test in the sidebar one after another and shows each one's progress here. Takes about 10 seconds.",
                                   actionTitle: "Start Check") { model.runFullDiagnostic() }
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
        .navigationTitle("Check Computer")
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
