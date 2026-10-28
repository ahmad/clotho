import Foundation

extension ModelState {
    /// The state after focusing `target`, by the daemon's rules (clothod's model.rs `focus_*`), so a client
    /// can show a click at once instead of after a round trip:
    /// - a pane: its tab's active pane and its workspace's active tab become it and its tab;
    /// - a tab: its workspace's active tab, and focus on its active pane;
    /// - a workspace: its active tab (else its first), and that tab's active pane.
    /// Nil when the target isn't in the model.
    ///
    /// Keep this in step with model.rs (`Model::focus_pane`, `focus_tab`, `focus_workspace`): clothod tells
    /// the mac agent when those change, and `ClothodBackendTests.testLocalFocusMatchesTheDaemon` runs the
    /// same focus sequence through both.
    public func focusing(_ target: FocusTarget) -> ModelState? {
        var next = self
        switch target {
        case .pane(let pane):
            guard let (w, t) = next.indices(where: { $0.layout.contains(pane) }) else { return nil }
            next.workspaces[w].tabs[t].activePane = pane
            next.workspaces[w].activeTab = next.workspaces[w].tabs[t].id
            next.focus = Focus(workspace: next.workspaces[w].id, tab: next.workspaces[w].tabs[t].id, pane: pane)
        case .tab(let tab):
            guard let (w, t) = next.indices(where: { $0.id == tab }) else { return nil }
            next.workspaces[w].activeTab = tab
            next.focus = Focus(workspace: next.workspaces[w].id, tab: tab, pane: next.workspaces[w].tabs[t].activePane)
        case .workspace(let id):
            guard let workspace = next.workspace(id) else { return nil }
            let tab = workspace.tabs.first { $0.id == workspace.activeTab } ?? workspace.tabs.first
            next.focus = Focus(workspace: id, tab: tab?.id, pane: tab?.activePane)
        }
        return next
    }

    private func indices(where match: (Tab) -> Bool) -> (Int, Int)? {
        for (w, workspace) in workspaces.enumerated() {
            if let t = workspace.tabs.firstIndex(where: match) { return (w, t) }
        }
        return nil
    }
}
