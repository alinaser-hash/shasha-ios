import SwiftUI
import AVKit
import Combine

/// One hand-off to Apple's player.
struct ApplePlayback: Identifiable {
    let id = UUID()
    let url: URL
    let start: Double
    let key: String
}

/// Apple's own player (AVPlayerViewController): Dolby Vision / HDR shown correctly, AirPlay, system PiP.
/// Plays MP4/MOV/HLS; MKV and some TS streams are not supported by Apple — then it reports `failed`.
struct ApplePlayerView: View {
    let playback: ApplePlayback
    /// position s, duration s, failed
    let onClose: (Double, Double, Bool) -> Void
    @StateObject private var box = AppleBox()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            AVPlayerControllerView(player: box.player).ignoresSafeArea()
            if box.failed {
                VStack(spacing: 12) {
                    Text("مشغّل Apple لا يدعم هذا الملف (غالبًا MKV).").font(.headline)
                    Button("رجوع لمشغّل شاشة") { finish(failed: true) }.buttonStyle(.borderedProminent)
                }
                .padding(20).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { finish(failed: false) } label: {
                Label("رجوع لمشغّل شاشة", systemImage: "chevron.down").font(.callout.bold())
                    .padding(.horizontal, 14).padding(.vertical, 9).background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white)
            }
            .padding(.top, 14).padding(.leading, 18)
        }
        .onAppear { box.start(playback) }
        .onChange(of: box.ended) { e in if e { finish(failed: false) } }
        .statusBarHidden(true)
    }

    private func finish(failed: Bool) {
        let (pos, dur) = box.position()
        box.player.pause()
        onClose(pos, dur, failed)
    }
}

final class AppleBox: ObservableObject {
    let player = AVPlayer()
    @Published var failed = false
    @Published var ended = false
    private var bag = Set<AnyCancellable>()

    func start(_ p: ApplePlayback) {
        let item = AVPlayerItem(url: p.url)
        item.publisher(for: \.status).receive(on: DispatchQueue.main).sink { [weak self] s in
            if s == .failed { self?.failed = true }
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.ended = true }.store(in: &bag)
        player.replaceCurrentItem(with: item)
        if p.start > 5 { player.seek(to: CMTime(seconds: p.start, preferredTimescale: 600)) }
        player.play()
    }

    func position() -> (Double, Double) {
        let t = player.currentTime().seconds
        let d = player.currentItem?.duration.seconds ?? 0
        return (t.isFinite ? t : 0, d.isFinite ? d : 0)
    }
}

struct AVPlayerControllerView: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController()
        c.player = player
        c.allowsPictureInPicturePlayback = true
        c.canStartPictureInPictureAutomaticallyFromInline = true
        c.entersFullScreenWhenPlaybackBegins = false
        return c
    }
    func updateUIViewController(_ c: AVPlayerViewController, context: Context) {}
}
