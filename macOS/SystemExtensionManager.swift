import Foundation
import SystemExtensions

/// Requests activation of the packet-tunnel System Extension. Actual activation
/// requires a signed, notarized app the user approves in System Settings.
final class SystemExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var statusMessage = ""
    /// Whether the extension has been activated (persisted so the menu can hide the
    /// "Enable VPN extension" setup step once it's done).
    @Published var isActivated = UserDefaults.standard.bool(forKey: "extActivated")
    static let extensionIdentifier = "com.stealthwg.mac.tunnel"

    private func setActivated(_ v: Bool) {
        isActivated = v
        UserDefaults.standard.set(v, forKey: "extActivated")
    }

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        statusMessage = "Requesting activation…"
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        statusMessage = "Approve StealthWG in System Settings → Privacy & Security."
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        statusMessage = "Extension ready."
        setActivated(true)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        statusMessage = "Activation failed: \(error.localizedDescription)"
        setActivated(false)
    }
}
