#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build/Diagnostics
for LOG_NAME in test device-build; do
  if [ -f "build/$LOG_NAME.log" ]; then
    tail -n 220 "build/$LOG_NAME.log" > "build/Diagnostics/$LOG_NAME-tail.txt"
  fi
done

if [ -d build/TestResults.xcresult ]; then
  xcrun xcresulttool get test-results summary --path build/TestResults.xcresult \
    > build/Diagnostics/test-summary.json || true
  xcrun xcresulttool export attachments --path build/TestResults.xcresult \
    --output-path build/attachments || true
  python3 - <<'PY'
from pathlib import Path
import json
import shutil
source = Path('build/attachments')
target = Path('build/Diagnostics/Screenshots')
target.mkdir(parents=True, exist_ok=True)
# Keep XCTest attachment names and test identifiers alongside opaque filenames.
# The manifest allows a reviewer to map each PNG to its screen/test/language.
for index, manifest in enumerate(sorted(source.rglob('manifest.json'))):
    filename = 'manifest.json' if index == 0 else f'manifest-{index}.json'
    shutil.copy2(manifest, target / filename)
total = 0
exported = []
for index, file in enumerate(sorted(source.rglob('*'))):
    if file.suffix.lower() not in {'.png', '.jpg', '.jpeg'} or not file.is_file():
        continue
    size = file.stat().st_size
    if total + size > 25_000_000:
        continue
    exported_name = f'{index:03d}-{file.name}'
    shutil.copy2(file, target / exported_name)
    exported.append({'original': str(file.relative_to(source)), 'exported': exported_name})
    total += size
if exported:
    (target / 'filename-map.json').write_text(json.dumps(exported, indent=2), encoding='utf-8')
text_target = Path('build/Diagnostics/TestAttachments')
text_target.mkdir(parents=True, exist_ok=True)
text_total = 0
for index, file in enumerate(sorted(source.rglob('*'))):
    if not file.is_file() or file.suffix.lower() not in {'.txt', '.log'}:
        continue
    remaining = 1_000_000 - text_total
    if remaining <= 0:
        break
    # Failed UI tests can attach accessibility hierarchies. Keep enough context
    # to diagnose missing controls while bounding report storage and log volume.
    with file.open('rb') as handle:
        data = handle.read(min(128_000, remaining))
    (text_target / f'{index:03d}-{file.name}').write_bytes(data)
    text_total += len(data)
print(f'Exported {total:,} bytes of simulator interface screenshots.')
PY
fi
