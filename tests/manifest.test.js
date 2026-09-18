const test = require("node:test");
const assert = require("node:assert/strict");
const manifest = require("../manifest.json");

test("takeover manifest retains the upstream identity and compatible version", () => {
    assert.equal(manifest.id, "io.github.kallupx.oma-mullvad");
    assert.equal(manifest.version, "1.4.6");
    assert.deepEqual(manifest.kinds, ["service", "bar-widget"]);
    assert.equal(manifest.keepLoaded, true);
    assert.equal(manifest.entryPoints.service, "Service.qml");
    assert.equal(manifest.entryPoints.barWidget, "BarWidget.qml");
    assert.equal(manifest.entryPoints.menu, undefined);
});
