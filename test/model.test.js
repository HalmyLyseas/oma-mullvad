const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const source = readFileSync(join(__dirname, "..", "Model.js"), "utf8")
    .replace(/^\.pragma library\s*/, "");
const moduleShim = { exports: {} };
new Function("module", "exports", source)(moduleShim, moduleShim.exports);
const Model = moduleShim.exports;
const accountNumber = "1234".repeat(4);
const spacedAccountNumber = accountNumber.match(/.{4}/g).join(" ");

test("status JSON and listen events normalize connection details", () => {
    const status = Model.parseStatus([
        JSON.stringify({ state: "connecting" }),
        JSON.stringify({ type: "tunnel_state", value: {
            state: "connected",
            details: {
                location: {
                    country: "Finland", city: "Helsinki", ipv4: "1.2.3.4",
                    ipv6: null, hostname: "fi-hel-wg-001", entry_hostname: "se-sto-wg-001",
                    mullvad_exit_ip: true
                },
                locked_down: true
            }
        } })
    ].join("\n"));
    assert.equal(status.state, "connected");
    assert.equal(status.connected, true);
    assert.equal(status.location.city, "Helsinki");
    assert.equal(status.location.entryHostname, "se-sto-wg-001");
    assert.equal(status.lockedDown, true);

    // C1 (12-fable-review.md): `locked_down` is only present on the
    // `disconnected` TunnelState variant. When neither `details.locked_down`
    // nor `value.locked_down` is a boolean, lockedDown must be `undefined`
    // (not coerced to false) so Service.qml's `!== undefined` guard actually
    // leaves the last known lockdown state alone instead of clobbering it.
    assert.equal(Model.parseStatus({
        state: "connected",
        details: { location: { country: "Finland", city: "Helsinki" } }
    }).lockedDown, undefined);
    assert.equal(Model.parseStatus({
        state: "disconnected", details: { locked_down: false }
    }).lockedDown, false);

    assert.equal(Model.parseStatus({ state: "disconnecting", details: "nothing" }).disconnectingAction,
        "nothing");
    assert.equal(Model.parseStatus({ state: "disconnecting", details: "reconnect" }).disconnectingAction,
        "reconnect");
    assert.equal(Model.parseStatus({ state: "disconnecting", details: "not-a-real-action" }).disconnectingAction,
        "unknown");

    const tokenValue = "x".repeat(12);
    const failed = Model.parseStatus({ state: "error", details: { error: `token=${tokenValue} account ${accountNumber}` } });
    assert.ok(!failed.error.includes(tokenValue));
    assert.ok(!failed.error.includes(accountNumber));
});

const relayOutput = `Sweden (se)
\tGothenburg (got) @ 57.70887°N, 11.97456°W
\t\tse-got-wg-001 (185.65.134.66, 2a03:1b20:5:f011::a01f) - hosted by 31173 (Mullvad-owned)
\tStockholm (sto) @ 59.33258°N, 18.06490°W
\t\tse-sto-wg-001 (185.213.154.66) - hosted by M247 (rented)

Finland (fi)
\tHelsinki (hel) @ 60.16952°N, 24.93545°W
\t\tfi-hel-wg-001 (193.138.7.220) - hosted by DataPacket (rented)`;

test("relay list parses hierarchy, providers, ownership, and location search", () => {
    const relay = Model.parseRelayList(relayOutput);
    assert.equal(relay.countries.length, 2);
    assert.equal(relay.locations.length, 3);
    assert.deepEqual(relay.providers, ["31173", "DataPacket", "M247"]);
    assert.equal(relay.locations[0].servers[0].ownership, "owned");
    assert.equal(relay.locations[0].latitude, 57.70887);
    assert.equal(relay.locations[0].longitude, 11.97456);
    assert.equal(Model.filterLocations(relay, "M247")[0].key, "se-sto");
    assert.deepEqual(Model.filterLocations(relay.locations, "fi").map(item => item.key), ["fi-hel"]);
    assert.deepEqual(Model.filterLocations(relay, "", ["fi-hel", "se-sto"]).map(item => item.key),
        ["fi-hel", "se-sto", "se-got"]);
    assert.deepEqual(Model.filterLocations(relay, "se", ["se-sto"]).map(item => item.key),
        ["se-sto", "se-got"]);
    assert.deepEqual(Model.filterLocations(relay, "", [], { ownership: "owned" }).map(item => item.key),
        ["se-got"]);
    assert.deepEqual(Model.filterLocations(relay, "", [], {
        ownership: "rented", providers: ["M247"], ipVersion: "ipv4"
    }).map(item => item.key), ["se-sto"]);
    assert.deepEqual(Model.filterServers(relay.locations[1].servers, { ownership: "owned" }), []);
    assert.equal(Model.relayConstraintAvailable(relay, {
        type: "city", countryCode: "se", cityCode: "sto"
    }, { ownership: "owned" }), false);
    assert.equal(Model.relayConstraintAvailable(relay, {
        type: "hostname", countryCode: "se", cityCode: "sto", hostname: "se-sto-wg-001"
    }, { ownership: "rented", providers: ["M247"] }), true);
    const southern = Model.parseRelayList("Argentina (ar)\n\tBuenos Aires (bue) @ -34.47456°N, -58.66452°W");
    assert.equal(southern.locations[0].latitude, -34.47456);
    assert.equal(southern.locations[0].longitude, -58.66452);
});

test("favourites normalize, find, skip stale locations, wrap, and recents cap at five", () => {
    const favorites = Model.normalizeFavorites([
        "se-sto", "zz-zzz", "fi-hel", "se-sto", "de-ber", "us-nyc",
        "gb-lon", "fr-par", "nl-ams", "ca-tor", "au-syd", "jp-tyo"
    ]);
    assert.equal(favorites.length, 9);
    assert.equal(Model.findFavoriteIndex(favorites, { countryCode: "fi", cityCode: "hel" }), 2);
    const relay = Model.parseRelayList(relayOutput);
    assert.equal(Model.cycleFavorite(favorites, relay, "se-sto", 1).favorite.key, "fi-hel");
    assert.equal(Model.cycleFavorite(favorites, relay, "fi-hel", 1).favorite.key, "se-sto");
    assert.equal(Model.cycleFavorite(favorites, relay, "se-sto", -1).favorite.key, "fi-hel");
    assert.equal(Model.cycleFavorite(["zz-zzz"], relay, null, 1), null);

    const recent = Model.addRecent(["se-sto", "fi-hel", "de-ber", "gb-lon", "fr-par"], "fi-hel");
    assert.deepEqual(recent.map(item => item.key), ["fi-hel", "se-sto", "de-ber", "gb-lon", "fr-par"]);
});

test("relay getter constraints include filters and multihop entry", () => {
    const parsed = Model.parseRelayConstraints(`Generic constraints
    Location:               city sto, se
    Provider(s):            M247, DataPacket
    Ownership:              rented
WireGuard constraints
    IP protocol:            ipv4
    Multihop state:         enabled
    Multihop entry:         country fi`);
    assert.deepEqual(parsed.location, {
        type: "city", countryCode: "se", cityCode: "sto", hostname: ""
    });
    assert.deepEqual(parsed.providers, ["M247", "DataPacket"]);
    assert.equal(parsed.ownership, "rented");
    assert.equal(parsed.ipVersion, "ipv4");
    assert.equal(parsed.multihop, true);
    assert.equal(parsed.entry.countryCode, "fi");
    assert.deepEqual(Model.parseRelayConstraints("Location: hostname fi-hel-wg-001").location, {
        type: "hostname", countryCode: "fi", cityCode: "hel",
        hostname: "fi-hel-wg-001"
    });
    assert.equal(Model.parseRelayConstraints("Location: unsupported constraint").location.type, "unknown");
    assert.equal(Model.parseRelayConstraints("Ownership: Mullvad-owned servers").ownership, "owned");
    assert.equal(Model.parseRelayConstraints("Ownership: Rented servers").ownership, "rented");
    assert.equal(Model.parseRelayConstraints("IP protocol: malicious").ipVersion, "any");
});

test("account parser exposes expiry and device but never the account number", () => {
    const parsed = Model.parseAccount(`Mullvad account:    ${accountNumber}
Expires at:         2026-11-04 12:39:19 +02:00
Device name:        Wired Cow`, Date.parse("2026-11-03T12:39:19+02:00"));
    assert.deepEqual(parsed, {
        loggedIn: true,
        expiresAt: "2026-11-04 12:39:19 +02:00",
        expiryMs: Date.parse("2026-11-04T12:39:19+02:00"),
        daysRemaining: 1,
        deviceName: "Wired Cow"
    });
    assert.ok(!JSON.stringify(parsed).includes(accountNumber));
    assert.equal(Model.parseAccount("Not logged in").loggedIn, false);
});

test("toggles and DNS getter/default/custom commands round-trip supported settings", () => {
    assert.equal(Model.parseToggle("Lockdown mode: on"), true);
    assert.equal(Model.parseToggle("Local network sharing: block"), false);
    assert.equal(Model.parseToggle("unknown"), null);
    // F3 (D3 fix): a trailing hint/help line must never override the value
    // that actually followed the first "key:" -- the line-anchored match
    // wins over the old last-match-anywhere fallback.
    assert.equal(Model.parseToggle("Autoconnect: on\nHint: … off by default"), true);

    const dns = Model.parseDns(`Custom DNS: yes
Servers: 1.1.1.1, 2606:4700:4700::1111
Block ads: false
Block trackers: true
Block malware: true
Block adult content: false
Block gambling: false
Block social media: true`);
    assert.equal(dns.mode, "custom");
    assert.deepEqual(dns.customServers, ["1.1.1.1", "2606:4700:4700::1111"]);
    assert.equal(dns.blockTrackers, true);
    assert.deepEqual(Model.argv("dnsDefault", { flags: { blockAds: true, blockMalware: true } }),
        ["mullvad", "dns", "set", "default", "--block-ads", "--block-malware"]);
    assert.deepEqual(Model.argv("dnsCustom", { servers: ["1.1.1.1", "2606:4700:4700::1111"] }),
        ["mullvad", "dns", "set", "custom", "1.1.1.1", "2606:4700:4700::1111"]);
    assert.throws(() => Model.argv("dnsCustom", { servers: ["1.2.3.999"] }), /Invalid/);
});

test("anti-censorship and excluded PID output parsers", () => {
    const anti = Model.parseAntiCensorship(`mode: udp2tcp
udp2tcp settings: port 443
shadowsocks settings: any port
wireguard-port settings: port 53
lwo settings: any port`);
    assert.deepEqual(anti, {
        mode: "udp2tcp", udp2tcpPort: "443", shadowsocksPort: "any",
        wireguardPort: "53", lwoPort: "any"
    });
    assert.equal(Model.parseAntiCensorship("udp2tcp settings: port 99999").udp2tcpPort, "any");

    assert.deepEqual(Model.parseExcludedPids(`Excluded PIDs:
  1234: /usr/bin/firefox
  5678 /opt/App/app --flag`), [
        { pid: 1234, command: "/usr/bin/firefox" },
        { pid: 5678, command: "/opt/App/app --flag" }
    ]);
});

test("T2: parseCliVersion/parseDaemonVersion match real mullvad CLI output shapes", () => {
    // Recorded live on this box (16-s8-feedback-spec.md PM research):
    // `mullvad --version` -> "mullvad-cli 2026.4"; `mullvad version` ->
    // the 3-line "Current version / Is supported / Suggested upgrade"
    // report (with real-world padding before the colon).
    assert.equal(Model.parseCliVersion("mullvad-cli 2026.4\n"), "2026.4");
    assert.equal(Model.parseCliVersion(""), "");

    const daemon = Model.parseDaemonVersion(
        "Current version       : 2026.4\n" +
        "Is supported          : true\n" +
        "Suggested upgrade     : none\n");
    assert.deepEqual(daemon, { version: "2026.4", supported: true, suggestedUpgrade: "" });

    const outdated = Model.parseDaemonVersion(
        "Current version: 2026.3\nIs supported: false\nSuggested upgrade: 2026.4\n");
    assert.deepEqual(outdated, { version: "2026.3", supported: false, suggestedUpgrade: "2026.4" });

    assert.equal(Model.parseDaemonVersion("").supported, null);
});

test("T2: parsePackageInfo only accepts the two known Mullvad package names, bounds fields", () => {
    const packages = Model.parsePackageInfo(
        "mullvad-vpn\t2026.4-1\t1787763238\t1786971553\n" +
        "mullvad-vpn-daemon\t2026.4-1\t1787763238\t1786971553\n" +
        "some-other-pkg\t9.9-9\t1\t1\n");
    assert.equal(packages.length, 2);
    assert.equal(packages[0].name, "mullvad-vpn");
    assert.equal(packages[0].version, "2026.4-1");
    assert.equal(packages[0].installedAt, new Date(1787763238 * 1000).toISOString());
    assert.equal(packages[0].buildAt, new Date(1786971553 * 1000).toISOString());
    assert.equal(packages[1].name, "mullvad-vpn-daemon");

    // Missing/zero dates degrade to "" rather than an Invalid Date string.
    assert.equal(Model.parsePackageInfo("mullvad-vpn\t2026.4-1\t0\t0\n")[0].installedAt, "");
    assert.equal(Model.parsePackageInfo("").length, 0);
    assert.equal(Model.parsePackageInfo("mullvad-vpn\tonly-two-fields\n").length, 0);
});

test("T2: parseUpdateCheck filters to the allowlisted package names only", () => {
    const targets = Model.parseUpdateCheck(
        "openai-codex-desktop\t26.820.71523-1\t26.820.80927-1\n" +
        "mullvad-vpn\t2026.3-1\t2026.4-1\n" +
        "mullvad-vpn-daemon\t2026.3-1\t2026.4-1\n");
    assert.equal(targets.length, 2);
    assert.deepEqual(targets[0], { name: "mullvad-vpn", current: "2026.3-1", latest: "2026.4-1" });
    assert.equal(Model.parseUpdateCheck("").length, 0);
    assert.equal(Model.parseUpdateCheck("openai-codex-desktop\t1\t2\n").length, 0);
});

test("T2: relativeTimeMs renders a live-countable label or \"never\"", () => {
    const now = Date.parse("2026-08-29T12:00:00Z");
    assert.equal(Model.relativeTimeMs(0, now), "never");
    assert.equal(Model.relativeTimeMs(now - 5000, now), "just now");
    assert.equal(Model.relativeTimeMs(now - 5 * 60000, now), "5m ago");
    assert.equal(Model.relativeTimeMs(now - 3 * 3600000, now), "3h ago");
    assert.equal(Model.relativeTimeMs(now - 2 * 86400000, now), "2d ago");
});

test("trust-boundary validation accepts useful values and rejects malformed input", () => {
    assert.equal(Model.validatePort(53), true);
    assert.equal(Model.validatePort(0), false);
    assert.equal(Model.validatePort(65536), false);
    assert.equal(Model.validateFavoriteIndex(1), true);
    assert.equal(Model.validateFavoriteIndex(10), false);
    assert.equal(Model.validateDnsAddress("192.0.2.1"), true);
    assert.equal(Model.validateDnsAddress("2001:db8::1"), true);
    assert.equal(Model.validateDnsAddress("2001:::1"), false);
    assert.equal(Model.validateLocationCode("se", "country"), true);
    assert.equal(Model.validateLocationCode("sto", "city"), true);
    assert.equal(Model.validateLocationCode("SWE", "country"), false);
});

test("argv builder covers tunnel, relay, anti-censorship, and exclusions", () => {
    const cases = [
        ["version", {}, ["mullvad", "--version"]],
        ["connect", {}, ["mullvad", "connect"]],
        ["disconnect", {}, ["mullvad", "disconnect"]],
        ["reconnect", {}, ["mullvad", "reconnect"]],
        ["login", {}, ["mullvad", "account", "login"]],
        ["location", { country: "SE", city: "sto" }, ["mullvad", "relay", "set", "location", "se", "sto"]],
        ["location", { country: "se", city: "sto", hostname: "se-sto-wg-001" }, ["mullvad", "relay", "set", "location", "se", "sto", "se-sto-wg-001"]],
        ["providers", { providers: ["M247", "DataPacket"] }, ["mullvad", "relay", "set", "provider", "M247", "DataPacket"]],
        ["providers", { providers: [] }, ["mullvad", "relay", "set", "provider", "any"]],
        ["ownership", { ownership: "owned" }, ["mullvad", "relay", "set", "ownership", "owned"]],
        ["ipVersion", { ipVersion: "ipv6" }, ["mullvad", "relay", "set", "ip-version", "ipv6"]],
        ["multihop", { enabled: true }, ["mullvad", "relay", "set", "multihop", "on"]],
        ["entryLocation", { country: "fi", city: "hel" }, ["mullvad", "relay", "set", "entry", "location", "fi", "hel"]],
        ["lockdown", { enabled: false }, ["mullvad", "lockdown-mode", "set", "off"]],
        ["autoConnect", { enabled: true }, ["mullvad", "auto-connect", "set", "on"]],
        ["lanSharing", { enabled: true }, ["mullvad", "lan", "set", "allow"]],
        ["antiCensorshipMode", { mode: "quic" }, ["mullvad", "anti-censorship", "set", "mode", "quic"]],
        ["antiCensorshipPort", { mode: "udp2tcp", port: 443 }, ["mullvad", "anti-censorship", "set", "udp2tcp", "--port", "443"]],
        ["excludedPidDelete", { pid: 1234 }, ["mullvad", "split-tunnel", "delete", "1234"]],
        ["launchExcluded", { desktopId: "org.mozilla.firefox.desktop" }, ["mullvad-exclude", "uwsm-app", "--", "gtk-launch", "org.mozilla.firefox.desktop"]]
    ];
    for (const [action, params, expected] of cases)
        assert.deepEqual(Model.argv(action, params), expected, action);

    assert.throws(() => Model.argv("login", { accountNumber }), /stdin/);
    assert.throws(() => Model.argv("location", { country: "se;reboot" }), /country/);
    assert.throws(() => Model.argv("antiCensorshipPort", { mode: "udp2tcp", port: 70000 }), /port/);
    assert.throws(() => Model.argv("launchExcluded", { desktopId: "x; reboot" }), /application/);

    // F4 (D5 fix): a leading "-" must never reach argv-bound values --
    // safeArg() rejects it directly (providers is one of its callers), and
    // launchExcluded's desktop-id regex independently requires the string
    // to start with an alphanumeric.
    assert.throws(() => Model.argv("providers", { providers: ["-x"] }), /provider/);
    assert.throws(() => Model.argv("launchExcluded", { desktopId: "-firefox.desktop" }), /application/);
    assert.throws(() => Model.argv("launchExcluded", { desktopId: ".firefox.desktop" }), /application/);
    assert.throws(() => Model.argv("launchExcluded", { desktopId: "_firefox.desktop" }), /application/);
    // F4: dot-separated "." / ".." segments (path-traversal-shaped) are
    // rejected even when the string otherwise starts with an alphanumeric
    // and would pass the base charset check.
    assert.throws(() => Model.argv("launchExcluded", { desktopId: "org...mozilla.desktop" }), /application/);
    assert.throws(() => Model.argv("launchExcluded", { desktopId: "org.mozilla.." }), /application/);
    // Ordinary reverse-DNS desktop IDs (the only real-world shape) still work.
    assert.deepEqual(Model.argv("launchExcluded", { desktopId: "org.mozilla.firefox.desktop" }),
        ["mullvad-exclude", "uwsm-app", "--", "gtk-launch", "org.mozilla.firefox.desktop"]);
});

test("redaction removes account and token-like secrets", () => {
    const tokenValue = "x".repeat(16);
    const bearerValue = ["abc", "def", "ghi"].join(".");
    const passwordValue = "hunter" + 2;
    const safe = Model.redact(`${spacedAccountNumber} token=${tokenValue} Bearer ${bearerValue} password: ${passwordValue}`);
    assert.ok(!safe.includes("1234"));
    assert.ok(!safe.includes(tokenValue));
    assert.ok(!safe.includes(bearerValue));
    assert.ok(!safe.includes(passwordValue));
    assert.match(safe, /redacted/);
});

test("external records and fields are bounded before reaching QML models", () => {
    const lines = ["<b>Testland</b> (zz)", "\t<b>First city</b> (000) @ 1°N, 1°E"];
    for (let i = 0; i < 140; i++)
        lines.push(`\t\tzz-000-wg-${String(i).padStart(3, "0")} (192.0.2.1) - hosted by <i>Provider</i> (rented)`);
    for (let i = 1; i < 520; i++) {
        const code = i.toString(36).padStart(3, "0");
        lines.push(`\tCity ${i} (${code}) @ 1°N, 1°E`);
    }

    const relays = Model.parseRelayList(lines.join("\n"));
    assert.equal(relays.locations.length, 512);
    assert.equal(relays.locations[0].servers.length, 128);
    assert.equal(relays.locations[0].country, "Testland");
    assert.equal(relays.locations[0].servers[0].provider, "Provider");

    const excluded = Model.parseExcludedPids(Array.from({ length: 300 }, (_, i) =>
        `${i + 1}: <b>${"x".repeat(700)}</b>`).join("\n"));
    assert.equal(excluded.length, 256);
    assert.ok(excluded[0].command.length <= 512);
    assert.ok(!excluded[0].command.includes("<"));

    const status = Model.parseStatus({
        state: "<b>connected</b>",
        details: { location: { country: "<b>Finland</b>", ipv4: "999.1.1.1", hostname: "bad host" } }
    });
    assert.equal(status.state, "unknown");
    assert.equal(status.location.country, "Finland");
    assert.equal(status.location.ipv4, "");
    assert.equal(status.location.hostname, "");
    assert.equal(Model.parseRelayConstraints("Location: hostname bad/host").location.type, "unknown");

    const dns = Model.parseDns("Servers: " + Array.from({ length: 20 }, (_, i) => `192.0.2.${i + 1}`).join(", "));
    assert.equal(dns.customServers.length, 16);
});
