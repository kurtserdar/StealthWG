import SwiftUI
import NetworkExtension

/// Palette and state language for StealthWG. The product masks WireGuard traffic,
/// so the interface speaks in "masked / unmasked" and colors carry the story:
/// teal when protected, amber mid-transition, coral when exposed.
enum Theme {
    static let accent = Color(red: 0.10, green: 0.80, blue: 0.72)   // masked / protected
    static let amber = Color(red: 0.98, green: 0.68, blue: 0.18)    // transitioning
    static let coral = Color(red: 0.90, green: 0.44, blue: 0.38)    // exposed / off

    static func color(for status: NEVPNStatus) -> Color {
        switch status {
        case .connected: return accent
        case .connecting, .reasserting, .disconnecting: return amber
        case .disconnected: return coral
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
