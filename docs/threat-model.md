# Threat model

Scope: `halmylyseas.oma-mullvad`, an Omarchy shell plugin using the local Mullvad CLI. The mandatory development and execution rules are in [CONTRIBUTING.md](../CONTRIBUTING.md); [developer notes](developers.md) describe the architecture and validation gates.

## Assets

- The account number entered for login, which must not reach argv, logs, settings, or rendered text.
- Truthful tunnel state and the user's network policy, including lockdown and excluded applications.
- The local desktop-entry catalogue and the plugin's own favourites and recent selections.

## Boundaries and safeguards

| Boundary | Safeguard |
|---|---|
| Mullvad commands | `Model.argv` constructs fixed allowlisted argv. Each `mullvad` invocation is a direct Quickshell `Process` child, never a dynamically constructed shell command. Actions require both the CLI and daemon to be available; read probes bypass the action guard so recovery remains possible. |
| Account login | The number is validated and sent only over the login child's stdin. Temporary references are cleared and stdin closes after sending. Ingested output is redacted. This is not a guarantee of secure erasure from the JavaScript heap. |
| CLI stdout/stderr | Finite processes count output across both streams, cap retained data at 4,096 lines and 262,144 characters, and terminate on overflow. Chunk parsing also bounds unterminated data; the listener rejects lines over 8,192 characters. Watchdogs escalate TERM to KILL with process-generation/PID guards. |
| Status polls and listener events | Accepted tunnel states and status payload shapes are checked before applying state. A malformed successful poll reports an error rather than inventing readiness. Previous accepted state is retained on parse failure. Sequence guards prevent an older poll, including its errors, from replacing a newer listener event. Non-tunnel listener messages do not advance the applied-state sequence. |
| Settings and UI text | Persisted favourites, recent locations, and recent desktop IDs are copied/scanned through at most 256 input entries, then normalized and capped at 9, 5, and 10 respectively. The separately bounded relay catalogue retains its 512-location limit. External display fields are bounded and redacted; QML text sinks use plain text. |
| Desktop entries and excluded launches | Catalogue searches scan at most 4,096 entries and bound each field and keyword list. Validated desktop IDs become the fixed argv `mullvad-exclude uwsm-app -- gtk-launch <id>`; there is no shell expansion. The installed launcher and desktop-entry contents remain trusted dependencies. The plugin does not control the exclusion binary's privilege implementation. |
| Omarchy integration | The widget resolves only its own service through the scoped facade, destroys its panel when that service disappears, and persists only its own inline settings entry. App discovery uses public Quickshell `DesktopEntries`, not a private host registry. |
| System diagnostics | Local package metadata is read from bounded pacman database files for two allowlisted package names. Update checks use a bounded, debounced, read-only `checkupdates` helper, with independent helper and service timeouts. The System page has no installer, package-update action, service mutation, privilege escalation, or app-launch controls. |
| Local IPC | The handler exposes fixed operations, not command evaluation. `lockdown` accepts only exact `on` and `off`; the service applies the same readiness guard as UI actions. `checkUpdates` performs only the read-only diagnostic. `systemInfo` returns bounded diagnostic values and last-success update results. |

## Residual risks and non-goals

- This plugin does not inspect VPN traffic, tunnel keys, or the daemon's control socket. It trusts the installed CLI, daemon, Omarchy/Quickshell runtime, and local desktop entries.
- A compromised local session or runtime is outside this boundary. IPC is a local control surface, not an authentication boundary against that session.
- Update checks can contact configured Arch mirrors independently of the VPN state. A failed check retains the last successful result and timestamp; callers must inspect `updateCheckStatus` and `updateCheckedAt` for freshness.
- Per-monitor panels can register the same IPC target. Host routing and duplicate-registration behavior belong to Omarchy/Quickshell.
- Process cleanup is exercised for normal exits, failures, deadlines, and floods. Abrupt death of the hosting runtime cannot guarantee child cleanup.
- Output bounds cover retained plugin buffers, not all memory used internally by the runtime while delivering a single process chunk.

## Validation boundary

`bash test/ci-local` runs lint, manifest validation, model/security tests, mocked CLI contracts, Cage-backed service/UI/physical-input/settings probes, and proposed-index archive checks. VPN mutations, application launches, process lookups, and network update checks are mocked. Tests do not install packages, control the real daemon, change installed plugins, or write under `/usr/share/omarchy/`. Disposable CI dependency installation is separate from the installed plugin's capabilities.
