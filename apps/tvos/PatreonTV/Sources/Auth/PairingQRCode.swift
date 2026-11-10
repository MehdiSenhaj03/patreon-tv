//
//  PairingQRCode.swift
//  PatreonTV
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Crisp QR code for a URL, drawn black on white for reliable phone scanning.
struct PairingQRCode: View {
    let url: URL

    var body: some View {
        if let image = Self.render(url.absoluteString) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.white
        }
    }

    private static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
