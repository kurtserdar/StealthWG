import SwiftUI
import UniformTypeIdentifiers

/// Chooser for the four ways to add a profile. Every path ends at
/// TunnelManager.importProfile and then calls onComplete to dismiss.
struct AddProfileView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    let onComplete: () -> Void

    #if os(iOS)
    @State private var showScanner = false
    #endif
    @State private var showFileImporter = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                NavigationLink { PasteImportView(onComplete: onComplete) } label: {
                    methodRow("Paste text", "A .conf with a [Stealth] section", "doc.on.clipboard")
                }
                #if os(iOS)
                Button { showScanner = true } label: {
                    methodRow("Scan QR code", "Import with the camera", "qrcode.viewfinder")
                }
                #endif
                Button { showFileImporter = true } label: {
                    methodRow("Import file", "Choose a .conf file", "folder")
                }
                NavigationLink { ProfileFormView(onComplete: onComplete) } label: {
                    methodRow("Create from scratch", "Fill in fields, generate keys", "square.and.pencil")
                }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add profile")
            .inlineNavTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: onComplete) } }
            #if os(iOS)
            .sheet(isPresented: $showScanner) {
                QRScannerView(
                    onScan: { code in
                        showScanner = false
                        Task { await tunnelManager.importProfile(code); if tunnelManager.hasProfile { onComplete() } }
                    },
                    onError: { m in errorText = m; showScanner = false }
                ).ignoresSafeArea()
            }
            #endif
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { importFromFile(url) }
            }
        }
    }

    private func importFromFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            errorText = "Could not read the file."
            return
        }
        Task { await tunnelManager.importProfile(text); if tunnelManager.hasProfile { onComplete() } }
    }

    private func methodRow(_ title: String, _ subtitle: String, _ system: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: system).font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.body, design: .rounded).weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

/// Paste-a-profile sub-screen.
struct PasteImportView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    let onComplete: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste a StealthWG profile (a .conf with a [Stealth] section).")
                .font(.footnote).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.3)))
            if let e = tunnelManager.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
            Spacer()
        }
        .padding()
        .navigationTitle("Paste")
        .inlineNavTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") {
                    Task { await tunnelManager.importProfile(text); if tunnelManager.hasProfile { onComplete() } }
                }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
