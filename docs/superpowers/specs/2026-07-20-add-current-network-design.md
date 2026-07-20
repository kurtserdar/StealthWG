# Add Current Wi-Fi to Trusted Networks (#3-B) — Design

**Date:** 2026-07-20
**Status:** Approved, ready for planning

## Goal

In the Trusted Networks screen, add a **"Use current Wi-Fi"** button that reads the
SSID of the network the phone is on right now and adds it to the trusted list —
so the user doesn't have to type it. This is the deferred follow-up to #3 (which
shipped manual SSID entry, Approach A).

## How it works (iOS)

- The current SSID comes from `NEHotspotNetwork.fetchCurrent { $0?.ssid }` (iOS 14+).
- Reading the SSID is gated by iOS privacy: the app needs the **Access WiFi
  Information** entitlement (`com.apple.developer.networking.wifi-info`) **and**
  Core Location **When In Use** authorization (StealthWG also qualifies via its
  active VPN configuration, but we request location to be safe/portable).
- Flow: tap → if location isn't authorized yet, request it → on authorization,
  `fetchCurrent` → if an SSID comes back, add it to the trusted list and apply →
  otherwise show a short, honest message.

**iOS only.** `NEHotspotNetwork` is an iOS API; macOS keeps manual entry (the
cellular toggle is already hidden there). A macOS "current network" via CoreWLAN is
out of scope.

## Architecture

```
"Use current Wi-Fi" (TrustedNetworksView, #if os(iOS))
        │
   CurrentWiFi.fetch { result in ... }
        │  CLLocationManager → When-In-Use auth
        │  NEHotspotNetwork.fetchCurrent → ssid
        ▼
   .success(ssid)  → add to list + tunnelManager.setTrustedNetworks
   .denied / .unavailable / .noSSID → inline message
```

## Components

### `App/CurrentWiFi.swift` (new, iOS only — I/O, not unit-tested)
```swift
#if os(iOS)
import CoreLocation
import NetworkExtension

/// Fetches the current Wi-Fi SSID, requesting Location When-In-Use if needed.
/// iOS gates SSID reads behind location authorization + the Access WiFi
/// Information entitlement.
final class CurrentWiFi: NSObject, CLLocationManagerDelegate {
    enum Result { case success(String), denied, unavailable }

    private let manager = CLLocationManager()
    private var completion: ((Result) -> Void)?

    func fetch(_ completion: @escaping (Result) -> Void) {
        self.completion = completion
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: readSSID()
        case .notDetermined: manager.delegate = self; manager.requestWhenInUseAuthorization()
        default: finish(.denied)
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: readSSID()
        case .notDetermined: break
        default: finish(.denied)
        }
    }

    private func readSSID() {
        NEHotspotNetwork.fetchCurrent { [weak self] net in
            if let ssid = net?.ssid, !ssid.isEmpty { self?.finish(.success(ssid)) }
            else { self?.finish(.unavailable) }
        }
    }

    private func finish(_ r: Result) {
        let c = completion; completion = nil
        DispatchQueue.main.async { c?(r) }
    }
}
#endif
```

### `App/Views/TrustedNetworksView.swift` (modify, iOS only addition)
- A **"Use current Wi-Fi"** button (inside `#if os(iOS)`) in the "Trusted Wi-Fi
  networks" section, above the manual add field.
- On tap: run `CurrentWiFi.fetch`; on `.success(ssid)` add it (dedup) and `apply()`;
  on `.denied` / `.unavailable` set a short `@State` message shown below the button.
- Holds a `CurrentWiFi` instance for the view's lifetime (it owns the location
  manager).

### Entitlement / Info.plist / `project.yml`
- `App/App.entitlements`: add `com.apple.developer.networking.wifi-info = true`.
- iOS app: `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` in `project.yml`
  ("StealthWG reads your current Wi-Fi name so you can mark it trusted.").
- (Signing: enable the **Access WiFi Information** capability on the `com.stealthwg`
  App ID in the portal — a device-signing step for the user; unsigned builds compile.)

## Data flow

1. User opens Trusted Networks (on-demand on) → taps "Use current Wi-Fi".
2. First time → iOS location prompt → user allows.
3. `fetchCurrent` returns the SSID → it's added to the list and applied
   (`setTrustedNetworks`), so on-demand ignores that Wi-Fi.
4. Denied/unavailable → a one-line explanation; manual entry still works.

## Error handling

- Location denied / restricted → `.denied` → "Allow location access to read the
  current Wi-Fi name, or type it below."
- No SSID (not on Wi-Fi, or system withheld it) → `.unavailable` → "Couldn't read
  the current Wi-Fi. Type the name below."
- Duplicate SSID → silently not re-added.

## Testing

- **Pure:** none of note (the flow is I/O). The dedupe/add reuses the existing
  in-view logic already covered by #3's behavior.
- **Builds:** unsigned iOS + macOS device builds green (the macOS build must ignore
  the iOS-only file via `#if os(iOS)` and the unchanged manual path).
- **Device:** the location prompt + real SSID read are verified on device by the user.

## Out of scope (YAGNI)

- macOS "current network" (CoreWLAN).
- Precise-location handling, Always authorization, background SSID monitoring.
- Auto-suggesting nearby known networks.
