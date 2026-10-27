// A local relay for testing without the APNs key or Cloudflare: the same code as the Worker, served on
// 127.0.0.1, delivering with `xcrun simctl push` to a booted simulator instead of APNs.
//
//   node relay/dev.js [port] [simulator udid]     (default 8787, "booted")
//
// Handles are sealed with a key made for this run, so they stop working when it exits.
import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { handle } from "./src/relay.js";

const port = Number(process.argv[2] ?? 8787);
const device = process.argv[3] ?? "booted";
const topic = process.env.APNS_TOPIC ?? "nyc.amin.clotho";
const env = { HANDLE_KEYS: JSON.stringify({ 1: randomBytes(32).toString("base64") }), HANDLE_KEY_ID: "1", APNS_TOPIC: topic };
const dir = mkdtempSync(join(tmpdir(), "clotho-relay-"));

async function simctlDeliver(_env, { payload, collapseID }) {
  const file = join(dir, `${collapseID}-${Date.now()}.json`);
  writeFileSync(file, JSON.stringify({ ...payload, "Simulator Target Bundle": topic }));
  return new Promise((resolve) => {
    execFile("xcrun", ["simctl", "push", device, topic, file], (err, _out, stderr) => {
      rmSync(file, { force: true });
      if (err) console.error(`simctl push failed: ${stderr.trim()}`);
      resolve(err ? { status: 500, reason: "SimctlFailed" } : { status: 200 });
    });
  });
}

const server = createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = req.method === "GET" || req.method === "HEAD" ? undefined : Buffer.concat(chunks);
  const response = await handle(new Request(`http://${req.headers.host}${req.url}`, { method: req.method, body }), env,
    { deliver: simctlDeliver });
  const text = await response.text();
  console.log(`${req.method} ${req.url} -> ${response.status}${response.status === 200 ? "" : ` ${text}`}`);
  res.writeHead(response.status, { "content-type": "application/json" }).end(text);
});

server.listen(port, "127.0.0.1", () => console.log(`clotho dev relay on http://127.0.0.1:${port}, delivering to simulator ${device}`));
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => { rmSync(dir, { recursive: true, force: true }); process.exit(0); });
