# Roblox installs and updates, one account at a time, with no other Roblox
# running anywhere on the PC.
#
# Proven on 2026-11-16: Roblox's installer ends in "FailFast ... failed to
# access client process info: Accès refusé" whenever a Roblox of another
# Windows account runs (a standard account may not inspect another user's
# process). Started with every Roblox closed, the same update succeeded in
# 11 s. Roblox forces an update about weekly, so every account meets this.
#
# A "Roblox window" is therefore taken: the macros that ran are stopped,
# every Roblox of the macro accounts is closed, the work is done, then only
# the macros that ran are restarted. A lock file says a window is open, so
# the supervisor restarts nothing meanwhile; it names its process and
# expires, so a window whose owner died cannot block anything for good.

$Script:RobloxLockFile = 'roblox-window.lock'
$Script:RobloxLockStaleMinutes = 15
$Script:RobloxAutoMinSeconds = 600

function Get-RobloxLockPath { return (Join-Path $Script:Bss.StateDir $Script:RobloxLockFile) }

function Test-RobloxWindowOpen {
  $path = Get-RobloxLockPath
  if (-not (Test-Path $path)) { return $false }
  $item = Get-Item $path
  if ($item.LastWriteTime -lt (Get-Date).AddMinutes(-$Script:RobloxLockStaleMinutes)) { return $false }
  $ownerPid = 0
  if ([int]::TryParse(([IO.File]::ReadAllText($path)).Trim(), [ref]$ownerPid) -and $ownerPid -ne $PID) {
    return [bool](Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)
  }
  return $true
}

# Roblox processes on the PC, with their owner (needs administrator rights).
function Get-RobloxProcessesAll {
  return @(Get-Process RobloxPlayerBeta, RobloxPlayerInstaller -IncludeUserName -ErrorAction SilentlyContinue |
    ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.ProcessName; User = ($_.UserName -split '\\')[-1]; Started = $_.StartTime } })
}

# The owner's own Roblox counts as "another Roblox" too. It may be closed
# when the owner allowed it (CloseOwnerRobloxForUpdates) or when it is the
# local account's, which then is a macro like the others; otherwise the
# window waits for it.
function Test-OwnerRobloxClosable {
  param($Cfg)
  return ([bool]$Cfg.CloseOwnerRobloxForUpdates -or [bool]@($Cfg.Accounts | Where-Object { $_.Local -and $_.Enabled }).Count)
}

function Test-OwnerRobloxBlocking {
  param($Cfg)
  if (Test-OwnerRobloxClosable $Cfg) { return $false }
  return [bool](Get-RobloxProcessesAll | Where-Object { $_.User -eq $env:USERNAME })
}

# Runs $Work with no Roblox running on the PC and restarts afterwards the
# macros that were running. Returns what $Work returns, or throws.
function Invoke-RobloxWindow {
  param($Cfg, [string] $Reason, [scriptblock] $Work, [int] $WaitOwnerSec = 0)
  if (Test-RobloxWindowOpen) { throw 'A Roblox install or update is already in progress.' }
  if (Test-OwnerRobloxBlocking $Cfg) {
    Write-Log "Roblox window ($Reason): your own Roblox is open, it must be closed." WARN
    if (-not (Wait-Until { -not (Test-OwnerRobloxBlocking $Cfg) } $WaitOwnerSec 5)) { throw 'Your Roblox is open: close it, then try again (or allow closing it in Settings).' }
  }
  Set-Content -Path (Get-RobloxLockPath) -Value $PID
  $wasRunning = @()
  try {
    # Only the account's own session counts: two accounts may point at one
    # macro folder (Roblox2 still at GuidingALT1's), and only the one that
    # runs it must be restarted.
    $processes = Get-AutoHotkeyProcesses
    $sessions = Get-BssSessions
    foreach ($a in @($Cfg.Accounts | Where-Object { $_.MacroPath })) {
      $session = Get-AccountSession $a $sessions
      if ($session -and (Test-NatroRunning $a $session.Id $processes)) {
        $wasRunning += $a.Name
        Stop-NatroProcesses $a.MacroPath
      }
    }
    $ownerClosable = Test-OwnerRobloxClosable $Cfg
    Get-RobloxProcessesAll | Where-Object { $_.User -ne $env:USERNAME -or $ownerClosable } |
      ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Write-Log "Roblox window open ($Reason): $(if ($wasRunning) { "macros stopped: $($wasRunning -join ', ')" } else { 'no macro was running' })."
    return (& $Work)
  } finally {
    Remove-Item (Get-RobloxLockPath) -Force -ErrorAction SilentlyContinue
    foreach ($name in $wasRunning) {
      $a = $Cfg.Accounts | Where-Object { $_.Name -eq $name } | Select-Object -First 1
      try { [void](Start-Natro $Cfg $a) } catch { Write-Log "$name : restart failed, $($_.Exception.Message)" ERROR }
    }
    Write-Log "Roblox window closed ($Reason)$(if ($wasRunning) { ', macros restarted' })." OK
  }
}

function Get-RobloxLogDir {
  param([string] $WindowsUser)
  $profilePath = Get-UserProfilePath $WindowsUser
  if (-not $profilePath) { return $null }
  return (Join-Path $profilePath 'AppData\Local\Roblox\logs')
}

function Test-InstallerLogCrashed {
  param([string] $Text)
  return ($Text -match 'FailFast')
}

# Why an account needs a Roblox window now, or ''. Only meaningful with the
# account's session open (its registry hive loaded).
function Get-RobloxUpdateNeed {
  param($Account)
  $exe = Get-RobloxPlayerExe $Account.Name
  if (-not $exe) { return '' }
  $sid = (Get-LocalUser -Name $Account.Name -ErrorAction SilentlyContinue).SID.Value
  if ($sid -and (Test-Path "Registry::HKEY_USERS\$sid")) {
    $registered = Get-RegisteredProtocolExe "Registry::HKEY_USERS\$sid\Software\Classes" 'roblox'
    if (-not $registered -or -not (Test-Path $registered)) { return 'roblox:// links missing' }
  }
  $dir = Get-RobloxLogDir $Account.Name
  try {
    $last = Get-ChildItem $dir -Filter 'RobloxPlayerInstaller_*.log' -ErrorAction Stop | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($last -and (Test-InstallerLogCrashed (Read-SharedText $last.FullName))) { return 'Roblox install or update stuck' }
  } catch {
    # No log yet: nothing to repair.
  }
  return ''
}

# Inside a window: starts the account's Roblox, which updates itself when
# Roblox demands it, and reads the installer's verdict.
function Update-AccountRoblox {
  param($Account)
  $exe = Get-RobloxPlayerExe $Account.Name
  if (-not $exe) { return 'not installed' }
  $dir = Get-RobloxLogDir $Account.Name
  $since = Get-Date
  [void](Start-InAccountSession $Account 'RobloxUpdate' $exe.FullName '')
  $installerFor = { @(Get-RobloxProcessesAll | Where-Object { $_.User -eq $Account.Name -and $_.Name -eq 'RobloxPlayerInstaller' }).Count }
  $newLogs = { @(Get-ChildItem $dir -Filter 'RobloxPlayerInstaller_*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $since }) }
  $result = 'up to date'
  if (Wait-Until { (& $installerFor) -or (& $newLogs).Count } 25 2) {
    # The updater relaunches itself once: wait until none is left.
    [void](Wait-Until { -not (& $installerFor) } 240 3)
    Start-Sleep -Seconds 3
    [void](Wait-Until { -not (& $installerFor) } 60 3)
    $crashed = @(& $newLogs | Where-Object { Test-InstallerLogCrashed (Read-SharedText $_.FullName) }).Count
    $result = $(if ($crashed) { 'FAILED' } else { 'updated' })
  }
  Get-RobloxProcessesAll | Where-Object { $_.User -eq $Account.Name } | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
  [void](Register-RobloxProtocols $Account)
  try { [void](Set-AccountRobloxSettings $Account) } catch { }
  return $result
}

# Updates Roblox in every included account whose session is open, in one
# window. -Names limits it to some accounts.
function Invoke-RobloxUpdate {
  param($Cfg, [string[]] $Names, [string] $Reason = 'Roblox update')
  $accounts = @(Select-Accounts $Cfg $Names | Where-Object {
      (Test-SessionConnected (Get-AccountSession $_)) -and (Get-RobloxPlayerExe $_.Name) })
  if (-not $accounts.Count) { Write-Log 'Roblox update: no account with an open session and Roblox installed.' WARN; return }
  Invoke-RobloxWindow $Cfg $Reason {
    foreach ($a in $accounts) {
      $r = Update-AccountRoblox $a
      Write-Log "$($a.Name) : Roblox $r." $(if ($r -eq 'FAILED') { 'ERROR' } else { 'OK' })
    }
  } 300 | Out-Null
}
