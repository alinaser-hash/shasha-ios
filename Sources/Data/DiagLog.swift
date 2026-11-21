import Foundation
#if VLC4
import VLCKit
#else
import MobileVLCKit
#endif

/// Keeps the VLC log of the current playback in memory for "Copy playback diagnostics". Nothing is written to disk or sent.
/// - Default: errors and warnings. "Detailed" adds debug lines, but only those about decoders, subtitles and video output
///   (module choice, libass/freetype/subsdec, vout), so the useful lines are not pushed out by noise.
/// - Repeated messages are folded into one line with a count.
/// - Cleared when a new item starts, so the report belongs to what is on screen.
#if VLC4
typealias DiagLevel = VLCLogLevel
#else
/// VLCKit 3 build: no log hook is used; the type exists so the rest of the code is the same.
enum DiagLevel: Int { case error, warning, info, debug }
#endif

final class DiagLog: NSObject {
    static let shared = DiagLog()
    var level: DiagLevel = .warning
    private let lock = NSLock()
    /// First lines of the playback (module choices, decoders, output) — never pushed out.
    private var head: [String] = []
    /// Latest lines.
    private var tail: [String] = []
    /// Very frequent messages are counted instead of stored after their first few occurrences.
    private var counts: [String: Int] = [:]
    private let headMax = 220, tailMax = 160, keepFirst = 3
    private static let noisy: [(key: String, match: String)] = [
        ("clock gap / new clock context", "clock gap"), ("clock gap / new clock context", "feeding synchro"),
        ("clock gap / new clock context", "clock context"), ("picture too late", "picture is too late"),
        ("picture displayed late", "picture displayed late"), ("deferring start", "deferring start"), ("buffering %", "Buffering ")]
    private static let interesting = try! NSRegularExpression(
        pattern: "(sub|spu|libass|freetype|font|decoder|codec|vout|display|module|ssa|render|osd|blend|filter|placebo|pl_scale|dovi|dolby|opengl|gles|hdr|videotoolbox|avcodec|demux|mkv|matroska|clock|pcr|es_out|track)",
        options: [.caseInsensitive])

    func beginSession(_ title: String) {
        lock.lock(); head.removeAll(); tail.removeAll(); counts.removeAll(); lock.unlock()
    }

    func record(_ message: String, level: DiagLevel, module: String, objectType: String) {
        if level == .debug || level == .info {
            let probe = module + " " + objectType + " " + message
            guard Self.interesting.firstMatch(in: probe, range: NSRange(probe.startIndex..., in: probe)) != nil else { return }
        }
        let tag: String
        switch level {
        case .error: tag = "E"
        case .warning: tag = "W"
        case .info: tag = "I"
        default: tag = "D"
        }
        lock.lock(); defer { lock.unlock() }
        if let n = Self.noisy.first(where: { message.contains($0.match) }) {
            let c = (counts[n.key] ?? 0) + 1
            counts[n.key] = c
            if c > keepFirst * 5 { return }      // the clock family logs 5 lines per event
        }
        let line = "[\(tag)] \(module)\(objectType.isEmpty ? "" : "/" + objectType): \(message)"
        if head.count < headMax { head.append(line); return }
        tail.append(line)
        if tail.count > tailMax { tail.removeFirst(tail.count - tailMax) }
    }

    /// Start of the playback, a count of the frequent messages, then the latest lines.
    func report() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var out = ["[بداية التشغيل]"] + head
        if !counts.isEmpty {
            out.append("[رسائل متكررة — العدد الكلي منذ بداية التشغيل]")
            for (k, v) in counts.sorted(by: { $0.key < $1.key }) { out.append("  \(k): \(v)") }
        }
        if !tail.isEmpty { out.append("[آخر الأسطر]"); out += tail }
        return out
    }
}

#if VLC4
extension DiagLog: VLCLogging {
    func handleMessage(_ message: String, logLevel level: VLCLogLevel, context: VLCLogContext?) {
        record(message, level: level, module: context?.module ?? "?", objectType: context?.objectType ?? "")
    }
}
#endif
