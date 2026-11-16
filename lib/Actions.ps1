# High-level actions, shared by the menu and the command line.

# ---------------------------------------------------------------------------
# Start / stop
# ---------------------------------------------------------------------------

# Start (the whole system, or some accounts): RDP Wrapper, macro updates,
# sessions, macros. Any start turns the system on, so the supervisor looks
# after what was started.
function Start-All {
  param($Cfg, [string[]] $Names)
  $accounts = @(Select-Accounts $Cfg $Names)
  if (-not $accounts.Count) { Write-Log 'No active account to start: make an account active in the Roblox accounts tab.' WARN; return }
  if (-not $Cfg.Running) {
    $Cfg.Running = $true
    Save-BssConfig $Cfg
    Write-Log 'System started: the supervisor watches and restarts the active accounts.' OK
  }

  $wrapper = Get-WrapperState $Cfg
  if (-not ($wrapper.IniSupports -and $wrapper.IniCrlf -and $wrapper.ServiceDllOk)) {
    if (-not (Update-RdpWrapper $Cfg)) { Write-Log 'Start cancelled: without an up-to-date RDP Wrapper, only one session can open.' ERROR; return }
  }

  if ($Cfg.UpdateMacrosOnStart) {
    $paths = @($accounts | Where-Object { $_.MacroPath } | ForEach-Object { $_.MacroPath } | Sort-Object -Unique)
    foreach ($path in $paths) {
      # A macro that already runs is left alone: an update would stop it.
      if (Get-NatroProcesses $path) { Write-Log "$(Split-Path $path -Leaf) is already running: updated at the next stop (or 'Update the macros')."; continue }
      if (Test-Path (Join-Path $path '.git')) { [void](Update-Macro $Cfg $path) }
    }
  }

  foreach ($a in $accounts) { $a.Paused = $false }
  Save-BssConfig $Cfg
  [void](Update-LearnedRobloxNames $Cfg)
  foreach ($a in $accounts) { Sync-NatroTask $Cfg $a }

  $sessions = Get-BssSessions
  $opened = 0
  for ($i = 0; $i -lt $accounts.Count; $i++) {
    $a = $accounts[$i]
    $missing = Get-AccountReadiness $a
    if ($missing) { Write-Log "$($a.Roblox) ($($a.Name)) : not ready, $missing." WARN; continue }
    Add-MacroFirewallRules $a.MacroPath
    $session = Get-AccountSession $a $sessions
    if (Test-SessionConnected $session) {
      if ($a.MacroPath -and -not (Test-NatroRunning $a $session.Id)) {
        Write-Log "$($a.Name) : session already open, starting Natro."
        [void](Start-Natro $Cfg $a)
      } else {
        Write-Log "$($a.Name) : already running."
      }
      continue
    }
    # The session's sign-in starts Natro through its own task, not through
    # Start-Natro, so Roblox's settings are put in place here, before it.
    try { [void](Set-AccountRobloxSettings $a) } catch { Write-Log "$($a.Name) : Roblox settings not applied, $($_.Exception.Message)" WARN }
    if ($opened -gt 0) { Start-Sleep -Seconds ([int]$Cfg.DelayBetweenSessionsSec) }
    $what = $(if ($session) { 'reconnecting' } elseif ($a.MacroPath) { "opening, Natro starts ~$($Cfg.NatroStartDelaySec) s later" } else { 'opening, no macro assigned' })
    Write-Log "$($a.Name) : $what ($($a.Ip))."
    if (Open-AccountSession $Cfg $a) { $opened++ }
  }
  Write-Log "$opened session(s) opened." OK
  Start-SupervisorTask
}

# Pauses first, so the supervisor does not reopen what is being closed.
# Without names this is Stop for the whole system: it is also switched off,
# and stays off after a reboot until Start.
function Stop-All {
  param($Cfg, [string[]] $Names)
  $accounts = @(Select-Accounts $Cfg $Names -IncludeDisabled)
  if (-not $accounts.Count) { return }
  if (-not (Confirm-Action "Stop $(($accounts | ForEach-Object { $_.Name }) -join ', ') (sessions closed, Roblox and Natro stopped)?")) { return }
  foreach ($a in $accounts) { $a.Paused = $true }
  if (-not $Names) {
    $Cfg.Running = $false
    Write-Log 'System stopped: the supervisor restarts nothing until the next Start.' OK
  }
  Save-BssConfig $Cfg
  foreach ($a in $accounts) {
    $closed = Close-AccountSession $a
    if ($a.Local) { Write-Log "$($a.Name) : Natro and Roblox stopped, your session stays open; account paused." OK }
    elseif ($closed) { Write-Log "$($a.Name) : session closed, account paused." OK }
    else { Write-Log "$($a.Name) : paused (no open session)." OK }
  }
}

# Restarts one macro: the entry point for the fleet or any script.
function Restart-AccountMacro {
  param($Cfg, [string[]] $Names)
  foreach ($a in @(Select-Accounts $Cfg $Names -IncludeDisabled)) {
    if (-not $a.MacroPath) { Write-Log "$($a.Name) : no macro assigned." WARN; continue }
    $session = Get-AccountSession $a
    Stop-NatroProcesses $a.MacroPath
    if (Test-SessionConnected $session) {
      if (Start-Natro $Cfg $a) { Write-Log "$($a.Name) : macro restarted." OK }
    } else {
      if (Open-AccountSession $Cfg $a) { Write-Log "$($a.Name) : session reopened, the macro starts with it." OK }
    }
  }
}

# ---------------------------------------------------------------------------
# Account edits: the menu and the window ask the questions, these act.
# Callers pass a configuration they have just read, so nothing a running
# action wrote in between is lost.
# ---------------------------------------------------------------------------

function Get-AccountByName {
  param($Cfg, [string] $Name)
  $a = $Cfg.Accounts | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
  if (-not $a) { throw "Unknown account: $Name" }
  return $a
}

function Wait-Until {
  param([scriptblock] $Condition, [int] $TimeoutSec, [int] $StepSec = 5)
  $end = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $end) {
    if (& $Condition) { return $true }
    Start-Sleep -Seconds $StepSec
  }
  return $false
}

# Downloads the official installer once a week and refuses it unless it
# carries a valid Roblox Corporation signature.
# https://learn.microsoft.com/powershell/module/microsoft.powershell.security/get-authenticodesignature
function Get-RobloxInstaller {
  $dir = Join-Path $Script:Bss.StateDir 'downloads'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $file = Join-Path $dir 'RobloxPlayerInstaller.exe'
  if (-not (Test-Path $file) -or (Get-Item $file).LastWriteTime -lt (Get-Date).AddDays(-7)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Write-Log 'Downloading the Roblox installer (roblox.com)...'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://www.roblox.com/download/client?os=win' -OutFile $file -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
  }
  $signature = Get-AuthenticodeSignature $file
  if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O="?Roblox Corporation') {
    Remove-Item $file -Force
    throw "Roblox installer refused: signature $($signature.Status), $($signature.SignerCertificate.Subject)"
  }
  return $file
}

# Runs a program once in the account's own desktop session, through a task
# with an Interactive principal. The task is kept (replaced on the next run)
# rather than deleted, since deleting a running task can end its process.
# https://learn.microsoft.com/windows/win32/taskschd/principal-logontype
function Start-InAccountSession {
  param($Account, [string] $Purpose, [string] $Program, [string] $Arguments)
  $name = "$Purpose-$($Account.Name)"
  $principal = New-ScheduledTaskPrincipal -UserId (Get-QualifiedUser $Account.Name) -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
  $action = $(if ($Arguments) { New-ScheduledTaskAction -Execute $Program -Argument $Arguments } else { New-ScheduledTaskAction -Execute $Program })
  Register-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName $name -Action $action -Principal $principal -Settings $settings `
    -Description "$Purpose for $($Account.Name) (BSS Manager)" -Force | Out-Null
  Start-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName $name
  return $name
}

# The installer is waited for until its task ends, not until the player file
# appears: the file shows up before the installer is done, and stopping
# there left an invisible Roblox behind (GuidingALT1, 2026-11-16).
function Install-RobloxInSession {
  param($Account)
  if (Test-RobloxInstalled $Account.Name) { Write-Log "$($Account.Name) : Roblox already installed."; return $true }
  $installer = Get-RobloxInstaller
  Write-Log "$($Account.Name) : installing Roblox in its session..."
  $task = Start-InAccountSession $Account 'RobloxSetup' $installer ''
  Start-Sleep -Seconds 5
  $finished = Wait-Until { (Get-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName $task).State -ne 'Running' } 900 10
  $done = Test-RobloxInstalled $Account.Name
  if ($done) { Write-Log "$($Account.Name) : Roblox installed." OK }
  elseif (-not $finished) { Write-Log "$($Account.Name) : the Roblox installer still runs after 15 minutes." WARN }
  return $done
}

# Opens the Roblox app in the account's session the way its Start menu
# shortcut does (RobloxPlayerBeta.exe, no argument), so the owner can sign
# in. A Roblox left running for minutes while nobody is signed in is a
# hidden leftover that would swallow the new start, so it is stopped; a
# fresh one is not, since right after an install it may still be finishing
# (stopping it a second after the installer was the likely cause of
# PlayerAlt3's missing roblox:// links, 2026-11-16).
function Open-RobloxForSignIn {
  param($Cfg, $Account)
  $exe = Get-RobloxPlayerExe $Account.Name
  if (-not $exe) { throw "$($Account.Name) : Roblox is not installed in its session." }
  if (-not (Test-SessionConnected (Get-AccountSession $Account))) {
    [void](Open-AccountSession $Cfg $Account)
    if (-not (Wait-Until { Test-SessionConnected (Get-AccountSession $Account) } 120 5)) { throw "$($Account.Name) : the session does not open." }
  }
  [void](Register-RobloxProtocols $Account)
  # Signed in already: the app is left alone, since starting it again could
  # disturb a running macro; only the web sign-in page is opened.
  if (-not (Get-RobloxSignedIn $Account.Name)) {
    $staleBefore = (Get-Date).AddMinutes(-3)
    Get-RobloxProcessesInSession $Account | Where-Object { $_.StartTime -lt $staleBefore } | Stop-Process -Force -ErrorAction SilentlyContinue
    [void](Start-InAccountSession $Account 'RobloxOpen' $exe.FullName '')
  }
  # Natro's browser fallback needs the roblox.com sign-in too, which is
  # separate from the app's: open its login page in the same go. The
  # owner's own Edge (local account) keeps its settings.
  if (-not $Account.Local) { Set-AccountEdgeQuiet $Account }
  $edge = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction SilentlyContinue).'(default)'
  if ($edge -and (Test-Path $edge)) { [void](Start-InAccountSession $Account 'RobloxWeb' $edge 'https://www.roblox.com/login') }
  Write-Log "$($Account.Name) : Roblox and the roblox.com page opened in its session, sign in to both (once)." OK
}

# Every step needed for one Roblox account, each skipped when already done,
# so running it again resumes where it stopped.
# Names follow the Roblox account when it is known, else the role (the
# owner may not know which Roblox account plays GuidingALT1: it is then
# learnt at the first sign-in).
function Add-RobloxAccount {
  param($Cfg, [string] $Roblox, [string] $Role, [string] $WindowsUser, [string] $SourcePath)
  $label = $(if ($Roblox) { $Roblox } else { $Role })
  if (-not $label) { throw 'A Roblox account or a role is required.' }
  foreach ($n in @($Roblox, $Role) | Where-Object { $_ }) {
    if ($n -notmatch '^[A-Za-z0-9_]{3,20}$') { throw "Invalid name: $n (3 to 20 letters, digits or _)." }
  }
  if (-not $WindowsUser) { $WindowsUser = $label }
  if (-not (Test-ValidAccountName $WindowsUser)) { throw "Invalid Windows account name: $WindowsUser (3 to 20 letters, digits or _, different from the PC's name and yours)." }
  $password = Get-CommonPassword
  if (-not $password) { throw 'No common password for the macro accounts: set it first (Settings tab).' }
  Write-Log "=== $label : preparing (Windows account $WindowsUser$(if ($Roblox) { ", Roblox $Roblox" } else { ', Roblox account learnt at the first sign-in' })) ==="

  if (-not (Get-WrapperState $Cfg).Healthy) {
    if (-not (Update-RdpWrapper $Cfg)) { throw 'RDP Wrapper unusable: the session could not open.' }
  }

  $account = $Cfg.Accounts | Where-Object { $_.Name -eq $WindowsUser } | Select-Object -First 1
  if (-not $account) {
    $account = New-AccountEntry $Cfg $WindowsUser $Roblox $Role
    $Cfg.Accounts = @($Cfg.Accounts) + $account
  }
  if ($Roblox) { $account.Roblox = $Roblox }
  if ($Role) { $account.Role = $Role }
  if (-not (Get-LocalUser -Name $WindowsUser -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $WindowsUser -Password $password -PasswordNeverExpires -AccountNeverExpires -UserMayNotChangePassword -Description (Get-AccountDescription $label) | Out-Null
    Set-AccountCredential $account $password
    Write-Log "Windows account $WindowsUser created with the common password." OK
  } elseif (-not [BssNative]::CredExists((Get-CredTarget $account))) {
    Set-AccountCommonPassword $account
  }
  Add-ToRdpGroups $WindowsUser
  # Two Windows accounts playing one Roblox account would fight over it.
  if ($Roblox) {
    foreach ($other in @($Cfg.Accounts | Where-Object { $_.Name -ne $WindowsUser -and $_.Roblox -eq $Roblox -and $_.Enabled })) {
      $other.Enabled = $false
      Write-Log "$($other.Name) excluded: $Roblox now has its own Windows account ($WindowsUser)." WARN
    }
  }
  Save-BssConfig $Cfg

  $account.MacroPath = New-CleanMacro $Cfg $label $SourcePath
  # Two accounts on one macro folder would share and overwrite its settings.
  foreach ($other in @($Cfg.Accounts | Where-Object { $_.Name -ne $WindowsUser -and $_.MacroPath -eq $account.MacroPath -and $_.Enabled })) {
    $other.Enabled = $false
    Write-Log "$($other.Name) excluded: its macro $(Split-Path $account.MacroPath -Leaf) now belongs to $WindowsUser." WARN
  }
  Save-BssConfig $Cfg
  Set-MacroFolderAcl $Cfg $account.MacroPath

  # Before the first sign-in, or Windows asks its privacy questions.
  Disable-PrivacyPrompt
  if (-not (Test-SessionConnected (Get-AccountSession $account))) { [void](Open-AccountSession $Cfg $account) }
  # The first sign-in builds the Windows profile, which can take a minute.
  if (-not (Wait-Until { (Test-SessionConnected (Get-AccountSession $account)) -and (Get-UserProfilePath $WindowsUser) } 300 5)) {
    throw "The session of $WindowsUser did not open within 5 minutes."
  }
  Set-AccountPrivacyOff $account
  Set-AccountEdgeQuiet $account
  Add-MacroFirewallRules $account.MacroPath
  # Roblox's installer fails while any other Roblox runs: install in a
  # window, which pauses the running macros briefly and restarts them.
  $installed = Invoke-RobloxWindow $Cfg "Roblox install for $WindowsUser" { Install-RobloxInSession $account } 300
  if (-not $installed) { throw "Roblox did not install in the session of $WindowsUser." }
  # Give the installer's own registration a moment, then fill any gap.
  [void](Wait-Until { Get-RegisteredProtocolExe "Registry::HKEY_USERS\$((Get-LocalUser -Name $WindowsUser).SID.Value)\Software\Classes" 'roblox' } 60 5)
  [void](Register-RobloxProtocols $account)
  if (-not (Get-RobloxSignedIn $WindowsUser)) { Open-RobloxForSignIn $Cfg $account }

  [void](Update-LearnedRobloxNames $Cfg)
  if (-not (Get-AccountReadiness $account)) {
    if (Start-Natro $Cfg $account) { Write-Log "$label is ready: the macro starts." OK }
  } else {
    $who = $(if ($Roblox) { "as $Roblox " } else { '' })
    Write-Log "$label : in the Remote Desktop window of $WindowsUser, sign in to Roblox $who(only once). The macro then starts by itself (supervisor) or with 'Start'." WARN
  }
}

function Set-AccountRobloxNames {
  param($Cfg, [string] $Name, [string] $Roblox, [string] $Role)
  $a = Get-AccountByName $Cfg $Name
  foreach ($n in @($Roblox, $Role) | Where-Object { $_ }) {
    if ($n -notmatch '^[A-Za-z0-9_]{3,20}$') { throw "Invalid name: $n (3 to 20 letters, digits or _)." }
  }
  $a.Roblox = $Roblox
  $a.Role = $Role
  Save-BssConfig $Cfg
  Sync-NatroTask $Cfg $a
  Write-Log "$Name : Roblox account '$(if ($Roblox) { $Roblox } else { 'learnt at the next sign-in' })', role '$Role'." OK
}

# Applies the common password to every managed Windows account.
function Set-CommonPasswordOnAll {
  param($Cfg)
  foreach ($a in @($Cfg.Accounts | Where-Object { -not $_.Local -and $_.Name -ne $env:USERNAME -and (Get-LocalUser -Name $_.Name -ErrorAction SilentlyContinue) })) {
    try { Set-AccountCommonPassword $a } catch { Write-Log "$($a.Name) : $($_.Exception.Message)" ERROR }
  }
}

# Roblox accounts the macro folders suggest, with the folders that could
# serve as a base, most recently used first and Cursed ones before old ones.
function Get-RobloxAccountSuggestions {
  param($Cfg)
  # A name already used by an account with its own Windows account (as its
  # Roblox name, role or account name) is not suggested again.
  $owned = @($Cfg.Accounts | Where-Object { $_.Name -eq $_.Roblox -or $_.Name -eq $_.Role } | ForEach-Object { $_.Name, $_.Roblox, $_.Role } | Where-Object { $_ })
  $groups = @{}
  foreach ($m in Find-Macros $Cfg) {
    $guess = Get-RobloxNameGuess $m.Name
    if (-not $guess) { continue }
    if (-not $groups.ContainsKey($guess)) { $groups[$guess] = @() }
    $groups[$guess] += $m
  }
  foreach ($name in ($groups.Keys | Sort-Object)) {
    [pscustomobject]@{
      Roblox     = $name
      Configured = ($owned -contains $name)
      Candidates = @($groups[$name] | Sort-Object @{ Expression = { -not $_.IsGit } }, @{ Expression = { $_.LastUsed }; Descending = $true })
    }
  }
}

function Reset-AccountPassword {
  param($Cfg, [string] $Name)
  Set-AccountCommonPassword (Get-AccountByName $Cfg $Name)
}

function Set-AccountMacroPath {
  param($Cfg, [string] $Name, [string] $Path)
  $a = Get-AccountByName $Cfg $Name
  if ($Path -and -not (Test-NatroFolder $Path)) { throw "Not a Natro macro: $Path" }
  $previous = $a.MacroPath
  $a.MacroPath = $Path
  Save-BssConfig $Cfg
  Sync-NatroTask $Cfg $a
  foreach ($p in @($previous, $Path) | Where-Object { $_ } | Sort-Object -Unique) { Set-MacroFolderAcl $Cfg $p }
  Write-Log "$Name : macro = $(if ($Path) { $Path } else { '(none)' })." OK
}

function Set-AccountPasswordValue {
  param($Cfg, [string] $Name, [Security.SecureString] $Password, [bool] $ChangeWindows)
  $a = Get-AccountByName $Cfg $Name
  if (-not $Password -or $Password.Length -eq 0) { throw 'Empty password.' }
  if ($a.Local -or $Name -eq $env:USERNAME) { throw "$Name is your own Windows account: BSS Manager neither saves nor changes its password." }
  if ($ChangeWindows) {
    Set-LocalUser -Name $Name -Password $Password
    Write-Log "Windows password of $Name changed." OK
  }
  Set-AccountCredential $a $Password
  Write-Log "Password of $Name saved for opening its session automatically." OK
}

function Set-AccountFlag {
  param($Cfg, [string] $Name, [ValidateSet('Paused', 'Enabled')] [string] $Flag, [bool] $Value)
  $a = Get-AccountByName $Cfg $Name
  $a.$Flag = $Value
  Save-BssConfig $Cfg
  if ($Flag -eq 'Enabled') {
    Sync-NatroTask $Cfg $a
    # Only an active account may write in its macro folder.
    if ($a.MacroPath) { Set-MacroFolderAcl $Cfg $a.MacroPath }
  }
  $text = switch ($Flag) {
    'Paused' { if ($Value) { 'paused: the supervisor restarts nothing (the session stays open)' } else { 'no longer paused' } }
    'Enabled' { if ($Value) { 'active: started by Start and supervised' } else { 'inactive: neither started by Start nor supervised' } }
  }
  Write-Log "$Name $text." OK
}

# ---------------------------------------------------------------------------
# The local account: one account run in the owner's own session
# ---------------------------------------------------------------------------
# An RDP session costs memory and GPU; the owner's session is there anyway.
# Choosing an account moves its Roblox account, role and macro into an
# entry for the owner's Windows account, and excludes the account it came
# from (its RDP session is what is saved; it is not deleted).

# Config change only, no side effect, so it can be tested. $SourceName
# empty removes the local account. Returns the entry that left the local
# role (to stop) and the account whose session to close.
function Set-LocalAccountConfig {
  param($Cfg, [string] $SourceName, [string] $Owner)
  $previous = $Cfg.Accounts | Where-Object { $_.Local } | Select-Object -First 1
  $result = @{ Previous = $previous; Close = $null; Local = $null }
  $Cfg.Accounts = @($Cfg.Accounts | Where-Object { -not $_.Local })
  if (-not $SourceName) { return $result }
  $source = Get-AccountByName $Cfg $SourceName
  $source.Enabled = $false
  $local = [pscustomobject]@{
    Name      = $Owner
    Roblox    = [string]$source.Roblox
    Role      = [string]$source.Role
    Local     = $true
    Enabled   = $true
    Paused    = $false
    Ip        = ''
    MacroPath = [string]$source.MacroPath
  }
  $Cfg.Accounts = @($Cfg.Accounts) + $local
  $result.Close = $source
  $result.Local = $local
  return $result
}

function Set-LocalAccount {
  param($Cfg, [string] $SourceName)
  $r = Set-LocalAccountConfig $Cfg $SourceName $env:USERNAME
  # The previous local account's Natro and Roblox stop; the session stays.
  if ($r.Previous) { [void](Close-AccountSession $r.Previous) }
  Save-BssConfig $Cfg
  # The excluded account must lose its write right on the macro now run in
  # the owner's session.
  foreach ($p in @($r.Previous.MacroPath, $r.Local.MacroPath) | Where-Object { $_ } | Sort-Object -Unique) { Set-MacroFolderAcl $Cfg $p }
  if ($r.Close) {
    [void](Close-AccountSession $r.Close)
    Sync-NatroTask $Cfg $r.Close
    Write-Log "$($r.Close.Name) excluded, its RDP session closed: its account now runs in your session." OK
  }
  if ($r.Local) {
    Sync-NatroTask $Cfg $r.Local
    $who = $(if ($r.Local.Roblox) { $r.Local.Roblox } else { 'the Roblox account signed in to your Roblox' })
    Write-Log "Local account: $who, macro $(Split-Path $r.Local.MacroPath -Leaf), in your session. 'Start' starts it." OK
  } else {
    Write-Log 'No local account anymore: your session no longer runs a macro.' OK
  }
}

function Remove-ManagedAccount {
  param($Cfg, [string] $Name, [bool] $DeleteWindowsAccount)
  $a = Get-AccountByName $Cfg $Name
  [void](Close-AccountSession $a)
  Unregister-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName (Get-NatroTaskName $a) -Confirm:$false -ErrorAction SilentlyContinue
  if (-not $a.Local) { [BssNative]::DeleteCred((Get-CredTarget $a)) }
  $Cfg.Accounts = @($Cfg.Accounts | Where-Object { $_.Name -ne $Name })
  Save-BssConfig $Cfg
  if ($a.MacroPath) { Set-MacroFolderAcl $Cfg $a.MacroPath }
  Write-Log "$Name removed from BSS Manager." OK
  # The owner's own Windows account is never deleted, whatever is asked.
  if ($DeleteWindowsAccount -and ($Name -eq $env:USERNAME -or $a.Local)) {
    Write-Log "$Name is your own Windows account: it is never deleted." WARN
  } elseif ($DeleteWindowsAccount -and (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue)) {
    Remove-LocalUser -Name $Name
    Write-Log "Windows account $Name deleted (the folder C:\Users\$Name stays on the disk)." OK
  }
}

# ---------------------------------------------------------------------------
# Macro updates
# ---------------------------------------------------------------------------

# Updates the macros of the given accounts, the given folders (-Paths) or
# every Cursed folder (-AllFolders), then restarts the ones whose account is
# running.
function Update-Macros {
  param($Cfg, [string[]] $Names, [switch] $AllFolders, [string[]] $Paths)
  if ($Paths) {
    $paths = @($Paths)
  } elseif ($AllFolders) {
    $paths = @(Find-Macros $Cfg | Where-Object { $_.IsGit -and $_.HasTools } | ForEach-Object { $_.Path })
  } else {
    $paths = @(Select-Accounts $Cfg $Names -IncludeDisabled | Where-Object { $_.MacroPath } | ForEach-Object { $_.MacroPath } | Sort-Object -Unique)
  }
  if (-not $paths.Count) { Write-Log 'No macro to update.' WARN; return }
  $sessions = Get-BssSessions
  foreach ($path in $paths) {
    [void](Update-Macro $Cfg $path)
    foreach ($a in @($Cfg.Accounts | Where-Object { $_.MacroPath -eq $path -and $_.Enabled -and -not $_.Paused })) {
      if ((Test-SessionConnected (Get-AccountSession $a $sessions)) -and -not (Test-NatroRunning $a)) {
        if (Start-Natro $Cfg $a) { Write-Log "$($a.Name) : macro restarted." OK }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

function Get-SupervisorTaskName { return 'Supervisor' }
function Get-StartAllTaskName { return 'Start-All' }

# A disabled supervisor stays off: disabling is the owner's decision.
function Start-SupervisorTask {
  $task = Get-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName (Get-SupervisorTaskName) -ErrorAction SilentlyContinue
  if ($task -and $task.State -eq 'Ready') { Start-ScheduledTask -InputObject $task; Write-Log 'Supervisor started.' OK }
}

function New-ManagerTaskAction {
  param([string] $Arguments, [string] $WindowStyle)
  $main = Join-Path $Script:Bss.Root 'BSS-Manager.ps1'
  return (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle {0} -File "{1}" {2}' -f $WindowStyle, $main, $Arguments))
}

function New-Shortcut {
  param([string] $Path, [string] $Target, [string] $Arguments, [string] $Icon)
  # https://learn.microsoft.com/troubleshoot/windows-client/admin-development/create-desktop-shortcut-with-wsh
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($Path)
  $link.TargetPath = $Target
  $link.Arguments = $Arguments
  $link.WorkingDirectory = $Script:Bss.Root
  if ($Icon) { $link.IconLocation = $Icon }
  $link.Save()
}

# Scheduled tasks run these scripts with administrator rights, so only
# administrators may change them. The whole list is replaced, so a write
# right granted by hand (for development) does not survive an installation;
# icacls /grant:r would only have replaced the rights of the SIDs it names.
# https://learn.microsoft.com/dotnet/api/system.security.accesscontrol.directorysecurity
function Set-ManagerAcl {
  param([string] $Root)
  $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
  $none = [Security.AccessControl.PropagationFlags]::None
  $acl = New-Object Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($rule in @(
      @('S-1-5-32-544', 'FullControl'),
      @('S-1-5-18', 'FullControl'),
      @('S-1-5-32-545', 'ReadAndExecute'))) {
    $sid = New-Object Security.Principal.SecurityIdentifier $rule[0]
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, $rule[1], $inherit, $none, 'Allow')))
  }
  Set-Acl -Path $Root -AclObject $acl
  # Children drop their own entries and inherit the list above.
  & icacls.exe (Join-Path $Root '*') /reset /T /C /Q | Out-Null
  Write-Log 'Folder rights: changes reserved to administrators.' OK
}

function Install-Manager {
  param($Cfg)
  $root = $Script:Bss.Root
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name

  Set-ManagerAcl $root
  Set-MacroRootAcl $Cfg
  Disable-PrivacyPrompt
  if ($Cfg.InboxEnabled) {
    if (-not (Test-Path $Script:Bss.InboxDir)) { New-Item -ItemType Directory -Path $Script:Bss.InboxDir | Out-Null }
    & icacls.exe $Script:Bss.InboxDir /grant '*S-1-5-32-555:(OI)(CI)M' | Out-Null
    Write-Log 'Inbox writable by the Remote Desktop accounts.' OK
  }

  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest

  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
  $trigger.Delay = 'PT30S'
  Register-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName (Get-SupervisorTaskName) -Action (New-ManagerTaskAction '-Action Supervise -Unattended' 'Hidden') `
    -Trigger $trigger -Principal $principal -Settings $settings -Description 'Keeps the macro sessions and Natro Macro running (BSS Manager)' -Force | Out-Null
  Write-Log "Supervisor installed: it starts at every sign-in of $user." OK

  # Run on demand by the desktop shortcut through schtasks /run, which needs
  # no UAC prompt because the task itself carries the rights.
  Register-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName (Get-StartAllTaskName) -Action (New-ManagerTaskAction '-Action Start -Unattended' 'Normal') `
    -Principal $principal -Settings $settings -Description 'One-click start of every macro (BSS Manager)' -Force | Out-Null

  $desktop = [Environment]::GetFolderPath('Desktop')
  Remove-Item (Join-Path $desktop 'BSS - Tout lancer.lnk') -ErrorAction SilentlyContinue
  New-Shortcut (Join-Path $desktop 'BSS - Start.lnk') "$env:SystemRoot\System32\schtasks.exe" ('/run /tn "{0}{1}"' -f $Script:Bss.TaskPath, (Get-StartAllTaskName)) "$env:SystemRoot\System32\shell32.dll,137"
  New-Shortcut (Join-Path $desktop 'BSS Manager.lnk') (Join-Path $root 'BSS-Manager.bat') '' "$env:SystemRoot\System32\shell32.dll,21"
  Write-Log 'Shortcuts ''BSS - Start'' and ''BSS Manager'' created on the desktop.' OK

  foreach ($a in @($Cfg.Accounts | Where-Object { Get-LocalUser -Name $_.Name -ErrorAction SilentlyContinue })) {
    Sync-NatroTask $Cfg $a
    if ($a.MacroPath) { Add-MacroFirewallRules $a.MacroPath }
    # Only reaches accounts whose session is open (their hive is loaded).
    # The owner's own Edge is never changed.
    if (-not $a.Local) { Set-AccountEdgeQuiet $a }
  }
  Start-SupervisorTask
}

function Uninstall-Manager {
  foreach ($task in @(Get-ScheduledTask -TaskPath $Script:Bss.TaskPath -ErrorAction SilentlyContinue)) {
    if ($task.State -eq 'Running') { Stop-ScheduledTask -InputObject $task }
    Unregister-ScheduledTask -InputObject $task -Confirm:$false
  }
  $desktop = [Environment]::GetFolderPath('Desktop')
  Remove-Item (Join-Path $desktop 'BSS - Tout lancer.lnk'), (Join-Path $desktop 'BSS - Start.lnk'), (Join-Path $desktop 'BSS Manager.lnk') -ErrorAction SilentlyContinue
  Write-Log 'Tasks and shortcuts deleted. Files, accounts and automatic sign-in are not touched.' OK
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

# One row per account, shared by the text status and the window.
function Get-AccountRows {
  param($Cfg, $Supervisor)
  $sessions = Get-BssSessions
  $processes = Get-AutoHotkeyProcesses
  foreach ($a in @($Cfg.Accounts)) {
    $session = Get-AccountSession $a $sessions
    $macro = $null
    if (Test-NatroFolder $a.MacroPath) { $macro = Get-MacroInfo $Cfg $a.MacroPath }
    # What is missing comes first; the supervisor's view only while it runs,
    # since a stopped supervisor leaves a stale file behind.
    $state = Get-AccountReadiness $a
    if ($state) { $state = "not ready: $state" }
    elseif ($Supervisor -and $Supervisor.Alive -and $Supervisor.Accounts.PSObject.Properties.Name -contains $a.Name) { $state = $Supervisor.Accounts.($a.Name).State }
    [pscustomobject]@{
      Roblox      = $(if ($a.Roblox) { $a.Roblox } else { '(first sign-in)' })
      Role        = [string]$a.Role
      Account     = $(if ($a.Local) { "$($a.Name) (my session)" } else { $a.Name })
      'Signed in' = [string](Get-RobloxSignedIn $a.Name)
      Active      = $(if ($a.Enabled) { 'yes' } else { 'no' })
      Paused      = $(if ($a.Paused) { 'yes' } else { '' })
      Address     = $a.Ip
      Password    = $(if ([BssNative]::CredExists((Get-CredTarget $a))) { 'saved' } else { 'no' })
      Macro       = $(if ($macro) { $macro.Name } elseif ($a.MacroPath) { 'NOT FOUND' } else { '(none)' })
      Version     = $(if ($macro) { $macro.Version } else { '' })
      Branch      = $(if ($macro -and $macro.IsGit) { $macro.Branch } elseif ($macro) { 'old' } else { '' })
      Session     = (Format-SessionState $session)
      Natro       = $(if ($session -and $a.MacroPath -and (Test-NatroRunning $a $session.Id $processes)) { 'running' } elseif ($session) { 'stopped' } else { '' })
      'Roblox settings' = (Get-RobloxSettingsState $a)
      State       = $state
    }
  }
}

function Get-SupervisorTask {
  return (Get-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName (Get-SupervisorTaskName) -ErrorAction SilentlyContinue)
}

# Enabled means: starts at every sign-in and runs now.
function Set-SupervisorEnabled {
  param([bool] $Enabled)
  $task = Get-SupervisorTask
  if (-not $task) { Write-Log 'Supervisor not installed: run the installation first.' WARN; return }
  if ($Enabled) {
    Enable-ScheduledTask -InputObject $task | Out-Null
    Start-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName (Get-SupervisorTaskName)
    Write-Log 'Supervisor enabled and started.' OK
  } else {
    Stop-ScheduledTask -InputObject $task
    Disable-ScheduledTask -InputObject $task | Out-Null
    Write-Log 'Supervisor stopped and disabled.' OK
  }
}

function Show-Status {
  param($Cfg)
  $w = Get-WrapperState $Cfg
  Write-Host "`n=== RDP Wrapper ===" -ForegroundColor Cyan
  Write-Host ('termsrv.dll   : {0}' -f $w.TermsrvVersion)
  Write-Host ('rdpwrap.ini   : Updated={0}' -f $w.IniUpdated)
  Write-Host ('Compatible    : {0}' -f $(if ($w.IniSupports) { 'yes' } else { 'NO' })) -ForegroundColor $(if ($w.IniSupports) { 'Green' } else { 'Red' })
  if (-not $w.IniCrlf) { Write-Host 'Line endings : LF, unreadable by RDP Wrapper -> ''Update RDP Wrapper''' -ForegroundColor Red }
  if (-not $w.ServiceDllOk) { Write-Host 'Service       : does not load rdpwrap.dll' -ForegroundColor Red }
  Write-Host ('Service       : {0}, port {1} {2}' -f $w.Service, $w.Port, $(if ($w.Listening) { 'listening' } else { 'NOT listening' }))

  $sup = Get-SupervisorStatus
  Write-Host "`n=== Supervisor ===" -ForegroundColor Cyan
  if (-not $sup) { Write-Host 'Never started (menu ''Install'').' -ForegroundColor Yellow }
  elseif ($sup.Alive) { Write-Host "Active, last check $($sup.AgeSec) s ago." -ForegroundColor Green }
  else { Write-Host "STOPPED: last check $($sup.AgeSec) s ago." -ForegroundColor Red }

  Write-Host "`n=== Accounts ===" -ForegroundColor Cyan
  $rows = Get-AccountRows $Cfg $sup
  if ($rows) { $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host } else { Write-Host 'No account configured.' -ForegroundColor Yellow }

  $auto = Get-AutoLogonState
  Write-Host '=== PC startup ===' -ForegroundColor Cyan
  Write-Host ('Automatic sign-in : {0}' -f $(if ($auto.Enabled -and $auto.SecretStored) { "enabled ($($auto.User))" } elseif ($auto.Enabled) { 'enabled but WITHOUT a stored password' } else { 'disabled' }))
  if ($auto.PlainTextStored) { Write-Host 'Warning: a plain-text password is present in the registry (Winlogon\DefaultPassword).' -ForegroundColor Red }
}
