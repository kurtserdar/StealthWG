#!/usr/bin/env bash
#
# Builds and pushes the StealthWG container images to GHCR, multi-arch
# (linux/amd64 + linux/arm64):
#   - ghcr.io/<owner>/stealthwg-gateway   (the relay)
#   - ghcr.io/<owner>/stealthwg-allinone  (userspace all-in-one server)
#
# Prereqs: `docker login ghcr.io -u <owner>` with a token that has write:packages.
# Usage:   ./scripts/publish-images.sh [VERSION]     # e.g. 0.2.0 (also tags :latest)
set -euo pipefail

OWNER="${OWNER:-kurtserdar}"
REGISTRY="ghcr.io/${OWNER}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
VERSION="${1:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tag_args() { # <image>
    printf -- '-t %s/%s:latest ' "$REGISTRY" "$1"
    [ -n "$VERSION" ] && printf -- '-t %s/%s:%s ' "$REGISTRY" "$1" "$VERSION"
}

echo "==> Publishing to ${REGISTRY} (${PLATFORMS})${VERSION:+, version ${VERSION}}"

echo "==> stealthwg-gateway (relay)"
docker buildx build --platform "$PLATFORMS" -f "$ROOT/Dockerfile" \
    $(tag_args stealthwg-gateway) --push "$ROOT"

echo "==> stealthwg-allinone (all-in-one server)"
docker buildx build --platform "$PLATFORMS" -f "$ROOT/deploy/standalone/allinone/Dockerfile" \
    $(tag_args stealthwg-allinone) --push "$ROOT"

echo "==> Done. On a first publish, make each package public:"
echo "    GitHub → your profile → Packages → <image> → Package settings → Change visibility → Public."
