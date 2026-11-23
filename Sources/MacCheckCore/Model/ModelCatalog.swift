import Foundation

/// Small, explicit table of Apple Silicon Mac model identifiers MacCheck knows about.
/// Unknown identifiers are handled gracefully ("Mac (Mac17,3)", fan presence unknown);
/// nothing elsewhere depends on a model being listed here.
public enum ModelCatalog {
    public struct Entry: Sendable, Equatable {
        public var name: String
        /// MacBook Air models have no fan. `nil` = not known to MacCheck.
        public var isFanless: Bool?
        /// Battery cycle rating Apple publishes for the family, when known.
        public var ratedCycles: Int?
    }

    static let table: [String: Entry] = [
        // MacBook Air — fanless
        "MacBookAir10,1": Entry(name: "MacBook Air (M1, 2020)", isFanless: true, ratedCycles: 1000),
        "Mac14,2": Entry(name: "MacBook Air (13-inch, M2, 2022)", isFanless: true, ratedCycles: 1000),
        "Mac14,15": Entry(name: "MacBook Air (15-inch, M2, 2023)", isFanless: true, ratedCycles: 1000),
        "Mac15,12": Entry(name: "MacBook Air (13-inch, M3, 2024)", isFanless: true, ratedCycles: 1000),
        "Mac15,13": Entry(name: "MacBook Air (15-inch, M3, 2024)", isFanless: true, ratedCycles: 1000),
        "Mac16,12": Entry(name: "MacBook Air (13-inch, M4, 2025)", isFanless: true, ratedCycles: 1000),
        "Mac16,13": Entry(name: "MacBook Air (15-inch, M4, 2025)", isFanless: true, ratedCycles: 1000),
    ]

    public static func entry(for identifier: String?) -> Entry? {
        guard let id = identifier else { return nil }
        if let known = table[id] { return known }
        // Older Intel-era identifiers still say what they are.
        if id.hasPrefix("MacBookAir") { return Entry(name: "MacBook Air (\(id))", isFanless: nil, ratedCycles: 1000) }
        if id.hasPrefix("MacBookPro") { return Entry(name: "MacBook Pro (\(id))", isFanless: false, ratedCycles: 1000) }
        return nil
    }

    public static func displayName(for identifier: String?) -> String {
        guard let id = identifier else { return "Mac" }
        return entry(for: id)?.name ?? "Mac (\(id))"
    }

    public static func isFanless(_ identifier: String?) -> Bool? { entry(for: identifier)?.isFanless }
}

/// Formatting helpers that behave the same on every platform (no locale surprises in tests).
public enum Fmt {
    public static func bytes(_ value: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return "\(value) bytes" }
        // Avoid `%@` with Swift strings: it is not portable to non-Darwin Foundation.
        return (v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)) + " " + units[i]
    }

    /// Memory is conventionally shown in binary units ("16 GB" for 17,179,869,184 bytes).
    public static func memory(_ value: Int64) -> String {
        let gib = Double(value) / 1_073_741_824
        return gib >= 1 ? String(format: "%.0f GB", gib.rounded()) : String(format: "%.0f MB", Double(value) / 1_048_576)
    }

    public static func percent(_ value: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", value)
    }

    public static func ms(_ value: Double) -> String { String(format: "%.0f ms", value) }

    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d) d \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
        return "\(m) min"
    }

    public static func isoDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

/// Plain-language System Settings destinations. Deep links are best effort; the `path` text is always shown.
public enum SettingsLinks {
    private static let privacy = "x-apple.systempreferences:com.apple.preference.security?"

    public static let battery = SystemSettingsLink(title: "Open Battery settings", path: "System Settings → Battery",
                                             url: "x-apple.systempreferences:com.apple.preference.battery")
    public static let storage = SystemSettingsLink(title: "Open Storage settings", path: "System Settings → General → Storage",
                                             url: "x-apple.systempreferences:com.apple.settings.Storage")
    public static let softwareUpdate = SystemSettingsLink(title: "Open Software Update", path: "System Settings → General → Software Update",
                                                    url: "x-apple.systempreferences:com.apple.preferences.softwareupdate")
    public static let network = SystemSettingsLink(title: "Open Network settings", path: "System Settings → Network",
                                             url: "x-apple.systempreferences:com.apple.preference.network")
    public static let loginItems = SystemSettingsLink(title: "Open Login Items", path: "System Settings → General → Login Items & Extensions",
                                                url: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    public static let privacySecurity = SystemSettingsLink(title: "Open Privacy & Security", path: "System Settings → Privacy & Security",
                                                     url: "x-apple.systempreferences:com.apple.preference.security")
    public static let activityMonitor = SystemSettingsLink(title: "Open Activity Monitor", path: "Applications → Utilities → Activity Monitor",
                                                     url: "bundle:com.apple.ActivityMonitor")
    public static let aboutThisMac = SystemSettingsLink(title: "About This Mac", path: "System Settings → General → About",
                                                  url: "x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension")
    public static let console = SystemSettingsLink(title: "Open Console", path: "Applications → Utilities → Console",
                                             url: "bundle:com.apple.Console")

    public static func privacy(_ pane: PrivacyPane) -> SystemSettingsLink {
        SystemSettingsLink(title: "Open \(pane.title) settings", path: "System Settings → Privacy & Security → \(pane.title)",
                     url: privacy + pane.anchor)
    }

    public enum PrivacyPane: String, CaseIterable, Sendable {
        case camera, microphone, screenRecording, accessibility, filesAndFolders, fullDiskAccess, automation, localNetwork, inputMonitoring

        public var title: String {
            switch self {
            case .camera: return "Camera"
            case .microphone: return "Microphone"
            case .screenRecording: return "Screen & System Audio Recording"
            case .accessibility: return "Accessibility"
            case .filesAndFolders: return "Files & Folders"
            case .fullDiskAccess: return "Full Disk Access"
            case .automation: return "Automation"
            case .localNetwork: return "Local Network"
            case .inputMonitoring: return "Input Monitoring"
            }
        }

        var anchor: String {
            switch self {
            case .camera: return "Privacy_Camera"
            case .microphone: return "Privacy_Microphone"
            case .screenRecording: return "Privacy_ScreenCapture"
            case .accessibility: return "Privacy_Accessibility"
            case .filesAndFolders: return "Privacy_FilesAndFolders"
            case .fullDiskAccess: return "Privacy_AllFiles"
            case .automation: return "Privacy_Automation"
            case .localNetwork: return "Privacy_LocalNetwork"
            case .inputMonitoring: return "Privacy_ListenEvent"
            }
        }

        /// What a missing grant typically looks like to the user.
        public var symptom: String {
            switch self {
            case .camera: return "camera shows black or 'no camera found' inside the app"
            case .microphone: return "others can't hear you, or recording is silent"
            case .screenRecording: return "screen sharing shows only the wallpaper or a black window"
            case .accessibility: return "shortcuts, window management or automation features silently do nothing"
            case .filesAndFolders: return "the app can't open or save in Desktop, Documents or Downloads"
            case .fullDiskAccess: return "backup or sync tools report missing files or 'operation not permitted'"
            case .automation: return "the app can't control another app (e.g. Mail, Finder)"
            case .localNetwork: return "the app can't find printers, speakers or devices on your network"
            case .inputMonitoring: return "keyboard shortcuts or input tools don't react"
            }
        }
    }
}
