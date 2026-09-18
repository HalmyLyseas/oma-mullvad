#!/usr/bin/env node

const [json, ...clauses] = process.argv.slice(2);
if (!json || clauses.length === 0 || clauses.length % 3 !== 0)
    process.exit(2);

let value;
try {
    value = JSON.parse(json);
} catch (_) {
    process.exit(1);
}

function field(object, path) {
    return path.split(".").reduce((current, key) =>
        current !== null && current !== undefined ? current[key] : undefined, object);
}

for (let i = 0; i < clauses.length; i += 3) {
    const [path, operation, expected] = clauses.slice(i, i + 3);
    const actualValue = field(value, path);
    const actual = actualValue === null || actualValue === undefined ? "" : String(actualValue);
    const left = Number(actual);
    const right = Number(expected);
    let passed = false;
    if (operation === "eq") passed = actual === expected;
    else if (operation === "ieq") passed = actual.toLowerCase() === expected.toLowerCase();
    else if (operation === "contains") passed = actual.includes(expected);
    else if (operation === "empty") passed = actual === "";
    else if (operation === "nonempty") passed = actual !== "";
    else if (operation === "gt") passed = Number.isFinite(left) && Number.isFinite(right) && left > right;
    else if (operation === "ge") passed = Number.isFinite(left) && Number.isFinite(right) && left >= right;
    else if (operation === "lt") passed = Number.isFinite(left) && Number.isFinite(right) && left < right;
    else if (operation === "le") passed = Number.isFinite(left) && Number.isFinite(right) && left <= right;
    else process.exit(2);
    if (!passed) process.exit(1);
}
