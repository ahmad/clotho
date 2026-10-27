//! `u32 length | u8 type | body` framing, used on both the client socket and the holder socket.

use std::io;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const MAX_FRAME: usize = 16 << 20;

pub const T_JSON: u8 = 1;
pub const T_OUTPUT: u8 = 2;
pub const T_INPUT: u8 = 3;
pub const T_SNAPSHOT: u8 = 4;
pub const T_FILE_DATA: u8 = 5;

/// FILE_DATA flag: last frame of the stream.
pub const FILE_FIN: u8 = 1;

#[derive(Debug, Clone, PartialEq)]
pub enum Frame {
    Json(serde_json::Value),
    /// PTY output: `data` covers `[seq, seq + data.len())` of the pane's output.
    Output { pane: u64, seq: u64, data: Vec<u8> },
    /// Bytes to write to the PTY.
    Input { pane: u64, data: Vec<u8> },
    /// Terminal state after `seq` bytes, as a VT stream for a `cols`x`rows` terminal.
    Snapshot { pane: u64, seq: u64, cols: u16, rows: u16, data: Vec<u8> },
    /// Bytes of an fs.* transfer stream at `offset` of the file (docs/protocol.md, Files).
    FileData { stream: u64, offset: u64, flags: u8, data: Vec<u8> },
    /// A frame type this build does not know; receivers ignore it.
    Unknown(u8),
}

impl Frame {
    pub fn json(v: serde_json::Value) -> Frame {
        Frame::Json(v)
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = vec![0u8; 4];
        match self {
            Frame::Json(v) => {
                out.push(T_JSON);
                serde_json::to_writer(&mut out, v).expect("serializing a Value cannot fail");
            }
            Frame::Output { pane, seq, data } => {
                out.push(T_OUTPUT);
                out.extend_from_slice(&pane.to_be_bytes());
                out.extend_from_slice(&seq.to_be_bytes());
                out.extend_from_slice(data);
            }
            Frame::Input { pane, data } => {
                out.push(T_INPUT);
                out.extend_from_slice(&pane.to_be_bytes());
                out.extend_from_slice(data);
            }
            Frame::Snapshot { pane, seq, cols, rows, data } => {
                out.push(T_SNAPSHOT);
                out.extend_from_slice(&pane.to_be_bytes());
                out.extend_from_slice(&seq.to_be_bytes());
                out.extend_from_slice(&cols.to_be_bytes());
                out.extend_from_slice(&rows.to_be_bytes());
                out.extend_from_slice(data);
            }
            Frame::FileData { stream, offset, flags, data } => {
                out.push(T_FILE_DATA);
                out.extend_from_slice(&stream.to_be_bytes());
                out.extend_from_slice(&offset.to_be_bytes());
                out.push(*flags);
                out.extend_from_slice(data);
            }
            Frame::Unknown(t) => out.push(*t),
        }
        let len = (out.len() - 4) as u32;
        out[..4].copy_from_slice(&len.to_be_bytes());
        out
    }

    pub fn decode(kind: u8, body: Vec<u8>) -> io::Result<Frame> {
        let short = || io::Error::new(io::ErrorKind::InvalidData, "frame body too short");
        let u64_at = |b: &[u8], i: usize| -> io::Result<u64> {
            b.get(i..i + 8).map(|s| u64::from_be_bytes(s.try_into().unwrap())).ok_or_else(short)
        };
        let u16_at = |b: &[u8], i: usize| -> io::Result<u16> {
            b.get(i..i + 2).map(|s| u16::from_be_bytes(s.try_into().unwrap())).ok_or_else(short)
        };
        Ok(match kind {
            T_JSON => Frame::Json(
                serde_json::from_slice(&body).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?,
            ),
            T_OUTPUT => {
                let (pane, seq) = (u64_at(&body, 0)?, u64_at(&body, 8)?);
                Frame::Output { pane, seq, data: body[16..].to_vec() }
            }
            T_INPUT => {
                let pane = u64_at(&body, 0)?;
                Frame::Input { pane, data: body[8..].to_vec() }
            }
            T_SNAPSHOT => {
                let (pane, seq) = (u64_at(&body, 0)?, u64_at(&body, 8)?);
                let (cols, rows) = (u16_at(&body, 16)?, u16_at(&body, 18)?);
                Frame::Snapshot { pane, seq, cols, rows, data: body[20..].to_vec() }
            }
            T_FILE_DATA => {
                let (stream, offset) = (u64_at(&body, 0)?, u64_at(&body, 8)?);
                let flags = *body.get(16).ok_or_else(short)?;
                Frame::FileData { stream, offset, flags, data: body[17..].to_vec() }
            }
            other => Frame::Unknown(other),
        })
    }
}

/// Read one frame. `Ok(None)` on a clean EOF at a frame boundary.
pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> io::Result<Option<Frame>> {
    let mut len = [0u8; 4];
    match r.read_exact(&mut len).await {
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes(len) as usize;
    if len == 0 || len > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidData, format!("bad frame length {len}")));
    }
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf).await?;
    let kind = buf[0];
    buf.remove(0);
    Frame::decode(kind, buf).map(Some)
}

/// Blocking [`read_frame`], for code that runs before any async runtime (state handover).
pub fn read_frame_sync<R: std::io::Read>(r: &mut R) -> io::Result<Option<Frame>> {
    let mut len = [0u8; 4];
    match r.read_exact(&mut len) {
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes(len) as usize;
    if len == 0 || len > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidData, format!("bad frame length {len}")));
    }
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf)?;
    let kind = buf[0];
    buf.remove(0);
    Frame::decode(kind, buf).map(Some)
}

pub async fn write_frame<W: AsyncWrite + Unpin>(w: &mut W, frame: &Frame) -> io::Result<()> {
    w.write_all(&frame.encode()).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn roundtrip_all_types() {
        let frames = vec![
            Frame::Json(serde_json::json!({"id": 1, "method": "hello"})),
            Frame::Output { pane: 7, seq: 1 << 40, data: b"hi\x1b[0m".to_vec() },
            Frame::Input { pane: 3, data: vec![0, 1, 2] },
            Frame::Snapshot { pane: 9, seq: 5, cols: 80, rows: 24, data: b"\x1bc".to_vec() },
            Frame::Output { pane: 1, seq: 0, data: vec![] },
            Frame::FileData { stream: 3, offset: 1 << 33, flags: FILE_FIN, data: b"tail".to_vec() },
        ];
        let mut buf = Vec::new();
        for f in &frames {
            buf.extend(f.encode());
        }
        buf.extend(Frame::Unknown(99).encode());
        let mut r = &buf[..];
        for f in &frames {
            assert_eq!(read_frame(&mut r).await.unwrap().as_ref(), Some(f));
        }
        assert_eq!(read_frame(&mut r).await.unwrap(), Some(Frame::Unknown(99)));
        assert_eq!(read_frame(&mut r).await.unwrap(), None);
    }
}
