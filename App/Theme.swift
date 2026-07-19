import SwiftUI
import NetworkExtension

/// Palette and state language for StealthWG (Wraith identity). The product masks
/// WireGuard traffic, so the interface speaks in "masked / unmasked": teal when
/// masked/active, amber mid-transition, brand silver when unmasked (the wraith at
/// rest, visible).
enum Theme {
    static let accent = Color(red: 0.20, green: 0.88, blue: 0.77)   // teal #34E0C4 — masked/active
    static let silver = Color(red: 0.84, green: 0.87, blue: 0.91)   // brand silver #D7DEE9 — unmasked
    static let amber = Color(red: 0.98, green: 0.68, blue: 0.18)    // transitioning

    static func color(for status: NEVPNStatus) -> Color {
        switch status {
        case .connected: return accent
        case .connecting, .reasserting, .disconnecting: return amber
        case .disconnected: return silver
        default: return .secondary
        }
    }

    static func label(for status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "Not configured"
        case .disconnected: return "Unmasked"
        case .connecting: return "Masking…"
        case .connected: return "Masked"
        case .reasserting: return "Re-masking…"
        case .disconnecting: return "Unmasking…"
        @unknown default: return "Unknown"
        }
    }
}
