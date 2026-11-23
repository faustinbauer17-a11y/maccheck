#if os(macOS)
import SwiftUI
import MacCheckCore

struct AppDoctorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s6) {
                switch model.doctorPhase {
                case .choose: ChooseAppStep()
                case let .investigating(step): InvestigatingStep(current: step)
                case .result:
                    if let report = model.doctorReport, let doc = report.appDoctor {
                        DoctorResultView(report: report, result: doc)
                    }
                case let .failed(message):
                    Card {
                        EmptyState(symbol: "exclamationmark.bubble", title: "App Doctor couldn't read that app",
                                   message: message + " Nothing was changed.",
                                   actionTitle: "Choose another app") { model.resetDoctor() }
                    }
                }
            }
            .padding(Theme.s6)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .navigationTitle("App Doctor")
        .onAppear { if model.apps.isEmpty { model.loadApps() } }
    }
}

// MARK: Step 1 — choose app and symptom

struct ChooseAppStep: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: Theme.s6) {
            SectionTitle(title: "Which app is giving you trouble?",
                         subtitle: "App Doctor only reads information. It won't change the app or your settings.")

            Card {
                HStack {
                    TextField("Search apps", text: $search).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search apps")
                    Button("Choose Other App…") { model.chooseOtherApp() }
                }
                if model.appsLoading {
                    HStack { ProgressView().controlSize(.small); Text("Finding apps…").foregroundStyle(Theme.muted) }
                } else if filtered.isEmpty {
                    Text(search.isEmpty ? "No apps found in the usual folders. Use Choose Other App…" : "No apps match “\(search)”.")
                        .foregroundStyle(Theme.muted)
                    if !search.isEmpty { Button("Clear search") { search = "" } }
                } else {
                    List(filtered, selection: $model.selectedAppPath) { app in
                        HStack {
                            Text(app.name).foregroundStyle(Theme.text)
                            if app.isRunning {
                                Text("Running").font(.caption2.weight(.semibold)).foregroundStyle(Theme.ok)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .overlay(Capsule().strokeBorder(Theme.ok.opacity(0.5)))
                            }
                            Spacer()
                            Text(Redactor()(app.path)).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                        }
                        .tag(app.path)
                    }
                    .frame(minHeight: 220, maxHeight: 300)
                    .scrollContentBackground(.hidden)
                }
            }

            SectionTitle(title: "What's happening?")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Theme.s3)], spacing: Theme.s3) {
                ForEach(Symptom.allCases) { s in
                    let selected = model.symptom == s
                    Button { model.symptom = s } label: {
                        Label(s.title, systemImage: s.symbolName)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, Theme.s3)
                            .foregroundStyle(selected ? Theme.text : Theme.muted)
                            .background(selected ? Theme.accentSoft : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(selected ? Theme.accent : Theme.border))
                            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            VStack(alignment: .leading, spacing: Theme.s2) {
                Text("Anything else? (optional)").font(.callout.weight(.medium)).foregroundStyle(Theme.text)
                TextField("e.g. it closes when I open a large PDF", text: $model.note, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder)
                Text("Kept with this investigation on your Mac only.").font(.caption).foregroundStyle(Theme.muted)
            }

            HStack {
                Spacer()
                Button { model.investigate() } label: { Label("Investigate", systemImage: "magnifyingglass") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.selectedAppPath == nil || model.symptom == nil)
                    .keyboardShortcut(.defaultAction)
                    .help(model.selectedAppPath == nil ? "Choose an app first" : (model.symptom == nil ? "Choose what's happening" : "Read-only investigation"))
            }
        }
    }

    private var filtered: [AppListing] {
        search.isEmpty ? model.apps : model.apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
}

// MARK: Step 2 — investigating

struct InvestigatingStep: View {
    @Environment(AppModel.self) private var model
    var current: AppDoctorStep

    var body: some View {
        Card {
            SectionTitle(title: "Investigating…", subtitle: "Reading only. This usually takes a few seconds; the log step can take up to 25.")
            ForEach(AppDoctorStep.allCases, id: \.self) { step in
                let index = AppDoctorStep.allCases.firstIndex(of: step)!
                let currentIndex = AppDoctorStep.allCases.firstIndex(of: current)!
                HStack(spacing: Theme.s3) {
                    Group {
                        if index < currentIndex { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                        else if index == currentIndex { ProgressView().controlSize(.small) }
                        else { Image(systemName: "circle.dotted").foregroundStyle(Theme.muted) }
                    }
                    .frame(width: 20)
                    Text(step.rawValue).foregroundStyle(index <= currentIndex ? Theme.text : Theme.muted)
                }
                .accessibilityElement(children: .combine)
            }
            HStack { Spacer(); Button("Cancel", role: .cancel) { model.cancelInvestigation() }.keyboardShortcut(.cancelAction) }
        }
    }
}

// MARK: Step 3 — results

struct DoctorResultView: View {
    @Environment(AppModel.self) private var model
    var report: ScanReport
    var result: AppDoctorResult
    @State private var confirming: RepairProposal?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.appName + (result.appVersion.map { " \($0)" } ?? ""))
                        .font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                    Text("You said: \(result.symptom.title.lowercased())").foregroundStyle(Theme.muted)
                }
                Spacer()
                StatusPill(status: result.overallStatus)
            }
            HStack {
                Button("Investigate another app") { model.resetDoctor() }
                Button("Run again") { model.investigate() }
                Spacer()
                Button("Review & Export…") { model.beginExport(report) }
            }

            if !result.repairs.isEmpty { nextSteps }
            if model.lastExecution != nil { VerificationPanel() }

            ForEach(result.checks) { check in
                DisclosureGroup {
                    CheckResultView(result: check).padding(.top, Theme.s2)
                } label: {
                    HStack {
                        Text(check.title).font(.headline).foregroundStyle(Theme.text)
                        Spacer()
                        Text(check.summary).font(.callout).foregroundStyle(Theme.muted).lineLimit(1)
                        StatusPill(status: check.status, compact: true)
                    }
                }
                .padding(Theme.s3)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusLg))
            }

            if !result.logExcerpts.isEmpty {
                Card {
                    SectionTitle(title: "Recent log errors (redacted)",
                                 subtitle: "Shown here for context. Left out of exported reports unless you include them.")
                    ForEach(result.logExcerpts, id: \.self) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(e.date?.formatted(date: .omitted, time: .standard) ?? "—") · \(e.level)")
                                .font(.caption).foregroundStyle(e.level == "Fault" ? Theme.problem : Theme.warning)
                            Text(e.message).font(.callout.monospaced()).foregroundStyle(Theme.text).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .sheet(item: $confirming) { proposal in
            RepairConfirmSheet(proposal: proposal) { confirming = nil }
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }

    private var nextSteps: some View {
        Card {
            SectionTitle(title: "What you can do", subtitle: "Suggestions based on the evidence below. None runs without you.")
            ForEach(result.repairs) { p in
                HStack(alignment: .top, spacing: Theme.s3) {
                    Image(systemName: p.kind == .change ? "wrench.and.screwdriver" : "arrow.up.forward.app")
                        .foregroundStyle(p.kind == .change ? Theme.warning : Theme.accent).frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                        Text(p.issue).font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        Text(p.kind == .change ? "Changes your Mac · you'll confirm first" : "Opens something · changes nothing")
                            .font(.caption).foregroundStyle(p.kind == .change ? Theme.warning : Theme.muted)
                    }
                    Spacer()
                    if p.kind == .change {
                        Button("Review…") { confirming = p }
                    } else {
                        Button("Open") { model.perform(handoff: p) }
                    }
                }
                .padding(.vertical, Theme.s1)
            }
        }
    }
}

/// Explains the issue, evidence, exact action, side effects and undo, then asks for explicit confirmation.
struct RepairConfirmSheet: View {
    @Environment(AppModel.self) private var model
    var proposal: RepairProposal
    var dismiss: () -> Void
    @State private var acknowledged = false
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            Text(proposal.title).font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
            if model.isSample {
                Label("Sample mode: confirming won't change anything on this Mac.", systemImage: "theatermasks")
                    .foregroundStyle(Theme.sample)
            }
            block("Why this might help", [proposal.issue], symbol: "lightbulb")
            block("What MacCheck found", proposal.evidence, symbol: "doc.text.magnifyingglass")
            block("Exactly what will happen", [proposal.whatHappens], symbol: "wrench.and.screwdriver")
            block("Side effects", proposal.sideEffects, symbol: "exclamationmark.triangle")
            block("How to undo it", [proposal.howToUndo], symbol: "arrow.uturn.backward")
            block("How we'll check it helped", [proposal.verification], symbol: "checkmark.seal")
            Text("Confidence that this is the cause: \(proposal.confidence.rawValue). It's worth trying because it's limited and reversible, not because it's certain.")
                .font(.callout).foregroundStyle(Theme.muted)

            Toggle("I've read what will change and want to go ahead", isOn: $acknowledged)
                .toggleStyle(.checkbox)

            if let err = model.repairError {
                Label(err, systemImage: "xmark.octagon").foregroundStyle(Theme.problem)
            }
            if let exec = model.lastExecution, exec.proposalID == proposal.id {
                Label(exec.summary, systemImage: "checkmark.circle").foregroundStyle(Theme.ok)
            }

            HStack {
                Button("Keep things as they are", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.lastExecution?.proposalID == proposal.id {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(working ? "Working…" : proposal.title) {
                        working = true
                        Task {
                            await model.perform(change: proposal, acknowledged: acknowledged)
                            working = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!acknowledged || working)
                }
            }
        }
        .padding(Theme.s6)
        .frame(width: 560)
        .background(Theme.raised)
    }

    private func block(_ title: String, _ lines: [String], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
            ForEach(lines, id: \.self) { Text($0).font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// After a change: re-check for new evidence. Never claims success without it.
struct VerificationPanel: View {
    @Environment(AppModel.self) private var model
    @State private var usedSince = false
    @State private var checking = false

    var body: some View {
        Card {
            SectionTitle(title: "Did it help?", subtitle: model.lastExecution?.summary)
            Text("Use the app as you normally would. Then come back and check: MacCheck looks for new crash or hang reports dated after the change.")
                .font(.callout).foregroundStyle(Theme.muted)
            Toggle("I've opened and used the app since the change", isOn: $usedSince).toggleStyle(.checkbox)
            HStack {
                Button(checking ? "Checking…" : "Check now") {
                    checking = true
                    Task { await model.verifyRepair(appUsed: usedSince); checking = false }
                }
                .disabled(checking)
                Spacer()
            }
            if let v = model.verification {
                Divider().overlay(Theme.border)
                Label(v.headline, systemImage: v.outcome == .improved ? "checkmark.circle" : (v.outcome == .noChange ? "xmark.circle" : "hourglass"))
                    .font(.headline)
                    .foregroundStyle(v.outcome == .improved ? Theme.ok : (v.outcome == .noChange ? Theme.problem : Theme.warning))
                Text(v.outcome.title).font(.caption).foregroundStyle(Theme.muted)
                ForEach(v.details, id: \.self) { Text("• " + $0).font(.callout).foregroundStyle(Theme.muted) }
            }
        }
    }
}
#endif
