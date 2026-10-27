//! Wire format shared by clothod, its PTY holder and clients. See `docs/protocol.md` at the
//! Clotho repo root for the client protocol; the holder protocol is described in [`holder`].

pub mod frame;
pub mod holder;
pub mod listen;
pub mod platform;

pub use frame::{read_frame, write_frame, Frame};

/// Client protocol version (docs/protocol.md).
pub const PROTOCOL: u32 = 1;
/// Oldest client protocol version the daemon accepts.
pub const PROTOCOL_MIN: u32 = 1;
