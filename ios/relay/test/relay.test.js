// node --test relay/test
import assert from "node:assert/strict";
import { test } from "node:test";
import { activityRequest, apnsDeliver, handle, openHandle, unb64url } from "../src/relay.js";

const keyPair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const pkcs8 = Buffer.from(await crypto.subtle.exportKey("pkcs8", keyPair.privateKey)).toString("base64");
const ENV = {
  APNS_KEY: `-----BEGIN PRIVATE KEY-----\n${pkcs8.match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----\n`,
  APNS_KEY_ID: "ABC123DEFG",
  APNS_TEAM_ID: "TEAMID0000",
  APNS_TOPIC: "nyc.amin.clotho",
  HANDLE_KEYS: JSON.stringify({ 1: Buffer.alloc(32, 7).toString("base64"), 2: Buffer.alloc(32, 9).toString("base64") }),
  HANDLE_KEY_ID: "2",
};
const TOKEN = "ab".repeat(32);
const COLLAPSE = "0123456789abcdef0123456789abcdef";

function post(path, body) {
  return new Request(`https://relay.test${path}`, { method: "POST", body: typeof body === "string" ? body : JSON.stringify(body) });
}

async function register(env = ENV) {
  const res = await handle(post("/v1/register", { token: TOKEN.toUpperCase(), env: "sandbox" }), env);
  assert.equal(res.status, 200);
  return (await res.json()).handle;
}

test("register seals the token into a handle only the relay opens", async () => {
  const h = await register();
  assert.equal(unb64url(h)[0], 2, "sealed with the current key id");
  assert.ok(!h.includes(TOKEN));
  assert.deepEqual(await openHandle(ENV, h), { token: TOKEN, env: "sandbox" });
  // An old key id still opens; an unknown one doesn't.
  const old = await register({ ...ENV, HANDLE_KEY_ID: "1" });
  assert.deepEqual(await openHandle(ENV, old), { token: TOKEN, env: "sandbox" });
  assert.equal(await openHandle({ ...ENV, HANDLE_KEYS: JSON.stringify({ 2: JSON.parse(ENV.HANDLE_KEYS)[2] }) }, old), null);
});

test("register rejects bad input", async () => {
  for (const body of [{ token: "xyz", env: "sandbox" }, { token: TOKEN, env: "prod" }, {}, "not json"]) {
    assert.equal((await handle(post("/v1/register", body), ENV)).status, 400);
  }
});

test("push delivers the ciphertext to the sealed token", async () => {
  const h = await register();
  const sent = [];
  const res = await handle(post("/v1/push", { handle: h, ciphertext: "AAEC/w==", collapse_id: COLLAPSE }), ENV, {
    deliver: async (_env, msg) => { sent.push(msg); return { status: 200 }; },
  });
  assert.equal(res.status, 200);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].token, TOKEN);
  assert.equal(sent[0].env, "sandbox");
  assert.equal(sent[0].collapseID, COLLAPSE);
  assert.deepEqual(sent[0].payload, {
    aps: { alert: { title: "Clotho", body: "An agent needs you" }, "mutable-content": 1, sound: "default", "thread-id": COLLAPSE },
    e: "AAEC/w==",
  });
});

test("push rejects tampered handles and bad bodies", async () => {
  const h = await register();
  const bytes = unb64url(h);
  bytes[20] ^= 1;
  const tampered = Buffer.from(bytes).toString("base64url");
  const deliver = async () => assert.fail("must not deliver");
  assert.equal((await handle(post("/v1/push", { handle: tampered, ciphertext: "AA==", collapse_id: COLLAPSE }), ENV, { deliver })).status, 403);
  assert.equal((await handle(post("/v1/push", { handle: "nope", ciphertext: "AA==", collapse_id: COLLAPSE }), ENV, { deliver })).status, 403);
  assert.equal((await handle(post("/v1/push", { handle: h, ciphertext: "AA==", collapse_id: "x" }), ENV, { deliver })).status, 400);
  assert.equal((await handle(post("/v1/push", { handle: h, ciphertext: "A".repeat(3004), collapse_id: COLLAPSE }), ENV, { deliver })).status, 400);
  assert.equal((await handle(post("/v1/push", { handle: h, ciphertext: "<script>", collapse_id: COLLAPSE }), ENV, { deliver })).status, 400);
});

test("APNs answers map to what clothod acts on", async () => {
  const h = await register();
  const cases = [
    [{ status: 410, reason: "Unregistered" }, 410],
    [{ status: 400, reason: "BadDeviceToken" }, 410],
    [{ status: 429, reason: "TooManyRequests" }, 429],
    [{ status: 500, reason: "InternalServerError" }, 502],
    [{ status: 403, reason: "InvalidProviderToken" }, 502],
  ];
  for (const [apns, expected] of cases) {
    const res = await handle(post("/v1/push", { handle: h, ciphertext: "AA==", collapse_id: COLLAPSE }), ENV, { deliver: async () => apns });
    assert.equal(res.status, expected, JSON.stringify(apns));
  }
});

test("the rate limiter turns pushes away with 429", async () => {
  const h = await register();
  const env = { ...ENV, RATE_LIMITER: { limit: async () => ({ success: false }) } };
  const res = await handle(post("/v1/push", { handle: h, ciphertext: "AA==", collapse_id: COLLAPSE }), env, {
    deliver: async () => assert.fail("must not deliver"),
  });
  assert.equal(res.status, 429);
});

test("apnsDeliver sends a valid ES256 provider token and the APNs headers", async (t) => {
  let seen;
  t.mock.method(globalThis, "fetch", async (url, init) => { seen = { url, init }; return new Response("", { status: 200 }); });
  const now = 1761512345000;
  const res = await apnsDeliver(ENV, { token: TOKEN, env: "production", payload: { aps: {} }, collapseID: COLLAPSE, now });
  assert.equal(res.status, 200);
  assert.equal(seen.url, `https://api.push.apple.com/3/device/${TOKEN}`);
  const h = seen.init.headers;
  assert.equal(h["apns-topic"], "nyc.amin.clotho");
  assert.equal(h["apns-push-type"], "alert");
  assert.equal(h["apns-collapse-id"], COLLAPSE);
  assert.equal(h["apns-expiration"], String(now / 1000 + 3600));
  const [header, claims, sig] = h.authorization.replace("bearer ", "").split(".");
  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url")), { alg: "ES256", kid: "ABC123DEFG" });
  assert.deepEqual(JSON.parse(Buffer.from(claims, "base64url")), { iss: "TEAMID0000", iat: now / 1000 });
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, keyPair.publicKey,
    Buffer.from(sig, "base64url"), new TextEncoder().encode(`${header}.${claims}`));
  assert.ok(ok, "signature verifies with the key's public half");
});

// Live Activities (docs/ios-redesign.md, phase 6).
const ACTIVITY_TOKEN = "cd".repeat(80);
function activity(h, extra = {}) {
  return {
    handle: h, token: ACTIVITY_TOKEN, event: "update", timestamp: 1761512345,
    content: { state: "running", kind: "claude", since: 1761512300, started: 1761512200 }, stale: 1761513245, ...extra,
  };
}

test("an activity update goes to the activity's token as a liveactivity push", async () => {
  const h = await register();
  let sent;
  const res = await handle(post("/v1/activity", activity(h)), ENV, { deliver: async (_, msg) => { sent = msg; return { status: 200 }; } });
  assert.equal(res.status, 200);
  assert.equal(sent.token, ACTIVITY_TOKEN);
  assert.equal(sent.env, "sandbox", "the handle's environment when none is given");
  assert.equal(sent.pushType, "liveactivity");
  assert.equal(sent.topic, "nyc.amin.clotho.push-type.liveactivity");
  assert.equal(sent.priority, "5");
  assert.deepEqual(sent.payload, { aps: {
    timestamp: 1761512345, event: "update", "stale-date": 1761513245,
    "content-state": { state: "running", kind: "claude", since: 1761512300, started: 1761512200 },
  } });
});

test("an activity end is high priority and carries its dismissal date", async () => {
  const h = await register();
  let sent;
  const body = activity(h, { event: "end", dismiss: 1761512645, content: { state: "done", kind: "claude", since: 1761512340, started: 1761512200 } });
  const env = { ...ENV, ACTIVITY_LIMITER: { limit: async () => ({ success: false }) } };
  const res = await handle(post("/v1/activity", body), env, { deliver: async (_, msg) => { sent = msg; return { status: 200 }; } });
  assert.equal(res.status, 200, "an end isn't rate limited");
  assert.equal(sent.priority, "10");
  assert.equal(sent.payload.aps.event, "end");
  assert.equal(sent.payload.aps["dismissal-date"], 1761512645);
});

test("activity content takes no unknown keys or malformed fields", async () => {
  const h = await register();
  const deliver = async () => assert.fail("must not deliver");
  const bad = [
    activity(h, { content: { state: "running", kind: "claude", since: 1, started: 1, message: "rm -rf /" } }),
    activity(h, { content: { state: "Allow rm -rf build?", kind: "claude", since: 1, started: 1 } }),
    activity(h, { content: { state: "running", kind: "claude", since: "now", started: 1 } }),
    activity(h, { event: "start" }),
    activity(h, { token: "not hex" }),
    activity(h, { timestamp: 1.5 }),
    activity(h, { env: "staging" }),
  ];
  for (const body of bad) {
    const res = await handle(post("/v1/activity", body), ENV, { deliver });
    assert.equal(res.status, 400, JSON.stringify(body.content ?? body));
  }
  const tampered = await handle(post("/v1/activity", activity(h.slice(0, -4) + "AAAA")), ENV, { deliver });
  assert.equal(tampered.status, 403);
});

test("activity content passes the tool, detail and message through unchanged", async () => {
  const h = await register();
  let sent;
  const content = { state: "waiting", kind: "claude", since: 1761512300, started: 1761512200, tool: "Bash",
                    detail: "rm -rf build — ünïcødé 🚀", msg: "Claude needs your permission to use Bash" };
  const res = await handle(post("/v1/activity", activity(h, { content })), ENV, { deliver: async (_, msg) => { sent = msg; return { status: 200 }; } });
  assert.equal(res.status, 200);
  assert.deepEqual(sent.payload.aps["content-state"], content);
  // At the caps, counted in Unicode scalars: 300 emoji are 600 UTF-16 units but pass.
  const full = { ...content, tool: "mcp__github__create_pull_request_" + "t".repeat(29), detail: "d".repeat(200), msg: "🚀".repeat(300) };
  assert.equal((await handle(post("/v1/activity", activity(h, { content: full })), ENV, { deliver: async () => ({ status: 200 }) })).status, 200);
});

test("activity text is capped, one line, and only under known keys", async () => {
  const h = await register();
  const deliver = async () => assert.fail("must not deliver");
  const base = { state: "running", kind: "claude", since: 1, started: 1 };
  const bad = [
    { ...base, tool: "t".repeat(65) },
    { ...base, tool: "Bash Edit" },
    { ...base, detail: "d".repeat(201) },
    { ...base, msg: "m".repeat(301) },
    { ...base, msg: "two\nlines" },
    { ...base, detail: "tab\there" },
    { ...base, msg: "sep\u2028arator" },
    { ...base, msg: "" },
    { ...base, tool: 7 },
    { ...base, detail: null },
    { ...base, prompt: "secret" },
  ];
  for (const content of bad) {
    const res = await handle(post("/v1/activity", activity(h, { content })), ENV, { deliver });
    assert.equal(res.status, 400, JSON.stringify(content));
  }
});

test("activity content keys are looked up as own keys only", async () => {
  const h = await register();
  const deliver = async () => assert.fail("must not deliver");
  for (const key of ["constructor", "toString", "__proto__", "hasOwnProperty"]) {
    // As the Worker reads it: JSON.parse makes "__proto__" an own key.
    const raw = `{"state":"running","kind":"claude","since":1,"started":1,${JSON.stringify(key)}:"x"}`;
    const body = { ...activity(h), content: JSON.parse(raw) };
    assert.ok(Object.keys(body.content).includes(key), key);
    assert.equal(activityRequest(body), null, key);
    const res = await handle(post("/v1/activity", body), ENV, { deliver });
    assert.equal(res.status, 400, key);
  }
});

test("activity updates are rate limited, and APNs answers map as for alerts", async () => {
  const h = await register();
  const limited = { ...ENV, ACTIVITY_LIMITER: { limit: async () => ({ success: false }) } };
  const res = await handle(post("/v1/activity", activity(h)), limited, { deliver: async () => assert.fail("must not deliver") });
  assert.equal(res.status, 429);
  for (const [apns, expected] of [[{ status: 410, reason: "Unregistered" }, 410], [{ status: 400, reason: "ExpiredToken" }, 410],
                                  [{ status: 429, reason: "TooManyRequests" }, 429], [{ status: 500 }, 502]]) {
    const r = await handle(post("/v1/activity", activity(h)), ENV, { deliver: async () => apns });
    assert.equal(r.status, expected, JSON.stringify(apns));
  }
});
