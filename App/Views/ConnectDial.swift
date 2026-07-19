import SwiftUI
import NetworkExtension

/// The signature control: a large tap-to-toggle dial that tells the masking story
/// through color, icon, and a glow. Idle coral (exposed), amber while working,
/// teal glow when masked.
struct ConnectDial: View {
    let status: NEVPNStatus
    let action: () -> Void

    @State private var pulse = false

    private var isBusy: Bool {
        status == .connecting || status == .reasserting || status == .disconnecting
    }
    private var isOn: Bool { status == .connected }
    private var tint: Color { Theme.color(for: status) }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Ambient glow, strongest when masked.
                Circle()
                    .fill(tint.opacity(isOn ? 0.30 : 0.12))
                    .frame(width: 220, height: 220)
                    .blur(radius: 40)

                // Concentric rings for depth.
                Circle()
                    .stroke(tint.opacity(0.20), lineWidth: 1)
                    .frame(width: 240, height: 240)
                Circle()
                    .stroke(tint.opacity(0.35), lineWidth: 14)
                    .frame(width: 200, height: 200)
                    .scaleEffect(isBusy && pulse ? 1.04 : 1.0)

                Circle()
                    .fill(tint.opacity(isOn ? 0.16 : 0.06))
                    .frame(width: 168, height: 168)

                VStack(spacing: 10) {
                    Image(systemName: isOn ? "lock.shield.fill" : "shield.slash")
                        .font(.system(size: 46, weight: .semibold))
                    Text(isOn ? "Tap to disconnect" : "Tap to connect")
                        .font(.system(.footnote, design: .rounded).weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(tint)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Disconnect" : "Connect")
        .onAppear { pulse = isBusy }
        .onChange(of: isBusy) { busy in
            withAnimation(busy ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default) {
                pulse = busy
            }
        }
        .animation(.easeInOut(duration: 0.45), value: status)
    }
}
