#!/bin/bash
# Builds MPVKit's libmpv (LGPL) for iPhone (arm64 device) with our patches in patches/libmpv/ added to
# MPVKit's own. Every other library (FFmpeg included) comes from MPVKit's prebuilt release archives, so only
# libmpv is compiled. Output: <out>/Libmpv.xcframework (same layout as MPVKit's release, module "Libmpv").
#
#   scripts/build-libmpv.sh <MPVKit tag> <out dir>
set -euo pipefail
TAG="$1"
OUT="$(mkdir -p "$2" && cd "$2" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for tool in meson ninja pkg-config wget; do command -v "$tool" >/dev/null || brew install "$tool"; done

WORK="$(mktemp -d)"
git clone --quiet --depth 1 --branch "$TAG" https://github.com/mpvkit/MPVKit.git "$WORK/MPVKit"
cd "$WORK/MPVKit"
cp "$ROOT"/patches/libmpv/*.patch Sources/BuildScripts/patch/libmpv/

python3 - "$TAG" <<'PY'
import sys
tag = sys.argv[1]
def edit(path, old, new):
    s = open(path).read()
    if s.count(old) != 1:
        sys.exit(f"{path}: expected text not found exactly once: {old!r}")
    open(path, "w").write(s.replace(old, new))

main = "Sources/BuildScripts/XCFrameworkBuild/main.swift"
# FFmpeg from MPVKit's own prebuilt archive of the same release instead of a source build.
edit(main, 'return "https://github.com/FFmpeg/FFmpeg"',
     f'return "https://github.com/mpvkit/MPVKit/releases/download/{tag}/FFmpeg-all.zip"')
edit(main, "try BuildFFMPEG().buildALL()", "try BuildFFmpegPrebuilt().buildALL()")
s = open(main).read()
s += "\nprivate class BuildFFmpegPrebuilt: ZipBaseBuild {\n    init() { super.init(library: .FFmpeg) }\n}\n"
open(main, "w").write(s)
# Turn on the avfoundation video output added by our patch (iOS).
edit(main, '"-Drubberband=disabled",\n        ]', '"-Drubberband=disabled",\n            "-Dvo-avfoundation=enabled",\n        ]')

base = "Sources/BuildScripts/XCFrameworkBuild/base.swift"
# Device only (platform=ios would also add the simulator).
edit(base, "options.platforms += [PlatformType.ios, PlatformType.isimulator]", "options.platforms += [PlatformType.ios]")
# No Package.swift generation (it needs checksums of every archive).
edit(base, "    func generatePackageManagerFile() throws {\n", "    func generatePackageManagerFile() throws {\n        return\n")
PY

swift run --build-path ./.build --package-path Sources/BuildScripts build platform=ios "version=$TAG"

XC="$(find dist -maxdepth 3 -type d -name 'Libmpv.xcframework' | head -1)"
[ -n "$XC" ] || { echo "Libmpv.xcframework not found"; find dist -maxdepth 3 | head -50; exit 1; }
BIN="$(find "$XC" -type f -path '*Libmpv.framework/Libmpv' | head -1)"
nm "$BIN" 2>/dev/null | grep '_video_out_avfoundation' >/dev/null || { echo "libmpv has no avfoundation video output"; exit 1; }
rm -rf "$OUT/Libmpv.xcframework"
cp -R "$XC" "$OUT/Libmpv.xcframework"
echo "Built $OUT/Libmpv.xcframework (MPVKit $TAG + $(ls "$ROOT"/patches/libmpv/*.patch | xargs -n1 basename | tr '\n' ' '))"
