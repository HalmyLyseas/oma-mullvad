const { readdirSync, readFileSync } = require("node:fs");
const { join, extname } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");

function sources(directory) {
    const result = [];
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
        if ([".git", ".hermes", "exchange", "node_modules", "fixtures"].includes(entry.name)) continue;
        const path = join(directory, entry.name);
        if (entry.isDirectory()) result.push(...sources(path));
        else if (entry.isFile() && ["", ".js", ".mjs", ".qml", ".sh", ".yml"].includes(extname(path))) result.push(path);
    }
    return result;
}

test("code comment blocks stay within two lines in checkout and archive", () => {
    const violations = [];
    for (const path of sources(root)) {
        let run = 0;
        const lines = readFileSync(path, "utf8").split("\n");
        lines.forEach((line, index) => {
            const comment = /^\s*(?:\/\/|#(?!\!))/.test(line);
            run = comment ? run + 1 : 0;
            if (run === 3) violations.push(`${path}:${index - 1}`);
        });
    }
    assert.deepEqual(violations, []);
});
