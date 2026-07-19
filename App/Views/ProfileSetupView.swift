import SwiftUI

/// Import sheet: paste a StealthWG profile or scan its QR code.
struct ProfileSetupView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @Environment(\.dismiss) private var dismiss

    @State private var profileText = ""
    @State private var showScanner = false
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Paste a StealthWG profile (a .conf with a [Stealth] section) or scan its QR code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextEditor(text: $profileText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(height: 220)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.3)))

                HStack {
                    Button { scanError = nil; showScanner = true } label: {
                        Label("Scan QR", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        Task {
                            await tunnelManager.importProfile(profileText)
                            if tunnelManager.hasProfile { dismiss() }
                        }
                    } label: { Text("Import").bold() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(profileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let scanError {
                    Text(scanError).font(.footnote).foregroundStyle(.red)
                }
                if let error = tunnelManager.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Add profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView(
                    onScan: { code in
                        showScanner = false
                        Task {
                            await tunnelManager.importProfile(code)
                            if tunnelManager.hasProfile { dismiss() }
                        }
                    },
                    onError: { message in scanError = message; showScanner = false }
                )
                .ignoresSafeArea()
            }
        }
    }
}
