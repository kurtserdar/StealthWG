# macOS app — Phase 1 (compiling skeleton) — design

**Date:** 2026-07-19
**Status:** Approved, ready for implementation planning

## Goal

Stand up a native macOS StealthWG target that **compiles**: a menu-bar app
(`MenuBarExtra`) plus a packet-tunnel **System Extension**, reusing the shared
logic and (adapted) SwiftUI views and building the wireguard-go bridge for
darwin. Phase 1 ends at a green unsigned macOS build. Signing, notarization,
System-Extension approval, and the networking entitlement are Phase 2 (the user's
Apple account).

Chosen: **System Extension** distribution, **menu-bar** UI.

## Background (current code)

- `project.yml` — iOS app `StealthWG` (sources `App` + `Shared`) + `PacketTunnel`
  app-extension (sources `Tunnel` + `Shared`, Go bridge build phase, StealthBridge
  header). `DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM)`, config in `Config.xcconfig`.
- Go bridge `Makefile` supports darwin (`GOOS_macosx := darwin`, `PLATFORM_NAME ?=
  macosx`). `WireGuardKit` Package supports `.macOS(.v12)` + `.iOS(.v15)`.
- `Shared/` (StealthProfile, StealthFallback, RuntimeStats, ProfileSummary,
  ProfileDraft, TunnelConstants) is pure and cross-platform.
- `App/TunnelManager.swift` uses NetworkExtension (`NETunnelProviderManager`,
  `NETunnelProviderSession`) — cross-platform.
- iOS-only pieces: `App/StealthWGApp.swift` (WindowGroup), `App/ContentView.swift`
  (iOS root), `App/LaunchScreen.storyboard`, `App/Assets.xcassets` (iOS icons),
  `App/QRScannerView.swift` (AVFoundation camera, UIKit).
- View iOS-only APIs to adapt: `UIPasteboard`, `UIImage`, `navigationBarTitleDisplayMode`,
  `textInputAutocapitalization`, camera scanning.

## Architecture

### New targets (`project.yml`)

- `options.deploymentTarget.macOS: "13.0"` (MenuBarExtra needs 13).
- **StealthWG-mac** (`type: application`, `platform: macOS`): the menu-bar app.
  Sources: `Shared`, `macOS`, and the cross-platform UI files (`App/Views`,
  `App/TunnelManager.swift`, `App/Theme.swift`, `App/QRCodeView.swift`,
  `App/Platform.swift`). Depends on `PacketTunnel-mac` (embed). Bundle id
  `com.stealthwg`.
- **PacketTunnel-mac** (`type: system-extension`, `platform: macOS`): the tunnel.
  Sources: `Tunnel`, `Shared`. Same StealthBridge header + a darwin Go-bridge
  build phase. Bundle id `com.stealthwg.tunnel`. If XcodeGen lacks a
  `system-extension` shortcut, set `PRODUCT_TYPE=com.apple.product-type.system-extension`
  explicitly.

The iOS targets are unchanged; the mac app deliberately does **not** include the
iOS shell (`StealthWGApp`, `ContentView`, LaunchScreen, iOS Assets, QRScannerView).

### Cross-platform view adaptation

Introduce `App/Platform.swift` (compiled into both apps, not the tunnel):

```swift
#if os(iOS)
typealias PlatformImage = UIImage
#elseif os(macOS)
typealias PlatformImage = NSImage
#endif
enum Clipboard { static func copy(_ s: String) }   // UIPasteboard / NSPasteboard
extension View { func inlineNavTitle() -> some View }  // .inline on iOS, no-op on macOS
```

- `QRCodeView` returns a `PlatformImage` and displays via `Image(nsImage:)`/`Image(uiImage:)`.
- `ProfileFormView` uses `Clipboard.copy` for the public key.
- Views replace `.navigationBarTitleDisplayMode(.inline)` with `.inlineNavTitle()`
  and drop `.textInputAutocapitalization` behind `#if os(iOS)`.
- `AddProfileView` wraps the **Scan QR** row + scanner sheet in `#if os(iOS)`
  (macOS keeps Paste / Import file / Create from scratch). `QRScannerView` stays
  iOS-only (excluded from the mac target).

### macOS shell (`macOS/`)

- `StealthWGMacApp.swift` — `@main` with a `MenuBarExtra` (a wraith SF Symbol /
  status tint) whose content is `MacMenuView`, plus a `Window("StealthWG")`
  management scene hosting profile add/detail. Uses `.menuBarExtraStyle(.window)`.
- `MacMenuView.swift` — compact panel: status label, a Connect/Disconnect button,
  active endpoint + throughput when connected (reuses `TunnelManager`), and
  buttons to open the management window and quit.
- `SystemExtensionManager.swift` — `OSSystemExtensionRequest` activation request
  (`activationRequestForExtension(_:queue:)`) with a delegate; wired to an
  "Enable extension" action. Compiles now; actually activates only when signed.
- `macOS/StealthWG-mac.entitlements`, `macOS/Assets.xcassets` (app icon from
  `branding/icon-macos.svg`), `Tunnel/PacketTunnel-mac.entitlements`.

## Data flow

Same as iOS: `MacMenuView`/management window ↔ `TunnelManager` ↔
`NETunnelProviderManager`/`Session` ↔ the System Extension
(`PacketTunnelProvider`, shared) ↔ WireGuard via the darwin Go bridge.

## Files

- Modify: `project.yml` (macOS deployment + two targets), and view files for
  cross-platform guards (`QRCodeView`, `ProfileFormView`, `AddProfileView`,
  `ProfileDetailView`, and any using iOS-only modifiers).
- Create: `App/Platform.swift`; `macOS/StealthWGMacApp.swift`,
  `macOS/MacMenuView.swift`, `macOS/SystemExtensionManager.swift`,
  `macOS/StealthWG-mac.entitlements`, `macOS/Assets.xcassets` (AppIcon);
  `Tunnel/PacketTunnel-mac.entitlements`.

## Testing

- Pure logic unchanged (`scripts/test-parser.sh` stays green).
- **Compile verification:** `xcodegen generate` then
  `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG-mac -sdk macosx -configuration Debug CODE_SIGNING_ALLOWED=NO build` → `BUILD SUCCEEDED` (mac app + System Extension + darwin Go bridge).
- The **iOS** build must still pass:
  `xcodebuild -scheme StealthWG -sdk iphoneos CODE_SIGNING_ALLOWED=NO build`.
- Actual VPN operation (extension activation, handshake) is **Phase 2**, validated
  on the user's Mac with signing/notarization.

## Non-goals (YAGNI — Phase 1)

- Real VPN operation on macOS (Phase 2: signing, notarization, System-Extension
  approval, networking entitlement).
- Menu-bar visual polish, Sparkle auto-update, login-item/launch-at-boot.
- Sharing the iOS launch screen (macOS has none).
- Camera QR scanning on macOS.

## Risks (resolved during implementation)

- XcodeGen `system-extension` type support (fallback: explicit PRODUCT_TYPE).
- Unsigned System-Extension build behaviour (may need `CODE_SIGNING_ALLOWED=NO`
  plus skipping the extension's embedding validation).
- Volume of `#if os()` view surgery (centralised in `App/Platform.swift` to limit
  scatter).

## Security notes

- No new secrets. macOS keeps the same privacy-by-design posture: keys/PSK live in
  `providerConfiguration`; the app-message channel returns only counters.
- System Extension requires explicit user approval in System Settings (Phase 2) —
  a deliberate macOS security gate, not something the app bypasses.
