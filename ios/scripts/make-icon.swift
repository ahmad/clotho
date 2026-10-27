// Draws the 1024×1024 app icon: a prompt chevron with a spun thread (Clotho spins the thread of life).
// Run: swift scripts/make-icon.swift Clotho/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
// No alpha channel: App Store icons must be opaque.
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// Background: deep blue-black gradient (no alpha; iOS rounds the corners).
let colors = [CGColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 1), CGColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

let accent = CGColor(red: 0.55, green: 0.75, blue: 1, alpha: 1)
let thread = CGColor(red: 0.98, green: 0.72, blue: 0.38, alpha: 1)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// The prompt chevron.
ctx.setStrokeColor(accent)
ctx.setLineWidth(78)
ctx.move(to: CGPoint(x: 250, y: 700))
ctx.addLine(to: CGPoint(x: 450, y: 512))
ctx.addLine(to: CGPoint(x: 250, y: 324))
ctx.strokePath()

// The cursor becomes a thread, spun into a loose spiral.
ctx.setStrokeColor(thread)
ctx.setLineWidth(46)
ctx.move(to: CGPoint(x: 520, y: 300))
ctx.addLine(to: CGPoint(x: 640, y: 300))
ctx.addCurve(to: CGPoint(x: 760, y: 470), control1: CGPoint(x: 760, y: 300), control2: CGPoint(x: 800, y: 400))
ctx.addCurve(to: CGPoint(x: 650, y: 640), control1: CGPoint(x: 720, y: 560), control2: CGPoint(x: 720, y: 640))
ctx.addCurve(to: CGPoint(x: 600, y: 540), control1: CGPoint(x: 590, y: 640), control2: CGPoint(x: 570, y: 580))
ctx.addCurve(to: CGPoint(x: 700, y: 760), control1: CGPoint(x: 660, y: 470), control2: CGPoint(x: 790, y: 640))
ctx.strokePath()

let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
