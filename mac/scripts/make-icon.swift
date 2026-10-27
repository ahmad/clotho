// Draws the Clotho app icon and writes a 1024px PNG to the path given as the first argument.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// macOS icon grid: 824px tile centered with a soft shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
color(0x0b0e14).setFill()
tilePath.fill()
ctx.restoreGState()

tilePath.addClip()
NSGradient(colors: [color(0x1a1f2e), color(0x07090d)])!.draw(in: tile, angle: -90)

// Window body.
let inset: CGFloat = 92
let win = tile.insetBy(dx: inset, dy: inset)
let winPath = NSBezierPath(roundedRect: win, xRadius: 46, yRadius: 46)
color(0x000000, 0.55).setFill()
winPath.fill()
color(0x2a3142).setStroke()
winPath.lineWidth = 6
winPath.stroke()

// Sidebar.
let sidebarW: CGFloat = 170
let sidebar = NSRect(x: win.minX, y: win.minY, width: sidebarW, height: win.height)
NSGraphicsContext.saveGraphicsState()
winPath.addClip()
color(0x121620).setFill()
sidebar.fill()
NSGraphicsContext.restoreGraphicsState()
color(0x2a3142).setFill()
NSRect(x: sidebar.maxX, y: win.minY + 3, width: 6, height: win.height - 6).fill()

// Sidebar rows: one active, the rest dim.
for i in 0..<4 {
    let y = win.maxY - 70 - CGFloat(i) * 62
    let row = NSRect(x: sidebar.minX + 26, y: y, width: sidebarW - 52, height: 26)
    (i == 0 ? color(0x7aa2f7) : color(0x3b4357)).setFill()
    NSBezierPath(roundedRect: row, xRadius: 13, yRadius: 13).fill()
}

// Tabs across the top of the main area.
let mainX = sidebar.maxX + 6
let tabY = win.maxY - 66
color(0x7aa2f7).setFill()
NSBezierPath(roundedRect: NSRect(x: mainX + 28, y: tabY, width: 104, height: 34), xRadius: 9, yRadius: 9).fill()
color(0x2a3142).setFill()
NSBezierPath(roundedRect: NSRect(x: mainX + 146, y: tabY, width: 104, height: 34), xRadius: 9, yRadius: 9).fill()

// Prompt chevron and cursor.
let chevron = NSBezierPath()
let cx = mainX + 70, cy = win.midY - 10
chevron.move(to: NSPoint(x: cx, y: cy + 70))
chevron.line(to: NSPoint(x: cx + 80, y: cy))
chevron.line(to: NSPoint(x: cx, y: cy - 70))
chevron.lineWidth = 34
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
color(0x7aa2f7).setStroke()
chevron.stroke()
color(0xe6e9f0).setFill()
NSBezierPath(roundedRect: NSRect(x: cx + 130, y: cy - 78, width: 120, height: 34), xRadius: 10, yRadius: 10).fill()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
