import NetworkExtension

/// Packet tunnel provider for StealthWG.
///
/// This is currently a skeleton: it configures a minimal tunnel network
/// setting so the system reports the tunnel as connected, then idles. The
/// WireGuard engine and the obfuscation transport are integrated in later
/// steps; no packets are actually forwarded yet.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Minimal settings so iOS accepts the tunnel as up. The remote address
        // is a placeholder; real values come from the imported WireGuard
        // profile once the engine is wired in.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.ipv4Settings = {
            let ipv4 = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.255"])
            ipv4.includedRoutes = [] // Do not route real traffic yet.
            return ipv4
        }()
        settings.mtu = 1420

        setTunnelNetworkSettings(settings) { error in
            completionHandler(error)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        completionHandler?(nil)
    }
}
