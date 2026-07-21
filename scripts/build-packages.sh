#!/usr/bin/env bash
#
# Build the StealthWG server binary for each target and produce .deb/.rpm/.apk
# packages (amd64 + arm64) plus raw cross-compiled binaries for other OSes.
# Requires: go, nfpm (go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
VERSION="${VERSION:-0.1.0}"
rm -rf "$DIST"
mkdir -p "$DIST"

build_bin() { # goos goarch out
  echo ">> build $1/$2"
  ( cd "$ROOT/gateway" && GOOS="$1" GOARCH="$2" CGO_ENABLED=0 \
      go build -trimpath -ldflags "-s -w" -o "$3" ./cmd/stealthwg )
}

# Linux packages (deb/rpm/apk) for amd64 + arm64. nfpm globs contents.src before
# env expansion, so we build to a fixed dist/stealthwg the config points at, and
# vary only arch/version via env (nfpm expands those non-glob fields).
for pair in amd64 arm64; do
  build_bin linux "$pair" "$DIST/stealthwg"
  export ARCH="$pair" VERSION
  for fmt in deb rpm apk; do
    echo ">> package $fmt $pair"
    ( cd "$ROOT" && nfpm package -f packaging/nfpm.yaml -p "$fmt" -t "$DIST" )
  done
done
rm -f "$DIST/stealthwg"

# Raw binaries for other OSes (the server engine is Linux; these are best-effort).
for target in darwin/amd64 darwin/arm64 freebsd/amd64; do
  os="${target%/*}"; arch="${target#*/}"
  build_bin "$os" "$arch" "$DIST/stealthwg-$os-$arch" || echo "   (skipped $target)"
done

# The CLI client (userspace WireGuard + masking; connects to a server) for Linux and
# Windows, amd64 + arm64. The Windows exe also needs the matching wintun.dll at
# runtime — fetch it with scripts/fetch-wintun.sh.
build_client() { # goos goarch out
  echo ">> build client $1/$2"
  ( cd "$ROOT/gateway" && GOOS="$1" GOARCH="$2" CGO_ENABLED=0 \
      go build -trimpath -ldflags "-s -w" -o "$3" ./cmd/stealthwg-client )
}
for arch in amd64 arm64; do
  build_client linux   "$arch" "$DIST/stealthwg-client-linux-$arch"
  build_client windows "$arch" "$DIST/stealthwg-client-windows-$arch.exe"
done

echo
echo "Artifacts in $DIST:"
ls -1 "$DIST"
