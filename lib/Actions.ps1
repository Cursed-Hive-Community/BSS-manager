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
  if (-not $accounts.Count) { Write-Log 'Aucun compte actif à lancer : rends un compte actif dans l''onglet Comptes Roblox.' WARN; return }
  if (-not $Cfg.Running) {
    $Cfg.Running = $true
    Save-BssConfig $Cfg
    Write-Log 'Système démarré : le superviseur surveille et relance les comptes actifs.' OK
  }

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
  [void](Update-LearnedRobloxNames $Cfg)
  foreach ($a in $accounts) { Sync-NatroTask $Cfg $a }

  $sessions = Get-BssSessions
  $opened = 0
  for ($i = 0; $i -lt $accounts.Count; $i++) {
    $a = $accounts[$i]
    $missing = Get-AccountReadiness $a
    if ($missing) { Write-Log "$($a.Roblox) ($($a.Name)) : pas prêt, $missing." WARN; continue }
    Add-MacroFirewallRules $a.MacroPath
    $session = Get-AccountSession $a $sessions
    if (Test-SessionConnected $session) {
      if ($a.MacroPath -and -not (Test-NatroRunning $a $session.Id)) {
        Write-Log "$($a.Name) : session déjà ouverte, démarrage de Natro."
        [void](Start-Natro $Cfg $a)
      } else {
        Write-Log "$($a.Name) : déjà en route."
      }
      continue
    }
    # The session's sign-in starts Natro through its own task, not through
    # Start-Natro, so Roblox's settings are put in place here, before it.
    try { [void](Set-AccountRobloxSettings $a) } catch { Write-Log "$($a.Name) : réglages Roblox non appliqués, $($_.Exception.Message)" WARN }
    if ($opened -gt 0) { Start-Sleep -Seconds ([int]$Cfg.DelayBetweenSessionsSec) }
    $what = $(if ($session) { 'reconnexion' } elseif ($a.MacroPath) { "ouverture, Natro démarre ~$($Cfg.NatroStartDelaySec) s après" } else { 'ouverture, aucune macro associée' })
    Write-Log "$($a.Name) : $what ($($a.Ip))."
    if (Open-AccountSession $Cfg $a) { $opened++ }
  }
  Write-Log "$opened session(s) ouverte(s)." OK
  Start-SupervisorTask
}

# Pauses first, so the supervisor does not reopen what is being closed.
# Without names this is Stop for the whole system: it is also switched off,
# and stays off after a reboot until Start.
function Stop-All {
  param($Cfg, [string[]] $Names)
  $accounts = @(Select-Accounts $Cfg $Names -IncludeDisabled)
  if (-not $accounts.Count) { return }
  if (-not (Confirm-Action "Arrêter $(($accounts | ForEach-Object { $_.Name }) -join ', ') (sessions fermées, Roblox et Natro arrêtés) ?")) { return }
  foreach ($a in $accounts) { $a.Paused = $true }
  if (-not $Names) {
    $Cfg.Running = $false
    Write-Log 'Système arrêté : le superviseur ne relance plus rien jusqu''au prochain Start.' OK
  }
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
      if (Start-Natro $Cfg $a) { Write-Log "$($a.Name) : macro redémarrée." OK }
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
  if (Test-RobloxInstalled $Account.Name) { Write-Log "$($Account.Name) : Roblox déjà installé."; return $true }
  $installer = Get-RobloxInstaller
  Write-Log "$($Account.Name) : installation de Roblox dans sa session..."
  $task = Start-InAccountSession $Account 'RobloxSetup' $installer ''
  Start-Sleep -Seconds 5
  $finished = Wait-Until { (Get-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName $task).State -ne 'Running' } 900 10
  $done = Test-RobloxInstalled $Account.Name
  if ($done) { Write-Log "$($Account.Name) : Roblox installé." OK }
  elseif (-not $finished) { Write-Log "$($Account.Name) : l'installateur Roblox tourne encore après 15 minutes." WARN }
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
  if (-not $exe) { throw "$($Account.Name) : Roblox n'est pas installé dans sa session." }
  if (-not (Test-SessionConnected (Get-AccountSession $Account))) {
    [void](Open-AccountSession $Cfg $Account)
    if (-not (Wait-Until { Test-SessionConnected (Get-AccountSession $Account) } 120 5)) { throw "$($Account.Name) : la session ne s'ouvre pas." }
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
  # separate from the app's: open its login page in the same go.
  Set-AccountEdgeQuiet $Account
  $edge = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction SilentlyContinue).'(default)'
  if ($edge -and (Test-Path $edge)) { [void](Start-InAccountSession $Account 'RobloxWeb' $edge 'https://www.roblox.com/login') }
  Write-Log "$($Account.Name) : Roblox et la page roblox.com ouverts dans sa session, connecte-toi aux deux (une fois)." OK
}

# Every step needed for one Roblox account, each skipped when already done,
# so running it again resumes where it stopped.
# Names follow the Roblox account when it is known, else the role (the
# owner may not know which Roblox account plays GuidingALT1: it is then
# learnt at the first sign-in).
function Add-RobloxAccount {
  param($Cfg, [string] $Roblox, [string] $Role, [string] $WindowsUser, [string] $SourcePath)
  $label = $(if ($Roblox) { $Roblox } else { $Role })
  if (-not $label) { throw 'Il faut un compte Roblox ou un rôle.' }
  foreach ($n in @($Roblox, $Role) | Where-Object { $_ }) {
    if ($n -notmatch '^[A-Za-z0-9_]{3,20}$') { throw "Nom invalide : $n (3 à 20 lettres, chiffres ou _)." }
  }
  if (-not $WindowsUser) { $WindowsUser = $label }
  if (-not (Test-ValidAccountName $WindowsUser)) { throw "Nom de compte Windows impossible : $WindowsUser (3 à 20 lettres, chiffres ou _, différent du nom du PC et du tien)." }
  $password = Get-CommonPassword
  if (-not $password) { throw 'Aucun mot de passe commun pour les comptes macro : définis-le d''abord (onglet Réglages).' }
  Write-Log "=== $label : préparation (compte Windows $WindowsUser$(if ($Roblox) { ", Roblox $Roblox" } else { ', compte Roblox retenu à la première connexion' })) ==="

  if (-not (Get-WrapperState $Cfg).Healthy) {
    if (-not (Update-RdpWrapper $Cfg)) { throw 'RDP Wrapper inutilisable : la session ne pourrait pas s''ouvrir.' }
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
    Write-Log "Compte Windows $WindowsUser créé avec le mot de passe commun." OK
  } elseif (-not [BssNative]::CredExists((Get-CredTarget $account))) {
    Set-AccountCommonPassword $account
  }
  Add-ToRdpGroups $WindowsUser
  # Two Windows accounts playing one Roblox account would fight over it.
  if ($Roblox) {
    foreach ($other in @($Cfg.Accounts | Where-Object { $_.Name -ne $WindowsUser -and $_.Roblox -eq $Roblox -and $_.Enabled })) {
      $other.Enabled = $false
      Write-Log "$($other.Name) exclu : $Roblox a maintenant son propre compte Windows ($WindowsUser)." WARN
    }
  }
  Save-BssConfig $Cfg

  $account.MacroPath = New-CleanMacro $Cfg $label $SourcePath
  # Two accounts on one macro folder would share and overwrite its settings.
  foreach ($other in @($Cfg.Accounts | Where-Object { $_.Name -ne $WindowsUser -and $_.MacroPath -eq $account.MacroPath -and $_.Enabled })) {
    $other.Enabled = $false
    Write-Log "$($other.Name) exclu : sa macro $(Split-Path $account.MacroPath -Leaf) appartient maintenant à $WindowsUser." WARN
  }
  Save-BssConfig $Cfg

  # Before the first sign-in, or Windows asks its privacy questions.
  Disable-PrivacyPrompt
  if (-not (Test-SessionConnected (Get-AccountSession $account))) { [void](Open-AccountSession $Cfg $account) }
  # The first sign-in builds the Windows profile, which can take a minute.
  if (-not (Wait-Until { (Test-SessionConnected (Get-AccountSession $account)) -and (Get-UserProfilePath $WindowsUser) } 300 5)) {
    throw "La session de $WindowsUser ne s'est pas ouverte en 5 minutes."
  }
  Set-AccountPrivacyOff $account
  Set-AccountEdgeQuiet $account
  Add-MacroFirewallRules $account.MacroPath
  # Roblox's installer fails while any other Roblox runs: install in a
  # window, which pauses the running macros briefly and restarts them.
  $installed = Invoke-RobloxWindow $Cfg "installation de Roblox pour $WindowsUser" { Install-RobloxInSession $account } 300
  if (-not $installed) { throw "Roblox ne s'est pas installé dans la session de $WindowsUser." }
  # Give the installer's own registration a moment, then fill any gap.
  [void](Wait-Until { Get-RegisteredProtocolExe "Registry::HKEY_USERS\$((Get-LocalUser -Name $WindowsUser).SID.Value)\Software\Classes" 'roblox' } 60 5)
  [void](Register-RobloxProtocols $account)
  if (-not (Get-RobloxSignedIn $WindowsUser)) { Open-RobloxForSignIn $Cfg $account }

  [void](Update-LearnedRobloxNames $Cfg)
  if (-not (Get-AccountReadiness $account)) {
    if (Start-Natro $Cfg $account) { Write-Log "$label est prêt : la macro démarre." OK }
  } else {
    $who = $(if ($Roblox) { "avec $Roblox " } else { '' })
    Write-Log "$label : dans la fenêtre Bureau à distance de $WindowsUser, connecte-toi à Roblox $who(une seule fois). La macro démarrera ensuite toute seule (superviseur) ou avec « Lancer »." WARN
  }
}

function Set-AccountRobloxNames {
  param($Cfg, [string] $Name, [string] $Roblox, [string] $Role)
  $a = Get-AccountByName $Cfg $Name
  foreach ($n in @($Roblox, $Role) | Where-Object { $_ }) {
    if ($n -notmatch '^[A-Za-z0-9_]{3,20}$') { throw "Nom invalide : $n (3 à 20 lettres, chiffres ou _)." }
  }
  $a.Roblox = $Roblox
  $a.Role = $Role
  Save-BssConfig $Cfg
  Sync-NatroTask $Cfg $a
  Write-Log "$Name : compte Roblox « $(if ($Roblox) { $Roblox } else { 'retenu à la prochaine connexion' }) », rôle « $Role »." OK
}

# Applies the common password to every managed Windows account.
function Set-CommonPasswordOnAll {
  param($Cfg)
  foreach ($a in @($Cfg.Accounts | Where-Object { Get-LocalUser -Name $_.Name -ErrorAction SilentlyContinue })) {
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
    'Enabled' { if ($Value) { 'actif : lancé par Start et surveillé' } else { 'inactif : ni lancé par Start, ni surveillé' } }
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
        if (Start-Natro $Cfg $a) { Write-Log "$($a.Name) : macro relancée." OK }
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
  Disable-PrivacyPrompt
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
  Remove-Item (Join-Path $desktop 'BSS - Tout lancer.lnk') -ErrorAction SilentlyContinue
  New-Shortcut (Join-Path $desktop 'BSS - Start.lnk') "$env:SystemRoot\System32\schtasks.exe" ('/run /tn "{0}{1}"' -f $Script:Bss.TaskPath, (Get-StartAllTaskName)) "$env:SystemRoot\System32\shell32.dll,137"
  New-Shortcut (Join-Path $desktop 'BSS Manager.lnk') (Join-Path $root 'BSS-Manager.bat') '' "$env:SystemRoot\System32\shell32.dll,21"
  Write-Log 'Raccourcis « BSS - Start » et « BSS Manager » créés sur le bureau.' OK

  foreach ($a in @($Cfg.Accounts | Where-Object { Get-LocalUser -Name $_.Name -ErrorAction SilentlyContinue })) {
    Sync-NatroTask $Cfg $a
    if ($a.MacroPath) { Add-MacroFirewallRules $a.MacroPath }
    # Only reaches accounts whose session is open (their hive is loaded).
    Set-AccountEdgeQuiet $a
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
      Roblox      = $(if ($a.Roblox) { $a.Roblox } else { '(1re connexion)' })
      'Rôle'      = [string]$a.Role
      Compte      = $a.Name
      'Connecté'  = [string](Get-RobloxSignedIn $a.Name)
      Actif       = $(if ($a.Enabled) { 'oui' } else { 'non' })
      Pause       = $(if ($a.Paused) { 'oui' } else { '' })
      Adresse     = $a.Ip
      MotDePasse  = $(if ([BssNative]::CredExists((Get-CredTarget $a))) { 'enregistré' } else { 'non' })
      Macro       = $(if ($macro) { $macro.Name } elseif ($a.MacroPath) { 'INTROUVABLE' } else { '(aucune)' })
      Version     = $(if ($macro) { $macro.Version } else { '' })
      Branche     = $(if ($macro -and $macro.IsGit) { $macro.Branch } elseif ($macro) { 'ancienne' } else { '' })
      Session     = (Format-SessionState $session)
      Natro       = $(if ($session -and $a.MacroPath -and (Test-NatroRunning $a $session.Id $processes)) { 'tourne' } elseif ($session) { 'arrêté' } else { '' })
      'Réglages Roblox' = (Get-RobloxSettingsState $a)
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
