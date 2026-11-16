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
3. Tab *Comptes Roblox*, *Ajouter des comptes Roblox...*: tick the Roblox
   accounts suggested from your folder names, fix their names, pick the base
   folder of each, and let it prepare them one after the other. Then sign in
   to Roblox once in each session it opened. The *État* column says what is
   still missing.
4. Tab *Réglages*, *Installer / réparer*. It restricts the folder to
   administrators, registers the supervisor and the one-click task, and
   creates two desktop shortcuts.
5. Optionally *Connexion automatique de Windows*, *Activer...*.

# Daily use

- **BSS - Start** on the desktop: RDP Wrapper check, macro updates,
  sessions, macros, supervision. No administrator prompt.
- **BSS Manager** on the desktop: the window. Its tabs:
  - *Comptes Roblox*: live state, add accounts, start, stop, restart,
    open a session, pause, macro, password;
  - *Macros*: every Natro folder found, *Nouvelle macro...* (creates
    `Natro_Macro_<name>` on `DefaultBranch`, settings fresh or copied from
    another macro left untouched), branch, update;
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
.\BSS-Manager.ps1 -Action AddRoblox -Roblox <name> -Path <base folder>
.\BSS-Manager.ps1 -Action AddRoblox -Role <role>   # Roblox account learnt
.\BSS-Manager.ps1 -Action Update -Force            # re-fetch rdpwrap.ini
.\BSS-Manager.ps1 -Action Status                   # no admin needed
.\BSS-Manager.ps1 -Action SelfTest                 # no admin needed
```

# Roblox accounts

One Roblox account has its own Windows account, its own macro folder
`Natro_Macro_<name>` and its own session. The name is the Roblox account's
when it is known. Some macros are named after a role instead (GuidingALT2
is played by PlayerAlt2): leave the Roblox account empty and the role gives
the name; the Roblox account is then learnt at the first sign-in, and any
other account signing in later is refused. A role is also shown in its own
column, and a macro folder named after it is accepted.

Every macro account shares one password chosen by the owner (*Réglages*,
*Mot de passe des comptes macro*), since Windows sometimes asks for it. It
is kept in Credential Manager, like each session's copy.

Adding an account runs every step, each skipped when already done, so
*Reprendre la préparation* resumes an interrupted one:

1. Windows account created with the common password.
2. Macro: a Cursed folder is used as is; otherwise a clean one is cloned
   from a Cursed instance with the fork's `nm-new-instance.ps1`, the base
   folder's `settings` are copied in, it is updated to `DefaultBranch`, and
   the base folder is moved to `_Anciennes`.
3. Session opened once, which builds the Windows profile, without
   Windows' privacy questions (policy `DisablePrivacyExperience`); the
   account's own privacy choices are then set to off. Device-wide ones stay
   as set for the PC.
4. Roblox installed in that session from roblox.com, only if the installer
   carries a valid Roblox Corporation signature, then opened.
5. You sign in to Roblox in that session, by hand, once, in the app and on
   the roblox.com page opened in Edge (*Ouvrir Roblox* opens both again if
   needed). The supervisor starts the macro about two minutes later.

Roblox's installer fails ("failed to access client process info: Accès
refusé") whenever a Roblox of another Windows account runs on the PC, and
Roblox forces an update about weekly. So every Roblox install or update
runs in a "Roblox window": the running macros are stopped, every Roblox of
the macro accounts is closed, accounts are updated one at a time, then the
macros that ran are restarted. The supervisor opens one by itself when an
account's last installer crashed or its `roblox://` links are missing, at
most every 10 minutes; *Mettre à jour Roblox* opens one on demand; adding
an account installs Roblox in one. The owner's own Roblox counts too: the
window waits until it is closed, unless *Réglages* allows closing it.

Natro only supports the Roblox installed from roblox.com ("Web Version"),
not the Microsoft Store one ("UWP"). It tells them apart by the command of
the `roblox://` link (`HKCR\roblox\shell\open\command` containing
`RobloxPlayerBeta`): without that registration it finds no Web Roblox and
cannot open its links either. BSS Manager installs the roblox.com version
and writes that registration when it is missing.

Natro reconnects through `roblox://` links, but every fifth attempt it
falls back to the browser with the private server's web address. That is
why each macro account gets, beforehand: firewall rules for its macro
folder's AutoHotkey (inbound, TCP and UDP, private networks only), and Edge
policies in its own registry hive (no first-run questions, no sign-in or
sync, Roblox opened from roblox.com without asking). The owner's own Edge
is not touched.

Roblox's own settings are set in each macro account's
`GlobalBasicSettings_*.xml`: what Natro checks (graphics manual and lowest,
smallest text, Shift Lock on, classic camera, keyboard movement, no
inverted camera or profiler) plus fullscreen on and haptics off. Roblox
rewrites that file when it exits, so it is written while Roblox is closed:
before every Natro start (closing a Roblox left open, which Natro reopens)
and before a session opens. *Réglages Roblox* applies it on demand and the
*Réglages Roblox* column shows whether an account matches.

The Roblox account signed in is read from
`%LOCALAPPDATA%\Roblox\LocalStorage\appStorage.json` in each profile. An
account only runs when the signed-in account matches its Roblox account
(or is the first one, while none is recorded) and its macro folder is named
after its Roblox account, role or Windows account; otherwise *État* says
what differs. Profiles created by BSS Manager are private, so this is only
visible with administrator rights (the window has them).

# Start, Stop and active accounts

- *Actif*: an active account is launched by Start and looked after by the
  supervisor; an inactive one is left alone.
- *Start* switches the whole system on (kept in `config.json` as
  `Running`), launches the active accounts and lets the supervisor restart
  whatever stops. *Stop* closes every session, pauses the accounts and
  switches the system off: the supervisor then does nothing, even after a
  reboot, until the next Start. *Lancer* / *Arrêter* act on one account.
- Closing the window changes nothing: the window is a dashboard, the
  supervisor (a scheduled task) does the work.

# Status page

With `StatusServerEnabled`, `http://<PC>:47700/status` answers a read-only
JSON document for a watchdog (the planned Raspberry Pi) and for the fleet:
no action is possible through it, it carries no secret or address, and its
firewall rule admits private networks only. The supervisor starts it and
keeps it alive; it runs as its own process.

| `health` | Meaning | A watchdog should |
|---|---|---|
| `stopped` | Stop pressed, or the supervisor disabled by the owner | nothing |
| `maintenance` | a Roblox window is open | nothing |
| `ok` | the supervisor passed recently | nothing |
| `degraded` | the supervisor crashed or hangs | alert only |

Cutting a PC's power is right only when neither this page nor a ping
answers for several minutes: a crash of BSS Manager alone never needs it.
`accounts` lists each account's session, Natro and state as the supervisor
last saw them, and `supervisor.ageSec` how old that is.

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
| `SessionWidth`, `SessionHeight` | `1920`, `1080` | session size |
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
- The common macro-account password and each session's copy live in
  Credential Manager; the auto-logon password is an LSA secret, as
  Sysinternals Autologon stores it[^autologon]. None is written to a file or
  a log.
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
