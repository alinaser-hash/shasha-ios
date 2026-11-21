import UIKit
import Libmpv

// mpv as the main player's engine (stage 2). Unlike the stage 1 hand-off controller, the main thread never
// waits on mpv: every value the player needs is observed (mpv_observe_property) and cached on mpv's event queue,
// and every write is asynchronous. Only the diagnostics/track panels read properties directly, on demand.

/// View that holds mpv's Metal layer (Vulkan via MoltenVK).
final class MPVHostView: UIView {
    let metal = MPVMetalLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metal.contentsScale = UIScreen.main.nativeScale
        metal.framebufferOnly = true
        metal.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(metal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        metal.frame = bounds
        CATransaction.commit()
    }
}

final class MPVCore {
    let view = MPVHostView()
    private(set) var mpv: OpaquePointer?
    private let events = DispatchQueue(label: "app.shasha.mpv.core")
    private let lock = NSLock()

    /// Values cached from mpv's property-change events.
    struct State {
        var time: Double = 0
        var duration: Double = 0
        var paused = false
        var pausedForCache = false
        var seeking = false
        var eof = false
        var coreIdle = true
        var loaded = false
        var height = 0
        var trackJSON = ""
        var endError: String?
    }
    private var st = State()
    var state: State { lock.lock(); defer { lock.unlock() }; return st }
    private func update(_ f: (inout State) -> Void) { lock.lock(); f(&st); lock.unlock() }

    private var log: [String] = []
    func note(_ s: String) {
        lock.lock(); log.append(s); if log.count > 300 { log.removeFirst(log.count - 300) }; lock.unlock()
        MPVSessionFile.append(s)
    }
    func logLines() -> [String] { lock.lock(); defer { lock.unlock() }; return log }

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    deinit { destroy() }

    // The Metal surface is lost in the background (fix from MPVKit's demo): drop video, keep audio.
    @objc private func background() { if mpv != nil { setAsync("vid", "no") } }
    @objc private func foreground() { if mpv != nil { setAsync("vid", "auto") } }

    /// Creates the mpv instance once (options can only be set before mpv_initialize).
    private func create(lab: MPVLab) -> Bool {
        guard let h = mpv_create() else { note("mpv_create failed"); return false }
        mpv = h
        mpv_request_log_messages(h, "info")
        var layerPtr = view.metal
        mpv_set_option(h, "wid", MPV_FORMAT_INT64, &layerPtr)
        opt("vo", lab == .voGPU ? "gpu" : "gpu-next")
        opt("gpu-api", "vulkan")
        opt("gpu-context", "moltenvk")
        opt("hwdec", lab == .noHwdec ? "no" : lab == .copyHwdec ? "videotoolbox-copy" : "videotoolbox")
        opt("video-rotate", "no")
        opt("keep-open", "yes")             // stay on the last frame: the app decides (EndRule) what the end means
        opt("idle", "yes")
        opt("cache", "yes")
        opt("demuxer-max-bytes", "150MiB")
        opt("volume-max", "200")
        opt("audio-channels", "auto")       // was auto-safe (stereo): request the file's layout; the route decides
        opt("subs-fallback", "yes")
        opt("sub-font-size", "46")
        opt("sub-scale", String(format: "%.2f", MPVSubScale.value))
        if let dir = MPVFonts.directory() { opt("sub-fonts-dir", dir); opt("sub-font", "Noto Sans Arabic") }
        opt("network-timeout", "20")
        // No automatic reconnect loop of our own; FFmpeg's own short reconnect inside one request is left as is.
        let r = mpv_initialize(h)
        if r < 0 { note("API initialize: \(String(cString: mpv_error_string(r)))"); mpv_terminate_destroy(h); mpv = nil; return false }
        let observed: [(String, mpv_format)] = [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("pause", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG), ("seeking", MPV_FORMAT_FLAG), ("eof-reached", MPV_FORMAT_FLAG),
            ("core-idle", MPV_FORMAT_FLAG), ("height", MPV_FORMAT_INT64), ("track-list", MPV_FORMAT_STRING),
        ]
        for (i, o) in observed.enumerated() { mpv_observe_property(h, UInt64(i + 1), o.0, o.1) }
        mpv_set_wakeup_callback(h, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVCore>.fromOpaque(ctx).takeUnretainedValue().drain()
        }, Unmanaged.passUnretained(self).toOpaque())
        return true
    }
    private var createdLab: MPVLab?

    /// Opens a stream. `alang`/`slang` are mpv language lists ("ara,ar,arabic").
    func open(_ url: URL, start: Double, live: Bool, alang: String, slang: String, lab: MPVLab) {
        // A lab mode changes creation-time options, so a different mode needs a fresh instance.
        if mpv != nil, createdLab != lab { destroy() }
        MPVSessionFile.begin(secrets: MPVSessionFile.secrets(of: url))
        MPVMetalLayer.onEDR = { [weak self] in self?.note("[مرحلة] \($0)") }
        note("[مرحلة] فتح في المشغّل الرئيسي | البداية عند \(Int(start)) ث | \(live ? "بث مباشر" : "فيلم/حلقة") | وضع الاختبار: \(lab.rawValue)")
        if mpv == nil { guard create(lab: lab) else { update { $0.endError = "تعذّر تشغيل mpv" }; return }; createdLab = lab }
        update { $0 = State() }
        setAsync("alang", alang.isEmpty ? "" : alang)
        setAsync("slang", slang.isEmpty ? "ar,ara,arabic" : slang)
        setAsync("start", start > 5 ? String(format: "%.0f", start) : "none")
        setAsync("pause", "no")
        setAsync("vid", "auto")
        // Track choices, delay and picture shape set at runtime are options in mpv and would carry over to the
        // next file: back to the defaults for every open (the player re-applies the viewer's choices itself).
        setAsync("aid", "auto"); setAsync("sid", "auto")
        setAsync("sub-delay", "0"); setAsync("panscan", "0.0"); setAsync("video-aspect-override", "no")
        commandAsync(["loadfile", url.absoluteString, "replace"])
    }

    /// Stops playback and closes the connection (the instance stays for the next open).
    func stopPlayback() {
        guard mpv != nil else { return }
        commandAsync(["stop"])
        update { $0.loaded = false }
    }

    func destroy() {
        guard let h = mpv else { return }
        note("[مرحلة] إغلاق طبيعي")
        MPVMetalLayer.onEDR = nil
        mpv_set_wakeup_callback(h, nil, nil)
        events.sync { self.mpv = nil }       // never destroy while the event queue is inside mpv_wait_event
        mpv_terminate_destroy(h)
        createdLab = nil
    }

    // MARK: Writes (asynchronous: the main thread never waits for mpv)

    private func opt(_ name: String, _ value: String) {
        guard let h = mpv else { return }
        let r = mpv_set_option_string(h, name, value)
        if r < 0 { note("API option \(name): \(String(cString: mpv_error_string(r)))") }
    }
    func setAsync(_ name: String, _ value: String) {
        guard let h = mpv else { return }
        name.withCString { n in
            value.withCString { v in
                var p: UnsafePointer<CChar>? = v
                _ = mpv_set_property_async(h, 0, n, MPV_FORMAT_STRING, &p)
            }
        }
    }
    func commandAsync(_ args: [String]) {
        guard let h = mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { if let p = $0 { free(UnsafeMutablePointer(mutating: p)) } } }
        let r = mpv_command_async(h, 0, &cargs)
        if r < 0 { note("API \(args.first ?? "command"): \(String(cString: mpv_error_string(r)))") }
    }

    /// Direct read, for panels and diagnostics only.
    func string(_ name: String) -> String? {
        guard let h = mpv, let c = mpv_get_property_string(h, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    // MARK: Tracks

    struct Track { let id: String; let type: String; let name: String; let selected: Bool; let codec: String; let lang: String }

    var tracks: [Track] {
        guard let d = state.trackJSON.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return arr.compactMap { t in
            guard let type = t["type"] as? String, let idn = t["id"] as? Int else { return nil }
            let lang = t["lang"] as? String ?? ""
            let title = t["title"] as? String ?? ""
            let codec = t["codec"] as? String ?? "?"
            var parts: [String] = []
            if !title.isEmpty { parts.append(title) }
            if !lang.isEmpty { parts.append("[\(lang)]") }
            if type == "audio", let ch = t["demux-channel-count"] as? Int {
                parts.append(ch == 6 ? "5.1" : ch == 8 ? "7.1" : ch == 2 ? "ستيريو" : ch == 1 ? "أحادي" : "\(ch) قنوات")
            }
            var name = parts.isEmpty ? "مسار \(idn)" : parts.joined(separator: " ")
            if (t["forced"] as? Bool) == true { name += " · إجبارية" }
            if (t["external"] as? Bool) == true { name += " · خارجية" }
            return Track(id: String(idn), type: type, name: name + "  (\(codec))", selected: (t["selected"] as? Bool) == true,
                         codec: codec, lang: lang)
        }
    }

    // MARK: Events

    private func drain() {
        events.async { [weak self] in
            guard let self else { return }
            while let h = self.mpv, let e = mpv_wait_event(h, 0), e.pointee.event_id != MPV_EVENT_NONE {
                switch e.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let p = UnsafeMutablePointer<mpv_event_property>(OpaquePointer(e.pointee.data))?.pointee,
                          let cname = p.name else { break }
                    let name = String(cString: cname)
                    switch p.format {
                    case MPV_FORMAT_DOUBLE:
                        let v = p.data.assumingMemoryBound(to: Double.self).pointee
                        self.update { if name == "time-pos" { $0.time = v } else if name == "duration" { $0.duration = v } }
                    case MPV_FORMAT_FLAG:
                        let v = p.data.assumingMemoryBound(to: Int32.self).pointee != 0
                        self.update {
                            switch name {
                            case "pause": $0.paused = v
                            case "paused-for-cache": $0.pausedForCache = v
                            case "seeking": $0.seeking = v
                            case "eof-reached": $0.eof = v
                            case "core-idle": $0.coreIdle = v
                            default: break
                            }
                        }
                    case MPV_FORMAT_INT64:
                        let v = p.data.assumingMemoryBound(to: Int64.self).pointee
                        if name == "height" { self.update { $0.height = Int(v) } }
                    case MPV_FORMAT_STRING:
                        if let s = p.data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                            let v = String(cString: s)
                            if name == "track-list" { self.update { $0.trackJSON = v } }
                        }
                    case MPV_FORMAT_NONE:
                        // Property unavailable (nothing loaded): reset what depends on a file.
                        self.update {
                            if name == "time-pos" { $0.time = 0 } else if name == "duration" { $0.duration = 0 }
                            else if name == "height" { $0.height = 0 }
                        }
                    default: break
                    }
                case MPV_EVENT_LOG_MESSAGE:
                    if let m = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(e.pointee.data))?.pointee,
                       let p = m.prefix, let l = m.level, let t = m.text {
                        self.note("[\(String(cString: l))] \(String(cString: p)): \(String(cString: t).trimmingCharacters(in: .newlines))")
                    }
                case MPV_EVENT_START_FILE: self.note("[مرحلة] بدء الملف")
                case MPV_EVENT_FILE_LOADED: self.note("[مرحلة] الملف محمّل"); self.update { $0.loaded = true; $0.endError = nil }
                case MPV_EVENT_VIDEO_RECONFIG: self.note("[مرحلة] تهيئة مخرج الفيديو")
                case MPV_EVENT_PLAYBACK_RESTART: self.note("[مرحلة] بدأ العرض")
                case MPV_EVENT_END_FILE:
                    if let d = UnsafeMutablePointer<mpv_event_end_file>(OpaquePointer(e.pointee.data))?.pointee {
                        switch d.reason {
                        case MPV_END_FILE_REASON_ERROR:
                            let msg = String(cString: mpv_error_string(d.error))
                            self.note("end-file: error: \(msg)")
                            self.update { $0.endError = msg; $0.loaded = false }
                        case MPV_END_FILE_REASON_EOF:
                            self.note("end-file: eof")
                            self.update { $0.eof = true }
                        case MPV_END_FILE_REASON_STOP: self.note("end-file: stop")
                        default: self.note("end-file: other")
                        }
                    }
                case MPV_EVENT_SHUTDOWN:
                    return
                default: break
                }
            }
        }
    }
}
