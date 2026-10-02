#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build/Diagnostics
xcrun simctl list devices available --json > build/simulators.json
SIMULATOR_ID="$(python3 - <<'PY'
import json
from pathlib import Path
devices = json.loads(Path('build/simulators.json').read_text())['devices']
options = []
for runtime, entries in devices.items():
    if '.iOS-26-' not in runtime:
        continue
    version = tuple(int(part) for part in runtime.rsplit('.iOS-', 1)[1].split('-'))
    if version > (26, 2):
        continue
    for device in entries:
        name = device.get('name', '')
        if name.startswith('iPhone') and device.get('isAvailable', False):
            options.append((version, name == 'iPhone 17 Pro', name, device['udid']))
if not options:
    raise SystemExit('No compatible iOS 26 simulator is available on this runner.')
print(max(options)[-1])
PY
)"
printf '%s\n' "$SIMULATOR_ID" > build/Diagnostics/simulator-id.txt

# Compile before starting the simulator. A compiler error should fail quickly
# instead of paying the first-boot/migration cost on every source correction.
BUILD_ARGUMENTS=(
  -workspace Luma.xcworkspace
  -scheme Luma
  -configuration Debug
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID"
  -destination-timeout 120
  -derivedDataPath build/Simulator
  CODE_SIGNING_ALLOWED=NO
)
xcodebuild build-for-testing "${BUILD_ARGUMENTS[@]}" \
  2>&1 | tee build/test.log

xcrun simctl boot "$SIMULATOR_ID" || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
# A cosmetic screenshot override must never block actual tests. Python's
# subprocess timeout terminates and reaps the child without a background helper.
python3 - "$SIMULATOR_ID" <<'PY'
import subprocess
import sys
command = [
    'xcrun', 'simctl', 'status_bar', sys.argv[1], 'override',
    '--time', '9:41', '--dataNetwork', 'wifi', '--wifiMode', 'active',
    '--wifiBars', '3', '--batteryState', 'charged', '--batteryLevel', '100',
]
try:
    result = subprocess.run(command, timeout=20, check=False)
    if result.returncode:
        print('Status-bar override unavailable; continuing with normal status bar.')
except subprocess.TimeoutExpired:
    print('Status-bar override exceeded 20 seconds; continuing with normal status bar.')
except OSError as error:
    print(f'Status-bar override unavailable: {error}; continuing with tests.')
PY

xcodebuild test-without-building "${BUILD_ARGUMENTS[@]}" \
  -resultBundlePath build/TestResults.xcresult \
  -parallel-testing-enabled NO \
  2>&1 | tee -a build/test.log
