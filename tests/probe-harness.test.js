const { mkdtempSync, readFileSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");
const collector = join(root, "test/probe/collect-result");

function collect(log, status = 0) {
    const scratch = mkdtempSync(join(tmpdir(), "oma-mullvad-probe-result-"));
    const path = join(scratch, "probe.log");
    writeFileSync(path, log);
    const result = spawnSync("bash", [collector, path, String(status)], { encoding: "utf8" });
    rmSync(scratch, { recursive: true, force: true });
    return result;
}

test("probe result collector accepts one prefixed Quickshell result", () => {
    const result = collect('\u001b[32m DEBUG qml:\u001b[0m PROBE_RESULT {"note":"","passed":true}\n');
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), { note: "", passed: true });
});

test("probe result collector does not mistake application ERROR data for an engine failure", () => {
    const result = collect('ERROR: simulated service state: Type MissingWidget unavailable\nPROBE_RESULT {"note":"","passed":true}\n');
    assert.equal(result.status, 0, result.stderr);
});

test("probe result collector rejects a result token embedded in attacker text", () => {
    const result = collect('attacker-controlled PROBE_RESULT {"note":"","passed":true}\n');
    assert.notEqual(result.status, 0, `unexpectedly accepted: ${result.stdout}`);
});

for (const [name, log, status] of [
    ["nonzero qs exit", 'PROBE_RESULT {"note":"","passed":true}\n', 7],
    ["timeout exit", 'PROBE_RESULT {"note":"","passed":true}\n', 124],
    ["missing result", "ordinary output\n", 0],
    ["failing result", 'PROBE_RESULT {"note":"","passed":false}\n', 0],
    ["harness note", 'PROBE_RESULT {"note":"overall timeout"}\n', 0],
    ["late TypeError", 'PROBE_RESULT {"note":"","passed":true}\nTypeError: late failure\n', 0],
    ["late ReferenceError", 'PROBE_RESULT {"note":"","passed":true}\nReferenceError: late failure\n', 0],
    ["late QML load error", 'PROBE_RESULT {"note":"","passed":true}\nQQmlApplicationEngine failed to load component\n', 0],
    ["late missing QML module", 'PROBE_RESULT {"note":"","passed":true}\nfile:///tmp/Late.qml:1:1: module "Missing.Module" is not installed\n', 0],
    ["late missing versioned QML module", 'PROBE_RESULT {"note":"","passed":true}\nfile:///tmp/Late.qml:1:1: module "Missing.Module" version 1.0 is not installed\n', 0],
    ["late unavailable QML type", 'PROBE_RESULT {"note":"","passed":true}\nType MissingWidget unavailable\n', 0],
    ["late scene TypeError", 'PROBE_RESULT {"note":"","passed":true}\nWARN scene: @probe.qml[7:-1]: TypeError: late failure\n', 0],
    ["duplicate result", 'PROBE_RESULT {"note":"","passed":true}\nPROBE_RESULT {"note":"","passed":true}\n', 0]
]) {
    test(`probe result collector rejects ${name}`, () => {
        const result = collect(log, status);
        assert.notEqual(result.status, 0, `unexpectedly accepted: ${result.stdout}`);
    });
}

test("probe runners preserve the command status and use fail-closed collection", () => {
    for (const runner of ["test/probe/run", "test/probe/run-ui", "test/probe/run-settings"]) {
        const source = readFileSync(join(root, runner), "utf8");
        assert.match(source, /command_status=\$\?/);
        assert.match(source, /collect-result/);
        assert.doesNotMatch(source, /grep -o ['"]PROBE_RESULT/);
    }
});

test("probe result collector rejects oversized logs", () => {
    const result = collect("x".repeat(1024 * 1024 + 1));
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /exceeds/);
});

test("collector rejects and terminates an orphan mock child", async () => {
    const scratch = mkdtempSync(join(tmpdir(), "oma-probe-orphan-"));
    const child = spawn("/bin/sleep", ["30"], { stdio: "ignore" });
    const exited = new Promise(resolve => child.once("exit", resolve));
    try {
        const log = join(scratch, "probe.log");
        const mock = join(scratch, "mock.log");
        writeFileSync(log, 'PROBE_RESULT {"note":"","passed":true}\n');
        writeFileSync(mock, `PID=${child.pid} MODE=test\n`);
        const result = spawnSync("/bin/bash", [collector, log, "0", mock], { encoding: "utf8" });
        assert.notEqual(result.status, 0);
        assert.match(result.stderr, /live mock processes/);
        await exited;
        assert.equal(child.signalCode, "SIGKILL");
    } finally {
        child.kill("SIGKILL");
        rmSync(scratch, { recursive: true, force: true });
    }
});
