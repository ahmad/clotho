// The push relay (docs/push.md): turns a push handle and an end-to-end encrypted payload into an APNs
// notification. It keeps no state: the APNs token travels sealed inside the handle, and the payload is
// ciphertext only the phone can open.
//
// Environment (Worker secrets and vars):
//   APNS_KEY        the .p8 file's contents (PEM, PKCS#8 P-256)
//   APNS_KEY_ID     the key's 10-character id
//   APNS_TEAM_ID    the developer team id
//   APNS_TOPIC      the app's bundle id
//   HANDLE_KEYS     JSON {"<id 1-255>": "<base64 32-byte AES key>", ...}; old ids keep old handles working
//   HANDLE_KEY_ID   the id new handles are sealed with
//   RATE_LIMITER    optional Workers rate-limiting binding, keyed per handle

const enc = new TextEncoder();
const dec = new TextDecoder();
const HANDLE_AAD = enc.encode("clotho handle v1");
const JWT_LIFETIME_MS = 40 * 60 * 1000;
const MAX_CIPHERTEXT = 3000;

export function b64url(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function unb64url(text) {
  const s = atob(text.replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
}

function unb64(text) {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}

function json(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

const keyCache = new Map();
async function handleKey(env, id) {
  const raw = JSON.parse(env.HANDLE_KEYS || "{}")[String(id)];
  if (!raw) return null;
  if (!keyCache.has(raw)) {
    keyCache.set(raw, await crypto.subtle.importKey("raw", unb64(raw), "AES-GCM", false, ["encrypt", "decrypt"]));
  }
  return keyCache.get(raw);
}

/// handle = base64url(key id (1 byte) || nonce (12) || AES-GCM({t, e, c}))
export async function sealHandle(env, token, apnsEnv, now) {
  const id = Number(env.HANDLE_KEY_ID);
  const key = await handleKey(env, id);
  if (!key) throw new Error("HANDLE_KEY_ID has no key in HANDLE_KEYS");
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const body = enc.encode(JSON.stringify({ t: token, e: apnsEnv, c: Math.floor(now / 1000) }));
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: HANDLE_AAD }, key, body));
  const out = new Uint8Array(13 + sealed.length);
  out[0] = id;
  out.set(nonce, 1);
  out.set(sealed, 13);
  return b64url(out);
}

export async function openHandle(env, handle) {
  try {
    const bytes = unb64url(handle);
    if (bytes.length < 13 + 16) return null;
    const key = await handleKey(env, bytes[0]);
    if (!key) return null;
    const plain = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: bytes.slice(1, 13), additionalData: HANDLE_AAD }, key, bytes.slice(13));
    const { t, e } = JSON.parse(dec.decode(plain));
    return { token: t, env: e };
  } catch {
    return null;
  }
}

let jwtCache = null;
async function providerToken(env, now) {
  if (jwtCache && jwtCache.source === env.APNS_KEY && now - jwtCache.at < JWT_LIFETIME_MS) return jwtCache.jwt;
  const pem = env.APNS_KEY.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const key = await crypto.subtle.importKey("pkcs8", unb64(pem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = b64url(enc.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = b64url(enc.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(now / 1000) })));
  const input = `${header}.${claims}`;
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(input)));
  const jwt = `${input}.${b64url(sig)}`;
  jwtCache = { jwt, at: now, source: env.APNS_KEY };
  return jwt;
}

/// The notification as APNs gets it. The generic text shows only if the extension can't decrypt.
export function apnsPayload(ciphertext, collapseID) {
  return {
    aps: {
      alert: { title: "Clotho", body: "An agent needs you" },
      "mutable-content": 1,
      sound: "default",
      "thread-id": collapseID,
    },
    e: ciphertext,
  };
}

const TOKEN = /^[0-9a-fA-F]{64,200}$/;
const COLLAPSE = /^[0-9a-f]{32}$/;
const CIPHERTEXT = /^[A-Za-z0-9+/]+={0,2}$/;

async function readJSON(request) {
  try {
    const body = await request.json();
    return body && typeof body === "object" ? body : null;
  } catch {
    return null;
  }
}

/// `deliver(env, {token, env, payload, collapseID})` sends one notification and returns APNs's
/// response; the Worker passes `apnsDeliver`, tests and the local dev server pass their own.
export async function handle(request, env, { deliver = apnsDeliver, now = Date.now() } = {}) {
  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/v1/health") return json(200, { ok: true });
  if (request.method !== "POST") return json(404, { error: "not_found" });

  if (url.pathname === "/v1/register") {
    const body = await readJSON(request);
    if (!body || !TOKEN.test(body.token ?? "") || !["sandbox", "production"].includes(body.env)) {
      return json(400, { error: "bad_request" });
    }
    return json(200, { handle: await sealHandle(env, body.token.toLowerCase(), body.env, now) });
  }

  if (url.pathname === "/v1/push") {
    const body = await readJSON(request);
    if (!body || typeof body.handle !== "string" || !COLLAPSE.test(body.collapse_id ?? "")
        || typeof body.ciphertext !== "string" || body.ciphertext.length > MAX_CIPHERTEXT
        || !CIPHERTEXT.test(body.ciphertext)) {
      return json(400, { error: "bad_request" });
    }
    const target = await openHandle(env, body.handle);
    if (!target) return json(403, { error: "bad_handle" });
    if (env.RATE_LIMITER) {
      const { success } = await env.RATE_LIMITER.limit({ key: body.handle.slice(0, 64) });
      if (!success) return json(429, { error: "rate_limited" });
    }
    const res = await deliver(env, { ...target, payload: apnsPayload(body.ciphertext, body.collapse_id), collapseID: body.collapse_id, now });
    if (res.status === 200) return json(200, {});
    const reason = res.reason ?? "";
    if (res.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered" || reason === "DeviceTokenNotForTopic") {
      return json(410, { error: "unregistered", reason });
    }
    if (res.status === 429) return json(429, { error: "rate_limited", reason });
    return json(502, { error: "apns", status: res.status, reason });
  }

  if (url.pathname === "/v1/activity") {
    const body = await readJSON(request);
    const req = body && activityRequest(body);
    if (!req) return json(400, { error: "bad_request" });
    const target = await openHandle(env, body.handle);
    if (!target) return json(403, { error: "bad_handle" });
    // Updates share a per-handle burst limit; an end always goes through, so an activity can always close.
    if (req.event === "update" && env.ACTIVITY_LIMITER) {
      const { success } = await env.ACTIVITY_LIMITER.limit({ key: body.handle.slice(0, 64) });
      if (!success) return json(429, { error: "rate_limited" });
    }
    const res = await deliver(env, {
      token: req.token, env: req.env ?? target.env, payload: activityPayload(req, now), now,
      pushType: "liveactivity", topic: `${env.APNS_TOPIC}.push-type.liveactivity`,
      priority: req.event === "end" ? "10" : "5",
    });
    if (res.status === 200) return json(200, {});
    const reason = res.reason ?? "";
    if (res.status === 410 || ["BadDeviceToken", "Unregistered", "ExpiredToken", "DeviceTokenNotForTopic"].includes(reason)) {
      return json(410, { error: "unregistered", reason });
    }
    if (res.status === 429) return json(429, { error: "rate_limited", reason });
    return json(502, { error: "apns", status: res.status, reason });
  }

  return json(404, { error: "not_found" });
}

const WORD = /^[a-z][a-z0-9_-]{0,31}$/;
const isTime = (n) => Number.isInteger(n) && n > 0 && n < 1e10;

/// A Live Activity request, checked strictly: the content is the agent's state and kind and two times,
/// nothing else, so no text from a terminal or an agent can ride along (APNs sees Live Activity content
/// in the clear). Null if anything is off.
export function activityRequest(body) {
  const { handle, token, env, event, content, timestamp, stale, dismiss } = body;
  if (typeof handle !== "string" || !TOKEN.test(token ?? "")) return null;
  if (env !== undefined && !["sandbox", "production"].includes(env)) return null;
  if (!["update", "end"].includes(event) || !isTime(timestamp)) return null;
  if (!content || typeof content !== "object" || Array.isArray(content)) return null;
  const keys = Object.keys(content).sort().join(",");
  if (keys !== "kind,since,started,state") return null;
  if (!WORD.test(content.state) || !WORD.test(content.kind) || !isTime(content.since) || !isTime(content.started)) return null;
  if (stale !== undefined && !isTime(stale)) return null;
  if (dismiss !== undefined && !isTime(dismiss)) return null;
  return { token: token.toLowerCase(), env, event, content, timestamp, stale, dismiss };
}

/// The aps body of a Live Activity update or end (ActivityKit's push format).
export function activityPayload(req, now) {
  const aps = {
    timestamp: req.timestamp ?? Math.floor(now / 1000),
    event: req.event,
    "content-state": { state: req.content.state, kind: req.content.kind, since: req.content.since, started: req.content.started },
  };
  if (req.stale !== undefined) aps["stale-date"] = req.stale;
  if (req.event === "end" && req.dismiss !== undefined) aps["dismissal-date"] = req.dismiss;
  return { aps };
}

export async function apnsDeliver(env, { token, env: apnsEnv, payload, collapseID, now, pushType = "alert", topic, priority = "10" }) {
  const host = apnsEnv === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const headers = {
    authorization: `bearer ${await providerToken(env, now)}`,
    "apns-topic": topic ?? env.APNS_TOPIC,
    "apns-push-type": pushType,
    "apns-priority": priority,
    // A "needs you", or a Live Activity's state, that can't arrive within the hour isn't worth showing.
    "apns-expiration": String(Math.floor(now / 1000) + 3600),
  };
  if (collapseID) headers["apns-collapse-id"] = collapseID;
  const res = await fetch(`https://${host}/3/device/${token}`, { method: "POST", headers, body: JSON.stringify(payload) });
  let reason;
  if (res.status !== 200) {
    try { reason = (await res.json()).reason; } catch { reason = undefined; }
  }
  return { status: res.status, reason };
}
