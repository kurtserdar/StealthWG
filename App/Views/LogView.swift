import SwiftUI

/// The ephemeral connection log. Polls the connected tunnel while visible and
/// renders the in-memory lines. Nothing here is persisted.
struct LogView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        Group {
            if !tunnelManager.loggingEnabled {
                emptyState("Logging is off", "Enable logging below to capture connection events. Nothing is written to disk.")
            } else if tunnelManager.connectedID == nil {
                emptyState("Not connected", "Connect a tunnel to see live log events.")
            } else if tunnelManager.logLines.isEmpty {
                emptyState("No log entries yet", "Events appear here as the tunnel connects.")
            } else {
                logList
            }
        }
        .safeAreaInset(edge: .bottom) { loggingToggle }
        .navigationTitle("Log")
        .inlineNavTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { Clipboard.copy(exportText) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .disabled(tunnelManager.logLines.isEmpty)
                    Button(role: .destructive) { tunnelManager.clearLogs() } label: { Label("Clear", systemImage: "trash") }
                        .disabled(tunnelManager.logLines.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { tunnelManager.startLogPolling() }
        .onDisappear { tunnelManager.stopLogPolling() }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(tunnelManager.logLines) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(Self.timeFormatter.string(from: entry.date))
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                        }
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .id(entry.seq)
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: tunnelManager.logLines.count) { _ in
                if let last = tunnelManager.logLines.last { withAnimation { proxy.scrollTo(last.seq, anchor: .bottom) } }
            }
        }
    }

    private var loggingToggle: some View {
        Toggle("Capture logs (this session only)", isOn: Binding(
            get: { tunnelManager.loggingEnabled },
            set: { tunnelManager.loggingEnabled = $0 }))
            .font(.footnote)
            .padding()
            .background(.thinMaterial)
    }

    private func emptyState(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "text.alignleft").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var exportText: String {
        tunnelManager.logLines
            .map { "\(Self.timeFormatter.string(from: $0.date))  \($0.message)" }
            .joined(separator: "\n")
    }
}
