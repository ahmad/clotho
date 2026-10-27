// Draws the Clotho app icon, "Panes" (the user's choice, 2026-10-27; the source drawing is
// Resources/AppIcon/clotho-icon-macos.svg): a split window with a blue prompt and a white cursor in the
// big left pane, two grey lines top right, and an amber "agent waiting" dot bottom right, on a rounded
// tile with the macOS icon grid's inset and shadow.
//
// Usage: swift make-icon.swift OUTPUT.png [PIXELS] [--small]
// Each size is drawn from the vector at exactly PIXELS (default 1024) rather than scaled down. --small is
// the hand-tuned 16 and 32 px version: the same layout without the grey lines, with heavier strokes so
// the window, the prompt and the dot still read.
import AppKit

let args = CommandLine.arguments
let output = args[1]
let pixels = args.count > 2 ? Int(args[2]) ?? 1024 : 1024
let small = args.contains("--small")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: rep)!
let ctx = context.cgContext
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// The SVG's coordinate space: 1024 units, y down.
ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)

// The tile: the artwork's 1024 square, scaled into the macOS grid's 824 px tile, with a drop shadow.
// Small sizes skip the shadow, which only muddies a 16 px edge.
ctx.translateBy(x: 100, y: 92)
ctx.scaleBy(x: 0.8047, y: 0.8047)
let tile = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024), cornerWidth: 230, cornerHeight: 230, transform: nil)
if !small {
    ctx.saveGState()
    // y is flipped, so a downward shadow has a positive y offset here; CG offsets are in device pixels.
    let scale = CGFloat(pixels) / 1024 * 0.8047
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 32 * scale, color: color(0x000000, 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(color(0x0c0e15))
    ctx.fillPath()
    ctx.restoreGState()
}
ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x232a3d), color(0x0c0e15)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024), options: [])

// Heavier lines at 16 and 32 px, where an 18-unit stroke is a fraction of a pixel.
let frameWidth: CGFloat = small ? 44 : 18
let promptWidth: CGFloat = small ? 80 : 58

// The window, and its split: one pane on the left, two on the right.
let window = CGPath(roundedRect: CGRect(x: 168, y: 214, width: 688, height: 596), cornerWidth: 72, cornerHeight: 72, transform: nil)
ctx.addPath(window)
ctx.setFillColor(color(0x0a0d14))
ctx.fillPath()
ctx.setStrokeColor(color(small ? 0x4a5a7c : 0x33405a))
ctx.setLineWidth(frameWidth)
ctx.move(to: CGPoint(x: 566, y: 214)); ctx.addLine(to: CGPoint(x: 566, y: 810))
ctx.move(to: CGPoint(x: 566, y: 512)); ctx.addLine(to: CGPoint(x: 856, y: 512))
ctx.strokePath()
ctx.addPath(window)
ctx.strokePath()

// The prompt and the cursor.
ctx.setStrokeColor(color(0x9ccbff))
ctx.setLineWidth(promptWidth)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 262, y: 410)); ctx.addLine(to: CGPoint(x: 382, y: 512)); ctx.addLine(to: CGPoint(x: 262, y: 614))
ctx.strokePath()
ctx.setFillColor(color(0xe6e9f2))
ctx.addPath(CGPath(roundedRect: CGRect(x: 414, y: 580, width: 96, height: small ? 52 : 40), cornerWidth: 12, cornerHeight: 12, transform: nil))
ctx.fillPath()

// Output lines in the top-right pane (left out where they'd be a smudge).
if !small {
    ctx.setFillColor(color(0x3a445c))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 626, y: 300, width: 160, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 626, y: 370, width: 112, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil))
    ctx.fillPath()
}

// The agent waiting for you.
ctx.setFillColor(color(0xfcc679))
let r: CGFloat = small ? 64 : 48
ctx.fillEllipse(in: CGRect(x: 711 - r, y: 661 - r, width: 2 * r, height: 2 * r))
ctx.restoreGState()

context.flushGraphics()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
