#!/bin/bash
# vendor/MPVKit = MPVKit's Package.swift at <tag>, with the Libmpv binary target pointing at our own build.
#   scripts/vendor-mpvkit.sh <MPVKit tag> <dir with Libmpv.xcframework>
set -euo pipefail
TAG="$1"; LIB="$(cd "$2" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rm -rf "$ROOT/vendor/MPVKit"
git clone --quiet --depth 1 --branch "$TAG" https://github.com/mpvkit/MPVKit.git "$ROOT/vendor/MPVKit"
cd "$ROOT/vendor/MPVKit"
rm -rf .git Demo Sources/BuildScripts
cp -R "$LIB/Libmpv.xcframework" ./Libmpv.xcframework
python3 - <<'PY'
import re, sys
s = open("Package.swift").read()
new, n = re.subn(r'\.binaryTarget\(\s*name: "Libmpv",\s*url: "[^"]+",\s*checksum: "[^"]+"\s*\)',
                 '.binaryTarget(name: "Libmpv", path: "Libmpv.xcframework")', s)
if n != 1: sys.exit("Libmpv binary target not found once in Package.swift")
open("Package.swift", "w").write(new)
PY
grep -n 'name: "Libmpv"' Package.swift
