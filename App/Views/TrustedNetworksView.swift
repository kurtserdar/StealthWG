import SwiftUI

/// Edits the Wi-Fi SSIDs where on-demand should not auto-connect, plus the
/// cellular preference. Applies each change immediately via the tunnel manager.
struct TrustedNetworksView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    let profileID: String

    @State private var ssids: [String]
    @State private var trustCellular: Bool
    @State private var newSSID = ""
    @State private var wifiNote = ""
    #if os(iOS)
    @StateObject private var currentWiFi = CurrentWiFi()
    #endif

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
                #if os(iOS)
                Button {
                    addCurrentWiFi()
                } label: {
                    Label("Use current Wi-Fi", systemImage: "wifi")
                }
                if !wifiNote.isEmpty {
                    Text(wifiNote).font(.caption2).foregroundStyle(.secondary)
                }
                #endif
                HStack {
                    TextField("Wi-Fi network name (SSID)", text: $newSSID)
                        .noAutocap()
                    Button("Add") {
                        add(newSSID)
                        newSSID = ""
                    }.disabled(newSSID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle("Trusted networks")
        .inlineNavTitle()
    }

    private func add(_ name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !ssids.contains(t) else { return }
        ssids.append(t)
        apply()
    }

    private func apply() {
        Task { await tunnelManager.setTrustedNetworks(id: profileID, ssids: ssids, trustCellular: trustCellular) }
    }

    #if os(iOS)
    private func addCurrentWiFi() {
        wifiNote = ""
        currentWiFi.fetch { result in
            switch result {
            case .success(let ssid):
                add(ssid)
            case .denied:
                wifiNote = "Allow location access to read the current Wi-Fi name, or type it below."
            case .unavailable:
                wifiNote = "Couldn't read the current Wi-Fi. Type the name below."
            }
        }
    }
    #endif
}
