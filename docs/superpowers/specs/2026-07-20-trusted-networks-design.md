# Network-Based Auto-Connect (Trusted Networks) — Design

**Date:** 2026-07-20
**Status:** Approved (Approach A — manual SSID entry), ready for planning

## Goal

Refine the per-profile "Connect on demand" (currently always-on everywhere) so the
VPN **does not auto-connect on trusted Wi-Fi** (home/work) but **does** on everything
else (unknown Wi-Fi, cellular). Serves the stealth use case: protect automatically on
hostile networks, stay out of the way on ones you trust.

## Approach A (chosen): manual SSID entry

The user maintains a list of **trusted Wi-Fi SSIDs** by typing them. No location
permission is needed: the system evaluates `ssidMatch` internally for on-demand
rules — the app never reads the current SSID. (Approach B, a one-tap "add current
network" via `NEHotspotNetwork.fetchCurrent`, needs CoreLocation and is a **deferred
follow-up**, tracked in the roadmap.)

## How it works

On-demand rules are evaluated in order; the first match wins. From the profile's
`trustedSSIDs` and `trustCellular`:

1. If `trustedSSIDs` non-empty → **Ignore** on Wi-Fi matching those SSIDs (don't
   auto-connect there; a manual connect is respected).
2. If `trustCellular` → **Ignore** on cellular.
3. Always → **Connect** on any interface.

`Ignore` (not `Disconnect`) means "don't auto-activate here" while respecting a
manual connection — the least-surprising reading of "trusted."

## Architecture

```
trustedSSIDs + trustCellular  ──►  onDemandRuleSpecs()  (pure, tested)
                                          │
        makeOnDemandRules() (TunnelManager: OnDemandRuleSpec → NEOnDemandRule)
                                          │
                          m.onDemandRules = [...]  (when on-demand is enabled)
```

Trusted networks are stored in `providerConfiguration` (like `transport`/`sni`) and
surfaced on `TunnelProfile`. The existing single-always-on rule and kill-switch
behavior are unchanged.

## Components

### `Shared/OnDemandRules.swift` (new, pure — unit-tested)

```swift
import Foundation

enum OnDemandAction: Equatable { case connect, ignore, disconnect }
enum OnDemandInterface: Equatable { case any, wifi, cellular }

/// A transport-agnostic description of one on-demand rule (adapted to
/// NEOnDemandRule in TunnelManager). Pure so the ordering logic is testable.
struct OnDemandRuleSpec: Equatable {
    let action: OnDemandAction
    let interface: OnDemandInterface
    let ssids: [String]   // empty = no SSID constraint
}

/// Builds the ordered rule specs: Ignore on trusted Wi-Fi SSIDs, optionally Ignore
/// on cellular, then Connect everywhere. Blank SSIDs are dropped.
func onDemandRuleSpecs(trustedSSIDs: [String], trustCellular: Bool) -> [OnDemandRuleSpec]
```

Ordering: `[ignore/wifi/<ssids>]?` + `[ignore/cellular]?` + `[connect/any]`.
Pure and covered by `scripts/test-parser.sh`.

### `App/TunnelManager.swift`

- `TunnelProfile` gains `trustedSSIDs: [String] = []` and `trustCellular: Bool = false`,
  derived at reload from `providerConfiguration`.
- `setOnDemand(id:enabled:)` builds `m.onDemandRules` from the profile's trusted
  networks via `onDemandRuleSpecs` + a private `makeOnDemandRules(_:)` adapter
  (instead of the fixed `[NEOnDemandRuleConnect(.any)]`). Single-always-on
  enforcement unchanged.
- New `setTrustedNetworks(id:ssids:trustCellular:)` — persists the two values into
  `providerConfiguration` and, if on-demand is currently enabled, rebuilds
  `m.onDemandRules`; then saves + reloads.
- `save(profile:name:into:id:)` preserves existing `trustedSSIDs`/`trustCellular`
  from the previous `providerConfiguration` across a profile edit (like it preserves
  `includeAllNetworks`).
- `makeOnDemandRules(_ specs:) -> [NEOnDemandRule]`: maps action → Connect/Ignore/
  Disconnect, interface → `.any`/`.wiFi`/`.cellular`, sets `ssidMatch` when non-empty.

### `App/Views/TrustedNetworksView.swift` (new, shared iOS + macOS)

- An editable list of trusted SSIDs: a text field + Add button; swipe/Delete to
  remove. Applies each change via `setTrustedNetworks`.
- A toggle **"Auto-connect on cellular data"** (bound to `!trustCellular`; default on
  → `trustCellular == false`).
- Explanatory footer: "On these Wi-Fi networks StealthWG won't connect automatically;
  everywhere else it will. You can still connect manually."

### `App/Views/ProfileDetailView.swift`

In "VPN options", when `current.onDemand` is true, add a `NavigationLink` **"Trusted
networks"** → `TrustedNetworksView(profileID: profile.id, ssids:, trustCellular:)`.
(Only meaningful with on-demand on; hidden otherwise.)

## Data flow

1. User enables "Connect on demand" → rules built from current (possibly empty)
   trusted networks → Connect everywhere (same as today until SSIDs are added).
2. User opens "Trusted networks", adds their home SSID → `setTrustedNetworks`
   persists it and rebuilds rules → Ignore on that SSID + Connect elsewhere.
3. At home the VPN no longer auto-connects; elsewhere it does. Manual connect always
   works.

## Error handling

- Empty/blank SSID input is ignored (not added).
- Duplicate SSIDs are de-duplicated.
- `setTrustedNetworks` when on-demand is off: values are persisted but no rules are
  rebuilt (they apply next time on-demand is enabled).
- Save failures surface via `lastError` (existing pattern).

## Testing

- **Unit (pure, `scripts/test-parser.sh`):** `onDemandRuleSpecs` — empty → just
  `[connect/any]`; SSIDs only → `[ignore/wifi/ssids, connect/any]`; SSIDs + cellular →
  `[ignore/wifi/ssids, ignore/cellular, connect/any]`; cellular only →
  `[ignore/cellular, connect/any]`; blank SSIDs dropped; order preserved.
- **Builds:** unsigned iOS + macOS device builds green.

## Out of scope (YAGNI)

- Approach B: one-tap "add current network" via `NEHotspotNetwork.fetchCurrent`
  (needs CoreLocation) — deferred follow-up.
- Trusted Ethernet, DNS-search-domain matching, per-SSID actions.
- Auto-disconnect (`NEOnDemandRuleDisconnect`) on trusted networks — we use `Ignore`.
