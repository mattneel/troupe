// Runs the playground's in-page self-test (index.html?selftest) in headless
// Chrome through the DevTools protocol, with no npm dependencies.
//
//   node playground/selftest.mjs http://127.0.0.1:4010/
//
// Chrome is taken from $CHROME_PATH, or google-chrome / chromium on PATH.
// Exits 0 only if every self-test check passes.
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const base = process.argv[2] ?? "http://127.0.0.1:4010/";
const url = new URL("?selftest", base).href;
const timeoutMs = Number(process.env.SELFTEST_TIMEOUT_MS ?? 180000);

function findChrome() {
  if (process.env.CHROME_PATH) return process.env.CHROME_PATH;
  for (const name of ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"]) {
    if (spawnSync("which", [name]).status === 0) return name;
  }
  throw new Error("no Chrome found; set CHROME_PATH");
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const profile = mkdtempSync(join(tmpdir(), "troupe-selftest-"));
const chrome = spawn(findChrome(), [
  "--headless=new",
  "--no-first-run",
  "--no-default-browser-check",
  "--remote-debugging-port=0",
  `--user-data-dir=${profile}`,
  "about:blank",
]);

const port = await new Promise((resolve, reject) => {
  let output = "";
  chrome.stderr.on("data", (chunk) => {
    output += chunk;
    const match = output.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//);
    if (match) resolve(Number(match[1]));
  });
  chrome.on("exit", (code) => reject(new Error(`chrome exited (${code}): ${output}`)));
});

let exitCode = 1;
try {
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = targets.find((target) => target.type === "page");
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve) => socket.addEventListener("open", resolve, { once: true }));

  let id = 0;
  const pending = new Map();
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    }
  });
  const send = (method, params = {}) =>
    new Promise((resolve) => {
      pending.set(++id, resolve);
      socket.send(JSON.stringify({ id, method, params }));
    });
  const evaluate = async (expression) => (await send("Runtime.evaluate", { expression, returnByValue: true })).result?.result?.value;

  await send("Page.navigate", { url });
  const deadline = Date.now() + timeoutMs;
  let status = null;
  while (Date.now() < deadline) {
    status = await evaluate(
      "JSON.stringify({ready: document.body?.dataset.ready ?? null, selftest: document.body?.dataset.selftest ?? null, isolated: self.crossOriginIsolated, vm: document.getElementById('vm-status')?.textContent ?? null})",
    );
    const parsed = status ? JSON.parse(status) : {};
    if (parsed.selftest || parsed.ready === "error") break;
    await sleep(1000);
  }

  const parsed = status ? JSON.parse(status) : {};
  console.log(`page: ${url}`);
  console.log(`cross-origin isolated: ${parsed.isolated}; vm: ${parsed.vm}`);
  console.log((await evaluate("document.getElementById('selftest')?.textContent ?? ''")) || "(no self-test output)");
  exitCode = parsed.selftest === "pass" ? 0 : 1;
  socket.close();
} finally {
  chrome.kill();
  await sleep(200);
  rmSync(profile, { recursive: true, force: true });
}

console.log(exitCode === 0 ? "SELFTEST PASSED" : "SELFTEST FAILED");
process.exit(exitCode);
