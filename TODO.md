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
- [x] the window builds and renders its four tabs with real data
      (`-Action Gui -SnapshotDir`, images checked by eye)

# Loads, never driven

Parsed and loaded, but nobody has run these yet:

- [ ] a second session opens next to the owner's after the CRLF repair
- [ ] window buttons and dialogs, clicked by a person (only the rendering
      is proven)
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
