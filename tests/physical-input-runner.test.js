const { readFileSync, statSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");

function source(path) {
    return readFileSync(join(root, path), "utf8");
}

test("physical Qt Quick Test runner resolves the Arch binary and fails closed", () => {
    const runner = source("test/quicktest/run");
    assert.match(runner, /command -v qmltestrunner/);
    assert.match(runner, /\/usr\/lib\/qt6\/bin\/qmltestrunner/);
    assert.match(runner, /requires qmltestrunner/);
    assert.ok(statSync(join(root, "test/quicktest/run")).mode & 0o111);
});

test("physical Qt Quick Test runner keeps a verified allowlisted PATH", () => {
    const runner = source("test/quicktest/run");
    assert.match(runner, /trusted_system_path='?\/usr\/bin:\/bin'?/);
    assert.doesNotMatch(runner, /PATH="\$[^"\n]*:\$PATH"/);
    assert.match(runner, /readlink -f/);
    assert.match(runner, /plugin_dir\/test\/mocks\/\$executable/);
});

test("physical Qt Quick Test runner preserves an inherited Wayland socket", () => {
    const runner = source("test/quicktest/run");
    assert.match(runner, /WAYLAND_DISPLAY/);
    assert.match(runner, /XDG_RUNTIME_DIR[^\n]*WAYLAND_DISPLAY|WAYLAND_DISPLAY[^\n]*XDG_RUNTIME_DIR/);
});

test("physical Qt Quick Test runner bounds diagnostics and rejects timeout or failure", () => {
    const runner = source("test/quicktest/run");
    assert.match(runner, /command_status=\$\?/);
    assert.match(runner, /head -c 65536/);
    assert.match(runner, /timeout/);
    assert.match(runner, /pgrep/);
});

test("the main and clean-archive gates inventory physical Qt Quick Tests", () => {
    assert.match(source("test/all"), /test\/quicktest\/run/);
    const gate = source("test/ci-local");
    assert.match(gate, /test\/quicktest\/run/);
    assert.match(gate, /test\/quicktest\/tst_physical_input\.qml/);
});

test("CI installs the Arch qmltestrunner provider for both exact Omarchy versions", () => {
    const workflow = source(".github/workflows/test.yml");
    assert.match(workflow, /qt6-declarative/);
    assert.match(workflow, /omarchy: \[v4\.0\.3, v4\.0\.4\]/);
});

test("developer docs name the Arch qmltestrunner provider and binary", () => {
    const docs = source("docs/developers.md");
    assert.match(docs, /qt6-declarative/);
    assert.match(docs, /\/usr\/lib\/qt6\/bin\/qmltestrunner/);
});
