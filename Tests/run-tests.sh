#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/GPUCheck-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  "$project_dir/Sources/Models.swift" \
  "$project_dir/Sources/SSHClient.swift" \
  "$project_dir/Sources/MonitorStore.swift" \
  "$project_dir/Sources/ContinuousIdleTimer.swift" \
  "$project_dir/Sources/IdleGuard.swift" \
  "$project_dir/Tests/IdleGuardSmoke.swift" \
  -lsqlite3 -framework Security -o "$test_dir/idle-smoke"
"$test_dir/idle-smoke" "$test_dir/export" "$@"
python3 "$project_dir/Tests/IdleGuardDryRun.py" "$test_dir/export"

xcrun swiftc -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  "$project_dir/Sources/Models.swift" \
  "$project_dir/Sources/SSHClient.swift" \
  "$project_dir/Sources/MonitorStore.swift" \
  "$project_dir/Sources/ContinuousIdleTimer.swift" \
  "$project_dir/Sources/IdleGuard.swift" \
  "$project_dir/Tests/HistoryRecoverySmoke.swift" \
  -lsqlite3 -framework Security -o "$test_dir/history-smoke"
"$test_dir/history-smoke"
