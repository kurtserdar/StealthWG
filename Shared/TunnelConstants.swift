import Foundation

/// Identifiers and keys shared between the app and the packet tunnel extension.
enum TunnelConstants {
    /// Bundle identifier of the packet tunnel network extension. macOS uses a
    /// distinct id so its App IDs don't collide with the iOS ones.
    #if os(macOS)
    static let tunnelBundleIdentifier = "com.stealthwg.mac.tunnel"
    #else
    static let tunnelBundleIdentifier = "com.stealthwg.tunnel"
    #endif

    /// App Group used to share configuration and state between the app and the
    /// tunnel extension. Must match the `com.apple.security.application-groups`
    /// entitlement on both targets.
    static let appGroup = "group.com.stealthwg"

    /// Human-readable name shown for the VPN configuration in system settings.
    static let displayName = "StealthWG"
}
