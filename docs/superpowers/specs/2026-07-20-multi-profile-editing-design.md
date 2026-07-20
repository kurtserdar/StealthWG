# Multiple profiles + structured editing — design

**Date:** 2026-07-20
**Status:** Approved, ready for implementation planning

## Goal

Let the app hold several named StealthWG profiles, switch between them, and edit an
existing profile in the structured form (pre-filled). Applies to **both iOS and
macOS** (shared layer). Today the app manages a single profile and "Replace"
creates a new one from scratch.

Decisions: structured-form editing (not raw text); imported profiles default their
name to the endpoint host.

## Background (current code)

- `App/TunnelManager.swift` — single `manager: NETunnelProviderManager?`.
  `importProfile` overwrites it; `deleteProfile` removes it; `connect`/`disconnect`
  drive it; `stats` poll it; `hasProfile`/`status` reflect it.
- `App/Views/ProfileFormView.swift` — builds a new profile from a `ProfileDraft`.
- `App/Views/AddProfileView.swift` — paste/scan/file/scratch → `importProfile`.
- `App/Views/ProfileDetailView.swift` — summary + Show QR / Replace / Delete.
- `Shared/ProfileDraft.swift` — `build()` assembles profile text from fields.
- `Shared/ProfileSummary.swift` — line-scans a profile for display fields.
- iOS `ContentView` routes empty-state ↔ `ConnectionView`; macOS `MacMenuView` +
  `ManageWindow` mirror it.
- Each profile is one `NETunnelProviderManager`; iOS/macOS allow only one active
  tunnel at a time.

## Architecture

### Model

```swift
struct TunnelProfile: Identifiable, Equatable {
    let id: String              // UUID stored in providerConfiguration["profileID"]
    let name: String            // manager.localizedDescription
    let profile: StealthProfile // parsed wgQuickConfig + maskKey + endpoints
}
```

### `TunnelManager` refactor (multi-profile)

```swift
@Published private(set) var profiles: [TunnelProfile]          // sorted by name
@Published private(set) var statuses: [String: NEVPNStatus]    // per-profile
@Published private(set) var stats: ConnectionStats?            // for the active tunnel
@Published private(set) var lastError: String?
@Published var selectedID: String?                            // profile the UI focuses on

private var managers: [String: NETunnelProviderManager]        // id -> manager
private var observers: [NSObjectProtocol]                      // one per connection
```

- `load()` → `loadAllFromPreferences` → build `managers`/`profiles`/`statuses`,
  observe each connection's status; `selectedID = connectedID ?? profiles.first?.id`.
- `addProfile(name:raw:)` — new manager, fresh `profileID`, `localizedDescription =
  name`; save; append.
- `addProfile(_ draft:name:)` — `draft.build()` then `addProfile(name:raw:)`.
- `updateProfile(id:name:raw:)` — update that manager's `providerConfiguration` +
  `localizedDescription`; keep the same `profileID`; save.
- `deleteProfile(id:)` — `removeFromPreferences` on that manager; drop it.
- `connect(id:)` / `disconnect(id:)` — start/stop that manager's tunnel. Connecting
  one while another is active stops the other first.
- Derived: `connectedID` (first profile whose status is connected/connecting/
  reasserting), `status(of id:)`, `selectedProfile`.
- Stats poll the **connected** manager (as today, keyed to `connectedID`).
- `profileText(id:)` — reconstruct raw text for QR export / edit pre-fill.

Default name for imports: the host of `profile.endpoints.first` (`host:port` → `host`),
or `"StealthWG"` when no endpoint. Duplicate names are allowed (id is unique).

### Reverse parser — `ProfileDraft.from` (`Shared/ProfileDraft.swift`)

```swift
static func from(_ profile: StealthProfile) -> ProfileDraft
```
Line-scans `wgQuickConfig` for PrivateKey/Address/DNS/MTU (`[Interface]`) and
PublicKey/Endpoint/AllowedIPs/PresharedKey/PersistentKeepalive (`[Peer]`); takes
`endpoint = endpoints.first`, `fallbackEndpoints = Array(endpoints.dropFirst())`,
`maskKey = profile.maskKey ?? ""`. Inverse of `build()` for our profile shape;
round-trip tested (`from(parse(build(x)))` recovers the fields).

### UI (shared, lands on both platforms)

- **`ProfilesListView` (new):** rows (name, endpoint summary, a "Connected" badge),
  tap to select, `+` to add (presents `AddProfileView`), swipe to delete, row →
  `ProfileDetailView`.
- **`ProfileFormView`:** gains a **Name** field; an `editing: TunnelProfile?` mode
  that pre-fills the draft (`ProfileDraft.from`) + name and, on Save, calls
  `updateProfile` instead of `addProfile`.
- **`ProfileDetailView`:** add **Edit** (opens the pre-filled form); shows the name;
  keeps Show QR / Delete; add "Set as active / Connect".
- **`AddProfileView`:** every path computes the default name (endpoint host) and
  calls `addProfile(name:raw:)`; the scratch path opens `ProfileFormView` with an
  empty draft + editable name.
- **iOS `ContentView`/`ConnectionView`:** empty state when no profiles; otherwise the
  hero shows `selectedProfile` (connect/disconnect that one, live stats) plus access
  to `ProfilesListView` to switch/manage.
- **macOS `MacMenuView`/`ManageWindow`:** the menu shows the selected profile +
  connect and a submenu/list to switch; the window hosts `ProfilesListView`.

## Testing

- **Pure:** `ProfileDraft.from` round-trip + default-name derivation (a small pure
  helper `defaultProfileName(for:)`) in `scripts/test-parser.sh`.
- **UI + NE:** unsigned device build (iOS `iphoneos`, macOS `macosx`) +
  `scripts/test-parser.sh` green. Runtime profile switching validated on device
  (single active tunnel).

## Non-goals (YAGNI)

- Auto best-profile selection, folders/tags, simultaneous tunnels (OS-limited).
- Cloud sync of profiles.
- Editing arbitrary multi-peer .conf via the form (form models our single-peer
  shape; import still stores the raw wg-quick text verbatim, so connect works even
  for shapes the form can't fully render — edit just exposes the modeled fields).

## Security notes

- No new persistence surface; profiles still live only in each manager's
  `providerConfiguration`. The `profileID` is a non-secret UUID. Names are
  user-supplied plain text.
