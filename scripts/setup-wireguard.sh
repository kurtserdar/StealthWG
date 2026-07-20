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
    # Idempotency for a stack of patches where later ones edit the same files as
    # earlier ones (0003 overlaps 0002): a plain reverse-check on the lower patch
    # fails once a higher patch sits on top of it. So decide by both directions:
    #   reverse-check succeeds        -> cleanly present, skip
    #   else forward-check succeeds   -> not present, apply
    #   else (neither)                -> already present under a higher patch, skip
    if git -C "$SUBMODULE" apply --reverse --check "$patch" 2>/dev/null; then
        echo "    already applied: $name"
    elif git -C "$SUBMODULE" apply --check "$patch" 2>/dev/null; then
        git -C "$SUBMODULE" apply "$patch"
        echo "    applied: $name"
    else
        echo "    already applied (stacked): $name"
    fi
done

echo "==> wireguard-apple is ready"
