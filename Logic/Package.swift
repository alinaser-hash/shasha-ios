// swift-tools-version:5.9
import PackageDescription

// Pure playback rules (no UIKit, no VLC) so they can be unit-tested with `swift test` on the CI Mac.
// The app target compiles the same source file directly (see project.yml).
let package = Package(
    name: "PlaybackLogic",
    platforms: [.macOS(.v13), .iOS(.v16)],
    targets: [
        .target(name: "PlaybackLogic"),
        .testTarget(name: "PlaybackLogicTests", dependencies: ["PlaybackLogic"]),
    ]
)
