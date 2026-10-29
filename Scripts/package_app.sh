#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
configuration="${1:-release}"
app_dir="$project_root/dist/OrbitDisk.app"

cd "$project_root"
swift build -c "$configuration"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_root/.build/$configuration/OrbitDisk" "$app_dir/Contents/MacOS/OrbitDisk"
cp "$project_root/Packaging/Info.plist" "$app_dir/Contents/Info.plist"
chmod +x "$app_dir/Contents/MacOS/OrbitDisk"

echo "$app_dir"
