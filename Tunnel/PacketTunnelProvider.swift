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

    private let pollQueue = DispatchQueue(label: "com.stealthwg.fallback")
    private var pollTimer: DispatchSourceTimer?
    private var plan: FallbackPlan?
    private var endpoints: [String] = []
    private var currentIndex = 0
    private var endpointStart = Date()
    private var baseConfiguration: TunnelConfiguration?

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
        baseConfiguration = tunnelConfiguration
        endpoints = providerConfiguration["endpoints"] as? [String] ?? []

        // Install (or clear) the masking key before the adapter creates the
        // wireguard-go device. An empty string means plain WireGuard.
        let maskKey = (providerConfiguration["maskKey"] as? String) ?? ""
        if wgSetStealthKey(maskKey) != 0 {
            completionHandler(PacketTunnelProviderError.invalidMaskKey)
            return
        }

        adapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self] adapterError in
            if adapterError == nil { self?.startFallbackPolling() }
            completionHandler(adapterError)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        stopFallbackPolling()
        adapter.stop { _ in
            completionHandler()
        }
    }

    // MARK: - Endpoint fallback

    private func startFallbackPolling() {
        pollQueue.async { [weak self] in
            guard let self, self.endpoints.count > 1 else { return }
            self.plan = FallbackPlan(endpointCount: self.endpoints.count, perEndpointTimeout: 12)
            self.currentIndex = 0
            self.endpointStart = Date()
            let timer = DispatchSource.makeTimerSource(queue: self.pollQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.pollOnce() }
            self.pollTimer = timer
            timer.resume()
        }
    }

    private func stopFallbackPolling() {
        pollQueue.async { [weak self] in
            self?.pollTimer?.cancel()
            self?.pollTimer = nil
        }
    }

    private func pollOnce() {
        adapter.getRuntimeConfiguration { [weak self] runtime in
            self?.pollQueue.async {
                guard let self, let plan = self.plan else { return }
                let handshaked = (runtime.map { lastHandshakeSeconds(fromRuntimeConfig: $0) } ?? 0) > 0
                let elapsed = Date().timeIntervalSince(self.endpointStart)
                switch plan.decide(index: self.currentIndex, elapsed: elapsed, handshaked: handshaked) {
                case .connected:
                    NSLog("[StealthWG] handshake on endpoint %d (%@)", self.currentIndex, self.endpoints[self.currentIndex])
                    self.pollTimer?.cancel(); self.pollTimer = nil
                case .keepWaiting:
                    break
                case .tryNext(let i):
                    self.currentIndex = i
                    self.endpointStart = Date()
                    NSLog("[StealthWG] no handshake, trying endpoint %d (%@)", i, self.endpoints[i])
                    if let cfg = self.configuration(withEndpoint: self.endpoints[i]) {
                        self.adapter.update(tunnelConfiguration: cfg) { _ in }
                    }
                case .exhausted:
                    NSLog("[StealthWG] all endpoints exhausted; staying on last")
                    self.pollTimer?.cancel(); self.pollTimer = nil
                }
            }
        }
    }

    private func configuration(withEndpoint endpoint: String) -> TunnelConfiguration? {
        guard let base = baseConfiguration, let ep = Endpoint(from: endpoint) else { return nil }
        var peers = base.peers
        guard !peers.isEmpty else { return nil }
        peers[0].endpoint = ep
        return TunnelConfiguration(name: base.name, interface: base.interface, peers: peers)
    }
}

enum PacketTunnelProviderError: Error {
    case missingConfiguration
    case invalidConfiguration(Error)
    case invalidMaskKey
}
