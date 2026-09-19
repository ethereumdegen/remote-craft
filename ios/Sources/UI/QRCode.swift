import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// A QR code of a command, drawn black on white.
///
/// **Black on white even though the app is dark**, and this is not a style slip. A
/// scanner looks for a high-contrast finder pattern with a quiet zone around it; a code
/// drawn in accent-on-charcoal, or with the app's background showing through the margin,
/// reads as a smear at anything but perfect focus. A code that does not scan is worse
/// than no code, because the user blames their camera.
///
/// `CIQRCodeGenerator` renders one module per pixel, so the tiny CIImage is scaled up by
/// a whole number of pixels before it becomes a `UIImage` — `CGAffineTransform` scaling
/// on a `CIImage` keeps the module edges square, where letting SwiftUI stretch a 25×25
/// bitmap into 220 points would interpolate them into grey.
struct QRCode: View {
    let text: String
    var side: CGFloat = 200

    var body: some View {
        Group {
            if let image = Self.render(text, side: side) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: side, height: side)
            } else {
                // Only reachable for input CoreImage cannot encode at all. Saying so is
                // better than an empty rectangle the user reads as a broken layout.
                Text("too long to encode as a QR")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.faint)
                    .frame(width: side, height: side)
            }
        }
        // The quiet zone. Four modules of white is what the spec asks for; this is the
        // padding that supplies it regardless of how many modules the payload needed.
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
    }

    private static let context = CIContext()

    static func render(_ text: String, side: CGFloat) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // Medium: recovers from about 15% damage, which is what a phone camera pointed
        // at a screen needs, without inflating a 150-character command into a code whose
        // modules are too fine to resolve.
        filter.correctionLevel = "M"
        guard let coded = filter.outputImage else { return nil }

        let pixels = side * UIScreen.main.scale
        let scale = max(1, (pixels / coded.extent.width).rounded(.down))
        let scaled = coded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
