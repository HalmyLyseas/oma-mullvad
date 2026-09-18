const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");

for (const path of ["README.md", "CONTRIBUTING.md", "docs/developers.md"]) {
    test(`${path} documents Cage as the canonical local gate`, () => {
        const text = readFileSync(join(root, path), "utf8");
        const primary = text.indexOf("bash tests/ci-local\n");
        const fallback = text.indexOf("bash tests/ci-local --no-cage");
        assert.ok(primary >= 0, "missing canonical Cage command");
        assert.ok(fallback > primary, "--no-cage must be documented only after the canonical command");
        assert.match(text, /live-session fallback|fallback for an existing live session/i);
    });
}

test("clean archive checks every tracked runner and mock syntax", () => {
    const source = readFileSync(join(root, "tests/ci-local"), "utf8");
    assert.match(source, /git[^\n]*ls-files[^\n]*tests\/probe[^\n]*tests\/mocks/);
    assert.match(source, /bash -n/);
    assert.match(source, /tests\/all/);
    assert.match(source, /\[\[ -x "\$root\/\$file" && ! -x "\$archive_dir\/\$file"/);
    assert.match(source, /command -v qs/);
});

test("local inventory contains service, UI, and scoped-host probes", () => {
    const source = readFileSync(join(root, "tests/all"), "utf8");
    for (const runner of ["run", "run-ui", "run-settings"])
        assert.match(source, new RegExp(`tests/probe/${runner}(?:\\"|$)`));
});
