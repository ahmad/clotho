import CoreGraphics
import Foundation

// Turns a tab's split tree into rectangles. Coordinates are top-left based (y grows downward), so
// "up" means smaller y on every platform.

public struct DividerFrame: Equatable, Sendable {
    public var split: SplitID
    public var axis: Axis
    /// The divider's own strip.
    public var rect: CGRect
    /// The area the split divides, which a drag's position is measured against.
    public var container: CGRect
}

public struct LayoutFrames: Equatable, Sendable {
    public var panes: [PaneID: CGRect]
    public var dividers: [DividerFrame]

    public init(panes: [PaneID: CGRect] = [:], dividers: [DividerFrame] = []) {
        self.panes = panes
        self.dividers = dividers
    }
}

extension Layout {
    public func frames(in rect: CGRect, divider: CGFloat) -> LayoutFrames {
        var result = LayoutFrames()
        place(in: rect, divider: divider, into: &result)
        return result
    }

    private func place(in rect: CGRect, divider: CGFloat, into result: inout LayoutFrames) {
        switch self {
        case .pane(let id):
            result.panes[id] = rect
        case let .split(id, axis, ratio, a, b):
            let (first, strip, second) = Self.divide(rect, axis: axis, ratio: ratio, divider: divider)
            result.dividers.append(DividerFrame(split: id, axis: axis, rect: strip, container: rect))
            a.place(in: first, divider: divider, into: &result)
            b.place(in: second, divider: divider, into: &result)
        }
    }

    static func divide(_ rect: CGRect, axis: Axis, ratio: Double, divider: CGFloat) -> (CGRect, CGRect, CGRect) {
        let clamped = min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
        switch axis {
        case .horizontal:
            let firstWidth = ((rect.width - divider) * clamped).rounded()
            let first = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
            let strip = CGRect(x: first.maxX, y: rect.minY, width: divider, height: rect.height)
            let second = CGRect(x: strip.maxX, y: rect.minY, width: max(0, rect.maxX - strip.maxX), height: rect.height)
            return (first, strip, second)
        case .vertical:
            let firstHeight = ((rect.height - divider) * clamped).rounded()
            let first = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
            let strip = CGRect(x: rect.minX, y: first.maxY, width: rect.width, height: divider)
            let second = CGRect(x: rect.minX, y: strip.maxY, width: rect.width, height: max(0, rect.maxY - strip.maxY))
            return (first, strip, second)
        }
    }

    /// The ratio that puts a split's divider at `point` (in the same coordinates as `container`).
    public static func ratio(at point: CGPoint, in container: CGRect, axis: Axis, divider: CGFloat) -> Double {
        let span = axis == .horizontal ? container.width - divider : container.height - divider
        guard span > 0 else { return 0.5 }
        let offset = axis == .horizontal ? point.x - container.minX : point.y - container.minY
        let ratio = Double((offset - divider / 2) / span)
        return min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
    }

    /// The pane next to `pane` toward `direction`: the closest one beyond that edge, preferring the most overlap.
    public static func neighbor(of pane: PaneID, toward direction: Direction, in frames: [PaneID: CGRect]) -> PaneID? {
        guard let from = frames[pane] else { return nil }
        let slack: CGFloat = 1
        var best: (id: PaneID, distance: CGFloat, overlap: CGFloat)?
        for (id, rect) in frames where id != pane {
            let distance: CGFloat
            let overlap: CGFloat
            switch direction {
            case .left:
                guard rect.maxX <= from.minX + slack else { continue }
                distance = from.minX - rect.maxX
                overlap = min(rect.maxY, from.maxY) - max(rect.minY, from.minY)
            case .right:
                guard rect.minX >= from.maxX - slack else { continue }
                distance = rect.minX - from.maxX
                overlap = min(rect.maxY, from.maxY) - max(rect.minY, from.minY)
            case .up:
                guard rect.maxY <= from.minY + slack else { continue }
                distance = from.minY - rect.maxY
                overlap = min(rect.maxX, from.maxX) - max(rect.minX, from.minX)
            case .down:
                guard rect.minY >= from.maxY - slack else { continue }
                distance = rect.minY - from.maxY
                overlap = min(rect.maxX, from.maxX) - max(rect.minX, from.minX)
            }
            guard overlap > 0 else { continue }
            if let current = best, (distance, -overlap, id) >= (current.distance, -current.overlap, current.id) { continue }
            best = (id, distance, overlap)
        }
        return best?.id
    }

    /// The innermost split on `axis` that holds `pane`, and whether the pane is on its `a` side.
    public func nearestSplit(of pane: PaneID, axis: Axis) -> (id: SplitID, ratio: Double, paneInA: Bool)? {
        guard case let .split(id, splitAxis, ratio, a, b) = self else { return nil }
        let inA = a.contains(pane)
        guard inA || b.contains(pane) else { return nil }
        if let inner = (inA ? a : b).nearestSplit(of: pane, axis: axis) { return inner }
        return splitAxis == axis ? (id, ratio, inA) : nil
    }
}
