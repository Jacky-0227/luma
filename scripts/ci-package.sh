#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
xcodebuild build \
  -workspace Luma.xcworkspace \
  -scheme Luma \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/Device \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  2>&1 | tee build/device-build.log

APP_PATH="$PWD/build/Device/Build/Products/Release-iphoneos/Luma.app"
test -x "$APP_PATH/Luma"
mkdir -p build/package/Payload build/output
ditto "$APP_PATH" build/package/Payload/Luma.app
ditto -c -k --sequesterRsrc --keepParent build/package/Payload build/output/Luma-unsigned.ipa
python3 scripts/validate-ipa.py build/output/Luma-unsigned.ipa
shasum --algorithm 256 build/output/Luma-unsigned.ipa > build/Diagnostics/ipa-sha256.txt
