import Foundation

/// Identifiers and keys shared between the app and the packet tunnel extension.
enum TunnelConstants {
    /// Bundle identifier of the packet tunnel network extension.
    static let tunnelBundleIdentifier = "com.stealthwg.tunnel"

    /// App Group used to share configuration and state between the app and the
    /// tunnel extension. Must match the `com.apple.security.application-groups`
    /// entitlement on both targets.
    static let appGroup = "group.com.stealthwg"

    /// Human-readable name shown for the VPN configuration in system settings.
    static let displayName = "StealthWG"
}
