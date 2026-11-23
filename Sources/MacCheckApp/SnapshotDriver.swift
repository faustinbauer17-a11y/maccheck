#if os(macOS)
import AppKit
import SwiftUI
import MacCheckCore

/// `MacCheck --ui-snapshot <dir>`: walks through the main screens using SAMPLE data and saves a PNG of
/// MacCheck's own window for each, then quits. Used by CI to produce real renders of the UI.
/// It captures only its own windows (no Screen Recording permission), uses no network and saves no history.
@MainActor
enum SnapshotDriver {
    static func run(_ model: AppModel, into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await pause(1.0)
        if let window = mainWindow() {
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.center()
        }
        var log: [String] = []
        func shot(_ name: String) async {
            await pause(0.8)
            log.append(capture(mainWindow(), to: dir.appendingPathComponent("\(name).png")))
        }

        model.selection = .dashboard
        await waitUntil(15) { model.live != nil && !model.liveLoading }
        await shot("01-home")

        model.runFullDiagnostic()
        await pause(0.6)
        await shot("02-check-computer-running")
        await waitUntil(20) { model.scanState == .finished || model.scanState == .cancelled }
        await shot("03-check-computer-result")

        for area in [DiagnosticArea.battery, .thermals, .storage] {
            model.selection = .area(area)
            await shot("04-test-\(area.rawValue)")
        }

        model.selection = .appDoctor
        model.loadApps()
        await waitUntil(10) { !model.apps.isEmpty }
        model.selectedAppPath = model.apps.first { $0.name == "Notes Pro" }?.path ?? model.apps.first?.path
        model.symptom = .crashes
        await shot("06-app-doctor-choose")
        model.investigate()
        await waitUntil(30) { model.doctorPhase == .result || { if case .failed = model.doctorPhase { return true }; return false }() }
        await shot("07-app-doctor-result")

        model.selection = .settings
        await shot("08-tools-settings")
        model.selection = .reports
        await shot("09-reports-latest")

        if let report = model.latestReport {
            model.beginExport(report)
            await pause(1.2)
            let sheet = NSApp.windows.first { $0.isSheet && $0.isVisible }
            log.append(capture(sheet, to: dir.appendingPathComponent("10-export-review.png")))
            model.exportDraft = nil
        }

        try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("snapshot-log.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && !$0.isSheet && $0.contentView != nil && $0.frame.width > 400 }
    }

    /// Renders the window's own view hierarchy (frame view, so the title bar and sidebar are included).
    static func capture(_ window: NSWindow?, to url: URL) -> String {
        guard let window, let view = window.contentView?.superview ?? window.contentView else {
            return "\(url.lastPathComponent): no window"
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return "\(url.lastPathComponent): no bitmap"
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return "\(url.lastPathComponent): no png" }
        do {
            try png.write(to: url)
            return "\(url.lastPathComponent): \(rep.pixelsWide)x\(rep.pixelsHigh)"
        } catch {
            return "\(url.lastPathComponent): \(error)"
        }
    }

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { await pause(0.2) }
    }
}
#endif
