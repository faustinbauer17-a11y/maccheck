#if os(macOS)
import SwiftUI
import MacCheckCore

/// Design tokens. Dark, calm, slightly blue-tinted neutrals; one accent; semantic status colours
/// that are always paired with an icon and a word (never colour alone).
enum Theme {
    static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    // Surfaces: higher elevation = lighter.
    static let background = rgb(0x0E1116)
    static let surface = rgb(0x151A21)
    static let raised = rgb(0x1B222B)
    static let border = rgb(0x28313C)
    static let text = rgb(0xE6EAF0)
    static let muted = rgb(0xA3ADBB)   // ≥ 4.5:1 on `surface`
    static let accent = rgb(0x6AA8FF)
    static let accentSoft = rgb(0x6AA8FF).opacity(0.14)

    static let ok = rgb(0x5CCB8E)
    static let info = rgb(0x7FAEFF)
    static let warning = rgb(0xE9B54F)
    static let problem = rgb(0xF2766F)
    static let unavailable = rgb(0x95A0AF)
    static let failed = rgb(0xC9A2F2)
    static let sample = rgb(0xE9B54F)

    // Spacing (4-pt scale) and radii.
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16, s6: CGFloat = 24, s8: CGFloat = 32
    static let radiusSm: CGFloat = 6, radiusMd: CGFloat = 10, radiusLg: CGFloat = 14
}

extension CheckStatus {
    var color: Color {
        switch self {
        case .ok: return Theme.ok
        case .info: return Theme.info
        case .warning: return Theme.warning
        case .problem: return Theme.problem
        case .unavailable, .skipped: return Theme.unavailable
        case .failed: return Theme.failed
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        case .unavailable: return "minus.circle"
        case .skipped: return "forward.circle"
        case .failed: return "questionmark.diamond"
        }
    }
}

extension FindingKind {
    var symbol: String {
        switch self {
        case .fact: return "checkmark.seal"
        case .warning: return "exclamationmark.triangle"
        case .problem: return "xmark.octagon"
        case .unavailable: return "eye.slash"
        case .possibleExplanation: return "lightbulb"
        case .limitation: return "ruler"
        }
    }

    var color: Color {
        switch self {
        case .fact: return Theme.ok
        case .warning: return Theme.warning
        case .problem: return Theme.problem
        case .unavailable, .limitation: return Theme.unavailable
        case .possibleExplanation: return Theme.info
        }
    }

}

// MARK: - Components

struct Card<Content: View>: View {
    var padding: CGFloat = Theme.s4
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusLg))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg).strokeBorder(Theme.border))
    }
}

struct StatusPill: View {
    var status: CheckStatus
    var compact = false

    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(status.color)
            .padding(.horizontal, compact ? 6 : 10)
            .padding(.vertical, compact ? 2 : 4)
            .background(status.color.opacity(0.13), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(status.title)")
    }
}

struct EvidenceTag: View {
    var evidence: EvidenceLevel
    var body: some View {
        Text(evidence.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(evidence == .sample ? Theme.sample : Theme.muted)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(evidence == .sample ? Theme.sample.opacity(0.6) : Theme.border))
            .accessibilityLabel("Evidence: \(evidence.label)")
    }
}

struct SampleBanner: View {
    var body: some View {
        Label("Sample data — not from this Mac. Switch to live data in Settings.", systemImage: "theatermasks")
            .font(.callout.weight(.semibold))
            .foregroundStyle(Theme.background)
            .padding(.horizontal, Theme.s4).padding(.vertical, Theme.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sample)
            .accessibilityLabel("Sample data mode. Results are not from this Mac.")
    }
}

struct SectionTitle: View {
    var title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
            if let s = subtitle { Text(s).font(.callout).foregroundStyle(Theme.muted) }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.s3) {
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
            Text(message).font(.body).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
            if let t = actionTitle, let a = action {
                Button(t, action: a).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, Theme.s2)
            }
        }
        .padding(Theme.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, Theme.s6).padding(.vertical, Theme.s3)
            .foregroundStyle(Theme.background)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
    }
}
#endif
