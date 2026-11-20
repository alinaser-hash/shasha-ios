import SwiftUI
import UIKit
import MobileVLCKit

/// What to play: a live channel inside its list (◀▶ switch channels) or a film/episode with a resume key.
enum PlayItem: Identifiable {
    case live(list: [Channel], index: Int)
    case vod(title: String, url: String, key: String)

    var id: String {
        switch self {
        case .live(let l, let i): return "live:" + l[i].id
        case .vod(_, _, let k): return "vod:" + k
        }
    }
}

/// VLCKit player state, polled twice a second (simple and robust across VLCKit versions).
final class PlayerModel: ObservableObject {
    let player = VLCMediaPlayer()
    @Published var timeMs: Int32 = 0
    @Published var lengthMs: Int32 = 0
    @Published var playing = false
    @Published var buffering = true
    private var timer: Timer?

    func open(_ url: String, startSeconds: Double = 0) {
        guard let u = URL(string: url) else { return }
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
    }

    func toggle() { player.isPlaying ? player.pause() : player.play() }
    func jump(_ seconds: Int32) { seconds > 0 ? player.jumpForward(seconds) : player.jumpBackward(-seconds) }
    func seek(fraction: Double) { player.position = Float(max(0, min(1, fraction))) }

    func stop() { timer?.invalidate(); timer = nil; player.stop() }

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
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PlayerModel()
    @State private var controls = true
    @State private var index = 0
    @State private var hideTask: Task<Void, Never>?

    private var title: String {
        switch item {
        case .live(let l, _): return l[index].name
        case .vod(let t, _, _): return t
        }
    }
    private var isLive: Bool { if case .live = item { return true } else { return false } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCView(model: model).ignoresSafeArea()
                .onTapGesture { controls.toggle(); scheduleHide() }
            if model.buffering { ProgressView().tint(.white).scaleEffect(1.6) }
            if controls { overlay }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { start() ; Orientation.landscape() }
        .onDisappear { saveResume(); model.stop(); Orientation.portrait() }
    }

    private var overlay: some View {
        VStack {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.title2.bold()).padding(12) }
                Text(title).font(.headline).lineLimit(1)
                Spacer()
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

    private var trackMenu: some View {
        Menu {
            Section("الصوت") {
                ForEach(model.audioTracks) { t in Button(t.name) { model.player.currentAudioTrackIndex = t.id } }
            }
            Section("الترجمة") {
                ForEach(model.subtitleTracks) { t in Button(t.name) { model.player.currentVideoSubTitleIndex = t.id } }
            }
        } label: { Image(systemName: "captions.bubble").font(.title2).padding(12) }
    }

    private func start() {
        switch item {
        case .live(let l, let i): index = i; model.open(l[i].url)
        case .vod(_, let url, let key): model.open(url, startSeconds: Store.position(key)?.pos ?? 0)
        }
        scheduleHide()
    }

    private func change(_ d: Int) {
        guard case .live(let l, _) = item, !l.isEmpty else { return }
        index = (index + d + l.count) % l.count
        model.open(l[index].url)
        scheduleHide()
    }

    private func saveResume() {
        guard case .vod(_, _, let key) = item, model.lengthMs > 0 else { return }
        Store.setPosition(key, Double(model.timeMs) / 1000, Double(model.lengthMs) / 1000)
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
