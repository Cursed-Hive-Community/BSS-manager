# High-level actions, shared by the menu and the command line.

# ---------------------------------------------------------------------------
# Start / stop
# ---------------------------------------------------------------------------

# The one-click action: RDP Wrapper, macro updates, sessions, macros.
function Start-All {
  param($Cfg, [string[]] $Names)
  $accounts = @(Select-Accounts $Cfg $Names)
  if (-not $accounts.Count) { Write-Log 'Aucun compte à lancer : ajoute ou inclus un compte dans « Comptes et macros ».' WARN; return }

  $wrapper = Get-WrapperState $Cfg
  if (-not ($wrapper.IniSupports -and $wrapper.IniCrlf -and $wrapper.ServiceDllOk)) {
    if (-not (Update-RdpWrapper $Cfg)) { Write-Log 'Lancement annulé : sans RDP Wrapper à jour, une seule session peut s''ouvrir.' ERROR; return }
  }

  if ($Cfg.UpdateMacrosOnStart) {
    $paths = @($accounts | Where-Object { $_.MacroPath } | ForEach-Object { $_.MacroPath } | Sort-Object -Unique)
    foreach ($path in $paths) {
      # A macro that already runs is left alone: an update would stop it.
      if (Get-NatroProcesses $path) { Write-Log "$(Split-Path $path -Leaf) tourne déjà : mise à jour au prochain arrêt (ou « Mettre à jour les macros »)."; continue }
      if (Test-Path (Join-Path $path '.git')) { [void](Update-Macro $Cfg $path) }
    }
  }

  foreach ($a in $accounts) { $a.Paused = $false }
  Save-BssConfig $Cfg
  foreach ($a in $accounts) { Sync-NatroTask $Cfg $a }

  $sessions = Get-BssSessions
  $opened = 0
  for ($i = 0; $i -lt $accounts.Count; $i++) {
    $a = $accounts[$i]
    $missing = Get-AccountReadiness $a
    if ($missing) { Write-Log "$($a.Roblox) ($($a.Name)) : pas prêt, $missing." WARN; continue }
    $session = Get-AccountSession $a $sessions
    if (Test-SessionConnected $session) {
      if ($a.MacroPath -and -not (Test-NatroRunning $a $session.Id)) {
        Write-Log "$($a.Name) : session déjà ouverte, démarrage de Natro."
        Start-Natro $a
      } else {
        Write-Log "$($a.Name) : déjà en route."
      }
      continue
    }
    if ($opened -gt 0) { Start-Sleep -Seconds ([int]$Cfg.DelayBetweenSessionsSec) }
    $what = $(if ($session) { 'reconnexion' } elseif ($a.MacroPath) { "ouverture, Natro démarre ~$($Cfg.NatroStartDelaySec) s après" } else { 'ouverture, aucune macro associée' })
    Write-Log "$($a.Name) : $what ($($a.Ip))."
    if (Open-AccountSession $Cfg $a) { $opened++ }
  }
  Write-Log "$opened session(s) ouverte(s)." OK
  Start-SupervisorTask
}

# Pauses first, so the supervisor does not reopen what is being closed.
function Stop-All {
  param($Cfg, [string[]] $Names)
  $accounts = @(Select-Accounts $Cfg $Names -IncludeDisabled)
  if (-not $accounts.Count) { return }
  if (-not (Confirm-Action "Arrêter $(($accounts | ForEach-Object { $_.Name }) -join ', ') (sessions fermées, Roblox et Natro arrêtés) ?")) { return }
  foreach ($a in $accounts) { $a.Paused = $true }
  Save-BssConfig $Cfg
  foreach ($a in $accounts) {
    if (Close-AccountSession $a) { Write-Log "$($a.Name) : session fermée, compte en pause." OK }
    else { Write-Log "$($a.Name) : en pause (aucune session ouverte)." OK }
  }
}

# Restarts one macro: the entry point for the fleet or any script.
function Restart-AccountMacro {
  param($Cfg, [string[]] $Names)
  foreach ($a in @(Select-Accounts $Cfg $Names -IncludeDisabled)) {
    if (-not $a.MacroPath) { Write-Log "$($a.Name) : aucune macro associée." WARN; continue }
    $session = Get-AccountSession $a
    Stop-NatroProcesses $a.MacroPath
    if (Test-SessionConnected $session) {
      Start-Natro $a
      Write-Log "$($a.Name) : macro redémarrée." OK
    } else {
      if (Open-AccountSession $Cfg $a) { Write-Log "$($a.Name) : session rouverte, la macro démarre avec elle." OK }
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
  if (-not $a) { throw "Compte inconnu : $Name" }
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
    Write-Log 'Téléchargement de l''installateur Roblox (roblox.com)...'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://www.roblox.com/download/client?os=win' -OutFile $file -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
  }
  $signature = Get-AuthenticodeSignature $file
  if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O="?Roblox Corporation') {
    Remove-Item $file -Force
    throw "Installateur Roblox refusé : signature $($signature.Status), $($signature.SignerCertificate.Subject)"
  }
  return $file
}

# Runs the installer inside the account's own session (Roblox installs per
# user), through a one-shot task with an Interactive principal.
function Install-RobloxInSession {
  param($Account)
  if (Test-RobloxInstalled $Account.Name) { Write-Log "$($Account.Name) : Roblox déjà installé."; return $true }
  $installer = Get-RobloxInstaller
  $user = Get-QualifiedUser $Account.Name
  $name = "RobloxSetup-$($Account.Name)"
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
  Register-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName $name -Action (New-ScheduledTaskAction -Execute $installer) `
    -Principal $principal -Settings $settings -Description 'One-shot Roblox install (BSS Manager)' -Force | Out-Null
  try {
    Write-Log "$($Account.Name) : installation de Roblox dans sa session..."
    Start-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName $name
    $done = Wait-Until { Test-RobloxInstalled $Account.Name } 600 10
  } finally {
    Unregister-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
  }
  if ($done) { Write-Log "$($Account.Name) : Roblox installé." OK }
  return $done
}

# Every step needed for one Roblox account, each skipped when already done,
# so running it again resumes where it stopped.
function Add-RobloxAccount {
  param($Cfg, [string] $Roblox, [string] $WindowsUser, [string] $SourcePath)
  if (-not $WindowsUser) { $WindowsUser = $Roblox }
  if ($Roblox -notmatch '^[A-Za-z0-9_]{3,20}$') { throw "Nom Roblox invalide : $Roblox" }
  if (-not (Test-ValidAccountName $WindowsUser)) { throw "Nom de compte Windows impossible : $WindowsUser (3 à 20 lettres, chiffres ou _, différent du nom du PC et du tien)." }
  Write-Log "=== $Roblox : préparation (compte Windows $WindowsUser) ==="

  if (-not (Get-WrapperState $Cfg).Healthy) {
    if (-not (Update-RdpWrapper $Cfg)) { throw 'RDP Wrapper inutilisable : la session ne pourrait pas s''ouvrir.' }
  }

  $account = $Cfg.Accounts | Where-Object { $_.Name -eq $WindowsUser } | Select-Object -First 1
  if (-not $account) {
    $account = New-AccountEntry $Cfg $WindowsUser $Roblox
    $Cfg.Accounts = @($Cfg.Accounts) + $account
  }
  $account.Roblox = $Roblox
  if (-not (Get-LocalUser -Name $WindowsUser -ErrorAction SilentlyContinue)) {
    $password = New-RandomPassword
    New-LocalUser -Name $WindowsUser -Password $password -PasswordNeverExpires -AccountNeverExpires -UserMayNotChangePassword -Description (Get-AccountDescription $Roblox) | Out-Null
    Set-AccountCredential $account $password
    Write-Log "Compte Windows $WindowsUser créé, mot de passe généré et mémorisé." OK
  } elseif (-not [BssNative]::CredExists((Get-CredTarget $account))) {
    $password = New-RandomPassword
    Set-LocalUser -Name $WindowsUser -Password $password
    Set-AccountCredential $account $password
    Write-Log "Compte Windows $WindowsUser existant : nouveau mot de passe généré et mémorisé." WARN
  }
  Add-ToRdpGroups $WindowsUser
  # Two Windows accounts playing one Roblox account would fight over it.
  foreach ($other in @($Cfg.Accounts | Where-Object { $_.Name -ne $WindowsUser -and $_.Roblox -eq $Roblox -and $_.Enabled })) {
    $other.Enabled = $false
    Write-Log "$($other.Name) exclu : $Roblox a maintenant son propre compte Windows ($WindowsUser)." WARN
  }
  Save-BssConfig $Cfg

  $account.MacroPath = New-CleanMacro $Cfg $Roblox $SourcePath
  Save-BssConfig $Cfg

  if (-not (Test-SessionConnected (Get-AccountSession $account))) { [void](Open-AccountSession $Cfg $account) }
  # The first sign-in builds the Windows profile, which can take a minute.
  if (-not (Wait-Until { (Test-SessionConnected (Get-AccountSession $account)) -and (Get-UserProfilePath $WindowsUser) } 300 5)) {
    throw "La session de $WindowsUser ne s'est pas ouverte en 5 minutes."
  }
  if (-not (Install-RobloxInSession $account)) { throw "Roblox ne s'est pas installé dans la session de $WindowsUser en 10 minutes." }

  $signedIn = Get-RobloxSignedIn $WindowsUser
  if ($signedIn -eq $Roblox) {
    Sync-NatroTask $Cfg $account
    Start-Natro $account
    Write-Log "$Roblox est prêt : la macro démarre." OK
  } else {
    Write-Log "$Roblox : dans la fenêtre Bureau à distance de $WindowsUser, connecte-toi à Roblox avec $Roblox. La macro démarrera ensuite toute seule (superviseur) ou avec « Lancer »." WARN
  }
}

# Roblox accounts the macro folders suggest, with the folders that could
# serve as a base, most recently used first and Cursed ones before old ones.
function Get-RobloxAccountSuggestions {
  param($Cfg)
  $owned = @($Cfg.Accounts | Where-Object { $_.Roblox -and $_.Name -eq $_.Roblox } | ForEach-Object { $_.Roblox })
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
  $a = Get-AccountByName $Cfg $Name
  $password = New-RandomPassword
  Set-LocalUser -Name $Name -Password $password
  Set-AccountCredential $a $password
  Write-Log "$Name : nouveau mot de passe généré et mémorisé." OK
}

function Set-AccountMacroPath {
  param($Cfg, [string] $Name, [string] $Path)
  $a = Get-AccountByName $Cfg $Name
  if ($Path -and -not (Test-NatroFolder $Path)) { throw "Pas une macro Natro : $Path" }
  $a.MacroPath = $Path
  Save-BssConfig $Cfg
  Sync-NatroTask $Cfg $a
  Write-Log "$Name : macro = $(if ($Path) { $Path } else { '(aucune)' })." OK
}

function Set-AccountPasswordValue {
  param($Cfg, [string] $Name, [Security.SecureString] $Password, [bool] $ChangeWindows)
  $a = Get-AccountByName $Cfg $Name
  if (-not $Password -or $Password.Length -eq 0) { throw 'Mot de passe vide.' }
  if ($ChangeWindows) {
    Set-LocalUser -Name $Name -Password $Password
    Write-Log "Mot de passe Windows de $Name changé." OK
  }
  Set-AccountCredential $a $Password
  Write-Log "Mot de passe de $Name enregistré pour l'ouverture automatique de sa session." OK
}

function Set-AccountFlag {
  param($Cfg, [string] $Name, [ValidateSet('Paused', 'Enabled')] [string] $Flag, [bool] $Value)
  $a = Get-AccountByName $Cfg $Name
  $a.$Flag = $Value
  Save-BssConfig $Cfg
  if ($Flag -eq 'Enabled') { Sync-NatroTask $Cfg $a }
  $text = switch ($Flag) {
    'Paused' { if ($Value) { 'en pause : le superviseur ne relance plus rien (la session reste ouverte)' } else { 'n''est plus en pause' } }
    'Enabled' { if ($Value) { 'inclus dans « Tout lancer » et la supervision' } else { 'exclu de « Tout lancer » et de la supervision' } }
  }
  Write-Log "$Name $text." OK
}

function Remove-ManagedAccount {
  param($Cfg, [string] $Name, [bool] $DeleteWindowsAccount)
  $a = Get-AccountByName $Cfg $Name
  [void](Close-AccountSession $a)
  Unregister-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName (Get-NatroTaskName $a) -Confirm:$false -ErrorAction SilentlyContinue
  [BssNative]::DeleteCred((Get-CredTarget $a))
  $Cfg.Accounts = @($Cfg.Accounts | Where-Object { $_.Name -ne $Name })
  Save-BssConfig $Cfg
  Write-Log "$Name retiré de BSS Manager." OK
  if ($DeleteWindowsAccount -and (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue)) {
    Remove-LocalUser -Name $Name
    Write-Log "Compte Windows $Name supprimé (le dossier C:\Users\$Name reste sur le disque)." OK
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
  if (-not $paths.Count) { Write-Log 'Aucune macro à mettre à jour.' WARN; return }
  $sessions = Get-BssSessions
  foreach ($path in $paths) {
    [void](Update-Macro $Cfg $path)
    foreach ($a in @($Cfg.Accounts | Where-Object { $_.MacroPath -eq $path -and $_.Enabled -and -not $_.Paused })) {
      if ((Test-SessionConnected (Get-AccountSession $a $sessions)) -and -not (Test-NatroRunning $a)) {
        Start-Natro $a
        Write-Log "$($a.Name) : macro relancée." OK
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
  if ($task -and $task.State -eq 'Ready') { Start-ScheduledTask -InputObject $task; Write-Log 'Superviseur démarré.' OK }
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
  Write-Log 'Droits du dossier : modification réservée aux administrateurs.' OK
}

function Install-Manager {
  param($Cfg)
  $root = $Script:Bss.Root
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name

  Set-ManagerAcl $root
  if ($Cfg.InboxEnabled) {
    if (-not (Test-Path $Script:Bss.InboxDir)) { New-Item -ItemType Directory -Path $Script:Bss.InboxDir | Out-Null }
    & icacls.exe $Script:Bss.InboxDir /grant '*S-1-5-32-555:(OI)(CI)M' | Out-Null
    Write-Log 'Boîte de réception ouverte en écriture aux comptes Bureau à distance.' OK
  }

  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest

  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
  $trigger.Delay = 'PT30S'
  Register-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName (Get-SupervisorTaskName) -Action (New-ManagerTaskAction '-Action Supervise -Unattended' 'Hidden') `
    -Trigger $trigger -Principal $principal -Settings $settings -Description 'Keeps the macro sessions and Natro Macro running (BSS Manager)' -Force | Out-Null
  Write-Log "Superviseur installé : il démarre à chaque ouverture de session de $user." OK

  # Run on demand by the desktop shortcut through schtasks /run, which needs
  # no UAC prompt because the task itself carries the rights.
  Register-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName (Get-StartAllTaskName) -Action (New-ManagerTaskAction '-Action Start -Unattended' 'Normal') `
    -Principal $principal -Settings $settings -Description 'One-click start of every macro (BSS Manager)' -Force | Out-Null

  $desktop = [Environment]::GetFolderPath('Desktop')
  New-Shortcut (Join-Path $desktop 'BSS - Tout lancer.lnk') "$env:SystemRoot\System32\schtasks.exe" ('/run /tn "{0}{1}"' -f $Script:Bss.TaskPath, (Get-StartAllTaskName)) "$env:SystemRoot\System32\shell32.dll,137"
  New-Shortcut (Join-Path $desktop 'BSS Manager.lnk') (Join-Path $root 'BSS-Manager.bat') '' "$env:SystemRoot\System32\shell32.dll,21"
  Write-Log 'Raccourcis « BSS - Tout lancer » et « BSS Manager » créés sur le bureau.' OK

  foreach ($a in @($Cfg.Accounts)) { Sync-NatroTask $Cfg $a }
  Start-SupervisorTask
}

function Uninstall-Manager {
  foreach ($task in @(Get-ScheduledTask -TaskPath $Script:Bss.TaskPath -ErrorAction SilentlyContinue)) {
    if ($task.State -eq 'Running') { Stop-ScheduledTask -InputObject $task }
    Unregister-ScheduledTask -InputObject $task -Confirm:$false
  }
  $desktop = [Environment]::GetFolderPath('Desktop')
  Remove-Item (Join-Path $desktop 'BSS - Tout lancer.lnk'), (Join-Path $desktop 'BSS Manager.lnk') -ErrorAction SilentlyContinue
  Write-Log 'Tâches et raccourcis supprimés. Les fichiers, comptes et la connexion automatique ne sont pas touchés.' OK
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
    if ($state) { $state = "pas prêt : $state" }
    elseif ($Supervisor -and $Supervisor.Alive -and $Supervisor.Accounts.PSObject.Properties.Name -contains $a.Name) { $state = $Supervisor.Accounts.($a.Name).State }
    [pscustomobject]@{
      Roblox      = $(if ($a.Roblox) { $a.Roblox } else { '?' })
      Compte      = $a.Name
      'Connecté'  = [string](Get-RobloxSignedIn $a.Name)
      Inclus      = $(if ($a.Enabled) { 'oui' } else { 'non' })
      Pause       = $(if ($a.Paused) { 'oui' } else { '' })
      Adresse     = $a.Ip
      MotDePasse  = $(if ([BssNative]::CredExists((Get-CredTarget $a))) { 'enregistré' } else { 'non' })
      Macro       = $(if ($macro) { $macro.Name } elseif ($a.MacroPath) { 'INTROUVABLE' } else { '(aucune)' })
      Version     = $(if ($macro) { $macro.Version } else { '' })
      Branche     = $(if ($macro -and $macro.IsGit) { $macro.Branch } elseif ($macro) { 'ancienne' } else { '' })
      Session     = (Format-SessionState $session)
      Natro       = $(if ($session -and $a.MacroPath -and (Test-NatroRunning $a $session.Id $processes)) { 'tourne' } elseif ($session) { 'arrêté' } else { '' })
      'État'      = $state
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
  if (-not $task) { Write-Log 'Superviseur pas installé : lance d''abord l''installation.' WARN; return }
  if ($Enabled) {
    Enable-ScheduledTask -InputObject $task | Out-Null
    Start-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName (Get-SupervisorTaskName)
    Write-Log 'Superviseur activé et démarré.' OK
  } else {
    Stop-ScheduledTask -InputObject $task
    Disable-ScheduledTask -InputObject $task | Out-Null
    Write-Log 'Superviseur arrêté et désactivé.' OK
  }
}

function Show-Status {
  param($Cfg)
  $w = Get-WrapperState $Cfg
  Write-Host "`n=== RDP Wrapper ===" -ForegroundColor Cyan
  Write-Host ('termsrv.dll   : {0}' -f $w.TermsrvVersion)
  Write-Host ('rdpwrap.ini   : Updated={0}' -f $w.IniUpdated)
  Write-Host ('Compatible    : {0}' -f $(if ($w.IniSupports) { 'oui' } else { 'NON' })) -ForegroundColor $(if ($w.IniSupports) { 'Green' } else { 'Red' })
  if (-not $w.IniCrlf) { Write-Host 'Fins de ligne : LF, illisible par RDP Wrapper -> « Mettre à jour RDP Wrapper »' -ForegroundColor Red }
  if (-not $w.ServiceDllOk) { Write-Host 'Service       : ne charge pas rdpwrap.dll' -ForegroundColor Red }
  Write-Host ('Service       : {0}, port {1} {2}' -f $w.Service, $w.Port, $(if ($w.Listening) { 'en écoute' } else { 'PAS en écoute' }))

  $sup = Get-SupervisorStatus
  Write-Host "`n=== Superviseur ===" -ForegroundColor Cyan
  if (-not $sup) { Write-Host 'Jamais lancé (menu « Installation »).' -ForegroundColor Yellow }
  elseif ($sup.Alive) { Write-Host "Actif, dernière vérification il y a $($sup.AgeSec) s." -ForegroundColor Green }
  else { Write-Host "ARRÊTÉ : dernière vérification il y a $($sup.AgeSec) s." -ForegroundColor Red }

  Write-Host "`n=== Comptes ===" -ForegroundColor Cyan
  $rows = Get-AccountRows $Cfg $sup
  if ($rows) { $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host } else { Write-Host 'Aucun compte configuré.' -ForegroundColor Yellow }

  $auto = Get-AutoLogonState
  Write-Host '=== Démarrage du PC ===' -ForegroundColor Cyan
  Write-Host ('Connexion automatique : {0}' -f $(if ($auto.Enabled -and $auto.SecretStored) { "activée ($($auto.User))" } elseif ($auto.Enabled) { 'activée mais SANS mot de passe stocké' } else { 'désactivée' }))
  if ($auto.PlainTextStored) { Write-Host 'Attention : un mot de passe en clair est présent dans le registre (Winlogon\DefaultPassword).' -ForegroundColor Red }
}
