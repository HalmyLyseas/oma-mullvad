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

As of S10 (below), there is no wrapper script on the CLI path at all — see
"Process contract".

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

### How the Panel `Loader` avoids a null-service Panel (C3, corrected by N4)

`Panel.qml` reads `service.<property>` unguarded in roughly 150 places (every
page: Overview, Locations, Advanced, Excluded Apps) — it is written to assume
`service` is always a live object for as long as it exists at all, never a
"service is still null" stub state.

Through the S6 fix pass this was enforced with `Loader { active: root.svc
!== null; source: Qt.resolvedUrl("Panel.qml") }` plus `onLoaded: injectPanel()`
handing the dependencies over *after* construction. **Measured, not
hypothesised: this was already safe** for the CONSTRUCTION path. Two shell
restarts plus a live panel open with that exact Loader produced zero
`TypeError`s in either the journal or the shell's own per-instance
`log.qslog` (see `exchange/11-s6-fixes.md`, confirmed independently in
`exchange/12-fable-review.md`) — `active:` gating construction until `svc`
resolves was already enough to keep Panel's bindings from ever seeing a
null `service` **the first time it loads**.

C3 (`exchange/12-fable-review.md`) hardened the construction path further,
at near-zero cost: `BarWidget.qml`'s `_loadPanel()` calls
`panelLoader.setSource(Qt.resolvedUrl("Panel.qml"), { bar, settings,
anchorItem, hostWidget, service })` whenever the Loader is active and not
yet loaded (checked via `panelLoader.status === Loader.Null`, so it is
harmless to call from both `Component.onCompleted` — svc already resolved —
and `onSvcChanged` — svc arriving later — whichever fires first). Quickshell
applies the second argument as the loaded component's *initial* property
values, evaluated before the component's own bindings run, so `service`
(and `bar`/`settings`/`anchorItem`/`hostWidget`) are never `null` for even
the first frame, by construction rather than by ordering luck.

At the time, C3 also removed the `active: svc !== null` gate as apparently
redundant, reasoning that `setSource`'s initial-properties mechanism alone
was sufficient. **That was a mistake, corrected by N4
(`exchange/25-fable-review-s10.md`): the gate is needed for the DESTROY
path, which C3's own measurement never covered.**
`/usr/share/omarchy/shell/shell.qml`'s `_syncServices()` destroys and
recreates a plugin's service instance if the plugin registry transiently
reports it disabled at startup — a real, observed race (not hypothetical:
`exchange/24-s10-native-process.md` deviation 5 measured 35-88 matching
`TypeError` lines on `omarchy restart shell`, initially misdiagnosed as
unrelated/pre-existing). Without the gate, `svc` transitions non-null ->
null -> (a NEW instance) non-null on the *same* `BarWidget` instance;
`onSvcChanged` still fires `injectPanel()` while `svc` is null, which wrote
`service = null` straight into the ALREADY-LIVE Panel from the
now-destroyed service — every one of Panel's ~150 unguarded `service.`
reads then throws. The gate is back: `Loader { active: root.svc !== null }`
now destroys the stale Panel (and resets `status` to `Loader.Null`) the
moment `svc` goes null, so when a new `svc` arrives, `_loadPanel()`'s
`status === Loader.Null` check re-fires `setSource` with the new instance —
a fresh, properly-initialized Panel every cycle, never a live one mutated
to null and back. `injectPanel()` also now returns early whenever
`root.svc` is null, as a second, redundant guard for the same event.

`BarWidget.qml` itself remains the one file that DOES need every `svc` read
null-guarded (`svc ? svc.x : <default>`), because the bar widget itself
paints before the service resolves on first load — that guarding work stays
concentrated in one small file instead of spread across the whole panel.

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

## Process contract (S10)

As of `23-s10-native-process-spec.md`, **every `mullvad` invocation is a
direct Quickshell `Process` child** — no shell wrapper anywhere on the CLI
path. This section is the reference for what that means and why; "Why the
listener runs unwrapped" below is now historical context for the same
mechanism (it started with the listener alone, in the S6 fix pass).

Four `Process` objects, one contract each (`Service.qml`):

| Process | Command | Deadline | Caps | stdin |
|---|---|---|---|---|
| `readProcess` (queue) | `Model.argv(...)` read verbs, direct | `readTimeoutMs` (default 10 s), one watchdog per queued read | per-line slice + total lines (4096) / chars (262144); breach stops appending, signals the child, marks the read `overflowed` (treated as a failure) | none |
| `actionProcess` (queue) | `Model.argv(...)` mutating verbs, direct | `actionTimeoutMs` (default 20 s) | same caps | `account login` only: `onStarted` → `write(number + "\n")`, clear the secret, then `stdinEnabled = false` (EOF). Every other action closes stdin the same way even though it never writes — nothing here reads further stdin once started. `stdinEnabled` is reset back to `true` at ARM time (N1, `exchange/25-fable-review-s10.md`) so a later action's `write()` isn't silently lost to a stdin a PREVIOUS action's `onStarted` already closed. |
| `listenerProcess` | `["mullvad","status","--json","listen"]`, unchanged since S6 | none (long-lived) | per-line slice only (`listenerLineChars`) | none |
| `updateCheckProcess` | `[updateCheckScript]` — `scripts/mullvad-update-check` stays a bash script (it wraps `checkupdates`, not the Mullvad CLI) spawned as a direct `Process`, same as before S10 | `updateCheckTimeoutMs` (default 130 s; probe-shortenable like the other two as of N6) | same caps | none |

**Watchdog pattern**, one `Timer` per process (`readWatchdog`/`actionWatchdog`/
`updateCheckWatchdog`), modeled on `halmylyseas.github-status`'s
`probeWatchdog`/`probeWatchdogFired`: on arm, `watchdog.interval = ms;
watchdog.restart()` (interval assigned imperatively at arm time, never a
live binding — Timer gotcha, recurs in every Omarchy plugin that's shipped
one). On the process's own `exited`, `watchdog.stop()` **and its matching
`killTimer.stop()`** (N2, `exchange/25-fable-review-s10.md`: the kill timer
was not previously stopped here, so a process that exited promptly on its
own `signal(15)` let the queue start the NEXT process while the still-
ticking 1s kill timer was pending — when it fired, `if (proc.running)` was
true again for the wrong (newer) child, which then got SIGKILLed). On the
watchdog firing: set a one-shot `_<kind>WatchdogFired` flag (consumed and
reset by the next `onExited`) and a persistent `_<kind>WatchdogFiredCount`
(a debug counter `test/probe/service-probe.qml` reads), send `signal(15)`,
then arm a 1s `killTimer` that sends `signal(9)` if the child is still
alive **and its `processId` still matches the PID captured at that
process's own `onStarted`** (N2's second guard, `root._<kind>ArmedPid`) —
belt-and-suspenders against the same stale-timer scenario.
`running = false` alone would **not** escalate anything here — it only
sends SIGTERM again (measured, see below) — so the killTimer calls
`signal(9)` explicitly. Same-tick guards read `Process.running` directly,
never a derived `readonly property bool` (a computed bool's re-evaluation
inside the same JS tick that flipped its inputs isn't guaranteed).

**Exit handling**: `onExited: function(exitCode, exitStatus)` —
`exitStatus === 1` (`CrashExit`, i.e. killed by signal) is folded into a
nonzero effective exit code regardless of `exitCode`, so a signalled child
can never look like a clean success to any of the per-kind parsing
branches in `_applyRead`/the action `onExited` (all of which already key
off "exit code nonzero = failure").

**Output caps**: `_appendReadOutput`/`_appendActionOutput`/
`_appendUpdateCheckOutput` are thin per-kind wrappers around one shared
`_appendBoundedOutput` helper. On breach, the line is capped so the
running total lands **at** `finiteOutputChars`, never one char past it (a
pre-existing +1 rounding in the old per-function implementations is fixed
here), the matching process is sent `signal(15)` immediately — it does not
keep running just because the QML side stopped reading its output — and
an overflow counter increments for the probe suite.

### Measured facts (Quickshell 0.3.1; PM probe, `scratchpad/pm-native/probe/shell.qml`)

- `Process.running = false` sends **SIGTERM** to the direct child (a
  trapping child saw TERM and exited `143`/`NormalExit`). `Process.signal(15)`
  behaves the same; `signal(9)` is the hard kill (`SIGKILL` — this is why
  the killTimer above calls it explicitly rather than relying on
  `running = false` a second time).
- `Process.write(str)` then `stdinEnabled = false` **closes stdin (EOF)**:
  a child's `read -r` got the full line, a following `cat | wc -c` got 0
  bytes. This is the exact mechanism `login()` now relies on, and the
  reason `exchange/22-login-stdin-bug.md`'s bash-backgrounding bug (a
  backgrounded `&` command gets `/dev/null` as stdin when job control is
  off — every non-interactive script) cannot recur: there is no
  backgrounded shell job anymore for that bug to hide in.
- `SplitParser` delivers a trailing partial line (no newline) on exit —
  relevant to why `_applyRead`/the action handlers always join whatever
  lines arrived rather than assuming a clean final newline.
- Quickshell's graceful `quickshell kill` IPC (what `omarchy restart shell`
  uses) kills only its own direct children — confirmed again live for this
  rework via `test/probe/run`: every mock PID for every mode, including the
  long-lived `status --json listen` mock, was gone after the probe's
  `Qt.quit()`, with **zero** orphans across 4 run modes. Grandchildren are
  **not** signalled (a wrapped child's own children survive a wrapper's
  death) — irrelevant now that no process here is ever wrapped, but it
  remains the invariant this whole design depends on: never reintroduce a
  shell wrapper on the CLI path.

### A caveat this rework makes broader, not smaller

`SplitParser`'s only property is `splitMarker` (the newline) — it cannot
call `onRead` until a full line arrives, so an adversarial child that wrote
an unbounded stream with **no newline** would have its entire output
buffered by Quickshell itself before this plugin's own caps ever see a
byte. Before S10 this was flagged as a listener-only accepted risk (see
"Why the listener runs unwrapped" below); it now applies to
`readProcess`/`actionProcess`/`updateCheckProcess` too, since none of them
route through a byte-capping shell pipe (`head -c`) anymore either.
Verified live in `test/probe/run`'s flood mode: the mock loops forever,
writing 64 KiB chunks with no newline ever (N6, `exchange/25-fable-review-
s10.md` — a genuine streaming flood with no natural exit, replacing an
earlier one-shot 10 MiB dump that already exited cleanly on its own and so
never actually proved the kill signal did anything). `SplitParser` buffers
everything internally with no `onRead` call until the process finally
dies (from Service.qml's own watchdog/kill escalation, the only thing that
can end it) and delivers the trailing partial line as one (huge) `onRead`
call, at which point `_appendBoundedOutput` correctly caps the *stored*
text at `finiteOutputChars` — but Quickshell's own internal buffer held
however many megabytes accumulated transiently first. Accepted for the same
reason as before: the source is the local, root-installed `mullvad` CLI,
not untrusted/remote input, and every real line it emits (JSON status
objects, human-readable settings) is a few hundred bytes at most.

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
listen` process is reparented to the user's `systemd --user` instance (a
normal per-user manager process, e.g. pid 1626 on this box — NOT system pid 1;
`systemd --user` is what orphaned children of a user session get reparented
to, distinct from the system-wide `systemd` at pid 1) and keeps running
forever. Combined with D1 (one `Service.qml`/listener per monitor before
this pass), a 2-monitor box leaked 2 of these per shell restart.

The fix (F2): the listener is now `Service.qml`'s **direct** `Process` child
— `command: ["mullvad", "status", "--json", "listen"]`, no wrapper at all.
Quickshell's kill now reaches the actual `mullvad` process directly. The
per-line size cap the wrapper's `listen` mode used to enforce is applied in
QML instead (`listenerLineChars`, sliced in both `stdout`/`stderr`
`SplitParser.onRead` handlers) — unchanged behaviour, just enforced one
layer up. `scripts/bounded-command`'s `listen` mode itself was deleted at
the time (kept `finite`/`finite-run` for every other, still-wrapped
read/action process); **S10 later removed the wrapper script itself
entirely** — see "Process contract" above — once the same
watchdog-plus-QML-caps approach was extended to `readProcess`/
`actionProcess`/`updateCheckProcess` too. `test/bounded-command.test.js`
(which asserted the wrapper rejected `listen`) is gone with it; its one
test that was never about the wrapper (the QML Text-sink audit) lives on
at `test/qml-sinks.test.js`.

**Residual risk, by design, documented rather than "fixed":** this only
covers the graceful `quickshell kill` IPC path (what `omarchy restart shell`
actually uses). An ungraceful `SIGKILL` of the quickshell process itself —
not something this plugin can intercept — still orphans this direct child,
exactly like any orphan of any killed process anywhere on the system. It is
not a leak forever, though: once its stdout pipe's read end disappears, its
next write hits `EPIPE` and the `mullvad` CLI exits on its own.

## Accepted risks / known couplings

- **No process has a pre-newline buffer cap (C2, `12-fable-review.md`;
  broadened by S10 — see "A caveat this rework makes broader, not smaller"
  above).** Originally flagged for `listenerProcess` alone (a direct
  `Process` child even before S10, with a plain `SplitParser` on
  `stdout`/`stderr` — `SplitParser`'s only property is `splitMarker`, the
  newline, so an unbounded no-newline stream buffers in full before
  `onRead` ever fires). S10 removed the wrapper that used to give
  `readProcess`/`actionProcess`/`updateCheckProcess` a byte cap
  independent of QML (`scripts/bounded-command`'s `head -c`), so the same
  caveat now applies to those three too — `finiteOutputChars`/
  `finiteOutputLines` still bound what this plugin *stores* and still kill
  the process on breach, just not before Quickshell's own `SplitParser`
  buffer has already held the full unterminated write. Accepted for the
  same reason as before: the source is the local, root-installed `mullvad`
  CLI, not untrusted/remote input, and every real line it emits is a few
  hundred bytes at most (confirmed against this box's live output).
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

- `bash test/all` — Node unit tests (`Model.js`, a QML Text-sink audit over
  every `.qml` file at the plugin root, now 7 files including
  `BarWidget.qml`), the `scripts.test.sh` suite (`mullvad-package-info` /
  `mullvad-update-check` / `install-mullvad` against `test/fixtures`/
  `test/mocks`), `test/cli-contract.mjs`, then `test/probe/run` (S10).
- `test/probe/run` is the deterministic mock-CLI probe suite for
  `Service.qml`'s Process rework (`23-s10-native-process-spec.md`, extended
  by N6 in `25-fable-review-s10.md`): `test/mocks/mullvad` shadows the real
  CLI on `PATH` (`MULLVAD_MOCK_MODE=ok|fail|hang|flood|action-hang`),
  `test/mocks/checkupdates` separately shadows `checkupdates` for the
  update-check scenarios (`MOCK_MODE=none|updates|offline|hang`).
  `test/probe/service-probe.qml` (`qs -n -p ...`) Loaders the real
  `Service.qml`, drains its read queue, then drives one of a few scenarios
  selected by env vars (plain `login()`; `MULLVAD_PROBE_DOUBLE_LOGIN=1` —
  connect then login twice, proving stdin reuse across actions;
  `MULLVAD_PROBE_ACTION_ONLY=1` — connect only, for the action-watchdog
  scenario; `MULLVAD_PROBE_CHECK_UPDATES=1` — also drives
  `checkForUpdates()`), and prints one JSON line the runner asserts
  against — including that no mock process (from either mock) is ever left
  running once `qs` exits. `PACMAN_LOCAL_DIR` points at the fixture pacman
  tree so the `packageInfo` read never touches this box's real installed-
  package database either. Skips itself (exit 0, with a notice) if no
  `qs`/Wayland session is available, same convention as every other
  `qs`-dependent check here. Never touches the real daemon.
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

## Upstreaming

This fork's identity/layout commits (own manifest `id`/`author`, own
marketplace listing, the S1-S8 architecture-migration history) are not PR
material upstream — they are this fork's own divergence, not a fix. The
PR-able change set is: F1/F2 (D1/D2 — the service-singleton split and the
unwrapped direct-child listener), F3-F6 (`parseToggle` line-anchoring, the
argv leading-`-`/path-traversal rejection, rendering `actionStatus`, the
imperative `Timer.interval` fix), C1 (the `lockedDown`
present-vs-`undefined` fix), C4 (`actionStatusTimer.stop()` before arming
the next action), and now T1/T2 (the safe package-page link, the System
tab). Each is a real, reproducible bug fix or a policy-clean addition, not
fork-specific rebranding.

To upstream: cherry-pick the specific commits above onto upstream `main`
(remote `upstream`, i.e. `kallupx/oma-mullvad`) using the **upstream**
manifest id (`io.github.kallupx.oma-mullvad`), not this fork's
`halmylyseas.mullvad` — one PR per concern (do not bundle unrelated fixes
into a single PR), and only after explicit human approval before anything
is pushed to a fork of `kallupx/oma-mullvad` or a PR is filed. No PR has
been prepared or filed as part of this pass; this section is preparation
only.

## Install prompt (privilege capability)

Human feedback after a from-scratch reinstall (`exchange/19-s9-install-prompt-spec.md`)
superseded the earlier decision to strip the AUR install button
(`exchange/07-human-gate.md` decision #3): rather than ship no installer at
all, the panel now offers a real install prompt through **Omarchy's own
mechanism**, never the AUR and never a raw shell command assembled from
plugin data.

**Mechanism.** The Overview page's "unavailable" card and the System tab's
UPDATES row both show an "Install Mullvad VPN" / "Enable the Mullvad
daemon" button (state-dependent on `!service.installed` /
`!service.daemonRunning`) behind a `ConfirmDialog`. On confirm, the panel
runs exactly:

```qml
Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                         Util.shellQuote(service.installScript)])
```

This is the identical mechanism Omarchy's own menu uses for its
"Install > Service" entries — see
`/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc:218`
(`install.service.nordvpn`) and its target script
`omarchy-install-service-nordvpn`, which `scripts/install-mullvad` mirrors
in shape (`echo "Installing …"`, `omarchy-pkg-add <pkg>`, `echo "Enabling …
daemon…"`, an idempotent `sudo systemctl enable --now <daemon>`).
`service.installScript` is a `Service.qml` property resolved the same way
as `packageInfoScript`/`updateCheckScript` (`Qt.resolvedUrl(...)`, stripped
of its `file://` prefix); the button never passes any argument or
plugin-derived data into the command — the script takes none.

**Why the daemon also needs enabling.** The Arch `extra` package
`mullvad-vpn` (→ `mullvad-vpn-daemon`) does **not** enable the daemon on
install. Its own `.INSTALL` `post_install` hook only prints:

```
sudo systemctl enable --now mullvad-daemon
```

to the terminal — it never runs it. Without `install-mullvad`'s own enable
step, a fresh install would leave the panel on "daemon unavailable" forever
until the user read that printed hint and ran it by hand. This is also why
this pass does not simply call the generic `omarchy-install-app "Mullvad
VPN" mullvad-vpn` helper (which only wraps `omarchy-pkg-add`, the same as
`install.editor.vim`'s menu entry): that helper has no notion of a daemon to
enable afterward, so the service-style script (`omarchy-install-service-*`)
is the correct precedent to follow, not the plain-app one.

**Idempotency.** `omarchy-pkg-add` is itself a no-op when the package is
already present; the daemon-enable step is skipped entirely once
`systemctl is-active --quiet mullvad-daemon` succeeds. Re-running the whole
script is safe in every state: nothing installed, package present but
daemon down, or both already present/running.

**Containment.** `scripts/install-mullvad` is the *only* file in this
plugin allowed to contain a package-manager/service-manager/sudo literal
(`CLAUDE.md` rule 4) — every other file documents prerequisites in prose
and links only. `test/scripts.test.sh` exercises it with PATH mocks for
`omarchy-pkg-add`/`systemctl`/`sudo` (recording invocations to a
`MOCK_LOG` file) covering: daemon inactive (install then enable, in that
order), daemon already active (install only, no `sudo` call), and
`omarchy-pkg-add` failing (script exits non-zero before ever calling
`systemctl`).

**Marketplace consequence.** This makes the plugin's declared capability
set `["privilege"]` again, exactly like the upstream `kallupx/oma-mullvad`
listing (`02-pm-plan.md`'s ground truth: Automated Security Baseline v3
outcome `review-required`, capability `["privilege"]`, for upstream's own
AUR-install button) — which passed maintainer review at that outcome. A
future marketplace update for this fork should expect the same
`review-required` baseline outcome, not `passed`, and that is the expected,
correct result for a plugin that ships one declared install action, not a
regression to fix.

## Credits

Author: kallupx (upstream OmaMullvad). Fork maintained by HalmyLyseas.

Forked from [kallupx/oma-mullvad](https://github.com/kallupx/oma-mullvad).
