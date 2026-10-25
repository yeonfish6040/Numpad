#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(cat VERSION)"
build_args=(-c release)
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
bundle="$PWD/dist/Numpad.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp LICENSE "$bundle/Contents/Resources/LICENSE"
cp "$binary_dir/TrackpadNumpad" "$bundle/Contents/MacOS/TrackpadNumpad"
for resource in "$binary_dir"/*.bundle; do
    if [[ -d "$resource" ]]; then
        ditto "$resource" "$bundle/Contents/Resources/$(basename "$resource")"
    fi
done
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>Numpad</string>
    <key>CFBundleDisplayName</key><string>Numpad</string>
    <key>CFBundleIdentifier</key><string>com.yftech.TrackpadNumpad</string>
    <key>CFBundleExecutable</key><string>TrackpadNumpad</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.4</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAccessibilityUsageDescription</key><string>Numpad controls pointer input and sends numeric keypad events to the focused app while keypad mode is active.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$bundle/Contents/Info.plist"

swift scripts/MakeIcon.swift "$PWD/dist/AppIcon.iconset"
iconutil -c icns "$PWD/dist/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --identifier com.yftech.TrackpadNumpad "$bundle"
else
    codesign --force --sign - --identifier com.yftech.TrackpadNumpad "$bundle"
fi
codesign --verify --strict "$bundle"
"$bundle/Contents/MacOS/TrackpadNumpad" --check-localization
printf '\nApp: %s\n' "$bundle"
