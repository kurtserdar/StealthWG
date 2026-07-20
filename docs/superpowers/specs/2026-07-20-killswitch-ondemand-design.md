# Kill switch + on-demand — design

**Date:** 2026-07-20
**Status:** Approved, ready for implementation planning

## Goal

Per-profile VPN hardening on both iOS and macOS: **Connect on demand** (always-on
+ block-when-down), **Kill switch** (route all traffic through the tunnel, no
leaks), and **Allow local network** (keep LAN reachable under the kill switch).
Only one profile may be always-on at a time.

Decided: three toggles; enforce a single always-on profile.

## Background (current code)

- `App/TunnelManager.swift` — multi-profile. Each profile is a
  `NETunnelProviderManager`; `save(...)` builds a fresh `NETunnelProviderProtocol`
  from the profile's fields. `rebuild(from:)` maps managers to `TunnelProfile`.
- `App/Views/ProfileDetailView.swift` — shows one profile with connect/edit/QR/
  delete.
- NE facts (min iOS 16 / macOS 13, all supported):
  - `NEVPNManager.isOnDemandEnabled` + `onDemandRules` (`NEOnDemandRuleConnect`,
    `interfaceTypeMatch = .any`) — auto-connect + block matched traffic while the
    tunnel is down (the "off" half of a kill switch). On-demand lives on the
    **manager**, so it survives replacing `protocolConfiguration`.
  - `NETunnelProviderProtocol.includeAllNetworks` / `excludeLocalNetworks` —
    full-tunnel / no-leak while connected. These live on the **protocol**, so they
    are wiped when `save(...)` replaces the protocol and must be preserved.

## Architecture

### Model additions (`TunnelProfile`)

```swift
var onDemand: Bool     // manager.isOnDemandEnabled
var killSwitch: Bool   // protocol.includeAllNetworks
var allowLocal: Bool   // protocol.excludeLocalNetworks
```
Read in `rebuild(from:)` from each manager/protocol.

### `TunnelManager` changes

- `rebuild(from:)` populates the three flags per profile.
- `save(...)` **preserves** `includeAllNetworks` / `excludeLocalNetworks` from the
  existing protocol when it rebuilds the protocol (so editing a profile doesn't
  clear its kill switch). On-demand is untouched by save (it's on the manager).
- `setOnDemand(id:enabled:)` — when enabling, first disable on-demand on **every
  other** manager (single always-on), then set this manager's
  `isOnDemandEnabled = true` + `onDemandRules = [NEOnDemandRuleConnect(.any)]`;
  when disabling, just clear this one. Save each changed manager; reload.
- `setKillSwitch(id:enabled:)` — set the profile's protocol `includeAllNetworks`;
  save; reload.
- `setAllowLocal(id:enabled:)` — set `excludeLocalNetworks`; save; reload.

### UI (`ProfileDetailView`, shared → both platforms)

A **VPN options** section with three toggles, bound to the manager values (looked
up live from `tunnelManager.profiles` so they reflect the saved state):

- **Connect on demand** — "Automatically connect and stay on; block traffic if the
  VPN drops."
- **Kill switch (route all traffic)** — `includeAllNetworks`; "Send all traffic
  through the tunnel to prevent leaks."
- **Allow local network** — shown only when the kill switch is on; toggles
  `excludeLocalNetworks`; "Keep printers, file shares, and other LAN devices
  reachable."

Each toggle's `set` dispatches the matching `TunnelManager` async method. Because
enabling on-demand can change other profiles, the list/detail refresh from
`@Published profiles`.

`ProfileDetailView` reads the **current** profile from `tunnelManager.profiles`
(by id) rather than the passed-in snapshot, so toggles reflect immediately.

## Testing

- No new pure logic (these are NE property writes). `scripts/test-parser.sh` stays
  green. Verified by unsigned device builds (iOS `iphoneos`, macOS `macosx`).
- Behaviour (auto-connect, block-when-down, no-leak) is validated on a real device;
  the app-side contract is "the right properties are written to the manager/
  protocol and preserved across edits."

## Non-goals (YAGNI)

- SSID / trusted-network / time-based on-demand rules (a later iteration).
- A global (non-per-profile) kill switch.
- DNS-leak-specific settings beyond `includeAllNetworks`.

## Security notes

- These settings strengthen leak prevention; no new secrets or persistence. The
  flags are non-sensitive booleans on the tunnel configuration.
- Enabling the kill switch forces all traffic through the tunnel; the "Allow local
  network" toggle is the deliberate, user-controlled exception for LAN access.
