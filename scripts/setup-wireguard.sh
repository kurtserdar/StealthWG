#!/usr/bin/env bash
#
# Initializes the pinned wireguard-apple submodule and applies StealthWG's
# patches to it. Idempotent: safe to run repeatedly. Run once after cloning
# (and after any `git submodule update` that resets the submodule working tree).
#
# The patches are the accepted, minimal cost of production obfuscated WireGuard:
# they keep the vendored engine building on current Xcode and (later) inject the
# masking bind. See docs/design/2026-07-18-ios-production-integration.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBMODULE="$REPO_ROOT/ThirdParty/wireguard-apple"
PATCH_DIR="$REPO_ROOT/patches/wireguard-apple"

echo "==> Initializing wireguard-apple submodule (pinned)"
git -C "$REPO_ROOT" submodule update --init ThirdParty/wireguard-apple

echo "==> Applying patches"
for patch in "$PATCH_DIR"/*.patch; do
    name="$(basename "$patch")"
    # If the patch can be reverse-applied, it is already present — skip it.
    if git -C "$SUBMODULE" apply --reverse --check "$patch" 2>/dev/null; then
        echo "    already applied: $name"
    else
        git -C "$SUBMODULE" apply "$patch"
        echo "    applied: $name"
    fi
done

echo "==> wireguard-apple is ready"
