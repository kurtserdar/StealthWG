import AppIntents
import NetworkExtension

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
        m.isEnabled = true
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        try (m.connection as? NETunnelProviderSession)?.startTunnel()
        return .result()
    }
}

struct DisconnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect StealthWG"
    static var openAppWhenRun = false
    @Parameter(title: "Profile") var profile: ProfileEntity?

    func perform() async throws -> some IntentResult {
        let m = try await targetManager(profile)
        m.connection.stopVPNTunnel()
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
            m.connection.stopVPNTunnel()
        default:
            m.isEnabled = true
            try await m.saveToPreferences()
            try await m.loadFromPreferences()
            try (m.connection as? NETunnelProviderSession)?.startTunnel()
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
            m.isEnabled = true
            try await m.saveToPreferences()
            try await m.loadFromPreferences()
            try (m.connection as? NETunnelProviderSession)?.startTunnel()
        } else {
            m.connection.stopVPNTunnel()
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
