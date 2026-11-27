#!/bin/sh
set -eu

packaging_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$packaging_dir/../.."

swift build "$@" --product TunnelGuardApp >&2
bin_dir=$(swift build "$@" --show-bin-path)
app="$bin_dir/TunnelGuard.app"
resources="$app/Contents/Resources"

mkdir -p "$app/Contents/MacOS" "$resources/Scripts"
install -m 644 "$packaging_dir/TunnelGuard-Info.plist" "$app/Contents/Info.plist"
install -m 755 "$bin_dir/TunnelGuardApp" "$app/Contents/MacOS/TunnelGuardApp"
install -m 644 Scripts/tunnelguard-run.py Scripts/tunnelguard-native.py Scripts/tunnelguard-control.py "$resources/Scripts/"
install -m 644 "$packaging_dir/install-native-filter.sh" "$packaging_dir/refresh-native-pf.sh" "$resources/Scripts/"

if [ -n "${TUNNELGUARD_PYINSTALLER_PYTHON:-}" ]; then
    sh "$packaging_dir/bundle-launcher.sh" "$resources/NativeLauncher"
fi

icon_dir=$(mktemp -d "${TMPDIR:-/tmp}/tunnelguard-icon.XXXXXX")
trap 'rm -rf -- "$icon_dir"' EXIT
mkdir "$icon_dir/TunnelGuard.iconset"
swift "$packaging_dir/make-icon.swift" "$icon_dir/icon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_dir/icon.png" --out "$icon_dir/TunnelGuard.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$icon_dir/icon.png" --out "$icon_dir/TunnelGuard.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_dir/TunnelGuard.iconset" -o "$resources/TunnelGuard.icns"
codesign --force --sign - "$app" >&2

printf '%s\n' "$app"
