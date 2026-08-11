import Foundation

/// The slice of NETunnelProviderManager the connect flow touches, abstracted so
/// the flow is testable off-device (the tunnel extension is device-only, so no
/// XCTest bundle can host NetworkExtension code).
protocol TunnelConfigurationHandle: AnyObject {
    var isEnabled: Bool { get set }
    /// Refreshes the handle from the system's persisted preferences.
    func reload() async throws
    /// Writes the handle back to the system's persisted preferences.
    func persist() async throws
    /// Starts the tunnel for this configuration.
    func start() throws
}

/// Starts the tunnel, making sure the configuration is enabled first. iOS
/// silently disables a VPN configuration when another one is enabled (another
/// profile, another VPN app, or a Settings change); starting a disabled
/// configuration fails with NEVPNErrorDomain error 2 (configurationDisabled).
/// Reloading first also refreshes stale cached state (error 4).
func startTunnelEnsuringEnabled(_ handle: TunnelConfigurationHandle) async throws {
    try await handle.reload()
    if !handle.isEnabled {
        handle.isEnabled = true
        try await handle.persist()
        try await handle.reload()
    }
    try handle.start()
}
