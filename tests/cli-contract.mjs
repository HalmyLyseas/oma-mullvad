#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const modelSource = readFileSync(join(here, "..", "Model.js"), "utf8")
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

function check(args, test) {
  const result = readOnly(args);
  assert.equal(result.status, 0, `mullvad ${args.join(" ")} failed: ${result.stderr.trim()}`);
  ensureNoAccount(result.stdout, args.join(" "));
  test(result.stdout);
}

const version = readOnly(["--version"]);
if (version.error?.code === "ENOENT") {
  console.log("SKIP: mullvad CLI is not installed");
  process.exit(0);
}
assert.equal(version.status, 0, "mullvad --version failed");
ensureNoAccount(version.stdout, "version");
const cliVersion = Model.parseCliVersion(version.stdout);
assert.ok(Model.isCliVersionSupported(cliVersion),
  `installed mullvad-cli ${cliVersion || "(unparsed)"} is not in supported series ${Model.SUPPORTED_CLI_SERIES}`);

check(["status", "--json"], output => {
  assert.ok(Model.isStatusSnapshot(output), "Invalid Mullvad status snapshot");
});
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

console.log(`OmaMullvad Mullvad ${cliVersion} read-only CLI contract: ok`);
