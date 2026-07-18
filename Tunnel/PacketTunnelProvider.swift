import NetworkExtension
import WireGuardKit

/// Packet tunnel provider for StealthWG.
///
/// Reads the profile the app stored in the provider configuration, enables the
/// UdpMask bind (when a mask key is present) via `wgSetStealthKey`, then starts
/// the WireGuard engine through `WireGuardAdapter`. The masking itself lives in
/// the wireguard-go bind, so from here on this is a normal WireGuard tunnel.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter = WireGuardAdapter(with: self) { _, message in
        NSLog("[StealthWG] %@", message)
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let providerConfiguration = proto.providerConfiguration,
            let wgQuickConfig = providerConfiguration["wgQuickConfig"] as? String
        else {
            completionHandler(PacketTunnelProviderError.missingConfiguration)
            return
        }

        let tunnelConfiguration: TunnelConfiguration
        do {
            tunnelConfiguration = try TunnelConfiguration(fromWgQuickConfig: wgQuickConfig)
        } catch {
            completionHandler(PacketTunnelProviderError.invalidConfiguration(error))
            return
        }

        // Install (or clear) the masking key before the adapter creates the
        // wireguard-go device. An empty string means plain WireGuard.
        let maskKey = (providerConfiguration["maskKey"] as? String) ?? ""
        if wgSetStealthKey(maskKey) != 0 {
            completionHandler(PacketTunnelProviderError.invalidMaskKey)
            return
        }

        adapter.start(tunnelConfiguration: tunnelConfiguration) { adapterError in
            completionHandler(adapterError)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        adapter.stop { _ in
            completionHandler()
        }
    }
}

enum PacketTunnelProviderError: Error {
    case missingConfiguration
    case invalidConfiguration(Error)
    case invalidMaskKey
}
