# Developer notes

The distilled why and how of this plugin, for a contributor starting from a
bare clone. The README covers using it; `CLAUDE.md` carries the project
rules. `exchange/` (present alongside this repo during the S1-S6 migration
project, not required to build or maintain the plugin) corroborates specific
claims below — treat it as evidence, not something a fresh clone needs.

## Architecture

As of the S6 fix pass, this plugin follows the same service/bar-widget/panel
split as `halmylyseas.github-status` and `halmylyseas.ristretto`:

| File | Role |
|---|---|
| `manifest.json` | `kinds: ["service", "bar-widget"]`, `keepLoaded: true`. `entryPoints.service` is `Service.qml`, `entryPoints.barWidget` is `BarWidget.qml`. |
| `Service.qml` | All state and the only place that spawns processes: the Mullvad CLI polling/action/listener processes, the account/relay/settings model. **Instantiated exactly once, machine-wide**, by `shell.ensureService()` (`/usr/share/omarchy/shell/shell.qml`) the first time any bar widget or panel resolves it. One poller, one `status --json listen` listener, one action queue, regardless of monitor count. |
| `BarWidget.qml` | The bar-slot entry point (one instance per monitor, the normal Quickshell bar-widget lifecycle). Resolves the singleton via `shell.serviceFor("halmylyseas.mullvad")` and re-derives it any time `shell._services` is reassigned (reactive — see "Injection contract" below). Owns the button + icon, and hosts `Panel.qml` through a `Loader`. |
| `Panel.qml` | The popup: Overview, Locations, Advanced, Excluded Apps pages. Receives `bar`, `settings`, `anchorItem`, `hostWidget`, and `service` from `BarWidget.injectPanel()` — it never creates its own `Service.qml` or reads `shell.serviceFor(...)` itself. |
| `Model.js` | Pure ES5 logic: CLI-output parsers, the mutating-command argv allowlist, redaction, field/list caps. Plain Node can `require()` it (`test/model.test.js`). |
| `OmaDropdown.qml` / `OmaSearchableDropdown.qml` | Shared dropdown widgets ("Oma" = Omarchy, kept from upstream naming — not a rebrand miss). |
| `ThemeIcon.qml`, `WorldMap.qml` | Icon theming and the relay world map. |
| `scripts/bounded-command` | `bash`, wraps *finite* CLI reads/actions with a hard deadline + output-line/byte cap so a stuck or verbose child can't hang the panel or flood memory. No longer used for the listener process — see "Why the listener runs unwrapped" below. |

### Injection contract (`BarWidget.injectPanel()`)

`BarWidget.qml` loads `Panel.qml` through a `Loader` and, on every load and on
every change to `bar`/`settings`/`svc`, calls `injectPanel()`, which sets (via
`"prop" in target` existence checks, so it degrades harmlessly if a property
is ever renamed on one side only):

- `bar` — the host `Bar` instance.
- `settings` — this widget's inline `shell.json` entry.
- `anchorItem` — the bar button, so `KeyboardPanel` positions the popup
  against it.
- `hostWidget` — `BarWidget`'s own `root`, so `Panel.qml` can read
  `hostWidget.stateIcon`/`stateColor` (see below) and so `KeyboardPanel`'s
  `owner` can relay `close()` back through the widget that actually owns the
  IPC/lifecycle plumbing (`owner: root.hostWidget || root`, matching the
  reference plugins).
- `service` — the resolved `Service.qml` singleton instance itself.

`BarWidget` also pushes `svc.pollInterval = clamp(setting("refreshIntervalSec",
30) * 1000)` on the same triggers, since the service does not read bar-widget
`settings` directly (a machine-wide singleton has no single owning widget to
read settings from — see "settings vs. the service" below).

### Why the Panel `Loader` is gated on `svc !== null`

`BarWidget.qml`'s `Loader { active: root.svc !== null; source:
Qt.resolvedUrl("Panel.qml") }` is deliberate, not a lazy-load optimisation.
`Panel.qml` reads `service.<property>` unguarded in roughly 150 places (every
page: Overview, Locations, Advanced, Excluded Apps). Gating the Loader means
Quickshell never even constructs a `Panel.qml` instance until the singleton
service already exists, so Panel never needs a "service is still null" stub
state or 150 individual null-guards — it can assume `service` is always a
live object for as long as it exists at all. `BarWidget.qml` itself is the
one file that DOES need every `svc` read null-guarded (`svc ? svc.x :
<default>`), because the bar widget itself paints before the service
resolves on first load — that guarding work is concentrated in one small
file instead of spread across the whole panel.

Panel keeps its own `stateIcon`/`stateColor` (used in the Overview hero
icon), but instead of duplicating BarWidget's svc-guarded computation, it
reads the host widget's already-computed value with a null-guard fallback:
`hostWidget && hostWidget.stateIcon !== undefined ? hostWidget.stateIcon :
"connecting"`. `barTooltip` was fully removed from Panel.qml — it only ever
fed the bar button's tooltip, and the button now lives in `BarWidget.qml`.

### `settings` vs. the service

The bar-widget `settings` object (this widget's inline `shell.json` entry,
currently just `refreshIntervalSec`, plus the `favoriteLocations`/
`recentLocations` this panel itself persists via
`bar.shell.updateEntryInline`) belongs to the **widget**, not the service.
`Service.qml` has no `settings` property; it only exposes a plain `pollInterval`
(ms) that the widget pushes into after reading its own settings. This keeps
the service ignorant of "which bar widget instance" concept entirely, which
matters once it is a true machine-wide singleton with potentially more than
one caller.

## Why the listener runs unwrapped (D2 story)

Through S5, `Service.qml`'s `status --json listen` watcher ran through
`scripts/bounded-command`'s `listen` mode (`bounded-command listen 8192 --
mullvad status --json listen`), which piped output through a `fold -b`
subshell for the per-line size cap. That wrapper is a **grandchild**
relationship as far as Quickshell's process tree is concerned: Quickshell's
own `Process` object only ever holds a handle to the wrapper (its direct
child); the actual `mullvad ... listen` process is a child *of the wrapper*,
started by the wrapper's own `"${command[@]}" >&3 2>&4 &` line.

`omarchy restart shell` (and any other path that asks Quickshell to reload)
ultimately sends the `quickshell kill -p <dir> --any-display` IPC call.
Quickshell's kill hard-terminates its direct child only — it does not
recurse into that child's own children, and the wrapper's TERM trap
(`stop_children`) never runs because the wrapper itself is the one being
killed, not signalled gracefully. The result, reproduced live in both the PM
verdict (`06-verdict.md` D2, using a synthetic `sleep 300` payload) and the
S5 migration pass (`09-s5-migration.md`, using the real `mullvad ... listen`
process): the wrapper disappears, and the bare `mullvad status --json
listen` process is reparented to `systemd --user` (pid 1) and keeps running
forever. Combined with D1 (one `Service.qml`/listener per monitor before
this pass), a 2-monitor box leaked 2 of these per shell restart.

The fix (F2): the listener is now `Service.qml`'s **direct** `Process` child
— `command: ["mullvad", "status", "--json", "listen"]`, no wrapper at all.
Quickshell's kill now reaches the actual `mullvad` process directly. The
per-line size cap the wrapper's `listen` mode used to enforce is applied in
QML instead (`listenerLineChars`, sliced in both `stdout`/`stderr`
`SplitParser.onRead` handlers) — unchanged behaviour, just enforced one
layer up. `scripts/bounded-command`'s `listen` mode itself was deleted
(kept only `finite`/`finite-run`, still used for every bounded read/action
process); `test/bounded-command.test.js` was updated to assert the wrapper
now rejects `listen` outright.

**Residual risk, by design, documented rather than "fixed":** this only
covers the graceful `quickshell kill` IPC path (what `omarchy restart shell`
actually uses). An ungraceful `SIGKILL` of the quickshell process itself —
not something this plugin can intercept — still orphans this direct child,
exactly like any orphan of any killed process anywhere on the system. It is
not a leak forever, though: once its stdout pipe's read end disappears, its
next write hits `EPIPE` and the `mullvad` CLI exits on its own.

## Accepted risks / known couplings

- **One `IpcHandler` per monitor.** `Panel.qml` still owns the plugin's
  `IpcHandler` (it needs the widget's `favoriteLocations`/`recentLocations`,
  which are Panel-local state persisted via `updateEntryInline`), and one
  `Panel.qml` instance still exists per monitor. Quickshell logs a
  "Handler was registered but will not be used because another handler is
  registered for target halmylyseas.mullvad" warning for every monitor after
  the first — this is the same benign/inherited multi-monitor duplication
  the reference plugins document, not a regression from the S6 fix pass.
- **`bar.shell.*` undocumented shell-internal surface.** Three properties/
  methods on the shell singleton are used here and are not part of any
  published API:
  - `bar.shell.serviceFor(id)` — **this is now the documented, load-bearing
    service-resolution pattern** this whole fix pass depends on (F1); it is
    the same call every first-party plugin with a `service` kind uses.
  - `bar.shell.appLibrary` / `.refreshIcons()` — used only to refresh the
    launcher icon cache before the Excluded Apps page renders (`Panel.qml`
    `onOpenedChanged`). Guarded (`bar && bar.shell && bar.shell.appLibrary
    && bar.shell.appLibrary.refreshIcons`) — degrades to stale/no icons if
    ever removed, never a crash.
  - `bar.shell.updateEntryInline(id, entry)` — used to persist
    `favoriteLocations`/`recentLocations` back into `shell.json`. Guarded the
    same way; the whole call is skipped (favourites just don't persist
    across a restart) if it is ever absent.
  None of these three are declared in any first-party plugin-facing contract
  document; treat a future Omarchy update silently removing or renaming any
  of them as a possible (if unlikely) breakage, not a bug in this plugin.

## Dev workflow

Every save under `~/.config/omarchy/plugins/` triggers a full bar reload
(`inotifywait -r`), so develop in the separate `work/` clone and deploy in
one burst:

```bash
git -C ~/.config/omarchy/plugins/halmylyseas.mullvad pull ~/git/oma-mullvad/work main
omarchy restart shell   # required after structural / new-file changes
omarchy-shell halmylyseas.mullvad __probe__   # "Function not found." = loaded
```

`BarWidget.qml` is a new file as of the S6 fix pass — a plain hot-reload
will not pick up a brand-new bar-widget entry point; `omarchy restart shell`
is required, not optional, after pulling this change in.

## Testing

- `bash test/all` — Node unit tests (`Model.js`, the `bounded-command`
  guard, a QML Text-sink audit over every `.qml` file at the plugin root,
  now 7 files including `BarWidget.qml`) then `test/cli-contract.mjs`.
- `test/cli-contract.mjs` runs the real local `mullvad` CLI with read-only
  subcommands only (`--version`, `status --json`, `relay list/get`,
  `auto-connect get`, `lan get`, `lockdown-mode get`, `dns get`,
  `anti-censorship get`, `split-tunnel list`) and asserts the parsers in
  `Model.js` accept the live output shape and never surface an account
  number. It never mutates daemon state.
- `omarchy plugin validate .` and qmllint on every `.qml` file must show 0
  errors before a commit that touches QML (warning counts are recorded per
  release in `exchange/11-s6-fixes.md` for this pass, not tracked to zero —
  they match the reference plugins' baseline density: `missing-property` on
  the generic `bar`/`QObject` type and `unqualified access` inside inline
  `Component {}` icon delegates without `pragma ComponentBehavior: Bound`).
- Live/mutating action tests (`connect`/`disconnect`/settings changes
  against the real daemon) are never run as part of routine development —
  only as an explicitly human-authorised pass, see `exchange/11-s6-fixes.md`
  F8 for the one that has been run and its before/after diff.

## Releasing

Creating the public GitHub repository and adding it as `origin` is a human
step (this fork currently has only an `upstream` remote pointing at
kallupx/oma-mullvad). Marketplace submission — the
`HANCORE-linux/omarchy-plugin-marketplace` issue, six required headings, the
AI-agent-clause attestation — needs explicit human approval and is never
filed by an agent. Updates after listing go through a `verify-plugin.yml`
issue naming the plugin ID, repo URL, and full 40-character commit SHA.

## Credits

Forked from [kallupx/oma-mullvad](https://github.com/kallupx/oma-mullvad).
