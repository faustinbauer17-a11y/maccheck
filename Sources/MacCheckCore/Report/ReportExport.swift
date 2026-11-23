import Foundation

public enum ReportFormat: String, CaseIterable, Sendable, Identifiable {
    case markdown, json, text
    public var id: String { rawValue }
    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .json: return "json"
        case .text: return "txt"
        }
    }
    public var title: String {
        switch self {
        case .markdown: return "Markdown (.md)"
        case .json: return "JSON (.json)"
        case .text: return "Plain text (.txt)"
        }
    }
}

/// What goes into an export. Privacy-preserving defaults; the user reviews before saving.
public struct ReportOptions: Equatable, Sendable {
    /// Serial number and other unique identifiers. Off by default.
    public var includeIdentifiers = false
    /// Redacted log excerpts from App Doctor. Off by default.
    public var includeLogExcerpts = false
    public var includeLimitations = true
    public var areas: Set<DiagnosticArea> = Set(DiagnosticArea.allCases)
    public var includeAppDoctor = true
    public var format: ReportFormat = .markdown

    public init() {}
}

/// A report being prepared for export. `markReviewed()` must be called (by the review screen)
/// after the user has seen the final text; exporting an unreviewed draft is refused.
public struct ReportDraft: Sendable {
    public private(set) var report: ScanReport
    public var options: ReportOptions {
        didSet { reviewed = false } // any change invalidates the review
    }
    public private(set) var reviewed = false
    public var redactor: Redactor

    public init(report: ScanReport, options: ReportOptions = ReportOptions(), redactor: Redactor = Redactor()) {
        self.report = report
        self.options = options
        self.redactor = redactor
    }

    /// The exact text that will be written. Shown in full on the review screen.
    public func render() -> String {
        ReportRenderer.render(report: filtered(), options: options, redactor: redactor)
    }

    public func redactionSummary() -> Redactor.Output {
        let raw = ReportRenderer.render(report: filtered(), options: options, redactor: Redactor(knownValues: []), redact: false)
        return redactor.redact(raw)
    }

    public mutating func markReviewed() { reviewed = true }

    func filtered() -> ScanReport {
        var r = options.includeIdentifiers ? report : report.withoutSensitiveData()
        r.results = r.results.filter { $0.area.map(options.areas.contains) ?? true }
        if !options.includeAppDoctor { r.appDoctor = nil }
        if !options.includeLogExcerpts, var doc = r.appDoctor {
            doc.logExcerpts = []
            r.appDoctor = doc
        }
        return r
    }
}

public enum ExportError: Error, Equatable, CustomStringConvertible, Sendable {
    case notReviewed
    case writeFailed(String)

    public var description: String {
        switch self {
        case .notReviewed: return "Please review the report before saving it."
        case let .writeFailed(m): return "The report couldn't be saved: \(m)"
        }
    }
}

/// Writes reports to a local file the user picked. There is no network code in this path.
public enum ReportExporter {
    public static func data(for draft: ReportDraft) throws -> Data {
        guard draft.reviewed else { throw ExportError.notReviewed }
        return Data(draft.render().utf8)
    }

    public static func write(_ draft: ReportDraft, to url: URL) throws {
        let data = try data(for: draft)
        do { try data.write(to: url, options: [.atomic]) } catch { throw ExportError.writeFailed(error.localizedDescription) }
    }

    public static func suggestedFileName(for report: ScanReport, format: ReportFormat) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let prefix = report.isSampleData ? "MacCheck-SAMPLE" : "MacCheck"
        return "\(prefix)-\(f.string(from: report.createdAt)).\(format.fileExtension)"
    }
}

public enum ReportRenderer {
    static let sampleBanner = "SAMPLE DATA — not from this Mac. Generated for demonstration only."

    public static func render(report: ScanReport, options: ReportOptions, redactor: Redactor, redact: Bool = true) -> String {
        let text: String
        switch options.format {
        case .json: text = json(report)
        case .markdown: text = markdown(report, options: options)
        case .text: text = plain(report, options: options)
        }
        return redact ? redactor(text) : text
    }

    static func json(_ report: ScanReport) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(report), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    static func markdown(_ r: ScanReport, options: ReportOptions) -> String {
        var out: [String] = []
        out.append("# MacCheck report")
        if r.isSampleData { out.append("\n> **\(sampleBanner)**") }
        out.append("")
        out.append("- Created: \(Fmt.isoDate(r.createdAt))")
        out.append("- MacCheck version: \(r.appVersion)")
        if let d = r.device {
            out.append("- Mac: \(d.modelName)" + (d.chip.map { ", \($0)" } ?? "") + (d.memory.map { ", \($0)" } ?? ""))
            if let os = d.macOS { out.append("- macOS: \(os)") }
        }
        out.append("- Overall: **\(r.overallStatus.title)**")
        if r.wasCancelled { out.append("- Note: the scan was cancelled; some checks did not run.") }
        out.append("")
        out.append("_Evidence labels: Measured = read from macOS; Reported by macOS = macOS's own verdict; Calculated = derived by MacCheck; Possible explanation = an inference, not a confirmed diagnosis._")

        for result in r.results { out.append(contentsOf: section(result, level: "##", options: options)) }

        if let doc = r.appDoctor {
            out.append("\n## App Doctor: \(doc.appName)" + (doc.appVersion.map { " \($0)" } ?? ""))
            out.append("Reported symptom: \(doc.symptom.title)\n")
            for c in doc.checks { out.append(contentsOf: section(c, level: "###", options: options)) }
            if !doc.repairs.isEmpty {
                out.append("\n### Suggested next steps")
                for p in doc.repairs { out.append("- **\(p.title)** (\(p.kind == .change ? "changes your Mac, needs confirmation" : "opens something, changes nothing")): \(p.issue)") }
            }
            if !doc.logExcerpts.isEmpty {
                out.append("\n### Log excerpts (redacted)")
                for e in doc.logExcerpts {
                    out.append("- \(e.date.map(Fmt.isoDate) ?? "?") [\(e.level)] \(e.message)")
                }
            }
        }
        out.append("\n---\nGenerated locally by MacCheck. Nothing was uploaded. Likely personal data and secrets were redacted.")
        return out.joined(separator: "\n")
    }

    static func section(_ c: CheckResult, level: String, options: ReportOptions) -> [String] {
        var out = ["\n\(level) \(c.title) — \(c.status.title)", c.summary]
        if let e = c.errorDescription { out.append("Error: \(e)") }
        if !c.measurements.isEmpty {
            out.append("")
            out.append("| Item | Value | Evidence | Source |")
            out.append("|---|---|---|---|")
            for m in c.measurements {
                out.append("| \(cell(m.label)) | \(cell(m.display)) | \(m.evidence.label) | \(cell(m.source.name)) |")
            }
        }
        let shown = c.findings
        if !shown.isEmpty {
            out.append("")
            for f in shown {
                var line = "- **\(kindLabel(f.kind))**: \(f.title). \(f.detail)"
                if let conf = f.confidence { line += " _(confidence: \(conf.rawValue))_" }
                out.append(line)
                for a in f.advice { out.append("  - \(a)") }
                for l in f.links { out.append("  - \(l.path)") }
            }
        }
        if options.includeLimitations && !c.limitations.isEmpty {
            out.append("\nLimits of this check:")
            for l in c.limitations { out.append("- \(l)") }
        }
        return out
    }

    static func kindLabel(_ k: FindingKind) -> String { k.label }

    static func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }

    static func plain(_ r: ScanReport, options: ReportOptions) -> String {
        // Markdown minus the table/emphasis syntax: readable in any editor.
        markdown(r, options: options)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "|---|---|---|---|\n", with: "")
            .replacingOccurrences(of: "_Evidence", with: "Evidence")
    }
}
