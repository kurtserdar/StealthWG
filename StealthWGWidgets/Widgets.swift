import WidgetKit
import SwiftUI
import AppIntents

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    var profile: ProfileEntity? = nil
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { .init(date: Date(), snapshot: .empty) }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(.init(date: Date(), snapshot: WidgetStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetStore.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }
}

/// Timeline provider for the configurable Quick-connect widget; carries the chosen
/// profile through to the connect button.
struct ConfigProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { .init(date: Date(), snapshot: .empty) }
    func snapshot(for configuration: QuickConnectConfig, in context: Context) async -> SnapshotEntry {
        .init(date: Date(), snapshot: WidgetStore.load(), profile: configuration.profile)
    }
    func timeline(for configuration: QuickConnectConfig, in context: Context) async -> Timeline<SnapshotEntry> {
        Timeline(entries: [.init(date: Date(), snapshot: WidgetStore.load(), profile: configuration.profile)],
                 policy: .after(Date().addingTimeInterval(60)))
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

// MARK: - Status board (medium)

struct StatusBoardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StatusBoardWidget", provider: SnapshotProvider()) { entry in
            StatusBoardView(snap: entry.snapshot).containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Status board")
        .description("Live throughput and endpoint.")
        .supportedFamilies([.systemMedium])
    }
}

struct StatusBoardView: View {
    let snap: WidgetSnapshot
    private func rate(_ b: Double) -> String {
        b > 1_000_000 ? String(format: "%.1f MB/s", b / 1_000_000) : String(format: "%.0f KB/s", b / 1000)
    }
    var body: some View {
        let c = WidgetTheme.accent(snap.accentName)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                GhostMark(color: c).frame(width: 26)
                Text("StealthWG").font(.system(.subheadline, design: .rounded).weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Text(snap.statusLabel).font(.system(.caption2, design: .monospaced)).foregroundStyle(c)
                    .padding(.horizontal, 8).padding(.vertical, 3).overlay(Capsule().stroke(c))
            }
            Text("\(snap.profileName ?? "—") · \((snap.transport ?? "mask").uppercased()) · \(snap.endpoint ?? "—")")
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            HStack(spacing: 18) {
                Label(rate(snap.rxRate), systemImage: "arrow.down").foregroundStyle(c)
                Label(rate(snap.txRate), systemImage: "arrow.up")
            }.font(.system(.footnote, design: .monospaced))
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
