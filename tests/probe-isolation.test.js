const { readFileSync, statSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");

test("all executable boundaries run through test-local wrappers", () => {
    const source = readFileSync(join(root, "test/all"), "utf8");
    assert.match(source, /test\/run-cli-contract/);
    assert.doesNotMatch(source, /node[^\n]+test\/cli-contract\.mjs/);
});

test("CLI contract fails closed unless mullvad resolves to its exact mock", () => {
    const source = readFileSync(join(root, "test/run-cli-contract"), "utf8");
    assert.match(source, /ln -s[^\n]*\|\| exit 1/);
    assert.match(source, /command -v mullvad/);
    assert.match(source, /readlink -f[^\n]*test\/mocks\/mullvad/);
    assert.doesNotMatch(source, /PATH="\$scratch\/bin:\$PATH"/);
});

for (const runner of ["test/probe/run", "test/probe/run-ui"]) {
    test(`${runner} shadows the excluded-application launcher`, () => {
        const source = readFileSync(join(root, runner), "utf8");
        assert.match(source, /test\/mocks\/mullvad-exclude/);
    });
    test(`${runner} verifies every executable mock before running`, () => {
        const source = readFileSync(join(root, runner), "utf8");
        assert.match(source, /for executable in mullvad mullvad-exclude ps pgrep checkupdates/);
        assert.match(source, /command -v "\$executable"/);
        assert.match(source, /readlink -f.*test\/mocks\/\$executable/);
    });
}

test("the excluded-application launcher mock is executable", () => {
    const path = join(root, "test/mocks/mullvad-exclude");
    assert.ok(statSync(path).mode & 0o111);
});
