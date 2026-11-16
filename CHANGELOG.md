# Changelog

All notable changes to this project are documented in this file. The format
follows Keep a Changelog[^keep] and the project uses Semantic
Versioning[^semver].

# [Unreleased]

# [0.1.0] - 2026-11-16

## Added

- RDP Wrapper upkeep: `rdpwrap.ini` fetched when `termsrv.dll` changes,
  service DLL and Remote Desktop switch repaired, service restarted.
- Macro accounts: creation, existing accounts, stored passwords, loopback
  sessions.
- Macro folders: discovery, assignment, branch per macro, git updates through
  the fork's tools, conversion of old release folders.
- One-click start through a scheduled task, without an administrator prompt.
- Supervisor restarting closed sessions and stopped macros.
- Windows automatic sign-in stored as an LSA secret.
- Restart request inbox, off by default.
- Self-test of the parts that need no session.

[^keep]: <https://keepachangelog.com/en/1.1.0/>
[^semver]: <https://semver.org/>
