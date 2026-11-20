import SwiftUI
import UIKit
import MobileVLCKit
import MediaPlayer

/// What to play: a live channel inside its list (◀▶ switch channels) or a film/episode with a resume key.
enum PlayItem: Identifiable {
    case live(list: [Channel], index: Int)
    case vod(VodPlay)

    var id: String {
        switch self {
        case .live(let l, let i): return "live:" + l[i].id
        case .vod(let v): return "vod:" + v.key
        }
    }
}

/// A film or an episode. `next` holds the following episodes of the same series (empty for films).
struct VodPlay: Hashable {
    let title: String
    let url: String
    let key: String
    var query: SubQuery
    var next: [VodPlay] = []
}

/// VLCKit player state, polled twice a second (simple and robust across VLCKit versions).
final class PlayerModel: ObservableObject {
    let player = VLCMediaPlayer()
    @Published var timeMs: Int32 = 0
    @Published var lengthMs: Int32 = 0
    @Published var playing = false
    @Published var buffering = true
    /// The stream stopped by itself (server dropped it or it never opened).
    @Published var failed = false
    @Published var rate: Float = 1
    private var timer: Timer?
    private var live = false

    func open(_ url: String, startSeconds: Double = 0, live: Bool = false) {
        guard let u = URL(string: url) else { return }
        self.live = live
        failed = false
        subDelay = 0
        let m = VLCMedia(url: u)
        m.addOption(":network-caching=1500")
        if startSeconds > 5 { m.addOption(":start-time=\(Int(startSeconds))") }
        player.media = m
        player.play()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        // Written so it compiles whether VLCKit imports these as optional or not.
        timeMs = (player.time as VLCTime?)?.intValue ?? 0
        lengthMs = (player.media as VLCMedia?)?.length.intValue ?? 0
        playing = player.isPlaying
        buffering = player.state == .buffering || player.state == .opening
        if player.state == .error || (live && player.state == .ended) { failed = true; buffering = false }
    }

    func setRate(_ r: Float) { player.rate = r; rate = r }

    /// Subtitle delay in seconds (VLC stores microseconds). Positive = later.
    @Published var subDelay: Double = 0
    func shiftSubs(_ d: Double) {
        subDelay = d == 0 ? 0 : (subDelay + d)
        player.currentVideoSubTitleDelay = Int(subDelay * 1_000_000)
    }

    /// Adds a downloaded subtitle file and switches to it.
    func addSubtitle(_ file: URL) {
        player.addPlaybackSlave(file, type: .subtitle, enforce: true)
    }

    // Lock screen / Control Center.
    private var remoteTargets: [Any] = []
    func nowPlaying(_ title: String) {
        var info: [String: Any] = [MPMediaItemPropertyTitle: title]
        if lengthMs > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(lengthMs) / 1000
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(timeMs) / 1000
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? Double(rate) : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        guard remoteTargets.isEmpty else { return }
        let c = MPRemoteCommandCenter.shared()
        remoteTargets = [
            c.playCommand.addTarget { [weak self] _ in self?.player.play(); return .success },
            c.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success },
            c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success },
        ]
    }
    private func clearRemote() {
        let c = MPRemoteCommandCenter.shared()
        for t in remoteTargets { c.playCommand.removeTarget(t); c.pauseCommand.removeTarget(t); c.togglePlayPauseCommand.removeTarget(t) }
        remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    enum Fit: String, CaseIterable { case fit = "ملاءمة", fill = "ملء الشاشة", wide = "16:9", classic = "4:3" }

    /// Picture shape. VLC copies the strings it is given.
    func apply(_ f: Fit) {
        player.videoAspectRatio = nil
        player.videoCropGeometry = nil
        switch f {
        case .fit: break
        case .fill:
            let b = UIScreen.main.bounds
            player.videoCropGeometry = strdup("\(Int(max(b.width, b.height))):\(Int(min(b.width, b.height)))")
        case .wide: player.videoAspectRatio = strdup("16:9")
        case .classic: player.videoAspectRatio = strdup("4:3")
        }
    }

    func toggle() { player.isPlaying ? player.pause() : player.play() }
    func jump(_ seconds: Int32) { seconds > 0 ? player.jumpForward(seconds) : player.jumpBackward(-seconds) }
    func seek(fraction: Double) { player.position = Float(max(0, min(1, fraction))) }

    func stop() { timer?.invalidate(); timer = nil; player.stop(); clearRemote() }

    struct Track: Identifiable { let id: Int32; let name: String }

    var audioTracks: [Track] { tracks(player.audioTrackIndexes as [Any]?, player.audioTrackNames as [Any]?) }
    var subtitleTracks: [Track] { tracks(player.videoSubTitlesIndexes as [Any]?, player.videoSubTitlesNames as [Any]?) }

    private func tracks(_ ids: [Any]?, _ names: [Any]?) -> [Track] {
        let i = (ids ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        let n = (names ?? []).map { "\($0)" }
        return zip(i, n).map { Track(id: $0, name: $1) }
    }
}

/// UIView that VLC draws into.
struct VLCView: UIViewRepresentable {
    let model: PlayerModel
    func makeUIView(context: Context) -> UIView {
        let v = UIView(); v.backgroundColor = .black
        model.player.drawable = v
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct PlayerScreen: View {
    let item: PlayItem
    @EnvironmentObject var library: Library
    @EnvironmentObject var epg: EPG
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PlayerModel()
    @State private var controls = true
    @State private var index = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var fit: PlayerModel.Fit = .fit
    @State private var flash: Int32 = 0
    /// The film/episode now playing (moves forward with "next episode").
    @State private var vod: VodPlay?
    @State private var subsSheet = false
    @State private var notice: String?
    @State private var advancedAt = Date.distantPast

    private var title: String {
        switch item {
        case .live(let l, _): return l[index].name
        case .vod(let v): return vod?.title ?? v.title
        }
    }
    private var isLive: Bool { if case .live = item { return true } else { return false } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCView(model: model).ignoresSafeArea()
            // Tap: show/hide controls. Double tap on the left/right half: −10 / +10 s (films and episodes).
            HStack(spacing: 0) { tapZone(-10); tapZone(10) }
                .environment(\.layoutDirection, .leftToRight)
                .ignoresSafeArea()
            if model.buffering && !model.failed { ProgressView().tint(.white).scaleEffect(1.6) }
            if flash != 0 {
                Label(flash > 0 ? "+10" : "−10", systemImage: flash > 0 ? "goforward.10" : "gobackward.10")
                    .font(.title2.bold()).padding(14).background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: flash > 0 ? .trailing : .leading).padding(.horizontal, 60)
                    .environment(\.layoutDirection, .leftToRight)
                    .allowsHitTesting(false)
            }
            if controls { overlay }
            if let n = nextUp, nearEnd, !model.failed {
                Button { playNext() } label: {
                    Label("الحلقة التالية", systemImage: "forward.end.fill").font(.headline).padding(.horizontal, 18).padding(.vertical, 12)
                        .background(Theme.accent, in: Capsule()).foregroundStyle(.black)
                }
                .accessibilityHint(n.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(28)
                .environment(\.layoutDirection, .leftToRight)
            }
            if let notice {
                Text(notice).font(.callout).padding(12).background(.black.opacity(0.75), in: Capsule()).foregroundStyle(.white)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 70).allowsHitTesting(false)
            }
            if model.failed {
                VStack(spacing: 12) {
                    Text(isLive ? "انقطع البث." : "تعذّر تشغيل الملف.").font(.headline)
                    HStack {
                        Button("إعادة المحاولة") { retry() }.buttonStyle(.borderedProminent)
                        Button("إغلاق") { dismiss() }.buttonStyle(.bordered)
                    }
                }
                .padding(20).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.white)
            }
        }
        .sheet(isPresented: $subsSheet) {
            if let v = vod {
                SubSearchSheet(query: v.query) { file in model.addSubtitle(file); show("تمت إضافة الترجمة") }
            }
        }
        .onReceive(model.$timeMs) { _ in
            if !isLive { model.nowPlaying(title) }
            if !isLive, model.player.state == .ended, nextUp != nil, !model.failed, Date().timeIntervalSince(advancedAt) > 5 { playNext() }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { start(); Orientation.landscape(); UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { saveResume(); model.stop(); Orientation.portrait(); UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func tapZone(_ seconds: Int32) -> some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !isLive else { return }
                model.jump(seconds); flash = seconds
                Task { try? await Task.sleep(nanoseconds: 700_000_000); await MainActor.run { flash = 0 } }
            }
            .onTapGesture { controls.toggle(); scheduleHide() }
    }

    private var nowOnAir: EPGNow? {
        guard case .live(let l, _) = item, l.indices.contains(index) else { return nil }
        return epg.now[l[index].id]
    }

    private var overlay: some View {
        VStack {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.title2.bold()).padding(12) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    if let n = nowOnAir {
                        Text(n.next.map { "الآن: \(n.title) · التالي: \($0)" } ?? "الآن: \(n.title)").font(.caption).lineLimit(1).opacity(0.85)
                    }
                }
                Spacer()
                pictureMenu
                trackMenu
            }
            .padding(.horizontal).background(.black.opacity(0.45))
            Spacer()
            HStack(spacing: 44) {
                if isLive {
                    Button { change(-1) } label: { Image(systemName: "chevron.up.circle.fill").font(.system(size: 40)) }
                } else {
                    Button { model.jump(-10) } label: { Image(systemName: "gobackward.10").font(.system(size: 36)) }
                }
                Button { model.toggle() } label: { Image(systemName: model.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64)) }
                if isLive {
                    Button { change(1) } label: { Image(systemName: "chevron.down.circle.fill").font(.system(size: 40)) }
                } else {
                    Button { model.jump(10) } label: { Image(systemName: "goforward.10").font(.system(size: 36)) }
                }
            }
            .environment(\.layoutDirection, .leftToRight)
            Spacer()
            if !isLive && model.lengthMs > 0 {
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { Double(model.timeMs) / Double(max(model.lengthMs, 1)) },
                                          set: { model.seek(fraction: $0); scheduleHide() }))
                    HStack { Text(fmt(model.timeMs)); Spacer(); Text(fmt(model.lengthMs)) }.font(.caption.monospacedDigit())
                }
                .environment(\.layoutDirection, .leftToRight)
                .padding().background(.black.opacity(0.45))
            }
        }
        .foregroundStyle(.white)
    }

    private var pictureMenu: some View {
        Menu {
            Section("شكل الصورة") {
                ForEach(PlayerModel.Fit.allCases, id: \.self) { f in
                    Button { fit = f; model.apply(f) } label: { if fit == f { Label(f.rawValue, systemImage: "checkmark") } else { Text(f.rawValue) } }
                }
            }
            if !isLive {
                Section("السرعة") {
                    ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { r in
                        Button { model.setRate(r) } label: {
                            let t = r == 1 ? "عادية" : String(format: "%gx", r)
                            if model.rate == r { Label(t, systemImage: "checkmark") } else { Text(t) }
                        }
                    }
                }
            }
        } label: { Image(systemName: "aspectratio").font(.title2).padding(12) }
    }

    private var trackMenu: some View {
        Menu {
            Section("الصوت") {
                ForEach(model.audioTracks) { t in Button(t.name) { model.player.currentAudioTrackIndex = t.id } }
            }
            Section("الترجمة") {
                ForEach(model.subtitleTracks) { t in
                    Button { model.player.currentVideoSubTitleIndex = t.id } label: {
                        if model.player.currentVideoSubTitleIndex == t.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                    }
                }
                if !isLive {
                    Button { subsSheet = true } label: { Label("ترجمة من الإنترنت…", systemImage: "globe") }
                }
            }
            Section("توقيت الترجمة: \(model.subDelay == 0 ? "بدون تعديل" : String(format: "%+.1f ث", model.subDelay))") {
                Button { model.shiftSubs(-0.5); show(delayText) } label: { Label("أبكر ٠٫٥ ث", systemImage: "minus.circle") }
                Button { model.shiftSubs(0.5); show(delayText) } label: { Label("أتأخر ٠٫٥ ث", systemImage: "plus.circle") }
                if model.subDelay != 0 { Button { model.shiftSubs(0); show(delayText) } label: { Label("إرجاع التوقيت", systemImage: "arrow.uturn.backward") } }
            }
        } label: { Image(systemName: "captions.bubble").font(.title2).padding(12) }
    }

    private func start() {
        switch item {
        case .live(let l, let i): index = i; model.open(l[i].url, live: true); epg.load(l[i], from: library.xtream)
        case .vod(let v): vod = v; model.open(v.url, startSeconds: Store.position(v.key)?.pos ?? 0)
        }
        scheduleHide()
    }

    private func change(_ d: Int) {
        guard case .live(let l, _) = item, !l.isEmpty else { return }
        index = (index + d + l.count) % l.count
        model.open(l[index].url, live: true)
        epg.load(l[index], from: library.xtream)
        scheduleHide()
    }

    /// One manual retry, started by the viewer (no automatic reconnect loop).
    private func retry() {
        switch item {
        case .live(let l, _): model.open(l[index].url, live: true)
        case .vod: if let v = vod { model.open(v.url, startSeconds: Double(model.timeMs) / 1000) }
        }
        if fit != .fit { model.apply(fit) }
        scheduleHide()
    }

    private func saveResume() {
        guard let v = vod, model.lengthMs > 0 else { return }
        Store.setPosition(v.key, Double(model.timeMs) / 1000, Double(model.lengthMs) / 1000)
    }

    private var nextUp: VodPlay? { vod?.next.first }
    /// Last 40 seconds of an episode (or it already ended).
    private var nearEnd: Bool {
        model.player.state == .ended || (model.lengthMs > 60_000 && model.lengthMs - model.timeMs < 40_000)
    }

    /// Marks the current episode watched and starts the next one, keeping the rest of the queue.
    private func playNext() {
        guard let cur = vod, var n = cur.next.first else { return }
        advancedAt = Date()
        Store.setPosition(cur.key, 1, 1)
        n.next = Array(cur.next.dropFirst())
        vod = n
        model.open(n.url, startSeconds: Store.position(n.key)?.pos ?? 0)
        if fit != .fit { model.apply(fit) }
        show(n.title)
        scheduleHide()
    }

    private var delayText: String {
        model.subDelay == 0 ? "توقيت الترجمة الأصلي" : String(format: "تأخير الترجمة %+.1f ث", model.subDelay)
    }

    private func show(_ text: String) {
        notice = text
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); await MainActor.run { if notice == text { notice = nil } } }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard controls else { return }
        hideTask = Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if !Task.isCancelled { await MainActor.run { controls = false } } }
    }

    private func fmt(_ ms: Int32) -> String {
        let s = Int(ms) / 1000
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Landscape while playing (iOS 16 geometry API).
enum Orientation {
    static func landscape() { request(.landscape) }
    static func portrait() { request(.portrait) }
    private static func request(_ m: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: m)) { _ in }
    }
}
