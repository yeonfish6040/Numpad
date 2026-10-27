#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-$(cat VERSION)}"
image="$PWD/dist/Numpad-$version-universal.dmg"
feed="$PWD/appcast.xml"
release_url="https://github.com/yeonfish6040/Numpad/releases/tag/v$version"
asset_url="https://github.com/yeonfish6040/Numpad/releases/download/v$version/Numpad-$version-universal.dmg"
sign_tool="$PWD/.build/artifacts/sparkle/Sparkle/bin/sign_update"

if [[ ! -f "$image" ]]; then
    echo "Missing release DMG: $image" >&2
    exit 1
fi
if [[ ! -x "$sign_tool" ]]; then
    echo "Resolve Swift packages before signing updates: swift package resolve" >&2
    exit 1
fi
signature="$("$sign_tool" -p "$image")"
length="$(stat -f %z "$image")"

VERSION="$version" RELEASE_URL="$release_url" ASSET_URL="$asset_url" SIGNATURE="$signature" LENGTH="$length" python3 - "$feed" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", sparkle)
version = os.environ["VERSION"]
feed = Path(sys.argv[1])
if feed.exists():
    tree = ET.parse(feed)
    root = tree.getroot()
    channel = root.find("channel")
    if channel is None:
        raise SystemExit("appcast.xml has no RSS channel")
else:
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Numpad Updates"
    ET.SubElement(channel, "link").text = "https://github.com/yeonfish6040/Numpad/releases"
    ET.SubElement(channel, "description").text = "Numpad for macOS updates"
    tree = ET.ElementTree(root)

existing_items = list(channel.findall("item"))
for existing in list(existing_items):
    item_version = existing.find(f"{{{sparkle}}}version")
    if item_version is not None and item_version.text == version:
        channel.remove(existing)
        existing_items.remove(existing)

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Numpad {version}"
ET.SubElement(item, "link").text = os.environ["RELEASE_URL"]
ET.SubElement(item, f"{{{sparkle}}}releaseNotesLink").text = os.environ["RELEASE_URL"]
ET.SubElement(item, f"{{{sparkle}}}version").text = version
ET.SubElement(item, f"{{{sparkle}}}shortVersionString").text = version
ET.SubElement(item, f"{{{sparkle}}}minimumSystemVersion").text = "13.0"
ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc), usegmt=True)
ET.SubElement(item, "enclosure", {
    "url": os.environ["ASSET_URL"],
    "length": os.environ["LENGTH"],
    "type": "application/octet-stream",
    f"{{{sparkle}}}edSignature": os.environ["SIGNATURE"],
})
metadata = [child for child in list(channel) if child.tag != "item"]
for child in list(channel):
    channel.remove(child)
for child in metadata:
    channel.append(child)
channel.append(item)
for existing in existing_items:
    channel.append(existing)
ET.indent(tree, space="  ")
tree.write(feed, encoding="utf-8", xml_declaration=True)
PY
printf 'Updated %s for release %s\n' "$feed" "$version"
