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
    if (-not (Get-LocalUser -Name $a.Name -ErrorAction SilentlyContinue)) { Write-Log "$($a.Name) : compte Windows introuvable, ignoré." WARN; continue }
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
# Macro updates
# ---------------------------------------------------------------------------

# Updates the macros of the given accounts (or every Cursed folder with
# -AllFolders), then restarts the ones whose account is running.
function Update-Macros {
  param($Cfg, [string[]] $Names, [switch] $AllFolders)
  if ($AllFolders) {
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

function Start-SupervisorTask {
  $task = Get-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName (Get-SupervisorTaskName) -ErrorAction SilentlyContinue
  if ($task -and $task.State -ne 'Running') { Start-ScheduledTask -InputObject $task; Write-Log 'Superviseur démarré.' OK }
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
  $sessions = Get-BssSessions
  $rows = foreach ($a in @($Cfg.Accounts)) {
    $session = Get-AccountSession $a $sessions
    $macro = $null
    if (Test-NatroFolder $a.MacroPath) { $macro = Get-MacroInfo $Cfg $a.MacroPath }
    $supEntry = $null
    if ($sup -and $sup.Accounts.PSObject.Properties.Name -contains $a.Name) { $supEntry = $sup.Accounts.($a.Name) }
    [pscustomobject]@{
      Compte     = $a.Name
      Inclus     = $(if ($a.Enabled) { 'oui' } else { 'non' })
      Pause      = $(if ($a.Paused) { 'oui' } else { '' })
      Adresse    = $a.Ip
      MotDePasse = $(if ([BssNative]::CredExists((Get-CredTarget $a))) { 'enregistré' } else { 'non' })
      Macro      = $(if ($macro) { $macro.Name } elseif ($a.MacroPath) { 'INTROUVABLE' } else { '(aucune)' })
      Version    = $(if ($macro) { $macro.Version } else { '' })
      Branche    = $(if ($macro -and $macro.IsGit) { $macro.Branch } elseif ($macro) { 'ancienne' } else { '' })
      Session    = (Format-SessionState $session)
      Natro      = $(if ($session -and $a.MacroPath -and (Test-NatroRunning $a $session.Id)) { 'tourne' } elseif ($session) { 'arrêté' } else { '' })
      Superviseur = $(if ($supEntry) { $supEntry.State } else { '' })
    }
  }
  if ($rows) { $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host } else { Write-Host 'Aucun compte configuré.' -ForegroundColor Yellow }

  $auto = Get-AutoLogonState
  Write-Host '=== Démarrage du PC ===' -ForegroundColor Cyan
  Write-Host ('Connexion automatique : {0}' -f $(if ($auto.Enabled -and $auto.SecretStored) { "activée ($($auto.User))" } elseif ($auto.Enabled) { 'activée mais SANS mot de passe stocké' } else { 'désactivée' }))
  if ($auto.PlainTextStored) { Write-Host 'Attention : un mot de passe en clair est présent dans le registre (Winlogon\DefaultPassword).' -ForegroundColor Red }
}
