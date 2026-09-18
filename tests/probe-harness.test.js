const { mkdtempSync, readFileSync, rmSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { spawnSync } = require("node:child_process");
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

test("probe result collector accepts one clean passing result", () => {
    const result = collect('PROBE_RESULT {"note":"","passed":true}\n');
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), { note: "", passed: true });
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
    ["duplicate result", 'PROBE_RESULT {"note":"","passed":true}\nPROBE_RESULT {"note":"","passed":true}\n', 0]
]) {
    test(`probe result collector rejects ${name}`, () => {
        const result = collect(log, status);
        assert.notEqual(result.status, 0, `unexpectedly accepted: ${result.stdout}`);
    });
}

test("probe runners preserve the command status and use fail-closed collection", () => {
    for (const runner of ["test/probe/run", "test/probe/run-ui"]) {
        const source = readFileSync(join(root, runner), "utf8");
        assert.match(source, /command_status=\$\?/);
        assert.match(source, /collect-result/);
        assert.doesNotMatch(source, /grep -o ['"]PROBE_RESULT/);
    }
});
