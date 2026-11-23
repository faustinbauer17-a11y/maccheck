#if os(macOS)
import SwiftUI
import MacCheckCore

/// Home screen: five live gauges, a drawing of the Mac, its specs, and a prompt to pick a test.
/// Every number comes from `AppModel.live`, which reads this Mac locally (no network).
struct HomeView: View {
    @Environment(AppModel.self) private var model

    private static let placeholderTitles = ["Processor", "Memory", "Storage", "Battery", "Thermal"]

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.s6) {
                gauges
                readingLine
                DeviceIllustration(modelName: model.live?.device?.modelName)
                    .padding(.top, Theme.s4)
                specs
                VStack(spacing: Theme.s3) {
                    Text("Please select a test or tool")
                        .font(.body).foregroundStyle(Theme.text)
                    Button { model.runFullDiagnostic() } label: {
                        Label(model.scanState == .running ? "Checking…" : "Check Computer", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.scanState == .running)
                    .keyboardShortcut(.defaultAction)
                    .help("Runs every test. Read-only, about 10 seconds.")
                }
                .padding(.top, Theme.s2)
            }
            .padding(.horizontal, Theme.s6)
            .padding(.vertical, Theme.s4)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("MacCheck")
        .task { if model.live == nil && !model.liveLoading { model.refreshLive() } }
    }

    // MARK: Gauges

    @ViewBuilder private var gauges: some View {
        HStack(alignment: .top, spacing: Theme.s6) {
            if let live = model.live {
                ForEach(live.gauges) { g in
                    Button { model.selection = .area(g.area) } label: { RingGauge(gauge: g) }
                        .buttonStyle(.plain)
                        .help(g.detail + " Click to open the \(g.area.title) test.")
                        .accessibilityLabel(g.detail)
                        .accessibilityHint("Opens the \(g.area.title) test")
                }
            } else {
                ForEach(Self.placeholderTitles, id: \.self) { title in
                    RingGauge(gauge: nil, placeholderTitle: title)
                }
            }
        }
    }

    private var readingLine: some View {
        HStack(spacing: Theme.s2) {
            if model.liveLoading {
                ProgressView().controlSize(.small)
                Text("Reading this Mac…")
            } else if let live = model.live {
                Text("Read at \(live.takenAt.formatted(date: .omitted, time: .standard))\(live.isSample ? " · sample data" : "")")
            }
            Button { model.refreshLive() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.liveLoading)
                .help("Reads the gauges again. Local only, nothing is changed.")
        }
        .font(.caption)
        .foregroundStyle(Theme.muted)
    }

    // MARK: Specs

    @ViewBuilder private var specs: some View {
        let live = model.live
        VStack(spacing: 3) {
            Text(live?.device?.modelName ?? (model.liveLoading ? " " : "This Mac"))
            if let chip = live?.device?.chip { Text(chip) }
            if let os = live?.device?.macOS {
                Text(os + (live?.macOSBuild.map { " (\($0))" } ?? ""))
            }
        }
        .font(.body)
        .foregroundStyle(Theme.text)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)

        HStack(spacing: Theme.s8) {
            if let memory = live?.memoryText { specChip(symbol: "memorychip", text: memory, label: "Memory") }
            if let storage = live?.storageText { specChip(symbol: "internaldrive", text: storage, label: "Startup disk") }
        }
    }

    private func specChip(symbol: String, text: String, label: String) -> some View {
        VStack(spacing: Theme.s2) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(Theme.text)
                .accessibilityHidden(true)
            Text(text).font(.callout).foregroundStyle(Theme.text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(text)")
        .help(label)
    }
}

// MARK: - Ring gauge

/// A dial with a 270° ring. Colour follows the level, and attention/problem levels also get an icon,
/// so meaning never depends on colour alone.
struct RingGauge: View {
    var gauge: LiveGauge?
    var placeholderTitle = ""

    private let size: CGFloat = 86
    private let sweep = 0.75 // 270°

    var body: some View {
        VStack(spacing: Theme.s2) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.dial, Theme.dialEdge], center: .center, startRadius: 4, endRadius: size / 2))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.06)))
                ticks
                Circle()
                    .trim(from: 0, to: sweep)
                    .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .padding(8)
                if let f = gauge?.fraction {
                    Circle()
                        .trim(from: 0, to: max(sweep * f, 0.004))
                        .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(135))
                        .padding(8)
                        .animation(.easeOut(duration: 0.6), value: f)
                }
                VStack(spacing: 0) {
                    if let gauge {
                        Text(gauge.value)
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                        Text(gauge.unit)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 18)
            }
            .frame(width: size, height: size)

            HStack(spacing: 4) {
                Text(gauge?.title ?? placeholderTitle).font(.callout.weight(.medium)).foregroundStyle(Theme.text)
                if let level = gauge?.level, level == .attention || level == .problem {
                    Image(systemName: level == .problem ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(color)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: size + 16)
        .contentShape(Rectangle())
    }

    private var ticks: some View {
        ForEach(0..<9, id: \.self) { i in
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 1.5, height: 5)
                .offset(y: -(size / 2) + 3)
                .rotationEffect(.degrees(-135 + Double(i) * 33.75))
        }
    }

    private var color: Color {
        switch gauge?.level ?? .neutral {
        case .good: return Theme.gauge
        case .attention: return Theme.warning
        case .problem: return Theme.problem
        case .neutral: return Theme.unavailable
        }
    }
}

// MARK: - Device drawing

/// A simple drawing of the Mac (no Apple artwork). Notebooks get a laptop; other Macs an SF Symbol.
struct DeviceIllustration: View {
    var modelName: String?

    var body: some View {
        Group {
            if let name = modelName, !name.localizedCaseInsensitiveContains("MacBook") {
                Image(systemName: desktopSymbol(name))
                    .font(.system(size: 120, weight: .ultraLight))
                    .foregroundStyle(Theme.text.opacity(0.85))
            } else {
                laptop
            }
        }
        .accessibilityHidden(true)
    }

    private func desktopSymbol(_ name: String) -> String {
        if name.localizedCaseInsensitiveContains("mini") { return "macmini" }
        if name.localizedCaseInsensitiveContains("Studio") { return "macstudio" }
        if name.localizedCaseInsensitiveContains("Mac Pro") { return "macpro.gen3" }
        return "desktopcomputer"
    }

    private var laptop: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(white: 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(white: 0.6), lineWidth: 1.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Theme.rgb(0x6CC0FA), Theme.rgb(0x2F86E0), Theme.rgb(0x1F5FB8)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        Ellipse()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 260, height: 90)
                            .offset(x: -40, y: 50)
                            .blur(radius: 14)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(7)
                UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
                    .fill(Color(white: 0.06))
                    .frame(width: 28, height: 6)
                    .padding(.top, 7)
            }
            .frame(width: 212, height: 138)

            ZStack(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 9, bottomTrailingRadius: 9, topTrailingRadius: 2)
                    .fill(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.62), Color(white: 0.45)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 252, height: 10)
                UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
                    .fill(Color(white: 0.5))
                    .frame(width: 38, height: 3)
            }
        }
        .shadow(color: .black.opacity(0.55), radius: 14, y: 8)
    }
}
#endif
