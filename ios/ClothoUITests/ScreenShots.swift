import UIKit
import XCTest

extension XCTestCase {
    /// Attaches the whole screen, upright. `app.screenshot()` comes out portrait and cropped when the iPad is in
    /// landscape, and `XCUIScreen.main.screenshot()` whole but still in the panel's portrait: this one turns it
    /// to the way the device is held.
    func attachScreen(_ name: String) {
        let shot = XCTAttachment(image: Self.upright(XCUIScreen.main.screenshot().image, held: XCUIDevice.shared.orientation))
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// `image` (the panel as it is in portrait) turned for a device held in landscape; unchanged otherwise.
    static func upright(_ image: UIImage, held orientation: UIDeviceOrientation) -> UIImage {
        guard orientation.isLandscape, let pixels = image.cgImage else { return image }
        let turned = UIImage(cgImage: pixels, scale: image.scale, orientation: orientation == .landscapeLeft ? .left : .right)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        // Drawn, so the turn is in the pixels: a PNG carries no orientation.
        return UIGraphicsImageRenderer(size: turned.size, format: format).image { _ in
            turned.draw(in: CGRect(origin: .zero, size: turned.size))
        }
    }
}
