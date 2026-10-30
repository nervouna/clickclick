# Contributing

ClickClick is an experimental personal project, but bug reports and fixes are welcome.

## Issues

- **Bugs:** use the bug report form. Say which keyboards were connected (built-in, USB, Bluetooth) and what the counts showed; a suggested fix is a bonus.
- **Security and privacy problems:** report them privately, see [SECURITY.md](SECURITY.md).
- **Feature ideas:** open an issue to discuss it first. ClickClick stays small on purpose, and nothing that stores more than counts will fit.

## How the project is developed

Most of the code is written by coding agents following [AGENTS.md](AGENTS.md); its rules apply to human contributions too. In short:

- Single user, single install: no compatibility shims or defenses against older builds writing the database.
- Database schema changes are forward-only: bump `schemaVersion`, migrate from the previous version only.
- Test behaviour that exists, with no timing or memory thresholds; the suite runs in about a second. Run it with `xcodebuild -project ClickClick.xcodeproj -scheme ClickClick -destination 'platform=macOS' test`.
- `CoreHIDInputMonitor` cannot be unit tested. When you change it, say so and list what to check on real hardware.
- `ClickClick.xcodeproj` is edited by hand when files are added or removed. Never commit build output.
- Commit messages use `type(scope): message`, entirely in lowercase English.

## Pull requests

Describe the change, list the commands you ran and their results, and for changes to key counting, what you checked on real keyboards.
