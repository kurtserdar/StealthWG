import Foundation
import SystemExtensions

/// Requests activation of the packet-tunnel System Extension. Actual activation
/// requires a signed, notarized app the user approves in System Settings.
final class SystemExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var statusMessage = ""
    static let extensionIdentifier = "com.stealthwg.mac.tunnel"

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
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        statusMessage = "Activation failed: \(error.localizedDescription)"
    }
}
