# Threat model

Scope: `halmylyseas.mullvad`, an Omarchy shell plugin driven entirely by the
local `mullvad` CLI. See `CLAUDE.md` for the hard rules this model assumes
are enforced, and `docs/developers.md` for architecture detail.

## Assets

- **The Mullvad account number.** Entered once at login, never persisted by
  this plugin.
- **Tunnel-state truthfulness.** The bar/panel must never claim protection
  the daemon does not itself report.
- **This machine's network policy** — connect/disconnect state and lockdown
  mode — since the plugin can change both.
- **The user's installed application list**, surfaced through the Excluded
  tab's app library and used to launch apps outside the tunnel.

## Trust boundaries and their guard

| Boundary | Guarded by |
|---|---|
| Mullvad CLI stdout/stderr | `Model.js`'s bounded parsers (`MAX_INPUT_CHARS`/`MAX_LINE_CHARS`/etc. caps) and `redact()`/`plainText()` (account-number and secret redaction) before any value reaches a `Service.qml` property; every `Text{}` sink is `textFormat: Text.PlainText` (`CLAUDE.md` rule 3, enforced by `test/qml-sinks.test.js`), so a hostile relay/city name can never be interpreted as rich text. |
| Persisted plugin settings (`shell.json`: favourites, recents, excluded apps) | `Model.js`'s `normalizeFavorites()`/`normalizeRecentApps()` — capped length (9 favourites, 5 recents, 10 apps), deduplicated by key, and every app id is passed through `validateDesktopId()` (fixed charset, no `.`/`..` path-traversal segment) before it is stored or rendered. |
| App library → the setuid `mullvad-exclude` | `Model.js`'s `buildCommand()` `"launchExcluded"` case re-validates the id (leading-`-` rejection plus the same charset/traversal check) before building a fixed argv, `["mullvad-exclude", "uwsm-app", "--", "gtk-launch", desktopId]`. `/usr/bin/mullvad-exclude` (shipped by `mullvad-vpn-daemon`) is **setuid root**; the plugin can only choose *which already-installed desktop entry* it launches outside the tunnel — it never assembles an arbitrary command line and has no visibility into, or control over, what the binary does once it execs (the network-namespace exclusion itself is entirely inside that binary, outside this plugin's process). |
| Omarchy shell internals (`bar.shell.*`) | `serviceFor(id)`/`appLibrary`/`updateEntryInline()` are undocumented, unversioned surface (see `docs/developers.md`, "Accepted risks"); `BarWidget.qml` gates its `Panel.qml` `Loader` on the service existing, so a null/removed service degrades to "widget shows nothing," not a crash. |
| The installer and its confirm gate | `scripts/install-mullvad` is the plugin's one declared `privilege` capability (`CLAUDE.md` rule 4): launched only from a `ConfirmDialog`-gated button in `Panel.qml`, takes no arguments, and receives no data derived from the CLI or settings. |
| The network update check | `scripts/mullvad-update-check` is a read-only `checkupdates` wrapper with capped output and a watchdog deadline, run hourly by `Service.qml`'s `checkForUpdates()`/timer; it contacts Arch mirrors, never Mullvad's own infrastructure, and never installs anything. |

## What the plugin can and cannot do

- It never sees VPN traffic, tunnel keys, or the Mullvad daemon's own
  control socket/RPC. Every interaction is a spawned `mullvad` (or
  `mullvad-exclude`) process, a direct Quickshell child (`CLAUDE.md` rule
  7) whose stdout/stderr is always treated as untrusted input, never a
  shell string (rule 1).
- It cannot escalate its own privilege: the only privileged action is the
  human-confirmed installer, and the only setuid-binary path is the
  pre-validated launch-outside-tunnel case above — nothing else in the
  plugin invokes `sudo`/`systemctl`/a package manager (rule 4).
- It cannot modify anything under `/usr/share/omarchy/` (rule 5) or
  otherwise change Omarchy shell internals — only read/react to them.
- The account number is stdin-only into `mullvad account login` (rule 2):
  never a CLI argument, never logged, never rendered, redacted at every
  ingestion point.

## Residual accepted risks

- **`SplitParser` pre-newline buffering** (`docs/developers.md`, "Process
  contract"): a trailing partial line is only delivered on process exit.
- **One `IpcHandler` per monitor** (`Panel.qml`): benign duplicate-
  registration warnings, no functional impact.
- **`SIGKILL` of quickshell orphans the `status --json listen` listener**
  until the OS reaps it; nothing this plugin runs is designed to outlive
  its own crash, but the orphan is momentarily undetected by anyone.
- **The hourly `checkupdates` run contacts Arch mirrors** on a fixed
  schedule, independent of Mullvad — the same network exposure as any
  other `pacman-contrib` use on the machine.

## Out of scope

- Compromise of the Mullvad daemon itself, the Omarchy shell process, or
  the user's session/login.
- Supply-chain integrity of the installed `mullvad`/`mullvad-exclude`
  binaries or the `omarchy` shell package — this plugin trusts what is
  already installed on the machine.
- Physical or local access, kernel-level attacks, or anything not reachable
  through this plugin's own CLI-argv, IPC, or settings surface.

## CI as part of this boundary

`.github/**` is exempt from the repo's own comment-hygiene scan
(`test/comment-hygiene.test.js`) and, by extension, from `CLAUDE.md` rule
4's package-manager-literal restriction: workflow files are CI-only
infrastructure, never installed on or executed by an end user's machine,
and legitimately need `pacman`-shaped commands to build a disposable test
container. `README.md` and `docs/developers.md` remain prose-only `.md`
files with no command literals of their own.
