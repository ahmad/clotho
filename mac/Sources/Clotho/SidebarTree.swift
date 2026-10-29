import AppKit

/// The sidebar's tree: a workspace's tabs hang off it on thin guide lines (├ for a middle tab, └ for the
/// last), and a small boxed [+] / [−] in the chevron's column opens and closes it.
///
/// Everything is drawn as filled 1-pixel rectangles snapped to the backing store, so the lines stay crisp
/// at every zoom level and on any display, and every row computes the same pixel column for the vertical
/// line (the toggle's centre), so the segments of separate rows join up.
enum SidebarTree {
    /// The guide lines' and the toggle's colour: secondary text, quieter still.
    static var lineColor: NSColor { Theme.dimText.withAlphaComponent(0.6) }

    /// The centre of the toggle column, from a row's leading edge (the machine chevrons' column too).
    static var columnX: CGFloat { s(10) + DisclosureChevron.size / 2 }

    /// The toggle box around `center`, snapped to pixels, an odd number of pixels wide so its +/− has a
    /// middle pixel. Returns the box and one pixel's size in points.
    static func box(in view: NSView, center: NSPoint) -> (rect: NSRect, pixel: CGFloat) {
        let scale = view.window?.backingScaleFactor ?? 2
        var pixels = (s(9) * scale).rounded()
        if Int(pixels) % 2 == 0 { pixels -= 1 }
        let side = pixels / scale
        let rect = view.backingAlignedRect(NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
                                           options: .alignAllEdgesNearest)
        return (rect, 1 / scale)
    }

    /// The pixel column of the vertical guide in `view`: the toggle box's middle pixel.
    static func column(in view: NSView) -> (x: CGFloat, pixel: CGFloat) {
        let (box, pixel) = box(in: view, center: NSPoint(x: columnX, y: view.bounds.midY))
        let middle = ((box.width / pixel - 1) / 2).rounded(.down)
        return (box.minX + middle * pixel, pixel)
    }

    /// A 1-pixel vertical line in the guide column from `y0` to `y1`. Its ends snap to the nearest pixel
    /// edge, so a row's line meets the next row's exactly.
    static func vertical(in view: NSView, from y0: CGFloat, to y1: CGFloat) -> NSRect {
        let (x, pixel) = column(in: view)
        return view.backingAlignedRect(NSRect(x: x, y: min(y0, y1), width: pixel, height: abs(y1 - y0)),
                                       options: [.alignMinXNearest, .alignWidthNearest, .alignMinYNearest, .alignMaxYNearest])
    }

    /// A 1-pixel horizontal line at `y` from the guide column to `x1`.
    static func horizontal(in view: NSView, at y: CGFloat, to x1: CGFloat) -> NSRect {
        let (x, pixel) = column(in: view)
        return view.backingAlignedRect(NSRect(x: x, y: y - pixel / 2, width: max(0, x1 - x), height: pixel),
                                       options: [.alignMinXNearest, .alignMaxXNearest, .alignMinYNearest, .alignHeightNearest])
    }

    static func path(_ rects: [NSRect]) -> CGPath {
        let path = CGMutablePath()
        rects.filter { $0.width > 0 && $0.height > 0 }.forEach { path.addRect($0) }
        return path
    }
}

/// A workspace's [+] / [−]: a small square with a minus, plus a bar when closed. It replaces the
/// chevron in workspace rows and keeps its interface.
final class TreeToggle: NSView {
    static var size: CGFloat { DisclosureChevron.size }
    private let shape = CAShapeLayer()
    private(set) var isExpanded: Bool

    init(expanded: Bool) {
        isExpanded = expanded
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        layer?.addSublayer(shape)
        setAccessibilityRole(.disclosureTriangle)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Clicks go to the row, which toggles on its toggle column (and takes a background window's first
    /// click; this view would swallow it).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        redraw()
    }

    /// The box's rectangles: four edges, the minus, and the plus's bar while closed.
    var rects: [NSRect] {
        let (box, pixel) = SidebarTree.box(in: self, center: NSPoint(x: bounds.midX, y: bounds.midY))
        let n = (box.width / pixel).rounded()
        let middle = ((n - 1) / 2).rounded(.down) * pixel
        let inset = 2 * pixel
        var rects = [
            NSRect(x: box.minX, y: box.minY, width: box.width, height: pixel),
            NSRect(x: box.minX, y: box.maxY - pixel, width: box.width, height: pixel),
            NSRect(x: box.minX, y: box.minY + pixel, width: pixel, height: box.height - 2 * pixel),
            NSRect(x: box.maxX - pixel, y: box.minY + pixel, width: pixel, height: box.height - 2 * pixel),
            // The minus, two pixels in from the sides.
            NSRect(x: box.minX + pixel + inset, y: box.minY + middle, width: box.width - 2 * (pixel + inset), height: pixel),
        ]
        if !isExpanded {
            rects.append(NSRect(x: box.minX + middle, y: box.minY + pixel + inset, width: pixel, height: box.height - 2 * (pixel + inset)))
        }
        return rects
    }

    func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.contentsScale = window?.backingScaleFactor ?? 2
        shape.path = SidebarTree.path(rects)
        var color = SidebarTree.lineColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = SidebarTree.lineColor.cgColor }
        shape.fillColor = color
        CATransaction.commit()
    }

    /// Flips the box, then calls `done` once the change has drawn.
    func setExpanded(_ expanded: Bool, animated: Bool, then done: (() -> Void)? = nil) {
        isExpanded = expanded
        redraw()
        guard let done else { return }
        if animated { DispatchQueue.main.async(execute: done) } else { done() }
    }
}

/// A borderless symbol button that rests dim and brightens under the pointer, like the machine headers'
/// quiet + (New Workspace).
final class QuietButton: NSButton {
    private let handler: () -> Void
    private var hovering = false { didSet { updateTint() } }

    init(symbol: String, label: String, pointSize: CGFloat, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
        isBordered = false
        target = self
        action = #selector(run)
        setAccessibilityLabel(label)
        updateTint()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// For tests and screenshots: as if the pointer came over it or left.
    func setHovering(_ on: Bool) { hovering = on }

    var isBright: Bool { hovering }

    private func updateTint() {
        contentTintColor = hovering ? Theme.foreground : Theme.dimText.withAlphaComponent(0.7)
    }
}
