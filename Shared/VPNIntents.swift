import AppIntents
import NetworkExtension
import WidgetKit

/// A StealthWG profile chooseable in Shortcuts / the Quick-connect widget.
struct ProfileEntity: AppEntity, Identifiable {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Profile"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = ProfileQuery()
}

struct ProfileQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ProfileEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [ProfileEntity] { try await all() }

    private func all() async throws -> [ProfileEntity] {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.compactMap { m in
            let pc = (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
            guard let id = pc?["profileID"] as? String else { return nil }
            return ProfileEntity(id: id, name: m.localizedDescription ?? "StealthWG")
        }
    }
}

enum VPNIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noProfile
    var localizedStringResource: LocalizedStringResource {
        switch self { case .noProfile: return "Add a profile in StealthWG first." }
    }
}

private func statusToState(_ s: NEVPNStatus) -> WidgetSnapshot.State {
    switch s {
    case .connected: return .masked
    case .connecting, .reasserting: return .masking
    default: return .exposed
    }
}

/// Waits until the tunnel reaches its FINAL status (or times out), so the reload
/// WidgetKit guarantees right after a widget-button tap renders the real settled
/// state — not a transient "connecting" that would otherwise get stuck until an
/// unreliable background refresh. This is the one rock-solid update path on iOS:
/// a tap → one guaranteed reload → we make sure that reload shows the truth.
private func waitForSettled(_ m: NETunnelProviderManager, connecting: Bool,
                            timeout: TimeInterval = 10) async -> NEVPNStatus {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let s = m.connection.status
        if connecting, s == .connected { return s }
        if !connecting, s == .disconnected || s == .invalid { return s }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
    return m.connection.status
}

/// Writes the settled state to the app group and reloads the widgets from this
/// (user-initiated, foreground-priority) context — the most reliable moment for a
/// reload to land. The widgets also read the live status on render, so this is
/// belt-and-suspenders: either path yields the correct final state.
private func publishSettled(_ status: NEVPNStatus, _ m: NETunnelProviderManager) {
    let state = statusToState(status)
    let pc = (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
    var snap = WidgetStore.load()
    snap.state = state
    snap.profileName = m.localizedDescription ?? (pc?["profileName"] as? String) ?? snap.profileName
    snap.transport = (pc?["transport"] as? String) ?? snap.transport ?? "mask"
    snap.connectedSince = state == .masked ? m.connection.connectedDate : nil
    if state == .exposed { snap.rxRate = 0; snap.txRate = 0; snap.lastHandshakeSeconds = 0 }
    WidgetStore.save(snap)
    WidgetCenter.shared.reloadAllTimelines()
}

/// Starts the tunnel, waits for it to settle, then publishes the real state.
private func connectAndPublish(_ m: NETunnelProviderManager) async throws {
    m.isEnabled = true
    try await m.saveToPreferences()
    try await m.loadFromPreferences()
    try (m.connection as? NETunnelProviderSession)?.startTunnel()
    let status = await waitForSettled(m, connecting: true)
    publishSettled(status, m)
}

/// Stops the tunnel, waits for it to settle, then publishes the real state.
private func disconnectAndPublish(_ m: NETunnelProviderManager) async {
    m.connection.stopVPNTunnel()
    let status = await waitForSettled(m, connecting: false)
    publishSettled(status, m)
}

/// Loads the target manager: the named profile, else the last-selected one, else the first.
private func targetManager(_ profile: ProfileEntity?) async throws -> NETunnelProviderManager {
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
    func id(_ m: NETunnelProviderManager) -> String? {
        (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["profileID"] as? String
    }
    if let pid = profile?.id ?? WidgetStore.selectedProfileID(),
       let m = managers.first(where: { id($0) == pid }) { return m }
    guard let first = managers.first else { throw VPNIntentError.noProfile }
    return first
}

struct ConnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect StealthWG"
    static var openAppWhenRun = false
    @Parameter(title: "Profile") var profile: ProfileEntity?

    func perform() async throws -> some IntentResult {
        let m = try await targetManager(profile)
        try await connectAndPublish(m)
        return .result()
    }
}

struct DisconnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect StealthWG"
    static var openAppWhenRun = false
    @Parameter(title: "Profile") var profile: ProfileEntity?

    func perform() async throws -> some IntentResult {
        let m = try await targetManager(profile)
        await disconnectAndPublish(m)
        return .result()
    }
}

struct ToggleVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle StealthWG"
    static var openAppWhenRun = false
    @Parameter(title: "Profile") var profile: ProfileEntity?

    func perform() async throws -> some IntentResult {
        let m = try await targetManager(profile)
        switch m.connection.status {
        case .connected, .connecting, .reasserting:
            await disconnectAndPublish(m)
        default:
            try await connectAndPublish(m)
        }
        return .result()
    }
}

/// Set-value intent for the Control Center toggle (true = connect, false = disconnect).
struct SetVPNIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set StealthWG"
    @Parameter(title: "Masked") var value: Bool

    func perform() async throws -> some IntentResult {
        let m = try await targetManager(nil)
        if value {
            try await connectAndPublish(m)
        } else {
            await disconnectAndPublish(m)
        }
        return .result()
    }
}

struct StealthShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleVPNIntent(), phrases: ["Toggle \(.applicationName)"],
                    shortTitle: "Toggle", systemImageName: "shield.lefthalf.filled")
        AppShortcut(intent: ConnectVPNIntent(), phrases: ["Connect \(.applicationName)"],
                    shortTitle: "Connect", systemImageName: "shield.fill")
        AppShortcut(intent: DisconnectVPNIntent(), phrases: ["Disconnect \(.applicationName)"],
                    shortTitle: "Disconnect", systemImageName: "shield.slash")
    }
}
