import SwiftUI

/// Full editor: build a profile from fields, generate/derive keys, save.
struct ProfileFormView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    let onComplete: () -> Void

    @State private var draft = ProfileDraft.defaults()
    @State private var newFallback = ""

    var body: some View {
        Form {
            Section("Interface") {
                keyRow
                DraftField("Addresses", text: $draft.address)
                DraftField("DNS", text: $draft.dns)
                DisclosureGroup("Advanced") {
                    DraftField("MTU", text: $draft.mtu)
                }
            }
            Section("Peer (server)") {
                DraftField("Public key", text: $draft.serverPublicKey)
                DraftField("Endpoint", text: $draft.endpoint, placeholder: "host:port")
                DraftField("Allowed IPs", text: $draft.allowedIPs)
                DisclosureGroup("Advanced") {
                    DraftField("Persistent keepalive", text: $draft.keepalive)
                    HStack(alignment: .bottom) {
                        DraftField("Preshared key (optional)", text: $draft.presharedKey)
                        Button("Generate") { draft.presharedKey = ProfileDraft.randomBase64Key() }
                            .buttonStyle(.bordered).font(.caption)
                    }
                    ForEach(Array(draft.fallbackEndpoints.enumerated()), id: \.offset) { _, ep in
                        Text(ep).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .bottom) {
                        DraftField("Fallback endpoint", text: $newFallback, placeholder: "host:port")
                        Button("Add") {
                            let t = newFallback.trimmingCharacters(in: .whitespaces)
                            if !t.isEmpty { draft.fallbackEndpoints.append(t); newFallback = "" }
                        }.buttonStyle(.bordered).font(.caption).disabled(newFallback.isEmpty)
                    }
                }
            }
            Section("Masking") {
                HStack(alignment: .bottom) {
                    DraftField("Mask key", text: $draft.maskKey)
                    Button("Generate") { draft.maskKey = ProfileDraft.randomBase64Key() }
                        .buttonStyle(.bordered).font(.caption)
                }
            }
        }
        .navigationTitle("Create profile")
        .inlineNavTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await tunnelManager.importProfile(draft.build())
                        if tunnelManager.hasProfile { onComplete() }
                    }
                }.disabled(!canSave)
            }
        }
    }

    private var canSave: Bool {
        [draft.privateKey, draft.serverPublicKey, draft.endpoint, draft.maskKey]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                DraftField("Private key", text: $draft.privateKey)
                Button("Generate") { draft.generateKeypair() }
                    .buttonStyle(.bordered).font(.caption)
            }
            if let pub = draft.derivedPublicKey {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Public key").font(.caption).foregroundStyle(.secondary)
                        Text(pub).font(.system(.caption2, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button { Clipboard.copy(pub) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                }
                Text("Add this public key to your server as a peer.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Labeled monospace text field used across the editor.
private struct DraftField: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    init(_ title: String, text: Binding<String>, placeholder: String = "") {
        self.title = title
        self._text = text
        self.placeholder = placeholder
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder.isEmpty ? title : placeholder, text: $text)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .noAutocap()
        }
    }
}
