const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const vm = require("node:vm");
const test = require("node:test");
const assert = require("node:assert/strict");

const rootDir = join(__dirname, "..");
const read = file => readFileSync(join(rootDir, file), "utf8");
const model = vm.createContext({});
vm.runInContext(read("Model.js").replace(/^\.pragma library\s*/, ""), model);
const plain = value => JSON.parse(JSON.stringify(value));

function methods(file, indent, values = {}) {
    const context = vm.createContext({ Model: model, ...values });
    context.root = context;
    const source = read(file);
    const pattern = new RegExp(`^${" ".repeat(indent)}function (\\w+)\\(([^\\n]*)\\)(?:: \\w+)? \\{`, "gm");
    for (const match of source.matchAll(pattern)) {
        const start = match.index + match[0].length;
        const inline = source.slice(start, source.indexOf("\n", start));
        const end = inline.includes("}") ? start + inline.lastIndexOf("}")
            : source.indexOf(`\n${" ".repeat(indent)}}`, start);
        assert.ok(end >= start, `function boundary for ${match[1]}`);
        const args = match[2].replace(/: \w+/g, "");
        vm.runInContext(`function ${match[1]}(${args}) {${source.slice(start, end)}}`, context);
    }
    return context;
}

function serviceContext() {
    return methods("Service.qml", 2, {
        installed: true, daemonRunning: false, connected: false, state: "unavailable",
        lastError: "", actionStatus: "", locations: [], _pendingStatusSeq: 2,
        _statusApplySeq: 0, _statusSeq: 2, _listenerOverflowed: false, listenerProcess: { running: false },
        listenerRestart: { stop() {} }
    });
}

test("successful status polls reject malformed payloads before claiming readiness", () => {
    for (const raw of ["garbage", "null", "[]", "{}", '{"state":"invented"}',
        '{"state":"connected","details":7}', '{"state":"connected","details":[]}',
        '{"state":"connected","details":null}', '{"state":"connected","details":{"location":"bad"}}']) {
        const service = serviceContext();
        service._applyRead("status", raw, "", 0);
        assert.equal(service.daemonRunning, false, raw);
        assert.match(service.lastError, /Could not parse Mullvad status/, raw);
        assert.equal(service.listenerProcess.running, false, raw);
    }
    for (const state of ["connected", "connecting", "disconnecting", "disconnected", "error", "blocked"]) {
        const service = serviceContext();
        service._applyRead("status", JSON.stringify({ state, details: {} }), "", 0);
        assert.equal(service.state, state);
        assert.equal(service.daemonRunning, true);
        assert.equal(service.lastError, "");
    }
    for (const action of ["nothing", "block", "reconnect"]) {
        const service = serviceContext();
        service._applyRead("status", JSON.stringify({ state: "disconnecting", details: action }), "", 0);
        assert.equal(service.disconnectingAction, action);
        assert.equal(service.daemonRunning, true);
    }
});

test("stale malformed and failed polls cannot disturb newer listener truth", () => {
    const service = serviceContext();
    service._applyListenerLine('{"state":"connected","details":{}}', false);
    assert.equal(service.daemonRunning, true);
    service._ensureListener = () => assert.fail("stale poll restarted listener");
    for (const [raw, code] of [["garbage", 0], ["", 1]]) {
        service._applyRead("status", raw, "failed", code);
        assert.equal(service.state, "connected");
        assert.equal(service.daemonRunning, true);
        assert.equal(service.lastError, "");
    }
});

test("listener classification rejects non-string states without coercion", () => {
    for (const state of [{ toString: null }, ["connected"], 1, true, null,
        { toString() { throw new Error("must not coerce"); } }]) {
        assert.equal(model.isTunnelStateEvent({ state }), false);
        assert.equal(model.isTunnelStateEvent(JSON.stringify({ state })), false);
    }
});

test("malformed listener lines cannot interrupt a chunk or consume sequence numbers", () => {
    const service = serviceContext();
    service.listenerLineChars = 65536;
    service._applyListenerLine('{"state":"connected","details":{}}', false);
    const seq = service._statusSeq;
    for (const line of ['{"state":{"toString":null}}', '{"state":["connected"]}',
        '{"settings":{}}', '{"relay_list":{"countries":[]}}', 'not json',
        '{"state":"connected","details":7}']) {
        service._appendListenerChunk(line + "\n", false);
        assert.equal(service._statusSeq, seq, line);
        assert.equal(service._statusApplySeq, seq, line);
        assert.equal(service.state, "connected", line);
    }
    service._appendListenerChunk('{"state":{"toString":null}}\n{"state":"disconnected","details":{}}\n', false);
    assert.equal(service.state, "disconnected");
    assert.equal(service.connected, false);
    assert.equal(service._statusSeq, seq + 1);
    assert.equal(service._statusApplySeq, seq + 1);
    service._applyRead("status", '{"state":"connected","details":{}}', "", 0);
    assert.equal(service.state, "disconnected", "older polls stay stale");
});

test("listener classification failures stay inside the per-line exception boundary", () => {
    const service = serviceContext();
    const seq = service._statusSeq;
    service.listenerLineChars = 65536;
    service.Model = { ...model, isTunnelStateEvent(raw) {
        if (raw === "throw") throw new Error("classification failed");
        return model.isTunnelStateEvent(raw);
    } };
    service._appendListenerChunk('throw\n{"state":"disconnected","details":{}}\n', false);
    assert.match(service.lastError, /classification failed/);
    assert.equal(service.state, "disconnected");
    assert.equal(service._statusSeq, seq + 1);
    assert.equal(service._statusApplySeq, seq + 1);
});

test("daemon-down service actions reject centrally while read probes remain usable", () => {
    const service = serviceContext();
    const commands = [];
    service.busy = false;
    service.locations = [{ countryCode: "se", code: "got", servers: [{ hostname: "se-got-wg-001", ownership: "owned", provider: "Example", ips: ["192.0.2.1"] }] }];
    service.relayConstraints = { location: {}, providers: [], ownership: "any", ipVersion: "any" };
    service._enqueueAction = command => { if (command) commands.push(plain(command)); return !!command; };
    service._armAction = command => commands.push(plain(command));
    service.Quickshell = { execDetached: command => commands.push(plain(command)) };
    for (const action of [() => service.connectTunnel(), () => service.disconnectTunnel(),
        () => service.setLockdown(true), () => service.setDnsCustom("1.1.1.1"),
        () => service.logout(), () => service.login("0".repeat(16)),
        () => service.launchExcludedApp("one.desktop"), () => service.removeExcludedPid(12)]) {
        action();
        assert.equal(commands.length, 0);
        assert.match(service.lastError, /Mullvad daemon unavailable/);
        assert.equal(service.actionStatus, service.lastError);
    }
    const reads = [];
    service._enqueueRead = (kind, argv) => reads.push([kind, plain(argv)]);
    service.refreshAll();
    assert.deepEqual(reads, [["probe", ["/usr/bin/env", "mullvad", "--version"]]]);
    service.daemonRunning = true;
    service.setLockdown(true);
    assert.deepEqual(commands, [["mullvad", "lockdown-mode", "set", "on"]]);
});

test("status refresh re-probes CLI installation when either readiness flag is false", () => {
    const service = serviceContext();
    for (const [installed, daemonRunning] of [[true, false], [false, false], [false, true], [true, true]]) {
        const reads = [];
        service.installed = installed;
        service.daemonRunning = daemonRunning;
        service._enqueueRead = (kind, command) => reads.push(kind);
        service.refreshStatus();
        assert.deepEqual(reads, installed && daemonRunning ? ["status"] : ["probe"]);
    }
});

test("persisted favorites stop scanning at 256 even behind invalid entries", () => {
    const values = Array(100000).fill(null);
    values[256] = "se-sto";
    assert.equal(model.normalizeFavorites(values).length, 0);
    values[255] = "se-got";
    assert.deepEqual(plain(model.normalizeFavorites(values)).map(v => v.key), ["se-got"]);
    assert.equal(model.normalizeFavorites(Array.from({ length: 20 }, (_, i) => `se-a${String(i).padStart(2, "0")}`)).length, 9);
    assert.equal(model.addRecent(values, "se-sto").length, 2);
});

test("Panel bounds settings copies without truncating the 512-location catalogue", () => {
    const panel = methods("Panel.qml", 2, { bar: null });
    const values = Array.from({ length: 100000 }, (_, i) => i);
    assert.equal(panel.arrayFrom(values).length, 256);
    assert.equal(panel.arrayFrom({ length: Infinity }).length, 256);
    assert.equal(panel.arrayFrom("string").length, 0);
    panel.service = { locations: Array.from({ length: 512 }, (_, i) => ({ countryCode: "se", cityCode: String(i) })) };
    assert.equal(panel.locationFor({ countryCode: "se", cityCode: "511" }).cityCode, "511");
    panel.persistCollections(["se-sto", "se-sto"], ["se-got"]);
    assert.equal(panel.favoriteLocations.length, 1);
    assert.equal(panel.recentLocations.length, 1);
});

test("stale Panel settings merge the current scoped widget settings", () => {
    let saved;
    const panel = methods("Panel.qml", 2, {
        moduleName: "io.github.kallupx.oma-mullvad",
        bar: { shell: { updateEntryInline(id, entry) { saved = plain(entry); } } },
        settings: { refreshIntervalSec: 30, siblingValue: "old" },
        hostWidget: { settings: { refreshIntervalSec: 99, siblingValue: "fresh", other: true } }
    });
    panel.persistCollections(["se-sto"], ["se-got"]);
    assert.equal(saved.refreshIntervalSec, 99);
    assert.equal(saved.siblingValue, "fresh");
    assert.equal(saved.other, true);
});

test("unavailable pages and text shortcuts never dispatch mutations", () => {
    const calls = [];
    const panel = methods("Panel.qml", 2, {
        cliReady: false, pageIndex: 0, keyCatcher: null, Qt: { callLater() {} },
        service: { refreshAll() { calls.push("refresh"); }, toggleTunnel() { calls.push("toggle"); } }
    });
    panel.cycleFavorite = () => calls.push("favorite");
    assert.equal(panel.pageAvailable(0), true);
    for (const index of [1, 2, 3]) {
        assert.equal(panel.pageAvailable(index), false);
        panel.showPage(index);
        assert.equal(panel.pageIndex, 0);
    }
    panel.movePage(1);
    assert.equal(panel.pageIndex, 0);
    for (const key of ["t", "T", "n", "N", "p", "P"]) panel.handleTextKey(key);
    assert.deepEqual(calls, []);
    panel.handleTextKey("r");
    assert.deepEqual(calls, ["refresh"]);
    panel.cliReady = true;
    panel.showPage(3);
    assert.equal(panel.pageIndex, 3);
    panel.movePage(1);
    assert.equal(panel.pageIndex, 0);
});

test("unavailable UI has no embedded package installation launcher", () => {
    const panel = read("Panel.qml");
    assert.doesNotMatch(panel, /omarchy pkg aur|Install Mullvad VPN \(AUR\)|omarchy-launch-floating-terminal/);
    assert.match(panel, /Install Mullvad separately/);
});

test("bar right click is guarded before calling the service", () => {
    const source = read("BarWidget.qml");
    const body = source.match(/onPressed: function\(buttonCode\) \{([\s\S]*?)\n    \}/)[1];
    for (const [installed, daemonRunning] of [[false, false], [true, false]]) {
        let calls = 0;
        const root = { svc: { installed, daemonRunning, toggleTunnel() { calls++; } } };
        vm.runInNewContext(body, { root, buttonCode: 2, Qt: { RightButton: 2, MiddleButton: 4 } });
        assert.equal(calls, 0);
    }
});
