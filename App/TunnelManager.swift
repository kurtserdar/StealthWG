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

/// A saved StealthWG profile — one NETunnelProviderManager.
struct TunnelProfile: Identifiable, Equatable {
    let id: String
    let name: String
    let profile: StealthProfile
    var onDemand: Bool = false      // manager.isOnDemandEnabled (always-on)
    var killSwitch: Bool = false    // protocol.includeAllNetworks (full tunnel)
    var allowLocal: Bool = false    // protocol.excludeLocalNetworks (LAN reachable)
}

/// Observable multi-profile wrapper the UI binds to. Each profile is a separate
/// NETunnelProviderManager; only one tunnel can be active at a time.
@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var profiles: [TunnelProfile] = []
    @Published private(set) var statuses: [String: NEVPNStatus] = [:]
    @Published private(set) var stats: ConnectionStats?
    @Published private(set) var lastError: String?
    @Published var selectedID: String?
    @Published private(set) var logLines: [LogEntry] = []

    private var managers: [String: NETunnelProviderManager] = [:]
    private var observers: [NSObjectProtocol] = []
    private var statsTimer: Timer?
    private var logTimer: Timer?
    private var logCursor = 0

    /// Persisted app setting: when off, the extension keeps no log buffer. Read at
    /// tunnel start via providerConfiguration.
    var loggingEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: "loggingEnabled") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "loggingEnabled") }
    }
    private var lastSample: (rx: Int64, tx: Int64, at: Date)?
    private var connectedSince: Date?

    var selectedProfile: TunnelProfile? { profiles.first { $0.id == selectedID } }
    var connectedID: String? { profiles.first { isActive(statuses[$0.id] ?? .invalid) }?.id }
    func status(of id: String?) -> NEVPNStatus { id.flatMap { statuses[$0] } ?? .invalid }

    private func isActive(_ s: NEVPNStatus) -> Bool {
        s == .connected || s == .connecting || s == .reasserting
    }

    // MARK: - Load

    func load() async {
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            rebuild(from: all)
            selectedID = connectedID ?? profiles.first?.id
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func rebuild(from all: [NETunnelProviderManager]) {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        managers.removeAll()
        var list: [TunnelProfile] = []
        for m in all {
            guard
                let proto = m.protocolConfiguration as? NETunnelProviderProtocol,
                proto.providerConfiguration?["wgQuickConfig"] is String,
                let parsed = try? StealthProfile.parse(assemble(proto))
            else { continue }
            let id = (proto.providerConfiguration?["profileID"] as? String) ?? UUID().uuidString
            managers[id] = m
            statuses[id] = m.connection.status
            list.append(TunnelProfile(
                id: id, name: m.localizedDescription ?? "StealthWG", profile: parsed,
                onDemand: m.isOnDemandEnabled,
                killSwitch: proto.includeAllNetworks,
                allowLocal: proto.excludeLocalNetworks
            ))
            observe(id: id, connection: m.connection)
        }
        profiles = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func assemble(_ proto: NETunnelProviderProtocol) -> String {
        let cfg = proto.providerConfiguration?["wgQuickConfig"] as? String ?? ""
        let mask = proto.providerConfiguration?["maskKey"] as? String
        let eps = proto.providerConfiguration?["endpoints"] as? [String] ?? []
        let transport = proto.providerConfiguration?["transport"] as? String ?? StealthProfile.defaultTransport
        let sni = proto.providerConfiguration?["sni"] as? String
        return StealthProfile(
            wgQuickConfig: cfg, maskKey: mask, endpoints: eps, transport: transport, sni: sni
        ).serialize()
    }

    private func observe(id: String, connection: NEVPNConnection) {
        let o = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: connection, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.statuses[id] = connection.status
            self.handleStatusChange(id: id, status: connection.status)
        }
        observers.append(o)
    }

    // MARK: - CRUD

    func addProfile(_ draft: ProfileDraft, name: String) async {
        await addProfile(name: name, raw: draft.build())
    }

    func addProfile(name: String, raw: String) async {
        do {
            let profile = try StealthProfile.parse(raw)
            let resolvedName = name.isEmpty ? defaultProfileName(for: profile) : name
            let m = NETunnelProviderManager()
            try await save(profile: profile, name: resolvedName, into: m, id: UUID().uuidString)
            await reloadAndSelect(preferName: resolvedName)
        } catch {
            lastError = describe(error)
        }
    }

    func updateProfile(id: String, name: String, raw: String) async {
        guard let m = managers[id] else { return }
        do {
            let profile = try StealthProfile.parse(raw)
            try await save(profile: profile, name: name, into: m, id: id)
            await reloadAndSelect(preferID: id)
        } catch {
            lastError = describe(error)
        }
    }

    private func save(profile: StealthProfile, name: String, into m: NETunnelProviderManager, id: String) async throws {
        // Preserve protocol-level hardening flags across a config rebuild (edit).
        let existing = m.protocolConfiguration as? NETunnelProviderProtocol
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TunnelConstants.tunnelBundleIdentifier
        proto.serverAddress = TunnelConstants.displayName
        var pc: [String: Any] = ["wgQuickConfig": profile.wgQuickConfig, "profileID": id]
        if let mask = profile.maskKey { pc["maskKey"] = mask }
        if !profile.endpoints.isEmpty { pc["endpoints"] = profile.endpoints }
        if profile.transport != StealthProfile.defaultTransport { pc["transport"] = profile.transport }
        if let sni = profile.sni { pc["sni"] = sni }
        pc["loggingEnabled"] = loggingEnabled
        proto.providerConfiguration = pc
        proto.includeAllNetworks = existing?.includeAllNetworks ?? false
        proto.excludeLocalNetworks = existing?.excludeLocalNetworks ?? false
        m.protocolConfiguration = proto
        m.localizedDescription = name.isEmpty ? TunnelConstants.displayName : name
        m.isEnabled = true
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        lastError = nil
    }

    private func reloadAndSelect(preferID: String? = nil, preferName: String? = nil) async {
        if let all = try? await NETunnelProviderManager.loadAllFromPreferences() {
            rebuild(from: all)
        }
        if let preferID, profiles.contains(where: { $0.id == preferID }) {
            selectedID = preferID
        } else if let preferName, let match = profiles.first(where: { $0.name == preferName }) {
            selectedID = match.id
        } else if selectedProfile == nil {
            selectedID = connectedID ?? profiles.first?.id
        }
    }

    func deleteProfile(id: String) async {
        guard let m = managers[id] else { return }
        if connectedID == id { stopStatsPolling() }
        do { try await m.removeFromPreferences() } catch { lastError = error.localizedDescription }
        await reloadAndSelect()
    }

    // MARK: - Connect

    func connect(id: String) {
        if let other = connectedID, other != id { managers[other]?.connection.stopVPNTunnel() }
        do {
            try managers[id]?.connection.startVPNTunnel()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disconnect(id: String) {
        managers[id]?.connection.stopVPNTunnel()
    }

    // MARK: - VPN options (on-demand / kill switch)

    func setOnDemand(id: String, enabled: Bool) async {
        guard let m = managers[id] else { return }
        do {
            if enabled {
                // Single always-on: turn on-demand off on every other profile first.
                for (otherID, other) in managers where otherID != id && other.isOnDemandEnabled {
                    other.isOnDemandEnabled = false
                    try await other.saveToPreferences()
                }
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                m.onDemandRules = [rule]
                m.isOnDemandEnabled = true
            } else {
                m.isOnDemandEnabled = false
            }
            m.isEnabled = true
            try await m.saveToPreferences()
            await reloadAndSelect(preferID: id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setKillSwitch(id: String, enabled: Bool) async {
        await setProtocolFlag(id: id) { $0.includeAllNetworks = enabled }
    }

    func setAllowLocal(id: String, enabled: Bool) async {
        await setProtocolFlag(id: id) { $0.excludeLocalNetworks = enabled }
    }

    private func setProtocolFlag(id: String, _ apply: (NETunnelProviderProtocol) -> Void) async {
        guard let m = managers[id], let proto = m.protocolConfiguration as? NETunnelProviderProtocol else { return }
        apply(proto)
        m.protocolConfiguration = proto
        do {
            try await m.saveToPreferences()
            await reloadAndSelect(preferID: id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func profileText(id: String) -> String? {
        guard let m = managers[id], let proto = m.protocolConfiguration as? NETunnelProviderProtocol else { return nil }
        return assemble(proto)
    }

    // MARK: - Stats (for the connected tunnel)

    private func handleStatusChange(id: String, status: NEVPNStatus) {
        if status == .connected {
            if connectedSince == nil { connectedSince = Date() }
            startStatsPolling(id: id)
        } else if !isActive(status), connectedID == nil {
            stopStatsPolling()
            connectedSince = nil
            lastSample = nil
            stats = nil
            stopLogPolling()
            logLines.removeAll()
            logCursor = 0
        }
    }

    private func startStatsPolling(id: String) {
        guard statsTimer == nil else { return }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollStats(id: id)
        }
        pollStats(id: id)
    }

    private func stopStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    private func pollStats(id: String) {
        guard let session = managers[id]?.connection as? NETunnelProviderSession else { return }
        do {
            try session.sendProviderMessage(Data("stats".utf8)) { [weak self] response in
                guard
                    let response,
                    let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
                else { return }
                let parsed = parseRuntimeStats(obj["runtime"] as? String ?? "")
                let ep = obj["activeEndpoint"] as? String
                let fb = obj["isFallback"] as? Bool ?? false
                Task { @MainActor in self?.updateStats(parsed, activeEndpoint: ep, isFallback: fb) }
            }
        } catch {
            // Transient; retry next tick.
        }
    }

    // MARK: - Ephemeral log polling

    /// Starts polling the connected tunnel's log buffer (call when the Log view
    /// appears). No-op if nothing is connected.
    func startLogPolling() {
        stopLogPolling()
        guard connectedID != nil else { return }
        logTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollLogs()
        }
        pollLogs()
    }

    func stopLogPolling() {
        logTimer?.invalidate()
        logTimer = nil
    }

    private func pollLogs() {
        guard
            let id = connectedID,
            let session = managers[id]?.connection as? NETunnelProviderSession
        else { return }
        do {
            try session.sendProviderMessage(Data("logs:\(logCursor)".utf8)) { [weak self] response in
                guard
                    let response,
                    let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                    let raw = obj["lines"] as? [[String: Any]]
                else { return }
                let newLines = raw.compactMap { d -> LogEntry? in
                    guard let seq = d["seq"] as? Int, let msg = d["msg"] as? String else { return nil }
                    let ts = d["ts"] as? Double ?? 0
                    return LogEntry(seq: seq, date: Date(timeIntervalSince1970: ts), message: msg)
                }
                let cursor = obj["cursor"] as? Int ?? self?.logCursor ?? 0
                Task { @MainActor in self?.appendLogLines(newLines, cursor: cursor) }
            }
        } catch {
            // Transient; retry next tick.
        }
    }

    @MainActor
    private func appendLogLines(_ newLines: [LogEntry], cursor: Int) {
        guard !newLines.isEmpty else { return }
        logLines.append(contentsOf: newLines)
        if logLines.count > 1000 { logLines.removeFirst(logLines.count - 1000) }
        logCursor = max(logCursor, cursor)
    }

    /// Clears the extension buffer and the local copy.
    func clearLogs() {
        if let id = connectedID, let session = managers[id]?.connection as? NETunnelProviderSession {
            try? session.sendProviderMessage(Data("logs:clear".utf8)) { _ in }
        }
        logLines.removeAll()
        logCursor = 0
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

    private func describe(_ error: Error) -> String {
        if case StealthProfile.ParseError.emptyConfiguration = error {
            return "The profile is empty or missing an [Interface] section."
        }
        return error.localizedDescription
    }
}
