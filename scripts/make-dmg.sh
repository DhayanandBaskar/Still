#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" != "--skip-build" ]; then
  ./scripts/build.sh
fi

build_dir="${STILL_BUILD_DIR:-$PWD/build}"
build_dir="$(cd "$build_dir" && pwd)"
app_path="$build_dir/Still.app"
release_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
release_arch=$(uname -m)
disk_image="$build_dir/Still-$release_version-$release_arch.dmg"
staging_path=$(mktemp -d "${TMPDIR:-/tmp/}still-dmg.XXXXXX")
trap 'rm -rf "$staging_path"' EXIT

codesign --verify --deep --strict "$app_path"
ditto "$app_path" "$staging_path/Still.app"
cp LICENSE NOTICE "$staging_path/"
ln -s /Applications "$staging_path/Applications"
hdiutil create -volname "Still $release_version" -srcfolder "$staging_path" \
  -fs HFS+ -format UDZO -ov "$disk_image"
hdiutil verify "$disk_image"
(cd "$build_dir" && shasum -a 256 "$(basename "$disk_image")" > "$(basename "$disk_image").sha256")
printf 'Packaged %s\n' "$disk_image"
