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

for (const runner of ["test/probe/run", "test/probe/run-ui"]) {
    test(`${runner} shadows the excluded-application launcher`, () => {
        const source = readFileSync(join(root, runner), "utf8");
        assert.match(source, /test\/mocks\/mullvad-exclude/);
    });
}

test("the excluded-application launcher mock is executable", () => {
    const path = join(root, "test/mocks/mullvad-exclude");
    assert.ok(statSync(path).mode & 0o111);
});
