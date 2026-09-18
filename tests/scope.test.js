const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");
const read = name => readFileSync(join(__dirname, "..", name), "utf8");
test("runtime reliability retains upstream identity and four pages", () => {
    const manifest = JSON.parse(read("manifest.json"));
    assert.equal(manifest.id, "io.github.kallupx.oma-mullvad");
    assert.equal(manifest.author, "kallupx");
    assert.equal(manifest.version, "0.1.2");
    assert.match(read("Panel.qml"), /model: \["Overview", "Locations", "Advanced", "Excluded"\]/);
    assert.doesNotMatch(read("Panel.qml"), /systemPage|function (?:lockdown|excluded|systemInfo|checkUpdates)\(/);
    assert.doesNotMatch(read("Service.qml"), /updateCheck|packageInfoScript|daemonPid|excludedProcesses/);
});
