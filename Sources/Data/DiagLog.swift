import Foundation
import VLCKit

/// Keeps the VLC log of the current playback in memory for "Copy playback diagnostics". Nothing is written to disk or sent.
/// - Default: errors and warnings. "Detailed" adds debug lines, but only those about decoders, subtitles and video output
///   (module choice, libass/freetype/subsdec, vout), so the useful lines are not pushed out by noise.
/// - Repeated messages are folded into one line with a count.
/// - Cleared when a new item starts, so the report belongs to what is on screen.
final class DiagLog: NSObject, VLCLogging {
    static let shared = DiagLog()
    var level: VLCLogLevel = .warning
    private let lock = NSLock()
    private var lines: [String] = []
    private var lastKey = ""
    private var repeats = 0
    private var session = ""
    private let maxLines = 400
    private static let interesting = try! NSRegularExpression(
        pattern: "(sub|spu|ass|freetype|text|font|decoder|codec|vout|display|module|libass|ssa|render|osd|blend)", options: [.caseInsensitive])

    func beginSession(_ title: String) {
        lock.lock(); lines.removeAll(); lastKey = ""; repeats = 0; session = title; lock.unlock()
    }

    func handleMessage(_ message: String, logLevel level: VLCLogLevel, context: VLCLogContext?) {
        let module = context?.module ?? "?"
        let objectType = context?.objectType ?? ""
        if level == .debug || level == .info {
            let probe = module + " " + objectType + " " + message
            let r = NSRange(probe.startIndex..., in: probe)
            guard Self.interesting.firstMatch(in: probe, range: r) != nil else { return }
        }
        let tag: String
        switch level {
        case .error: tag = "E"
        case .warning: tag = "W"
        case .info: tag = "I"
        default: tag = "D"
        }
        // Fold repeats: same module + same text once digits are ignored.
        let key = module + "|" + message.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
        lock.lock(); defer { lock.unlock() }
        if key == lastKey, !lines.isEmpty {
            repeats += 1
            let base = lines[lines.count - 1].components(separatedBy: "  (×").first ?? lines[lines.count - 1]
            lines[lines.count - 1] = base + "  (×\(repeats + 1))"
            return
        }
        lastKey = key; repeats = 0
        lines.append("[\(tag)] \(module)\(objectType.isEmpty ? "" : "/" + objectType): \(message)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    func recent(_ n: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(lines.suffix(n))
    }
}
