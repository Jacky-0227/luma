#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != '--ptz-only' ] && [ "$1" != '--unit-only' ]; }; then
  echo 'Usage: ci-test-ptz.sh [--ptz-only|--unit-only]' >&2
  exit 2
fi
TEST_SUITES=(
  LumaTests/PTZDiscoveryTests
  LumaTests/PTZTests
  LumaTests/PTZHTTPIntegrationTests
  LumaTests/PTZTouchTests
)
TEST_SCOPE='PTZ discovery/control + real HTTP Digest/connection reuse + UIKit touch events'
if [ "${1:-}" != '--ptz-only' ]; then
  TEST_SUITES+=(
    LumaTests/LumaCoreTests
    LumaTests/ConfigurationBackupTests
    LumaTests/DashboardStoreTests
    LumaTests/DashboardSessionTests
    LumaTests/DashboardPreviewTests
    LumaTests/CameraThumbnailStoreTests
    LumaTests/VLCCaptureIntegrationTests
  )
  TEST_SCOPE="$TEST_SCOPE + camera persistence/backup + dashboard store/session/preview + local thumbnail store/real VLC capture"
  if [ "${1:-}" != '--unit-only' ]; then
    TEST_SUITES+=(LumaUITests/DashboardUITests LumaUITests/WelcomeUITests)
    TEST_SCOPE="$TEST_SCOPE + dashboard editor/first-launch welcome UI"
  fi
fi
TEST_ARGUMENTS=()
for SUITE in "${TEST_SUITES[@]}"; do
  TEST_ARGUMENTS+=("-only-testing:$SUITE")
done
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
printf '%s\n' "$TEST_SCOPE" > build/Diagnostics/test-scope.txt

# Build the actual hosted XCTest target and production sources with the same
# scheme/settings as normal CI. PTZ-only and unit-only scopes exclude the UI
# target from both build-for-testing and execution; default focused keeps it.
BUILD_ARGUMENTS=(
  -workspace Luma.xcworkspace
  -scheme Luma
  -configuration Debug
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID"
  -destination-timeout 120
  -derivedDataPath build/Simulator
  CODE_SIGNING_ALLOWED=NO
)
xcodebuild build-for-testing "${BUILD_ARGUMENTS[@]}" "${TEST_ARGUMENTS[@]}" \
  2>&1 | tee build/test.log

xcrun simctl boot "$SIMULATOR_ID" || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcodebuild test-without-building "${BUILD_ARGUMENTS[@]}" \
  -resultBundlePath build/TestResults.xcresult \
  -parallel-testing-enabled NO \
  "${TEST_ARGUMENTS[@]}" \
  2>&1 | tee -a build/test.log

# xcodebuild can succeed when a filter matches zero tests. Confirm that all
# requested suites really ran; never publish a misleading focused-test pass.
python3 - "${TEST_SUITES[@]}" <<'PY'
from pathlib import Path
import re
import sys
log = Path('build/test.log').read_text(errors='replace')
counts = {}
for requested in sys.argv[1:]:
    target, suite = requested.split('/', 1)
    count = len(re.findall(r"Test Case '-\[" + re.escape(target + '.' + suite) + r" [^\]]+\]' passed \(", log))
    if count == 0:
        raise SystemExit(f'No passing tests executed in required suite {suite}.')
    counts[suite] = count
summary = '\n'.join(f'{suite}: {count} tests passed' for suite, count in counts.items())
Path('build/Diagnostics/focused-test-counts.txt').write_text(summary + '\n')
print(summary)
PY
