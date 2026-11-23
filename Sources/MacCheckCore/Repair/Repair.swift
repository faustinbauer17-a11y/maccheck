import Foundation

/// `handoff` only opens something (a Settings pane, Finder, Console) — it changes nothing.
/// `change` modifies the Mac and always needs explicit, informed consent first.
public enum RepairKind: String, Codable, Sendable {
    case handoff, change
}

public enum RepairActionType: Codable, Sendable, Hashable {
    case openLink(SystemSettingsLink)
    case revealInFinder(path: String)
    /// Moves `~/Library/Saved Application State/<bundleID>.savedState` to the Trash (recoverable with Put Back).
    case moveSavedStateToTrash(bundleIdentifier: String)
}

/// A proposed action, explained in plain language before anything happens.
public struct RepairProposal: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: RepairKind
    public var action: RepairActionType
    public var title: String
    /// The suspected issue (never stated as certain).
    public var issue: String
    public var evidence: [String]
    /// Exactly what will be done.
    public var whatHappens: String
    public var sideEffects: [String]
    public var howToUndo: String
    /// How MacCheck will check whether it helped.
    public var verification: String
    public var confidence: Confidence

    public init(id: String, kind: RepairKind, action: RepairActionType, title: String, issue: String,
                evidence: [String], whatHappens: String, sideEffects: [String], howToUndo: String,
                verification: String, confidence: Confidence) {
        self.id = id
        self.kind = kind
        self.action = action
        self.title = title
        self.issue = issue
        self.evidence = evidence
        self.whatHappens = whatHappens
        self.sideEffects = sideEffects
        self.howToUndo = howToUndo
        self.verification = verification
        self.confidence = confidence
    }

    /// Only bundle identifiers of a conservative shape are ever turned into file paths.
    public static func isSafeBundleIdentifier(_ s: String) -> Bool {
        s.count <= 155 && !s.contains("..") && s.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$"#, options: .regularExpression) != nil
    }

    /// Relative to the user's home folder.
    public static func savedStateRelativePath(for bundleID: String) -> String {
        "Library/Saved Application State/\(bundleID).savedState"
    }
}

// MARK: - Consent

public enum ConsentError: Error, Equatable, CustomStringConvertible, Sendable {
    case sideEffectsNotAcknowledged
    case tokenForDifferentAction
    case expired
    case alreadyUsed
    case handoffNeedsNoConsent

    public var description: String {
        switch self {
        case .sideEffectsNotAcknowledged: return "Please confirm you've read what will change."
        case .tokenForDifferentAction: return "This confirmation was given for a different action."
        case .expired: return "The confirmation expired. Please review and confirm again."
        case .alreadyUsed: return "This confirmation was already used. Each change needs its own confirmation."
        case .handoffNeedsNoConsent: return "This action only opens something and doesn't change your Mac."
        }
    }
}

/// Proof that the user confirmed one specific change, just now.
public struct ConsentToken: Sendable, Equatable {
    public let proposalID: String
    public let grantedAt: Date
    public let nonce: UUID
}

/// Issues single-use, short-lived consent tokens bound to one proposal.
public final class ConsentGate: @unchecked Sendable {
    public let validity: TimeInterval
    private let lock = NSLock()
    private var used = Set<UUID>()

    public init(validity: TimeInterval = 120) {
        self.validity = validity
    }

    public func grant(for proposal: RepairProposal, acknowledgedSideEffects: Bool, now: Date = Date()) throws -> ConsentToken {
        guard proposal.kind == .change else { throw ConsentError.handoffNeedsNoConsent }
        guard acknowledgedSideEffects else { throw ConsentError.sideEffectsNotAcknowledged }
        return ConsentToken(proposalID: proposal.id, grantedAt: now, nonce: UUID())
    }

    /// Validates and consumes the token. Throws if it doesn't match, has expired or was used.
    public func redeem(_ token: ConsentToken, for proposal: RepairProposal, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        guard token.proposalID == proposal.id else { throw ConsentError.tokenForDifferentAction }
        guard !used.contains(token.nonce) else { throw ConsentError.alreadyUsed }
        guard now.timeIntervalSince(token.grantedAt) <= validity, now >= token.grantedAt else { throw ConsentError.expired }
        used.insert(token.nonce)
    }
}

public struct RepairExecution: Codable, Sendable, Hashable {
    public var proposalID: String
    public var performedAt: Date
    public var summary: String
    public var undoHint: String
    /// Where the item went (e.g. the path inside the Trash), when known.
    public var resultingPath: String?

    public init(proposalID: String, performedAt: Date, summary: String, undoHint: String, resultingPath: String?) {
        self.proposalID = proposalID
        self.performedAt = performedAt
        self.summary = summary
        self.undoHint = undoHint
        self.resultingPath = resultingPath
    }
}

/// Performs a change. The macOS implementation lives in MacCheckMac; tests use fakes.
public protocol RepairPerformer: Sendable {
    func perform(_ proposal: RepairProposal) async throws -> RepairExecution
}

/// The only path from a proposal to a change: consent is checked immediately before performing.
public struct RepairCoordinator: Sendable {
    public let gate: ConsentGate
    public let performer: RepairPerformer

    public init(gate: ConsentGate, performer: RepairPerformer) {
        self.gate = gate
        self.performer = performer
    }

    public func execute(_ proposal: RepairProposal, token: ConsentToken, now: Date = Date()) async throws -> RepairExecution {
        guard proposal.kind == .change else { throw ConsentError.handoffNeedsNoConsent }
        try gate.redeem(token, for: proposal, now: now)
        return try await performer.perform(proposal)
    }
}

// MARK: - Verification

public enum VerificationOutcome: String, Codable, Sendable {
    case improved, noChange, inconclusive

    public var title: String {
        switch self {
        case .improved: return "Looks better so far"
        case .noChange: return "Not fixed"
        case .inconclusive: return "Not enough information yet"
        }
    }
}

public struct VerificationResult: Codable, Sendable, Hashable {
    public var outcome: VerificationOutcome
    public var headline: String
    public var details: [String]
    public var checkedAt: Date
}

/// Compares evidence after a change with evidence before it. Never declares success without new evidence.
public enum RepairVerifier {
    public static func verify(execution: RepairExecution, symptom: Symptom,
                              reportsForApp: [CrashReportSummary], appUsedSinceChange: Bool,
                              now: Date = Date()) -> VerificationResult {
        let relevantKinds: Set<DiagnosticReportKind> = symptom == .freezes ? [.hang] : [.crash, .hang]
        let after = reportsForApp.filter { r in
            guard let d = r.date else { return false }
            return d > execution.performedAt && relevantKinds.contains(r.kind)
        }
        let minutes = Int(now.timeIntervalSince(execution.performedAt) / 60)
        var details = ["Change made: \(execution.summary)",
                       "Checked \(minutes) minute\(minutes == 1 ? "" : "s") after the change."]

        if !after.isEmpty {
            details.append("\(after.count) new report\(after.count == 1 ? "" : "s") since the change (latest: \(after.compactMap(\.date).max().map(Fmt.isoDate) ?? "unknown")).")
            details.append("You can undo the change: \(execution.undoHint)")
            return VerificationResult(outcome: .noChange, headline: "The problem happened again after the change",
                                      details: details, checkedAt: now)
        }
        guard appUsedSinceChange else {
            details.append("No new reports, but the app hasn't been used since the change, so there's nothing to compare yet.")
            return VerificationResult(outcome: .inconclusive, headline: "Open the app and use it as usual, then verify again",
                                      details: details, checkedAt: now)
        }
        details.append("No new crash or hang reports since the change while the app was in use.")
        details.append("This is encouraging, not proof. Problems that happen rarely may still come back — verify again in a day or two.")
        return VerificationResult(outcome: .improved, headline: "No new problems since the change",
                                  details: details, checkedAt: now)
    }
}
