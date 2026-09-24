#!/bin/bash
# Builds build/Untranslate.app (Apple silicon + Intel) and build/Untranslate.dmg for a release.
set -euo pipefail
cd "$(dirname "$0")/.."

flags=(-c release --product Untranslate --arch arm64 --arch x86_64)
swift build "${flags[@]}"

app=build/Untranslate.app
rm -rf build && mkdir -p "$app/Contents/MacOS"
cp "$(swift build "${flags[@]}" --show-bin-path)/Untranslate" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
# Sign with a stable identity if there is one, so macOS keeps its permissions across rebuilds.
# Without it (ad-hoc), every build counts as a new app and asks to control Music again.
identity="${SIGN_IDENTITY:-Untranslate Developer}"
# (A self-signed certificate shows as "not trusted" here, which is fine for signing.)
if security find-identity -p codesigning | grep -q "\"$identity\""; then
  codesign --force --sign "$identity" "$app"
else
  codesign --force --sign - "$app"  # ad-hoc: first launch needs "Open Anyway"
fi

# Disk image with the app next to an Applications shortcut, so installing is one drag.
mkdir -p build/dmg && cp -R "$app" build/dmg/ && ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname Untranslate -srcfolder build/dmg -ov -format UDZO build/Untranslate.dmg
rm -rf build/dmg
echo "Built $app"
