#!/bin/bash
# Regression check for test discovery; no build products or frameworks needed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
diff -u <(printf '%s\n' Plain.First Typed/0.Convert Values/Suite.Works/0 Last.Final) \
    <(awk -f "$ROOT/MavericksSupport/scripts/parse-api-test-list.awk" <<'LIST'
diagnostic before listing
Plain.
  First
  DISABLED_Second
Typed/0.  # TypeParam = unsigned long
  Convert
Values/Suite.
  Works/0  # GetParam() = 12
  DISABLED_Works/1  # GetParam() = 13
Values/DISABLED_Suite.
  MustNotRun/0
DISABLED_Suite.
  MustNotRun
unrelated diagnostic
  indented diagnostic
Last.
  Final
LIST
)
echo 'PASS: API test discovery includes parameterized tests and excludes disabled tests'
