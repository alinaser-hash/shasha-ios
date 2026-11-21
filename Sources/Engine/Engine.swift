import UIKit
#if VLC4
import VLCKit
#else
import MobileVLCKit
#endif

// The app is built twice from the same source:
// - "شاشة"      → MobileVLCKit 3 (same libVLC 3 as the official VLC app: embedded subtitles, MKV timing work reliably)
// - "شاشة PiP"  → VLCKit 4 alpha (picture in picture), compiled with the VLC4 condition.
// Everything that differs between the two libraries lives in this file.

#if !VLC4
/// VLCKit 3 has no picture-in-picture protocols; a plain view to draw into.
final class ShashaPiPView: UIView {}
#endif

enum Engine {
    static var hasPiP: Bool {
        #if VLC4
        return true
        #else
        return false
        #endif
    }

    static var name: String {
        #if VLC4
        return "VLCKit 4 (libVLC \(VLCLibrary.shared().version))"
        #else
        return "MobileVLCKit 3 (libVLC \(VLCLibrary.shared().version))"
        #endif
    }

    static var lastError: String {
        #if VLC4
        return VLCLibrary.currentErrorMessage ?? "لا يوجد"
        #else
        return "غير متاح في VLCKit 3"
        #endif
    }

    static func media(_ url: URL) -> VLCMedia? {
        VLCMedia(url: url)
    }

    static func state(_ s: VLCMediaPlayerState) -> EngineState {
        switch s {
        case .opening: return .opening
        case .buffering: return .buffering
        case .playing: return .playing
        case .paused: return .paused
        case .error: return .error
        #if VLC4
        case .stopped, .stopping: return .stopped
        #else
        case .stopped: return .stopped
        case .ended: return .ended
        #endif
        default: return .buffering
        }
    }
}

extension PlayerModel {
    // MARK: Picture shape

    func applyFitToEngine(_ f: Fit) {
        #if VLC4
        player.videoAspectRatio = nil
        player.setCropRatioWithNumerator(0, denominator: 0)
        switch f {
        case .fit: break
        case .fill:
            let b = UIScreen.main.bounds
            player.setCropRatioWithNumerator(UInt32(max(b.width, b.height)), denominator: UInt32(min(b.width, b.height)))
        case .wide: player.videoAspectRatio = "16:9"
        case .classic: player.videoAspectRatio = "4:3"
        }
        #else
        // VLC copies the strings it is given.
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
        #endif
    }

    // MARK: Tracks (ids are the engine's own: VLC 4 track id, VLC 3 track index)

    var engineAudioTracks: [Track] {
        #if VLC4
        return player.audioTracks.map { Track(id: $0.trackId, name: $0.trackName, selected: $0.isSelected) }
        #else
        let cur = player.currentAudioTrackIndex
        return pairs(player.audioTrackIndexes as [Any]?, player.audioTrackNames as [Any]?)
            .filter { $0.0 >= 0 }
            .map { Track(id: String($0.0), name: $0.1, selected: $0.0 == cur) }
        #endif
    }

    var engineSubtitleTracks: [Track] {
        #if VLC4
        return player.textTracks.map { Track(id: $0.trackId, name: $0.trackName, selected: $0.isSelected) }
        #else
        let cur = player.currentVideoSubTitleIndex
        return pairs(player.videoSubTitlesIndexes as [Any]?, player.videoSubTitlesNames as [Any]?)
            .filter { $0.0 >= 0 }          // VLC 3 lists "Disable" as -1
            .map { Track(id: String($0.0), name: $0.1, selected: $0.0 == cur) }
        #endif
    }

    #if !VLC4
    private func pairs(_ ids: [Any]?, _ names: [Any]?) -> [(Int32, String)] {
        let i = (ids ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        let n = (names ?? []).map { "\($0)" }
        return Array(zip(i, n))
    }
    #endif

    /// Selects by engine id in the engine's current list. Returns the track name, or nil if it no longer exists.
    func engineSelect(audio: Bool, id: String) -> String? {
        let list = audio ? engineAudioTracks : engineSubtitleTracks
        guard let t = list.first(where: { $0.id == id }) else { return nil }
        #if VLC4
        let raw = audio ? player.audioTracks : player.textTracks
        raw.first(where: { $0.trackId == id })?.isSelectedExclusively = true
        #else
        if let i = Int32(id) {
            if audio { player.currentAudioTrackIndex = i } else { player.currentVideoSubTitleIndex = i }
        }
        #endif
        return t.name
    }

    func engineSubtitlesOff() {
        #if VLC4
        player.deselectAllTextTracks()
        #else
        player.currentVideoSubTitleIndex = -1
        #endif
    }

    // MARK: Diagnostics

    struct EngineTrackReport { var video: [String]; var audio: [String]; var text: [String] }

    func engineTrackReport() -> EngineTrackReport {
        #if VLC4
        return EngineTrackReport(video: player.videoTracks.map(Self.describe),
                                 audio: player.audioTracks.map(Self.describe),
                                 text: player.textTracks.map(Self.describe))
        #else
        let note = "الترميز واللغة: غير متاح في VLCKit 3"
        return EngineTrackReport(
            video: ["غير متاح في VLCKit 3"],
            audio: engineAudioTracks.map { "id=\($0.id) | «\($0.name)» | محدد=\($0.selected ? "نعم" : "لا") | \(note)" },
            text: engineSubtitleTracks.map { "id=\($0.id) | «\($0.name)» | محدد=\($0.selected ? "نعم" : "لا") | \(note)" })
        #endif
    }

    #if VLC4
    /// Everything VLC 4 exposes about one track; "غير متاح" where it exposes nothing.
    static func describe(_ t: VLCMediaPlayer.Track) -> String {
        var p = ["id=\(t.trackId)", "«\(t.trackName)»", "محدد=\(t.isSelected ? "نعم" : "لا")",
                 "ترميز=\(t.codecName())", "fourcc=\(DiagRule.fourcc(t.fourcc))", "codec=\(DiagRule.fourcc(t.codec))",
                 "لغة=\(t.language ?? "غير متاح")"]
        p.append("profile=" + (t.profile >= 0 ? String(t.profile) : "غير متاح"))
        p.append("level=" + (t.level >= 0 ? String(t.level) : "غير متاح"))
        if t.bitrate > 0 { p.append("bitrate=\(t.bitrate)") }
        if let d = t.trackDescription, !d.isEmpty { p.append("وصف=\(d)") }
        if let v = t.video {
            p.append("\(v.width)x\(v.height)")
            if v.frameRateDenominator > 0 { p.append(String(format: "fps=%.3f", Double(v.frameRate) / Double(v.frameRateDenominator))) }
        }
        if let a = t.audio { p.append("قنوات=\(a.channelsNumber)"); p.append("rate=\(a.rate)") }
        if let x = t.text { p.append("ترميز النص=\(x.encoding ?? "غير متاح")") }
        return p.joined(separator: " | ")
    }
    #endif
}
