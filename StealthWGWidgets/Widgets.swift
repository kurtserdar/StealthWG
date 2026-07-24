import WidgetKit
import SwiftUI
import AppIntents
import NetworkExtension

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    var profile: ProfileEntity? = nil
}

/// Reads the ACTUAL VPN state live from NetworkExtension, so the widget always
/// reflects the real connection whenever it renders — independent of whether any
/// pushed snapshot or reload actually landed (the source of the old "stuck"
/// widgets). Pushed reloads are now just a nudge to re-render sooner; correctness
/// no longer depends on them. Falls back to the app-group snapshot only if the
/// managers can't be read (e.g. the entitlement isn't granted).
///
/// `preferred` pins the read to a specific profile (the Quick-connect widget's
/// configured one); otherwise it shows whichever profile is live, else selected.
func liveSnapshot(preferred: String? = nil) async -> WidgetSnapshot {
    var snap = WidgetStore.load()   // endpoint + last-known details, and the fallback
    guard let managers = try? await NETunnelProviderManager.loadAllFromPreferences(),
          !managers.isEmpty else { return snap }

    func pid(_ m: NETunnelProviderManager) -> String? {
        (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["profileID"] as? String
    }
    func isLive(_ m: NETunnelProviderManager) -> Bool {
        switch m.connection.status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }
    let selectedID = WidgetStore.selectedProfileID()
    let m = (preferred.flatMap { p in managers.first { pid($0) == p } })
        ?? managers.first(where: isLive)
        ?? managers.first { pid($0) == selectedID }
        ?? managers[0]

    let pc = (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
    switch m.connection.status {
    case .connected:                return applyLive(&snap, .masked, m, pc)
    case .connecting, .reasserting: return applyLive(&snap, .masking, m, pc)
    default:                        return applyLive(&snap, .exposed, m, pc)
    }
}

private func applyLive(_ snap: inout WidgetSnapshot, _ state: WidgetSnapshot.State,
                       _ m: NETunnelProviderManager, _ pc: [String: Any]?) -> WidgetSnapshot {
    snap.state = state
    snap.connectedSince = state == .masked ? m.connection.connectedDate : nil
    if let name = m.localizedDescription { snap.profileName = name }
    if let t = pc?["transport"] as? String { snap.transport = t }
    if state == .exposed { snap.rxRate = 0; snap.txRate = 0; snap.lastHandshakeSeconds = 0 }
    return snap
}

/// "masking" is a short-lived transitional state — refresh soon so the widget
/// catches the flip to "masked" even if the push-reload is missed. Steady states
/// lean on push-reloads on change; this slow backstop just guarantees eventual
/// correctness without burning the WidgetKit refresh budget.
private func refreshDate(for state: WidgetSnapshot.State) -> Date {
    Date().addingTimeInterval(state == .masking ? 15 : 600)
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { .init(date: Date(), snapshot: .empty) }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        Task { completion(.init(date: Date(), snapshot: await liveSnapshot())) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        Task {
            let snap = await liveSnapshot()
            let entry = SnapshotEntry(date: Date(), snapshot: snap)
            completion(Timeline(entries: [entry], policy: .after(refreshDate(for: snap.state))))
        }
    }
}

/// Timeline provider for the configurable Quick-connect widget; carries the chosen
/// profile through to the connect button and reads that profile's live status.
struct ConfigProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { .init(date: Date(), snapshot: .empty) }
    func snapshot(for configuration: QuickConnectConfig, in context: Context) async -> SnapshotEntry {
        .init(date: Date(), snapshot: await liveSnapshot(preferred: configuration.profile?.id), profile: configuration.profile)
    }
    func timeline(for configuration: QuickConnectConfig, in context: Context) async -> Timeline<SnapshotEntry> {
        let snap = await liveSnapshot(preferred: configuration.profile?.id)
        return Timeline(entries: [.init(date: Date(), snapshot: snap, profile: configuration.profile)],
                        policy: .after(refreshDate(for: snap.state)))
    }
}

// MARK: - Shield (small, toggle)

struct ShieldWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ShieldWidget", provider: SnapshotProvider()) { entry in
            ShieldView(snap: entry.snapshot).containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Shield")
        .description("Status and one-tap toggle.")
        .supportedFamilies([.systemSmall])
    }
}

struct ShieldView: View {
    let snap: WidgetSnapshot
    var body: some View {
        let c = WidgetTheme.accent(snap.accentName)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                GhostMark(color: c).frame(width: 22)
                Text("StealthWG").font(.system(.caption2, design: .rounded).weight(.bold)).foregroundStyle(.secondary)
                Spacer()
            }
            Spacer()
            Text(snap.statusLabel).font(.system(.title2, design: .rounded).weight(.heavy)).foregroundStyle(c)
            Text("\(snap.profileName ?? "No profile") · \((snap.transport ?? "mask").uppercased())")
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            Button(intent: ToggleVPNIntent()) {
                Text(snap.state == .exposed ? "Connect" : "Disconnect")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
            }
            .buttonStyle(.borderedProminent).tint(c)
        }
    }
}

// MARK: - Quick connect (small, configurable)

struct QuickConnectConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Quick connect"
    @Parameter(title: "Profile") var profile: ProfileEntity?
}

struct QuickConnectWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "QuickConnectWidget", intent: QuickConnectConfig.self, provider: ConfigProvider()) { entry in
            QuickConnectView(entry: entry).containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Quick connect")
        .description("Connect a chosen profile.")
        .supportedFamilies([.systemSmall])
    }
}

struct QuickConnectView: View {
    let entry: SnapshotEntry
    private func connectIntent() -> ConnectVPNIntent {
        let i = ConnectVPNIntent()
        i.profile = entry.profile
        return i
    }
    var body: some View {
        let c = WidgetTheme.accent("teal")
        VStack(alignment: .leading, spacing: 6) {
            GhostMark(color: c, filled: false).frame(width: 26)
            Spacer()
            Text(entry.profile?.name ?? "Connect")
                .font(.system(.title3, design: .rounded).weight(.heavy)).foregroundStyle(.primary).lineLimit(1)
            Button(intent: connectIntent()) {
                Text("Tap to connect").font(.caption2)
            }
            .buttonStyle(.bordered).tint(c)
        }
    }
}

// MARK: - Control Center (iOS 18)

@available(iOS 18.0, *)
struct StealthControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "StealthControl") {
            ControlWidgetToggle("StealthWG", isOn: WidgetStore.load().state != .exposed, action: SetVPNIntent()) { on in
                Label(on ? "Masked" : "Exposed", systemImage: "shield.lefthalf.filled")
            }
        }
        .displayName("StealthWG")
    }
}
