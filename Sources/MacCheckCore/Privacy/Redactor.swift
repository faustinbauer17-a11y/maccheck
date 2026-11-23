import Foundation

/// Removes likely personal data and secrets from text before it is displayed in log excerpts,
/// stored, or exported. Conservative by design: it would rather hide too much than too little.
public struct Redactor: Sendable {
    public enum Category: String, CaseIterable, Codable, Sendable {
        case userName, email, ipAddress, macAddress, uuid, secret, longToken, urlQuery, hostName, serial, knownValue
    }

    public struct Output: Sendable, Equatable {
        public var text: String
        public var counts: [Category: Int]
        public var total: Int { counts.values.reduce(0, +) }
    }

    /// Exact strings to always hide (account short name, full name, computer name, serial if collected).
    public var knownValues: [String]

    public init(knownValues: [String] = []) {
        // Ignore very short values to avoid shredding normal words.
        self.knownValues = knownValues.filter { $0.count >= 3 }.sorted { $0.count > $1.count }
    }

    private struct Rule {
        let category: Category
        let regex: NSRegularExpression
        let template: String
    }

    private static func rx(_ pattern: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are constants covered by tests; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: opts)
    }

    /// Order matters: secrets and labelled identifiers first, then structural patterns.
    private static let rules: [Rule] = [
        // key=value / key: value secrets — keep the key, hide the value.
        Rule(category: .secret,
             regex: rx(#"(?i)\b(password|passwd|pwd|passphrase|secret|token|access[_-]?token|refresh[_-]?token|api[_-]?key|apikey|client[_-]?secret|auth|authorization|cookie|session[_-]?id|sessionid)\b("?\s*[:=]\s*)((?:bearer\s+|basic\s+)?(?:"[^"]*"|'[^']*'|[^\s,;&"']+))"#),
             template: "$1$2<redacted>"),
        Rule(category: .secret, regex: rx(#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#), template: "Bearer <redacted>"),
        // Labelled device identifiers.
        Rule(category: .serial,
             regex: rx(#"(?i)\b(serial(\s*number)?|IOPlatformSerialNumber|hardware\s*uuid|provisioning\s*udid|crashReporterKey|crash\s*reporter\s*key|sleepWakeUUID|deviceIdentifier)("?\s*[:=]\s*"?)([A-Za-z0-9-]+)"#),
             template: "$1$3<redacted>"),
        Rule(category: .email, regex: rx(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#), template: "<email>"),
        // Home directories: /Users/<name>/ → /Users/<user>/ (Shared is not personal).
        Rule(category: .userName, regex: rx(#"/Users/(?!Shared\b)(?!<user>)[^/\s:"']+"#), template: "/Users/<user>"),
        Rule(category: .urlQuery, regex: rx(#"(https?://[^\s?#"']+)\?[^\s"']*"#), template: "$1?<redacted>"),
        Rule(category: .uuid, regex: rx(#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#), template: "<uuid>"),
        Rule(category: .macAddress, regex: rx(#"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#), template: "<mac-address>"),
        Rule(category: .ipAddress, regex: rx(#"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#), template: "<ip>"),
        // IPv6: at least three colon-separated hex groups, or a "::" compression with hex around it.
        Rule(category: .ipAddress, regex: rx(#"(?<![\w:])(?:[0-9A-Fa-f]{1,4}:){3,7}[0-9A-Fa-f]{1,4}(?![\w:])|(?<![\w:])(?:[0-9A-Fa-f]{1,4}:){1,6}:(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,5})?(?![\w:])"#),
             template: "<ip>"),
        Rule(category: .hostName, regex: rx(#"\b[A-Za-z0-9-]+\.local\b"#), template: "<host>.local"),
        // Long opaque tokens (hex ≥ 32 or base64-like ≥ 40) are likely keys or identifiers.
        Rule(category: .longToken, regex: rx(#"\b[0-9A-Fa-f]{32,}\b"#), template: "<token>"),
        // Base64-like: no "/" (so file paths survive) and must contain a digit (so long identifiers survive).
        Rule(category: .longToken, regex: rx(#"(?<![A-Za-z0-9+_-])(?=[A-Za-z0-9+_-]*\d)(?=[A-Za-z0-9+_-]*[A-Za-z])[A-Za-z0-9+_-]{40,}={0,2}(?![A-Za-z0-9+_-])"#), template: "<token>"),
    ]

    public func redact(_ input: String) -> Output {
        var text = input
        var counts: [Category: Int] = [:]

        // Whole-word, case-insensitive: the account name "anna" hides "Anna" but leaves "Annapurna" intact.
        for value in knownValues {
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: value) + "(?![A-Za-z0-9])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(location: 0, length: (text as NSString).length)
            let found = regex.numberOfMatches(in: text, options: [], range: range)
            guard found > 0 else { continue }
            counts[.knownValue, default: 0] += found
            text = regex.stringByReplacingMatches(in: text, options: [], range: range,
                                                  withTemplate: NSRegularExpression.escapedTemplate(for: "<redacted>"))
        }

        for rule in Self.rules {
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            let n = rule.regex.numberOfMatches(in: text, options: [], range: range)
            guard n > 0 else { continue }
            counts[rule.category, default: 0] += n
            text = rule.regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: rule.template)
        }
        return Output(text: text, counts: counts)
    }

    /// Convenience: redacted text only.
    public func callAsFunction(_ input: String) -> String { redact(input).text }
}
