import Foundation

// MARK: - Diagnostic reports (.ips / .crash / .hang / .spin / .diag)

/// Parses macOS diagnostic reports from `~/Library/Logs/DiagnosticReports`.
///
/// Supports the JSON `.ips` format (one JSON header line + JSON body, macOS 12+) and the older
/// text format. Only summary fields are kept; thread backtraces and binary image lists are dropped.
/// Format details are reverse-documented by Apple ("Interpreting the JSON format of a crash report");
/// fields that are absent are simply left nil.
public enum DiagnosticReportParser {
    /// Max bytes read from one report. Reports can be several MB; the summary is near the top.
    public static let maxBytes = 512 * 1024

    public static func parse(fileName: String, data: Data) -> CrashReportSummary? {
        let slice = data.prefix(maxBytes)
        guard let text = String(data: slice, encoding: .utf8) ?? String(data: slice, encoding: .isoLatin1) else { return nil }
        let lower = fileName.lowercased()
        if lower.hasSuffix(".ips") || text.hasPrefix("{") {
            if let r = parseIPS(fileName: fileName, text: text) { return r }
        }
        return parseText(fileName: fileName, text: text)
    }

    static func kind(bugType: String?, fileName: String, exceptionType: String?) -> DiagnosticReportKind {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".hang") || lower.hasSuffix(".spin") || lower.contains("_hang") { return .hang }
        if lower.contains("cpu_resource") || lower.contains("wakeups_resource") || lower.contains("diskwrites_resource")
            || lower.hasSuffix(".diag") { return .resource }
        if lower.hasPrefix("jetsamevent") { return .jetsam }
        switch bugType {
        case "309", "109": return exceptionType == "EXC_RESOURCE" ? .resource : .crash
        case "298": return .jetsam
        case "288", "228", "409": return .hang
        default: break
        }
        if exceptionType != nil { return .crash }
        return .other
    }

    static func parseIPS(fileName: String, text: String) -> CrashReportSummary? {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let headerLine = parts.first,
              let header = (try? JSONSerialization.jsonObject(with: Data(headerLine.utf8))) as? [String: Any]
        else { return nil }

        var body: [String: Any] = [:]
        if parts.count > 1, let b = (try? JSONSerialization.jsonObject(with: Data(parts[1].utf8))) as? [String: Any] {
            body = b
        }

        let bugType = header["bug_type"] as? String ?? (header["bug_type"] as? Int).map(String.init)
        let exception = body["exception"] as? [String: Any]
        let exceptionType = exception?["type"] as? String
        let signal = exception?["signal"] as? String
        var termination: String?
        if let t = body["termination"] as? [String: Any] {
            let ns = t["namespace"] as? String
            let ind = t["indicator"] as? String
            termination = [ns, ind].compactMap { $0 }.joined(separator: ": ")
            if termination?.isEmpty == true { termination = nil }
        }

        // Launch-failure hints (dyld) and the app-specific message are the most useful one-liners.
        var detail: String?
        if let asi = body["asi"] as? [String: Any] {
            let lines = asi.values.compactMap { $0 as? [String] }.flatMap { $0 }
            detail = lines.first { $0.contains("Library not loaded") || $0.contains("Symbol not found") } ?? lines.first
        }
        if detail == nil, let reason = body["crashReason"] as? String ?? (exception?["message"] as? String) {
            detail = reason
        }
        if let d = detail { detail = String(d.prefix(300)) }

        let ts = header["timestamp"] as? String ?? body["captureTime"] as? String
        let osVersion = (header["os_version"] as? String) ?? ((body["osVersion"] as? [String: Any])?["train"] as? String)
        let bundle = header["bundleID"] as? String ?? (body["bundleInfo"] as? [String: Any])?["CFBundleIdentifier"] as? String
        let version = header["app_version"] as? String
            ?? (body["bundleInfo"] as? [String: Any])?["CFBundleShortVersionString"] as? String

        return CrashReportSummary(
            fileName: fileName,
            date: ts.flatMap(parseDate),
            kind: kind(bugType: bugType, fileName: fileName, exceptionType: exceptionType),
            processName: header["app_name"] as? String ?? header["name"] as? String ?? body["procName"] as? String,
            bundleIdentifier: bundle, appVersion: version, osVersion: osVersion,
            exceptionType: exceptionType, signal: signal, terminationReason: termination, detail: detail)
    }

    static func parseText(fileName: String, text: String) -> CrashReportSummary? {
        var fields: [String: String] = [:]
        var detail: String?
        for raw in text.split(separator: "\n").prefix(400) {
            let line = String(raw)
            if detail == nil, line.contains("Library not loaded") || line.contains("Symbol not found") {
                detail = String(line.trimmingCharacters(in: .whitespaces).prefix(300))
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil, !key.isEmpty, key.count < 40 { fields[key] = value }
        }
        let process = fields["Process"].map { $0.components(separatedBy: " [").first ?? $0 } ?? fields["Command"]
        guard process != nil || fields["Exception Type"] != nil || fields["Event"] != nil else { return nil }

        var exceptionType = fields["Exception Type"]
        var signal: String?
        if let et = exceptionType, let open = et.firstIndex(of: "(") {
            signal = et[et.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
            exceptionType = et[..<open].trimmingCharacters(in: .whitespaces)
        }
        var kind = kind(bugType: nil, fileName: fileName, exceptionType: exceptionType)
        if let event = fields["Event"]?.lowercased() {
            if event.contains("hang") || event.contains("spin") { kind = .hang }
            else if event.contains("resource") || event.contains("cpu") || event.contains("wakeups") { kind = .resource }
        }
        let version = fields["Version"].map { $0.components(separatedBy: " (").first ?? $0 }
        return CrashReportSummary(
            fileName: fileName,
            date: (fields["Date/Time"] ?? fields["Date"]).flatMap(parseDate),
            kind: kind, processName: process, bundleIdentifier: fields["Identifier"],
            appVersion: version, osVersion: fields["OS Version"], exceptionType: exceptionType,
            signal: signal, terminationReason: fields["Termination Reason"], detail: detail)
    }

    /// Accepts "2025-06-01 10:11:12.00 +0200", "2025-06-01 10:11:12.123 +0200" and "2025-06-01 10:11:12 +0200".
    public static func parseDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss.SSS Z", "yyyy-MM-dd HH:mm:ss.SSSS Z",
                       "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss.SSSSSSZ"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }

    /// Does this report belong to the given app?
    public static func matches(_ r: CrashReportSummary, bundleIdentifier: String?, executableName: String?, appName: String) -> Bool {
        if let b = bundleIdentifier, let rb = r.bundleIdentifier { return b.caseInsensitiveCompare(rb) == .orderedSame }
        let names = [executableName, appName].compactMap { $0?.lowercased() }
        if let p = r.processName?.lowercased(), names.contains(p) { return true }
        let file = r.fileName.lowercased()
        return names.contains { file.hasPrefix($0 + "-") || file.hasPrefix($0 + "_") || file.hasPrefix($0 + ".") }
    }
}

// MARK: - Mach-O architectures

/// Reads which CPU architectures an executable contains (universal or thin Mach-O). Read-only, header only.
public enum MachOReader {
    static let cpuTypeX86_64: UInt32 = 0x0100_0007
    static let cpuTypeI386: UInt32 = 0x0000_0007
    static let cpuTypeARM64: UInt32 = 0x0100_000C
    static let cpuSubtypeARM64E: UInt32 = 2

    public static func architectures(of data: Data) -> [CPUArch]? {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data.prefix(4096))
        func be32(_ o: Int) -> UInt32? {
            guard o + 4 <= bytes.count else { return nil }
            return UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3])
        }
        func le32(_ o: Int) -> UInt32? {
            guard o + 4 <= bytes.count else { return nil }
            return UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        guard let magicBE = be32(0) else { return nil }
        switch magicBE {
        case 0xCAFE_BABE, 0xCAFE_BABF: // universal (fat); fields are big-endian
            guard let n = be32(4), n > 0, n < 32 else { return nil } // small n distinguishes from Java class files
            let entry = magicBE == 0xCAFE_BABF ? 32 : 20
            var out: [CPUArch] = []
            for i in 0..<Int(n) {
                let base = 8 + i * entry
                guard let type = be32(base), let sub = be32(base + 4) else { break }
                out.append(arch(type: type, subtype: sub & 0x00FF_FFFF))
            }
            return out.isEmpty ? nil : out
        default:
            guard let magicLE = le32(0) else { return nil }
            if magicLE == 0xFEED_FACF || magicLE == 0xFEED_FACE, let type = le32(4), let sub = le32(8) {
                return [arch(type: type, subtype: sub & 0x00FF_FFFF)]
            }
            return nil
        }
    }

    static func arch(type: UInt32, subtype: UInt32) -> CPUArch {
        switch type {
        case cpuTypeARM64: return subtype == cpuSubtypeARM64E ? .arm64e : .arm64
        case cpuTypeX86_64: return .x86_64
        case cpuTypeI386: return .i386
        default: return .other
        }
    }
}

// MARK: - Info.plist

public struct BundleInfo: Equatable, Sendable {
    public var name: String?
    public var bundleIdentifier: String?
    public var executableName: String?
    public var version: String?
    public var build: String?
    public var minimumSystemVersion: String?
}

public enum BundleInfoReader {
    public static func read(plistData: Data) -> BundleInfo? {
        guard let dict = (try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)) as? [String: Any]
        else { return nil }
        return BundleInfo(
            name: dict["CFBundleDisplayName"] as? String ?? dict["CFBundleName"] as? String,
            bundleIdentifier: dict["CFBundleIdentifier"] as? String,
            executableName: dict["CFBundleExecutable"] as? String,
            version: dict["CFBundleShortVersionString"] as? String,
            build: dict["CFBundleVersion"] as? String,
            minimumSystemVersion: dict["LSMinimumSystemVersion"] as? String)
    }
}

/// Compares dotted version strings ("14.2" vs "14.10").
public enum VersionCompare {
    public static func isLower(_ a: String, than b: String) -> Bool {
        let pa = components(a), pb = components(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// Extracts "15.6.1" from "macOS 15.6.1 (24G90)" or "Version 15.6.1 (Build 24G90)".
    public static func numeric(_ s: String) -> String? {
        guard let r = s.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) else { return nil }
        return String(s[r])
    }

    static func components(_ s: String) -> [Int] {
        (numeric(s) ?? s).split(separator: ".").map { Int($0) ?? 0 }
    }
}

// MARK: - Unified log (`log show --style ndjson`)

public enum UnifiedLogParser {
    /// Parses NDJSON lines, keeping only errors and faults, redacting and truncating messages.
    public static func parse(ndjson: String, redactor: Redactor, limit: Int = 25) -> [LogEntrySummary] {
        var out: [LogEntrySummary] = []
        for line in ndjson.split(separator: "\n") where line.first == "{" {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let level = (obj["messageType"] as? String) ?? ""
            guard ["error", "fault"].contains(level.lowercased()) else { continue }
            let message = (obj["eventMessage"] as? String) ?? ""
            let clean = redactor(String(message.prefix(400)))
            out.append(LogEntrySummary(date: (obj["timestamp"] as? String).flatMap(DiagnosticReportParser.parseDate),
                                       level: level.capitalized, subsystem: obj["subsystem"] as? String,
                                       message: String(clean.prefix(300))))
            if out.count >= limit { break }
        }
        return out
    }

    /// Process names safe to embed in a `log` predicate. Anything else is refused.
    public static func isSafePredicateValue(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.range(of: #"^[A-Za-z0-9 ._+-]+$"#, options: .regularExpression) != nil
    }
}

// MARK: - diskutil

public enum DiskutilInfoParser {
    public struct Info: Equatable, Sendable {
        public var smartStatus: String?
        public var isSolidState: Bool?
        public var isInternal: Bool?
    }

    public static func parse(plistData: Data) -> Info? {
        guard let dict = (try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)) as? [String: Any]
        else { return nil }
        return Info(smartStatus: dict["SMARTStatus"] as? String,
                    isSolidState: dict["SolidState"] as? Bool,
                    isInternal: dict["Internal"] as? Bool)
    }
}
