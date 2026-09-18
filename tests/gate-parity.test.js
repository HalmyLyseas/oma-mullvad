const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");

for (const path of ["README.md", "CONTRIBUTING.md", "docs/developers.md"]) {
    test(`${path} documents Cage as the canonical local gate`, () => {
        const text = readFileSync(join(root, path), "utf8");
        const primary = text.indexOf("bash test/ci-local\n");
        const fallback = text.indexOf("bash test/ci-local --no-cage");
        assert.ok(primary >= 0, "missing canonical Cage command");
        assert.ok(fallback > primary, "--no-cage must be documented only after the canonical command");
        assert.match(text, /live-session fallback|fallback for an existing live session/i);
    });
}

test("clean archive checks every tracked runner and mock syntax", () => {
    const source = readFileSync(join(root, "test/ci-local"), "utf8");
    assert.match(source, /git[^\n]*ls-files[^\n]*test\/probe[^\n]*test\/mocks/);
    assert.match(source, /bash -n/);
    assert.match(source, /test\/all/);
});

test("local inventory contains service, UI, and scoped-host probes", () => {
    const source = readFileSync(join(root, "test/all"), "utf8");
    for (const runner of ["run", "run-ui", "run-settings"])
        assert.match(source, new RegExp(`test/probe/${runner}(?:\\"|$)`));
});
