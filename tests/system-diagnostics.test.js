const { mkdtempSync, mkdirSync, readFileSync, writeFileSync, chmodSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { delimiter, join } = require("node:path");
const { spawnSync } = require("node:child_process");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");
const modelSource = readFileSync(join(root, "Model.js"), "utf8").replace(/^\.pragma library\s*/, "");
const moduleShim = { exports: {} };
new Function("module", "exports", modelSource)(moduleShim, moduleShim.exports);
const Model = moduleShim.exports;

function temporaryDirectory() {
    const directory = mkdtempSync(join(tmpdir(), "oma-mullvad-system-"));
    test.after(() => rmSync(directory, { recursive: true, force: true }));
    return directory;
}

function writeExecutable(path, contents) {
    writeFileSync(path, contents, { mode: 0o755 });
    chmodSync(path, 0o755);
}

test("System is a fifth tab and remains available without the CLI or daemon", () => {
    const panel = readFileSync(join(root, "Panel.qml"), "utf8");
    assert.match(panel, /model:\s*\["Overview", "Locations", "Advanced", "Excluded", "System"\]/);
    assert.match(panel, /function pageAvailable\(index\)\s*\{\s*return index === 0 \|\| index === 4 \|\| cliReady\s*\}/);
    assert.match(panel, /next = \(next \+ delta \+ 5\) % 5/);
    assert.match(panel, /text === "5"\) root\.showPage\(4\)/);
    assert.match(panel, /root\.pageIndex === 4 \? systemPage/);
});

test("diagnostic parsers return bounded plain text", () => {
    const daemon = Model.parseDaemonVersion("Current version: <b>2026.4</b>\nSupported: yes\n" + "x".repeat(10000));
    assert.equal(daemon.version, "2026.4");
    assert.equal(daemon.supported, true);

    const packages = Model.parsePackageInfo([
        "mullvad-vpn\t2026.4-1\tMullvad <b>VPN</b>\t2026-09-01 12:00",
        "mullvad-vpn-daemon\t" + "9".repeat(1000) + "\tDaemon\tunknown",
        ...Array.from({ length: 30 }, (_, index) => `other-${index}\t1\tOther\tnow`)
    ].join("\n"));
    assert.equal(packages.length, 2);
    assert.equal(packages[0].description, "Mullvad VPN");
    assert.ok(packages.every(item => item.name.length <= 128 && item.version.length <= 128));
    assert.ok(!JSON.stringify(packages).includes("<"));

    const updates = Model.parseUpdateCheck("mullvad-vpn 2026.4-1 -> <b>2026.5-1</b>\n" + "x".repeat(10000));
    assert.deepEqual(updates, ["mullvad-vpn 2026.4-1 -> 2026.5-1"]);
    assert.ok(updates.join("\n").length <= 4096);
});

test("package metadata helper only reads a bounded local package database", () => {
    const scratch = temporaryDirectory();
    const db = join(scratch, "local");
    mkdirSync(join(db, "mullvad-vpn-2026.4-1"), { recursive: true });
    mkdirSync(join(db, "unrelated-1.0-1"), { recursive: true });
    writeFileSync(join(db, "mullvad-vpn-2026.4-1", "desc"), [
        "%NAME%", "mullvad-vpn", "", "%VERSION%", "2026.4-1", "",
        "%DESC%", "Mullvad <b>VPN</b>", "", "%INSTALLDATE%", "1788264000", ""
    ].join("\n"));
    writeFileSync(join(db, "unrelated-1.0-1", "desc"), "%NAME%\nunrelated\n");

    const result = spawnSync("bash", [join(root, "scripts/mullvad-package-info")], {
        encoding: "utf8", env: { ...process.env, MULLVAD_PACMAN_LOCAL_DB: db }
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /^mullvad-vpn\t2026\.4-1\tMullvad VPN\t\d{4}-\d{2}-\d{2}/m);
    assert.ok(result.stdout.length <= 16384);
    assert.doesNotMatch(result.stdout, /unrelated|[<>]/);
});

test("update helper invokes only PATH-shadowed checkupdates and bounds results", () => {
    const scratch = temporaryDirectory();
    const bin = join(scratch, "bin");
    mkdirSync(bin);
    const log = join(scratch, "calls");
    writeExecutable(join(bin, "checkupdates"), `#!/usr/bin/env bash\nprintf 'checkupdates <%s>\\n' "$*" >> "$MOCK_LOG"\nprintf 'mullvad-vpn 2026.4-1 -> 2026.5-1\\nunrelated 1 -> 2\\n%s\\n' "$(printf 'x%.0s' {1..20000})"\n`);

    const result = spawnSync("bash", [join(root, "scripts/mullvad-update-check")], {
        encoding: "utf8",
        env: { ...process.env, PATH: bin + delimiter + process.env.PATH, MOCK_LOG: log }
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(log, "utf8"), "checkupdates <>\n");
    assert.equal(result.stdout, "mullvad-vpn 2026.4-1 -> 2026.5-1\n");
    assert.ok(result.stdout.length <= 4096);
});

test("System diagnostics contain no privileged or mutating package/service capability", () => {
    const files = ["Panel.qml", "Service.qml", "scripts/mullvad-package-info", "scripts/mullvad-update-check"];
    const source = files.map(file => readFileSync(join(root, file), "utf8")).join("\n");
    assert.doesNotMatch(source, /scripts\/install-mullvad|Install Mullvad VPN \(AUR\)|terminal/i);
    assert.doesNotMatch(source, /\b(?:sudo|pkexec|systemctl)\b|omarchy\s+pkg|pacman\s+-(?:S|R|U)|\b(?:yay|paru)\s+-(?:S|R|U)/i);
    assert.doesNotMatch(source, /\bcheckupdates\s+--(?:download|nosync)\b/);
});
