# iOS QR import + export — design

**Date:** 2026-07-19
**Status:** Approved, ready for implementation planning

## Goal

Let a StealthWG profile move in and out of the iOS app as a QR code:

- **Import:** scan a QR (e.g. the one the standalone bundle prints in its logs)
  and configure the tunnel from it — closing the loop with the server-side QR the
  `deploy/standalone` bundle already emits.
- **Export:** render the app's current profile as a QR to move it to another
  device.

Today import is paste-only (`TextEditor` + "Import profile"), and the app stores
no raw profile text — only the split `wgQuickConfig` + `maskKey` in the tunnel's
`providerConfiguration`.

## Background (current code)

- `Shared/StealthProfile.swift` — `StealthProfile.parse(_ raw:)` splits a raw
  profile into `wgQuickConfig` (wg-quick config with the `[Stealth]` section
  removed) and optional `maskKey` (base64 PSK from `[Stealth] MaskKey`).
- `App/TunnelManager.swift` — `importProfile(_ raw:)` parses and saves to
  `providerConfiguration` (`wgQuickConfig`, `maskKey`).
- `App/ContentView.swift` — paste editor + Import/Connect buttons.
- `project.yml` — app target uses `GENERATE_INFOPLIST_FILE: YES` with
  `INFOPLIST_KEY_*` settings; there is no standalone app `Info.plist`.

The QR payload is exactly the raw StealthWG profile text (wg-quick config plus a
`[Stealth]` section). This is a StealthWG-specific superset of a standard
WireGuard QR — standard WG apps are not a target consumer.

## Architecture

### Import (scan)

- `App/QRScannerView.swift` — a SwiftUI `UIViewControllerRepresentable`
  wrapping an `AVCaptureSession` with `AVCaptureMetadataOutput` filtering
  `.qr`. On the first decoded string it invokes a callback and stops the
  session.
- `ContentView` gains a **Scan QR** button that presents the scanner in a sheet.
  On a decoded payload, the sheet dismisses and the payload is passed straight to
  the existing `TunnelManager.importProfile(_:)` — no change to the parse/save
  path. Parse failures surface through the existing `lastError` mechanism.
- Camera permission: add `INFOPLIST_KEY_NSCameraUsageDescription` to the app
  target in `project.yml`. The scanner handles denied permission and the
  no-camera case (Simulator) by reporting a readable message rather than crashing.

### Export (show)

- `StealthProfile.serialize()` reconstructs the raw profile text:
  `wgQuickConfig`, and when `maskKey` is present, a trailing
  `\n\n[Stealth]\nMaskKey = <key>` section. This is the inverse of `parse` and is
  covered by a round-trip test (`parse(serialize(x)) == x`). It keeps the split
  fields as the single source of truth — no duplicate raw string is stored.
- `TunnelManager` exposes the current profile's raw text, reconstructed from
  `providerConfiguration` via `StealthProfile(wgQuickConfig:maskKey:).serialize()`
  (e.g. `currentProfileText() -> String?`, nil when no profile is present).
- `App/QRCodeView.swift` — generates a QR `UIImage` from a string using
  CoreImage's `CIFilter.qrCodeGenerator` (no camera; works in the Simulator),
  presented as a SwiftUI `Image`.
- `ContentView` gains a **Show QR** button (enabled only when `hasProfile`) that
  presents `QRCodeView` for `currentProfileText()` in a sheet.

## Data flow

```
bundle log QR ──scan──▶ QRScannerView ──string──▶ TunnelManager.importProfile ──▶ providerConfiguration
providerConfiguration ──▶ StealthProfile.serialize() ──string──▶ QRCodeView ──▶ QR image ──show──▶ other device
```

## Files

- Modify: `Shared/StealthProfile.swift` — add `serialize()` and a memberwise-usable
  init (already synthesized) for reconstruction.
- Create: `App/QRScannerView.swift` — camera scanner.
- Create: `App/QRCodeView.swift` — QR image generator + view.
- Modify: `App/ContentView.swift` — Scan QR / Show QR buttons + sheets.
- Modify: `App/TunnelManager.swift` — `currentProfileText()` reconstruction.
- Modify: `project.yml` — `INFOPLIST_KEY_NSCameraUsageDescription`.
- Modify: `scripts/test-parser.sh` — add `serialize()` + round-trip checks.

## Testing

- `StealthProfile.serialize()` and the `parse(serialize(x)) == x` round-trip are
  unit-tested in `scripts/test-parser.sh` (swiftc-compiled checks, matching the
  existing 12-check harness — the packet extension does not build for the
  Simulator, so XCTest is not used here).
- Camera scanning and QR rendering are device/Simulator UI concerns and are not
  unit-tested. They are verified by an unsigned device build
  (`xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO`), the project's autonomous
  verification ceiling. Live camera capture is validated on the user's physical
  iPhone.

## Non-goals (YAGNI)

- No multi-profile gallery/management.
- No password/encryption on the QR.
- No standard-WireGuard-compatible QR variant (our payload is a `[Stealth]`
  superset, consumed only by StealthWG).
- Export is a "show QR on screen" only — no saving a QR image to Photos/sharing
  sheet in this iteration.

## Security notes

- The QR encodes the full profile including the private key and the mask PSK.
  Treat a displayed/exported QR as sensitive (same sensitivity as the `.conf`).
  No new persistence is introduced; the profile continues to live only in
  `providerConfiguration`.
