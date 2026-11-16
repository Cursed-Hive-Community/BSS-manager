# TODO

What is proven, by which kind of evidence, and what is not.

# Proven by the self-test (`-Action SelfTest`, 2026-11-16)

- [x] native types load; sessions enumerate
- [x] Credential Manager write, read and delete
- [x] configuration defaults survive a JSON round trip
- [x] loopback addresses skip used ones
- [x] an empty account list means enabled accounts only
- [x] RDP Wrapper state readable; the installed ini knows `termsrv.dll`
- [x] installed ini uses CRLF; LF is detected and converted
- [x] mstsc arguments carry the account address and size, no `.rdp` file
- [x] `nm_config.ini` edits keep other keys and sections
- [x] macro discovery finds a Cursed folder with its tools
- [x] inbox keeps valid requests only and empties itself

# Proven on this machine (2026-11-16)

- [x] the ini offsets for termsrv.dll 10.0.26100.9818 land on the right
      functions (checked against Microsoft's public symbols)
- [x] an LF `rdpwrap.ini` explains the "all connections are in use" error:
      the last multi-session logon (12.11) used a CRLF file
- [x] `-Action Update` converts the LF file and restarts the service
- [x] `mstsc /v:` opens no "unknown publisher" warning
- [x] after the CRLF repair, Roblox1 signs in next to the owner's console
      session, both active (events 41, 42, 21 at 11:13, no disconnect)
- [x] the window's *Lancer* button opened that session
- [x] the window builds and renders its four tabs with real data
      (`-Action Gui -SnapshotDir`, images checked by eye)
- [x] the add-accounts assistant renders the 8 accounts suggested by the
      folder names, with their base folders
- [x] the signed-in Roblox account is read (Roblox2: PlayerAlt4), and
      Roblox2 holding GuidingALT1's macro is reported as not ready
- [x] `AddRoblox` end to end in real use (GuidingALT2, then PlayerAlt2):
      account, clean macro from `nm-new-instance.ps1`, old settings, move to
      `_Anciennes`, first sign-in, certificate approval, signed Roblox
      installer through the one-shot task, Roblox sign-in detected, Natro
      started (12:24-12:26)
- [x] `AddRoblox` with the common password and a role (GuidingALT1,
      12:42); its Roblox account learnt by the window at the first sign-in
      (PlayerAlt1, 12:54); the other account on the same macro
      (Roblox2) excluded
- [x] the supervisor saw GuidingALT1 ready and started Natro after its
      2-minute grace (12:58), Natro running at 12:59
- [x] per-account privacy set to off in a signed-in account's hive
      (GuidingALT1, PlayerAlt2)
- [x] a brand-new account end to end (PlayerAlt3, 13:04-13:08): installer
      waited for to its end (52 s), Roblox opened and shown, macro started
      by the supervisor after the sign-in; three macros running together

# Loads, never driven

Parsed and loaded, but nobody has run these yet:

- [ ] window buttons and dialogs, clicked by a person (only the rendering
      is proven)
- [ ] Windows' privacy screen skipped at a new account's first sign-in
      (PlayerAlt3 prepared after the policy; the owner reported other
      problems, not this screen: to confirm)
- [ ] firewall rules created beforehand stop the AutoHotkey prompt on a
      new macro folder (the owner accepted it by hand for PlayerAlt3 13:09)
- [ ] Edge opens with no first-run questions and launches Roblox from
      roblox.com without asking, in a macro account
- [ ] Natro's browser fallback (every fifth reconnect attempt) joins the
      private server once the account is signed in on roblox.com
- [ ] Natro in PlayerAlt3 shows "Web Version" and joins through roblox://
      after the registration (keys proven absent before and present after;
      why the installer left them out, a Roblox stopped right after
      install, not proven)
- [ ] Roblox settings written in a macro account and kept after Natro
      reopens Roblox (tested on a copy of the owner's real file only: 6
      values changed, Natro's own checks find nothing left)
- [ ] 1920x1080 sessions on this PC's screen (window larger than the
      screen?)
- [ ] one-click start opens the sessions without a password prompt
- [ ] the `Natro-<account>` task starts Natro inside the account's session,
      at sign-in and on demand
- [ ] Natro presses Start by itself (`START.bat 1 0 <delay>`)
- [ ] `nm-git-update.ps1 -Yes -NoRestart` updates without any prompt
- [ ] `nm-git-adopt.ps1` converts an old folder with `-Branch`
- [ ] the supervisor reopens a closed session and restarts a stopped Natro
- [ ] RDP Wrapper repair from the supervisor, unattended
- [ ] automatic sign-in after a reboot, with the Microsoft account password
- [ ] the desktop shortcut runs the one-click task without a UAC prompt
- [ ] sessions keep rendering while the owner's own session is locked or
      disconnected

# Not built

- [ ] fleet side: the fork's fleet writing restart requests to `inbox\`
- [ ] alert (Discord) when a PC stays down
