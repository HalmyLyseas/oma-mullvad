const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { spawnSync } = require("node:child_process");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");

test("probe runners never use shell eval", () => {
    for (const file of ["test/probe/run", "test/probe/run-ui", "test/probe/run-settings"])
        assert.doesNotMatch(readFileSync(join(root, file), "utf8"), /\beval\b/, file);
});

test("probe JSON comparisons treat adversarial values as data", () => {
    const marker = join(root, ".probe-injection-marker");
    const value = `quotes '" $() ; $(touch ${marker})`;
    const result = spawnSync(process.execPath, [
        join(root, "test/probe/json-assert.mjs"),
        JSON.stringify({ value }), "value", "eq", value
    ], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    assert.throws(() => readFileSync(marker), /ENOENT/);
});
