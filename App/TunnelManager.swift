import Foundation
import NetworkExtension

/// Observable wrapper around `NETunnelProviderManager` that the UI binds to.
///
/// For now this only installs/loads the VPN configuration and starts or stops
/// the tunnel. The actual WireGuard configuration is wired in a later step;
/// today the extension is a stub that brings the interface up and idles.
@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var lastError: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    /// Load the existing tunnel configuration from preferences, if any.
    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let manager = managers.first ?? NETunnelProviderManager()
            self.manager = manager
            observeStatus(of: manager)
            status = manager.connection.status
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Create or update the tunnel configuration and start the connection.
    func connect() async {
        do {
            let manager = self.manager ?? NETunnelProviderManager()

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = TunnelConstants.tunnelBundleIdentifier
            // Placeholder until a real profile is imported. The tunnel needs a
            // server address to be considered valid by the system.
            proto.serverAddress = "StealthWG"

            manager.protocolConfiguration = proto
            manager.localizedDescription = TunnelConstants.displayName
            manager.isEnabled = true

            try await manager.saveToPreferences()
            // Reload so the connection object reflects the saved configuration.
            try await manager.loadFromPreferences()

            self.manager = manager
            observeStatus(of: manager)

            try manager.connection.startVPNTunnel()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Stop the active tunnel connection.
    func disconnect() {
        manager?.connection.stopVPNTunnel()
    }

    private func observeStatus(of manager: NETunnelProviderManager) {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        status = manager.connection.status
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            self?.status = manager.connection.status
        }
    }
}
