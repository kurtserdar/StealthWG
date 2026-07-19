import SwiftUI
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
#endif

/// Cross-platform clipboard write.
enum Clipboard {
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

extension View {
    /// Inline nav-title on iOS; no-op on macOS (which has no title display mode).
    @ViewBuilder func inlineNavTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Disable autocapitalization on iOS; no-op on macOS.
    @ViewBuilder func noAutocap() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
