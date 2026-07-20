import SwiftUI

/// Edits the Wi-Fi SSIDs where on-demand should not auto-connect, plus the
/// cellular preference. Applies each change immediately via the tunnel manager.
struct TrustedNetworksView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    let profileID: String

    @State private var ssids: [String]
    @State private var trustCellular: Bool
    @State private var newSSID = ""

    init(profileID: String, ssids: [String], trustCellular: Bool) {
        self.profileID = profileID
        _ssids = State(initialValue: ssids)
        _trustCellular = State(initialValue: trustCellular)
    }

    var body: some View {
        Form {
            Section {
                #if os(iOS)
                Toggle("Auto-connect on cellular data", isOn: Binding(
                    get: { !trustCellular },
                    set: { trustCellular = !$0; apply() }))
                #endif
            } footer: {
                Text("On the Wi-Fi networks below StealthWG won't connect automatically; everywhere else it will. You can still connect manually.")
            }

            Section("Trusted Wi-Fi networks") {
                ForEach(ssids, id: \.self) { ssid in
                    Text(ssid).font(.system(.footnote, design: .monospaced))
                }
                .onDelete { idx in
                    ssids.remove(atOffsets: idx); apply()
                }
                HStack {
                    TextField("Wi-Fi network name (SSID)", text: $newSSID)
                        .noAutocap()
                    Button("Add") {
                        let t = newSSID.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty, !ssids.contains(t) { ssids.append(t) }
                        newSSID = ""
                        apply()
                    }.disabled(newSSID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle("Trusted networks")
        .inlineNavTitle()
    }

    private func apply() {
        Task { await tunnelManager.setTrustedNetworks(id: profileID, ssids: ssids, trustCellular: trustCellular) }
    }
}
