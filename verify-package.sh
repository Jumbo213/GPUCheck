#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
workspace_dir="$(cd "$project_dir/../.." && pwd)"
if [[ -f "$project_dir/outputs/GPUCheck.dmg" ]]; then
  default_dmg="$project_dir/outputs/GPUCheck.dmg"
else
  default_dmg="$workspace_dir/outputs/GPUCheck.dmg"
fi
dmg_file="${1:-$default_dmg}"
mkdir -p "$project_dir/build"
mount_dir="$(mktemp -d "$project_dir/build/verify-mount.XXXXXX")"
mounted=0
cleanup() {
  if [[ "$mounted" -eq 1 ]]; then
    hdiutil detach "$mount_dir" -quiet || true
  fi
  rmdir "$mount_dir" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil verify "$dmg_file"
hdiutil attach "$dmg_file" -nobrowse -readonly -mountpoint "$mount_dir" -quiet
mounted=1
app_dir="$mount_dir/GPUCheck.app"
test -d "$app_dir"
test "$(readlink "$mount_dir/Applications")" = /Applications
test -s "$app_dir/Contents/Resources/AppIcon.icns"
test -x "$app_dir/Contents/MacOS/GPUCheckAskPass"
plutil -lint "$app_dir/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app_dir"
for arch in arm64 x86_64; do
  xcrun lipo "$app_dir/Contents/MacOS/GPUCheck" -verify_arch "$arch"
  xcrun lipo "$app_dir/Contents/MacOS/GPUCheckAskPass" -verify_arch "$arch"
done
otool -L "$app_dir/Contents/MacOS/GPUCheck"
echo "GPUCheck package checks passed."
