#!/bin/sh
set -eu

packaging_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$packaging_dir/../.."

swift build "$@" >&2
bin_dir=$(swift build "$@" --show-bin-path)
output=$(mktemp -d "$bin_dir/tunnelguard-lab.XXXXXX")
app="$output/TunnelGuardLab.app"
extension_id=$(plutil -extract CFBundleIdentifier raw -o - "$packaging_dir/FilterProbe-Info.plist")
extension="$app/Contents/Library/SystemExtensions/$extension_id.systemextension"

mkdir -p "$app/Contents/MacOS" "$extension/Contents/MacOS"
cp "$packaging_dir/LabHost-Info.plist" "$app/Contents/Info.plist"
cp "$packaging_dir/FilterProbe-Info.plist" "$extension/Contents/Info.plist"
install -m 755 "$bin_dir/TunnelGuardLab" "$app/Contents/MacOS/TunnelGuardLab"
install -m 755 "$bin_dir/TunnelGuardFilterProbe" "$extension/Contents/MacOS/TunnelGuardFilterProbe"
probe="$output/tunnelguard-network-probe"
install -m 755 "$bin_dir/tunnelguard-network-probe" "$probe"
codesign --force --sign - --identifier app.tunnelguard.lab.networkprobe "$probe" >&2

printf '%s\n' "$output"
