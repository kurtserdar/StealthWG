# Kill switch + On-Demand Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Per-profile Connect-on-demand, Kill switch (`includeAllNetworks`), and Allow-local-network toggles on iOS + macOS, with a single always-on profile.

**Architecture:** Extend `TunnelProfile` with three flags read from the manager/protocol; add `TunnelManager` setters that write the NE properties (preserving them across edits) and enforce single always-on; add a VPN-options section to the shared `ProfileDetailView`.

**Tech Stack:** Swift, SwiftUI, NetworkExtension.

## Global Constraints

- Code comments in English.
- Keep both device builds green (iOS `iphoneos`, macOS `macosx`, `CODE_SIGNING_ALLOWED=NO`) and `scripts/test-parser.sh` green.
- On-demand lives on the manager; `includeAllNetworks`/`excludeLocalNetworks` live on the protocol and must be preserved when `save(...)` rebuilds the protocol.
- Only one profile may have on-demand enabled at a time.

## File Structure

- `App/TunnelManager.swift` — flags + setters (Task 1).
- `App/Views/ProfileDetailView.swift` — VPN options section (Task 2).

---

### Task 1: `TunnelManager` — flags + setters

**Files:** Modify `App/TunnelManager.swift`.

- [ ] **Step 1: Extend `TunnelProfile`**

```swift
struct TunnelProfile: Identifiable, Equatable {
    let id: String
    let name: String
    let profile: StealthProfile
    var onDemand: Bool = false
    var killSwitch: Bool = false
    var allowLocal: Bool = false
}
```

- [ ] **Step 2: Read flags in `rebuild(from:)`**

When building each `TunnelProfile`, read:
```swift
let proto2 = m.protocolConfiguration as? NETunnelProviderProtocol
list.append(TunnelProfile(
    id: id, name: m.localizedDescription ?? "StealthWG", profile: parsed,
    onDemand: m.isOnDemandEnabled,
    killSwitch: proto2?.includeAllNetworks ?? false,
    allowLocal: proto2?.excludeLocalNetworks ?? false
))
```

- [ ] **Step 3: Preserve protocol flags in `save(...)`**

Before replacing the protocol, capture the existing flags and re-apply:
```swift
let existing = m.protocolConfiguration as? NETunnelProviderProtocol
let proto = NETunnelProviderProtocol()
// ... existing providerConfiguration setup ...
proto.includeAllNetworks = existing?.includeAllNetworks ?? false
proto.excludeLocalNetworks = existing?.excludeLocalNetworks ?? false
m.protocolConfiguration = proto
```

- [ ] **Step 4: Add setters**

```swift
    func setOnDemand(id: String, enabled: Bool) async {
        guard let m = managers[id] else { return }
        do {
            if enabled {
                // Single always-on: disable it on every other profile first.
                for (otherID, other) in managers where otherID != id && other.isOnDemandEnabled {
                    other.isOnDemandEnabled = false
                    try await other.saveToPreferences()
                }
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                m.onDemandRules = [rule]
                m.isOnDemandEnabled = true
            } else {
                m.isOnDemandEnabled = false
            }
            m.isEnabled = true
            try await m.saveToPreferences()
            await reloadAndSelect(preferID: id)
        } catch { lastError = error.localizedDescription }
    }

    func setKillSwitch(id: String, enabled: Bool) async {
        await setProtocolFlag(id: id) { $0.includeAllNetworks = enabled }
    }

    func setAllowLocal(id: String, enabled: Bool) async {
        await setProtocolFlag(id: id) { $0.excludeLocalNetworks = enabled }
    }

    private func setProtocolFlag(id: String, _ apply: (NETunnelProviderProtocol) -> Void) async {
        guard let m = managers[id], let proto = m.protocolConfiguration as? NETunnelProviderProtocol else { return }
        apply(proto)
        m.protocolConfiguration = proto
        do {
            try await m.saveToPreferences()
            await reloadAndSelect(preferID: id)
        } catch { lastError = error.localizedDescription }
    }
```

- [ ] **Step 5: Commit** — `git commit -am "TunnelManager: per-profile on-demand + kill switch settings (single always-on)"`

---

### Task 2: `ProfileDetailView` — VPN options

**Files:** Modify `App/Views/ProfileDetailView.swift`.

- [ ] **Step 1: Use the live profile + add the section**

Compute the current profile live so toggles reflect saved state:
```swift
    private var current: TunnelProfile {
        tunnelManager.profiles.first { $0.id == profile.id } ?? profile
    }
```
Use `current` for `summary`/`name`/`status` throughout. Add a section before the
edit/QR/delete section:

```swift
                Section("VPN options") {
                    Toggle("Connect on demand", isOn: Binding(
                        get: { current.onDemand },
                        set: { v in Task { await tunnelManager.setOnDemand(id: profile.id, enabled: v) } }))
                    Text("Automatically connect and stay on; block traffic if the VPN drops.")
                        .font(.caption2).foregroundStyle(.secondary)

                    Toggle("Kill switch (route all traffic)", isOn: Binding(
                        get: { current.killSwitch },
                        set: { v in Task { await tunnelManager.setKillSwitch(id: profile.id, enabled: v) } }))
                    Text("Send all traffic through the tunnel to prevent leaks.")
                        .font(.caption2).foregroundStyle(.secondary)

                    if current.killSwitch {
                        Toggle("Allow local network", isOn: Binding(
                            get: { current.allowLocal },
                            set: { v in Task { await tunnelManager.setAllowLocal(id: profile.id, enabled: v) } }))
                        Text("Keep printers, file shares, and other LAN devices reachable.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .tint(Theme.accent)
```

Replace the `let s = summary` line and other `profile.` references with `current.`
where they read the profile's parsed data (`summary` uses `current.profile`; the
title uses `current.name`).

- [ ] **Step 2: Regenerate is not needed (no new files). Build both platforms**

Run: `export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"`
- iOS: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG -sdk iphoneos -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3` → SUCCEEDED.
- macOS: `xcodebuild -project StealthWG.xcodeproj -scheme StealthWG-mac -sdk macosx -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3` → SUCCEEDED.
- `bash scripts/test-parser.sh` → ALL PASSED.

- [ ] **Step 3: Commit** — `git commit -am "ProfileDetailView: VPN options (on-demand, kill switch, allow local)"`

---

## Self-Review

- **Spec coverage:** three toggles + single always-on (Task 1 setOnDemand loop, Task 2 toggles), flags read/preserved (Task 1). ✓ Both platforms via shared `ProfileDetailView`. ✓
- **Placeholder scan:** concrete code throughout; no TODOs.
- **Type/name consistency:** `TunnelProfile.onDemand/killSwitch/allowLocal` set in Task 1, read in Task 2. `setOnDemand`/`setKillSwitch`/`setAllowLocal` signatures match the toggle call sites. `current` used consistently for the live profile.
