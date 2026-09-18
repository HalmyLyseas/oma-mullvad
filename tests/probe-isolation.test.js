const { readFileSync, statSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");

test("all executable boundaries run through test-local wrappers", () => {
    const source = readFileSync(join(root, "tests/all"), "utf8");
    assert.match(source, /tests\/run-cli-contract/);
    assert.doesNotMatch(source, /node[^\n]+tests\/cli-contract\.mjs/);
});

test("CLI contract fails closed unless mullvad resolves to its exact mock", () => {
    const source = readFileSync(join(root, "tests/run-cli-contract"), "utf8");
    assert.match(source, /^set -euo pipefail$/m);
    assert.match(source, /ln -s[^\n]*\|\| exit 1/);
    assert.match(source, /command -v mullvad/);
    assert.match(source, /readlink -f[^\n]*tests\/mocks\/mullvad/);
    assert.doesNotMatch(source, /PATH="\$scratch\/bin:\$PATH"/);
    assert.match(source, /trusted_system_path='?\/usr\/bin:\/bin'?/);
    assert.match(source, /PATH="\$trusted_system_path" command -v node/);
});

for (const runner of ["tests/probe/run", "tests/probe/run-ui"]) {
    test(`${runner} shadows the excluded-application launcher`, () => {
        const source = readFileSync(join(root, runner), "utf8");
        assert.match(source, /tests\/mocks\/mullvad-exclude/);
    });
    test(`${runner} verifies every executable mock before running`, () => {
        const source = readFileSync(join(root, runner), "utf8");
        assert.match(source, /for executable in mullvad mullvad-exclude ps pgrep checkupdates touch/);
        assert.match(source, /command -v "\$executable"/);
        assert.match(source, /readlink -f.*tests\/mocks\/\$executable/);
    });
    test(`${runner} never appends the host PATH`, () => {
        const source = readFileSync(join(root, runner), "utf8");
        assert.doesNotMatch(source, /PATH="\$[^"\n]*:\$PATH"/);
        assert.match(source, /PATH="\$[^"\n]*(?:path_dir|scratch\/bin)"/);
        assert.match(source, /qs_bin=.*command -v qs/);
        assert.match(source, /timeout_bin=.*command -v timeout/);
        assert.match(source, /trusted_system_path='?\/usr\/bin:\/bin'?/);
        assert.match(source, /PATH="\$trusted_system_path" command -v qs/);
    });
    test(`${runner} bounds diagnostic log output`, () => {
        const source = readFileSync(join(root, runner), "utf8");
        assert.match(source, /head -c 65536/);
        assert.doesNotMatch(source, /cat \"\$[^\"]*log\"/);
    });
}

test("scoped settings runner uses the same verified executable boundary", () => {
    const source = readFileSync(join(root, "tests/probe/run-settings"), "utf8");
    assert.match(source, /PATH="\$scratch\/empty-bin"/);
    assert.match(source, /readlink -f.*\$helper/);
    assert.match(source, /PATH="\$trusted_system_path" command -v qs/);
});

test("the excluded-application launcher mock is executable", () => {
    const path = join(root, "tests/mocks/mullvad-exclude");
    assert.ok(statSync(path).mode & 0o111);
});

test("availability recovery crosses the mocked process boundary", () => {
    const probe = readFileSync(join(root, "tests/probe/service-probe.qml"), "utf8");
    const scenario = probe.slice(probe.indexOf('scenario === "availability-recovery"'),
        probe.indexOf('scenario === "listener-flood"'));
    assert.match(scenario, /refreshAll\(\)/);
    assert.doesNotMatch(scenario, /_applyRead/);
    const mock = readFileSync(join(root, "tests/mocks/mullvad"), "utf8");
    assert.match(mock, /MULLVAD_MOCK_AVAILABILITY_TRIGGER/);
});
