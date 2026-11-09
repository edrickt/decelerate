import Foundation

/// Lightweight diagnostics for development and QA runs.
///
/// Enabled by launching with `DECELERATE_DEBUG=1` in the environment; goes to
/// stderr so it never shows up in Console for normal users.
enum DebugLog {
    static func write(_ message: String) {
        guard ProcessInfo.processInfo.environment["DECELERATE_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data("[Decelerate] \(message)\n".utf8))
    }
}
