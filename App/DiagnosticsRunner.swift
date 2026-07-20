import Foundation
import Network

/// Runs app-side reachability probes for a profile's endpoints. QUIC endpoints get
/// a real QUIC/TLS handshake probe; mask endpoints report `needsTunnel` (upgraded to
/// `reachableViaTunnel` by the live status). Nothing is persisted.
@MainActor
final class DiagnosticsRunner: ObservableObject {
    @Published private(set) var results: [DiagnosticResult] = []
    @Published private(set) var isRunning = false

    private let timeout: TimeInterval = 4
    private let queue = DispatchQueue(label: "com.stealthwg.diagnostics")

    /// Probes every target concurrently, then applies live status.
    func run(for profile: StealthProfile, activeEndpoint: String?, handshakeRecent: Bool) {
        let targets = diagnosticTargets(for: profile)
        results = targets.map { DiagnosticResult(target: $0, status: .pending) }
        isRunning = true

        let group = DispatchGroup()
        for (index, target) in targets.enumerated() {
            group.enter()
            probe(target) { [weak self] status in
                Task { @MainActor in
                    self?.update(index: index, status: status)
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.results = applyLiveStatus(self.results, activeEndpoint: activeEndpoint, handshakeRecent: handshakeRecent)
            self.isRunning = false
        }
    }

    private func update(index: Int, status: DiagnosticStatus) {
        guard results.indices.contains(index) else { return }
        results[index].status = status
    }

    /// Probes one target. Mask/UDP is not directly probeable, so it reports
    /// needsTunnel. QUIC opens an NWConnection with QUIC + ALPN h3, accepting the
    /// self-signed cert (WireGuard authenticates the peer, not TLS).
    private func probe(_ target: DiagnosticTarget, completion: @escaping (DiagnosticStatus) -> Void) {
        guard target.port > 0, let port = NWEndpoint.Port(rawValue: UInt16(target.port)) else {
            completion(.unreachable("bad port")); return
        }
        let host = NWEndpoint.Host(target.host)

        if target.transport != "quic" {
            completion(.needsTunnel)
            return
        }

        let quic = NWProtocolQUIC.Options(alpn: ["h3"])
        sec_protocol_options_set_verify_block(
            quic.securityProtocolOptions,
            { _, _, complete in complete(true) },
            queue
        )
        let params = NWParameters(quic: quic)
        let conn = NWConnection(host: host, port: port, using: params)

        let start = Date()
        var finished = false
        let finish: (DiagnosticStatus) -> Void = { status in
            if finished { return }
            finished = true
            conn.cancel()
            completion(status)
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(.reachableQUIC(rttMillis: Int(Date().timeIntervalSince(start) * 1000)))
            case .failed(let error):
                finish(.unreachable(error.localizedDescription))
            case .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(.timeout) }
    }
}
