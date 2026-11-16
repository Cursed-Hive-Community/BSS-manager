# Changelog

All notable changes to this project are documented in this file. The format
follows Keep a Changelog[^keep] and the project uses Semantic
Versioning[^semver].

# [Unreleased]

## Added

- A window (WinForms), opened by default: live account table, start, stop,
  restart, pause, passwords, macro assignment, branches, updates,
  conversion, RDP Wrapper, supervisor, automatic sign-in, settings and log.
- Command-line actions `SetBranch`, `ConvertMacro` and
  `UpdateMacros -Path`, used by the window for its long actions.
- An *État* column saying what an account still lacks to run unattended.
- Roblox accounts at the centre: each one gets its own Windows account,
  macro folder and session. The assistant suggests them from folder names
  and prepares them in a queue: Windows account with a generated password,
  clean Cursed macro with the old settings, old folder moved to
  `_Anciennes`, first sign-in, signed Roblox installer.
- Signed-in Roblox account read from `appStorage.json`; an account whose
  Roblox name, signed-in name and macro folder disagree does not run.

## Changed

- The text menu moved to `-Action Menu`.
- Sessions are 1920x1080 by default.
- Old macros are no longer converted in place: a clean folder is created.

## Removed

- Creating or adding a bare Windows account, replaced by adding a Roblox
  account.

## Fixed

- `rdpwrap.ini` is always installed with CRLF line endings, and an installed
  LF file is converted. rdpwrap.dll reads no section from an LF file, which
  left Windows at one session ("all connections are in use").
- Sessions open with `mstsc /v:` instead of an `.rdp` file, which Windows now
  holds behind an "unknown publisher" warning every time.
- At most one connection window per account; the supervisor no longer adds
  one every minute.
- The supervisor only runs accounts with a saved password and a macro.
- Installation replaces the whole folder access list, so a write right
  granted by hand is removed.

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
