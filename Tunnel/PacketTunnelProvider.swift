import NetworkExtension
import WireGuardKit
import WidgetKit

/// Packet tunnel provider for StealthWG.
///
/// Reads the profile the app stored in the provider configuration, enables the
/// UdpMask bind (when a mask key is present) via `wgSetStealthKey`, then starts
/// the WireGuard engine through `WireGuardAdapter`. The masking itself lives in
/// the wireguard-go bind, so from here on this is a normal WireGuard tunnel.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter = WireGuardAdapter(with: self) { [weak self] _, message in
        self?.log(message)
    }

    private let logBuffer = LogRingBuffer(capacity: 1000)
    private var loggingEnabled = true

    /// NSLogs and, when logging is enabled, appends to the ephemeral buffer.
    private func log(_ message: String) {
        NSLog("[StealthWG] %@", message)
        if loggingEnabled { logBuffer.append(message) }
    }

    private let pollQueue = DispatchQueue(label: "com.stealthwg.fallback")
    private var pollTimer: DispatchSourceTimer?
    private var plan: FallbackPlan?
    private var endpoints: [String] = []
    private var targets: [EndpointTarget] = []
    private var activeTransport = "mask"
    private var sni = ""
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

        // Select the transport (UDP mask vs QUIC) before the device is created.
        let transport = (providerConfiguration["transport"] as? String) ?? "mask"
        sni = (providerConfiguration["sni"] as? String) ?? ""
        loggingEnabled = (providerConfiguration["loggingEnabled"] as? Bool) ?? true

        // Resolve each candidate endpoint's transport (a quic://|mask:// scheme
        // overrides the profile transport for that endpoint).
        let rawEndpoints = providerConfiguration["endpoints"] as? [String] ?? []
        targets = rawEndpoints.map { parseEndpointTarget($0, defaultTransport: transport) }
        endpoints = targets.map(\.hostPort)
        activeTransport = targets.first?.transport ?? transport

        // Install (or clear) the masking key before the adapter creates the
        // wireguard-go device. An empty string means plain WireGuard.
        let maskKey = (providerConfiguration["maskKey"] as? String) ?? ""
        if wgSetStealthKey(maskKey) != 0 {
            completionHandler(PacketTunnelProviderError.invalidMaskKey)
            return
        }
        _ = wgSetTransport(activeTransport, sni)

        setStopping(false)
        publishWidgetSnapshot(state: .masking)
        adapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self] adapterError in
            if adapterError == nil {
                self?.startFallbackPolling()
                self?.publishWidgetSnapshot(state: .masked)
                self?.startWidgetStats()
            } else {
                self?.publishWidgetSnapshot(state: .exposed)
            }
            completionHandler(adapterError)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        stopFallbackPolling()
        setStopping(true)
        stopWidgetStats()
        publishWidgetSnapshot(state: .exposed)
        adapter.stop { _ in
            completionHandler()
        }
    }

    // MARK: - App messages (live stats for the UI)

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let command = String(data: messageData, encoding: .utf8) ?? ""

        if command == "logs:clear" {
            logBuffer.clear()
            completionHandler?(try? JSONSerialization.data(withJSONObject: [String: Any]()))
            return
        }
        if command.hasPrefix("logs:") {
            let since = Int(command.dropFirst("logs:".count)) ?? 0
            let lines = logBuffer.entries(since: since).map { entry -> [String: Any] in
                ["seq": entry.seq, "ts": entry.date.timeIntervalSince1970, "msg": entry.message]
            }
            let payload: [String: Any] = ["lines": lines, "cursor": logBuffer.latestCursor()]
            completionHandler?(try? JSONSerialization.data(withJSONObject: payload))
            return
        }

        // Default: live stats (unchanged).
        adapter.getRuntimeConfiguration { [weak self] runtime in
            let payload: [String: Any] = [
                "runtime": runtime ?? "",
                "activeEndpoint": self?.currentActiveEndpoint() as Any,
                "isFallback": (self?.currentIndex ?? 0) > 0
            ]
            completionHandler?(try? JSONSerialization.data(withJSONObject: payload))
        }
    }

    private func currentActiveEndpoint() -> String? {
        guard !endpoints.isEmpty, currentIndex < endpoints.count else { return nil }
        return endpoints[currentIndex]
    }

    // MARK: - Widget snapshot (keeps widgets fresh without the app)

    private var widgetTimer: DispatchSourceTimer?
    private var lastWidgetSample: (rx: Int64, tx: Int64, at: Date)?
    private let widgetLock = NSLock()
    private var stopping = false

    private func setStopping(_ v: Bool) { widgetLock.lock(); stopping = v; widgetLock.unlock() }
    private func isStopping() -> Bool { widgetLock.lock(); defer { widgetLock.unlock() }; return stopping }

    /// Writes the current state to the app group and (by default) reloads the
    /// widgets. Runs in the extension, so widgets update on connect/disconnect even
    /// when the app is closed. `reload` is false for the periodic throughput writes
    /// so they don't burn the scarce WidgetKit reload budget — only real state
    /// changes reload; the fresh numbers ride along on the next refresh.
    private func publishWidgetSnapshot(state: WidgetSnapshot.State, rxRate: Double = 0, txRate: Double = 0, lastHandshake: Int = 0, reload: Bool = true) {
        // Once we start tearing down, don't let an in-flight stats update re-write
        // .masked over the .exposed we just published (the stop race).
        if state != .exposed, isStopping() { return }
        let pc = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        var snap = WidgetStore.load()
        snap.state = state
        snap.profileName = (pc?["profileName"] as? String) ?? snap.profileName
        snap.transport = (pc?["transport"] as? String) ?? "mask"
        snap.endpoint = currentActiveEndpoint() ?? snap.endpoint
        switch state {
        case .masked:
            snap.rxRate = rxRate
            snap.txRate = txRate
            snap.lastHandshakeSeconds = lastHandshake
            if snap.connectedSince == nil { snap.connectedSince = Date() }
        case .exposed:
            snap.rxRate = 0; snap.txRate = 0
            snap.connectedSince = nil; snap.lastHandshakeSeconds = 0
        case .masking:
            break
        }
        WidgetStore.save(snap)
        if reload { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// While connected, refresh the widgets' throughput periodically. Home-screen
    /// widgets are not real-time (iOS throttles refreshes), so this is a best-effort
    /// cadence, not per-second.
    private func startWidgetStats() {
        stopWidgetStats()
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 5, repeating: 30)
        timer.setEventHandler { [weak self] in self?.updateWidgetStats() }
        widgetTimer = timer
        timer.resume()
    }

    private func stopWidgetStats() {
        widgetTimer?.cancel()
        widgetTimer = nil
        lastWidgetSample = nil
    }

    private func updateWidgetStats() {
        adapter.getRuntimeConfiguration { [weak self] runtime in
            guard let self, let runtime else { return }
            let s = parseRuntimeStats(runtime)
            var rx = 0.0, tx = 0.0
            let now = Date()
            if let last = self.lastWidgetSample {
                let dt = now.timeIntervalSince(last.at)
                if dt > 0 {
                    rx = max(0, Double(s.rxBytes - last.rx) / dt)
                    tx = max(0, Double(s.txBytes - last.tx) / dt)
                }
            }
            self.lastWidgetSample = (s.rxBytes, s.txBytes, now)
            // Write fresh numbers but DON'T reload — reloading every 15 s would burn
            // the WidgetKit budget and freeze state updates on the other widgets.
            self.publishWidgetSnapshot(state: .masked, rxRate: rx, txRate: tx, lastHandshake: s.lastHandshakeSeconds, reload: false)
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
                    self.log(String(format: "handshake on endpoint %d (%@)", self.currentIndex, self.endpoints[self.currentIndex]))
                    self.pollTimer?.cancel(); self.pollTimer = nil
                case .keepWaiting:
                    break
                case .tryNext(let i):
                    self.currentIndex = i
                    self.endpointStart = Date()
                    let target = self.targets[i]
                    self.log(String(format: "no handshake, trying endpoint %d (%@ via %@)", i, target.hostPort, target.transport))
                    if target.transport == self.activeTransport {
                        // Same transport: an in-place peer-endpoint update (cheap).
                        if let cfg = self.configuration(withEndpoint: target.hostPort) {
                            self.adapter.update(tunnelConfiguration: cfg) { _ in }
                        }
                    } else {
                        // Transport changed: the bind is fixed at device creation,
                        // so restart the engine with the new transport selected.
                        self.restartEngine(with: target)
                    }
                case .exhausted:
                    self.log("all endpoints exhausted; staying on last")
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

    /// Restarts the wireguard-go engine with a new transport selected. The bind
    /// (mask vs QUIC) is chosen when the device is created, so switching
    /// transports mid-tunnel requires a stop/start rather than an endpoint update.
    private func restartEngine(with target: EndpointTarget) {
        guard let cfg = configuration(withEndpoint: target.hostPort) else { return }
        activeTransport = target.transport
        _ = wgSetTransport(target.transport, sni)
        adapter.stop { [weak self] _ in
            self?.adapter.start(tunnelConfiguration: cfg) { error in
                if let error {
                    self?.log(String(format: "transport restart failed: %@", String(describing: error)))
                }
            }
        }
    }
}

enum PacketTunnelProviderError: Error {
    case missingConfiguration
    case invalidConfiguration(Error)
    case invalidMaskKey
}
