//! Workspace > Tab > split tree > Pane. Pure data plus the edits the protocol allows; the daemon
//! persists it in the holder so a restarted logic process gets it back.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Workspace {
    pub id: u64,
    pub name: String,
    /// Last focused tab; `focus` with just a workspace goes back to it.
    #[serde(default)]
    pub active_tab: Option<u64>,
    pub tabs: Vec<Tab>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Serialize, Deserialize)]
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
