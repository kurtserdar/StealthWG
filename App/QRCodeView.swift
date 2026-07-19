import SwiftUI
import CoreImage.CIFilterBuiltins

/// Renders a string as a QR code. Uses CoreImage — no camera, cross-platform.
/// Used to export the current StealthWG profile to another device.
struct QRCodeView: View {
    let text: String

    var body: some View {
        VStack(spacing: 16) {
            if let image = Self.qrImage(from: text) {
                #if os(iOS)
                Image(uiImage: image)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 280)
                    .accessibilityLabel("Profile QR code")
                #elseif os(macOS)
                Image(nsImage: image)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 280)
                    .accessibilityLabel("Profile QR code")
                #endif
            } else {
                Text("Could not render QR code.")
                    .foregroundStyle(.red)
            }
            Text("Scan this on another device to import the profile.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    /// Generates a scaled, crisp QR image for `text`, or nil on failure.
    static func qrImage(from text: String) -> PlatformImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cg)
        #elseif os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }
}
