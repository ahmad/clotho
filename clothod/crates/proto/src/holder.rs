//! Protocol between the logic daemon (`clothod`) and the PTY holder (`clothod holder`).
//!
//! Same framing as the client protocol. The holder accepts one logic connection at a time; a new
//! one replaces the old. It is kept small on purpose: the holder is the process that must not be
//! restarted, so every change here has to stay backward compatible with running holders.
//!
//! Logic -> holder:
//! - JSON [`ToHolder`] requests.
//! - `INPUT` frames: bytes for a pane's PTY.
//! - `SNAPSHOT` frames: the latest VT snapshot of a pane, stored for the next logic process.
//!
//! Holder -> logic:
//! - On connect, after `hello`: [`FromHolder::Welcome`], then for each pane
//!   [`FromHolder::Pane`], its stored `SNAPSHOT` (if any) and its buffered output as `OUTPUT`
//!   frames starting at `seq_start`, then [`FromHolder::Ready`]. Live output for a pane is only
//!   sent after that pane's recovery frames.
//! - Live `OUTPUT` frames for every pane, and JSON events ([`FromHolder::Exited`]...).

use serde::{Deserialize, Serialize};

/// Holder protocol this build speaks. Bump only for changes an older logic process cannot
/// handle; every bump forces "restart sessions" on upgrade.
pub const HOLDER_PROTOCOL: u32 = 1;
/// Oldest holder protocol this build's logic process can drive.
pub const HOLDER_PROTOCOL_MIN: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ToHolder {
    /// The holder answers every hello with `Welcome`, whatever the protocol: deciding whether
    /// the two can work together is the (newer) logic process's job.
    Hello {
        protocol: u32,
        #[serde(default)]
        version: Option<String>,
    },
    /// Start a process on a new PTY. Answered with `Spawned` or `Error` carrying the same `id`.
    Spawn {
        id: u64,
        command: Vec<String>,
        cwd: Option<String>,
        #[serde(default)]
        env: Vec<(String, String)>,
        cols: u16,
        rows: u16,
    },
    /// Resize the PTY. `seq` is the output position from which bytes are at the new size; the
    /// holder records it so a rebuild replays resizes at the right place.
    Resize { pane: u64, cols: u16, rows: u16, seq: u64 },
    /// Send a signal (e.g. "HUP", "KILL") to the pane's process group.
    Kill { pane: u64, signal: String },
    /// Drop an exited pane's buffers.
    Forget { pane: u64 },
    /// Opaque model state (workspaces, tabs, layout) the holder keeps for the next logic process.
    SetState { state: serde_json::Value },
    /// Hang up every pane and exit.
    Shutdown,
    /// Replace this holder's program with `exe`, in the same process: state goes over an
    /// inherited fd, so PTYs, children and buffers stay. Refused (`Error` with `id`) unless
    /// `exe holder-formats` lists this holder's state format; on success the connection just
    /// closes and the new image accepts connections again. Only holders whose `Welcome` lists
    /// `upgrade_formats` understand it.
    Upgrade { id: u64, exe: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum FromHolder {
    Welcome {
        protocol: u32,
        /// Holder build version (`clothod --version`).
        #[serde(default)]
        version: String,
        /// Path of the executable the holder runs from.
        #[serde(default)]
        exe: Option<String>,
        /// Install id of the holder's own program image (`<version>-<hash>`).
        #[serde(default)]
        build: Option<String>,
        /// State formats this holder can hand over in an in-place `Upgrade` (empty: it can't).
        #[serde(default)]
        upgrade_formats: Vec<u32>,
        /// macOS: the holder's launchd namespace (`platform::launchd_namespace`); its shells
        /// inherit it.
        #[serde(default)]
        namespace: Option<String>,
        /// Random id for this holder's lifetime (the client protocol's `instance`).
        instance: String,
        pid: u32,
        state: Option<serde_json::Value>,
    },
    Pane(PaneInfo),
    Ready,
    Spawned { id: u64, pane: PaneInfo },
    Error { id: u64, message: String },
    Exited { pane: u64, status: ExitStatus },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaneInfo {
    pub pane: u64,
    pub pid: u32,
    pub command: Vec<String>,
    pub cols: u16,
    pub rows: u16,
    /// First buffered output byte.
    pub seq_start: u64,
    /// Total output so far.
    pub seq_end: u64,
    /// Resizes at or after `seq_start`, as (seq, cols, rows), oldest first.
    #[serde(default)]
    pub resizes: Vec<(u64, u16, u16)>,
    pub exited: Option<ExitStatus>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExitStatus {
    Code(i32),
    Signal(i32),
}
