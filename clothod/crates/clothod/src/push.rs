//! Push alerts to phones (docs/push.md): `push.*` requests, registrations in `push.json`, and
//! the sender: an HPKE-sealed record per attention rise, POSTed to the phone's relay, with
//! coalescing, rate limits and retries.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use hpke::{aead::ChaCha20Poly1305, kdf::HkdfSha256, kem::X25519HkdfSha256, Deserializable, Kem, OpModeR, OpModeS, Serializable};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

pub const INFO: &[u8] = b"clotho push v1";
const MAX_MSG: usize = 400;
const PER_DEVICE_HOUR: usize = 60;

/// Timings, shortened by `CLOTHOD_TEST_PUSH_FAST` so tests don't wait minutes.
struct Timing {
    per_pane: Duration,
    /// Live Activity updates: at most one per activity this often (the latest state wins).
    activity_gap: Duration,
    /// Apple ends a Live Activity after 8 hours; its token is dropped then.
    activity_ttl: Duration,
    backoff: Duration,
    backoff_max: Duration,
    give_up: Duration,
}

fn timing() -> Timing {
    if std::env::var_os("CLOTHOD_TEST_PUSH_FAST").is_some() {
        let ms = Duration::from_millis;
        let ttl = std::env::var("CLOTHOD_TEST_ACTIVITY_TTL_MS").ok().and_then(|v| v.parse().ok()).map(ms).unwrap_or(Duration::from_secs(8 * 3600));
        return Timing { per_pane: ms(1000), activity_gap: ms(1000), activity_ttl: ttl, backoff: ms(100), backoff_max: ms(400), give_up: ms(3000) };
    }
    let s = Duration::from_secs;
    Timing { per_pane: s(30), activity_gap: s(10), activity_ttl: s(8 * 3600), backoff: s(2), backoff_max: s(60), give_up: s(600) }
}

pub struct Error {
    pub code: &'static str,
    pub message: String,
}

fn bad(message: impl Into<String>) -> Error {
    Error { code: "bad_request", message: message.into() }
}

/// What a pane's agent says when it asks for the user.
#[derive(Clone, Default)]
pub struct Alert {
    pub kind: String,
    pub state: String,
    /// What the agent says: for `done` the start of its last reply, for `waiting` the prompt
    /// it shows, for `error` the error.
    pub message: Option<String>,
    pub since: f64,
    /// The user's prompt that started this turn (first line), if they typed it.
    pub prompt: Option<String>,
    /// For `waiting`: the tool it asks about ("Bash") and its key input ("npm test").
    pub tool: Option<String>,
    pub tool_input: Option<String>,
    /// For `waiting` on a permission request: its id, for `agent.decide` (Allow/Deny).
    pub request: Option<String>,
    /// For `done` and `error`: seconds since the turn started.
    pub duration: Option<u64>,
    pub workspace_id: Option<u64>,
    pub workspace: Option<String>,
    pub tab: Option<String>,
    /// The agent's directory's name: the project.
    pub project: Option<String>,
    /// `message` (or, without one, the tool it asks about) as one or two plain sentences: a
    /// small model's rewrite (crate::summary), else the message cleaned of Markdown.
    pub summary: Option<String>,
}

impl Alert {
    /// Just the basics (the test alert, older callers).
    pub fn basic(kind: &str, state: &str, message: Option<String>, since: f64) -> Alert {
        Alert { kind: kind.into(), state: state.into(), message, since, ..Default::default() }
    }
}

#[derive(Clone, Serialize, Deserialize)]
struct Reg {
    device: String,
    handle: String,
    key: String,
    label: String,
    relay: String,
    env: String,
    created: f64,
    #[serde(default)]
    last_error: Option<String>,
    /// The relay refused the handle (400/403); skipped until the phone registers again.
    #[serde(default)]
    blocked: bool,
}

#[derive(Default)]
struct PaneState {
    attention: bool,
    /// Bumped on every rise, so a queued or retried push for an older rise can tell.
    rise: u64,
    last_sent: Option<Instant>,
    delayed: bool,
    /// The current rise is quiet: the user is at the pane (no push for it, now or delayed).
    quiet: bool,
    alert: Option<Alert>,
}

/// A Live Activity following one pane's agent on one phone (`push.activity`).
#[derive(Clone, Serialize, Deserialize)]
struct Activity {
    pane: u64,
    device: String,
    token: String,
    env: String,
    created: f64,
    #[serde(default)]
    last_error: Option<String>,
}

/// What a Live Activity shows (docs/push.md, Live Activity): the agent's state and times, and
/// the detail notifications carry. That text goes in the clear to the relay and Apple (the user's
/// choice, PLAN.md "Live Activity detail").
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Live {
    pub kind: String,
    /// running, waiting, done or error.
    pub state: String,
    /// When the current state began (unix seconds).
    pub since: u64,
    /// When the turn began, else `since`: the activity's elapsed timer.
    pub started: u64,
    /// The tool it's in or asks about ("Bash"), for running and waiting.
    pub tool: Option<String>,
    /// That tool's key input: the command or file path.
    pub detail: Option<String>,
    /// Done: its last message. Error: the error. Waiting: what it asks.
    pub msg: Option<String>,
}

/// The relay's limits on the detail keys (it refuses more with a 400). Counted in bytes of the
/// key's JSON string, escapes included: at least the UTF-16 units the relay counts, and the
/// three together stay well inside its 1024-byte content cap.
pub const LIVE_TOOL_MAX: usize = 64;
pub const LIVE_DETAIL_MAX: usize = 200;
pub const LIVE_MSG_MAX: usize = 300;

/// One line of text for an activity: control characters and line separators become spaces, runs of space fold,
/// and it's cut to `max` bytes as a JSON string (without its quotes), ending "…" when cut.
/// None when nothing is left.
pub fn live_text(text: &str, max: usize) -> Option<String> {
    let mut line = String::new();
    for c in text.chars() {
        let c = if c.is_control() || c == '\u{2028}' || c == '\u{2029}' { ' ' } else { c };
        if c == ' ' && (line.is_empty() || line.ends_with(' ')) {
            continue;
        }
        line.push(c);
    }
    let line = line.trim_end();
    if line.is_empty() {
        return None;
    }
    let size = |c: char| match c {
        '"' | '\\' => 2,
        c => c.len_utf8(),
    };
    if line.chars().map(size).sum::<usize>() <= max {
        return Some(line.to_string());
    }
    let mut out = String::new();
    let mut used = 3; // "…"
    for c in line.chars() {
        if used + size(c) > max {
            break;
        }
        used += size(c);
        out.push(c);
    }
    Some(format!("{}…", out.trim_end()))
}

impl Live {
    fn content(&self) -> Value {
        // The relay takes `^[a-z][a-z0-9_-]{0,31}$`: a reported kind is any short text.
        let mut kind: String = self.kind.to_ascii_lowercase().chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '-' }).take(32).collect();
        if !kind.starts_with(|c: char| c.is_ascii_lowercase()) {
            kind = "other".into();
        }
        let mut c = json!({"state": self.state, "kind": kind, "since": self.since, "started": self.started});
        // Optional, and left out when absent: older apps decode the four keys above.
        let tool = self.tool.as_deref().filter(|t| (1..=LIVE_TOOL_MAX).contains(&t.len()) && t.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.:-".contains(&b)));
        let detail = self.detail.as_deref().and_then(|d| live_text(d, LIVE_DETAIL_MAX));
        let msg = self.msg.as_deref().and_then(|m| live_text(m, LIVE_MSG_MAX));
        for (k, v) in [("tool", tool.map(str::to_string)), ("detail", detail), ("msg", msg)] {
            if let Some(v) = v {
                c[k] = json!(v);
            }
        }
        c
    }

    fn ended(&self) -> bool {
        matches!(self.state.as_str(), "done" | "error")
    }
}

/// Sending state per activity (not stored).
#[derive(Default)]
struct ActivitySend {
    last_sent: Option<Instant>,
    /// A timer will send the latest state at the end of the gap.
    pending: bool,
    /// The content last sent, so an unchanged state isn't sent again.
    sent: Option<Live>,
    /// The last `timestamp` sent: APNs drops updates that aren't newer.
    timestamp: u64,
}

#[derive(Default)]
struct Inner {
    activities: Vec<Activity>,
    /// Each pane's agent as an activity shows it (None: no agent, or one it can't show).
    live: HashMap<u64, Live>,
    activity_send: HashMap<(u64, String), ActivitySend>,
    regs: Vec<Reg>,
    panes: HashMap<u64, PaneState>,
    sent: HashMap<String, VecDeque<Instant>>,
}

pub struct Push {
    path: PathBuf,
    inner: Mutex<Inner>,
}

fn unix_now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// First 32 hex digits of SHA-256(label + "/" + pane): stable per pane, so alerts replace each other.
pub fn collapse_id(label: &str, pane: u64) -> String {
    Sha256::digest(format!("{label}/{pane}").as_bytes())[..16].iter().map(|b| format!("{b:02x}")).collect()
}

fn public_key(b64: &str) -> Option<<X25519HkdfSha256 as Kem>::PublicKey> {
    let raw = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
    <X25519HkdfSha256 as Kem>::PublicKey::from_bytes(&raw).ok()
}

/// HPKE base mode to `key`: `base64(enc || ct)`.
pub fn seal(key_b64: &str, plaintext: &[u8], aad: &[u8]) -> Option<String> {
    let pk = public_key(key_b64)?;
    let (enc, ct) = hpke::single_shot_seal::<ChaCha20Poly1305, HkdfSha256, X25519HkdfSha256>(&OpModeS::Base, &pk, INFO, plaintext, aad).ok()?;
    let mut out = enc.to_bytes().to_vec();
    out.extend_from_slice(&ct);
    Some(base64::engine::general_purpose::STANDARD.encode(out))
}

/// The phone's side of [`seal`], for tests.
pub fn open(private_b64: &str, ciphertext_b64: &str, aad: &[u8]) -> Option<Vec<u8>> {
    let b64 = base64::engine::general_purpose::STANDARD;
    let sk = <X25519HkdfSha256 as Kem>::PrivateKey::from_bytes(&b64.decode(private_b64).ok()?).ok()?;
    let data = b64.decode(ciphertext_b64).ok()?;
    let (enc, ct) = data.split_at_checked(32)?;
    let enc = <X25519HkdfSha256 as Kem>::EncappedKey::from_bytes(enc).ok()?;
    hpke::single_shot_open::<ChaCha20Poly1305, HkdfSha256, X25519HkdfSha256>(&OpModeR::Base, &sk, &enc, INFO, ct, aad).ok()
}

/// The record a phone decrypts: `{"v":1, "m", "p", "k", "s", "msg", "t"}`, plus what of
/// `w`, `wid`, `tb`, `pj`, `q`, `tool`, `cmd`, `sm`, `d`, `rq` the alert has (docs/push.md).
///
/// Each text is first held to its own cap (bytes, on a char boundary). If the record would still
/// pass MAX_RECORD padded (long names, escape-heavy text), texts are halved in this order until
/// it fits: the result (`msg`), the prompt (`q`), the tool input (`cmd`), the summary (`sm`),
/// the project, tab and workspace names, and last the label.
fn plaintext(label: &str, pane: u64, a: &Alert) -> Vec<u8> {
    let cut = |m: &str, max: usize| {
        let mut end = m.len().min(max);
        while !m.is_char_boundary(end) {
            end -= 1;
        }
        m[..end].to_string()
    };
    let capped = |t: &Option<String>, max: usize| t.as_deref().map(|t| cut(t, max));
    // In cutting order; the label (`m`) goes last.
    let mut texts: Vec<(&str, Option<String>)> = vec![
        ("msg", capped(&a.message, MAX_MSG)),
        ("q", capped(&a.prompt, MAX_PROMPT)),
        ("cmd", capped(&a.tool_input, MAX_TOOL_INPUT)),
        ("sm", capped(&a.summary, MAX_SUMMARY)),
        ("pj", capped(&a.project, MAX_NAME)),
        ("tb", capped(&a.tab, MAX_NAME)),
        ("w", capped(&a.workspace, MAX_NAME)),
    ];
    let mut label = label.to_string();
    let record = |label: &str, texts: &[(&str, Option<String>)]| {
        let mut v = json!({"v": 1, "m": label, "p": pane, "k": a.kind, "s": a.state, "msg": texts[0].1, "t": a.since});
        for (k, t) in &texts[1..] {
            if let Some(t) = t {
                v[*k] = json!(t);
            }
        }
        if let Some(id) = a.workspace_id {
            v["wid"] = json!(id);
        }
        if let Some(tool) = &a.tool {
            v["tool"] = json!(cut(tool, MAX_NAME));
        }
        if let Some(d) = a.duration {
            v["d"] = json!(d);
        }
        if let Some(r) = &a.request {
            v["rq"] = json!(cut(r, 64));
        }
        v
    };
    let pad_key = r#","pad":"""#.len();
    // At most MAX_RECORD padded (the relay refuses bigger ciphertexts).
    loop {
        let len = serde_json::to_vec(&record(&label, &texts)).unwrap().len() + pad_key;
        if len <= MAX_RECORD {
            break;
        }
        match texts.iter_mut().find(|(_, t)| t.as_ref().is_some_and(|t| !t.is_empty())) {
            Some((_, t)) => *t = t.as_deref().map(|t| cut(t, t.len() / 2)),
            None => label = cut(&label, label.len() / 2),
        }
    }
    let mut v = record(&label, &texts);
    // Padded to a multiple of PAD_TO bytes with a `pad` of spaces, so the ciphertext's length
    // (which the relay and APNs see) doesn't tell how long the texts are.
    let len = serde_json::to_vec(&v).unwrap().len() + pad_key;
    v["pad"] = json!(" ".repeat(len.div_ceil(PAD_TO) * PAD_TO - len));
    serde_json::to_vec(&v).unwrap()
}

/// Caps per text in a push record, in bytes (before the record's own cap).
const MAX_PROMPT: usize = 240;
const MAX_TOOL_INPUT: usize = 240;
const MAX_NAME: usize = 96;
/// The summary is asked for in at most 160 characters and kept to 200 (crate::summary).
pub const MAX_SUMMARY: usize = 320;

/// Largest record sealed: 2048 bytes is about 2,800 base64 characters of ciphertext, under the
/// relay's 3,000 (ios/relay, MAX_CIPHERTEXT).
pub const MAX_RECORD: usize = 2 * PAD_TO;

/// Push records are padded to a multiple of this many bytes: every record is 1024 bytes unless
/// its label (machine name) and an escape-heavy message are unusually long.
pub const PAD_TO: usize = 1024;

/// https anywhere; plain http only to this machine (a dev relay).
fn check_relay(url: &str) -> Result<(), Error> {
    let host = |rest: &str| rest.split('/').next().unwrap_or("").to_string();
    if let Some(rest) = url.strip_prefix("https://") {
        if !host(rest).is_empty() {
            return Ok(());
        }
    } else if let Some(rest) = url.strip_prefix("http://") {
        let h = host(rest);
        let name = if h.starts_with('[') { h.split(']').next().map(|s| format!("{s}]")).unwrap_or_default() } else { h.split(':').next().unwrap_or("").to_string() };
        if matches!(name.as_str(), "127.0.0.1" | "localhost" | "[::1]") {
            return Ok(());
        }
        return Err(bad("relay: http:// is only allowed for localhost; use https://"));
    }
    Err(bad("relay must be an https:// URL"))
}

/// What a relay POST came to.
enum Outcome {
    Sent,
    /// 410: the phone's token is gone.
    Gone,
    /// 400/403: the relay refused the handle.
    Refused(u16),
    /// 429, 5xx or no answer: worth retrying.
    Retry(String),
    Failed(String),
}

fn post(relay: &str, body: &Value) -> Outcome {
    post_to(relay, "/v1/push", body)
}

fn post_to(relay: &str, path: &str, body: &Value) -> Outcome {
    let url = format!("{}{path}", relay.trim_end_matches('/'));
    match ureq::post(&url).timeout(Duration::from_secs(20)).set("content-type", "application/json").send_string(&body.to_string()) {
        Ok(_) => Outcome::Sent,
        Err(ureq::Error::Status(410, _)) => Outcome::Gone,
        Err(ureq::Error::Status(c @ (400 | 403), _)) => Outcome::Refused(c),
        Err(ureq::Error::Status(c, _)) if c == 429 || c >= 500 => Outcome::Retry(format!("relay answered {c}")),
        Err(ureq::Error::Status(c, _)) => Outcome::Failed(format!("relay answered {c}")),
        Err(e) => Outcome::Retry(format!("relay unreachable: {e}")),
    }
}

impl Push {
    /// Registrations live in `dir/push.json`.
    /// Registrations live in `dir/push.json`, Live Activities in `dir/push-activities.json`
    /// (a file of their own, so push.json keeps the format older daemons read).
    pub fn load(dir: &Path) -> Arc<Push> {
        let path = dir.join("push.json");
        let regs = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        let activities = std::fs::read(Self::activities_path(&path)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Arc::new(Push { path, inner: Mutex::new(Inner { regs, activities, ..Default::default() }) })
    }

    fn activities_path(path: &Path) -> PathBuf {
        path.with_file_name("push-activities.json")
    }

    fn save(&self, regs: &[Reg]) {
        self.write(&self.path, &serde_json::to_vec_pretty(regs).unwrap());
    }

    fn save_activities(&self, activities: &[Activity]) {
        self.write(&Self::activities_path(&self.path), &serde_json::to_vec_pretty(activities).unwrap());
    }

    fn write(&self, path: &Path, data: &[u8]) {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        if let Some(dir) = path.parent() {
            let _ = clotho_proto::platform::ensure_private_dir(dir);
        }
        let tmp = path.with_extension("tmp");
        let _ = std::fs::remove_file(&tmp);
        let ok = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp).and_then(|mut f| f.write_all(data));
        if ok.is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }

    pub async fn request(self: &Arc<Self>, method: &str, p: &Value) -> Result<Value, Error> {
        let s = |k: &str| p.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
        match method {
            "push.register" => {
                let need = |k: &str| s(k).map(String::from).ok_or_else(|| bad(format!("missing {k}")));
                let (device, handle, key, label, relay) = (need("device")?, need("handle")?, need("key")?, need("label")?, need("relay")?);
                let env = s("env").unwrap_or("production");
                if !matches!(env, "sandbox" | "production") {
                    return Err(bad("env must be sandbox or production"));
                }
                if device.len() > 200 || handle.len() > 2048 || label.len() > 500 {
                    return Err(bad("device, handle or label too long"));
                }
                if public_key(&key).is_none() {
                    return Err(bad("key must be a base64 X25519 public key"));
                }
                check_relay(&relay)?;
                let reg = Reg { device, handle, key, label, relay, env: env.into(), created: unix_now(), last_error: None, blocked: false };
                let mut g = self.inner.lock().unwrap();
                g.regs.retain(|r| r.device != reg.device);
                g.regs.push(reg);
                self.save(&g.regs);
                Ok(json!({}))
            }
            "push.unregister" => {
                let device = s("device").ok_or_else(|| bad("missing device"))?;
                let mut g = self.inner.lock().unwrap();
                g.regs.retain(|r| r.device != device);
                self.save(&g.regs);
                if g.activities.iter().any(|a| a.device == device) {
                    g.activities.retain(|a| a.device != device);
                    g.activity_send.retain(|(_, d), _| d != device);
                    self.save_activities(&g.activities);
                }
                Ok(json!({}))
            }
            "push.activity" => {
                let pane = p.get("pane").and_then(Value::as_u64).ok_or_else(|| bad("missing pane"))?;
                let device = s("device").ok_or_else(|| bad("missing device"))?.to_string();
                let token = s("token").ok_or_else(|| bad("missing token"))?.to_string();
                if !(64..=200).contains(&token.len()) || !token.bytes().all(|b| b.is_ascii_hexdigit()) {
                    return Err(bad("token must be 64 to 200 hex characters"));
                }
                let mut g = self.inner.lock().unwrap();
                let reg = g.regs.iter().find(|r| r.device == device).ok_or_else(|| Error { code: "not_found", message: format!("no registration for device {device}") })?;
                let env = s("env").unwrap_or(&reg.env).to_string();
                if !matches!(env.as_str(), "sandbox" | "production") {
                    return Err(bad("env must be sandbox or production"));
                }
                g.activities.retain(|a| !(a.pane == pane && a.device == device));
                g.activities.push(Activity { pane, device: device.clone(), token, env, created: unix_now(), last_error: None });
                g.activity_send.remove(&(pane, device.clone()));
                self.save_activities(&g.activities);
                // Right away with the current state, so a change between the app starting the
                // activity and this request isn't missed. An ended or absent agent waits for the
                // next turn (the user's prompt may not have reached it yet).
                if g.live.get(&pane).is_some_and(|l| !l.ended()) {
                    self.activity_send(&mut g, pane, &device);
                }
                Ok(json!({}))
            }
            "push.activity_end" => {
                let pane = p.get("pane").and_then(Value::as_u64).ok_or_else(|| bad("missing pane"))?;
                let device = s("device").ok_or_else(|| bad("missing device"))?.to_string();
                let mut g = self.inner.lock().unwrap();
                g.activities.retain(|a| !(a.pane == pane && a.device == device));
                g.activity_send.remove(&(pane, device));
                self.save_activities(&g.activities);
                Ok(json!({}))
            }
            "push.list" => {
                let g = self.inner.lock().unwrap();
                let devices: Vec<Value> = g
                    .regs
                    .iter()
                    .map(|r| json!({"device": r.device, "label": r.label, "relay": r.relay, "env": r.env, "created": r.created, "last_error": r.last_error}))
                    .collect();
                let ttl = timing().activity_ttl.as_secs_f64();
                let activities: Vec<Value> = g
                    .activities
                    .iter()
                    .filter(|a| unix_now() - a.created < ttl)
                    .map(|a| json!({"pane": a.pane, "device": a.device, "created": a.created, "last_error": a.last_error}))
                    .collect();
                Ok(json!({"devices": devices, "activities": activities}))
            }
            "push.test" => {
                let device = s("device").ok_or_else(|| bad("missing device"))?;
                let reg = self.inner.lock().unwrap().regs.iter().find(|r| r.device == device).cloned();
                let reg = reg.ok_or_else(|| Error { code: "not_found", message: format!("no registration for device {device}") })?;
                let alert = Alert::basic("clotho", "done", Some("Test alert".into()), unix_now());
                let body = body(&reg, 0, &alert).ok_or_else(|| bad("registered key is invalid"))?;
                let relay = reg.relay.clone();
                let outcome = tokio::task::spawn_blocking(move || post(&relay, &body)).await.unwrap_or(Outcome::Failed("send failed".into()));
                match self.settle(&reg, outcome) {
                    None => Ok(json!({})),
                    Some(e) => Err(Error { code: "relay_error", message: e }),
                }
            }
            _ => Err(Error { code: "unknown_method", message: format!("unknown method {method}") }),
        }
    }

    /// A pane's attention, every time it changes. A rise pushes to every registered phone, at
    /// most once per pane per `per_pane` (a later rise waits and goes out with the latest alert).
    /// A `quiet` rise (the user is at the pane) sends nothing.
    ///
    /// `rewrite`: a notification rewrite under way (crate::summary). The push waits for it up
    /// to `summary::push_wait()`, then goes with whatever `alert.summary` holds.
    pub fn attention(self: &Arc<Self>, pane: u64, on: bool, alert: Option<Alert>, quiet: bool, rewrite: Option<tokio::sync::watch::Receiver<Option<String>>>) {
        let mut g = self.inner.lock().unwrap();
        if g.regs.is_empty() && !on {
            g.panes.remove(&pane);
            return;
        }
        let ps = g.panes.entry(pane).or_default();
        let rose = on && !ps.attention;
        ps.attention = on;
        if !rose {
            return;
        }
        ps.rise += 1;
        ps.alert = alert;
        ps.quiet = quiet;
        if quiet {
            return;
        }
        let Some(mut rx) = rewrite else {
            self.schedule(&mut g, pane);
            return;
        };
        let rise = ps.rise;
        drop(g);
        let me = self.clone();
        tokio::spawn(async move {
            let text = match tokio::time::timeout(crate::summary::push_wait(), rx.wait_for(Option::is_some)).await {
                Ok(Ok(v)) => v.clone(),
                _ => None,
            };
            let mut g = me.inner.lock().unwrap();
            let Some(ps) = g.panes.get_mut(&pane) else { return };
            if ps.rise != rise || !ps.attention || ps.quiet {
                return;
            }
            if let (Some(t), Some(a)) = (text, ps.alert.as_mut()) {
                a.summary = Some(t);
            }
            me.schedule(&mut g, pane);
        });
    }

    /// Push the pane's alert now, or once its per-pane interval has passed.
    fn schedule(self: &Arc<Self>, g: &mut Inner, pane: u64) {
        let t = timing();
        let Some(ps) = g.panes.get_mut(&pane) else { return };
        let wait = ps.last_sent.map(|at| (at + t.per_pane).saturating_duration_since(Instant::now())).unwrap_or_default();
        if wait.is_zero() {
            self.dispatch(g, pane);
        } else if !ps.delayed {
            ps.delayed = true;
            let me = self.clone();
            tokio::spawn(async move {
                tokio::time::sleep(wait).await;
                let mut g = me.inner.lock().unwrap();
                let Some(ps) = g.panes.get_mut(&pane) else { return };
                ps.delayed = false;
                if ps.attention && !ps.quiet {
                    me.dispatch(&mut g, pane);
                }
            });
        }
    }

    /// Send the pane's current alert to every phone, within each one's hourly budget.
    fn dispatch(self: &Arc<Self>, g: &mut Inner, pane: u64) {
        let Some(ps) = g.panes.get_mut(&pane) else { return };
        let Some(alert) = ps.alert.clone() else { return };
        ps.last_sent = Some(Instant::now());
        let rise = ps.rise;
        let hour = Duration::from_secs(3600);
        let mut changed = false;
        for i in 0..g.regs.len() {
            if g.regs[i].blocked {
                continue;
            }
            let sent = g.sent.entry(g.regs[i].device.clone()).or_default();
            while sent.front().is_some_and(|at| at.elapsed() >= hour) {
                sent.pop_front();
            }
            if sent.len() >= PER_DEVICE_HOUR {
                g.regs[i].last_error = Some(format!("rate limited: {PER_DEVICE_HOUR} alerts in the last hour; dropped one"));
                changed = true;
                continue;
            }
            sent.push_back(Instant::now());
            let reg = g.regs[i].clone();
            let Some(body) = body(&reg, pane, &alert) else { continue };
            let me = self.clone();
            tokio::spawn(async move { me.deliver(reg, body, pane, rise).await });
        }
        if changed {
            self.save(&g.regs);
        }
    }

    /// POST with retries (backoff) while the pane still wants the user, for up to `give_up`.
    async fn deliver(self: Arc<Self>, reg: Reg, body: Value, pane: u64, rise: u64) {
        let t = timing();
        let deadline = Instant::now() + t.give_up;
        let mut backoff = t.backoff;
        loop {
            let (relay, b) = (reg.relay.clone(), body.clone());
            let outcome = tokio::task::spawn_blocking(move || post(&relay, &b)).await.unwrap_or(Outcome::Failed("send failed".into()));
            let Outcome::Retry(why) = outcome else {
                self.settle(&reg, outcome);
                return;
            };
            if Instant::now() + backoff > deadline {
                self.settle(&reg, Outcome::Failed(format!("{why}; gave up")));
                return;
            }
            tokio::time::sleep(backoff).await;
            backoff = (backoff * 2).min(t.backoff_max);
            // A stale "needs you" must not arrive late.
            let wanted = self.inner.lock().unwrap().panes.get(&pane).is_some_and(|ps| ps.attention && ps.rise == rise);
            if !wanted {
                return;
            }
        }
    }

    /// A pane's agent, every time it changes (None: gone, or nothing an activity can show).
    /// Activities following the pane get an update, or `end` when the turn is over.
    pub fn agent(self: &Arc<Self>, pane: u64, live: Option<Live>) {
        let mut g = self.inner.lock().unwrap();
        let prev = match &live {
            Some(l) => g.live.insert(pane, l.clone()),
            None => g.live.remove(&pane),
        };
        if prev == live || !g.activities.iter().any(|a| a.pane == pane) {
            return;
        }
        match live {
            Some(l) if !l.ended() => {
                let devices: Vec<String> = g.activities.iter().filter(|a| a.pane == pane).map(|a| a.device.clone()).collect();
                for d in devices {
                    self.activity_send(&mut g, pane, &d);
                }
            }
            // Done, error or gone: the final state, then the tokens go.
            Some(l) => self.activity_end(&mut g, pane, &l),
            None => {
                if let Some(p) = prev {
                    self.activity_end(&mut g, pane, &p);
                }
            }
        }
    }

    /// The pane closed: its activities end with the last state they showed.
    pub fn pane_gone(self: &Arc<Self>, pane: u64) {
        let mut g = self.inner.lock().unwrap();
        let last = g.live.remove(&pane);
        if !g.activities.iter().any(|a| a.pane == pane) {
            return;
        }
        match last {
            Some(l) => self.activity_end(&mut g, pane, &l),
            None => {
                g.activities.retain(|a| a.pane != pane);
                g.activity_send.retain(|(p, _), _| *p != pane);
                self.save_activities(&g.activities);
            }
        }
    }

    /// Drop activities past Apple's 8 hours. Returns whether any went.
    fn expire_activities(&self, g: &mut Inner) -> bool {
        let ttl = timing().activity_ttl.as_secs_f64();
        let before = g.activities.len();
        g.activities.retain(|a| unix_now() - a.created < ttl);
        if g.activities.len() == before {
            return false;
        }
        let live: Vec<(u64, String)> = g.activities.iter().map(|a| (a.pane, a.device.clone())).collect();
        g.activity_send.retain(|k, _| live.contains(k));
        self.save_activities(&g.activities);
        true
    }

    /// Send an update for one activity now, or at the end of its gap (with the state then).
    fn activity_send(self: &Arc<Self>, g: &mut Inner, pane: u64, device: &str) {
        let gap = timing().activity_gap;
        let st = g.activity_send.entry((pane, device.to_string())).or_default();
        if st.pending {
            return;
        }
        let wait = st.last_sent.map(|at| (at + gap).saturating_duration_since(Instant::now())).unwrap_or_default();
        if wait.is_zero() {
            self.activity_post(g, pane, device, "update", None);
            return;
        }
        st.pending = true;
        let (me, device) = (self.clone(), device.to_string());
        tokio::spawn(async move {
            tokio::time::sleep(wait).await;
            let mut g = me.inner.lock().unwrap();
            let Some(st) = g.activity_send.get_mut(&(pane, device.clone())) else { return };
            st.pending = false;
            // An end in the meantime dropped the activity; an ended state is the end's to send.
            if g.live.get(&pane).is_some_and(|l| !l.ended()) {
                me.activity_post(&mut g, pane, &device, "update", None);
            }
        });
    }

    /// `end` to every activity of the pane, at once, then forget them.
    fn activity_end(self: &Arc<Self>, g: &mut Inner, pane: u64, last: &Live) {
        let devices: Vec<String> = g.activities.iter().filter(|a| a.pane == pane).map(|a| a.device.clone()).collect();
        for d in &devices {
            self.activity_post(g, pane, d, "end", Some(last.clone()));
        }
        g.activities.retain(|a| a.pane != pane);
        g.activity_send.retain(|(p, _), _| *p != pane);
        self.save_activities(&g.activities);
    }

    /// POST one activity event. Updates go once (a newer one supersedes a failed one); `end` is
    /// retried like alerts.
    fn activity_post(self: &Arc<Self>, g: &mut Inner, pane: u64, device: &str, event: &'static str, last: Option<Live>) {
        if self.expire_activities(g) && !g.activities.iter().any(|a| a.pane == pane && a.device == device) {
            return;
        }
        let Some(live) = last.or_else(|| g.live.get(&pane).cloned()) else { return };
        let Some(act) = g.activities.iter().find(|a| a.pane == pane && a.device == device).cloned() else { return };
        let Some(reg) = g.regs.iter().find(|r| r.device == device && !r.blocked).cloned() else { return };
        let st = g.activity_send.entry((pane, device.to_string())).or_default();
        if event == "update" && st.sent.as_ref() == Some(&live) {
            return;
        }
        let now = unix_now() as u64;
        let timestamp = now.max(st.timestamp + 1);
        st.timestamp = timestamp;
        st.last_sent = Some(Instant::now());
        st.sent = Some(live.clone());
        let mut body = json!({"handle": reg.handle, "token": act.token, "env": act.env, "event": event, "content": live.content(), "timestamp": timestamp});
        if event == "end" {
            body["dismiss"] = json!(timestamp + 300);
        } else {
            body["stale"] = json!(timestamp + 900);
        }
        let me = self.clone();
        let device = device.to_string();
        tokio::spawn(async move {
            let t = timing();
            let deadline = Instant::now() + t.give_up;
            let mut backoff = t.backoff;
            loop {
                let (relay, b) = (reg.relay.clone(), body.clone());
                let outcome = tokio::task::spawn_blocking(move || post_to(&relay, "/v1/activity", &b)).await.unwrap_or(Outcome::Failed("send failed".into()));
                let error = match outcome {
                    Outcome::Sent => None,
                    Outcome::Gone => {
                        let mut g = me.inner.lock().unwrap();
                        g.activities.retain(|a| !(a.pane == pane && a.device == device && a.token == act.token));
                        me.save_activities(&g.activities);
                        return;
                    }
                    Outcome::Retry(why) if event == "end" && Instant::now() + backoff <= deadline => {
                        tokio::time::sleep(backoff).await;
                        backoff = (backoff * 2).min(t.backoff_max);
                        let _ = why;
                        continue;
                    }
                    Outcome::Refused(c) => Some(format!("relay refused the activity ({c})")),
                    Outcome::Retry(e) | Outcome::Failed(e) => Some(e),
                };
                let mut g = me.inner.lock().unwrap();
                if let Some(a) = g.activities.iter_mut().find(|a| a.pane == pane && a.device == device && a.token == act.token) {
                    if a.last_error != error {
                        a.last_error = error;
                        let acts = g.activities.clone();
                        me.save_activities(&acts);
                    }
                }
                return;
            }
        });
    }

    /// Record how a send went on its registration (if that registration is still current).
    /// Returns the error, if any.
    fn settle(&self, reg: &Reg, outcome: Outcome) -> Option<String> {
        let mut g = self.inner.lock().unwrap();
        let Some(i) = g.regs.iter().position(|r| r.device == reg.device && r.handle == reg.handle) else {
            return match outcome {
                Outcome::Sent => None,
                _ => Some("registration changed while sending".into()),
            };
        };
        let error = match outcome {
            Outcome::Sent => None,
            Outcome::Gone => {
                g.regs.remove(i);
                self.save(&g.regs);
                return Some("the phone's push token is no longer valid; registration removed".into());
            }
            Outcome::Refused(c) => {
                g.regs[i].blocked = true;
                Some(format!("relay refused the handle ({c}); waiting for the phone to register again"))
            }
            Outcome::Retry(e) | Outcome::Failed(e) => Some(e),
        };
        if g.regs[i].last_error != error {
            g.regs[i].last_error = error.clone();
            self.save(&g.regs);
        }
        error
    }
}

fn body(reg: &Reg, pane: u64, alert: &Alert) -> Option<Value> {
    let collapse = collapse_id(&reg.label, pane);
    let ciphertext = seal(&reg.key, &plaintext(&reg.label, pane, alert), collapse.as_bytes())?;
    Some(json!({"handle": reg.handle, "ciphertext": ciphertext, "collapse_id": collapse}))
}

#[cfg(test)]
mod tests {
    use super::*;

    // The vector shared with the iOS side (ClothoTests/PushTests). CT_IOS was sealed by iOS
    // (CryptoKit) for Rust to open; CT, CT_PADDED, CT_FULL and CT_PERMISSION were sealed by
    // clothod (resealed in 3be7df2) for iOS to open with SK.
    const SK: &str = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=";
    const PK: &str = "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=";
    const LABEL: &str = "00000000-0000-0000-0000-00000000C10D devbox";
    /// PLAIN (unpadded) sealed to PK by clothod.
    const CT: &str = "7Nr1oOMC39SZcf90z0zGpw6evTVseUzsnkRUWv1Dz3GDqh2klG2lrOSWha+TcMj78vQjWJdV5OHK4XEpXTo5ri24K2/R/Ca6H+6hEMjL19aYfHwIY26pxFi+O4BQYdc7e/Gao2nYt8ZONGK9BnLADuzmSh3FhkrBoNIrE3zlefKhzUbE700B8hKzUGL5eorQ/vAEcJvPX29y1YNtaB5qjuIN25vsqRM25H9l54TJa58geXZqxyDDSWpPyyQcLB0=";
    /// PLAIN sealed to PK by iOS (CryptoKit), AAD = the collapse id; the same string as PushTests.vectorCiphertext.
    /// Rust can't reseal it: if INFO or the suite changes, iOS must seal it again.
    const CT_IOS: &str = "LaMPSZpg7wDeSa1yKp1q9SqiEIXggADLO+ezBn4U+ASwiLzAzxIW/mFiE3NZD9atex8F8qBz71MO52bkXdUDQicnz4HhbuiIsGs9wtoKFYzhZC3un764DD+Oia6eDSVNLpEq+dZ7MGzfC3zaIkHKhDDBk2Ut7/UdoR2JL8pThT1ZBuB3CSHZZ8AGF8gUdjpYzFZaVM6rrDRS25e7dlGvSQi/Y+vaakVJyA8yhPKEfksd9AZIwTNsu+huFFT2jzU=";
    /// PLAIN as clothod sends it since 0.1.11: padded to 1024 bytes.
    const PADDED: &str = r#"{"v":1,"m":"00000000-0000-0000-0000-00000000C10D devbox","p":7,"k":"claude","s":"waiting","msg":"Allow cargo test --release?","t":1761512345.5,"pad":"                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        "}"#;
    /// PADDED sealed to PK (by clothod), for iOS to open with SK.
    const CT_PADDED: &str = "1os6Zx8iJ3Bc8mFS6jX808zzJa+FCOcYMMsicsVk+l7MeFf9SFSQ+BugL0LbWMK8BPSPbUwxMaEMx9vv+tk/keKCDSJzL2N9uzXaKV4wZBhWtWKeyA/VopbuU8AkiuIQBglHHl/3wUBzpkGSKRtnj1m21gToALLQrv0eY3p/dvnM3KxZIVQDk0ygbwbOU5DgU6nlc65g7W7fZ+swgcUVcKIsiKz8sZ5hau6FuIsWdAVZoA6BeXEa3MiDg6War2NkKsV6YXiy2GLbqLujaESWGiMh/vdwqE9mTQkZJmMqZ1hcT6FAqEKFm/I9OUkheONXTxvU+JpjNoqzQjRYmYuf7o+cUfb0y/n6pqNGapTX3Wo2tJZGrcZnHiA6Plh2LoOdOvtDYONZ2o8msQBLW3kbAKmXQhVrBPwmoCFmuACZ6L5l5hmrXhC6T9ryB3tF/7LFwGoHOA9OjNP9jxKXPpeOfVi0t8vYIXRPgK+U7WjOD/fmA7e9sw7f3aqfY8I6wbjyZzepxvG+Ihx4SP0UsaQmwUhcdv08FGn4X3hzwbzg8RU/SZpvD3MdeTG/6Vu2AgUwiwbGwlYZTejB8Lgbg39+VPbGgaRfQehTjST92xir5jHU6yEreM2kQMu+XyY4ZHNj8zq6idApk7l4hI5p4kgIj+4CSi//78VgAmCW7Cxd/NPHr43m07niXZyW2fuIUDgt9iPvSc4gSqhV4m3gme2VRzSgUC3KXDKiHmiOM+DAvBGe8subWB9vLioLM8zsuo3h/peIbHJ+Co8g0A48a2lb11GQXMp/qFNUZsHqGYiF8+Xry/AK/vy9Gy0/OkmmJO8yG3JU9wprvlE+4GMYxXO1RIPdP2Imka+Z1vIGDG+866pyLAKQNQIVubhladTr7mx8B95SzsqDP4DnHW9KGtXvZqYIrT5uqdUoQxW/u7D5DjRua3NSSaMyL4GgpqWtpBkxqiXiWCh4omqClpGgA435tQYcGZTSzDX8T6HqkAMRaUzIggy7leRMUtayWKNOFM8xD6GQk5SVU0edtsfkm/+q04T0nz0Qv3X0gTbrAMKbsvbJGJ0O/IbNgfZfSTmUfyypK5xD8vNjVbUtQUbfR9bnJKK/4h++ylYZG45+EM+Q2HCTqd/CkUd6PluHJmVi0mozOcE3VhMKO6ukB02YNLMYFeu+nAmPQnkjajXkUypD2Ez5iq0BMLA4OD9WQMbLsijHVOfqpkx/lhKz/xvg40YziXbr5OomxNGN7F7YmToZa1ki0M/2ywwTIuYH63TDXW4kl8VEJjDQAGQtVHvoA7mYK5VM8/pyGVyoRWV34wLCqKgXo9aNivxiaOnpzYkD4xmxzZY5vrVT9RfkEyEzR5oh+I81/T+jxmJ7ZbBtGP6QwJkifSYAzrpU3dsZ/W8k9L5JwM8Hz6tgARWg7jNxLUGuLA==";
    /// A done record with every detail (`full()`), padded to 1024 bytes.
    const FULL: &str = r#"{"v":1,"m":"00000000-0000-0000-0000-00000000C10D devbox","p":7,"k":"claude","s":"done","msg":"All 61 tests pass. I fixed the flaky timing test by measuring from the report instead of the first delivery.","t":1761512345.5,"q":"fix the flaky push test on macOS","pj":"clotho","tb":"clothod","w":"clotho","wid":3,"d":254,"pad":"                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         "}"#;
    /// FULL sealed to PK (by clothod), for iOS to open with SK: a record with every detail.
    const CT_FULL: &str = "9opST3exXumrNqA5EzaDfCCQ9hFt7c7zvTyHThUFERC6Kn83TrqqibBRtQNa8KRf099Jr7nhaROwZffD9uF+qo6UJCfwZhRDvO+QuviILs0sXV4Pji5/+eAOaY00QI815TXpoRArqH9p65gJLiyU8O6Eytrcv9ePw9Cowfe9q1yF7JH04hkOIKq28Io+/2gpqRCP8RQWgvZ3I5wUXcuSTZqWCcW4iytVi7DywhrtnCythnT0l0+FR3760cnU9HdWgdIoqMurYiy9uDitrHsQaUrgOydHHTWV85qNrtp8oXkO0JmNCusqFMVad1LUZo600b8bPVprDdVlSiKx5rbfT30a7Gq7OJo67ZIas0kLOBas8j1PrmiqLMS8G1GKcB+9SyvIXXEGCGCK6OO4gptSgKAw5ZOhibTRLRZDGVzC/9EPRpz65k/JWhny9M2Ig1qpS77gu6QKcfW+AlT/PXaI3zL1k/pPnfCvSQL9KAGasKxRxWzEDpal7dhS3ieSbBL1FiDjxS8/Q8dYAMJa3Hg2r5C33GlISrXUiWqJzvah0+bxxUjGJMh0OxDRklZ6REPvsKkVqIcefWYRGRcz6T4763gsTqKU59fzZoXp5tTbzDbYM6nc6+YYdp1MPcsYqTu+HgmGW7R4Nbs6mNVSAsgMfDYydOmxFqVegPIZRDfjNoRxtgr0Y6LfBWEF3yOYbnqnFniimqyu4NzbkWqWOKw1d3HCT0sSPr9cP+TjNaCPXiPToFBHlDPhsvxUL1NioavtIl7P3V7xPxCE7eDlcwFmoHtmvHrhpA93TD60Q/TSFHu9rl6rhIIkR+fBw4pujQTtGd0/laDNZy/CLGznF9RNCaUKjN5FBanTsgf6F20J11d9EC+7G5AtOxQvop2OewGHr3+op+8v3XPMWyjhXmoQQvwA28nvajzAb4oNGd6BlreiTnu3pL2tawxRfUcej55eEty+gp++VeNeRsMDkmSfLSujmV1WffdHUtpPnYqO7w7iUC9MKs0ehUgwL5Q9bEE5YbgJkMj4KUqe3WfkLY5TWlp08cgp/im8PuZq1LRQqeOnCbTCC8WhlWBfSu468Y676YwSwDTm0xfAXoh3S4smP23Xbe4rUDInYOhqDh5pouO87OMpsuqdV8Y4NI/XUQecqZGO57Vph73tu8cnMna3Ksc3YjrO6zzb9q8enECHJkk0Mc4PGm/42ls/spaGUM9hAK4g8WgBNv6jAkZjhE8/TaHKBk9v7mjidjyC6CXZUn7ADexHvXs0Vef4DtnYLc9W5jWMXEGyKemOY0L8F2EABANJ9ObX485dYLxV7Dq5frE+MPAJR0nEZtmYH1I8Gae5bCL13DBpowzsLjvC0H6hMmRczdaX6IzjI1nX4Jc/qojn7crBf7K2KgSUJjBf3ZKqqsHK0AM/l2cmQ+VFtmBrEQ==";
    const PLAIN: &str = r#"{"v":1,"m":"00000000-0000-0000-0000-00000000C10D devbox","p":7,"k":"claude","s":"waiting","msg":"Allow cargo test --release?","t":1761512345.5}"#;

    fn alert() -> Alert {
        Alert::basic("claude", "waiting", Some("Allow cargo test --release?".into()), 1761512345.5)
    }

    #[test]
    fn matches_the_ios_vector() {
        assert_eq!(collapse_id(LABEL, 7), "2d85134107d287e04043e26b56beefb2");
        // Ours is PLAIN padded. CT is PLAIN unpadded, sealed by clothod; CT_IOS is PLAIN
        // unpadded, sealed by iOS.
        let ours = String::from_utf8(plaintext(LABEL, 7, &alert())).unwrap();
        assert_eq!(ours, PADDED);
        assert_eq!(ours.len(), PAD_TO);
        assert_eq!(open(SK, CT_PADDED, collapse_id(LABEL, 7).as_bytes()).unwrap(), PADDED.as_bytes(), "the padded vector for iOS");
        let opened = open(SK, CT, collapse_id(LABEL, 7).as_bytes()).expect("opens the Rust-sealed unpadded ciphertext");
        assert_eq!(String::from_utf8(opened).unwrap(), PLAIN);
        let opened = open(SK, CT_IOS, collapse_id(LABEL, 7).as_bytes()).expect("opens the iOS-sealed (CryptoKit) ciphertext");
        assert_eq!(opened, PLAIN.as_bytes(), "the iOS-sealed vector opens to PLAIN byte for byte");
        assert!(open(SK, CT_IOS, b"another pane").is_none(), "aad binds the collapse id on the iOS-sealed vector too");
        let ours = seal(PK, PLAIN.as_bytes(), collapse_id(LABEL, 7).as_bytes()).unwrap();
        assert_eq!(open(SK, &ours, collapse_id(LABEL, 7).as_bytes()).unwrap(), PLAIN.as_bytes());
        assert!(open(SK, &ours, b"another pane").is_none(), "aad binds the collapse id");
    }

    #[test]
    fn long_messages_are_cut_on_a_char_boundary() {
        let a = Alert { message: Some("é".repeat(300)), ..alert() };
        let v: Value = serde_json::from_slice(&plaintext(LABEL, 1, &a)).unwrap();
        let msg = v["msg"].as_str().unwrap();
        assert!(msg.len() <= MAX_MSG && msg.len() >= MAX_MSG - 1, "{}", msg.len());
    }

    /// A done alert with every detail, as a real Claude turn produces it.
    fn full() -> Alert {
        Alert {
            kind: "claude".into(),
            state: "done".into(),
            message: Some("All 61 tests pass. I fixed the flaky timing test by measuring from the report instead of the first delivery.".into()),
            since: 1761512345.5,
            prompt: Some("fix the flaky push test on macOS".into()),
            tool: None,
            tool_input: None,
            request: None,
            duration: Some(254),
            workspace_id: Some(3),
            workspace: Some("clotho".into()),
            tab: Some("clothod".into()),
            project: Some("clotho".into()),
            summary: None,
        }
    }

    #[test]
    fn the_summary_goes_in_sm_only_when_there_is_one() {
        let v: Value = serde_json::from_slice(&plaintext(LABEL, 7, &full())).unwrap();
        assert!(v.get("sm").is_none(), "{v}");
        let a = Alert { summary: Some("All tests pass. The flaky test is fixed.".into()), ..full() };
        let v: Value = serde_json::from_slice(&plaintext(LABEL, 7, &a)).unwrap();
        assert_eq!(v["sm"], "All tests pass. The flaky test is fixed.");
        assert_eq!(v["msg"], full().message.unwrap(), "msg is kept");
        // Long and escape-heavy everything: the record still fits, and msg is cut before sm.
        let big = |c: &str| Some(c.repeat(2000));
        let a = Alert { message: big("\\"), prompt: big("\\"), tool_input: big("\\"), summary: big("s"), ..full() };
        let raw = plaintext(LABEL, 7, &a);
        assert!(raw.len() <= MAX_RECORD, "{}", raw.len());
        let v: Value = serde_json::from_slice(&raw).unwrap();
        assert_eq!(v["sm"].as_str().unwrap().len(), MAX_SUMMARY, "{v}");
    }

    #[test]
    fn records_carry_the_turns_details() {
        let v: Value = serde_json::from_slice(&plaintext(LABEL, 7, &full())).unwrap();
        for (k, want) in [("q", json!("fix the flaky push test on macOS")), ("d", json!(254)), ("wid", json!(3)), ("w", json!("clotho")), ("tb", json!("clothod")), ("pj", json!("clotho"))] {
            assert_eq!(v[k], want, "{k}");
        }
        assert!(v.get("tool").is_none() && v.get("cmd").is_none(), "absent details are left out: {v}");
        let waiting = Alert { state: "waiting".into(), message: Some("Claude needs your permission to use Bash".into()), tool: Some("Bash".into()), tool_input: Some("npm test".into()), duration: None, ..full() };
        let v: Value = serde_json::from_slice(&plaintext(LABEL, 7, &waiting)).unwrap();
        assert_eq!((v["tool"].clone(), v["cmd"].clone()), (json!("Bash"), json!("npm test")));
        assert!(v.get("d").is_none());
        // A basic alert is byte for byte what older daemons sent (the shared vector).
        assert_eq!(std::str::from_utf8(&plaintext(LABEL, 7, &alert())).unwrap(), PADDED);
    }

    /// Every text at its cap, in 4-byte characters and in characters JSON escapes six-fold:
    /// the record stays within MAX_RECORD (the relay's limit), and texts are cut in order:
    /// a later one is cut only once every earlier one is empty.
    #[test]
    fn full_records_fit_and_cut_the_result_first() {
        for ch in ["\u{1F600}", "\u{1}", "é"] {
            let big = |n: usize| Some(ch.repeat(n));
            let a = Alert { message: big(400), prompt: big(240), tool: big(96), tool_input: big(240), workspace: big(96), tab: big(96), project: big(96), request: Some("f".repeat(16)), ..full() };
            let rec = plaintext(&ch.repeat(100), 7, &a);
            assert!(rec.len() <= MAX_RECORD && rec.len() % PAD_TO == 0, "{ch:?}: {}", rec.len());
            assert!(seal(PK, &rec, b"x").unwrap().len() <= 3000);
            let v: Value = serde_json::from_slice(&rec).unwrap();
            let caps = [("msg", MAX_MSG), ("q", MAX_PROMPT), ("cmd", MAX_TOOL_INPUT), ("pj", MAX_NAME), ("tb", MAX_NAME), ("w", MAX_NAME)];
            let len = |k: &str| v[k].as_str().map_or(0, str::len);
            let full_len = |cap: usize| cap - cap % ch.len();
            for (i, (k, cap)) in caps.iter().enumerate() {
                if len(k) < full_len(*cap) {
                    for (earlier, _) in &caps[..i] {
                        assert_eq!(len(earlier), 0, "{ch:?}: {k} was cut while {earlier} was not empty");
                    }
                }
            }
            if ch == "\u{1}" {
                assert!(len("msg") < full_len(MAX_MSG), "six-fold escapes overflow: the result is cut first");
            }
        }
    }

    /// A permission wait with its request id (`rq`), for iOS's Allow/Deny actions.
    fn permission() -> Alert {
        Alert {
            state: "waiting".into(),
            message: Some("Claude needs your permission to use Bash".into()),
            prompt: Some("run the phone test".into()),
            tool: Some("Bash".into()),
            tool_input: Some("date > /tmp/clotho-phone-test.txt".into()),
            request: Some("87b99bd3910be450".into()),
            duration: None,
            ..full()
        }
    }

    /// The permission vector iOS pins: its notification gets the Allow/Deny category and the
    /// request id from `rq`.
    const PERMISSION: &str = r#"{"v":1,"m":"00000000-0000-0000-0000-00000000C10D devbox","p":7,"k":"claude","s":"waiting","msg":"Claude needs your permission to use Bash","t":1761512345.5,"q":"run the phone test","cmd":"date > /tmp/clotho-phone-test.txt","pj":"clotho","tb":"clothod","w":"clotho","wid":3,"tool":"Bash","rq":"87b99bd3910be450","pad":"                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                "}"#;
    /// PERMISSION sealed to PK by clothod, for iOS to open with SK.
    const CT_PERMISSION: &str = "GO2U6qxLoSfGq56/pQlDPdcXC6pJtnjUBjnruelxeHZxNvOlIk4/0MmiOYevavq8+s2cs7dzeqV9hgTbCYdTX8kgf6TGyhpbHlerT7vzQA3IIDPlh5d3LXSwRYarSZ6UOtL2SGDU+HvMj2k72XpbaHu27shLXVi7mKb8DzC2V3wuEFm8jWKIQLI30k48olIzv46a34pAeOkxBeS3yThDIb6v4s+jlCSw2o9dNBmOmT40O/oU0VS7RPevdnWf39QjHn8HUWzltUCigV4sgN4/V02I1VDqiGNEOfSw3jOZNsv8UUuF+AZwYuxGfWOLex91CTs21kwIHNfEaPcESRLSecqgK4z+NZQuuYB7YL/5q3l0pyui+aF1Z1KzQssEPZopLLgCquQAHvYzEBfUqg2GTRz2qUTc28Z5jimEswO3AGTHz+Nmcx7mnjw7aLqZpUqjXAUYJk9Wsu2m6h6FIQj2sid2XVAtrB7gEK8PDjyWYhi5nIg9z+Kmfv158SOpwJHbRbLPRvSRQ563xKtZ6FULUIpuIBt9b9Deg38L0e/nM81x9RN3aCp4xaMNNKSrFLZ7xlmzomjrUrT0PHiRxoE6rx4h0C6uKJNnfYKvKlxmAUfIWXUuPzdlsPnM9jfh9bxxLhbu9YH1SmIfTD/53gegGSAaankmEiO9cIfB9FXTlEaAviMB6A2zQOQeZn1aZpadviRPgJeIJ/Abv22FhuWtCB4MF/c/Z/d01vOQGLvHqGYIkAqrBJ67UB/KuFde/owadwwZVYNmoMk8P9nt4gbU8Lf/J3g5wYVO2bEv8XregYBMHiVVgAXTb5dfMew/Rh0SFOBsrQwOBdK/lGUfse3DJPrYs95bd+qg2g/TxGjxowK1+tAc+elLeVC/XzW7GHxIfbQA4Hd/VTsbHgOhszt/X/Eq7Gm4+x5FEprXuEkFVSeODNv3CqObv5OChyK2+uLmH73HfbY4s/0C92sZ6UH1VRMpESvNvFkfgkyXR17FpuRa6k25fXrfNPxIWXsmyCGB9L4Q3Hi8vUEkkZd/o+5KjUmg+7qfcNpivTeNWbjVVb4+akgXOwvQ01/qCku4qMXLBbo4pfLlbmscPr9nYVFj4Pvw5W357d163SYTEusThclJtz0tk5nv/qqJQCcXJ8VxU5+pW1/n63L/eC7JUWoRc9b34jfMypWk4W2rL8Fg7mk1/yshIEBKjzZDyxO6HU6AbX9ixrXYGUJjDHVJKPZ95MOssxIbMa7X7B3GRe/wmzUW8GF+WeBTGPdDkCCmt6ugzAci7osqf5M+skfWo9iWbreTQWYSHiJdwKZN3qqORyxzvumONgopxQ8YZH2sINLorneaUrPCplLr9txQ9S23lmYGP74Yocny+AkhWe1X/ylgOBsU0YkW+nLf3h91SVvhduaVBdQaI0iIE4n9K04owQ==";

    #[test]
    fn the_permission_vector_opens() {
        assert_eq!(std::str::from_utf8(&plaintext(LABEL, 7, &permission())).unwrap(), PERMISSION);
        assert_eq!(open(SK, CT_PERMISSION, collapse_id(LABEL, 7).as_bytes()).unwrap(), PERMISSION.as_bytes());
        let v: Value = serde_json::from_str(PERMISSION).unwrap();
        assert_eq!((v["s"].clone(), v["rq"].clone(), v["tool"].clone()), (json!("waiting"), json!("87b99bd3910be450"), json!("Bash")));
    }

    #[test]
    fn live_activity_kinds_fit_the_relay() {
        let kind = |k: &str| Live { kind: k.into(), state: "running".into(), since: 1, started: 1, ..Default::default() }.content()["kind"].as_str().unwrap().to_string();
        assert_eq!(kind("claude"), "claude");
        assert_eq!(kind("Claude Code"), "claude-code");
        assert_eq!(kind("9lives"), "other");
        assert_eq!(kind(""), "other");
        assert_eq!(kind("ünï"), "other");
        assert_eq!(kind(&"a".repeat(40)).len(), 32);
    }

    #[test]
    fn live_activity_detail_fits_the_relay() {
        let live = |tool: Option<&str>, detail: Option<&str>, msg: Option<&str>| {
            Live { kind: "claude".into(), state: "waiting".into(), since: 1, started: 1, tool: tool.map(Into::into), detail: detail.map(Into::into), msg: msg.map(Into::into) }.content()
        };
        // Absent keys are left out: older apps decode the rest.
        let bare = live(None, None, None);
        assert_eq!(bare.as_object().unwrap().len(), 4, "{bare}");
        let c = live(Some("Bash"), Some("npm test\n  && echo ok"), Some("Claude needs\tyour permission"));
        assert_eq!((c["tool"].as_str(), c["detail"].as_str(), c["msg"].as_str()), (Some("Bash"), Some("npm test && echo ok"), Some("Claude needs your permission")));
        // Tools the relay wouldn't take are left out; empty text too.
        assert_eq!(live(Some("mcp__github__create_pr"), None, None)["tool"], "mcp__github__create_pr");
        for t in ["", "two words", "naïve", &"a".repeat(65)] {
            assert!(live(Some(t), None, None).get("tool").is_none(), "{t}");
        }
        assert!(live(None, Some(" \n\t "), Some("")).as_object().unwrap().len() == 4);
        // Line separators go too; caps hold in UTF-8 bytes of the escaped string, ellipsis
        // included, whatever the text.
        assert_eq!(live_text("a\u{2028}b\u{2029}c\u{85}d", 100).as_deref(), Some("a b c d"));
        for text in ["x".repeat(1000), "é".repeat(1000), "🙂".repeat(1000), "\"".repeat(1000), "\\".repeat(1000), format!("a{}", "😀".repeat(500))] {
            let c = live(None, Some(&text), Some(&text));
            for (k, max) in [("detail", LIVE_DETAIL_MAX), ("msg", LIVE_MSG_MAX)] {
                let v = c[k].as_str().unwrap();
                let escaped = serde_json::to_string(v).unwrap().len() - 2;
                assert!(escaped <= max && escaped > max - 8, "{k}: {escaped} bytes");
                assert!(v.ends_with('…') && v.chars().count() <= max && v.encode_utf16().count() <= max);
            }
        }
        assert_eq!(live_text(&"y".repeat(LIVE_MSG_MAX), LIVE_MSG_MAX).unwrap().len(), LIVE_MSG_MAX, "exactly at the cap: kept whole");
        // The worst case stays well inside the relay's content cap.
        let worst = live(Some(&"m".repeat(64)), Some(&"\"".repeat(999)), Some(&"🙂".repeat(999)));
        assert!(worst.to_string().len() < 1024, "{}", worst.to_string().len());
    }

    #[test]
    fn the_full_vector_opens() {
        assert_eq!(std::str::from_utf8(&plaintext(LABEL, 7, &full())).unwrap(), FULL);
        assert_eq!(open(SK, CT_FULL, collapse_id(LABEL, 7).as_bytes()).unwrap(), FULL.as_bytes());
    }

    #[test]
    fn records_are_padded_to_a_fixed_size() {
        let len = |m: Option<&str>| plaintext(LABEL, 3, &Alert { message: m.map(String::from), ..alert() }).len();
        let sizes = [len(None), len(Some("y")), len(Some(&"a".repeat(MAX_MSG))), len(Some(&"\"".repeat(MAX_MSG)))];
        assert_eq!(sizes, [PAD_TO; 4], "every message length looks the same");
        // Escapes six-fold (control characters) in the message and the label: still at most
        // MAX_RECORD, and the relay takes the ciphertext.
        let worst = plaintext(&"\u{1}".repeat(500), 3, &Alert { message: Some("\u{1}".repeat(MAX_MSG)), ..alert() });
        assert_eq!(worst.len(), MAX_RECORD);
        let ct = seal(PK, &worst, b"x").unwrap();
        assert!(ct.len() <= 3000, "{} base64 chars", ct.len());
        assert!(serde_json::from_slice::<Value>(&worst).is_ok());
    }

    /// TLS works in this build (static musl builds bundle their own roots). Needs the network,
    /// so opt in: CLOTHOD_TEST_HTTPS=1.
    #[test]
    fn https_reaches_a_real_server() {
        if std::env::var_os("CLOTHOD_TEST_HTTPS").is_none() {
            return;
        }
        match post("https://example.com", &json!({})) {
            Outcome::Retry(e) if e.starts_with("relay unreachable") => panic!("{e}"),
            _ => {}
        }
    }

    #[test]
    fn relay_urls() {
        for ok in ["https://clotho-push.example.workers.dev", "http://127.0.0.1:8787", "http://localhost:8787/", "http://[::1]:1"] {
            assert!(check_relay(ok).is_ok(), "{ok}");
        }
        for no in ["http://example.com", "http://127.0.0.1.evil.com", "ftp://x", "https://", "http://localhostx:1"] {
            assert!(check_relay(no).is_err(), "{no}");
        }
    }
}
