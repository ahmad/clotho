import AppKit
import ClothoKit

// Shows one tab: lays out its panes' frames straight from the split tree's ratios, with thin draggable
// dividers between them. (Nested NSSplitViews fight programmatic ratios.)
final class SplitLayoutView: NSView {
    static let dividerWidth: CGFloat = 1
    // Dividers are 1pt lines with a wider strip to grab.
    static let grabWidth: CGFloat = 7

    var onRatioChange: ((SplitID, Double) -> Void)?

    private(set) var layoutTree: Layout?
    private(set) var maximized: PaneID?
    private var hosts: [PaneID: PaneHostView] = [:]
    private var dividers: [DividerView] = []
    // Ratios being dragged, shown before the daemon's next state confirms them.
    private var draggedRatios: [SplitID: Double] = [:]

    override var isFlipped: Bool { true }

    /// Shows `layout` with these pane views, which may be shared with other tabs' history.
    func show(_ layout: Layout?, hosts newHosts: [PaneID: PaneHostView], maximized: PaneID?) {
        layoutTree = layout
        self.maximized = maximized.flatMap { layout?.contains($0) == true ? $0 : nil }
        for (id, host) in hosts where newHosts[id] !== host { host.removeFromSuperview() }
        for (_, host) in newHosts where host.superview !== self { addSubview(host) }
        hosts = newHosts
        // Drop drag overrides the daemon has caught up with.
        if let layout { draggedRatios = draggedRatios.filter { id, ratio in layout.ratio(of: id).map { abs($0 - ratio) > 0.0001 } ?? false } }
        needsLayout = true
    }

    /// Current pane frames, in this view's (top-left) coordinates.
    var paneFrames: [PaneID: CGRect] {
        guard let layoutTree else { return [:] }
        if let maximized { return [maximized: bounds] }
        return applyingDrags(layoutTree).frames(in: bounds, divider: Self.dividerWidth).panes
    }

    override func layout() {
        super.layout()
        guard let layoutTree else {
            dividers.forEach { $0.removeFromSuperview() }
            dividers = []
            return
        }
        let frames: LayoutFrames
        if let maximized {
            frames = LayoutFrames(panes: [maximized: bounds], dividers: [])
        } else {
            frames = applyingDrags(layoutTree).frames(in: bounds, divider: Self.dividerWidth)
        }
        for (id, host) in hosts {
            if let rect = frames.panes[id] {
                host.isHidden = false
                if host.frame != rect { host.frame = rect }
            } else {
                // A maximized pane hides its siblings but keeps them subscribed and sized.
                host.isHidden = true
            }
        }
        while dividers.count < frames.dividers.count {
            let divider = DividerView()
            divider.onDrag = { [weak self] divider, point in self?.drag(divider, to: point) }
            divider.onEnd = { [weak self] divider in self?.endDrag(divider) }
            addSubview(divider)
            dividers.append(divider)
        }
        while dividers.count > frames.dividers.count { dividers.removeLast().removeFromSuperview() }
        for (view, frame) in zip(dividers, frames.dividers) {
            view.frame = frame.axis == .horizontal
                ? frame.rect.insetBy(dx: -(Self.grabWidth - Self.dividerWidth) / 2, dy: 0)
                : frame.rect.insetBy(dx: 0, dy: -(Self.grabWidth - Self.dividerWidth) / 2)
            view.divider = frame
            // Keep dividers above the panes so the grab strip wins over the terminal.
            if subviews.last !== view { addSubview(view, positioned: .above, relativeTo: nil) }
        }
    }

    private func drag(_ divider: DividerView, to point: CGPoint) {
        guard let frame = divider.divider else { return }
        let ratio = Layout.ratio(at: point, in: frame.container, axis: frame.axis, divider: Self.dividerWidth)
        draggedRatios[frame.split] = ratio
        needsLayout = true
        onRatioChange?(frame.split, ratio)
    }

    private func endDrag(_ divider: DividerView) {
        guard let frame = divider.divider, let ratio = draggedRatios[frame.split] else { return }
        onRatioChange?(frame.split, ratio)
    }

    private func applyingDrags(_ layout: Layout) -> Layout {
        guard !draggedRatios.isEmpty else { return layout }
        return layout.mapSplits { id, ratio in draggedRatios[id] ?? ratio }
    }
}

final class DividerView: NSView {
    var divider: DividerFrame?
    var onDrag: ((DividerView, CGPoint) -> Void)?
    var onEnd: ((DividerView) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        guard let divider else { return }
        // The visible line is the divider's own strip, centered in the grab area.
        let line = divider.axis == .horizontal
            ? NSRect(x: ((bounds.width - SplitLayoutView.dividerWidth) / 2).rounded(), y: 0, width: SplitLayoutView.dividerWidth, height: bounds.height)
            : NSRect(x: 0, y: ((bounds.height - SplitLayoutView.dividerWidth) / 2).rounded(), width: bounds.width, height: SplitLayoutView.dividerWidth)
        line.fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: divider?.axis == .vertical ? .resizeUpDown : .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(self, superview.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) { onEnd?(self) }
}

extension Layout {
    func ratio(of split: SplitID) -> Double? {
        guard case let .split(id, _, ratio, a, b) = self else { return nil }
        return id == split ? ratio : a.ratio(of: split) ?? b.ratio(of: split)
    }

    func mapSplits(_ transform: (SplitID, Double) -> Double) -> Layout {
        switch self {
        case .pane: return self
        case let .split(id, axis, ratio, a, b):
            return .split(id: id, axis: axis, ratio: transform(id, ratio), a: a.mapSplits(transform), b: b.mapSplits(transform))
        }
    }
}
