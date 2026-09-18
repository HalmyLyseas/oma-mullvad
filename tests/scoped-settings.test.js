const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");

test("scoped settings probe uses the real host facade and isolated shell.json", () => {
    const runner = readFileSync(join(root, "test/probe/run-settings"), "utf8");
    const probe = readFileSync(join(root, "test/probe/scoped-settings-probe.qml"), "utf8");
    assert.match(runner, /HOME="\$scratch\/home"/);
    assert.match(runner, /OMARCHY_PATH="\$scratch\/omarchy"/);
    assert.match(runner, /PATH="\$scratch\/empty-bin"/);
    assert.match(runner, /collect-result/);
    assert.match(probe, /OMARCHY_SHELL_DIR[\s\S]*shell\.qml/);
    assert.match(probe, /pluginShellFor/);
    assert.match(probe, /FileView/);
    assert.doesNotMatch(probe, /services\/PluginShellApi\.qml|_updateSettings|function updateSettings|MULLVAD_SHELL_JSON/);
});

test("all probe inventory includes scoped settings", () => {
    const all = readFileSync(join(root, "test/all"), "utf8");
    assert.match(all, /test\/probe\/run-settings/);
});
