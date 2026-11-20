import SwiftUI
import UIKit
import MobileVLCKit
import MediaPlayer

/// What to play: a live channel inside its list (switch channels) or a film/episode inside its queue.
enum PlayItem: Identifiable {
    case live(list: [Channel], index: Int)
    case vod(list: [VodPlay], index: Int)

    var id: String {
        switch self {
        case .live(let l, let i): return "live:" + l[i].id
        case .vod(let l, let i): return "vod:" + l[i].key
        }
    }
}

/// A film, or one episode of a series (season/number set).
struct VodPlay: Hashable {
    let title: String
    let url: String
    let key: String
    var query: SubQuery
    var season: Int? = nil
    var number: Int? = nil
}

// MARK: - Engine

/// VLCKit player state, polled twice a second (simple and robust across VLCKit versions).
final class PlayerModel: ObservableObject {
    let player = VLCMediaPlayer()
    @Published var timeMs: Int32 = 0
    @Published var lengthMs: Int32 = 0
    @Published var playing = false
    /// Spinner: only when the picture is really not moving (VLC reports "buffering" all the time while playing).
    @Published var buffering = true
    /// The stream stopped by itself (server dropped it or it never opened).
    @Published var failed = false
    @Published var ended = false
    @Published var rate: Float = 1
    @Published var videoHeight: Int = 0
    @Published var subDelay: Double = 0
    private var timer: Timer?
    private var live = false
    private var lastTime: Int32 = -1
    private var stalledTicks = 0
    private var userPaused = false

    func open(_ url: String, startSeconds: Double = 0, live: Bool = false) {
        guard let u = URL(string: url) else { failed = true; return }
        self.live = live
        failed = false; ended = false; userPaused = false
        subDelay = 0; lastTime = -1; stalledTicks = 0; buffering = true; timeMs = 0; lengthMs = 0
        let m = VLCMedia(url: u)
        m.addOption(":network-caching=1500")
        if startSeconds > 5 { m.addOption(":start-time=\(Int(startSeconds))") }
        player.media = m
        player.play()
        if rate != 1 { player.rate = rate }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        // Written so it compiles whether VLCKit imports these as optional or not.
        let t = (player.time as VLCTime?)?.intValue ?? 0
        timeMs = t
        lengthMs = (player.media as VLCMedia?)?.length.intValue ?? 0
        playing = player.isPlaying
        let st = player.state
        stalledTicks = (t != lastTime) ? 0 : stalledTicks + 1
        lastTime = t
        if st == .error || (live && st == .ended) { failed = true }
        if !live && st == .ended { ended = true }
        buffering = !userPaused && !failed && !ended && st != .paused && st != .stopped && (st == .opening || stalledTicks >= 3)
        let h = Int(player.videoSize.height)
        if h > 0 && h != videoHeight { videoHeight = h }
    }

    var quality: String? {
        switch videoHeight {
        case 0: return nil
        case 1900...: return "4K"
        case 1000...: return "FHD"
        case 700...: return "HD"
        default: return "SD"
        }
    }

    func setRate(_ r: Float) { player.rate = r; rate = r }

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

    func toggle() {
        if player.isPlaying { player.pause(); userPaused = true } else { player.play(); userPaused = false }
        playing = !userPaused
    }
    func jump(_ seconds: Int32) { seek(toMs: Int32(max(0, Int(timeMs) + Int(seconds) * 1000))) }
    func seek(toMs ms: Int32) {
        let target = lengthMs > 0 ? min(ms, lengthMs - 1000) : ms
        player.time = VLCTime(int: max(0, target))
        timeMs = max(0, target); stalledTicks = 0
    }

    /// App volume 0…200 (100 = normal).
    var volume: Int32 {
        get { (player.audio as VLCAudio?)?.volume ?? 100 }
        set { if let a = player.audio as VLCAudio? { a.volume = max(0, min(200, newValue)) } }
    }

    func stop() { timer?.invalidate(); timer = nil; player.stop(); clearRemote() }

    /// Subtitle delay in seconds (VLC stores microseconds). Positive = later.
    func shiftSubs(_ d: Double) {
        subDelay = d == 0 ? 0 : (subDelay + d)
        player.currentVideoSubTitleDelay = Int(subDelay * 1_000_000)
    }

    /// Adds a downloaded subtitle file and switches to it.
    func addSubtitle(_ file: URL) { player.addPlaybackSlave(file, type: .subtitle, enforce: true) }

    struct Track: Identifiable { let id: Int32; let name: String }
    var audioTracks: [Track] { tracks(player.audioTrackIndexes as [Any]?, player.audioTrackNames as [Any]?) }
    var subtitleTracks: [Track] { tracks(player.videoSubTitlesIndexes as [Any]?, player.videoSubTitlesNames as [Any]?) }
    private func tracks(_ ids: [Any]?, _ names: [Any]?) -> [Track] {
        let i = (ids ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        let n = (names ?? []).map { "\($0)" }
        return zip(i, n).map { Track(id: $0, name: $1) }
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

// MARK: - Screen

struct PlayerScreen: View {
    let item: PlayItem
    @EnvironmentObject var library: Library
    @EnvironmentObject var epg: EPG
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PlayerModel()

    @State private var index = 0
    @State private var controls = true
    @State private var locked = false
    @State private var hideTask: Task<Void, Never>?
    @State private var fit: PlayerModel.Fit = .fit
    @State private var flash: String?
    @State private var flashIcon = ""
    @State private var notice: String?
    @State private var scrub: Double?          // 0…1 while dragging the bar or swiping
    @State private var gesture: GestureKind?
    @State private var gestureStart: Double = 0
    @State private var level: (icon: String, value: Double)?
    @State private var sheet: Sheet?
    @State private var resumeAt: Double?       // seconds; shows the "from the start" chip
    @State private var nextCountdown: Int?
    @State private var nextCancelled = false
    @State private var countdownTask: Task<Void, Never>?

    enum GestureKind { case seek, brightness, volume }
    enum Sheet: String, Identifiable { case subs, channels, episodes; var id: String { rawValue } }

    private var isLive: Bool { if case .live = item { return true } else { return false } }
    private var channels: [Channel] { if case .live(let l, _) = item { return l } else { return [] } }
    private var queue: [VodPlay] { if case .vod(let l, _) = item { return l } else { return [] } }
    private var current: VodPlay? { queue.indices.contains(index) ? queue[index] : nil }
    private var nextUp: VodPlay? { queue.indices.contains(index + 1) ? queue[index + 1] : nil }
    private var prevUp: VodPlay? { index > 0 && queue.indices.contains(index - 1) ? queue[index - 1] : nil }

    private var title: String {
        if isLive { return channels.indices.contains(index) ? channels[index].name : "" }
        return current?.title ?? ""
    }
    private var nowOnAir: EPGNow? {
        guard isLive, channels.indices.contains(index) else { return nil }
        return epg.now[channels[index].id]
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                VLCView(model: model).ignoresSafeArea()
                touchLayer(geo.size).ignoresSafeArea()

                if model.buffering { ProgressView().tint(.white).scaleEffect(1.5).allowsHitTesting(false) }
                if let flash { centerBadge(flash, flashIcon) }
                if let level { levelBar(level.icon, level.value) }
                if let s = scrub, !isLive, model.lengthMs > 0 { centerBadge(fmt(Int32(s * Double(model.lengthMs))) + " / " + fmt(model.lengthMs), "arrow.left.and.right") }

                if locked {
                    lockedOverlay
                } else if controls {
                    overlay(geo.size)
                }
                if let r = resumeAt, !locked { resumeChip(r) }
                if let n = nextUp, showNextCard, !locked { nextCard(n) }
                if let notice {
                    Text(notice).font(.callout).padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.black.opacity(0.75), in: Capsule()).foregroundStyle(.white)
                        .frame(maxHeight: .infinity, alignment: .top).padding(.top, 64).allowsHitTesting(false)
                }
                if model.failed { failedPanel }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(item: $sheet) { s in
            switch s {
            case .subs:
                if let v = current { SubSearchSheet(query: v.query) { file in model.addSubtitle(file); show("تمت إضافة الترجمة") } }
            case .channels:
                ChannelPickerSheet(channels: channels, current: index) { i in sheet = nil; switchChannel(to: i) }
                    .environmentObject(library).environmentObject(epg)
            case .episodes:
                EpisodePickerSheet(queue: queue, current: index) { i in sheet = nil; playEpisode(i, markWatched: false) }
            }
        }
        .onReceive(model.$timeMs) { _ in
            if !isLive { model.nowPlaying(title) }
            updateNextCard()
        }
        .onReceive(model.$ended) { e in
            guard e, !isLive else { return }
            if nextUp != nil && !nextCancelled { playEpisode(index + 1, markWatched: true) } else { saveResume(finished: true); dismiss() }
        }
        .onAppear { start(); Orientation.landscape(); UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { saveResume(); model.stop(); Orientation.portrait(); UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Touch: tap = controls, double tap sides = ±10 s, swipe sideways = seek, up/down = brightness (left) / volume (right)

    private func touchLayer(_ size: CGSize) -> some View {
        HStack(spacing: 0) { tapZone(-10); tapZone(10) }
            .environment(\.layoutDirection, .leftToRight)
            .simultaneousGesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { v in if !locked { dragChanged(v, size) } }
                    .onEnded { _ in if !locked { dragEnded() } }
            )
            .simultaneousGesture(MagnificationGesture().onEnded { s in
                guard !locked else { return }
                let f: PlayerModel.Fit = s > 1 ? .fill : .fit
                if f != fit { fit = f; model.apply(f); show(f.rawValue) }
            })
    }

    private func tapZone(_ seconds: Int32) -> some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !locked, !isLive else { return }
                model.jump(seconds)
                flashIcon = seconds > 0 ? "goforward.10" : "gobackward.10"
                flashText(seconds > 0 ? "+10 ث" : "−10 ث")
            }
            .onTapGesture {
                controls.toggle()
                scheduleHide()
            }
    }

    private func dragChanged(_ v: DragGesture.Value, _ size: CGSize) {
        if gesture == nil {
            if abs(v.translation.width) > abs(v.translation.height) {
                guard !isLive, model.lengthMs > 0 else { return }
                gesture = .seek; gestureStart = Double(model.timeMs) / Double(model.lengthMs)
            } else if v.startLocation.x < size.width / 2 {
                gesture = .brightness; gestureStart = Double(UIScreen.main.brightness)
            } else {
                gesture = .volume; gestureStart = Double(model.volume) / 200
            }
        }
        switch gesture {
        case .seek:
            // A full-width swipe moves 3 minutes (or the whole file if shorter).
            let span = min(180_000, Double(model.lengthMs)) / Double(max(model.lengthMs, 1))
            scrub = max(0, min(1, gestureStart + Double(v.translation.width / max(size.width, 1)) * span))
        case .brightness:
            let b = max(0, min(1, gestureStart - Double(v.translation.height / max(size.height, 1)) * 1.4))
            UIScreen.main.brightness = CGFloat(b); level = ("sun.max.fill", b)
        case .volume:
            let x = max(0, min(1, gestureStart - Double(v.translation.height / max(size.height, 1)) * 1.4))
            model.volume = Int32(x * 200); level = (x == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", x)
        case nil: break
        }
    }

    private func dragEnded() {
        if gesture == .seek, let s = scrub { model.seek(toMs: Int32(s * Double(model.lengthMs))) }
        gesture = nil; scrub = nil
        Task { try? await Task.sleep(nanoseconds: 600_000_000); await MainActor.run { level = nil } }
    }

    // MARK: Controls

    private func overlay(_ size: CGSize) -> some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            centerButtons
            Spacer()
            if isLive { liveBottom } else { vodBottom }
        }
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
        )
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            iconButton("chevron.down") { dismiss() }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                if let n = nowOnAir {
                    Text(n.next.map { "الآن: \(n.title) · التالي: \($0)" } ?? "الآن: \(n.title)").font(.caption).lineLimit(1).opacity(0.85)
                }
            }
            Spacer(minLength: 8)
            if let q = model.quality {
                Text(q).font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(.black)
            }
            iconButton("lock.open") { locked = true; controls = true; scheduleHide(); show("الشاشة مقفلة — اضغط القفل للفتح") }
            audioMenu
            subtitleMenu
            pictureMenu
        }
        .padding(.horizontal, 12).padding(.top, 6)
    }

    private var centerButtons: some View {
        HStack(spacing: 56) {
            if isLive {
                bigButton("backward.end.fill", 34) { switchChannel(to: index - 1) }
            } else {
                bigButton("gobackward.10", 38) { model.jump(-10); scheduleHide() }
            }
            Button { model.toggle(); scheduleHide() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.system(size: 40))
                    .frame(width: 84, height: 84).background(.white.opacity(0.18), in: Circle())
            }
            if isLive {
                bigButton("forward.end.fill", 34) { switchChannel(to: index + 1) }
            } else {
                bigButton("goforward.10", 38) { model.jump(10); scheduleHide() }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private var vodBottom: some View {
        VStack(spacing: 6) {
            if model.lengthMs > 0 {
                let shown = scrub ?? Double(model.timeMs) / Double(max(model.lengthMs, 1))
                HStack(spacing: 10) {
                    Text(fmt(Int32(shown * Double(model.lengthMs)))).font(.caption.monospacedDigit())
                    Slider(value: Binding(get: { shown }, set: { scrub = $0; scheduleHide() }), in: 0...1, onEditingChanged: { editing in
                        if !editing, let s = scrub { model.seek(toMs: Int32(s * Double(model.lengthMs))); scrub = nil }
                    })
                    .tint(Theme.accent)
                    Text("-" + fmt(max(0, model.lengthMs - Int32(shown * Double(model.lengthMs))))).font(.caption.monospacedDigit())
                }
                .environment(\.layoutDirection, .leftToRight)
            }
            HStack(spacing: 10) {
                if model.lengthMs > 0 {
                    Text("ينتهي \(endsAt)").font(.caption).opacity(0.85)
                }
                Spacer()
                speedMenu
                if !queue.isEmpty && current?.season != nil {
                    pill("الحلقات", "list.bullet") { sheet = .episodes }
                }
                if prevUp != nil { pill("السابقة", "backward.end") { playEpisode(index - 1, markWatched: false) } }
                if nextUp != nil { pill("التالية", "forward.end") { playEpisode(index + 1, markWatched: true) } }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private var liveBottom: some View {
        HStack(spacing: 12) {
            if let n = nowOnAir {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(timeText(n.start)) – \(timeText(n.end))  \(n.title)").font(.caption).lineLimit(1)
                    ProgressView(value: n.progress).tint(Theme.teal).frame(maxWidth: 260)
                }
            }
            Spacer()
            Text("\(index + 1) / \(channels.count)").font(.caption.monospacedDigit()).opacity(0.8)
            pill("القنوات", "list.bullet.rectangle") { sheet = .channels }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private var lockedOverlay: some View {
        Group {
            if controls {
                Button { locked = false; show("تم فتح القفل"); scheduleHide() } label: {
                    Image(systemName: "lock.fill").font(.title2).padding(16).background(.black.opacity(0.6), in: Circle()).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 20)
            }
        }
    }

    private var failedPanel: some View {
        VStack(spacing: 12) {
            Text(isLive ? "انقطع البث." : "تعذّر تشغيل الملف.").font(.headline)
            HStack {
                Button("إعادة المحاولة") { retry() }.buttonStyle(.borderedProminent)
                if isLive { Button("القنوات") { sheet = .channels }.buttonStyle(.bordered) }
                Button("إغلاق") { dismiss() }.buttonStyle(.bordered)
            }
        }
        .padding(20).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.white)
    }

    private func resumeChip(_ seconds: Double) -> some View {
        HStack(spacing: 10) {
            Text("استكمال من \(fmt(Int32(seconds * 1000)))").font(.callout)
            Button("من البداية") { model.seek(toMs: 0); resumeAt = nil }.buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.7), in: Capsule()).foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 20).padding(.bottom, controls ? 96 : 24)
        .environment(\.layoutDirection, .leftToRight)
    }

    private var showNextCard: Bool { nextCountdown != nil && !nextCancelled }

    private func nextCard(_ n: VodPlay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("الحلقة التالية").font(.caption).opacity(0.8)
            Text(n.title).font(.headline).lineLimit(2)
            HStack {
                Button { playEpisode(index + 1, markWatched: true) } label: {
                    Label("شغّل الآن (\(nextCountdown ?? 0))", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Button("إلغاء") { nextCancelled = true; countdownTask?.cancel(); nextCountdown = nil }.buttonStyle(.bordered)
            }
        }
        .padding(16).frame(maxWidth: 330, alignment: .leading)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 20).padding(.bottom, controls ? 96 : 24)
        .environment(\.layoutDirection, .rightToLeft)
    }

    // MARK: Menus

    private var audioMenu: some View {
        Menu {
            let tracks = model.audioTracks
            if tracks.isEmpty { Text("لا توجد مسارات صوت") }
            ForEach(tracks) { t in
                Button { model.player.currentAudioTrackIndex = t.id; show("الصوت: \(t.name)") } label: {
                    if model.player.currentAudioTrackIndex == t.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                }
            }
        } label: { menuIcon("waveform") }
    }

    private var subtitleMenu: some View {
        Menu {
            Section("ترجمات الملف") {
                let tracks = model.subtitleTracks
                if tracks.isEmpty { Text("لا توجد ترجمة داخل الملف") }
                ForEach(tracks) { t in
                    Button { model.player.currentVideoSubTitleIndex = t.id } label: {
                        if model.player.currentVideoSubTitleIndex == t.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                    }
                }
            }
            if !isLive {
                Button { sheet = .subs } label: { Label("ترجمة من الإنترنت…", systemImage: "globe") }
            }
            Section("التوقيت: \(model.subDelay == 0 ? "الأصلي" : String(format: "%+.1f ث", model.subDelay))") {
                Button { model.shiftSubs(-0.5); show(delayText) } label: { Label("أبكر ٠٫٥ ث", systemImage: "minus.circle") }
                Button { model.shiftSubs(0.5); show(delayText) } label: { Label("أتأخر ٠٫٥ ث", systemImage: "plus.circle") }
                if model.subDelay != 0 { Button { model.shiftSubs(0); show(delayText) } label: { Label("إرجاع التوقيت", systemImage: "arrow.uturn.backward") } }
            }
        } label: { menuIcon("captions.bubble") }
    }

    private var pictureMenu: some View {
        Menu {
            Section("شكل الصورة") {
                ForEach(PlayerModel.Fit.allCases, id: \.self) { f in
                    Button { fit = f; model.apply(f); show(f.rawValue) } label: { if fit == f { Label(f.rawValue, systemImage: "checkmark") } else { Text(f.rawValue) } }
                }
            }
        } label: { menuIcon("aspectratio") }
    }

    private var speedMenu: some View {
        Menu {
            ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { r in
                Button { model.setRate(r); show("السرعة \(rateText(r))") } label: {
                    if model.rate == r { Label(rateText(r), systemImage: "checkmark") } else { Text(rateText(r)) }
                }
            }
        } label: {
            Label(model.rate == 1 ? "السرعة" : rateText(model.rate), systemImage: "speedometer")
                .font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 7)
                .background(.white.opacity(0.16), in: Capsule())
        }
    }

    // MARK: Small views

    private func iconButton(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button { action(); scheduleHide() } label: { menuIcon(name) }
    }
    private func menuIcon(_ name: String) -> some View {
        Image(systemName: name).font(.title3).frame(width: 42, height: 42).contentShape(Rectangle())
    }
    private func bigButton(_ name: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: size)).frame(width: 64, height: 64).contentShape(Rectangle()) }
    }
    private func pill(_ text: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button { action(); scheduleHide() } label: {
            Label(text, systemImage: icon).font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 7)
                .background(.white.opacity(0.16), in: Capsule())
        }
    }
    private func centerBadge(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon).font(.title3.bold().monospacedDigit()).padding(.horizontal, 18).padding(.vertical, 12)
            .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
            .environment(\.layoutDirection, .leftToRight)
            .frame(maxHeight: .infinity, alignment: .top).padding(.top, 90)
            .allowsHitTesting(false)
    }
    private func levelBar(_ icon: String, _ value: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            ProgressView(value: value).tint(.white).frame(width: 140)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
        .environment(\.layoutDirection, .leftToRight)
        .frame(maxHeight: .infinity, alignment: .top).padding(.top, 90)
        .allowsHitTesting(false)
    }

    // MARK: Actions

    private func start() {
        switch item {
        case .live(let l, let i):
            index = i; model.open(l[i].url, live: true); epg.load(l[i], from: library.xtream)
        case .vod(let l, let i):
            index = i; openVod(l[i])
        }
        scheduleHide()
    }

    private func openVod(_ v: VodPlay) {
        let pos = Store.position(v.key)?.pos ?? 0
        model.open(v.url, startSeconds: pos)
        if fit != .fit { model.apply(fit) }
        nextCountdown = nil; nextCancelled = false; countdownTask?.cancel()
        resumeAt = pos > 15 ? pos : nil
        if resumeAt != nil {
            let k = v.key
            Task { try? await Task.sleep(nanoseconds: 8_000_000_000); await MainActor.run { if current?.key == k { resumeAt = nil } } }
        }
    }

    private func switchChannel(to i: Int) {
        guard !channels.isEmpty else { return }
        index = (i + channels.count) % channels.count
        model.open(channels[index].url, live: true)
        if fit != .fit { model.apply(fit) }
        epg.load(channels[index], from: library.xtream)
        show(channels[index].name)
        scheduleHide()
    }

    private func playEpisode(_ i: Int, markWatched: Bool) {
        guard queue.indices.contains(i) else { return }
        if markWatched, let c = current { Store.setPosition(c.key, 1, 1) } else { saveResume() }
        index = i
        openVod(queue[i])
        show(queue[i].title)
        scheduleHide()
    }

    /// Next-episode card: last 40 s of the episode, 15 s countdown, then the next one starts.
    private func updateNextCard() {
        guard !isLive, nextUp != nil, !nextCancelled, model.lengthMs > 120_000 else { return }
        let left = model.lengthMs - model.timeMs
        if left < 40_000 && left > 0 && nextCountdown == nil && scrub == nil {
            nextCountdown = 15
            countdownTask?.cancel()
            countdownTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let done = await MainActor.run { () -> Bool in
                        guard let c = nextCountdown, !nextCancelled else { return true }
                        if !model.playing { return false }      // paused: hold the countdown
                        if c <= 1 { playEpisode(index + 1, markWatched: true); return true }
                        nextCountdown = c - 1; return false
                    }
                    if done { break }
                }
            }
        } else if left >= 45_000 && nextCountdown != nil {
            countdownTask?.cancel(); nextCountdown = nil      // viewer seeked back
        }
    }

    /// One manual retry, started by the viewer (no automatic reconnect loop).
    private func retry() {
        if isLive { model.open(channels[index].url, live: true) }
        else if let v = current { model.open(v.url, startSeconds: Double(model.timeMs) / 1000) }
        if fit != .fit { model.apply(fit) }
        scheduleHide()
    }

    private func saveResume(finished: Bool = false) {
        guard let v = current else { return }
        if finished { Store.setPosition(v.key, 1, 1); return }
        guard model.lengthMs > 0 else { return }
        Store.setPosition(v.key, Double(model.timeMs) / 1000, Double(model.lengthMs) / 1000)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard controls else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if !Task.isCancelled { await MainActor.run { if sheet == nil { withAnimation { controls = false } } } }
        }
    }

    private func flashText(_ text: String) {
        flash = text
        Task { try? await Task.sleep(nanoseconds: 700_000_000); await MainActor.run { if flash == text { flash = nil } } }
    }

    private func show(_ text: String) {
        notice = text
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); await MainActor.run { if notice == text { notice = nil } } }
    }

    private var delayText: String {
        model.subDelay == 0 ? "توقيت الترجمة الأصلي" : String(format: "تأخير الترجمة %+.1f ث", model.subDelay)
    }

    private var endsAt: String {
        let left = Double(max(0, model.lengthMs - model.timeMs)) / 1000 / Double(max(model.rate, 0.1))
        return timeText(Date().addingTimeInterval(left))
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private func rateText(_ r: Float) -> String { r == 1 ? "عادية" : String(format: "%gx", r) }

    private func fmt(_ ms: Int32) -> String {
        let s = Int(ms) / 1000
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Sheets

/// Channel list while watching: search, now-playing line, tap to switch.
struct ChannelPickerSheet: View {
    let channels: [Channel]
    let current: Int
    let onPick: (Int) -> Void
    @EnvironmentObject var library: Library
    @EnvironmentObject var epg: EPG
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(channels.enumerated()), id: \.element.id) { i, ch in
                        if query.isEmpty || ch.name.localizedCaseInsensitiveContains(query) {
                            Button { onPick(i) } label: {
                                HStack(spacing: 12) {
                                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 32)
                                    Art(url: ch.logo, fit: true).frame(width: 50, height: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ch.name).lineLimit(1).foregroundStyle(i == current ? Theme.accent : .primary)
                                        if let n = epg.now[ch.id] { Text(n.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer()
                                    if i == current { Image(systemName: "play.fill").foregroundStyle(Theme.accent) }
                                }
                            }
                            .id(i)
                            .task(id: ch.id) { epg.load(ch, from: library.xtream) }
                        }
                    }
                }
                .searchable(text: $query, prompt: "بحث")
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle("القنوات").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

/// Episodes of the series playing now, with watch progress.
struct EpisodePickerSheet: View {
    let queue: [VodPlay]
    let current: Int
    let onPick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(queue.enumerated()), id: \.element.key) { i, e in
                        Button { onPick(i) } label: {
                            HStack {
                                Text("م\(e.season ?? 0) ح\(e.number ?? 0)").font(.callout.monospacedDigit())
                                    .foregroundStyle(i == current ? Theme.accent : .primary)
                                Spacer()
                                if let p = progress(e.key) { ProgressView(value: p).tint(Theme.accent).frame(width: 70) }
                                if i == current { Image(systemName: "play.fill").foregroundStyle(Theme.accent) }
                            }
                        }
                        .id(i)
                    }
                }
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle("الحلقات").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        }
        .environment(\.layoutDirection, .rightToLeft)
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
