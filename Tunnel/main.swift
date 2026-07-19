// Entry point for the macOS packet-tunnel System Extension. iOS packages the
// tunnel as an app extension (NSExtensionMain provides the entry point), so this
// file is empty there; macOS system extensions need an explicit main that starts
// the NetworkExtension provider machinery.
#if os(macOS)
import Foundation
import NetworkExtension

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

dispatchMain()
#endif
