# Changelog

## 1.4.6

- Support the scoped Omarchy 4.0.3+ stock-bar facade while showing a clear unavailable state in replacement bars without service access.
- Restore installed-application discovery through the bounded local `DesktopEntries` catalogue and retain up to ten recent excluded applications.
- Accept safe desktop IDs containing spaces or parentheses, and update recent state only after a launch is dispatched successfully.
- Group related excluded processes into one bounded, removable application row.
- Disable CLI- and daemon-dependent controls when Mullvad is unavailable, with separate-install guidance and no package-manager action.
- Restore correctness, process, UI, lifecycle, facade, read-only CLI, lint, manifest, and clean-archive validation without shell `eval` in probes.
- Validate against exact Omarchy `v4.0.3` and `v4.0.4` shell and plugin-validator sources in CI.
- Keep the privileged System/package installation and update tab deferred; it is not included in this release.

Version 1.4.6 continues the maintained fork's public 1.4.5 sequence while retaining the upstream plugin identity and attribution.
