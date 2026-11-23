import Foundation

/// Accumulates measurements and findings for one check and derives an honest status.
struct ResultBuilder {
    let id: String
    let area: DiagnosticArea?
    let title: String
    let started: Date
    let isSample: Bool

    var measurements: [Measurement] = []
    var findings: [Finding] = []
    var limitations: [String] = []
    var sources: [DataSource] = []
    private var measuredSomething = false

    init(id: String, area: DiagnosticArea?, title: String, started: Date, isSample: Bool) {
        self.id = id
        self.area = area
        self.title = title
        self.started = started
        self.isSample = isSample
    }

    private func evidence(_ e: EvidenceLevel) -> EvidenceLevel { isSample ? .sample : e }

    /// Records a reading as a measurement, or an `unavailable` finding with the reason.
    mutating func add<T>(_ reading: Reading<T>, key: String, label: String,
                         evidence: EvidenceLevel = .measured, sensitive: Bool = false,
                         reportUnavailable: Bool = true,
                         numeric: (T) -> Double? = { _ in nil }, display: (T) -> String) {
        switch reading {
        case let .value(v, source):
            measuredSomething = true
            if !sources.contains(source) { sources.append(source) }
            measurements.append(Measurement(key: key, label: label, display: display(v), numeric: numeric(v),
                                            source: source, evidence: self.evidence(evidence), isSensitive: sensitive))
        case let .unavailable(reason):
            if reportUnavailable {
                findings.append(Finding(id: "\(key).unavailable", kind: .unavailable, title: "\(label): not available",
                                        detail: reason, evidence: self.evidence(.measured)))
            }
        }
    }

    mutating func addDerived(key: String, label: String, display: String, numeric: Double?) {
        measuredSomething = true
        let src = isSample ? DataSource.sample : DataSource("Calculated by MacCheck", kind: .derived)
        measurements.append(Measurement(key: key, label: label, display: display, numeric: numeric,
                                        source: src, evidence: evidence(.derived)))
    }

    mutating func finding(_ id: String, _ kind: FindingKind, _ title: String, _ detail: String,
                          evidence: EvidenceLevel = .measured, confidence: Confidence? = nil,
                          advice: [String] = [], links: [SystemSettingsLink] = []) {
        findings.append(Finding(id: id, kind: kind, title: title, detail: detail, evidence: self.evidence(evidence),
                                confidence: confidence, advice: advice, links: links))
    }

    mutating func limit(_ text: String) { limitations.append(text) }

    /// Status: worst finding wins; with no measured data at all the check is `unavailable`, never "ok".
    func build(summary explicitSummary: String? = nil, informational: Bool = false) -> CheckResult {
        var status: CheckStatus
        if findings.contains(where: { $0.kind == .problem }) {
            status = .problem
        } else if findings.contains(where: { $0.kind == .warning }) {
            status = .warning
        } else if !measuredSomething {
            status = .unavailable
        } else {
            status = informational ? .info : .ok
        }
        let summary = explicitSummary ?? defaultSummary(status)
        var srcs = sources
        if isSample && !srcs.contains(.sample) { srcs.insert(.sample, at: 0) }
        return CheckResult(id: id, area: area, title: title, status: status, summary: summary,
                           startedAt: started, finishedAt: Date(), measurements: measurements,
                           findings: findings, limitations: limitations, sources: srcs)
    }

    private func defaultSummary(_ status: CheckStatus) -> String {
        switch status {
        case .problem: return findings.first { $0.kind == .problem }?.title ?? "A problem was found."
        case .warning: return findings.first { $0.kind == .warning }?.title ?? "Something needs attention."
        case .unavailable: return "macOS did not provide the data this check needs on this Mac."
        default: return "Nothing unusual found in what MacCheck can measure."
        }
    }
}
