# Contributing

## Process and security contract

- Every `mullvad` invocation must be a direct Quickshell `Process` child. Do not insert a shell wrapper between Quickshell and the CLI.
- Build command arguments only through the fixed-argv allowlist in `Model.argv`. Never construct a shell command from runtime data.
- Send a Mullvad account number only to `mullvad account login` over standard input. Never persist, log, render, or place it in argv.
- Treat CLI, process-table, desktop-entry, and settings text as untrusted. Bound and redact it before exposing it to QML.
- Routine tests must not mutate the live VPN, package manager, or service manager. Use the existing mocks for connect, disconnect, settings, package, service, lock, and suspend behavior.

## Development workflow

Use tests first for behavior changes: add a focused failing test, confirm the expected failure, implement the minimum change, then run the relevant suite. Before committing, run:

```bash
bash test/ci-local --no-cage
```

QML service changes require `omarchy restart shell` when testing an installed copy; plugin hot reload does not replace a `keepLoaded` service reliably. Installed testing is separate from source-tree validation and must be explicitly requested.

## Publication

Keep source commits, installed deployment, pushing, tagging, and releasing as separate steps. Publish only an exact reviewed commit, verify the remote full SHA, and require successful GitHub Actions before tagging or requesting marketplace verification.
