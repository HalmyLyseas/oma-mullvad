# Changelog

## 1.5-rc

- Adopt `halmylyseas.oma-mullvad` as the maintained fork identity and `HalmyLyseas` as manifest author; retain original MIT attribution.
- Require an explicit switch from the old plugin ID; update installation and IPC examples for this repository.
- Expand isolated service, scoped-settings, recovery, and Qt Quick input coverage under Cage.
- Simplify command construction, private output buffers, DNS dispatch and excluded-app search without weakening safety limits.
- Keep code comment blocks to two lines maximum, with longer explanations in developer documentation.

## 1.4.6

- Support the scoped Omarchy 4.0.3+ stock-bar facade while showing a clear unavailable state in replacement bars without service access.
- Restore installed-application discovery through the bounded local `DesktopEntries` catalogue and retain up to ten recent excluded applications.
- Accept safe desktop IDs containing spaces or parentheses, and update recent state only after a launch is dispatched successfully.
- Group related excluded processes into one bounded, removable application row.
- Disable CLI- and daemon-dependent controls when Mullvad is unavailable, with separate-install guidance and no package-manager action.
- Restore correctness, process, UI, lifecycle, facade, read-only CLI, lint, manifest, and clean-archive validation without shell `eval` in probes.
- Validate against exact Omarchy `v4.0.3` and `v4.0.4` shell and plugin-validator sources in CI.
- Restore the fifth System tab with bounded, plain-text CLI, daemon, PID, package metadata, suggested-upgrade, and timestamped read-only update-check diagnostics.
- Keep diagnostics available without the CLI or daemon, run `checkupdates` outside the service busy queue with debounce and TERM/KILL deadlines, and provide no package installation, update, service mutation, privilege, or terminal-launch action.

Version 1.4.6 continues the maintained fork's public 1.4.5 sequence while retaining the upstream plugin identity and attribution.
