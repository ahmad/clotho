import Foundation

/// What a pane's program says about how far it is (protocol.md, "Model": the pane's `progress`, feature
/// `pane.progress`, clothod 0.1.33): `{"state", "percent"}` from OSC 9;4 or OSC 7501. It is the pane's,
/// not an agent's, and only for drawing: a bar on the pane's Tab, and on the agent's row when the pane
/// has an agent. It never raises attention.
public struct PaneProgress: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable, CaseIterable {
        case running, error, indeterminate, paused
    }

    public var state: State
    /// 0 to 100; nil when the program gave none (always for `indeterminate`).
    public var percent: Int?

    /// `percent` is brought into 0...100, and dropped for `indeterminate`.
    public init(state: State, percent: Int? = nil) {
        self.state = state
        self.percent = state == .indeterminate ? nil : percent.map { min(max($0, 0), 100) }
    }

    enum CodingKeys: String, CodingKey { case state, percent }

    /// An unknown (or unreadable) state reads as running, and a percent that isn't a whole number as
    /// none. Only something that isn't an object fails, and `Pane` reads that as no progress.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try? c.decodeIfPresent(String.self, forKey: .state)
        let percent = try? c.decodeIfPresent(Int.self, forKey: .percent)
        self.init(state: raw.flatMap(State.init(rawValue:)) ?? .running, percent: percent)
    }

    /// The percent as 0...1, for a bar; nil when there is none (draw it indeterminate).
    public var fraction: Double? { percent.map { Double($0) / 100 } }

    /// For VoiceOver: "Progress 40 percent", "Progress 55 percent, error", "Progress 70 percent,
    /// paused"; without a percent "Progress, in progress" (or "Progress, error", "Progress, paused").
    public var spokenText: String {
        let mark: String?
        switch state {
        case .error: mark = "error"
        case .paused: mark = "paused"
        case .running, .indeterminate: mark = nil
        }
        guard let percent else { return "Progress, \(mark ?? "in progress")" }
        return "Progress \(percent) percent" + (mark.map { ", \($0)" } ?? "")
    }

    /// The one progress a Tab shows, from its panes' in layout order: the first error, else the first.
    /// Shared, so the Mac and iOS pick the same one.
    public static func forTab(_ inLayoutOrder: [PaneProgress]) -> PaneProgress? {
        inLayoutOrder.first { $0.state == .error } ?? inLayoutOrder.first
    }
}
