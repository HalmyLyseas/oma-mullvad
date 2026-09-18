#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const path = process.argv[2];
if (!path) process.exit(2);
const actual = readFileSync(path, "utf8").split(/\r?\n/).filter(Boolean).map(line => {
  const marker = " ARGV: ";
  const index = line.indexOf(marker);
  return index < 0 ? "" : line.slice(index + marker.length);
});
const expected = [
  "--version", "status --json", "relay list", "relay get", "auto-connect get",
  "lan get", "lockdown-mode get", "dns get", "anti-censorship get", "split-tunnel list"
];
assert.deepEqual(actual, expected, "CLI contract escaped its exact read-only argv inventory");
console.log("mocked CLI contract argv: ok");
