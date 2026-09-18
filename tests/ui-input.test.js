const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");

test("interactive UI probe uses honest rendered handler boundaries", () => {
    const probe = readFileSync(join(root, "test/probe/ui-probe.qml"), "utf8");
    const scenario = probe.slice(probe.indexOf('scenario === "interactive-controls"'),
        probe.indexOf('scenario === "excluded-groups"'));
    assert.doesNotMatch(probe, /import QtTest/);
    assert.match(scenario, /physicalInputAvailable: false/);
    assert.match(scenario, /focusTrigger\(\)/);
    assert.match(scenario, /handleTriggerKey\(/);
    assert.match(scenario, /handlePopupKey\(/);
    assert.match(scenario, /_probeConfirmDialog\.handleKey\(/);
    assert.doesNotMatch(scenario, /\.changed\(|\.canceled\(|\.confirmed\(/);
});

test("dropdown test boundary focuses the rendered trigger without emitting output", () => {
    for (const file of ["OmaDropdown.qml", "OmaSearchableDropdown.qml"]) {
        const source = readFileSync(join(root, file), "utf8");
        assert.match(source, /function focusTrigger\(\) \{ trigger\.forceActiveFocus\(\) \}/);
    }
});

test("UI gate labels component-boundary coverage honestly", () => {
    const runner = readFileSync(join(root, "test/probe/run-ui"), "utf8");
    assert.match(runner, /real map component projects the selected relay target/);
    assert.match(runner, /lacks a physical event injector/);
    assert.doesNotMatch(runner, /map selection/);
});
