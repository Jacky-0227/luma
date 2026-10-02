#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build/Diagnostics
test -d "${DEVELOPER_DIR:-/Applications/Xcode_26.2.app/Contents/Developer}"
xcodebuild -version | tee build/Diagnostics/xcode-version.txt

# Produce the required 1024px icon from the original generated artwork.
# Resizing is packaging only; the full-resolution original remains in design/.
ICON_OUTPUT=Luma/Assets.xcassets/AppIcon.appiconset/AppIcon.png
mkdir -p "$(dirname "$ICON_OUTPUT")"
sips --resampleHeightWidth 1024 1024 design/Luma-icon-source.png --out "$ICON_OUTPUT"
python3 scripts/validate-project.py --prepared-assets

# Use the release artifact's published SHA-256, not an unpinned Homebrew formula.
XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
TOOLS_DIR="${RUNNER_TEMP:-$PWD/build}/luma-build-tools"
mkdir -p "$TOOLS_DIR"
curl --fail --location --retry 3 --connect-timeout 20 \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" \
  --output "$TOOLS_DIR/xcodegen.zip"
printf '%s  %s\n' "$XCODEGEN_SHA256" "$TOOLS_DIR/xcodegen.zip" | shasum --algorithm 256 --check
unzip -q -o "$TOOLS_DIR/xcodegen.zip" -d "$TOOLS_DIR"
"$TOOLS_DIR/xcodegen/bin/xcodegen" --version
"$TOOLS_DIR/xcodegen/bin/xcodegen" generate --spec project.yml

gem install cocoapods --version 1.16.2 --no-document
pod _1.16.2_ install
cp Podfile.lock build/Diagnostics/Podfile.lock
pod _1.16.2_ spec cat MobileVLCKit --version=3.7.3 > build/Diagnostics/MobileVLCKit.podspec.json

# CocoaPods validates the downloaded MobileVLCKit archive using its podspec SHA-256.
python3 - <<'PY'
import json
from pathlib import Path
spec = json.loads(Path('build/Diagnostics/MobileVLCKit.podspec.json').read_text())
expected = '0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9'
if spec.get('version') != '3.7.3' or spec.get('source', {}).get('sha256') != expected:
    raise SystemExit('MobileVLCKit version or archive checksum differs from reviewed dependency.')
print('MobileVLCKit 3.7.3 release checksum verified.')
PY
