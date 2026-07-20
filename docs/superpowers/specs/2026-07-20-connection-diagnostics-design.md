# Connection Diagnostics (Transport Reachability) — Design

**Date:** 2026-07-20
**Status:** Approved, ready for planning

## Goal

A **"Test server"** action in the app that checks, from the current network, whether
each of a profile's endpoints is reachable and over which transport — answering the
core stealth question *"which transport gets through here?"*. Runs app-side
(Network.framework), works whether or not the tunnel is connected, and needs no
extension changes.

## The honest constraint

- **QUIC endpoints are directly testable.** A QUIC/TLS handshake either completes
  (listener reachable) or it doesn't. We probe it and report reachable + RTT, or
  failure/timeout. This is the high-value signal on a censored network.
- **Mask (UDP) endpoints are not directly testable.** WireGuard/mask never replies to
  an unauthenticated datagram, so plain UDP gives no reachability signal. We report
  mask endpoints as **"needs tunnel"** and, when the tunnel is connected and that
  endpoint is the live active one with a recent handshake, upgrade it to
  **"reachable via live tunnel."**
- **DNS is checked for both.** A name that doesn't resolve is reported as `dnsFailed`
  before any transport probe.

## Architecture

```
StealthProfile.endpoints ──► diagnosticTargets()  (pure: parseEndpointTarget + host/port split)
                                     │
                                     ▼
        DiagnosticsRunner (app, Network.framework)  ── per target, concurrent ──►
          • DNS resolve
          • QUIC → NWConnection(quic, ALPN h3, accept self-signed) → .ready? + RTT
          • mask → needsTunnel
                                     │
        applyLiveStatus() (pure: mask active endpoint + recent handshake → reachableViaTunnel)
                                     ▼
        @Published diagnostics: [DiagnosticResult]  ──►  DiagnosticsView (App/Views)
```

The probe runs on whatever the current default path is; it is most meaningful while
**disconnected** ("will this server work before I connect?"). When connected, the
live status already proves the active endpoint works, and `applyLiveStatus` reflects
that for the mask endpoint.

## Components

### `Shared/ConnectionDiagnostics.swift` (new, pure — unit-tested)

```swift
import Foundation

/// One endpoint to probe, with its transport and split host/port.
struct DiagnosticTarget: Equatable {
    let hostPort: String
    let transport: String   // "mask" | "quic"
    var host: String        // hostPort minus the last :port
    var port: Int
}

/// Outcome of probing one target.
enum DiagnosticStatus: Equatable {
    case pending
    case reachableQUIC(rttMillis: Int) // QUIC/TLS handshake completed
    case reachableViaTunnel            // mask endpoint confirmed by the live handshake
    case timeout
    case unreachable(String)           // failed with a reason
    case dnsFailed
    case needsTunnel                   // mask endpoint, not directly probeable

    var symbol: String   // SF Symbol name for the row
    var label: String    // short human label
}

struct DiagnosticResult: Equatable, Identifiable {
    let target: DiagnosticTarget
    var status: DiagnosticStatus
    var id: String { target.hostPort }
}

/// Builds probe targets from a profile's endpoints (reuses parseEndpointTarget).
func diagnosticTargets(for profile: StealthProfile) -> [DiagnosticTarget]

/// Upgrades a mask endpoint's `needsTunnel` to `reachableViaTunnel` when it is the
/// live active endpoint with a recent handshake. Pure; used after probing.
func applyLiveStatus(_ results: [DiagnosticResult], activeEndpoint: String?, handshakeRecent: Bool) -> [DiagnosticResult]

/// Human-readable multi-line summary for Copy.
func diagnosticsSummary(_ results: [DiagnosticResult]) -> String
```

`DiagnosticTarget.host`/`port` split on the **last** colon (so `host:443` → `host`,
`443`). `diagnosticTargets` maps each `profile.endpoints` entry through
`parseEndpointTarget(_, defaultTransport: profile.transport)`. The `symbol`/`label`
mapping and `applyLiveStatus`/`diagnosticsSummary` are pure and covered by
`scripts/test-parser.sh`.

### `App/DiagnosticsRunner.swift` (new, app-side I/O — not unit-tested)

An `@MainActor final class DiagnosticsRunner: ObservableObject` with
`@Published private(set) var results: [DiagnosticResult]` and
`@Published private(set) var isRunning: Bool`.

- `run(for profile: StealthProfile, activeEndpoint: String?, handshakeRecent: Bool)`:
  seeds `results` with `.pending`, probes every target concurrently, updates each
  result as it finishes, then applies `applyLiveStatus`.
- **QUIC probe:** `NWConnection` with `NWParameters(quic:)`, `NWProtocolQUIC.Options`
  `alpn = ["h3"]`, and a `sec_protocol_options_set_verify_block` that accepts the
  self-signed cert (WireGuard, not TLS, authenticates the peer). Start a timer;
  `.ready` → `.reachableQUIC(rtt)`, `.failed`/`.cancelled` → `.unreachable`, timeout
  (~4 s) → `.timeout`. DNS failure surfaces as `.dnsFailed`.
- **Mask probe:** no network I/O — set `.needsTunnel` immediately (DNS is still
  resolved first; a resolve failure → `.dnsFailed`).

### `App/Views/DiagnosticsView.swift` (new, shared by iOS + macOS)

- Header: live status when connected (transport, active endpoint, handshake age),
  reusing `TunnelManager.stats`.
- A **"Run test"** button → `runner.run(...)`.
- A list of `results`: transport badge, status symbol + label (color-coded), RTT.
- Toolbar **Copy** → `diagnosticsSummary` via `Clipboard.copy`.
- Explains inline that mask endpoints are confirmed only by a live handshake.

### Entry point

`App/Views/ProfileDetailView.swift` — add a **"Test reachability"** row to the
existing **Diagnostics** section (next to "Connection log"), pushing
`DiagnosticsView(profile:)`. Appears on iOS and macOS (shared view).

## Data flow

1. User opens Test reachability for a profile → `DiagnosticsView` builds targets.
2. Tapping Run probes all targets concurrently (QUIC handshake / mask→needsTunnel),
   each row updates as it resolves.
3. `applyLiveStatus` upgrades the live mask endpoint if connected + recent handshake.
4. User reads results / taps Copy. Nothing is persisted.

## Error handling

- DNS failure → `.dnsFailed` (clear "host not found" message).
- QUIC connection failure/refused → `.unreachable(reason)`.
- No response within the timeout → `.timeout`.
- Probe while the VPN routes all traffic → results reflect the in-tunnel path;
  the view notes the test is most accurate while disconnected.

## Testing

- **Unit (pure, `scripts/test-parser.sh`):** `diagnosticTargets` (endpoint → target,
  host/port split, transport inheritance + `quic://` scheme); `applyLiveStatus`
  (mask active+recent → reachableViaTunnel; non-active untouched; QUIC untouched);
  `DiagnosticStatus.symbol`/`label` mapping; `diagnosticsSummary` formatting.
- **Builds:** unsigned iOS + macOS device builds green (`DiagnosticsRunner`,
  `DiagnosticsView`, entry point compile and link).

## Out of scope (YAGNI)

- Active probing of mask/UDP endpoints (not possible without WireGuard).
- Escaping the VPN tunnel to probe out-of-band while connected.
- Background/automatic or scheduled testing; latency history/graphs.
- Persisting diagnostic results.
