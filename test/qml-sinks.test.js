const { readFileSync, readdirSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

// test/qml-sinks.test.js -- moved out of test/bounded-command.test.js by the
// S10 Process rework (23-s10-native-process-spec.md), which removed
// scripts/bounded-command (and with it, that file's other two tests: they
// exercised the wrapper directly, which no longer exists -- every `mullvad`
// invocation is now a direct Quickshell Process child, see Service.qml).
// This is the one test from that file that was never about the wrapper:
// the plugin-wide QML Text-sink audit (CLAUDE.md rule 3 -- every local
// Text{} sink must be textFormat: Text.PlainText, since remote/relay
// strings are rendered there and must never be interpreted as rich text).
test("every local QML Text sink is explicitly plain text", () => {
    const root = join(__dirname, "..");
    for (const file of readdirSync(root).filter(name => name.endsWith(".qml"))) {
        const lines = readFileSync(join(root, file), "utf8").split("\n");
        for (let i = 0; i < lines.length; i++) {
            if (/\bText\s*\{/.test(lines[i]))
                assert.match(lines.slice(i + 1, i + 4).join("\n"), /textFormat:\s*Text\.PlainText/, `${file}:${i + 1}`);
        }
    }
});
