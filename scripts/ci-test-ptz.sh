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
printf '%s\n' 'PTZ discovery/control + dashboard store/session/preview + dashboard editor UI' > build/Diagnostics/test-scope.txt

# Build the actual hosted XCTest target and production sources with the same
# scheme/settings as normal CI. Run the changed protocol/dashboard suites and
# their focused editor UI regression; unrelated media tests stay in normal CI.
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
xcodebuild test-without-building "${BUILD_ARGUMENTS[@]}" \
  -resultBundlePath build/TestResults.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:LumaTests/PTZDiscoveryTests \
  -only-testing:LumaTests/PTZTests \
  -only-testing:LumaTests/DashboardStoreTests \
  -only-testing:LumaTests/DashboardSessionTests \
  -only-testing:LumaTests/DashboardPreviewTests \
  -only-testing:LumaUITests/DashboardUITests \
  2>&1 | tee -a build/test.log

# xcodebuild can succeed when a filter matches zero tests. Confirm that all
# requested suites really ran; never publish a misleading focused-test pass.
python3 - <<'PY'
from pathlib import Path
import re
log = Path('build/test.log').read_text(errors='replace')
counts = {}
suites = {
    'LumaTests': ('PTZDiscoveryTests', 'PTZTests', 'DashboardStoreTests', 'DashboardSessionTests', 'DashboardPreviewTests'),
    'LumaUITests': ('DashboardUITests',),
}
for target, names in suites.items():
    for suite in names:
        count = len(re.findall(r"Test Case '-\[" + re.escape(target + '.' + suite) + r" [^\]]+\]' passed \(", log))
        if count == 0:
            raise SystemExit(f'No passing tests executed in required suite {suite}.')
        counts[suite] = count
summary = '\n'.join(f'{suite}: {count} tests passed' for suite, count in counts.items())
Path('build/Diagnostics/focused-test-counts.txt').write_text(summary + '\n')
print(summary)
PY
