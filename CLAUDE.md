# Mullvad VPN for the Omarchy bar (`halmylyseas.mullvad`)

An Omarchy shell plugin: a bar widget and panel for Mullvad VPN — connect,
disconnect, relay/location search and favourites, DNS/anti-censorship/LAN/
lockdown settings, launching apps outside the tunnel, and a relay world map —
driven entirely by the user's local Mullvad CLI (`mullvad`).

Forked from [kallupx/oma-mullvad](https://github.com/kallupx/oma-mullvad)
(upstream history kept; `upstream` remote points at it). The fork exists to
diverge on identity and house rules (own marketplace listing, AUR-install
button removed) while staying upstreamable: fixes here are meant to be
PR-able back to kallupx where they apply.

Author: kallupx (upstream OmaMullvad). Fork maintained by HalmyLyseas.

## Architecture

`manifest.json` declares kinds `service` + `bar-widget`. `Service.qml` is a
machine-wide singleton (one poller/listener/action-queue total, not one per
monitor); `BarWidget.qml` is the per-monitor bar-slot entry point, resolving
the singleton via `bar.shell.serviceFor("halmylyseas.mullvad")`; `Panel.qml`
is the popup, injected with `bar`/`settings`/`anchorItem`/`hostWidget`/
`service` by `BarWidget.injectPanel()`. Full detail, including why the
panel `Loader` is gated on the service existing: `docs/developers.md`.

## Hard rules

1. **The plugin never runs a mutating Mullvad command from remote/derived
   data as a shell string.** Every process spawn is a fixed argv array
   (`Model.argv`); a variable or relay-derived value is always a separate
   argv element, never interpolated into a `-c`/`-lc` string.
2. **Account numbers are stdin-only.** `mullvad account login` reads the
   number over standard input; it is never a CLI argument, never logged,
   never rendered, and every ingestion point redacts it.
3. **`textFormat: Text.PlainText` on every local `Text{}` sink** (enforced by
   a test that scans every `.qml` file at the plugin root) — remote/relay
   strings are never rendered as rich text.
4. **No package-manager, service-manager, or privilege-escalation command
   strings shipped anywhere, EXCEPT `scripts/install-mullvad`** — no other
   file may contain an Arch/AUR install helper, an init-system control verb,
   or a privilege-elevation wrapper. `scripts/install-mullvad` is the single
   declared exception: it is launched only from a ConfirmDialog-gated button
   in `Panel.qml`, takes no arguments and receives no data from the CLI or
   settings, and is the plugin's one declared `privilege` capability (S9,
   `19-s9-install-prompt-spec.md`) — the same mechanism Omarchy's own menu
   uses for its "Install > Service" entries. Everywhere else, prerequisites
   remain prose + links only, never a command the plugin would run for the
   user.
5. **Never modify anything under `/usr/share/omarchy/`** (reading is
   encouraged). Never run `omarchy refresh`/`omarchy reinstall`.
6. Read-only toward the Mullvad daemon during development/testing: never run
   `mullvad connect|disconnect|reconnect|... set|account login|logout|
   split-tunnel delete` from a dev/test session outside a human-approved
   live-test pass. `test/cli-contract.mjs` is deliberately read-only.
7. **Every `mullvad` call is a direct Quickshell `Process` child; never a
   shell wrapper.** S10 (`23-s10-native-process-spec.md`) removed
   `scripts/bounded-command` from the CLI path for exactly this reason: a
   wrapper is a grandchild relationship as far as Quickshell's process
   tree is concerned, and both real bugs this project has had (the
   orphaned `status --json listen` listener, `06-verdict.md` D2; the empty
   stdin on `account login`, `22-login-stdin-bug.md`) were bash-semantics
   bugs in that wrapper, not in this plugin's own argv/redaction logic.
   Deadlines and output caps are enforced in QML instead — see
   `docs/developers.md` "Process contract" for the exact mechanism
   (per-process watchdog `Timer`s, `signal(15)` then `signal(9)`, the
   shared `_appendBoundedOutput` cap-and-kill helper). `scripts/` may still
   contain non-CLI helper scripts (`install-mullvad`,
   `mullvad-package-info`, `mullvad-update-check` — none of them spawn
   `mullvad` itself), each still a direct `Process` child in its own right.

## Working agreement

- Working repo: `~/git/oma-mullvad/work` (clone of the canonical installed
  folder, branch `main`). Deploy with:
  `git -C ~/.config/omarchy/plugins/halmylyseas.mullvad pull ~/git/oma-mullvad/work main`
- The PM workspace's `exchange/` (`~/git/oma-mullvad/exchange/`) holds the
  numbered handoff docs — read the **highest-numbered** doc first.
- `bash test/all` before every deploy; `omarchy plugin validate .` and
  qmllint (0 errors) before every commit that touches `.qml`.
- Marketplace submission is a human-approved step only — never filed by an
  agent. See `docs/developers.md` "Releasing".
