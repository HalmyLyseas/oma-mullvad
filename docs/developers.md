# Developer notes

The distilled why and how of this plugin, for a contributor starting from a
bare clone. The README covers using it; `CLAUDE.md` carries the project
rules. `exchange/` (present alongside this repo during the S1-S6 migration
project, not required to build or maintain the plugin) corroborates specific
claims below — treat it as evidence, not something a fresh clone needs.

## Architecture

| File | Role |
|---|---|
| `manifest.json` | `kinds: ["bar-widget"]` only — no `service` kind yet. |
| `Service.qml` | All state: Mullvad CLI process spawns, polling, the account/relay/settings model. **Currently instantiated once per `Panel.qml`, i.e. once per monitor** — this plugin has no standalone `service` kind, so on a multi-monitor box each monitor runs its own poller, its own `status --json listen` listener, and its own IPC handler against the same daemon. A future pass may split a singleton `Service` out via `entryPoints.service` + `bar.shell.serviceFor(...)` (mirrors ristretto/github-status); until then, treat any per-monitor duplication (extra listener processes, duplicate-IpcHandler warnings) as expected, not a bug to silently work around. |
| `Panel.qml` | The bar button + popup panel: Overview, Locations, Advanced, Excluded Apps pages. One instance per monitor, hosts its own `Service.qml`. |
| `Model.js` | Pure ES5 logic: CLI-output parsers, the mutating-command argv allowlist, redaction, field/list caps. Plain Node can `require()` it (`test/model.test.js`). |
| `OmaDropdown.qml` / `OmaSearchableDropdown.qml` | Shared dropdown widgets ("Oma" = Omarchy, kept from upstream naming — not a rebrand miss). |
| `ThemeIcon.qml`, `WorldMap.qml` | Icon theming and the relay world map. |
| `scripts/bounded-command` | `bash`, wraps CLI spawns with a hard deadline + output-line cap so a stuck/verbose child can't hang the panel or flood memory. |

## Dev workflow

Every save under `~/.config/omarchy/plugins/` triggers a full bar reload
(`inotifywait -r`), so develop in the separate `work/` clone and deploy in
one burst:

```bash
git -C ~/.config/omarchy/plugins/halmylyseas.mullvad pull ~/git/oma-mullvad/work main
omarchy restart shell   # required after structural / new-file changes
omarchy-shell halmylyseas.mullvad __probe__   # "Function not found." = loaded
```

## Testing

- `bash test/all` — Node unit tests (`Model.js`, the `bounded-command`
  guard, a QML Text-sink audit over every `.qml` file at the plugin root)
  then `test/cli-contract.mjs`.
- `test/cli-contract.mjs` runs the real local `mullvad` CLI with read-only
  subcommands only (`--version`, `status --json`, `relay list/get`,
  `auto-connect get`, `lan get`, `lockdown-mode get`, `dns get`,
  `anti-censorship get`, `split-tunnel list`) and asserts the parsers in
  `Model.js` accept the live output shape and never surface an account
  number. It never mutates daemon state.
- `omarchy plugin validate .` and qmllint on every `.qml` file must show 0
  errors before a commit that touches QML.

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
