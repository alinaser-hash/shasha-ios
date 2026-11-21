import Foundation
import VLCKit

/// Keeps the latest VLC log lines in memory for "Copy playback diagnostics". Nothing is written to disk or sent.
/// Default level: errors and warnings. "Detailed" (debug) is switched on from the diagnostics panel.
final class DiagLog: NSObject, VLCLogging {
    static let shared = DiagLog()
    var level: VLCLogLevel = .warning
    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 600

    func handleMessage(_ message: String, logLevel level: VLCLogLevel, context: VLCLogContext?) {
        let tag: String
        switch level {
        case .error: tag = "E"
        case .warning: tag = "W"
        case .info: tag = "I"
        default: tag = "D"
        }
        let module = context?.module ?? "?"
        let line = "[\(tag)] \(module): \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
    }

    func recent(_ n: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(lines.suffix(n))
    }

    func clear() { lock.lock(); lines.removeAll(); lock.unlock() }
}
