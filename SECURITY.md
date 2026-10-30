# Security

ClickClick holds the Input Monitoring permission, so it sees every key press on every keyboard attached to the Mac. Its promise is that it keeps only counts: no text, no key order, no exact times, no app or window, and nothing leaves the Mac. It runs in the App Sandbox and keeps its database inside its container. Release builds are signed with a Developer ID and notarized.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately through GitHub: **Security → Report a vulnerability** on this repository ([direct link](https://github.com/nervouna/clickclick/security/advisories/new)). Include what you did, what happened, and the release or commit you tested.

You will get an answer within a week. Fixes land on `main`; there are no maintained release branches.

## In scope

- Anything ClickClick stores or logs that could reveal typed text, key order or exact key press times
- Any data leaving the Mac
- A way for another process to read the statistics or use ClickClick's Input Monitoring permission
- A release build that is not signed and notarized as published

## Out of scope

- Anything that needs an already compromised user account or administrator access
- Someone with access to your user account reading the per-key counts, which are stored as described in the README
- What other apps can do once you grant them Input Monitoring
