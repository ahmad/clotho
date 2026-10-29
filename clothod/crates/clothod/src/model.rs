//! Workspace > Tab > split tree > Pane. Pure data plus the edits the protocol allows; the daemon
//! persists it in the holder so a restarted logic process gets it back.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Model {
    pub next_id: u64,
    pub workspaces: Vec<Workspace>,
    pub focus: Focus,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Focus {
    pub workspace: Option<u64>,
    pub tab: Option<u64>,
    pub pane: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Workspace {
    pub id: u64,
    pub name: String,
    /// Last focused tab; `focus` with just a workspace goes back to it.
    #[serde(default)]
    pub active_tab: Option<u64>,
    pub tabs: Vec<Tab>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Tab {
    pub id: u64,
    pub title: Option<String>,
    pub active_pane: u64,
    pub layout: Node,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Axis {
    /// a | b
    Horizontal,
    /// a over b
    Vertical,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Node {
    Pane { pane: u64 },
    Split { id: u64, axis: Axis, ratio: f64, a: Box<Node>, b: Box<Node> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Right,
    Down,
    Left,
    Up,
}

impl Direction {
    pub fn parse(s: &str) -> Option<Direction> {
        Some(match s {
            "right" => Direction::Right,
            "down" => Direction::Down,
            "left" => Direction::Left,
            "up" => Direction::Up,
            _ => return None,
        })
    }
}

pub fn clamp_ratio(r: f64) -> f64 {
    if r.is_nan() {
        0.5
    } else {
        r.clamp(0.05, 0.95)
    }
}

impl Node {
    fn panes(&self, out: &mut Vec<u64>) {
        match self {
            Node::Pane { pane } => out.push(*pane),
            Node::Split { a, b, .. } => {
                a.panes(out);
                b.panes(out);
            }
        }
    }

    fn contains(&self, pane: u64) -> bool {
        match self {
            Node::Pane { pane: p } => *p == pane,
            Node::Split { a, b, .. } => a.contains(pane) || b.contains(pane),
        }
    }

    /// Replace the leaf `pane` with a split of it and `new`. Returns false if `pane` isn't here.
    fn split(&mut self, pane: u64, new: u64, dir: Direction, ratio: f64, split_id: u64) -> bool {
        match self {
            Node::Pane { pane: p } if *p == pane => {
                let old = Box::new(Node::Pane { pane });
                let fresh = Box::new(Node::Pane { pane: new });
                let (axis, a, b, ratio) = match dir {
                    Direction::Right => (Axis::Horizontal, old, fresh, ratio),
                    Direction::Down => (Axis::Vertical, old, fresh, ratio),
                    // The new pane comes first, and gets the requested share.
                    Direction::Left => (Axis::Horizontal, fresh, old, 1.0 - ratio),
                    Direction::Up => (Axis::Vertical, fresh, old, 1.0 - ratio),
                };
                *self = Node::Split { id: split_id, axis, ratio: clamp_ratio(ratio), a, b };
                true
            }
            Node::Pane { .. } => false,
            Node::Split { a, b, .. } => {
                a.split(pane, new, dir, ratio, split_id) || b.split(pane, new, dir, ratio, split_id)
            }
        }
    }

    /// Remove leaf `pane`, collapsing its parent split. Returns `None` if this whole node goes.
    /// `sibling` gets the pane that took the removed one's place.
    fn remove(self, pane: u64, sibling: &mut Option<u64>) -> Option<Node> {
        match self {
            Node::Pane { pane: p } if p == pane => None,
            leaf @ Node::Pane { .. } => Some(leaf),
            Node::Split { id, axis, ratio, a, b } => match (a.remove(pane, sibling), b.remove(pane, sibling)) {
                (Some(a), Some(b)) => Some(Node::Split { id, axis, ratio, a: Box::new(a), b: Box::new(b) }),
                (Some(only), None) | (None, Some(only)) => {
                    if sibling.is_none() {
                        *sibling = Some(only.first_pane());
                    }
                    Some(only)
                }
                (None, None) => None,
            },
        }
    }

    fn set_ratio(&mut self, split: u64, r: f64) -> bool {
        match self {
            Node::Pane { .. } => false,
            Node::Split { id, ratio, a, b, .. } => {
                if *id == split {
                    *ratio = clamp_ratio(r);
                    true
                } else {
                    a.set_ratio(split, r) || b.set_ratio(split, r)
                }
            }
        }
    }

    fn first_pane(&self) -> u64 {
        match self {
            Node::Pane { pane } => *pane,
            Node::Split { a, .. } => a.first_pane(),
        }
    }
}

impl Tab {
    pub fn panes(&self) -> Vec<u64> {
        let mut out = Vec::new();
        self.layout.panes(&mut out);
        out
    }
}

impl Model {
    fn alloc(&mut self) -> u64 {
        self.next_id += 1;
        self.next_id
    }

    pub fn panes(&self) -> Vec<u64> {
        self.workspaces.iter().flat_map(|w| w.tabs.iter()).flat_map(|t| t.panes()).collect()
    }

    pub fn contains_pane(&self, pane: u64) -> bool {
        self.workspaces.iter().flat_map(|w| &w.tabs).any(|t| t.layout.contains(pane))
    }

    pub fn workspace(&self, id: u64) -> Option<&Workspace> {
        self.workspaces.iter().find(|w| w.id == id)
    }

    fn workspace_mut(&mut self, id: u64) -> Option<&mut Workspace> {
        self.workspaces.iter_mut().find(|w| w.id == id)
    }

    fn tab_mut(&mut self, id: u64) -> Option<&mut Tab> {
        self.workspaces.iter_mut().flat_map(|w| w.tabs.iter_mut()).find(|t| t.id == id)
    }

    /// (workspace, tab) holding `pane`.
    pub fn locate(&self, pane: u64) -> Option<(u64, u64)> {
        for w in &self.workspaces {
            for t in &w.tabs {
                if t.layout.contains(pane) {
                    return Some((w.id, t.id));
                }
            }
        }
        None
    }

    pub fn create_workspace(&mut self, name: Option<String>, pane: u64) -> (u64, u64) {
        let ws = self.alloc();
        let tab = self.alloc();
        let name = name.unwrap_or_else(|| format!("workspace {}", self.workspaces.len() + 1));
        self.workspaces.push(Workspace {
            id: ws,
            name,
            active_tab: Some(tab),
            tabs: vec![Tab { id: tab, title: None, active_pane: pane, layout: Node::Pane { pane } }],
        });
        self.focus = Focus { workspace: Some(ws), tab: Some(tab), pane: Some(pane) };
        (ws, tab)
    }

    pub fn create_tab(&mut self, workspace: u64, pane: u64) -> Option<u64> {
        let tab = self.alloc();
        let w = self.workspace_mut(workspace)?;
        w.tabs.push(Tab { id: tab, title: None, active_pane: pane, layout: Node::Pane { pane } });
        w.active_tab = Some(tab);
        self.focus = Focus { workspace: Some(workspace), tab: Some(tab), pane: Some(pane) };
        Some(tab)
    }

    pub fn split(&mut self, pane: u64, new: u64, dir: Direction, ratio: f64) -> Option<u64> {
        let (ws, tab) = self.locate(pane)?;
        let split = self.alloc();
        let t = self.tab_mut(tab)?;
        if !t.layout.split(pane, new, dir, ratio, split) {
            return None;
        }
        t.active_pane = new;
        self.focus = Focus { workspace: Some(ws), tab: Some(tab), pane: Some(new) };
        Some(split)
    }

    /// Remove a pane from the layout; an emptied tab goes too. Returns false if it wasn't there.
    pub fn remove_pane(&mut self, pane: u64) -> bool {
        let Some((ws, tab)) = self.locate(pane) else { return false };
        let w = self.workspace_mut(ws).expect("located");
        let idx = w.tabs.iter().position(|t| t.id == tab).expect("located");
        let t = &mut w.tabs[idx];
        let layout = std::mem::replace(&mut t.layout, Node::Pane { pane: 0 });
        let mut sibling = None;
        match layout.remove(pane, &mut sibling) {
            Some(rest) => {
                if t.active_pane == pane {
                    t.active_pane = sibling.unwrap_or_else(|| rest.first_pane());
                }
                t.layout = rest;
            }
            None => {
                w.tabs.remove(idx);
                if w.active_tab == Some(tab) {
                    w.active_tab = w.tabs.get(idx.saturating_sub(1)).map(|t| t.id);
                }
            }
        }
        self.fix_focus();
        true
    }

    /// Remove a tab; returns its panes.
    pub fn close_tab(&mut self, tab: u64) -> Option<Vec<u64>> {
        for w in &mut self.workspaces {
            if let Some(i) = w.tabs.iter().position(|t| t.id == tab) {
                let t = w.tabs.remove(i);
                if w.active_tab == Some(tab) {
                    w.active_tab = w.tabs.get(i.saturating_sub(1)).map(|t| t.id);
                }
                self.fix_focus();
                return Some(t.panes());
            }
        }
        None
    }

    /// Remove a workspace; returns its panes.
    pub fn close_workspace(&mut self, ws: u64) -> Option<Vec<u64>> {
        let i = self.workspaces.iter().position(|w| w.id == ws)?;
        let w = self.workspaces.remove(i);
        self.fix_focus();
        Some(w.tabs.iter().flat_map(|t| t.panes()).collect())
    }

    pub fn rename_workspace(&mut self, ws: u64, name: String) -> bool {
        self.workspace_mut(ws).map(|w| w.name = name).is_some()
    }

    pub fn rename_tab(&mut self, tab: u64, title: Option<String>) -> bool {
        self.tab_mut(tab).map(|t| t.title = title).is_some()
    }

    pub fn set_ratio(&mut self, split: u64, ratio: f64) -> bool {
        self.workspaces.iter_mut().flat_map(|w| w.tabs.iter_mut()).any(|t| t.layout.set_ratio(split, ratio))
    }

    // The apps mirror focus_pane, focus_tab, focus_workspace and fix_focus's fallbacks
    // (ClothoKit/Sources/ClothoKit/LocalFocus.swift) to show a click's focus at once;
    // testLocalFocusMatchesTheDaemon compares the two. Tell the mac agent before changing them.
    pub fn focus_pane(&mut self, pane: u64) -> bool {
        let Some((ws, tab)) = self.locate(pane) else { return false };
        if let Some(t) = self.tab_mut(tab) {
            t.active_pane = pane;
        }
        if let Some(w) = self.workspace_mut(ws) {
            w.active_tab = Some(tab);
        }
        self.focus = Focus { workspace: Some(ws), tab: Some(tab), pane: Some(pane) };
        true
    }

    pub fn focus_tab(&mut self, tab: u64) -> bool {
        let found = self
            .workspaces
            .iter()
            .find_map(|w| w.tabs.iter().find(|t| t.id == tab).map(|t| (w.id, t.active_pane)));
        let Some((ws, pane)) = found else { return false };
        if let Some(w) = self.workspace_mut(ws) {
            w.active_tab = Some(tab);
        }
        self.focus = Focus { workspace: Some(ws), tab: Some(tab), pane: Some(pane) };
        true
    }

    pub fn focus_workspace(&mut self, ws: u64) -> bool {
        let Some(w) = self.workspace(ws) else { return false };
        let tab = w
            .active_tab
            .and_then(|id| w.tabs.iter().find(|t| t.id == id))
            .or(w.tabs.first())
            .map(|t| (t.id, t.active_pane));
        self.focus = Focus { workspace: Some(ws), tab: tab.map(|t| t.0), pane: tab.map(|t| t.1) };
        true
    }

    /// Put workspace `ws` at `index` (counted after taking it out; past the end means last).
    /// Returns its final index and whether anything changed, or `None` for an unknown id.
    pub fn move_workspace(&mut self, ws: u64, index: usize) -> Option<(usize, bool)> {
        let from = self.workspaces.iter().position(|w| w.id == ws)?;
        let w = self.workspaces.remove(from);
        let to = index.min(self.workspaces.len());
        self.workspaces.insert(to, w);
        Some((to, to != from))
    }

    /// Move `tab` to workspace `dest` (default: its own) at `index` (counted after taking it
    /// out; past the end means last), with its split tree and panes as they are. Returns the
    /// destination, the final index and whether anything changed, or `None` for an unknown id.
    ///
    /// The rules (docs/protocol.md, "Moving tabs and workspaces"; the Mac mirrors them):
    /// - the source's active tab, if it was this one, becomes the tab before it, else the new
    ///   first (tab.close's rule), or none when the source is left empty (which stays);
    /// - if the focus was on this tab, or `focus` is asked for, the destination's active tab
    ///   becomes this one and the focus goes to it (its active pane); otherwise the
    ///   destination's active tab is unchanged, unless it had none, and focus doesn't move.
    pub fn move_tab(&mut self, tab: u64, dest: Option<u64>, index: usize, focus: bool) -> Option<(u64, usize, bool)> {
        let (src, from) = self
            .workspaces
            .iter()
            .enumerate()
            .find_map(|(wi, w)| w.tabs.iter().position(|t| t.id == tab).map(|ti| (wi, ti)))?;
        let src_id = self.workspaces[src].id;
        let dest_id = dest.unwrap_or(src_id);
        let dst = self.workspaces.iter().position(|w| w.id == dest_id)?;
        let focused = self.focus.tab == Some(tab);
        let t = self.workspaces[src].tabs.remove(from);
        let pane = t.active_pane;
        let to = index.min(self.workspaces[dst].tabs.len());
        self.workspaces[dst].tabs.insert(to, t);
        let moved = dst != src || to != from;
        if dst != src {
            let s = &mut self.workspaces[src];
            if s.active_tab == Some(tab) {
                s.active_tab = s.tabs.get(from.saturating_sub(1)).map(|t| t.id);
            }
        }
        let before = (self.workspaces[dst].active_tab, self.focus.clone());
        let d = &mut self.workspaces[dst];
        if focused || focus {
            d.active_tab = Some(tab);
            self.focus = Focus { workspace: Some(dest_id), tab: Some(tab), pane: Some(pane) };
        } else if d.active_tab.is_none() {
            d.active_tab = Some(tab);
        }
        let changed = moved || before != (self.workspaces[dst].active_tab, self.focus.clone());
        Some((dest_id, to, changed))
    }

    /// Give the panes new ids (`map`, old to new), as after a restore; a pane not in `map` is
    /// removed first, as if it had exited. Focus, active tabs and active panes follow.
    pub fn remap_panes(&mut self, map: &std::collections::HashMap<u64, u64>) {
        for old in self.panes() {
            if !map.contains_key(&old) {
                self.remove_pane(old);
            }
        }
        fn walk(n: &mut Node, map: &std::collections::HashMap<u64, u64>) {
            match n {
                Node::Pane { pane } => *pane = map[pane],
                Node::Split { a, b, .. } => {
                    walk(a, map);
                    walk(b, map);
                }
            }
        }
        for t in self.workspaces.iter_mut().flat_map(|w| w.tabs.iter_mut()) {
            walk(&mut t.layout, map);
            t.active_pane = map.get(&t.active_pane).copied().unwrap_or_else(|| t.layout.first_pane());
        }
        self.focus.pane = self.focus.pane.and_then(|p| map.get(&p).copied());
        self.fix_focus();
    }

    /// Point focus at something that still exists.
    fn fix_focus(&mut self) {
        let f = self.focus.clone();
        if let Some(p) = f.pane {
            if self.contains_pane(p) {
                return;
            }
        }
        if let Some(t) = f.tab {
            if self.focus_tab(t) {
                return;
            }
        }
        if let Some(w) = f.workspace {
            if self.focus_workspace(w) {
                return;
            }
        }
        match self.workspaces.first().map(|w| w.id) {
            Some(w) => {
                self.focus_workspace(w);
            }
            None => self.focus = Focus::default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Workspace ids and their tab ids, in order.
    fn order(m: &Model) -> Vec<(u64, Vec<u64>)> {
        m.workspaces.iter().map(|w| (w.id, w.tabs.iter().map(|t| t.id).collect())).collect()
    }

    /// Three workspaces: w1 with tabs a, b, c (panes 1, 2, 3), w2 with d (pane 4), w3 empty.
    fn three() -> (Model, [u64; 3], [u64; 4]) {
        let mut m = Model::default();
        let (w1, a) = m.create_workspace(Some("one".into()), 1);
        let b = m.create_tab(w1, 2).unwrap();
        let c = m.create_tab(w1, 3).unwrap();
        let (w2, d) = m.create_workspace(Some("two".into()), 4);
        let (w3, e) = m.create_workspace(Some("three".into()), 5);
        m.close_tab(e);
        (m, [w1, w2, w3], [a, b, c, d])
    }

    #[test]
    fn move_workspace_reorders_and_clamps() {
        let (mut m, [w1, w2, w3], _) = three();
        let focus = m.focus.clone();
        assert_eq!(m.move_workspace(w1, 99), Some((2, true)));
        assert_eq!(order(&m).iter().map(|o| o.0).collect::<Vec<_>>(), vec![w2, w3, w1]);
        assert_eq!(m.move_workspace(w1, 2), Some((2, false)), "same place");
        assert_eq!(m.move_workspace(w3, 0), Some((0, true)));
        assert_eq!(order(&m).iter().map(|o| o.0).collect::<Vec<_>>(), vec![w3, w2, w1]);
        assert_eq!(m.move_workspace(999, 0), None);
        assert_eq!(m.focus, focus, "focus never moves");
    }

    #[test]
    fn move_tab_within_a_workspace() {
        let (mut m, [w1, ..], [a, b, c, _]) = three();
        m.focus_tab(b);
        assert_eq!(m.move_tab(a, None, 99, false), Some((w1, 2, true)));
        assert_eq!(order(&m)[0].1, vec![b, c, a]);
        assert_eq!(m.move_tab(a, Some(w1), 2, false), Some((w1, 2, false)), "same place");
        assert_eq!(m.move_tab(c, None, 0, false), Some((w1, 0, true)));
        assert_eq!(order(&m)[0].1, vec![c, b, a]);
        assert_eq!((m.workspaces[0].active_tab, m.focus.tab), (Some(b), Some(b)), "a reorder changes no focus");
        assert_eq!(m.move_tab(a, None, 1, true), Some((w1, 1, true)));
        assert_eq!((m.workspaces[0].active_tab, m.focus.clone()), (Some(a), Focus { workspace: Some(w1), tab: Some(a), pane: Some(1) }));
        assert_eq!(m.move_tab(999, None, 0, false), None);
        assert_eq!(m.move_tab(a, Some(999), 0, false), None);
        assert_eq!(order(&m)[0].1, vec![c, a, b], "nothing moved by the failures");
    }

    #[test]
    fn move_tab_across_workspaces() {
        let (mut m, [w1, w2, w3], [a, b, c, d]) = three();
        // Focus is in w2 (d); move w1's active tab b, unfocused, to w2's front.
        m.focus_tab(b);
        m.focus_tab(d);
        assert_eq!(m.workspaces[0].active_tab, Some(b));
        assert_eq!(m.move_tab(b, Some(w2), 0, false), Some((w2, 0, true)));
        assert_eq!(order(&m)[0..2], [(w1, vec![a, c]), (w2, vec![b, d])]);
        assert_eq!(m.workspaces[0].active_tab, Some(a), "the tab before it");
        assert_eq!(m.workspaces[1].active_tab, Some(d), "destination unchanged");
        assert_eq!(m.focus.tab, Some(d), "focus stays");
        // The first tab, active, moves out: the new first takes over.
        m.focus_tab(a);
        assert_eq!(m.move_tab(a, Some(w3), 5, false), Some((w3, 0, true)));
        assert_eq!(m.workspaces[2].active_tab, Some(a), "an empty destination gets it");
        assert_eq!(m.focus, Focus { workspace: Some(w3), tab: Some(a), pane: Some(1) }, "focus followed the tab");
        assert_eq!(m.workspaces[0].active_tab, Some(c));
        // The last tab out: the workspace stays, empty.
        assert_eq!(m.move_tab(c, Some(w2), 1, true), Some((w2, 1, true)));
        assert!(m.workspaces[0].tabs.is_empty() && m.workspaces[0].active_tab.is_none());
        assert_eq!(m.workspaces[1].active_tab, Some(c));
        assert_eq!(m.focus, Focus { workspace: Some(w2), tab: Some(c), pane: Some(3) });
        assert_eq!(m.panes(), vec![2, 3, 4, 1], "panes untouched, in their tabs");
    }

    #[test]
    fn remap_panes_keeps_the_layout() {
        let mut m = Model::default();
        let (ws, tab) = m.create_workspace(Some("w".into()), 1);
        m.split(1, 2, Direction::Right, 0.3);
        m.split(2, 3, Direction::Down, 0.5);
        let tab2 = m.create_tab(ws, 4).unwrap();
        m.focus_pane(3);
        m.focus_tab(tab2);
        m.focus_tab(tab);
        // 2 failed to come back; the rest get new ids, some equal to old ones.
        let map: std::collections::HashMap<u64, u64> = [(1, 3), (3, 7), (4, 1)].into_iter().collect();
        m.remap_panes(&map);
        assert_eq!(m.panes(), vec![3, 7, 1]);
        assert_eq!(m.focus, Focus { workspace: Some(ws), tab: Some(tab), pane: Some(7) });
        let t = &m.workspaces[0].tabs[0];
        assert_eq!(t.active_pane, 7);
        let Node::Split { ratio, .. } = &t.layout else { panic!() };
        assert_eq!(*ratio, 0.3);
        assert_eq!(m.workspaces[0].tabs[1].active_pane, 1);
    }

    #[test]
    fn split_and_remove() {
        let mut m = Model::default();
        let (ws, tab) = m.create_workspace(None, 100);
        let s1 = m.split(100, 101, Direction::Right, 0.5).unwrap();
        m.split(101, 102, Direction::Up, 0.3).unwrap();
        assert_eq!(m.panes(), vec![100, 102, 101]);
        assert_eq!(m.focus.pane, Some(102));
        assert!(m.set_ratio(s1, 2.0));
        assert!(m.remove_pane(102));
        assert_eq!(m.panes(), vec![100, 101]);
        assert_eq!(m.focus, Focus { workspace: Some(ws), tab: Some(tab), pane: Some(101) });
        assert!(m.remove_pane(100));
        assert!(m.remove_pane(101));
        assert!(m.workspace(ws).unwrap().tabs.is_empty());
        assert_eq!(m.focus, Focus { workspace: Some(ws), tab: None, pane: None });
    }

    #[test]
    fn serializes_like_the_spec() {
        let mut m = Model::default();
        m.create_workspace(Some("main".into()), 3);
        m.split(3, 4, Direction::Right, 0.5);
        let v = serde_json::to_value(&m.workspaces[0].tabs[0].layout).unwrap();
        assert_eq!(
            v,
            serde_json::json!({"type": "split", "id": 3, "axis": "horizontal", "ratio": 0.5,
                "a": {"type": "pane", "pane": 3}, "b": {"type": "pane", "pane": 4}})
        );
    }
}
