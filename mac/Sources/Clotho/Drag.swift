import AppKit
import ClothoKit

// Drag to reorder: workspaces within their machine in the sidebar, tabs within the tab bar, and a tab onto
// another workspace of the same machine (its panes and shells move with it). A clear line shows where a
// drop lands; a workspace a tab would move to is highlighted. Moves are optimistic, through
// ModelStore.move (`ModelState.moving`), so they show on the frame of the drop. Only against daemons with
// the `move` feature; elsewhere nothing drags. The drag side is ChromeItem's (Chrome.swift).

/// The drag in flight, if any. One at a time, within this app.
enum ChromeDrag {
    static let type = NSPasteboard.PasteboardType("app.clotho.drag")
    /// Posted when a drag ends, dropped or not: views that held their updates apply them.
    static let ended = Notification.Name("ClothoChromeDragEnded")

    struct Payload: Equatable {
        enum Kind: String { case tab, workspace }
        var kind: Kind
        var machine: MachineKey
        /// The tab's or workspace's id.
        var id: UInt64
        /// The workspace it's in (for a workspace, itself).
        var workspace: WorkspaceID

        var encoded: String { [kind.rawValue, machine, String(id), String(workspace)].joined(separator: "\t") }

        init(kind: Kind, machine: MachineKey, id: UInt64, workspace: WorkspaceID) {
            (self.kind, self.machine, self.id, self.workspace) = (kind, machine, id, workspace)
        }

        init?(encoded: String) {
            let parts = encoded.components(separatedBy: "\t")
            guard parts.count == 4, let kind = Kind(rawValue: parts[0]), let id = UInt64(parts[2]), let workspace = UInt64(parts[3]) else { return nil }
            self.init(kind: kind, machine: parts[1], id: id, workspace: workspace)
        }
    }

    @MainActor private(set) static var current: Payload?
    @MainActor static var isActive: Bool { current != nil }

    @MainActor static func begin(_ payload: Payload) { current = payload }

    @MainActor static func end() {
        guard current != nil else { return }
        current = nil
        NotificationCenter.default.post(name: ended, object: nil)
    }

    /// What's being dragged over `sender`: this app's drag, else one decoded from the pasteboard.
    @MainActor static func payload(_ sender: NSDraggingInfo) -> Payload? {
        current ?? sender.draggingPasteboard.string(forType: type).flatMap(Payload.init(encoded:))
    }

    /// Where a drop lands among the other items: how many of their middles come before `position`, along
    /// the axis they're laid out on (left to right, or top to bottom).
    static func insertionIndex(at position: CGFloat, middles: [CGFloat]) -> Int {
        middles.filter { $0 < position }.count
    }
}

/// The line where a drop would land.
final class DropIndicator: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 1
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Theme.accent.cgColor }
    }

    func show(_ rect: NSRect) {
        frame = rect.integral
        isHidden = false
        superview?.addSubview(self, positioned: .above, relativeTo: nil)
    }

    func hide() { isHidden = true }

    // The line never takes clicks or drops from what's under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A workspace a dragged tab would move to.
final class DropTargetHighlight: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = s(6)
        layer?.borderWidth = 1.5
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = Theme.accent.cgColor
            layer?.backgroundColor = Theme.accent.withAlphaComponent(0.14).cgColor
        }
    }

    /// The workspace it's on now (tests).
    private(set) var target: WorkspaceID?

    func show(_ rect: NSRect, workspace: WorkspaceID) {
        frame = rect
        target = workspace
        isHidden = false
        superview?.addSubview(self, positioned: .above, relativeTo: nil)
    }

    func hide() {
        isHidden = true
        target = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: Tab bar: reorder

extension TabBarView {
    /// Where a tab dragged to `point` (window coordinates) would land: its id and its index among the others.
    /// Nil when it isn't this bar's, or it would land where it is.
    func tabDrop(_ payload: ChromeDrag.Payload?, at point: NSPoint) -> (tab: TabID, index: Int, lineX: CGFloat)? {
        guard let payload, payload.kind == .tab, payload.machine == machine, payload.workspace == workspace,
              let from = order.firstIndex(of: payload.id) else { return nil }
        let others = order.filter { $0 != payload.id }.compactMap { id in frameOfTab(id).map { (id, $0) } }
        let x = convert(point, from: nil).x
        let index = ChromeDrag.insertionIndex(at: x, middles: others.map(\.1.midX))
        guard index != from else { return nil }
        let gap = s(4) / 2
        let lineX = index == 0 ? (others.first?.1.minX ?? 0) - gap : others[index - 1].1.maxX + gap
        return (payload.id, index, lineX)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { tabDragUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { tabDragUpdated(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropLine.hide() }

    private func tabDragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let drop = tabDrop(ChromeDrag.payload(sender), at: sender.draggingLocation),
              let frame = frameOfTab(drop.tab) else {
            dropLine.hide()
            return []
        }
        dropLine.show(NSRect(x: drop.lineX - 1, y: frame.minY + 2, width: 2, height: frame.height - 4))
        return .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropLine.hide()
        guard let drop = tabDrop(ChromeDrag.payload(sender), at: sender.draggingLocation) else { return false }
        onMoveTab?(drop.tab, drop.index)
        return true
    }
}

// MARK: Sidebar: reorder workspaces, move a tab to another workspace

extension SidebarView {
    enum Drop: Equatable {
        /// A workspace to `index` among its machine's others; the line goes across at `lineY`.
        case reorder(MachineKey, WorkspaceID, index: Int, lineY: CGFloat, minX: CGFloat, maxX: CGFloat)
        /// A tab onto a workspace, whose row is `frame`.
        case moveTab(MachineKey, TabID, to: WorkspaceID, frame: NSRect)
    }

    /// What dropping `payload` at `point` (window coordinates) would do; nil for nothing (another
    /// machine, its own place, its own workspace, or outside its machine's rows).
    func drop(_ payload: ChromeDrag.Payload?, at point: NSPoint) -> Drop? {
        guard let payload else { return nil }
        let rows = workspaceRows(of: payload.machine).map { (id: $0.id, frame: $0.row.convert($0.row.bounds, to: self)) }
        guard !rows.isEmpty else { return nil }
        let at = convert(point, from: nil)
        // Down the column, whichever way the view's y runs.
        let down: (CGFloat) -> CGFloat = { [isFlipped] in isFlipped ? $0 : -$0 }
        switch payload.kind {
        case .tab:
            guard let row = rows.first(where: { $0.frame.contains(at) }), row.id != payload.workspace else { return nil }
            return .moveTab(payload.machine, payload.id, to: row.id, frame: row.frame)
        case .workspace:
            guard let from = rows.firstIndex(where: { $0.id == payload.id }) else { return nil }
            // Only within the machine's own rows, give or take half a row.
            let tops = rows.map { down(isFlipped ? $0.frame.minY : $0.frame.maxY) }
            let bottoms = rows.map { down(isFlipped ? $0.frame.maxY : $0.frame.minY) }
            let half = (bottoms[0] - tops[0]) / 2
            guard down(at.y) >= tops.min()! - half, down(at.y) <= bottoms.max()! + half else { return nil }
            let others = rows.enumerated().filter { $0.offset != from }.map(\.element)
            let index = ChromeDrag.insertionIndex(at: down(at.y), middles: others.map { down($0.frame.midY) })
            guard index != from else { return nil }
            // In the gap above the row it goes before, or below the last.
            let lineY: CGFloat
            if index < others.count {
                let next = others[index].frame
                lineY = (isFlipped ? next.minY : next.maxY) + (isFlipped ? -1 : 1) * Self.rowSpacing / 2
            } else {
                let last = others[others.count - 1].frame
                lineY = (isFlipped ? last.maxY : last.minY) + (isFlipped ? 1 : -1) * Self.rowSpacing / 2
            }
            let span = rows[0].frame
            return .reorder(payload.machine, payload.id, index: index, lineY: lineY, minX: span.minX + s(4), maxX: span.maxX - s(4))
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { sidebarDragUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { sidebarDragUpdated(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropLine.hide()
        dropTarget.hide()
    }

    private func sidebarDragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        switch drop(ChromeDrag.payload(sender), at: sender.draggingLocation) {
        case .reorder(_, _, _, let y, let minX, let maxX):
            dropTarget.hide()
            dropLine.show(NSRect(x: minX, y: y - 1, width: maxX - minX, height: 2))
            return .move
        case .moveTab(_, _, let workspace, let frame):
            dropLine.hide()
            dropTarget.show(frame, workspace: workspace)
            return .move
        case nil:
            dropLine.hide()
            dropTarget.hide()
            return []
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let drop = drop(ChromeDrag.payload(sender), at: sender.draggingLocation)
        dropLine.hide()
        dropTarget.hide()
        switch drop {
        case .reorder(let machine, let id, let index, _, _, _): onMoveWorkspace?(machine, id, index)
        case .moveTab(let machine, let tab, let workspace, _): onMoveTab?(machine, tab, workspace)
        case nil: return false
        }
        return true
    }
}
