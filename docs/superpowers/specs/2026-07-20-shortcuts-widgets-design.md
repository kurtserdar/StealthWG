# Shortcuts, Widgets & Control Center — Design

**Date:** 2026-07-20
**Status:** Approved, ready for planning

## Goal

Let people connect/disconnect/toggle a StealthWG profile **without opening the app**:
- **App Intents** → Siri + Shortcuts automations ("when I leave home, connect").
- **Three Home-Screen widgets** → Shield (small, toggle), Status board (medium, live
  stats), Quick connect (small, pinned to a chosen profile).
- **Control Center toggle** (iOS 18+) → the same toggle, one swipe away.

All four surfaces call the same App Intents, so they stay in sync. Visual identity
matches the app: the Wraith ghost shifts **teal (masked) / amber (masking) / coral
(exposed)**; SF Rounded for status, SF Mono for data. (See the mockup artifact.)

## Architecture

```
App Intents (shared: ConnectVPNIntent / DisconnectVPNIntent / ToggleVPNIntent + ProfileEntity)
        │  load NETunnelProviderManager → start/stopVPNTunnel
        ▼
   NetworkExtension  ──stats/status──►  App writes WidgetSnapshot to the App Group
                                              │  WidgetCenter.reloadAllTimelines()
                                              ▼
              Widget extension reads the snapshot → Shield / Status board / Quick connect / Control
```

- **App Group** `group.com.stealthwg` shares a small `WidgetSnapshot` (JSON in the
  group's `UserDefaults`) app → widgets. The app never lets the widget poll the
  extension; it publishes a snapshot when status/stats change.
- **App Intents** live in a source compiled by **both** the app and the widget
  extension, so the widgets' buttons and Control Center invoke them directly.

## Components

### `Shared/WidgetSnapshot.swift` (new, pure — unit-tested)
The data the widgets render. Codable; read/written through the app group.
```swift
struct WidgetSnapshot: Codable, Equatable {
    enum State: String, Codable { case masked, masking, exposed }
    var state: State
    var profileName: String?      // active/selected profile
    var transport: String?        // "mask" | "quic"
    var endpoint: String?         // active endpoint host:port
    var rxRate: Double            // bytes/s
    var txRate: Double            // bytes/s
    var connectedSince: Date?
    var lastHandshakeSeconds: Int // epoch of last handshake (0 = none)

    static let empty = WidgetSnapshot(state: .exposed, ...)

    var statusLabel: String       // "Masked" | "Masking…" | "Exposed"
    var accentName: String        // "teal" | "amber" | "coral" (mapped to Color in views)
}

/// Group store: `WidgetStore.load()` / `WidgetStore.save(_:)` using
/// UserDefaults(suiteName: appGroup); `WidgetStore.appGroup = "group.com.stealthwg"`.
enum WidgetStore {
    static func load() -> WidgetSnapshot
    static func save(_ snapshot: WidgetSnapshot)
}
```
`statusLabel`/`accentName` and the snapshot's Codable round-trip are pure and covered
by `scripts/test-parser.sh` (the `UserDefaults` I/O is not).

### `Shared/VPNIntents.swift` (new — app + widget targets)
```swift
import AppIntents

struct ProfileEntity: AppEntity, Identifiable { let id: String; let name: String; ... }
struct ProfileQuery: EntityQuery { ... }   // reads NETunnelProviderManager list

struct ConnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect StealthWG"
    @Parameter(title: "Profile") var profile: ProfileEntity?
    func perform() async throws -> some IntentResult { ... start the tunnel ... }
}
struct DisconnectVPNIntent: AppIntent { ... stop ... }
struct ToggleVPNIntent: AppIntent { ... start if off, stop if on ... }

struct StealthShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleVPNIntent(), phrases: ["Toggle \(.applicationName)"])
        AppShortcut(intent: ConnectVPNIntent(), phrases: ["Connect \(.applicationName)"])
        AppShortcut(intent: DisconnectVPNIntent(), phrases: ["Disconnect \(.applicationName)"])
    }
}
```
Intents load managers via `NETunnelProviderManager.loadAllFromPreferences`, pick the
named profile (or the last-selected one when the parameter is nil), and
start/stop the connection. They require the NetworkExtension entitlement + app group.

### `App/TunnelManager.swift`
- Publishes a `WidgetSnapshot` to the app group whenever `stats`/`statuses` change
  (a `publishWidgetSnapshot()` called from the status observer and stats update),
  then `WidgetCenter.shared.reloadAllTimelines()`.
- Stores the last-selected profile id in the app group so an intent with no explicit
  profile knows which one to act on.

### Widget extension `StealthWGWidgets/` (new target, iOS)
- `StealthWGWidgetBundle.swift` — `@main struct` listing the widgets + control.
- `ShieldWidget` (`.systemSmall`) — ghost (accent-colored), status word,
  `profile · transport`, and a `Button(intent: ToggleVPNIntent())` (iOS 17+).
- `StatusBoardWidget` (`.systemMedium`) — ghost, status pill, endpoint, ↓/↑ rates,
  session time, last handshake; tap opens the app.
- `QuickConnectWidget` (`.systemSmall`, configurable) — a
  `AppIntentConfiguration` with a `ProfileEntity` parameter; a `Button(intent:
  ConnectVPNIntent(profile:))` for the pinned profile.
- `ControlToggle` (`ControlWidget`, `@available(iOS 18)`) — a `ControlWidgetToggle`
  bound to the tunnel state via `ToggleVPNIntent`.
- Timelines read `WidgetStore.load()`; a short refresh cadence plus app-driven
  `reloadAllTimelines()` keeps them fresh. Views use the shared identity colors.

### Entitlements / `project.yml`
- Add `com.apple.security.application-groups = [group.com.stealthwg]` to the app,
  the widget extension, and (for the intent that runs in-app) the app entitlements.
- New `StealthWGWidgets` target (`type: app-extension`, WidgetKit), embedded in the
  iOS app; sources: `StealthWGWidgets` + the shared `Shared` + `VPNIntents.swift`.
- Widget extension deployment target iOS 17 (interactive widgets); Control widget
  guarded by `@available(iOS 18)`. App stays at its current minimum.

## Data flow

1. App connects/disconnects or stats tick → `publishWidgetSnapshot()` writes the
   group snapshot + `reloadAllTimelines()`.
2. Widgets render the snapshot (ghost color = state).
3. User taps a widget/Control toggle → the embedded App Intent starts/stops the
   tunnel → the app (or the intent) republishes the snapshot → widgets refresh.
4. Siri/Shortcuts run the same intents.

## Error handling

- No profiles configured → intents throw a clear `IntentError` ("Add a profile in
  StealthWG first"); widgets show an "Open StealthWG" prompt.
- Manager load/start failure → intent surfaces the error; widget keeps the last
  snapshot.
- App group unavailable (mis-provisioned) → `WidgetStore.load()` returns `.empty`.

## Testing

- **Unit (pure, `scripts/test-parser.sh`):** `WidgetSnapshot` Codable round-trip;
  `statusLabel`/`accentName` mapping for each state; `.empty` is exposed.
- **Builds:** unsigned iOS app + widget-extension build green; parser tests green.
  (Live widget rendering / Siri are device-only, verified by the user.)

## Out of scope (YAGNI)

- macOS widgets / Menu Bar extras beyond the existing menu-bar app (iOS widgets
  first; macOS widget target is a later follow-up).
- Lock Screen / StandBy widget families, Live Activities.
- Per-widget theming options; multiple accent themes.
