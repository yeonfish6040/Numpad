#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# A public release uses a Developer ID Application identity and a stored
# notarytool profile. Without these, the output is for local testing only.
if [[ -n "${NOTARY_PROFILE:-}" && -z "${SIGN_IDENTITY:-}" ]]; then
    echo "SIGN_IDENTITY is required for notarization." >&2
    exit 1
fi
if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "Use the full Developer ID Application identity name." >&2
    exit 1
fi

export UNIVERSAL=1
bash scripts/build-app.sh
version="$(cat VERSION)"
bundle="$PWD/dist/Numpad.app"
image="$PWD/dist/Numpad-$version-universal.dmg"
staging="$(mktemp -d "${TMPDIR:-/tmp}/numpad-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --keepParent "$bundle" "$staging/Numpad.zip"
    xcrun notarytool submit "$staging/Numpad.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$bundle"
    xcrun stapler validate "$bundle"
fi

mkdir "$staging/volume"
ditto "$bundle" "$staging/volume/Numpad.app"
ln -s /Applications "$staging/volume/Applications"
hdiutil create -volname Numpad -srcfolder "$staging/volume" -format UDZO -ov "$image"

# Some macOS versions leave the image creation device attached. Release only
# devices belonging to this output image before signing or notarizing it.
devices="$(hdiutil info -plist | /usr/bin/python3 -c '
import os, plistlib, sys
target = os.path.realpath(sys.argv[1])
for item in plistlib.loads(sys.stdin.buffer.read()).get("images", []):
    if os.path.realpath(item.get("image-path", "")) == target:
        for entity in item.get("system-entities", []):
            if entity.get("dev-entry"):
                print(entity["dev-entry"])
                break
' "$image")"
while IFS= read -r device; do
    if [[ -n "$device" ]]; then hdiutil detach "$device"; fi
done <<< "$devices"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$image"
    codesign --verify --strict "$image"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    # Apple processes nested containers and issues a ticket for the signed DMG.
    # Submitting a ZIP also avoids local DMG preflight stalls in notarytool.
    ditto -c -k --keepParent "$image" "$staging/Numpad-dmg.zip"
    xcrun notarytool submit "$staging/Numpad-dmg.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$image"
    xcrun stapler validate "$image"
    spctl --assess --type execute --verbose=2 "$bundle"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
else
    echo "Local test build: not notarized. Do not publish as a notarized release." >&2
fi

(cd dist && shasum -a 256 "Numpad-$version-universal.dmg" > "Numpad-$version-SHA256SUMS.txt")
printf '\nDMG: %s\n' "$image"
