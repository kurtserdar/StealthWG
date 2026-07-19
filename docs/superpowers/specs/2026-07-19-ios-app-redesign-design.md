# iOS app redesign — modern, full-information VPN client — design

**Date:** 2026-07-19
**Status:** Approved, ready for implementation planning

## Goal

Turn the test-bench UI (a paste box + buttons on one screen) into a modern,
easy-to-use VPN app that surfaces all the useful connection information: a hero
connect control with animated states, live throughput and handshake stats, the
active endpoint (with a fallback badge), masking status, and a clean
profile-setup/detail flow.

Scope decided: **restructure + visual polish + full live stats via app⇄extension
IPC** (the maximal option).

## Background (current code)

- `App/ContentView.swift` — one screen: status badge, a `TextEditor` paste box,
  Import/Scan QR/Show QR buttons, a Connect button, error text.
- `App/TunnelManager.swift` — `@MainActor` `ObservableObject`; `importProfile`,
  `connect`/`disconnect`, `currentProfileText`, `hasProfile`, `status`.
- `App/QRScannerView.swift`, `App/QRCodeView.swift` — QR import/export (reused).
- `Tunnel/PacketTunnelProvider.swift` — starts the tunnel; runs the endpoint
  fallback loop; holds `endpoints`/`currentIndex`.
- `Shared/StealthProfile.swift` (`endpoints`, `maskKey`), `Shared/StealthFallback.swift`
  (`lastHandshakeSeconds`, `FallbackPlan`).
- `WireGuardAdapter.getRuntimeConfiguration` returns UAPI text with `rx_bytes=`,
  `tx_bytes=`, `last_handshake_time_sec=` per peer. It lives in the **extension**.

## Architecture

### Screen structure

`ContentView` becomes a thin router:

- **No profile → empty state:** a friendly prompt and a prominent "Add profile"
  button opening the import sheet.
- **Profile present → ConnectionView** (the home/hero screen).

Views (all in `App/Views/`):

1. **ConnectionView** — the hero. A large animated connect control
   (`ConnectDial`), the status text, a profile chip at top (taps to
   `ProfileDetailView`), and — when connected — the `StatsView`.
2. **ConnectDial** — a circular tap-to-toggle control that animates across
   `NEVPNStatus` (disconnected/connecting/connected/disconnecting) with
   color + motion (idle neutral, connecting amber pulse, connected accent glow).
3. **StatsView** — cards for: connection duration (live), ↓ download rate+total,
   ↑ upload rate+total, last handshake ("Ns ago"), active endpoint (+ a
   "Fallback" badge when it is not the primary), and a "Masking ON" badge.
4. **ProfileSetupView** — the import sheet: "Paste" (TextEditor) and "Scan QR"
   (`QRScannerView`), validates + saves via `importProfile`.
5. **ProfileDetailView** — parsed profile summary (address, DNS, MTU, endpoints,
   peer public key (shortened), AllowedIPs, masking on/off) with actions: Show QR
   (`QRCodeView`), Replace (reopen setup), Delete.

`App/Theme.swift` centralises colors (dark-first, theme-aware) and the accent.

### Live stats via IPC

`getRuntimeConfiguration` is only reachable inside the extension, so the app asks
for it over the NE app-message channel.

- **Extension** (`PacketTunnelProvider`): override
  `handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?)`.
  On any request it calls `adapter.getRuntimeConfiguration` and replies with JSON:
  `{ "runtime": "<uapi text>", "activeEndpoint": "<host:port|null>", "isFallback": Bool }`.
  `activeEndpoint`/`isFallback` come from the fallback loop's `endpoints` +
  `currentIndex` (index > 0 ⇒ fallback).
- **App** (`TunnelManager`): while `status == .connected`, poll every ~1.5 s via
  `(manager.connection as? NETunnelProviderSession).sendProviderMessage(_:responseHandler:)`.
  Parse the runtime text with the shared `parseRuntimeStats`, compute ↓/↑ rates
  from the byte delta since the previous sample, and publish
  `@Published var stats: ConnectionStats?`. Clear stats on disconnect. Start/stop
  the poll loop on status transitions.

`ConnectionStats` (app model): `rxBytes`, `txBytes`, `rxRate`, `txRate`,
`lastHandshakeSeconds`, `activeEndpoint`, `isFallback`, `connectedSince`.

### Shared pure parsers (unit-tested)

- `Shared/RuntimeStats.swift`:
  - `struct RuntimeStats { rxBytes: Int64; txBytes: Int64; lastHandshakeSeconds: Int }`
  - `func parseRuntimeStats(_ uapi: String) -> RuntimeStats` — sums `rx_bytes`/
    `tx_bytes` across peers and reuses the existing
    `lastHandshakeSeconds(fromRuntimeConfig:)` for the handshake field (no change
    to the fallback path).
- `Shared/ProfileSummary.swift`:
  - `struct ProfileSummary { address, dns, mtu, endpoints, peerPublicKey, allowedIPs, maskingOn }`
  - `static func from(_ profile: StealthProfile) -> ProfileSummary` — line-scans
    `wgQuickConfig` for the display fields (avoids adding a WireGuardKit
    dependency to the app just for display).

## Data flow

```
extension: adapter.getRuntimeConfiguration + endpoints/currentIndex
   └─ handleAppMessage → JSON {runtime, activeEndpoint, isFallback}
app: sendProviderMessage (poll 1.5s while connected)
   └─ parseRuntimeStats(runtime) + rate deltas → @Published stats → StatsView
```

## Files

- Create: `App/Views/ConnectionView.swift`, `ConnectDial.swift`, `StatsView.swift`,
  `ProfileSetupView.swift`, `ProfileDetailView.swift`; `App/Theme.swift`;
  `Shared/RuntimeStats.swift`, `Shared/ProfileSummary.swift`.
- Modify: `App/ContentView.swift` (router + empty state + sheets),
  `App/TunnelManager.swift` (stats poll/IPC, `ConnectionStats`, delete profile),
  `Tunnel/PacketTunnelProvider.swift` (`handleAppMessage`),
  `scripts/test-parser.sh` (+ new shared files), `Tests/StealthProfileTests.swift`
  (parser checks).
- Reuse unchanged: `App/QRScannerView.swift`, `App/QRCodeView.swift`,
  `Shared/StealthProfile.swift`, `Shared/StealthFallback.swift`.

## Testing

- **Pure logic:** `parseRuntimeStats` (rx/tx/handshake, multi-peer sum) and
  `ProfileSummary.from` are unit-tested in `scripts/test-parser.sh` (swiftc).
- **UI + IPC:** verified by the unsigned device build
  (`xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO`) and a real on-device test
  (connect, watch stats update, see the active endpoint / fallback badge).
- Rate computation lives in the app between samples; the pure per-sample parse is
  what gets unit-tested.

## Visual direction (executed with frontend-design)

- Dark-first, theme-aware (light supported). Secure/technical mood.
- A distinctive "stealth" accent (deep teal/cyan), not generic blue. Connection
  state drives color: idle neutral, connecting amber (pulse), connected accent
  (glow).
- Large confident typography for status; monospace for technical values (bytes,
  keys, endpoints). SF Symbols (`lock.shield`, `arrow.down`/`arrow.up`, `clock`,
  `network`). Generous spacing; smooth state transitions.

## Non-goals (YAGNI)

- Multi-profile gallery/switching.
- On-demand / auto-connect rules, widgets, Shortcuts.
- A full settings screen (beyond a short "what masking does" note).
- Re-running endpoint fallback after a mid-session drop (already deferred).

## Security notes

- The app-message channel only returns runtime counters + the active endpoint —
  no keys or PSK. `ProfileSummary` shows the peer public key and masking on/off
  but never the private key or the mask PSK value.
- No new persistence; the profile still lives only in `providerConfiguration`.
