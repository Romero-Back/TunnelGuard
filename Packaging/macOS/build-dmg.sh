#!/bin/sh
set -eu

app=$1
image=$2
/usr/bin/codesign --verify --strict "$app"

staging=$(mktemp -d "${TMPDIR:-/tmp}/tunnelguard-dmg.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT
/usr/bin/ditto "$app" "$staging/TunnelGuard.app"
/bin/ln -s /Applications "$staging/Applications"

/usr/bin/hdiutil create -volname TunnelGuard -fs HFS+ -format UDZO -srcfolder "$staging" "$image"
/usr/bin/hdiutil verify "$image"
