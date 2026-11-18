#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build --configuration release --arch arm64 --arch x86_64
bin_dir=$(swift build --configuration release --arch arm64 --arch x86_64 --show-bin-path)
app_dir="$PWD/dist/ClaudeMeter.app"

mkdir -p "$app_dir/Contents/MacOS"
install -m 755 "$bin_dir/ClaudeMeter" "$app_dir/Contents/MacOS/ClaudeMeter"
install -m 644 Resources/Info.plist "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"

printf 'Собрано %s\n' "$app_dir"
