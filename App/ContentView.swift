import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var tunnelManager: TunnelManager
    @State private var showProfileSheet = false

    var body: some View {
        Group {
            if tunnelManager.hasProfile {
                ConnectionView(showProfile: $showProfileSheet)
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $showProfileSheet) {
            if tunnelManager.hasProfile {
                ProfileDetailView().environmentObject(tunnelManager)
            } else {
                ProfileSetupView().environmentObject(tunnelManager)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
            Text("StealthWG")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("Add a profile to start masking your connection.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { showProfileSheet = true } label: {
                Label("Add profile", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(.horizontal, 40)
            Spacer()
        }
        .padding()
    }
}
