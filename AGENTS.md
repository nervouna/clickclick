# Project Instructions

## Product

- ClickClick, known in Chinese as "咔咔咔咔计数器", is a macOS app that tracks user input activity.

## Development Philosophy

- This is an experimental project for personal use. YOLO is encouraged: move forward proactively within the authorized scope, and prioritize completion over perfection.

## Scope

- Single user, single install. Do not add compatibility shims, deprecated stubs, or defenses against other processes or older builds writing the database.
- Schema changes are forward-only: bump `schemaVersion`, migrate from the previous version only, and reject anything older.

## Tests

- Test behaviour that exists. No test-only parameters or hooks in production code unless a test cannot be written without one.
- No timing or memory thresholds. The whole suite should run in about a second.
- `CoreHIDInputMonitor` cannot be unit tested. Say so when changing it and list what to check on real hardware.

## Build

- `ClickClick.xcodeproj` is the source of truth and is edited by hand when files are added or removed.
- Never commit build output. Release packages go in `dist/`, which is ignored.
- The real database lives in the app's sandbox container, which agents cannot read. Do not launch a build that carries a new migration without the user's go-ahead.

## Git Commits

- Use the `type(scope): message` commit format.
- Commit messages must be entirely in lowercase English, including `type`, `scope`, and `message`.
