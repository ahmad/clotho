import Foundation

/// Reordering workspaces and moving tabs (`workspace.move`, `tab.move`; feature "move", clothod 0.1.22).
public enum MoveRequest: Equatable, Sendable {
    /// Puts the workspace at `index` in the list.
    case workspace(WorkspaceID, index: Int)
    /// Puts the tab at `index` among `workspace`'s tabs (nil: its own workspace, a reorder). `focus` makes it
    /// the focus too.
    case tab(TabID, workspace: WorkspaceID?, index: Int, focus: Bool)
    /// Puts `pane` beside `to` (feature `pane.move`): out of its tab as `pane.close` takes it, but alive,
    /// then into a split with `to` as `pane.split {to, direction, ratio}` makes one. `ratio` is `to`'s share
    /// (nil: 0.5). `focus` moves focus to it. The daemon only: the new split's id is the daemon's.
    case pane(PaneID, beside: PaneID, direction: Direction, ratio: Double?, focus: Bool)
    /// Puts every pane of `tab`, its splits as they are, beside `to` in another tab (`tab.join`); the tab
    /// goes. ⌘↩ in ⌘P ("open beside"). The daemon only, as `.pane`.
    case tabJoin(TabID, beside: PaneID, direction: Direction, ratio: Double?, focus: Bool)

    /// Moves the daemon makes new ids for, which can't be shown before its reply.
    public var isDaemonOnly: Bool {
        switch self {
        case .pane, .tabJoin: return true
        case .workspace, .tab: return false
        }
    }
}

extension ModelState {
    /// The state after `move`, by the daemon's rules (protocol.md, "Moving tabs and workspaces"), so a drag
    /// shows at once instead of after a round trip. Nil when its workspace or tab isn't in the model, or the
    /// index is negative. A move that changes nothing returns the state unchanged.
    ///
    /// Keep this in step with clothod's model.rs (`move_workspace`, `move_tab`):
    /// `ClothodBackendTests.testLocalMovesMatchTheDaemon` runs the same moves through both.
    ///
    /// - workspace: removed from the list, then inserted at min(index, count after removal). Nothing else changes.
    /// - tab T from S into W at index I:
    ///   - removed from S at position i, inserted into W at min(I, count after removal);
    ///   - when W ≠ S and S's active tab was T: S's active tab becomes the tab before i, else the new first
    ///     (nil when S is empty, which stays);
    ///   - if the focus was on T, or `focus` is set: W's active tab is T, and the focus is T's active pane in W;
    ///   - otherwise W's active tab is unchanged, unless W had none (it was empty), when it becomes T.
    public func moving(_ move: MoveRequest) -> ModelState? {
        var next = self
        switch move {
        case .workspace(let id, let index):
            guard index >= 0, let from = next.workspaces.firstIndex(where: { $0.id == id }) else { return nil }
            let workspace = next.workspaces.remove(at: from)
            next.workspaces.insert(workspace, at: min(index, next.workspaces.count))
        case .tab(let id, let destination, let index, let focus):
            guard index >= 0,
                  let s = next.workspaces.firstIndex(where: { $0.tabs.contains { $0.id == id } }),
                  let i = next.workspaces[s].tabs.firstIndex(where: { $0.id == id }) else { return nil }
            let target = destination ?? next.workspaces[s].id
            guard let w = next.workspaces.firstIndex(where: { $0.id == target }) else { return nil }
            let followsFocus = next.focus.tab == id || focus
            let tab = next.workspaces[s].tabs.remove(at: i)
            if w != s, next.workspaces[s].activeTab == id {
                let tabs = next.workspaces[s].tabs
                next.workspaces[s].activeTab = tabs.isEmpty ? nil : tabs[max(i - 1, 0)].id
            }
            let wasEmpty = next.workspaces[w].activeTab == nil && w != s
            next.workspaces[w].tabs.insert(tab, at: min(index, next.workspaces[w].tabs.count))
            if followsFocus {
                next.workspaces[w].activeTab = id
                next.focus = Focus(workspace: next.workspaces[w].id, tab: id, pane: tab.activePane)
            } else if wasEmpty {
                next.workspaces[w].activeTab = id
            }
        case .pane, .tabJoin:
            // Only the daemon knows the new split's id (`isDaemonOnly`).
            return nil
        }
        return next
    }
}
