import AppKit

/// The sidebar's tree: a workspace's tabs hang off it on thin guide lines (├ for a middle tab, └ for the
/// last), and a small boxed [+] / [−] in the chevron's column opens and closes it.
///
/// Everything is drawn as filled 1-pixel rectangles snapped to the backing store, so the lines stay crisp
/// at every zoom level and on any display, and every row computes the same pixel column for the vertical
/// line (the toggle's centre), so the segments of separate rows join up.
enum SidebarTree {
    /// The guide lines' colour: secondary text, quieter still.
    static var lineColor: NSColor { Theme.dimText.withAlphaComponent(0.6) }
    /// The toggle's colour: secondary text at rest, the title colour under the pointer. It reads clearly
    /// without competing with the workspace name.
    static func toggleColor(hovering: Bool) -> NSColor { hovering ? Theme.foreground : Theme.dimText }

    /// The toggle's stroke, in pixels: a point's worth (2 px on a Retina display at 100%), never less
    /// than one.
    static func strokePixels(scale: CGFloat) -> CGFloat { max(1, (s(1) * scale).rounded()) }

    /// The centre of the toggle column, from a row's leading edge (the machine chevrons' column too).
    static var columnX: CGFloat { s(10) + DisclosureChevron.size / 2 }

    /// The toggle box around `center` (about 11.5 pt), snapped to pixels. Its width leaves the same
    /// number of pixels either side of the +/−'s stroke, so the sign sits exactly in the middle. Returns
    /// the box and one pixel's size in points.
    static func box(in view: NSView, center: NSPoint) -> (rect: NSRect, pixel: CGFloat) {
        let scale = view.window?.backingScaleFactor ?? 2
        var pixels = (s(11.5) * scale).rounded()
        if Int(pixels - strokePixels(scale: scale)) % 2 != 0 { pixels -= 1 }
        let side = pixels / scale
        let rect = view.backingAlignedRect(NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
                                           options: .alignAllEdgesNearest)
        return (rect, 1 / scale)
    }

    /// The pixel column of the vertical guide in `view`: the toggle box's middle pixel (inside the sign's
    /// stroke).
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
    /// Under the pointer: it brightens.
    private(set) var hovering = false { didSet { if hovering != oldValue { redraw() } } }

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// For tests and screenshots: as if the pointer came over it or left.
    func setHovering(_ on: Bool) { hovering = on }

    /// The stroke in points (whole pixels).
    var stroke: CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return SidebarTree.strokePixels(scale: scale) / scale
    }

    /// The box's rectangles: four edges, the minus, and the plus's bar while closed, each `stroke` thick.
    var rects: [NSRect] {
        let (box, pixel) = SidebarTree.box(in: self, center: NSPoint(x: bounds.midX, y: bounds.midY))
        let t = stroke
        // The sign: centred (the box leaves an even number of pixels around it), a gap in from the edges.
        let gap = max(pixel, (s(2) / pixel).rounded() * pixel)
        let middle = ((box.width - t) / 2 / pixel).rounded() * pixel
        let length = box.width - 2 * (t + gap)
        var rects = [
            NSRect(x: box.minX, y: box.minY, width: box.width, height: t),
            NSRect(x: box.minX, y: box.maxY - t, width: box.width, height: t),
            NSRect(x: box.minX, y: box.minY + t, width: t, height: box.height - 2 * t),
            NSRect(x: box.maxX - t, y: box.minY + t, width: t, height: box.height - 2 * t),
            NSRect(x: box.minX + t + gap, y: box.minY + middle, width: length, height: t),
        ]
        if !isExpanded {
            rects.append(NSRect(x: box.minX + middle, y: box.minY + t + gap, width: t, height: length))
        }
        return rects
    }

    func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.contentsScale = window?.backingScaleFactor ?? 2
        shape.path = SidebarTree.path(rects)
        var color = SidebarTree.toggleColor(hovering: hovering).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = SidebarTree.toggleColor(hovering: self.hovering).cgColor }
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
