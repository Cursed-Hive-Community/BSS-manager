# Text menu, kept for consoles and remote shells (-Action Menu). Each choice
# asks its questions here and calls the shared actions in Actions.ps1, the
# same ones the window uses.

function Format-MacroLabel {
  param($Info)
  $kind = $(if ($Info.IsGit) { "Cursed, $($Info.Branch)" } else { 'old version' })
  return ('{0}  v{1}  [{2}]  used on {3:dd.MM.yyyy}' -f $Info.Name, $Info.Version, $kind, $Info.LastUsed)
}

# ---------------------------------------------------------------------------
# Questions, then the shared action
# ---------------------------------------------------------------------------

function Set-AccountMacro {
  param($Cfg)
  $a = Select-OneAccount $Cfg
  if (-not $a) { return }
  $macros = @(Find-Macros $Cfg)
  Write-Host "Current: $(if ($a.MacroPath) { $a.MacroPath } else { '(none)' })"
  $i = Select-Index (@($macros | ForEach-Object { Format-MacroLabel $_ }) + @('No macro')) 'Macro'
  if ($i -lt 0) { return }
  $path = $(if ($i -eq $macros.Count) { '' } else { $macros[$i].Path })
  $other = $Cfg.Accounts | Where-Object { $path -and $_.Name -ne $a.Name -and $_.MacroPath -eq $path } | Select-Object -First 1
  if ($other -and -not (Confirm-Action "$($other.Name) already uses this macro. Assign it anyway?")) { return }
  Set-AccountMacroPath $Cfg $a.Name $path
  if ($path -and -not $macros[$i].IsGit) { Write-Host 'Old version: ''Add a Roblox account'' creates a clean macro from this folder.' -ForegroundColor Yellow }
}

function Set-MacroBranchMenu {
  param($Cfg)
  $macros = @(Find-Macros $Cfg | Where-Object { $_.IsGit })
  $labels = @("Default branch of new macros (current: $($Cfg.DefaultBranch))") + @($macros | ForEach-Object { Format-MacroLabel $_ })
  $i = Select-Index $labels 'Which branch to change'
  if ($i -lt 0) { return }
  $sample = $(if ($i -eq 0) { $macros | Select-Object -First 1 } else { $macros[$i - 1] })
  if (-not $sample) { Write-Host 'No Cursed macro to list the branches.' -ForegroundColor Yellow; return }
  $branches = @(Get-RemoteBranches $sample.Path)
  if (-not $branches.Count) { Write-Host 'Cannot list the branches (network?).' -ForegroundColor Yellow; return }
  $j = Select-Index $branches 'Branch'
  if ($j -lt 0) { return }
  if ($i -eq 0) {
    $Cfg.DefaultBranch = $branches[$j]
    Save-BssConfig $Cfg
    Write-Log "Default branch: $($branches[$j])." OK
    return
  }
  if ((Get-NatroProcesses $sample.Path) -and -not (Confirm-Action 'This macro is running: stop it, switch branch, update and restart it?')) { return }
  Set-MacroBranch $Cfg $sample.Path $branches[$j]
}

function Add-RobloxAccountMenu {
  param($Cfg)
  $suggestions = @(Get-RobloxAccountSuggestions $Cfg | Where-Object { -not $_.Configured })
  $labels = @($suggestions | ForEach-Object { '{0}  ({1} folder(s))' -f $_.Roblox, $_.Candidates.Count }) + @('Other name...')
  $i = Select-Index $labels 'Roblox account'
  if ($i -lt 0) { return }
  $candidates = @()
  $guess = ''
  if ($i -lt $suggestions.Count) { $guess = $suggestions[$i].Roblox; $candidates = $suggestions[$i].Candidates }
  # Empty by default: the folder name may be a role, and a wrong guess here
  # would block the macro. Left empty, it is learnt at the first sign-in.
  $role = $guess
  if (-not $role) { $role = (Read-Host 'Role or folder name').Trim() }
  $roblox = (Read-Host 'Exact Roblox account (Enter = unknown, learnt at the first sign-in)').Trim()
  if ($roblox -eq $role) { $role = '' }
  if (-not (Test-CommonPassword)) {
    Write-Host 'Choose the common password of the macro accounts (Windows sometimes asks for it).' -ForegroundColor Cyan
    Set-CommonPassword (Read-NewPassword 'the macro accounts')
  }
  $j = Select-Index (@($candidates | ForEach-Object { Format-MacroLabel $_ }) + @('No base: fresh settings')) 'Base macro'
  if ($j -lt 0) { return }
  $source = $(if ($j -lt $candidates.Count) { $candidates[$j].Path } else { '' })
  Add-RobloxAccount $Cfg $roblox $role '' $source
}

function Switch-AccountFlagMenu {
  param($Cfg, [string] $Flag)
  $a = Select-OneAccount $Cfg
  if ($a) { Set-AccountFlag $Cfg $a.Name $Flag (-not $a.$Flag) }
}

function Set-AccountPasswordMenu {
  param($Cfg)
  $a = Select-OneAccount $Cfg
  if (-not $a) { return }
  $i = Select-Index @('Apply the common password of the macro accounts', 'Save the current password (changes nothing in Windows)') 'Choice'
  if ($i -eq 0) { Reset-AccountPassword $Cfg $a.Name }
  elseif ($i -eq 1) { Set-AccountPasswordValue $Cfg $a.Name (Read-Host "Current Windows password of $($a.Name)" -AsSecureString) $false }
}

function Remove-MacroAccountMenu {
  param($Cfg)
  $a = Select-OneAccount $Cfg
  if (-not $a) { return }
  if (-not (Confirm-Action "Remove $($a.Name) from BSS Manager (its session will be closed)?")) { return }
  $typed = Read-Host "To also DELETE the Windows account (permanent), type '$($a.Name)'. Otherwise Enter"
  Remove-ManagedAccount $Cfg $a.Name ($typed -ceq $a.Name)
}

function Set-AutoLogonMenu {
  $state = Get-AutoLogonState
  Write-Host ('Automatic sign-in: {0}' -f $(if ($state.Enabled) { "enabled ($($state.User))" } else { 'disabled' }))
  if ($state.Enabled) {
    if (Confirm-Action 'Disable it and erase the stored password?') { Disable-AutoLogon }
    return
  }
  Write-Host 'Windows will open your session by itself at startup, then the supervisor restarts everything.' -ForegroundColor Cyan
  Write-Host 'The password is stored encrypted by Windows (LSA secret). Windows Hello alone will be disabled.' -ForegroundColor Cyan
  if (-not (Confirm-Action 'Enable automatic sign-in?')) { return }
  $user = Read-Host "Windows account to open automatically (Enter = $env:USERNAME)"
  if (-not $user) { $user = $env:USERNAME }
  Write-Host 'For an account linked to Microsoft, type the Microsoft account password (not the PIN).' -ForegroundColor Yellow
  Enable-AutoLogon $user (Read-NewPassword $user)
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------

function Invoke-MenuChoice {
  param([scriptblock] $Block)
  try { & $Block } catch { Write-Log "Error: $($_.Exception.Message)" ERROR }
  Wait-Enter
}

function Show-AccountsMenu {
  while ($true) {
    # Re-read every time: the supervisor or a window may have changed it.
    $cfg = Get-BssConfig
    Clear-Host
    Write-Host '=== Roblox accounts ===' -ForegroundColor Cyan
    foreach ($a in @($cfg.Accounts)) {
      $flags = @()
      if (-not $a.Enabled) { $flags += 'excluded' }
      if ($a.Paused) { $flags += 'paused' }
      Write-Host ('  {0,-16} {1,-16} {2,-11} {3} {4}' -f $(if ($a.Roblox) { $a.Roblox } else { '?' }), $a.Name, $a.Ip, $(if ($a.MacroPath) { Split-Path $a.MacroPath -Leaf } else { '(no macro)' }), $(if ($flags) { "[$($flags -join ', ')]" } else { '' }))
    }
    Write-Host ''
    Write-Host '  1. Add a Roblox account (Windows account, macro, Roblox)'
    Write-Host '  2. Change an account''s macro'
    Write-Host '  3. Choose a macro''s branch (or the default one)'
    Write-Host '  4. Pause / maintenance of an account'
    Write-Host '  5. Account active / inactive'
    Write-Host '  6. Password of an account'
    Write-Host '  7. Remove an account'
    Write-Host '  0. Back'
    switch (Read-Host "`nChoice") {
      '1' { Invoke-MenuChoice { Add-RobloxAccountMenu $cfg } }
      '2' { Invoke-MenuChoice { Set-AccountMacro $cfg } }
      '3' { Invoke-MenuChoice { Set-MacroBranchMenu $cfg } }
      '4' { Invoke-MenuChoice { Switch-AccountFlagMenu $cfg 'Paused' } }
      '5' { Invoke-MenuChoice { Switch-AccountFlagMenu $cfg 'Enabled' } }
      '6' { Invoke-MenuChoice { Set-AccountPasswordMenu $cfg } }
      '7' { Invoke-MenuChoice { Remove-MacroAccountMenu $cfg } }
      '0' { return }
      '' { return }
    }
  }
}

function Show-UpdateMenu {
  param($Cfg)
  $i = Select-Index @('Macros of the accounts (restarted afterwards)', "All Cursed macros in $($Cfg.MacroRoot)") 'Update'
  if ($i -eq 0) { Update-Macros $Cfg }
  elseif ($i -eq 1) { Update-Macros $Cfg -AllFolders }
}

function Show-StopMenu {
  param($Cfg)
  $accounts = @($Cfg.Accounts)
  if (-not $accounts.Count) { return }
  $i = Select-Index (@('The whole system (Stop)') + @($accounts | ForEach-Object { $_.Name })) 'Stop'
  if ($i -eq 0) { Stop-All $Cfg }
  elseif ($i -gt 0) { Stop-All $Cfg @($accounts[$i - 1].Name) }
}

function Show-MainMenu {
  while ($true) {
    $cfg = Get-BssConfig
    Clear-Host
    Write-Host '=========================================' -ForegroundColor Cyan
    Write-Host '   BSS Manager - Natro Macro multi-RDP' -ForegroundColor Cyan
    Write-Host '=========================================' -ForegroundColor Cyan
    try {
      $w = Get-WrapperState $cfg
      if ($w.Healthy) { Write-Host "RDP Wrapper    : OK (termsrv $($w.TermsrvVersion))" -ForegroundColor Green }
      else { Write-Host "RDP Wrapper    : NEEDS REPAIR (termsrv $($w.TermsrvVersion)) -> 6" -ForegroundColor Red }
      $sup = Get-SupervisorStatus
      if ($sup -and $sup.Alive) { Write-Host "Supervisor     : active ($($sup.AgeSec) s ago)" -ForegroundColor Green }
      elseif ($sup) { Write-Host 'Supervisor     : STOPPED' -ForegroundColor Red }
      else { Write-Host 'Supervisor     : not installed -> 8' -ForegroundColor Yellow }
      $sessions = Get-BssSessions
      $up = @($cfg.Accounts | Where-Object { Test-SessionConnected (Get-AccountSession $_ $sessions) })
      Write-Host "Macro sessions : $($up.Count) / $(@($cfg.Accounts | Where-Object { $_.Enabled }).Count) connected"
    } catch { Write-Host "State unavailable: $($_.Exception.Message)" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host "  System: $(if ($cfg.Running) { 'STARTED' } else { 'STOPPED' })"
    Write-Host '  1. Start (updates, sessions, macros, supervision)'
    Write-Host '  2. Stop'
    Write-Host '  3. Detailed status'
    Write-Host '  4. Update the macros'
    Write-Host '  5. Accounts and macros'
    Write-Host '  6. Update RDP Wrapper'
    Write-Host '  7. Windows automatic sign-in'
    Write-Host '  8. Install (supervisor, shortcuts, rights)'
    Write-Host '  9. Uninstall'
    Write-Host '  0. Quit'
    switch (Read-Host "`nChoice") {
      '1' { Invoke-MenuChoice { Start-All $cfg } }
      '2' { Invoke-MenuChoice { Show-StopMenu $cfg } }
      '3' { Invoke-MenuChoice { Show-Status $cfg } }
      '4' { Invoke-MenuChoice { Show-UpdateMenu $cfg } }
      '5' { Show-AccountsMenu }
      '6' { Invoke-MenuChoice { [void](Update-RdpWrapper $cfg) } }
      '7' { Invoke-MenuChoice { Set-AutoLogonMenu } }
      '8' { Invoke-MenuChoice { Install-Manager $cfg } }
      '9' { Invoke-MenuChoice { if (Confirm-Action 'Delete the tasks and shortcuts of BSS Manager?') { Uninstall-Manager } } }
      '0' { return }
    }
  }
}
