#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
// Same strip-and-eval as test/model.test.js: Model.js is .pragma library
// QML, so Node can't require() it directly.
const modelSource = readFileSync(join(__dirname, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*/, "");
const modelExports = { exports: {} };
new Function("module", "exports", modelSource)(modelExports, modelExports.exports);
const Model = modelExports.exports;

const ACCOUNT = /\b\d{16}\b/g;

function ensureNoAccount(value, label) {
  if (/\b\d{16}\b/.test(value)) throw new Error(`${label} returned sensitive account data`);
}

function readOnly(args) {
  const result = spawnSync("mullvad", args, { encoding: "utf8", timeout: 15000 });
  return {
    error: result.error,
    status: result.status,
    stdout: String(result.stdout || ""),
    stderr: String(result.stderr || "").replace(ACCOUNT, "[REDACTED]")
  };
}

function skip(reason) {
  console.log(`SKIP: ${reason}`);
  process.exit(0);
}

function check(args, test) {
  const result = readOnly(args);
  assert.equal(result.status, 0, `mullvad ${args.join(" ")} failed: ${result.stderr.trim()}`);
  ensureNoAccount(result.stdout, args.join(" "));
  test(result.stdout);
}

const version = readOnly(["--version"]);
if (version.error?.code === "ENOENT") skip("mullvad CLI is not installed");
assert.equal(version.status, 0, "mullvad --version failed");
ensureNoAccount(version.stdout, "version");
const cliVersion = Model.parseCliVersion(version.stdout);
assert.ok(
  Model.isCliVersionSupported(cliVersion),
  `installed mullvad-cli ${cliVersion || "(unparsed)"} is not in the pinned SUPPORTED_CLI_VERSIONS list ` +
  `[${Model.SUPPORTED_CLI_VERSIONS.join(", ")}] -- a Mullvad upgrade needs Model.SUPPORTED_CLI_VERSIONS updated`
);

const status = readOnly(["status", "--json"]);
if (status.status !== 0) skip("Mullvad daemon is unavailable");
ensureNoAccount(status.stdout, "status");
const snapshot = JSON.parse(status.stdout);
assert.ok(["connected", "connecting", "disconnected", "disconnecting", "error", "blocked"].includes(snapshot.state));
assert.equal(typeof snapshot.details, "object");

check(["relay", "list"], output => {
  assert.match(output, /^[^\n]+ \([a-z]{2}\)$/m);
  assert.match(output, /^\t[^\n]+ \([a-z0-9-]+\) @ /m);
});
check(["relay", "get"], output => {
  assert.match(output, /Generic constraints/);
  assert.match(output, /WireGuard constraints/);
});
check(["auto-connect", "get"], output => assert.match(output, /Autoconnect: (on|off)/));
check(["lan", "get"], output => assert.match(output, /Local network sharing setting: (allow|block)/));
check(["lockdown-mode", "get"], output => assert.match(output, /Block traffic when the VPN is disconnected: (on|off)/));
check(["dns", "get"], output => assert.match(output, /Custom DNS: (yes|no)/));
check(["anti-censorship", "get"], output => assert.match(output, /mode: (auto|off|wireguard-port|udp2tcp|shadowsocks|quic|lwo)/));
check(["split-tunnel", "list"], output => assert.match(output, /^Excluded PIDs:/));

console.log("halmylyseas.mullvad 2026.4 read-only CLI contract: ok");
