import Foundation
import NetworkExtension

/// Observable wrapper around `NETunnelProviderManager` that the UI binds to.
///
/// The app parses a pasted StealthWG profile, stores the wg-quick config and the
/// mask key in the tunnel's provider configuration, and starts/stops the tunnel.
/// The packet tunnel extension reads that configuration and drives WireGuard.
@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var lastError: String?
    @Published private(set) var hasProfile = false

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    /// Load the existing tunnel configuration from preferences, if any.
    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let manager = managers.first ?? NETunnelProviderManager()
            self.manager = manager
            hasProfile = profileIsPresent(in: manager)
            observeStatus(of: manager)
            status = manager.connection.status
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Parse a pasted StealthWG profile and save it as the tunnel configuration.
    func importProfile(_ raw: String) async {
        do {
            let profile = try StealthProfile.parse(raw)

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = TunnelConstants.tunnelBundleIdentifier
            proto.serverAddress = TunnelConstants.displayName
            var providerConfiguration: [String: Any] = ["wgQuickConfig": profile.wgQuickConfig]
            if let maskKey = profile.maskKey {
                providerConfiguration["maskKey"] = maskKey
            }
            proto.providerConfiguration = providerConfiguration

            let manager = self.manager ?? NETunnelProviderManager()
            manager.protocolConfiguration = proto
            manager.localizedDescription = TunnelConstants.displayName
            manager.isEnabled = true

            try await manager.saveToPreferences()
            // Reload so the connection object reflects the saved configuration.
            try await manager.loadFromPreferences()

            self.manager = manager
            observeStatus(of: manager)
            hasProfile = true
            lastError = nil
        } catch {
            lastError = describe(error)
        }
    }

    /// Start the tunnel using the saved profile.
    func connect() {
        do {
            try manager?.connection.startVPNTunnel()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Stop the active tunnel connection.
    func disconnect() {
        manager?.connection.stopVPNTunnel()
    }

    private func profileIsPresent(in manager: NETunnelProviderManager) -> Bool {
        let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
        return proto?.providerConfiguration?["wgQuickConfig"] != nil
    }

    private func describe(_ error: Error) -> String {
        if case StealthProfile.ParseError.emptyConfiguration = error {
            return "The profile is empty or missing an [Interface] section."
        }
        return error.localizedDescription
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
