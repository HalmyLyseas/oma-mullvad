const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const read = path => readFileSync(join(__dirname, '..', path), 'utf8');

test('probe boundary has no host fallback and verifies inert launchers', () => {
    const boundary = read('test/probe/isolate');
    assert.match(boundary, /readlink -f/);
    assert.match(boundary, /mullvad-exclude/);
    assert.match(boundary, /uwsm-app gtk-launch gio xdg-open/);
    assert.match(boundary, /XDG_RUNTIME_DIR/);
    assert.match(boundary, /XDG_CONFIG_HOME/);
    assert.doesNotMatch(boundary, /PATH=.*:\$PATH/);
    assert.match(read('test/probe/run'), /source.*isolate/);
    assert.doesNotMatch(read('test/probe/run'), /skipped: qs/);
});

test('automated CLI contract uses a verified mock wrapper', () => {
    assert.match(read('test/all'), /tests\/run-cli-contract/);
    assert.match(read('tests/run-cli-contract'), /command -v mullvad/);
    assert.match(read('tests/run-cli-contract'), /readlink -f/);
});

test("all QML probe timeouts escalate if graceful shutdown stalls", () => {
    for (const runner of ["run", "run-ui", "run-settings"])
        assert.match(read("test/probe/" + runner), /"\$timeout_bin" -k 2 20/);
});
