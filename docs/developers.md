# Developer notes

The design record for this plugin, for a contributor starting from a bare
clone. The README covers using it; `CLAUDE.md` carries the hard rules.

## Architecture

| File | Role |
|---|---|
| `manifest.json` | Kinds `["service", "bar-widget"]`, `keepLoaded: true`. `entryPoints.service` is `Service.qml`, `entryPoints.barWidget` is `BarWidget.qml`. |
| `Service.qml` | All state and the only place that spawns processes: the Mullvad CLI polling/action/listener processes, the account/relay/settings model. **Instantiated exactly once, machine-wide**, by `shell.ensureService()` the first time any bar widget or panel resolves it. One poller, one `status --json listen` listener, one action queue, regardless of monitor count. |
| `BarWidget.qml` | The bar-slot entry point (one instance per monitor). Resolves the singleton via `shell.serviceFor("halmylyseas.mullvad")`, reactive to `shell._services` being reassigned on every service add. Owns the button + icon, and hosts `Panel.qml` through a `Loader`. |
| `Panel.qml` | The popup: Overview, Locations, Advanced, Excluded Apps, System pages. Receives `bar`, `settings`, `anchorItem`, `hostWidget`, and `service` from `BarWidget.injectPanel()` — it never resolves the service itself. |
| `Model.js` | Pure ES5 logic: CLI-output parsers, the mutating-command argv allowlist, redaction, field/list caps. Plain Node can `require()` it (`test/model.test.js`). |
| `OmaDropdown.qml` / `OmaSearchableDropdown.qml` | Shared dropdown widgets ("Oma" = Omarchy, kept from upstream naming). |
| `ThemeIcon.qml`, `WorldMap.qml` | Icon theming and the relay world map. |

### Injection contract and the null-service Panel

`BarWidget.qml` loads `Panel.qml` through a `Loader` and, on every load and
every change to `bar`/`settings`/`svc`, calls `injectPanel()`, which sets
`bar`, `settings`, `anchorItem` (the bar button, for `KeyboardPanel`
positioning), `hostWidget` (so Panel can read its already-computed
`stateIcon`/`stateColor`), and `service`. `BarWidget` also pushes
`svc.pollInterval` from its own `refreshIntervalSec` setting, since a
machine-wide singleton has no single owning widget to read settings from.

`Panel.qml` reads `service.<property>` unguarded in roughly 150 places, so
`BarWidget._loadPanel()` calls `panelLoader.setSource(...)` with those
dependencies as *initial* property values (applied before the loaded
component's own bindings run), so `service` is never `null` for even the
first frame. The Loader is also gated `active: root.svc !== null`: the
shell can destroy and recreate a plugin's service instance if the plugin
registry transiently reports it disabled at startup, and without the gate
a stale Panel would have `service` written back to `null` in place rather
than being destroyed and freshly reloaded once a new instance arrives.

`BarWidget.qml` itself is the one file that DOES need every `svc` read
null-guarded, since the bar widget paints before the service resolves.

### `settings` vs. the service

The bar-widget `settings` object (`refreshIntervalSec`, plus the
favourites/recents the panel persists via `bar.shell.updateEntryInline`)
belongs to the **widget**, not the service, which only exposes a plain
`pollInterval` (ms) the widget pushes into.

## Process contract

**Every `mullvad` invocation is a direct Quickshell `Process` child** — no
shell wrapper anywhere on the CLI path (see CLAUDE.md rule 7 for why).

Four `Process` objects, one contract each (`Service.qml`):

| Process | Command | Deadline | Caps | stdin |
|---|---|---|---|---|
| `readProcess` (queue) | `Model.argv(...)` read verbs, direct | `readTimeoutMs` (default 10 s), one watchdog per queued read | per-line slice + total lines (4096) / chars (262144); breach stops appending, signals the child, marks the read `overflowed` (treated as a failure) | none |
| `actionProcess` (queue) | `Model.argv(...)` mutating verbs, direct | `actionTimeoutMs` (default 20 s) | same caps | `account login` only: `onStarted` → `write(number + "\n")`, clear the secret, then `stdinEnabled = false` (EOF). Reset back to `true` at ARM time so a later action's `write()` isn't silently lost to a stdin a previous action already closed. |
| `listenerProcess` | `["mullvad","status","--json","listen"]` | none (long-lived); respawns after `listenerRestartMs` (default 5 s) on exit | per-line slice only (`listenerLineChars`) | none |
| `updateCheckProcess` | `[updateCheckScript]` — `scripts/mullvad-update-check` stays a bash script (wraps `checkupdates`, not the Mullvad CLI) | `updateCheckTimeoutMs` (default 130 s, probe-shortenable like the other two) | same caps | none |

**Watchdog pattern**: one `Timer` per process, interval assigned
imperatively and restarted at arm time (never a live `interval:` binding,
which restarts on any change to its own inputs). On `exited`, the watchdog
and its matching kill timer both stop. On firing: a one-shot flag and a
persistent `*Count` (read by the probe suite) are set, `signal(15)` is
sent, then a 1s kill timer sends `signal(9)` if the child is still alive
**and its `processId` still matches the PID captured at its own
`onStarted`** — never escalate against a different, later process the
queue already started in its place. Same-tick guards read
`Process.running` directly, never a derived `readonly property bool`.

**Exit handling**: `exitStatus === 1` (killed by signal) folds into a
nonzero effective exit code, so a signalled child never looks like success.

**Output caps**: one shared `_appendBoundedOutput` helper backs all three
processes' buffers. Arrays are always **replaced**, never mutated (QML
bindings don't notice a mutated array). On breach, the line is capped so
the total lands at the limit, `signal(15)` is sent, and an overflow
counter increments for the probe suite.

**Failed-start semantics**: a `Process` whose binary cannot be found flips
`running` to `false` **without ever emitting `exited`** — a normal exit's
transition, by contrast, is always immediately followed by `exited`. Since
every `onExited` body used to be the only finalize point, a failed-start
read never applied its result, a failed-start action left `actionStatus`
stuck forever with no `refreshAll()`, and the listener kept streaming from
a daemon whose CLI no longer resolves.

Fixed by a per-process `onRunningChanged` that schedules a deferred check
(a normal exit's own `exited` always fires first, synchronously) that
synthesizes the same finalize call with exit code 127 when `exited` never
came. Guarded with a **per-kind generation counter**, bumped on every arm
and stamped by the real `onExited`, rather than a plain boolean — a
boolean lets a stale deferred check misfire against a newer, still-running
process queued in the same batch. `test/probe/run`'s `removed` scenario
deletes a per-run temp symlink standing in for the `mullvad` binary
mid-run and drives both the read-side and action-side recovery.

**Measured facts** (Quickshell 0.3.x): `running = false` and `signal(15)`
both send SIGTERM to the direct child; `signal(9)` is the hard kill, hence
the kill timer calling it explicitly. `write(str)` then `stdinEnabled =
false` closes stdin (EOF) — the mechanism `login()` relies on.
`SplitParser` delivers a trailing partial line on exit, so every handler
joins whatever arrived rather than assuming a clean final newline. The
graceful `quickshell kill` IPC (what `omarchy restart shell` uses) kills
only its own direct children, never a wrapped grandchild — the invariant
this whole design depends on.

**Accepted risk**: `SplitParser` cannot call `onRead` until a newline
arrives, so an adversarial child writing an unbounded stream with none
would have its output buffered by Quickshell itself before this plugin's
caps see a byte. Accepted: the source is the local, root-installed
`mullvad` CLI, and every real line it emits is a few hundred bytes at most.

## State truthfulness: icon, and the poll/listener race

`Service.qml` exposes a public `readonly property string stateIcon`
(connecting/connected/disconnected/error/warning) so the icon shown is
testable without any UI; `BarWidget.qml` just binds `svc ? svc.stateIcon :
"connecting"`. Two status sources feed the same state: the periodic poll
(`status --json`) and the long-lived listener (`status --json listen`).
A slow poll started before a listener event must not overwrite it on
arrival — fixed with a monotonically increasing `_statusSeq`: each source
captures its own seq when it *starts* (poll: at `_startNextRead`; listener:
per received line) and `_applyStatus` only applies a result whose seq is
not older than the last one actually applied. Measured without the guard:
a slow poll returning stale `disconnected` reliably overwrote a
just-arrived `connected` from the listener (`test/probe/run`'s `race`
scenario, mock `status --json` delayed via `MULLVAD_MOCK_STATUS_DELAY_MS`/
`_TRIGGER`); with the guard, the listener's value always wins.

The listener also validates JSON itself before calling `_applyStatus` —
`Model.parseStatus` never throws on unparseable input, it silently maps to
`"unknown"`, which would otherwise flash a false status on a garbage or
truncated (`listenerLineChars`-capped) line. `listenerRestartMs` (default
5 s, probe-shortenable) gates the respawn delay after the listener exits.

## Why no shell wrapper

A shell wrapper around a CLI call is a **grandchild** relationship as far
as Quickshell's process tree is concerned: its `Process` object only ever
holds a handle to the wrapper, and any real child the wrapper starts is a
child *of the wrapper*. Two real bug classes came from exactly that gap:
a backgrounded shell job gets `/dev/null` as stdin regardless of what was
written to the wrapper's own stdin, so a wrapper could never deliver a
written account number to the real CLI; and `quickshell kill`
hard-terminates its direct child only, never recursing into that child's
own children, so a wrapped grandchild (e.g. the long-lived status
listener) is reparented to `systemd --user` and keeps running forever —
one leak per monitor, per restart.

The fix: every `mullvad` invocation is `Service.qml`'s **direct** `Process`
child, so `write()` reaches the real stdin directly and `quickshell kill`
reaches the actual `mullvad` process. Deadlines and per-line caps a
wrapper used to enforce are enforced in QML instead — see "Process
contract" above.

**Residual risk, by design:** this only covers the graceful `quickshell
kill` IPC path. An ungraceful `SIGKILL` of the quickshell process itself
still orphans a direct child, like any orphan anywhere on the system —
not forever, since its next write hits `EPIPE` once its stdout pipe's read
end disappears, and the CLI exits on its own.

## Install prompt (privilege capability)

The panel offers a real install prompt through **Omarchy's own mechanism**,
never the AUR and never a raw shell command assembled from plugin data.
The Overview page's "unavailable" card and the System tab's UPDATES row
both show an "Install Mullvad VPN" / "Enable the Mullvad daemon" button
behind a `ConfirmDialog`; on confirm the panel runs exactly:

```qml
Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                         Util.shellQuote(service.installScript)])
```

the identical mechanism Omarchy's own menu uses for its "Install > Service"
entries; the button never passes any argument or plugin-derived data into
the command. The Arch `extra` package `mullvad-vpn` does **not** enable
its daemon on install — its post-install hook only prints the enable
command, never runs it — so `install-mullvad` also enables it, idempotently
(package-add is a no-op if already installed, enable is skipped if the
daemon is already active).

`scripts/install-mullvad` is the *only* file in this plugin allowed to
contain a package-manager/service-manager/sudo literal (CLAUDE.md rule 4);
`test/scripts.test.sh` exercises it with PATH mocks for both orderings and
a failing package-add. This makes the plugin's declared capability set
`["privilege"]`, exactly like the upstream `kallupx/oma-mullvad` listing —
expect a "review-required" marketplace baseline outcome, not "passed";
that is correct, not a regression.

## Accepted risks / known couplings

- **One `IpcHandler` per monitor.** `Panel.qml` owns the plugin's
  `IpcHandler` (it needs Panel-local favourites/recents state), one
  instance per monitor. Quickshell logs a benign "Handler was registered
  but will not be used" warning for every monitor after the first.
- **`bar.shell.*` undocumented shell-internal surface.** `serviceFor(id)`
  (load-bearing), `appLibrary`/`.refreshIcons()`, and
  `updateEntryInline(id, entry)` are used here but not part of any
  published API; the latter two are guarded and degrade harmlessly if
  ever removed.

## Dev workflow

Every save under `~/.config/omarchy/plugins/` reloads the whole bar, so
develop in a separate clone and deploy in one burst:

```bash
git -C ~/.config/omarchy/plugins/halmylyseas.mullvad pull <work-clone> main
omarchy restart shell   # required after structural / new-file changes
omarchy-shell halmylyseas.mullvad __probe__   # "Function not found." = loaded
```

`omarchy restart shell` is required, not optional, after pulling in a new
file — a plain hot-reload will not pick it up.

## Testing

- `bash test/all` — Node unit tests (`Model.js`, a QML Text-sink audit, the
  comment-hygiene scan), `scripts.test.sh` (against `test/fixtures`/
  `test/mocks`), `test/cli-contract.mjs`, then `test/probe/run`.
- `test/probe/run` is the deterministic mock-CLI probe suite for
  `Service.qml`'s Process pipeline: `test/mocks/mullvad`/`checkupdates`/`ps`
  shadow the real binaries on `PATH` (`ps` serves the fixture process table
  behind the excluded-processes read). `test/probe/service-probe.qml`
  (`qs -n -p ...`) Loaders the real `Service.qml`, drains its read queue,
  drives a scenario selected by env vars, and prints one JSON line the
  runner asserts against, including that no mock process is left running.
  `PACMAN_LOCAL_DIR` points at a fixture pacman tree. Skips itself if no
  `qs`/Wayland session is available. Never touches the real daemon.
- The mock listener also supports a scripted mode:
  `MULLVAD_MOCK_LISTEN_SCRIPT=<file>`, one `<delay-ms> <payload>` line each
  (`EXIT <code>`/`STDERR <text>` payloads end the stream or write to
  stderr), for the state-truthfulness matrix in `test/probe/run`
  (`test/fixtures/cli/listen-scripts/`): connect, tunnel-drop, lockdown
  block, daemon-restart-respawn, and garbage/over-long lines, plus the
  poll-vs-listener race (`MULLVAD_MOCK_STATUS_DELAY_MS`/`_TRIGGER`).
- `test/probe/run-ui` instantiates the real `BarWidget.qml`/`Panel.qml`
  against a stub `bar`/`shell` covering the bar-widget README's injected
  surface, with `QML_IMPORT_PATH` pointed at a scratch `qs` symlink to
  `/usr/share/omarchy/shell` so `import qs.Ui`/`qs.Commons` resolve. Drives
  page locking, the Ownership dropdown's live binding, Excluded-tab
  rendering, and the svc null/recreate lifecycle; fails on any
  TypeError/ReferenceError in the log. `BarWidget._debugPanelItem/
  _debugPanelActive/_debugPanelStatus` and `Panel._debugPageItem` are
  debug-only aliases that exist solely so this probe can observe the
  Loader lifecycle without opening a real popup window.
- `test/cli-contract.mjs` runs the real local `mullvad` CLI, read-only
  subcommands only, asserting `Model.js`'s parsers accept the live output
  shape and never surface an account number.
- `omarchy plugin validate .` and qmllint on every `.qml` file must show 0
  errors before a commit that touches QML.
- Live/mutating action tests against the real daemon are only ever run as
  an explicitly human-authorised pass, never routine development.

## Releasing

Creating the public GitHub repository and adding it as `origin` is a human
step. Marketplace submission — the
`HANCORE-linux/omarchy-plugin-marketplace` issue, six required headings,
the AI-agent-clause attestation — needs explicit human approval and is
never filed by an agent. Updates after listing go through a
`verify-plugin.yml` issue naming the plugin ID, repo URL, and full SHA.

## Upstreaming

This fork's identity/layout commits (own manifest `id`/`author`, own
marketplace listing) are not PR material upstream — they are this fork's
own divergence, not a fix. The PR-able set, by topic: the
service-singleton split and unwrapped direct-child listener (the two
process-tree bugs under "Why no shell wrapper"); `parseToggle`'s
line-anchored match; the argv leading-`-`/path-traversal rejection;
rendering `service.actionStatus`; the imperative `Timer.interval` fix; the
`lockedDown` present-vs-`undefined` fix; stopping `actionStatusTimer`
before arming the next label; and the System tab — each a real,
reproducible fix or policy-clean addition, not fork-specific rebranding.

To upstream: cherry-pick the specific commits onto upstream `main` (remote
`upstream`) using the **upstream** manifest id
(`io.github.kallupx.oma-mullvad`), not `halmylyseas.mullvad` — one PR per
concern, only after explicit human approval before anything is pushed or
filed.

## Credits

Author: kallupx (upstream OmaMullvad). Fork maintained by HalmyLyseas.

Forked from [kallupx/oma-mullvad](https://github.com/kallupx/oma-mullvad).
