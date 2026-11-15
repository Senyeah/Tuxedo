// make_icon.swift DIR: draws the app icon's two windows as transparent 1024x1024 layers, for
// ios/Tuxedo/AppIcon.icon/Assets (Icon Composer's format: iOS adds the glass). l0 is the front one.
// Geometry is in the pixels of docs/tuxedo-icon-source.png (1500), the master; the layers scale it to 1024.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let dir = CommandLine.arguments[1]
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let scale: CGFloat = 1024.0 / 1500.0
func col(_ h: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a) }

let w: CGFloat = 931, h: CGFloat = 667, r: CGFloat = 112

func window(_ file: String, _ x: CGFloat, _ y: CGFloat, _ fill: CGColor, _ chevron: CGColor) {
    let c = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: 1024); c.scaleBy(x: scale, y: -scale)
    c.setFillColor(fill)
    c.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
    c.fillPath()
    // Two chevrons at the top right: one up, one down.
    c.setStrokeColor(chevron); c.setLineWidth(12.5); c.setLineCap(.round); c.setLineJoin(.round)
    let top = y + 63, arm: CGFloat = 36, up = x + w - 229, down = x + w - 118
    c.move(to: CGPoint(x: up - arm, y: top + arm)); c.addLine(to: CGPoint(x: up, y: top)); c.addLine(to: CGPoint(x: up + arm, y: top + arm))
    c.move(to: CGPoint(x: down - arm, y: top + 3)); c.addLine(to: CGPoint(x: down, y: top + 3 + arm)); c.addLine(to: CGPoint(x: down + arm, y: top + 3))
    c.strokePath()
    let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir + "/" + file) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(out, c.makeImage()!, nil)
    CGImageDestinationFinalize(out)
}

window("l0.png", 434, 554, col(0xFFFFFF), col(0x5F5F5F))
window("l1.png", 135, 281, col(0xDADADA, 0.62), col(0x5F5F5F, 0.22))
