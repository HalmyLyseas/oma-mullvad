#!/usr/bin/env node
import { readFileSync, statSync } from "node:fs";

const maxLogBytes = 1024 * 1024;

function readBounded(path, label) {
    let size;
    try {
        size = statSync(path).size;
    } catch {
        console.error(`cannot read ${label}`);
        process.exit(1);
    }
    if (size > maxLogBytes) {
        console.error(`${label} exceeds ${maxLogBytes} bytes`);
        process.exit(1);
    }
    return readFileSync(path, "utf8");
}

const [logPath, statusText, mockLogPath] = process.argv.slice(2);
const status = Number(statusText);
if (!logPath || !Number.isInteger(status)) {
    console.error("invalid probe collector arguments");
    process.exit(2);
}

const log = readBounded(logPath, "probe log");
if (mockLogPath) {
    const mockLog = readBounded(mockLogPath, "mock log");
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
const logPrefix = /^\s*(?:(?:TRACE|DEBUG|INFO|WARN|WARNING|ERROR|CRITICAL|FATAL):\s*)?/;
function isEngineError(line) {
    const text = line.replace(logPrefix, "");
    return /^(?:TypeError:|ReferenceError:|QQmlApplicationEngine failed to load component|QQmlComponent: Component is not ready)(?:\s|$)/.test(text)
        || /^(?:(?:file|qrc|resource):\/\/\/[^\r\n]*?:\d+(?::\d+)?:\s*)?module\s+["'][^"']+["']\s+(?:version\s+\S+\s+)?is not installed(?:\s|$)/.test(text)
        || /^(?:(?:file|qrc|resource):\/\/\/[^\r\n]*?:\d+(?::\d+)?:\s*)?Type\s+[A-Za-z_][A-Za-z0-9_.]*\s+unavailable\s*$/.test(text);
}
if (status !== 0) {
    console.error(`probe process exited with status ${status}`);
    process.exit(1);
}
if (log.split(/\r?\n/).some(isEngineError)) {
    console.error("probe log contains a QML engine error");
    process.exit(1);
}

const lines = log.split(/\r?\n/).map(line => {
    const match = line.match(/^\s*(?:(?:TRACE|DEBUG|INFO|WARN|WARNING|ERROR|CRITICAL|FATAL):\s*)?PROBE_RESULT (.*)$/);
    return match ? match[1] : null;
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
