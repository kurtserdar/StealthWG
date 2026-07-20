import Foundation

/// The state the widgets render, shared from the app via the app group.
struct WidgetSnapshot: Codable, Equatable {
    enum State: String, Codable { case masked, masking, exposed }

    var state: State = .exposed
    var profileName: String?
    var transport: String?          // "mask" | "quic"
    var endpoint: String?
    var rxRate: Double = 0
    var txRate: Double = 0
    var connectedSince: Date?
    var lastHandshakeSeconds: Int = 0

    static let empty = WidgetSnapshot()

    /// "Masked" | "Masking…" | "Exposed".
    var statusLabel: String {
        switch state {
        case .masked: return "Masked"
        case .masking: return "Masking…"
        case .exposed: return "Exposed"
        }
    }
    /// Accent token the widget views map to a Color.
    var accentName: String {
        switch state {
        case .masked: return "teal"
        case .masking: return "amber"
        case .exposed: return "coral"
        }
    }
}

/// Reads/writes the snapshot in the shared app group. Also stores the id of the
/// profile an intent should act on when none is specified.
enum WidgetStore {
    static let appGroup = "group.com.stealthwg"
    private static let snapshotKey = "widgetSnapshot"
    private static let selectedKey = "selectedProfileID"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load() -> WidgetSnapshot {
        guard let data = defaults?.data(forKey: snapshotKey),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .empty }
        return snap
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: snapshotKey)
    }

    static func selectedProfileID() -> String? { defaults?.string(forKey: selectedKey) }
    static func setSelectedProfileID(_ id: String?) { defaults?.set(id, forKey: selectedKey) }
}
