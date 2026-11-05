#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
./scripts/swift.sh build -c release "$@"
binary_dir="$(./scripts/swift.sh build -c release --show-bin-path "$@")"
app_dir="$project_dir/dist/Codex Limits.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/CodexLimitsWidget" "$app_dir/Contents/MacOS/CodexLimitsWidget"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app_dir"
echo "Готово: $app_dir"
echo "Запуск: open \"$app_dir\""
