# Changelog

All notable changes to this project are documented in this file. The format
follows Keep a Changelog[^keep] and the project uses Semantic
Versioning[^semver].

# [Unreleased]

## Added

- Start / Stop for the whole system, kept across reboots; accounts are
  *Actif* or not.
- Read-only status page on the local network (`/status`, port 47700) with
  a verdict telling the owner's stop, maintenance, health and a crashed or
  hung supervisor apart.
- *Nouvelle macro...*: creates `Natro_Macro_<name>` like the others.
- A local account: one account, chosen from a list, runs in the owner's own
  session instead of an RDP session, with guards so the owner's session,
  password, Windows account and Edge are never touched.
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

- Roles: an account may have a role (GuidingALT2) besides its Roblox
  account (PlayerAlt2); a macro named after the role is accepted, and an
  unknown Roblox account is learnt at the first sign-in.
- One common password, chosen by the owner, for every macro account, with
  buttons to set it and apply it to existing accounts.

- No Windows privacy questions for new macro accounts, and their
  per-account privacy choices set to off.
- *Ouvrir Roblox*: opens the Roblox app in an account's session to sign in;
  the preparation does it after installing Roblox. It also opens the
  roblox.com login page in Edge, which Natro's browser fallback needs.
- Coordinated Roblox installs and updates ("Roblox window"): every Roblox
  closed, accounts updated one at a time, the macros that ran restarted.
  Opened automatically by the supervisor when an install or update
  failed or roblox:// is missing, by the preparation of an account, and by
  *Mettre à jour Roblox*.
- Roblox settings in each macro account: what Natro checks, plus
  fullscreen on, haptics off and graphics manual at the lowest level;
  applied before every Natro start, with a button and a column.
- Firewall rules for each macro folder's AutoHotkey (inbound, TCP and UDP,
  private networks), so Windows' prompt no longer stops the macro.
- Edge policies for macro accounts only: no first-run questions, no
  sign-in or sync, Roblox launched from roblox.com without asking.

## Changed

- The text menu moved to `-Action Menu`.
- The assistant leaves the Roblox account empty (learnt at the first
  sign-in): a role prefilled there blocked GuidingALT1's macro.
- Preparing an account excludes any other account using the same macro.
- Sessions are 1920x1080 by default.
- Old macros are no longer converted in place: a clean folder is created.

## Removed

- Creating or adding a bare Windows account, replaced by adding a Roblox
  account.
- Random generated passwords: the owner needs to know the password, as
  Windows sometimes asks for it.

## Fixed

- `roblox://` links are registered for a macro account when missing or
  stale (Windows answered "get an app to open this 'roblox' link" for
  PlayerAlt3 after a reinstall), with the installer's own keys, and a Roblox
  started less than 3 minutes ago is no longer stopped by *Ouvrir Roblox*.
- The Roblox installer is waited for until it ends; stopping when its first
  file appeared could leave an invisible Roblox behind.
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
