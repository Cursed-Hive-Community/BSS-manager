# BSS Manager

Runs several Natro Macro instances for Bee Swarm Simulator on one Windows PC,
one Windows account per macro, each in its own Remote Desktop session, and
keeps them running.

Goal: one click launches every macro, up to date, and everything comes back
by itself after a crash.

# What it does

- Keeps RDP Wrapper usable: when Windows Update replaces `termsrv.dll`, it
  fetches the `rdpwrap.ini` that knows the new build[^ini] and restarts the
  Remote Desktop service.
- Manages the macro accounts: creates Windows accounts, stores their
  passwords in Credential Manager, opens one loopback session per account
  (`127.0.0.2`, `127.0.0.3`...).
- Updates each macro from git, on the branch it follows, through the fork's
  own tools[^fork], then starts Natro in the right session with the macro
  already running.
- Supervises: a background task checks every minute that each session is
  connected and each Natro runs, and restarts what is missing.
- Optional Windows automatic sign-in, so the PC gets back to a running state
  after a crash or a power cut.

# Requirements

- Windows 10 or 11, Windows PowerShell 5.1.
- RDP Wrapper installed in `C:\Program Files\RDP Wrapper`.
- Git for Windows.
- Natro Macro folders, ideally on the Cursed fork[^fork].

# Installation

1. Put this folder at `C:\BSS-Manager`. Scheduled tasks point at it.
2. Double-click `BSS-Manager.bat` and accept the administrator prompt: the
   window opens.
3. Tab *Comptes*: for each account, *Associer une macro...* and
   *Mot de passe...*. The *État* column says what is still missing.
4. Tab *Réglages*, *Installer / réparer*. It restricts the folder to
   administrators, registers the supervisor and the one-click task, and
   creates two desktop shortcuts.
5. Optionally *Connexion automatique de Windows*, *Activer...*.

# Daily use

- **BSS - Tout lancer** on the desktop: RDP Wrapper check, macro updates,
  sessions, macros. No administrator prompt.
- **BSS Manager** on the desktop: the window. Its tabs:
  - *Comptes*: live state, start, stop, restart, pause, passwords, macros;
  - *Macros*: every Natro folder found, branch, update, conversion;
  - *Réglages*: RDP Wrapper, supervisor, automatic sign-in, settings,
    installation;
  - *Journal*: the log, live.
- Long actions run in the background; the window shows them in *Journal*
  and in its status bar, one at a time.
- To configure a macro by hand, pause its account first, or the supervisor
  restarts what you close.
- The text menu is still there: `BSS-Manager.bat -Action Menu`.

Command line, from an administrator PowerShell:

```powershell
.\BSS-Manager.ps1 -Action Start                    # same as the shortcut
.\BSS-Manager.ps1 -Action Stop -Account Roblox1    # pause and close
.\BSS-Manager.ps1 -Action Restart -Account Roblox1 # restart one macro
.\BSS-Manager.ps1 -Action UpdateMacros             # update and restart
.\BSS-Manager.ps1 -Action SetBranch -Path <dir> -Branch main
.\BSS-Manager.ps1 -Action ConvertMacro -Path <dir> # old release -> fork
.\BSS-Manager.ps1 -Action Update -Force            # re-fetch rdpwrap.ini
.\BSS-Manager.ps1 -Action Status                   # no admin needed
.\BSS-Manager.ps1 -Action SelfTest                 # no admin needed
```

# After a crash

1. Windows restarts. After a power cut this needs the firmware setting
   *Restore on AC power loss* set to *Power on*.
2. Automatic sign-in opens the owner's session.
3. The task scheduler starts the supervisor.
4. The supervisor reopens one session per minute; each session starts its
   Natro with the macro running.

A PC that hangs without rebooting cannot be helped by any software on it.

# Branches

Each macro follows the branch in `GitBranch` and the repository in
`GitRepoUrl` of its `settings\nm_config.ini`, the keys the macro's own
Git Sync button uses. Without them it follows `DefaultBranch` from
`config.json`. Change either from `5. Comptes et macros`, `2.`.

# Configuration

`config.json` is created on first run and ignored by git.

| Key | Default | Meaning |
|---|---|---|
| `MacroRoot` | `G:\Macro bee swarm` | where macro folders are searched |
| `DefaultBranch` | `feature/rays-extensions` | branch without `GitBranch` |
| `DefaultRepoUrl` | the Cursed fork | repository without `GitRepoUrl` |
| `UpdateMacrosOnStart` | `true` | update stopped macros on start |
| `SessionWidth`, `SessionHeight` | `1280`, `720` | session size |
| `DelayBetweenSessionsSec` | `20` | gap between two sessions on start |
| `NatroStartDelaySec` | `15` | wait in a session before Natro |
| `SupervisorIntervalSec` | `60` | time between two checks |
| `RestartGraceSec` | `120` | minimum time before restarting |
| `InboxEnabled` | `false` | accept restart requests, see below |

# Restart requests (inbox)

Off by default. With `InboxEnabled` set and installation run again, another
program, such as the fork's fleet, may drop a JSON file in `inbox\`:

```json
{"action": "restart", "account": "Roblox1"}
{"action": "restart", "macro": "Natro_Macro_GuidingALT1"}
```

The supervisor reads at most 20 files per pass, deletes each one, and refuses
any other action, an unknown account or a file over 4 KB.

# Remote Desktop notes

- `rdpwrap.ini` must use CRLF line endings: rdpwrap.dll reads no section
  from an LF file, and Windows then refuses any second session with "all
  connections are in use". BSS Manager converts it and flags LF as broken.
- Sessions open with `mstsc /v:`, not with an `.rdp` file: Windows holds
  every unsigned `.rdp` file behind an "unknown publisher" warning.

# Security

- The folder is writable by administrators only, since tasks run it with
  administrator rights. A write right added by hand for development is
  removed by the next *Installer / réparer*.
- Account passwords live in Credential Manager; the auto-logon password is an
  LSA secret, as Sysinternals Autologon stores it[^autologon]. Neither is
  written to a file or a log.
- Updates run the fork's scripts with administrator rights: trust the
  repository a macro follows.

# Files

| Path | Role |
|---|---|
| `BSS-Manager.ps1` | entry point: window, menu and command line |
| `lib\` | one module per concern |
| `config.json` | wanted state, written by the menu |
| `state\supervisor.json` | what the supervisor saw and did |
| `logs\bss-manager.log` | log, rotated at 2 MB |

See [TODO.md](TODO.md) for what is proven and what is not.

[^ini]: <https://github.com/sebaxakerhtc/rdpwrap.ini>
[^fork]: <https://github.com/Cursed-Hive-Community/NatroMacroCursed>
[^autologon]: <https://learn.microsoft.com/sysinternals/downloads/autologon>
