#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
source_files=("$project_dir"/macos-app/Sources/*.swift)
info_plist="$project_dir/macos-app/Info.plist"
html_file="$project_dir/stock-dashboard.html"
core_script="$project_dir/web/dashboard-core.js"
dist_dir="$project_dir/dist"
app_path="$dist_dir/看盘面板.app"
mkdir -p "$dist_dir"
build_dir="$(mktemp -d "$dist_dir/.dashboard-build.XXXXXX")"
staged_app="$build_dir/看盘面板.app"

cleanup() {
  rm -rf -- "$build_dir"
}
trap cleanup EXIT

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"

xcrun swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework CryptoKit \
  -framework Network \
  "${source_files[@]}" \
  -o "$staged_app/Contents/MacOS/DashboardApp"

cp "$info_plist" "$staged_app/Contents/Info.plist"
cp "$html_file" "$staged_app/Contents/Resources/stock-dashboard.html"
cp "$core_script" "$staged_app/Contents/Resources/dashboard-core.js"
codesign --force --deep --sign - "$staged_app"

binary="$staged_app/Contents/MacOS/DashboardApp"
architectures="$(lipo -archs "$binary")"
[[ "$architectures" == "arm64" ]] || { echo "Unexpected architectures: $architectures" >&2; exit 1; }
minimum_system="$(vtool -show-build "$binary" | awk '/minos/{print $2; exit}')"
[[ "$minimum_system" == "13.0" ]] || { echo "Unexpected deployment target: $minimum_system" >&2; exit 1; }
codesign --verify --deep --strict "$staged_app"

if [[ -e "$app_path" ]]; then
  rm -rf -- "$app_path"
fi
mv "$staged_app" "$app_path"

echo "$app_path"
