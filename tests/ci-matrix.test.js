const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");
const workflow = readFileSync(join(root, ".github/workflows/test.yml"), "utf8");
const ciLocal = readFileSync(join(root, "tests/ci-local"), "utf8");
const uiRunner = readFileSync(join(root, "tests/probe/run-ui"), "utf8");

test("CI validates exact Omarchy 4.0.3 and 4.0.4 tags", () => {
    assert.match(workflow, /matrix:[\s\S]*omarchy:[^\n]*v4\.0\.3[^\n]*v4\.0\.4/);
    assert.match(workflow, /git clone --depth 1 --branch "\$\{\{ matrix\.omarchy \}\}" https:\/\/github\.com\/basecamp\/omarchy\.git/);
    assert.match(workflow, /describe --tags --exact-match/);
    assert.doesNotMatch(workflow, /pacman -Swdd --noconfirm omarchy/);
});

test("local gate and UI runner share overridable Omarchy sources", () => {
    assert.match(ciLocal, /OMARCHY_SHELL_DIR:-\/usr\/share\/omarchy\/shell/);
    assert.match(ciLocal, /OMARCHY_PLUGIN_VALIDATOR/);
    assert.match(uiRunner, /OMARCHY_SHELL_DIR:-\/usr\/share\/omarchy\/shell/);
    assert.doesNotMatch(ciLocal, /-I \/usr\/share\/omarchy\/shell/);
    assert.doesNotMatch(uiRunner, /ln -s \/usr\/share\/omarchy\/shell/);
});
