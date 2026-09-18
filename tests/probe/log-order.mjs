#!/usr/bin/env node
import { readFileSync } from "node:fs";

const [path, first, second] = process.argv.slice(2);
if (!path || !first || !second) process.exit(2);
const text = readFileSync(path, "utf8");
const firstIndex = text.indexOf(first);
const secondIndex = firstIndex < 0 ? -1 : text.indexOf(second, firstIndex + first.length);
if (firstIndex < 0 || secondIndex < 0) {
    console.error(`expected log order: ${first} before ${second}`);
    process.exit(1);
}
