# Developer notes

## Architecture

| File | Responsibility |
|---|---|
| `manifest.json` | Declares the `service` and `bar-widget` entry points and keeps the service loaded across widget reloads. |
| `Service.qml` | Owns shared Mullvad state, polling, the status listener, action queues, deadlines, output bounds, and excluded-process resolution. |
| `BarWidget.qml` | Resolves only this plugin's service through the scoped bar facade, renders state, and loads `Panel.qml` while the service exists. |
| `Panel.qml` | Implements Overview, Locations, Advanced, and Excluded Apps. It receives the service from `BarWidget.qml`; it does not search host registries. |
| `Model.js` | Contains pure parsing, validation, redaction, grouping, desktop-entry search, recent-ID normalization, and fixed argv construction. |

The System/package-management page is intentionally deferred. This release has no package installation or update UI and does not require privilege capability.

## Omarchy 4.0.3 facade

A third-party `bar-widget` receives a scoped facade. `serviceFor("io.github.kallupx.oma-mullvad")` may resolve the plugin service; foreign service IDs must return `null`. The facade's `appLibrary` is `null` because the manifest does not declare `kind: "menu"`. The plugin does not traverse parent objects, private service registries, or replacement-bar internals to escape this boundary.

Excluded-app discovery uses the public Quickshell `DesktopEntries` catalogue. Search and scoring are bounded pure functions in `Model.js`; standard `noDisplay` entries are filtered. Omarchy's private launcher-hide configuration is not available through the scoped facade. Empty search shows resolved recent desktop IDs, while a non-empty query searches the complete local catalogue. Launch execution remains the fixed argv returned by `Model.argv("launchExcluded", ...)`.

Settings persistence clones the current inline settings and replaces only favourites, recent locations, and recent excluded desktop IDs. This preserves unrelated values such as `refreshIntervalSec`.

## Service and widget lifecycle

`manifest.json` keeps `Service.qml` loaded while per-monitor bar widgets may reload. A new widget must resolve and inject the existing service instance. The panel loader is active only while the scoped service exists, so removing or replacing the facade destroys a stale panel. A host that does not expose the plugin service renders `Mullvad controls unavailable in this bar`; it does not attempt a private lookup.

When testing an installed change to `Service.qml`, use a full `omarchy restart shell`. A rescan or widget hot reload is insufficient.

## Process contract

Every `mullvad` command is a direct Quickshell child with argv created by `Model.argv`. Read and action queues enforce deadlines and bounded output. The long-lived status listener rejects over-limit unterminated output and cannot be overwritten by an older delayed poll. Account login writes the number to the direct child's stdin, closes stdin, and never stores or logs the value. Excluded-application launch is the only fire-and-forget path and still uses fixed argv.

## Validation

Run the complete local gate from the repository root:

```bash
bash test/ci-local --no-cage
```

The gate runs:

1. QML lint and manifest validation.
2. `node --test tests/*.test.js` for pure model and sink checks.
3. `node test/cli-contract.mjs`, which invokes only read-only Mullvad commands and skips only when the CLI is absent.
4. `test/probe/run` for mocked process, timeout, output-limit, listener, race, and grouping behavior.
5. `test/probe/run-ui` against the real `BarWidget.qml` and `Panel.qml` under a scoped 4.0.3-style facade.
6. Node tests, QML lint, and manifest validation again from a clean archive of the proposed index.

The probe suites mock all VPN-changing commands and must not mutate the live daemon. CI runs the same tracked suites in an Arch container with the Omarchy shell API extracted for linting and headless QML probes.

## Release discipline

Update release metadata in a focused commit after the behavior and documentation gates pass. Publish only an exact reviewed SHA, compare the remote ref with that SHA, and require the corresponding Actions run to succeed before tagging or requesting marketplace verification.
