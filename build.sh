#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
workspace_dir="$(cd "$project_dir/../.." && pwd)"
build_dir="$project_dir/build"
if [[ "$(basename "$(dirname "$project_dir")")" == "work" && -d "$workspace_dir/outputs" ]]; then
  default_output_dir="$workspace_dir/outputs"
else
  default_output_dir="$project_dir/outputs"
fi
output_dir="${GPUCHECK_OUTPUT_DIR:-$default_output_dir}"
architecture="universal"
create_dmg=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      architecture="${2:?--arch requires arm64, x86_64, or universal}"
      shift 2
      ;;
    --skip-dmg) create_dmg=0; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
case "$architecture" in
  universal) architectures=(arm64 x86_64) ;;
  arm64|x86_64) architectures=("$architecture") ;;
  *) echo "Unsupported architecture: $architecture" >&2; exit 2 ;;
esac

mkdir -p "$build_dir" "$output_dir"
app_dir="$build_dir/GPUCheck.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
if [[ ! -f "$project_dir/Resources/AppIcon.icns" ]]; then
  echo "Missing Resources/AppIcon.icns; finish generating the application icon first." >&2
  exit 1
fi
cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"

sources=()
for source_file in "$project_dir"/Sources/*.swift; do
  case "$(basename "$source_file")" in
    AskPass.swift|Smoke*.swift|*Tests.swift) ;;
    *) sources+=("$source_file") ;;
  esac
done
if [[ ${#sources[@]} -eq 0 ]]; then
  echo "No application Swift sources found." >&2
  exit 1
fi

sdk_dir="${GPUCHECK_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
# Some Command Line Tools installations ship a preview SDK without the SwiftUI
# macro plugins supplied by full Xcode. The stable SDK needs no such plugins.
stable_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [[ -z "${GPUCHECK_SDK_PATH:-}" && -d "$stable_sdk" ]]; then
  sdk_dir="$stable_sdk"
fi
app_slices=()
askpass_slices=()
for arch in "${architectures[@]}"; do
  echo "Building GPUCheck for $arch (macOS 14+)"
  slice_dir="$build_dir/$arch"
  mkdir -p "$slice_dir"
  xcrun swiftc -parse-as-library -swift-version 5 -O \
    -sdk "$sdk_dir" -target "$arch-apple-macosx14.0" \
    -framework SwiftUI -framework Charts -framework AppKit -framework Security \
    -lsqlite3 "${sources[@]}" -o "$slice_dir/GPUCheck"
  xcrun swiftc -swift-version 5 -O \
    -sdk "$sdk_dir" -target "$arch-apple-macosx14.0" \
    -framework Security "$project_dir/Sources/AskPass.swift" \
    -o "$slice_dir/GPUCheckAskPass"
  app_slices+=("$slice_dir/GPUCheck")
  askpass_slices+=("$slice_dir/GPUCheckAskPass")
done
if [[ ${#architectures[@]} -gt 1 ]]; then
  xcrun lipo -create "${app_slices[@]}" -output "$app_dir/Contents/MacOS/GPUCheck"
  xcrun lipo -create "${askpass_slices[@]}" -output "$app_dir/Contents/MacOS/GPUCheckAskPass"
else
  cp "${app_slices[0]}" "$app_dir/Contents/MacOS/GPUCheck"
  cp "${askpass_slices[0]}" "$app_dir/Contents/MacOS/GPUCheckAskPass"
fi
chmod 755 "$app_dir/Contents/MacOS/GPUCheck" "$app_dir/Contents/MacOS/GPUCheckAskPass"
printf 'APPL????' > "$app_dir/Contents/PkgInfo"

# Local ad-hoc signatures provide integrity verification. Distribution with a
# Developer ID and notarization can replace these when credentials are available.
codesign --force --sign - "$app_dir/Contents/MacOS/GPUCheckAskPass"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
plutil -lint "$app_dir/Contents/Info.plist"
file "$app_dir/Contents/MacOS/GPUCheck"

if [[ "$create_dmg" -eq 1 ]]; then
  stage_dir="$build_dir/dmg-stage"
  rm -rf "$stage_dir"
  mkdir -p "$stage_dir"
  ditto "$app_dir" "$stage_dir/GPUCheck.app"
  ln -s /Applications "$stage_dir/Applications"
  if [[ -f "$output_dir/使用说明.txt" ]]; then
    cp "$output_dir/使用说明.txt" "$stage_dir/使用说明.txt"
  fi
  hdiutil create -volname GPUCheck -srcfolder "$stage_dir" -ov \
    -format UDZO -imagekey zlib-level=9 "$output_dir/GPUCheck.dmg"
  hdiutil verify "$output_dir/GPUCheck.dmg"
  (cd "$output_dir" && shasum -a 256 GPUCheck.dmg > GPUCheck.dmg.sha256)
  echo "Created $output_dir/GPUCheck.dmg"
fi
