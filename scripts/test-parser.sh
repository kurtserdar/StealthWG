#!/usr/bin/env bash
#
# Runs the StealthProfile parser tests. The parser is pure Foundation, so it is
# compiled and run directly with swiftc — no Xcode target or simulator needed
# (the packet tunnel extension is device-only, so it can't host an XCTest bundle).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$(mktemp -d)/parsertest"

swiftc -o "$BIN" \
    "$ROOT/Shared/StealthProfile.swift" \
    "$ROOT/Shared/StealthFallback.swift" \
    "$ROOT/Shared/RuntimeStats.swift" \
    "$ROOT/Shared/ProfileSummary.swift" \
    "$ROOT/Shared/ProfileDraft.swift" \
    "$ROOT/Shared/LogEntry.swift" \
    "$ROOT/Shared/LogRingBuffer.swift" \
    "$ROOT/Shared/ConnectionDiagnostics.swift" \
    "$ROOT/Shared/OnDemandRules.swift" \
    "$ROOT/Shared/WidgetSnapshot.swift" \
    "$ROOT/Tests/StealthProfileTests.swift"

"$BIN"
