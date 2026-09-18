const test = require("node:test");
const assert = require("node:assert/strict");
const manifest = require("../manifest.json");

test("release candidate declares the maintained fork identity and author", () => {
    assert.equal(manifest.id, "halmylyseas.oma-mullvad");
    assert.equal(manifest.author, "HalmyLyseas");
    assert.equal(manifest.version, "1.5-rc");
    assert.deepEqual(manifest.kinds, ["service", "bar-widget"]);
    assert.equal(manifest.keepLoaded, true);
    assert.equal(manifest.entryPoints.service, "Service.qml");
    assert.equal(manifest.entryPoints.barWidget, "BarWidget.qml");
    assert.equal(manifest.entryPoints.menu, undefined);
});
