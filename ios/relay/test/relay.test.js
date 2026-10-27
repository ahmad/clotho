// node --test relay/test
import assert from "node:assert/strict";
import { test } from "node:test";
import { apnsDeliver, handle, openHandle, unb64url } from "../src/relay.js";

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
