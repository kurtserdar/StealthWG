#!/usr/bin/env bash
#
# Downloads the official Wintun driver and extracts the amd64 + arm64 wintun.dll
# (the userspace TUN the Windows client loads at runtime). MIT-licensed, from
# https://www.wintun.net.
set -euo pipefail

VERSION="${WINTUN_VERSION:-0.14.1}"
DEST="${1:-dist/wintun}"
URL="https://www.wintun.net/builds/wintun-${VERSION}.zip"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> Downloading $URL"
curl -fsSL "$URL" -o "$tmp/wintun.zip"
unzip -q "$tmp/wintun.zip" -d "$tmp"

mkdir -p "$DEST/amd64" "$DEST/arm64"
cp "$tmp/wintun/bin/amd64/wintun.dll" "$DEST/amd64/wintun.dll"
cp "$tmp/wintun/bin/arm64/wintun.dll" "$DEST/arm64/wintun.dll"

echo "==> wintun.dll placed in $DEST/{amd64,arm64}"
echo "    Ship the matching-arch wintun.dll next to stealthwg-client.exe."
