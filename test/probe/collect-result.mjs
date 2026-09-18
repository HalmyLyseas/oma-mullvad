#!/usr/bin/env node
import { readFileSync } from "node:fs";

const [logPath, statusText, mockLogPath] = process.argv.slice(2);
const status = Number(statusText);
if (!logPath || !Number.isInteger(status)) {
    console.error("invalid probe collector arguments");
    process.exit(2);
}

const log = readFileSync(logPath, "utf8");
if (mockLogPath) {
    const mockLog = readFileSync(mockLogPath, "utf8");
    const pids = new Set([...mockLog.matchAll(/^PID=([0-9]+)(?:\s|$)/gm)].map(match => Number(match[1])));
    const leaked = [];
    for (const pid of pids) {
        try {
            process.kill(pid, 0);
            const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
            const closeParen = stat.lastIndexOf(")");
            const state = closeParen >= 0 ? stat.slice(closeParen + 2).split(" ")[0] : "";
            if (state !== "Z") {
                leaked.push(pid);
                try { process.kill(pid, "SIGKILL"); } catch {}
            }
        } catch {}
    }
    if (leaked.length) {
        console.error(`probe left live mock processes: ${leaked.join(",")}`);
        process.exit(1);
    }
}
const engineError = /(?:TypeError:|ReferenceError:|QQmlApplicationEngine failed to load component|QQmlComponent: Component is not ready|^\s*ERROR:)/m;
if (status !== 0) {
    console.error(`probe process exited with status ${status}`);
    process.exit(1);
}
if (engineError.test(log)) {
    console.error("probe log contains a QML engine error");
    process.exit(1);
}

const lines = log.split(/\r?\n/).map(line => {
    const index = line.indexOf("PROBE_RESULT ");
    return index < 0 ? null : line.slice(index + "PROBE_RESULT ".length);
}).filter(value => value !== null);
if (lines.length !== 1) {
    console.error(`expected exactly one PROBE_RESULT, found ${lines.length}`);
    process.exit(1);
}

let result;
try {
    result = JSON.parse(lines[0]);
} catch {
    console.error("PROBE_RESULT is not valid JSON");
    process.exit(1);
}
if (!result || typeof result !== "object" || Array.isArray(result)) {
    console.error("PROBE_RESULT must be an object");
    process.exit(1);
}
if (typeof result.note !== "string" || result.note !== "") {
    console.error("probe reported a harness note");
    process.exit(1);
}
if (result.passed === false) {
    console.error("probe reported failure");
    process.exit(1);
}
process.stdout.write(`${JSON.stringify(result)}\n`);
