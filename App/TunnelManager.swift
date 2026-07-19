import Foundation
import NetworkExtension

/// Live connection statistics shown in the UI, refreshed from the extension.
struct ConnectionStats: Equatable {
    var rxBytes: Int64
    var txBytes: Int64
    var rxRate: Double
    var txRate: Double
    var lastHandshakeSeconds: Int
    var activeEndpoint: String?
    var isFallback: Bool
    var connectedSince: Date?
}

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
    @Published private(set) var stats: ConnectionStats?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var statsTimer: Timer?
    private var lastSample: (rx: Int64, tx: Int64, at: Date)?
    private var connectedSince: Date?

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
            if !profile.endpoints.isEmpty {
                providerConfiguration["endpoints"] = profile.endpoints
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

    /// Reconstructs the saved profile's raw text (wg-quick + `[Stealth]`) for
    /// export, or nil when no profile is configured.
    func currentProfileText() -> String? {
        guard
            let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol,
            let config = proto.providerConfiguration?["wgQuickConfig"] as? String
        else {
            return nil
        }
        let maskKey = proto.providerConfiguration?["maskKey"] as? String
        let endpoints = proto.providerConfiguration?["endpoints"] as? [String] ?? []
        return StealthProfile(wgQuickConfig: config, maskKey: maskKey, endpoints: endpoints).serialize()
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
            guard let self else { return }
            self.status = manager.connection.status
            self.handleStatusChange(self.status)
        }
    }

    // MARK: - Live stats

    private func handleStatusChange(_ status: NEVPNStatus) {
        if status == .connected {
            if connectedSince == nil { connectedSince = Date() }
            startStatsPolling()
        } else {
            stopStatsPolling()
            if status != .reasserting {
                connectedSince = nil
                lastSample = nil
                stats = nil
            }
        }
    }

    private func startStatsPolling() {
        guard statsTimer == nil else { return }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollStats()
        }
        pollStats()
    }

    private func stopStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func pollStats() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        do {
            try session.sendProviderMessage(Data("stats".utf8)) { [weak self] response in
                guard
                    let response,
                    let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
                else { return }
                let runtime = obj["runtime"] as? String ?? ""
                let parsed = parseRuntimeStats(runtime)
                let activeEndpoint = obj["activeEndpoint"] as? String
                let isFallback = obj["isFallback"] as? Bool ?? false
                Task { @MainActor in
                    self?.updateStats(parsed, activeEndpoint: activeEndpoint, isFallback: isFallback)
                }
            }
        } catch {
            // Transient (tunnel not ready yet); ignore and retry next tick.
        }
    }

    private func updateStats(_ p: RuntimeStats, activeEndpoint: String?, isFallback: Bool) {
        let now = Date()
        var rxRate = 0.0
        var txRate = 0.0
        if let last = lastSample {
            let dt = now.timeIntervalSince(last.at)
            if dt > 0 {
                rxRate = max(0, Double(p.rxBytes - last.rx) / dt)
                txRate = max(0, Double(p.txBytes - last.tx) / dt)
            }
        }
        lastSample = (p.rxBytes, p.txBytes, now)
        stats = ConnectionStats(
            rxBytes: p.rxBytes, txBytes: p.txBytes,
            rxRate: rxRate, txRate: txRate,
            lastHandshakeSeconds: p.lastHandshakeSeconds,
            activeEndpoint: activeEndpoint, isFallback: isFallback,
            connectedSince: connectedSince
        )
    }

    /// Remove the saved tunnel configuration.
    func deleteProfile() async {
        stopStatsPolling()
        do {
            try await manager?.removeFromPreferences()
        } catch {
            lastError = error.localizedDescription
        }
        manager = nil
        hasProfile = false
        stats = nil
        connectedSince = nil
        lastSample = nil
        status = .invalid
    }
}
