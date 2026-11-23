#if os(macOS)
import Foundation
import IOKit
import MacCheckCore

/// Thin, read-only wrappers around documented system interfaces (sysctl, IORegistry).
enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func value<T: FixedWidthInteger>(_ name: String, as: T.Type = T.self) -> T? {
        var v = T.zero
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return v
    }

    static func int(_ name: String) -> Int? {
        // Most integer sysctls are 32-bit; a few (hw.memsize) are 64-bit. Ask for the size first.
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 8: return value(name, as: Int64.self).map(Int.init)
        case 4: return value(name, as: Int32.self).map(Int.init)
        default: return nil
        }
    }
}

enum IORegistry {
    /// All properties of the first service matching `className`, or nil.
    static func properties(ofClass className: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict
    }

    static func property(ofClass className: String, key: String) -> Any? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

extension DataSource {
    static func api(_ name: String) -> DataSource { DataSource(name, kind: .publicAPI) }
    static func ioreg(_ name: String) -> DataSource { DataSource(name, kind: .ioRegistry) }
    static func tool(_ name: String) -> DataSource { DataSource(name, kind: .systemTool) }
    static func files(_ name: String) -> DataSource { DataSource(name, kind: .fileSystem) }
}

/// Runs one of a fixed set of Apple command-line tools with fixed argument shapes,
/// a hard timeout and an output cap. Never runs a shell and never accepts free-form commands.
enum BoundedTool {
    enum Tool: String {
        case diskutil = "/usr/sbin/diskutil"
        case log = "/usr/bin/log"
    }

    struct Failure: Error, CustomStringConvertible { var description: String }

    static func run(_ tool: Tool, _ arguments: [String], timeout: TimeInterval, maxOutputBytes: Int = 2 * 1024 * 1024) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool.rawValue)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let collected = LockedData()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            collected.append(chunk, cap: maxOutputBytes)
        }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate() // our own child process only
            out.fileHandleForReading.readabilityHandler = nil
            throw Failure(description: "\(URL(fileURLWithPath: tool.rawValue).lastPathComponent) took longer than \(Int(timeout)) s")
        }
        out.fileHandleForReading.readabilityHandler = nil
        if let rest = try? out.fileHandleForReading.readToEnd() { collected.append(rest, cap: maxOutputBytes) }
        guard process.terminationStatus == 0 else {
            throw Failure(description: "\(URL(fileURLWithPath: tool.rawValue).lastPathComponent) exited with status \(process.terminationStatus)")
        }
        return collected.data
    }

    final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ d: Data, cap: Int) {
            lock.lock(); defer { lock.unlock() }
            guard buffer.count < cap else { return }
            buffer.append(d.prefix(cap - buffer.count))
        }
        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }
}
#endif
