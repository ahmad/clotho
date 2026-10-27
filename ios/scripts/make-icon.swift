// Draws the 1024×1024 iOS app icon, "Panes" (the user's choice, 2026-10-27): a terminal window split into
// panes, a prompt chevron and cursor on the left, text lines and an amber agent dot on the right.
// The source drawing is scripts/clotho-icon-ios.svg; this draws the same shapes in its coordinates.
// Full bleed with no corner mask (iOS masks it), and no alpha channel (App Store icons must be opaque).
// Run on a Mac: swift scripts/make-icon.swift Clotho/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// SVG coordinates: origin top-left, y down.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                            CGFloat(hex & 0xff) / 255, 1])!
}

func roundedRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

// Background: top-left #232a3d to bottom-right #0c0e15.
let gradient = CGGradient(colorsSpace: space, colors: [color(0x232a3d), color(0x0c0e15)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// The window, and its pane dividers.
let frame = roundedRect(168, 214, 688, 596, 72)
ctx.addPath(frame)
ctx.setFillColor(color(0x0a0d14))
ctx.fillPath()
ctx.setStrokeColor(color(0x33405a))
ctx.setLineWidth(18)
ctx.move(to: CGPoint(x: 566, y: 214)); ctx.addLine(to: CGPoint(x: 566, y: 810))
ctx.move(to: CGPoint(x: 566, y: 512)); ctx.addLine(to: CGPoint(x: 856, y: 512))
ctx.strokePath()
ctx.addPath(frame)
ctx.strokePath()

// The prompt chevron.
ctx.setStrokeColor(color(0x9ccbff))
ctx.setLineWidth(58)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 262, y: 410)); ctx.addLine(to: CGPoint(x: 382, y: 512)); ctx.addLine(to: CGPoint(x: 262, y: 614))
ctx.strokePath()

// The cursor, the text lines, and the agent's dot.
for (rect, hex) in [(roundedRect(414, 580, 96, 40, 12), UInt32(0xe6e9f2)),
                    (roundedRect(626, 300, 160, 30, 15), 0x3a445c),
                    (roundedRect(626, 370, 112, 30, 15), 0x3a445c)] {
    ctx.addPath(rect)
    ctx.setFillColor(color(hex))
    ctx.fillPath()
}
ctx.setFillColor(color(0xfcc679))
ctx.fillEllipse(in: CGRect(x: 711 - 48, y: 661 - 48, width: 96, height: 96))

let url = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png")
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("couldn't write \(url.path)") }
print("wrote \(url.path)")
