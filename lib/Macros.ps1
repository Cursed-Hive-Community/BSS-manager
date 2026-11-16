# Natro Macro folders: discovery, branch, start/stop inside a session, update.
#
# Updates are delegated to the fork's own tools (tools\nm-git-update.ps1 and
# tools\nm-git-adopt.ps1) instead of being written a second time here. They
# keep settings\ (git-ignored), stop only the processes of their own folder,
# and accept -Yes (no prompt) and -NoRestart. The restart is ours because
# their restart would start the macro in the caller's session, not in the
# macro account's one.
# https://github.com/Cursed-Hive-Community/NatroMacroCursed/blob/feature/rays-extensions/UPDATE-GIT.md
#
# The branch an instance follows is read from GitBranch/GitRepoUrl in its
# settings\nm_config.ini: the same keys the macro's Git Sync button uses, so
# the two never disagree.

$Script:UpdatingStaleMinutes = 15
$Script:ArchiveFolderName = '_Anciennes'
$Script:MacroFolderPrefix = 'Natro_Macro_'

function Get-NatroIniPath { param([string] $Path) return (Join-Path $Path 'settings\nm_config.ini') }

function Get-NatroIniValue {
  param([string] $Path, [string] $Key)
  $ini = Get-NatroIniPath $Path
  if (-not (Test-Path $ini)) { return $null }
  # Natro writes this file while it runs.
  $text = Read-SharedText $ini
  if ($null -eq $text) { return $null }
  $m = [regex]::Match($text, "(?m)^$([regex]::Escape($Key))=(.*?)\s*$")
  if ($m.Success -and $m.Groups[1].Value) { return $m.Groups[1].Value }
  return $null
}

# Sets Key=Value inside [Settings], adding the line or the section if needed.
function Set-NatroIniValue {
  param([string] $Path, [string] $Key, [string] $Value)
  $ini = Get-NatroIniPath $Path
  $lines = @()
  if (Test-Path $ini) { $lines = @([IO.File]::ReadAllLines($ini)) }
  $out = New-Object Collections.Generic.List[string]
  $inSettings = $false
  $done = $false
  foreach ($line in $lines) {
    if ($line -match '^\s*\[(.+)\]\s*$') {
      if ($inSettings -and -not $done) { $out.Add("$Key=$Value"); $done = $true }
      $inSettings = ($Matches[1] -eq 'Settings')
    } elseif ($inSettings -and $line -match "^$([regex]::Escape($Key))=") {
      $out.Add("$Key=$Value"); $done = $true; continue
    }
    $out.Add($line)
  }
  if (-not $done) {
    if (-not $inSettings) { $out.Add('[Settings]') }
    $out.Add("$Key=$Value")
  }
  [IO.File]::WriteAllLines($ini, $out)
}

function Get-MacroBranch {
  param($Cfg, [string] $Path)
  $branch = Get-NatroIniValue $Path 'GitBranch'
  if ($branch) { return $branch }
  return $Cfg.DefaultBranch
}

function Get-MacroRepoUrl {
  param($Cfg, [string] $Path)
  $url = Get-NatroIniValue $Path 'GitRepoUrl'
  if ($url) { return $url }
  return $Cfg.DefaultRepoUrl
}

function Test-NatroFolder {
  param([string] $Path)
  return ($Path -and (Test-Path (Join-Path $Path 'submacros\natro_macro.ahk')))
}

function Get-MacroInfo {
  param($Cfg, [string] $Path)
  $script = Join-Path $Path 'submacros\natro_macro.ahk'
  $version = Select-String -Path $script -Pattern 'VersionID\s*:=\s*"([^"]+)"' -List -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Matches[0].Groups[1].Value }
  $lastSetting = Get-ChildItem (Join-Path $Path 'settings') -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $isGit = Test-Path (Join-Path $Path '.git')
  [pscustomobject]@{
    Path     = $Path
    Name     = Split-Path $Path -Leaf
    Version  = $(if ($version) { $version } else { '?' })
    IsGit    = $isGit
    Branch   = $(if ($isGit) { Get-MacroBranch $Cfg $Path } else { '' })
    HasTools = Test-Path (Join-Path $Path 'tools\nm-git-update.ps1')
    LastUsed = $(if ($lastSetting) { $lastSetting.LastWriteTime } else { (Get-Item $Path).LastWriteTime })
  }
}

# Macro folders under MacroRoot and in each local profile, newest use first.
function Find-Macros {
  param($Cfg)
  $bases = @()
  if ($Cfg.MacroRoot -and (Test-Path $Cfg.MacroRoot)) { $bases += $Cfg.MacroRoot }
  foreach ($user in Get-LocalUser | Where-Object { $_.Enabled }) {
    $profilePath = Get-UserProfilePath $user.Name
    if (-not $profilePath) { continue }
    foreach ($sub in 'Documents', 'Desktop', 'Downloads') {
      $base = Join-Path $profilePath $sub
      # Profiles created by BSS Manager are private to their owner and to
      # administrators: unreadable here simply means "not searched".
      if (Test-Path $base -ErrorAction SilentlyContinue) { $bases += $base }
    }
  }
  $paths = foreach ($base in $bases) {
    Get-ChildItem $base -Directory -Depth 1 -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notlike "*\$($Script:ArchiveFolderName)\*" -and (Test-NatroFolder $_.FullName) } |
      ForEach-Object { $_.FullName }
  }
  return @($paths | Sort-Object -Unique | ForEach-Object { Get-MacroInfo $Cfg $_ } | Sort-Object LastUsed -Descending)
}

# ---------------------------------------------------------------------------
# Processes
# ---------------------------------------------------------------------------

# Every AutoHotkey process, in one query; callers checking several accounts
# pass it on instead of querying once per account.
# https://learn.microsoft.com/windows/win32/cimwin32prov/win32-process
function Get-AutoHotkeyProcesses {
  return @(Get-CimInstance Win32_Process -Filter "Name='AutoHotkey32.exe' OR Name='AutoHotkey64.exe'" -ErrorAction SilentlyContinue)
}

# AutoHotkey processes started from this folder, whatever their session.
function Get-NatroProcesses {
  param([string] $Path, [object[]] $All)
  if (-not $Path) { return @() }
  if ($null -eq $All) { $All = Get-AutoHotkeyProcesses }
  $prefix = $Path.TrimEnd('\') + '\'
  return @($All | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
}

# The main macro script is what matters: its helpers (background.ahk, the
# fleet coordinator) may outlive it.
function Test-NatroRunning {
  param($Account, [int] $SessionId = -1, [object[]] $All)
  foreach ($p in Get-NatroProcesses $Account.MacroPath $All) {
    if ($p.CommandLine -notmatch 'natro_macro\.ahk') { continue }
    if ($SessionId -lt 0 -or $p.SessionId -eq $SessionId) { return $true }
  }
  return $false
}

function Stop-NatroProcesses {
  param([string] $Path)
  foreach ($p in Get-NatroProcesses $Path) {
    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {
      Write-Log "PID $($p.ProcessId) not stopped: $($_.Exception.Message)" WARN
    }
  }
}

# ---------------------------------------------------------------------------
# Start inside the account's own session
# ---------------------------------------------------------------------------
# A task with an Interactive principal runs in that user's desktop session, at
# logon and whenever it is started on demand. That is the only supported way
# to start a program in another user's session without its password.
# https://learn.microsoft.com/windows/win32/taskschd/principal-logontype

function Get-NatroTaskName { param($Account) return "Natro-$($Account.Name)" }

function Sync-NatroTask {
  param($Cfg, $Account)
  $name = Get-NatroTaskName $Account
  $existing = Get-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName $name -ErrorAction SilentlyContinue
  $bat = ''
  if ($Account.MacroPath) { $bat = Join-Path $Account.MacroPath 'START.bat' }
  # No task until the account is ready: during its first sign-in Roblox is
  # not installed yet, and Natro would try to open it anyway.
  if (-not ($Account.Enabled -and $bat -and (Test-Path $bat) -and -not (Get-AccountReadiness $Account))) {
    if ($existing) { Unregister-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName $name -Confirm:$false }
    if ($Account.Enabled -and $Account.MacroPath -and -not (Test-Path $bat)) { Write-Log "$($Account.Name) : START.bat not found in $($Account.MacroPath)." WARN }
    return
  }
  $user = Get-QualifiedUser $Account.Name
  # START.bat forwards its arguments to natro_macro.ahk: 1 = press Start by
  # itself, 0 = no heartbeat window, then the delay before launching.
  $action = New-ScheduledTaskAction -Execute ('"{0}"' -f $bat) -Argument ('1 0 {0}' -f [int]$Cfg.NatroStartDelaySec) -WorkingDirectory $Account.MacroPath
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName $name -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description "Starts Natro Macro when $($Account.Name) signs in (BSS Manager)" -Force | Out-Null
}

# Every start goes through here, so the task is created when it is missing
# (it is registered lazily, once an account becomes ready) and an account
# that is not ready is refused with its reason instead of a "file not found"
# from the task scheduler. Returns $true when Natro was started.
function Start-Natro {
  param($Cfg, $Account)
  $missing = Get-AccountReadiness $Account
  if ($missing) { Write-Log "$($Account.Roblox) ($($Account.Name)) : Natro not started, $missing." WARN; return $false }
  # Natro would open Roblox while another process installs it with every
  # Roblox closed; that process restarts the macros itself afterwards.
  if (Test-RobloxWindowOpen) { Write-Log "$($Account.Name) : Natro will start after the Roblox update in progress." WARN; return $false }
  $name = Get-NatroTaskName $Account
  if (-not (Get-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName $name -ErrorAction SilentlyContinue)) { Sync-NatroTask $Cfg $Account }
  # Natro is not running here, so a Roblox left open may be closed to put
  # the settings Natro needs in place; Natro opens it again itself.
  try { [void](Set-AccountRobloxSettings $Account -CloseRoblox) } catch { Write-Log "$($Account.Name) : Roblox settings not applied, $($_.Exception.Message)" WARN }
  # Natro joins through roblox:// links: make sure Windows can open them.
  try { [void](Register-RobloxProtocols $Account) } catch { Write-Log "$($Account.Name) : roblox:// links not checked, $($_.Exception.Message)" WARN }
  Start-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName $name
  return $true
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
# The fork's fleet talks over the network, so the first start of each
# folder's AutoHotkey raises Windows' firewall prompt, which a standard
# macro account cannot answer and which steals focus from the macro. The
# rules it would create are created beforehand: inbound, TCP and UDP, for
# that folder's two AutoHotkey programs only, on private networks only.
# https://learn.microsoft.com/powershell/module/netsecurity/new-netfirewallrule

function Get-MacroFirewallRuleNames {
  param([string] $Path)
  $leaf = Split-Path $Path -Leaf
  foreach ($exe in 'AutoHotkey32.exe', 'AutoHotkey64.exe') {
    foreach ($protocol in 'TCP', 'UDP') {
      [pscustomobject]@{ Name = "BSS Manager - $leaf - $exe - $protocol"; Program = Join-Path $Path "submacros\$exe"; Protocol = $protocol }
    }
  }
}

function Add-MacroFirewallRules {
  param([string] $Path)
  if (-not (Test-NatroFolder $Path)) { return }
  $added = 0
  foreach ($rule in Get-MacroFirewallRuleNames $Path) {
    if (-not (Test-Path $rule.Program)) { continue }
    if (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue) { continue }
    New-NetFirewallRule -DisplayName $rule.Name -Group 'BSS Manager' -Direction Inbound -Action Allow -Profile Private `
      -Program $rule.Program -Protocol $rule.Protocol | Out-Null
    $added++
  }
  if ($added) { Write-Log "$(Split-Path $Path -Leaf) : $added firewall rule(s) added (private networks)." OK }
}

# ---------------------------------------------------------------------------
# Updates
# ---------------------------------------------------------------------------

function Get-UpdatingMarker { param([string] $Path) return (Join-Path $Script:Bss.StateDir ('updating-{0}.txt' -f (Split-Path $Path -Leaf))) }

# The supervisor leaves a macro alone while it is being updated, or it would
# restart it in the middle and lock the files git is replacing. The marker
# expires by itself so a crashed update cannot block a macro for good.
function Test-MacroUpdating {
  param([string] $Path)
  $marker = Get-UpdatingMarker $Path
  return ((Test-Path $marker) -and ((Get-Item $marker).LastWriteTime -gt (Get-Date).AddMinutes(-$Script:UpdatingStaleMinutes)))
}

# ---------------------------------------------------------------------------
# Folder rights
# ---------------------------------------------------------------------------
# The macro accounts run their macro, but BSS Manager updates it with
# administrator rights: git, and the fork's tools\*.ps1. Any Windows account
# able to change tools\ or .git, or to add a folder next to the macros, could
# make that elevated update run its own code (the macro accounts share a
# password the owner chose, and run third-party patterns). So:
# - the root: administrators and SYSTEM change it, everyone reads, and the
#   owner may change what is inside the folders without adding one;
# - each macro folder: its own active Windows account may change it;
# - tools\ and .git: administrators only, except tools\OCR_debug, where
#   Natro saves its diagnostics while it runs.
# https://learn.microsoft.com/windows-server/administration/windows-commands/icacls

$Script:AdminOnlySubfolders = @('tools', '.git')
$Script:NatroWritableSubfolder = 'tools\OCR_debug'

function Get-OwnerSid {
  return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

# tools\ and .git stop inheriting, so the folder's account loses its write
# right there. Skipped when already done: re-propagating through .git takes
# a while.
function Protect-MacroCode {
  param([string] $Path)
  foreach ($name in $Script:AdminOnlySubfolders) {
    $dir = Join-Path $Path $name
    if (-not (Test-Path $dir) -or (Get-Acl $dir).AreAccessRulesProtected) { continue }
    & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /C /Q | Out-Null
  }
}

# Write rights inside one macro folder: its active, non-local accounts, plus
# the owner (who runs the local account's Natro). Rights granted earlier are
# reset first, so an account the macro was taken from loses them.
function Set-MacroFolderAcl {
  param($Cfg, [string] $Path)
  if (-not (Test-NatroFolder $Path)) { return }
  $sids = @(@($Cfg.Accounts | Where-Object { $_.MacroPath -eq $Path -and $_.Enabled -and -not $_.Local }) | ForEach-Object {
      $user = Get-LocalUser -Name $_.Name -ErrorAction SilentlyContinue
      if ($user) { $user.SID.Value }
    })
  & icacls.exe $Path /reset /C /Q | Out-Null
  foreach ($sid in $sids) { & icacls.exe $Path /grant "*${sid}:(OI)(CI)M" /C /Q | Out-Null }
  $debug = Join-Path $Path $Script:NatroWritableSubfolder
  if ((Test-Path (Join-Path $Path 'tools')) -and -not (Test-Path $debug)) { New-Item -ItemType Directory -Path $debug | Out-Null }
  Protect-MacroCode $Path
  if (-not (Test-Path $debug)) { return }
  & icacls.exe $debug /reset /C /Q | Out-Null
  foreach ($sid in @($sids) + @(Get-OwnerSid)) { & icacls.exe $debug /grant "*${sid}:(OI)(CI)M" /C /Q | Out-Null }
}

function Set-MacroRootAcl {
  param($Cfg)
  $root = $Cfg.MacroRoot
  if (-not $root -or -not (Test-Path $root)) { return }
  $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
  $acl = New-Object Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($rule in @(
      @('S-1-5-18', 'FullControl', 'None'),
      @('S-1-5-32-544', 'FullControl', 'None'),
      @('S-1-5-32-545', 'ReadAndExecute', 'None'),
      @((Get-OwnerSid), 'Modify', 'InheritOnly'))) {
    $sid = New-Object Security.Principal.SecurityIdentifier $rule[0]
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, $rule[1], $inherit, [Security.AccessControl.PropagationFlags]$rule[2], 'Allow')))
  }
  Set-Acl -Path $root -AclObject $acl
  Write-Log "Rights of $root : only administrators add folders, each macro writable by its own account..."
  # Children drop their own entries and inherit the list above.
  & icacls.exe (Join-Path $root '*') /reset /T /C /Q | Out-Null
  foreach ($m in @(Find-Macros $Cfg)) { Set-MacroFolderAcl $Cfg $m.Path }
  Write-Log "Rights of $root set; tools\ and .git of each macro are administrators only." OK
}

function Invoke-ForkTool {
  param([string] $Script, [string[]] $Arguments)
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1
  foreach ($line in $output) {
    $text = "$line".TrimEnd()
    if ($text) { Write-Log "  $text" }
  }
  return $LASTEXITCODE
}

# Returns $true when the folder is now on the latest commit of its branch.
function Update-Macro {
  param($Cfg, [string] $Path)
  $tool = Join-Path $Path 'tools\nm-git-update.ps1'
  if (-not (Test-Path (Join-Path $Path '.git'))) { Write-Log "$Path is not tracked by git: use 'Convert to Cursed version'." WARN; return $false }
  if (-not (Test-Path $tool)) { Write-Log "$Path lacks the update tools (tools\nm-git-update.ps1)." WARN; return $false }
  $branch = Get-MacroBranch $Cfg $Path
  $repo = Get-MacroRepoUrl $Cfg $Path
  $marker = Get-UpdatingMarker $Path
  Set-Content -Path $marker -Value (Get-Date -Format o)
  try {
    Write-Log "Updating $(Split-Path $Path -Leaf) ($branch)..."
    Protect-MacroCode $Path
    $code = Invoke-ForkTool $tool @('-Yes', '-NoRestart', '-Branch', $branch, '-RepoUrl', $repo)
    if ($code -ne 0) { Write-Log "Update of $(Split-Path $Path -Leaf) failed (code $code): the current version is kept." ERROR; return $false }
    Write-Log "$(Split-Path $Path -Leaf) is up to date." OK
    return $true
  } finally {
    Remove-Item $marker -ErrorAction SilentlyContinue
  }
}

function Get-RemoteBranches {
  param([string] $Path)
  Protect-MacroCode $Path
  $git = @('-c', 'safe.directory=*', '-C', $Path)
  & git @git fetch --quiet --prune origin 2>$null
  return @(& git @git branch -r --format='%(refname:short)' 2>$null |
    Where-Object { $_ -and $_ -notmatch '/HEAD$' -and $_ -ne 'origin' } | ForEach-Object { $_ -replace '^origin/', '' })
}

# Natro rewrites nm_config.ini from memory, so a running macro is stopped
# before its GitBranch changes; the update then restarts it where it ran.
function Set-MacroBranch {
  param($Cfg, [string] $Path, [string] $Branch)
  if (Get-NatroProcesses $Path) { Stop-NatroProcesses $Path }
  Set-NatroIniValue $Path 'GitBranch' $Branch
  if (-not (Get-NatroIniValue $Path 'GitRepoUrl')) { Set-NatroIniValue $Path 'GitRepoUrl' $Cfg.DefaultRepoUrl }
  Write-Log "$(Split-Path $Path -Leaf) suit maintenant $Branch." OK
  # An empty name list would mean "every account" to Update-Macros.
  $owners = @($Cfg.Accounts | Where-Object { $_.MacroPath -eq $Path } | ForEach-Object { $_.Name })
  if ($owners.Count) { Update-Macros $Cfg -Names $owners } else { [void](Update-Macro $Cfg $Path) }
}

# ---------------------------------------------------------------------------
# One clean macro per Roblox account
# ---------------------------------------------------------------------------
# Old release folders are not converted in place: a new folder named after
# the Roblox account is cloned from a Cursed instance, the old settings are
# copied into it, and the old folder is moved to _Anciennes. Names stay clean
# and nothing is lost.

# The Roblox account a folder name points at, by the owner's naming habit:
# "Natro_Macro_v1.0.1 Player25bee - Red" -> Player25bee. Only a guess,
# shown for the owner to confirm.
function Get-RobloxNameGuess {
  param([string] $FolderName)
  $rest = $FolderName -replace '^Natro[ _]Macro[ _]*', '' -replace '^v?\d+(\.\d+)+[a-z]?\s*', ''
  $ignored = '^(Copie|Copy|Blue|Red|White|Alts?|v?\d+(\.\d+)*)$'
  return ($rest -split '[\s\-]+' | Where-Object { $_ -match '^[A-Za-z0-9_]{3,20}$' -and $_ -notmatch $ignored } | Select-Object -First 1)
}

function Get-RobloxMacroPath {
  param($Cfg, [string] $Roblox)
  return (Join-Path $Cfg.MacroRoot ($Script:MacroFolderPrefix + $Roblox))
}

function Move-MacroToArchive {
  param($Cfg, [string] $Path)
  $root = $Cfg.MacroRoot.TrimEnd('\') + '\'
  if (-not $Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Log "$Path is outside $($Cfg.MacroRoot): left in place." WARN
    return
  }
  if (Get-NatroProcesses $Path) { Write-Log "$(Split-Path $Path -Leaf) is running: not moved to $($Script:ArchiveFolderName)." WARN; return }
  $archive = Join-Path $Cfg.MacroRoot $Script:ArchiveFolderName
  if (-not (Test-Path $archive)) { New-Item -ItemType Directory -Path $archive | Out-Null }
  $target = Join-Path $archive (Split-Path $Path -Leaf)
  if (Test-Path $target) { $target = "$target $(Get-Date -Format 'yyyyMMdd-HHmmss')" }
  Move-Item -LiteralPath $Path -Destination $target
  Write-Log "Old folder moved: $target" OK
}

# Returns the path of the Roblox account's macro, creating it if needed.
# $SourcePath: a Cursed folder (used as is), an old folder (settings copied,
# folder archived), or empty (fresh settings).
function New-CleanMacro {
  param($Cfg, [string] $Roblox, [string] $SourcePath)
  $source = $null
  if ($SourcePath) { $source = Get-MacroInfo $Cfg $SourcePath }
  if ($source -and $source.IsGit) {
    Write-Log "$Roblox keeps its Cursed macro: $SourcePath"
    return $SourcePath
  }
  $target = Get-RobloxMacroPath $Cfg $Roblox
  if (Test-Path $target) {
    if (-not (Test-Path (Join-Path $target '.git'))) { throw "$target already exists and is not a Cursed macro: rename it or choose it as the base." }
    Write-Log "$Roblox already has its Cursed macro: $target"
    return $target
  }
  $target = New-MacroFolder $Cfg $Roblox $SourcePath
  # An old release used as a base has been replaced: put it aside.
  if ($source) { Move-MacroToArchive $Cfg $SourcePath }
  return $target
}

# Creates Natro_Macro_<Name> under MacroRoot: a clone of a Cursed instance
# through the fork's nm-new-instance.ps1, on DefaultBranch, with the
# settings of $SettingsFrom when given (any macro, old or Cursed, left as it
# is) or fresh ones. Returns its path.
function New-MacroFolder {
  param($Cfg, [string] $Name, [string] $SettingsFrom)
  if ($Name -notmatch '^[A-Za-z0-9_]{3,20}$') { throw "Invalid name: $Name (3 to 20 letters, digits or _)." }
  $target = Get-RobloxMacroPath $Cfg $Name
  if (Test-Path $target) { throw "$(Split-Path $target -Leaf) already exists." }
  if ($SettingsFrom -and -not (Test-NatroFolder $SettingsFrom)) { throw "Not a Natro macro: $SettingsFrom" }
  $template = Find-Macros $Cfg | Where-Object { $_.IsGit -and (Test-Path (Join-Path $_.Path 'tools\nm-new-instance.ps1')) } | Select-Object -First 1
  if (-not $template) { throw 'No Cursed macro with tools\nm-new-instance.ps1 to use as a template.' }

  Write-Log "Creating $target from $($template.Name)..."
  Protect-MacroCode $template.Path
  $code = Invoke-ForkTool (Join-Path $template.Path 'tools\nm-new-instance.ps1') @('-Name', (Split-Path $target -Leaf), '-Path', $Cfg.MacroRoot, '-Yes')
  if ($code -ne 0 -or -not (Test-Path $target)) { throw "Macro creation failed (code $code)." }

  $settings = Join-Path $target 'settings'
  if (-not (Test-Path $settings)) { New-Item -ItemType Directory -Path $settings | Out-Null }
  if ($SettingsFrom) {
    Copy-Item -Path (Join-Path $SettingsFrom 'settings\*') -Destination $settings -Recurse -Force
    Write-Log "Settings copied from $(Split-Path $SettingsFrom -Leaf)." OK
  }
  Set-NatroIniValue $target 'GitBranch' $Cfg.DefaultBranch
  Set-NatroIniValue $target 'GitRepoUrl' $Cfg.DefaultRepoUrl
  Set-MacroFolderAcl $Cfg $target
  [void](Update-Macro $Cfg $target)
  Add-MacroFirewallRules $target
  Write-Log "$(Split-Path $target -Leaf) created." OK
  return $target
}
