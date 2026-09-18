# Developer notes

## Architecture

| File | Responsibility |
|---|---|
| `manifest.json` | Declares the `service` and `bar-widget` entry points and keeps the service loaded across widget reloads. |
| `Service.qml` | Owns shared Mullvad state, polling, the status listener, action queues, read-only System diagnostics, deadlines, output bounds, and excluded-process resolution. |
| `BarWidget.qml` | Resolves only this plugin's service through the scoped bar facade, renders state, and loads `Panel.qml` while the service exists. |
| `Panel.qml` | Implements Overview, Locations, Advanced, Excluded Apps, and the always-available read-only System page. It receives the service from `BarWidget.qml`; it does not search host registries. |
| `Model.js` | Contains pure parsing, validation, redaction, grouping, bounded diagnostic parsing, desktop-entry search, recent-ID normalization, and fixed argv construction. |
| `scripts/mullvad-package-info` | Reads bounded metadata for the two allowlisted Mullvad packages from pacman's local database without running a package manager. |
| `scripts/mullvad-update-check` | Runs only `checkupdates`, filters and bounds Mullvad results, and applies its own TERM/KILL timeout. |

The System page is diagnostic only. It has no installer, package-update action, service mutation, privilege escalation, or application-launch path. Its package metadata read is local; its optional automatic/manual update check is the sole network-capable diagnostic.

## Omarchy 4.0.3 facade

A third-party `bar-widget` receives a scoped facade. `serviceFor("io.github.kallupx.oma-mullvad")` may resolve the plugin service; foreign service IDs must return `null`. The facade's `appLibrary` is `null` because the manifest does not declare `kind: "menu"`. The plugin does not traverse parent objects, private service registries, or replacement-bar internals to escape this boundary.

Excluded-app discovery uses the public Quickshell `DesktopEntries` catalogue. Search scans at most 4,096 entries, caps keyword count at 64, and bounds every searchable field before concatenation. Standard `noDisplay` entries are filtered. Omarchy's private launcher-hide configuration is not available through the scoped facade. Empty search shows resolved recent desktop IDs, while a non-empty query searches the bounded local catalogue. Launch execution remains the fixed argv returned by `Model.argv("launchExcluded", ...)`; safe desktop IDs may contain spaces and parentheses, while path syntax and shell metacharacters remain rejected. The panel persists the recent ID and closes only when the service reports that dispatch succeeded.

Settings persistence clones the current inline settings and replaces only favourites, recent locations, and recent excluded desktop IDs. This preserves unrelated values such as `refreshIntervalSec`.

## Service and widget lifecycle

`manifest.json` keeps `Service.qml` loaded while per-monitor bar widgets may reload. A new widget must resolve and inject the existing service instance. The panel loader is active only while the scoped service exists, so removing or replacing the facade destroys a stale panel. A host that does not expose the plugin service renders `Mullvad controls unavailable in this bar`; it does not attempt a private lookup.

When testing an installed change to `Service.qml`, use a full `omarchy restart shell`. A rescan or widget hot reload is insufficient.

## Process contract

Every `mullvad` command is a direct Quickshell child with argv created by `Model.argv`. Read and action queues enforce deadlines and bounded output. The long-lived status listener rejects over-limit unterminated output and cannot be overwritten by an older delayed poll. Account login writes the number to the direct child's stdin, closes stdin, and never stores or logs the value. Excluded-application launch is the only fire-and-forget path and still uses fixed argv.

System package metadata uses the normal bounded read queue and is collected even when the CLI probe fails. Daemon version and support come from `mullvad version`; `pgrep -x mullvad-daemon` supplies a PID when available. `checkupdates` runs through a dedicated `Process` that is excluded from `busy`, so a slow check cannot block VPN controls. Attempts are debounced for 60 seconds, automatic checks run after the startup grace period and then hourly, and both the helper and service process have bounded output plus TERM/KILL watchdogs. Failed checks preserve the last successful result and timestamp.

## Validation

Run the complete local gate from the repository root:

```bash
bash test/ci-local
```

Use `bash test/ci-local --no-cage` only as a live-session fallback when Cage cannot be used.

The gate runs:

1. QML lint and manifest validation.
2. `node --test tests/*.test.js` for pure model and sink checks.
3. `test/run-cli-contract`, which runs the read-only CLI contract against an inert test-local `mullvad` mock and verifies its exact argv inventory.
4. `test/probe/run` for mocked process, timeout, output-limit, listener, race, grouping, package metadata, and isolated read-only update-check behavior.
5. `test/probe/run-ui` against the real `BarWidget.qml` and `Panel.qml`, including System availability without the CLI or daemon, under the selected Omarchy shell source.
6. `test/quicktest/run`, which drives real `QtTest.TestCase` keyboard and pointer events through Panel routing, both dropdowns, confirmation dialogs, and WorldMap markers under the Cage gate.
7. `test/probe/run-settings` against the current scoped host facade and an isolated `shell.json`.
8. Node tests, runner/mock syntax, QML lint, and manifest validation again from a clean archive of the proposed index.

The physical-input suite requires `qmltestrunner`, provided on Arch by `qt6-declarative` at `/usr/lib/qt6/bin/qmltestrunner`. The runner first accepts `command -v qmltestrunner`, then checks that explicit Arch path, and fails closed when neither is available.

The probe suites mock all VPN-changing commands, `checkupdates`, process lookup, and excluded-application launch; they must not mutate the live daemon or invoke a real package manager or network update check. CI clones exact Omarchy `v4.0.3` and `v4.0.4` tags and runs the gate once against each tag's `shell/` and `bin/omarchy-plugin-validate`. Local validation defaults to `/usr/share/omarchy/shell` and the installed `omarchy-plugin-validate`; set `OMARCHY_SHELL_DIR` and `OMARCHY_PLUGIN_VALIDATOR` to test other source trees.

## Release discipline

Update release metadata in a focused commit after the behavior and documentation gates pass. Publish only an exact reviewed SHA, compare the remote ref with that SHA, and require the corresponding Actions run to succeed before tagging or requesting marketplace verification.
