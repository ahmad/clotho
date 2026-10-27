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
    backoff: Duration,
    backoff_max: Duration,
    give_up: Duration,
}

fn timing() -> Timing {
    if std::env::var_os("CLOTHOD_TEST_PUSH_FAST").is_some() {
        let ms = Duration::from_millis;
        return Timing { per_pane: ms(1000), backoff: ms(100), backoff_max: ms(400), give_up: ms(3000) };
    }
    let s = Duration::from_secs;
    Timing { per_pane: s(30), backoff: s(2), backoff_max: s(60), give_up: s(600) }
}

pub struct Error {
    pub code: &'static str,
    pub message: String,
}

fn bad(message: impl Into<String>) -> Error {
    Error { code: "bad_request", message: message.into() }
}

/// What a pane's agent says when it asks for the user.
#[derive(Clone)]
pub struct Alert {
    pub kind: String,
    pub state: String,
    pub message: Option<String>,
    pub since: f64,
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
    alert: Option<Alert>,
}

#[derive(Default)]
struct Inner {
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

/// The record a phone decrypts: `{"v":1, "m", "p", "k", "s", "msg", "t"}`.
fn plaintext(label: &str, pane: u64, a: &Alert) -> Vec<u8> {
    let msg = a.message.as_deref().map(|m| {
        let mut end = m.len().min(MAX_MSG);
        while !m.is_char_boundary(end) {
            end -= 1;
        }
        &m[..end]
    });
    let mut v = json!({"v": 1, "m": label, "p": pane, "k": a.kind, "s": a.state, "msg": msg, "t": a.since});
    // Padded to a multiple of PAD_TO bytes with a `pad` of spaces, so the ciphertext's length
    // (which the relay and APNs see) doesn't tell how long the message is.
    let len = serde_json::to_vec(&v).unwrap().len() + r#","pad":"""#.len();
    v["pad"] = json!(" ".repeat(len.div_ceil(PAD_TO) * PAD_TO - len));
    serde_json::to_vec(&v).unwrap()
}

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
    let url = format!("{}/v1/push", relay.trim_end_matches('/'));
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
    pub fn load(dir: &Path) -> Arc<Push> {
        let path = dir.join("push.json");
        let regs = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Arc::new(Push { path, inner: Mutex::new(Inner { regs, ..Default::default() }) })
    }

    fn save(&self, regs: &[Reg]) {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        if let Some(dir) = self.path.parent() {
            let _ = clotho_proto::platform::ensure_private_dir(dir);
        }
        let tmp = self.path.with_extension("tmp");
        let _ = std::fs::remove_file(&tmp);
        let ok = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)
            .and_then(|mut f| f.write_all(&serde_json::to_vec_pretty(regs).unwrap()));
        if ok.is_ok() {
            let _ = std::fs::rename(&tmp, &self.path);
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
                Ok(json!({}))
            }
            "push.list" => {
                let g = self.inner.lock().unwrap();
                let devices: Vec<Value> = g
                    .regs
                    .iter()
                    .map(|r| json!({"device": r.device, "label": r.label, "relay": r.relay, "env": r.env, "created": r.created, "last_error": r.last_error}))
                    .collect();
                Ok(json!({"devices": devices}))
            }
            "push.test" => {
                let device = s("device").ok_or_else(|| bad("missing device"))?;
                let reg = self.inner.lock().unwrap().regs.iter().find(|r| r.device == device).cloned();
                let reg = reg.ok_or_else(|| Error { code: "not_found", message: format!("no registration for device {device}") })?;
                let alert = Alert { kind: "clotho".into(), state: "done".into(), message: Some("Test alert".into()), since: unix_now() };
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
    pub fn attention(self: &Arc<Self>, pane: u64, on: bool, alert: Option<Alert>) {
        let t = timing();
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
        let wait = ps.last_sent.map(|at| (at + t.per_pane).saturating_duration_since(Instant::now())).unwrap_or_default();
        if wait.is_zero() {
            self.dispatch(&mut g, pane);
        } else if !ps.delayed {
            ps.delayed = true;
            let me = self.clone();
            tokio::spawn(async move {
                tokio::time::sleep(wait).await;
                let mut g = me.inner.lock().unwrap();
                let Some(ps) = g.panes.get_mut(&pane) else { return };
                ps.delayed = false;
                if ps.attention {
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

    // The vector shared with the iOS side (ClothoTests/PushTests).
    const SK: &str = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=";
    const PK: &str = "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=";
    const LABEL: &str = "00000000-0000-0000-0000-00000000C10D devbox";
    const CT: &str = "jmHxxNQXj2wm3geR2KiLzXdhyo1/9E1jusxEmNVobigz4a+nHrN7MWYh8vvydxOmkSaESvX70WVLehRpiZb+pr9SJQPvKyhGm4Ym2ZXUGzUh5CrZVaVjnxOAIeuxPWOn8cGaelb1KkT8UR18z+Q4otc5PJLweY7a6nZmQ8ih8y9x35WLjHMHBQvaRUSZTr1K2uWBauhUmNsmQX6G2HcBf3XFG+sNQEyXVfJUlMJw0/+rp4gtYszv3tIXRNHrKpk=";
    /// PLAIN as clothod sends it since 0.1.11: padded to 1024 bytes.
    const PADDED: &str = r#"{"v":1,"m":"00000000-0000-0000-0000-00000000C10D devbox","p":7,"k":"claude","s":"waiting","msg":"Allow cargo test --release?","t":1761512345.5,"pad":"                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        "}"#;
    /// PADDED sealed to PK (by clothod), for iOS to open with SK.
    const CT_PADDED: &str = "waIuQwmR41aqP/FeDl6qcxO3VMlzn9JWMLLSVBBno3RoZ6H0WMBF+pB381kmx09JSwR0LKdoo1tQiL82E1SUpXiSbNRqF/I2TLdju9z5NN3Tcjo28n1MRYN8N54znoR81MryHYIWWw/enTmy3dld+zdiULd8YS8ZWuh/Yzv82zWvJRRoOMF2gHElBCt9BxNEXA3vxxlgM8dxksJx8uKZGql7nXKBsBVjnkUjSm/5JnzaHW89fhAbpaKXUXLP5TwGJ8N6d1k0yO/ikMJgQOJ3cMSkygWVIOLJFtuQ/hPDEj7vJSzVcud/zb+wZlbVJxjl1eSr+t4x9ESxBWnwy13o3zdDhwiHkbXlVYpCbaNtFjTmvSRf27nGoPEPCEIMskcnciNhc1aRrE1oEg9gHO2AbWuTD3qBOazA3YMGXPkgljx3JMSdjPA0mKoascgEZzt6x1aITqdnu4dNhTaDtgN8qpyZi+bDaSvXRpY5vRm14T9izWayls3wHDa2VWBVXSiKTbge3gYoKIBtTMnNEPYQ/hM3ibv0u8eIXRpdvTNljP9+WOPSb2y0dMcK7ZgnCMZ7CqJbM+Bk0rXye+WiuM+vQGe4E1grJMo7Ot7NtW+oWSadm8s+QeGELUhwk9Ol1zkbswNWON1mSCcFh3XnAyZzegzd1lqMCIBL57bnxm/trSrpPOQNICHjvQhd91H0A20XSXMQWOfVP6m8O0AMa9fwLM3GzWJhlZJhysvmRlZjHtV/gsq1/rqnMOGGj6GlWYDZ1ye59wBkwOPfJmOrTjQVgnrIi4GG7WhlKd2o4Ushvh3Bml7+S1uJq2b+DymcOydvSsqYRmG7N7vSvd+VsgeSbdn7DQ2nwY100B99kosRiOeID6wmQml+OIP6YJsSSrLgBtF+zwvWD4NMGg+DLCFeCusFQZE9JVbEPDATWHe4FGVXfKrR2uzK6Hhj3QSUOJzAOUdPKYIs+aDYgrqC3FRZtZdwFUFORxp9kfG4uhF3fVqXFCxM4PQMQv5PtuGzkrYvIxASp1+ZmIBWUB03C5R3HJ7IU/HE0IViOzJmSv3XpSmbf2S+fF+yZv1Jv8OJbtzF7n+0mKzM5tbXNVOlEI1ie7nC1zExWoVjE/XYOzaMToo10qzrW0PRf5VBRMX0i2rOZTHyJE9KTCHDoy/0DqfewdGX/HbB16P+yzY9r50J9fcR3YyPOPba/qtMEVs/Ovskng9U+br7THXQ17gr3x86oQRcDwzfv0ws/g+VgmNANpL72ra6TewLGmYWOiyam7jHJrfcY5V17E7Tdm4pqpLadui7ua6GShgm6c4iR/ppy80CJOYYnFfxqeZczor6O5Rear0J9C/ul1NCYeONaGOzZtq8xf4t3QrMmxhO5/4rPvwOBwUsqqf1apYuBAN3NNF1I36qfakZ6JlKqOg2O587HA==";
    const PLAIN: &str = r#"{"v":1,"m":"00000000-0000-0000-0000-00000000C10D devbox","p":7,"k":"claude","s":"waiting","msg":"Allow cargo test --release?","t":1761512345.5}"#;

    fn alert() -> Alert {
        Alert { kind: "claude".into(), state: "waiting".into(), message: Some("Allow cargo test --release?".into()), since: 1761512345.5 }
    }

    #[test]
    fn matches_the_ios_vector() {
        assert_eq!(collapse_id(LABEL, 7), "c1b5d6191cb70ab41a81baa4c6158682");
        // Ours is PLAIN padded; the iOS ciphertext (unpadded, as iOS produced it) still opens.
        let ours = String::from_utf8(plaintext(LABEL, 7, &alert())).unwrap();
        assert_eq!(ours, PADDED);
        assert_eq!(ours.len(), PAD_TO);
        assert_eq!(open(SK, CT_PADDED, collapse_id(LABEL, 7).as_bytes()).unwrap(), PADDED.as_bytes(), "the padded vector for iOS");
        let opened = open(SK, CT, collapse_id(LABEL, 7).as_bytes()).expect("opens the iOS ciphertext");
        assert_eq!(String::from_utf8(opened).unwrap(), PLAIN);
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

    #[test]
    #[test]
    fn records_are_padded_to_a_fixed_size() {
        let len = |m: Option<&str>| plaintext(LABEL, 3, &Alert { message: m.map(String::from), ..alert() }).len();
        let sizes = [len(None), len(Some("y")), len(Some(&"a".repeat(MAX_MSG))), len(Some(&"\"".repeat(MAX_MSG)))];
        assert_eq!(sizes, [PAD_TO; 4], "every message length looks the same");
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
