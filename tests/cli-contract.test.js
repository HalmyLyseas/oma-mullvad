const { mkdtempSync, writeFileSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { spawnSync } = require("node:child_process");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");

function contract(snapshot, mode = "cli-contract") {
    const scratch = mkdtempSync(join(tmpdir(), "oma-cli-contract-"));
    try {
        const fixture = join(scratch, "status.json");
        writeFileSync(fixture, snapshot);
        return spawnSync("/bin/bash", [join(root, "test/run-cli-contract")], {
            encoding: "utf8", timeout: 30000,
            env: { ...process.env, MULLVAD_MOCK_MODE: mode, MULLVAD_MOCK_STATUS_FIXTURE: fixture }
        });
    } finally {
        rmSync(scratch, { recursive: true, force: true });
    }
}

for (const details of ["nothing", "block", "reconnect"]) {
    test(`isolated CLI contract accepts disconnecting ${details}`, () => {
        const result = contract(JSON.stringify({ state: "disconnecting", details }));
        assert.equal(result.error, undefined);
        assert.equal(result.status, 0, result.stderr);
        assert.match(result.stdout, /mocked CLI contract argv: ok/);
    });
}

test("isolated CLI contract rejects malformed status snapshots", () => {
    for (const snapshot of ['{"state":"connected","details":null}',
        "garbage", "null", "[]", "{}", '{"state":"invented","details":{}}',
        '{"state":"connected","details":[]}',
        '{"state":"connected","details":7}', '{"state":"connected","details":"nothing"}',
        '{"state":"disconnecting","details":"invalid"}', '{"state":{"toString":null}}',
        '{"state":"connected","details":{"location":"bad"}}']) {
        const result = contract(snapshot);
        assert.equal(result.error, undefined);
        assert.equal(result.status, 1, snapshot);
        assert.match(result.stderr, /Invalid Mullvad status snapshot/, snapshot);
    }
});

test("isolated CLI contract still rejects a failed daemon read", () => {
    const result = contract('{"state":"disconnected","details":{}}', "fail");
    assert.equal(result.error, undefined);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /mullvad status --json failed: mock failure/);
});

test("isolated CLI contract still rejects unrelated CLI format failures", () => {
    const result = contract('{"state":"disconnected","details":{}}', "ok");
    assert.equal(result.error, undefined);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Excluded PIDs:/);
});
