// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let canvas = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                       bytesPerRow: size * 4, space: space,
                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func color(_ rgb: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1)
}
func polygon(_ coords: [(CGFloat, CGFloat)], _ fill: UInt32) {
    canvas.beginPath()
    canvas.move(to: CGPoint(x: coords[0].0, y: coords[0].1))
    for point in coords.dropFirst() { canvas.addLine(to: CGPoint(x: point.0, y: point.1)) }
    canvas.closePath()
    canvas.setFillColor(color(fill))
    canvas.fillPath()
}
canvas.setFillColor(color(0x102623))
canvas.fill(CGRect(x: 0, y: 0, width: size, height: size))

// A single peak with an open notch. The silhouette reads at Home Screen size.
polygon([(230, 336), (512, 744), (794, 336), (640, 336),
         (512, 520), (384, 336)], 0xB8F5A3)

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let png = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(png, canvas.makeImage()!, nil)
precondition(CGImageDestinationFinalize(png))
