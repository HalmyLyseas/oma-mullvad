const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");

test("application icons decode asynchronously at a fixed size", () => {
    const panel = readFileSync(join(root, "Panel.qml"), "utf8");
    const image = panel.slice(panel.indexOf("      Image {"), panel.indexOf("      ColumnLayout {", panel.indexOf("      Image {")));
    assert.match(image, /asynchronous: true/);
    assert.match(image, /sourceSize.width: Style.space\(24\)/);
    assert.match(image, /sourceSize.height: Style.space\(24\)/);
});

test("interactive UI probe uses honest rendered handler boundaries", () => {
    const probe = readFileSync(join(root, "tests/probe/ui-probe.qml"), "utf8");
    const scenario = probe.slice(probe.indexOf('scenario === "interactive-controls"'),
        probe.indexOf('scenario === "excluded-groups"'));
    assert.doesNotMatch(probe, /import QtTest/);
    assert.doesNotMatch(probe, /physicalInputAvailable/);
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

test("UI gate labels component-boundary coverage as complementary", () => {
    const runner = readFileSync(join(root, "tests/probe/run-ui"), "utf8");
    assert.match(runner, /real map component projects the selected relay target/);
    assert.match(runner, /complements Qt Quick physical input/);
    assert.doesNotMatch(runner, /lacks a physical event injector/);
    assert.doesNotMatch(runner, /map selection/);
});

test("dedicated Qt Quick Tests use genuine keyboard and pointer injection", () => {
    const source = readFileSync(join(root, "tests/quicktest/tst_physical_input.qml"), "utf8");
    assert.match(source, /import QtTest/);
    assert.match(source, /keyClick\(/);
    assert.match(source, /mouseClick\(/);
    assert.doesNotMatch(source, /control\.handleTriggerKey\(|control\.handlePopupKey\(|dialog\.handleKey\(/);
});

test("physical suite covers panel routing, dropdowns, dialogs, and map payloads", () => {
    const source = readFileSync(join(root, "tests/quicktest/tst_physical_input.qml"), "utf8");
    for (const name of ["panel_keyboard", "dropdown_keyboard", "dropdown_pointer",
        "searchable_keyboard", "searchable_pointer", "dialog_keyboard",
        "dialog_pointer", "world_map_pointer"])
        assert.match(source, new RegExp(`test_${name}`));
    assert.match(source, /SignalSpy/);
});

test("the real Panel consumes WorldMap selection through its inert-service boundary", () => {
    const panel = readFileSync(join(root, "Panel.qml"), "utf8");
    assert.match(panel, /WorldMap\s*\{[\s\S]*?onLocationSelected:\s*function\(location\)\s*\{\s*root\.chooseLocation\(location, service\.active\)\s*\}/);
});
