# Windows macro accounts and their loopback Remote Desktop sessions.
#
# Each account connects to its own address in 127.0.0.0/8 (127.0.0.2, .3...).
# Credential Manager stores one password per target name, so distinct
# addresses are what let every account keep its own saved password.
# https://learn.microsoft.com/windows-server/remote/remote-desktop-services/clients/rdp-files

$Script:SidRdpUsers = 'S-1-5-32-555'
$Script:SidUsers = 'S-1-5-32-545'

# WTS_CONNECTSTATE_CLASS
# https://learn.microsoft.com/windows/win32/api/wtsapi32/ne-wtsapi32-wts_connectstate_class
$Script:WtsActive = 0
$Script:WtsConnected = 1
$Script:WtsDisconnected = 4

function Get-BssSessions { return @([BssNative]::GetSessions()) }

function Get-AccountSession {
  param($Account, $Sessions)
  if (-not $Sessions) { $Sessions = Get-BssSessions }
  return ($Sessions | Where-Object { $_.User -eq $Account.Name } | Select-Object -First 1)
}

function Test-SessionConnected {
  param($Session)
  return ($Session -and ($Session.State -eq $Script:WtsActive -or $Session.State -eq $Script:WtsConnected))
}

function Format-SessionState {
  param($Session)
  if (-not $Session) { return 'fermée' }
  switch ($Session.State) {
    0 { return 'connectée' }
    1 { return 'connectée' }
    4 { return 'DÉCONNECTÉE (écran figé)' }
    default { return "état $($Session.State)" }
  }
}

function Get-CredTarget { param($Account) return "TERMSRV/$($Account.Ip)" }

function Get-QualifiedUser { param([string] $Name) return "$env:COMPUTERNAME\$Name" }

function Get-NextLoopbackIp {
  param($Cfg)
  $used = @($Cfg.Accounts | ForEach-Object { $_.Ip })
  for ($n = 2; $n -lt 255; $n++) {
    $ip = "127.0.0.$n"
    if ($used -notcontains $ip) { return $ip }
  }
  throw "Plus d'adresse 127.0.0.x disponible."
}

function Get-UserProfilePath {
  param([string] $Name)
  try {
    $sid = (Get-LocalUser -Name $Name -ErrorAction Stop).SID.Value
    $path = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
    if ($path) { return [Environment]::ExpandEnvironmentVariables($path) }
  } catch {
    # No profile yet: the account has never signed in.
  }
  return $null
}

function Get-RdpGroupLocalUsers {
  $names = @()
  try {
    $group = Get-LocalGroup -SID $Script:SidRdpUsers
    foreach ($member in Get-LocalGroupMember -Group $group -ErrorAction Stop) {
      $name = ($member.Name -split '\\')[-1]
      if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) { $names += $name }
    }
  } catch {
    # Get-LocalGroupMember fails on orphaned SIDs; the import is best effort.
  }
  return @($names | Where-Object { $_ -ne $env:USERNAME })
}

function Add-ToRdpGroups {
  param([string] $Name)
  foreach ($sid in $Script:SidUsers, $Script:SidRdpUsers) {
    try { Add-LocalGroupMember -SID $sid -Member $Name -ErrorAction Stop } catch {
      # Already a member.
    }
  }
}

function Set-AccountCredential {
  param($Account, [Security.SecureString] $Password)
  [BssNative]::WriteCred((Get-CredTarget $Account), (Get-QualifiedUser $Account.Name), $Password)
}

# mstsc is started with /v: rather than with an .rdp file. Since 2026 Windows
# shows a blocking "unknown publisher" warning every time an unsigned .rdp
# file is opened; /v: has no file, so no warning (checked on this machine on
# 2026-11-16). The account name comes from the saved TERMSRV/<address>
# credential, which is what mstsc looks up for /v:.
# https://learn.microsoft.com/windows-server/administration/windows-commands/mstsc
function Get-MstscArguments {
  param($Cfg, $Account)
  $port = Get-RdpPort
  $address = $Account.Ip
  if ($port -ne 3389) { $address = "$($Account.Ip):$port" }
  return @("/v:$address", "/w:$([int]$Cfg.SessionWidth)", "/h:$([int]$Cfg.SessionHeight)")
}

# The mstsc client of an account, found by its /v: argument. Reading another
# elevated process's command line needs administrator rights, which every
# caller of this has.
function Get-AccountClient {
  param($Account)
  $pattern = "/v:$([regex]::Escape($Account.Ip))(\s|:|$)"
  return @(Get-CimInstance Win32_Process -Filter "Name='mstsc.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match $pattern })
}

# The SHA-256 of this PC's Remote Desktop certificate, the value mstsc saves
# when "don't ask again" is ticked on its certificate warning (checked
# against the value it saved for 127.0.0.2 on 2026-11-16).
function Get-RdpCertificateHash {
  $cert = Get-ChildItem 'Cert:\LocalMachine\Remote Desktop' -ErrorAction SilentlyContinue | Sort-Object NotAfter -Descending | Select-Object -First 1
  if (-not $cert) { return $null }
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return , $sha.ComputeHash($cert.RawData) } finally { $sha.Dispose() }
}

# mstsc /v: cannot lower the certificate check the way an .rdp file could,
# and a warning would stall an unattended start. Approving this PC's own
# certificate for the account's loopback address does what ticking the box
# does, and still warns if the certificate ever differs.
function Approve-LoopbackCertificate {
  param($Account)
  $hash = Get-RdpCertificateHash
  if (-not $hash) { Write-Log 'Certificat Bureau à distance introuvable : Windows demandera de le confirmer.' WARN; return }
  $key = "HKCU:\Software\Microsoft\Terminal Server Client\Servers\$($Account.Ip)"
  if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
  New-ItemProperty -Path $key -Name CertHash -Value ([byte[]]$hash) -PropertyType Binary -Force | Out-Null
  New-ItemProperty -Path $key -Name UsernameHint -Value (Get-QualifiedUser $Account.Name) -PropertyType String -Force | Out-Null
}

# Opens a new session, or reattaches a disconnected one: mstsc does either.
# Never a second client for the same account: one waiting on a password or
# still connecting is left alone, so windows cannot pile up.
function Open-AccountSession {
  param($Cfg, $Account)
  if (Get-AccountClient $Account) {
    Write-Log "$($Account.Name) : une fenêtre de connexion est déjà ouverte, pas de deuxième." WARN
    return $false
  }
  if (-not [BssNative]::CredExists((Get-CredTarget $Account))) {
    Write-Log "$($Account.Name) : aucun mot de passe enregistré, Windows va le demander (coche « Mémoriser »)." WARN
  }
  Approve-LoopbackCertificate $Account
  Start-Process -FilePath "$env:SystemRoot\System32\mstsc.exe" -ArgumentList (Get-MstscArguments $Cfg $Account)
  return $true
}

# The Roblox account signed in for a Windows account. The Roblox app writes
# it to appStorage.json in the profile each time it runs; UserId -1 means
# signed out. This is what ties a Windows account to a Roblox account, since
# Natro's own settings do not name the account they play.
function Get-RobloxSignedIn {
  param([string] $WindowsUser)
  $profilePath = Get-UserProfilePath $WindowsUser
  if (-not $profilePath) { return $null }
  $file = Join-Path $profilePath 'AppData\Local\Roblox\LocalStorage\appStorage.json'
  # A fresh profile is private: without administrator rights the file
  # cannot even be tested, which must read as "unknown", not stop the caller.
  if (-not (Test-Path $file -ErrorAction SilentlyContinue)) { return $null }
  try {
    $j = [IO.File]::ReadAllText($file) | ConvertFrom-Json
    if ([long]$j.UserId -gt 0 -and $j.Username) { return [string]$j.Username }
  } catch {
    # Roblox may be writing it; the next refresh reads it again.
  }
  return $null
}

function Test-RobloxInstalled {
  param([string] $WindowsUser)
  $profilePath = Get-UserProfilePath $WindowsUser
  if (-not $profilePath) { return $false }
  # Get-ChildItem throws on a private profile despite SilentlyContinue when
  # the caller runs with ErrorActionPreference Stop: unreadable is "unknown".
  try {
    return [bool](Get-ChildItem (Join-Path $profilePath 'AppData\Local\Roblox\Versions') -Filter 'RobloxPlayerBeta.exe' -Recurse -ErrorAction Stop | Select-Object -First 1)
  } catch { return $false }
}

# What an account still lacks to run unattended; empty when ready. Read live
# every time (a state, not a stored stage), so signing in to Roblox is enough
# to make an account ready, whoever is watching.
function Get-AccountReadiness {
  param($Account)
  if (-not (Get-LocalUser -Name $Account.Name -ErrorAction SilentlyContinue)) { return 'compte Windows introuvable' }
  if (-not [BssNative]::CredExists((Get-CredTarget $Account))) { return 'mot de passe non enregistré' }
  if (-not $Account.MacroPath) { return 'aucune macro associée' }
  # A macro folder named after another account holds that account's settings
  # (fields, private server, webhook): never run it for this one. The owner
  # names folders after the Roblox account or after a role (GuidingALT2 is
  # played by PlayerAlt2), so any of the account's names is accepted.
  $macroOwner = Get-RobloxNameGuess (Split-Path $Account.MacroPath -Leaf)
  $names = @($Account.Roblox, $Account.Role, $Account.Name) | Where-Object { $_ }
  if ($macroOwner -and $names -notcontains $macroOwner) { return "la macro est celle de $macroOwner, pas de $($names[0])" }
  $signedIn = Get-RobloxSignedIn $Account.Name
  $installed = $true
  if (-not $signedIn) { $installed = Test-RobloxInstalled $Account.Name }
  return (Get-RobloxSignInProblem $Account.Roblox $signedIn $installed)
}

# The sign-in rule on its own, testable without a session. An empty
# expected name accepts whoever signs in first; Update-LearnedRobloxNames
# then records it and any later different account is refused.
function Get-RobloxSignInProblem {
  param([string] $Expected, [string] $SignedIn, [bool] $Installed)
  if (-not $SignedIn) {
    if (-not $Installed) { return 'Roblox pas installé dans la session' }
    if ($Expected) { return "connecte-toi à Roblox avec $Expected (bouton « Ouvrir Roblox »)" }
    return 'connecte-toi à Roblox (bouton « Ouvrir Roblox »)'
  }
  if ($Expected -and $SignedIn -ne $Expected) { return "mauvais compte Roblox ($SignedIn au lieu de $Expected)" }
  return ''
}

# Records the Roblox account of every account that had none, from what is
# signed in. Only config writers (window, command line) call it; the
# supervisor reads, and the rule above already accepts the first sign-in.
function Update-LearnedRobloxNames {
  param($Cfg)
  $changed = $false
  foreach ($a in @($Cfg.Accounts | Where-Object { -not $_.Roblox })) {
    $signedIn = Get-RobloxSignedIn $a.Name
    if ($signedIn) {
      $a.Roblox = $signedIn
      $changed = $true
      Write-Log "$($a.Name) : compte Roblox retenu, $signedIn." OK
    }
  }
  if ($changed) { Save-BssConfig $Cfg }
  return $changed
}

# One password, chosen by the owner, for every macro account: Windows
# sometimes asks for it, so it must be one they know. Kept in Credential
# Manager like the per-session copies, never in a file.
$Script:CommonPasswordTarget = 'BSS-Manager/MacroAccounts'

function Get-CommonPassword { return [BssNative]::ReadCredSecure($Script:CommonPasswordTarget) }

function Test-CommonPassword { return [BssNative]::CredExists($Script:CommonPasswordTarget) }

function Set-CommonPassword {
  param([Security.SecureString] $Password)
  if (-not $Password -or $Password.Length -eq 0) { throw 'Mot de passe vide.' }
  [BssNative]::WriteCred($Script:CommonPasswordTarget, 'BSS Manager', $Password)
  Write-Log 'Mot de passe commun des comptes macro enregistré.' OK
}

# Gives one Windows account the common password, in Windows and in its
# saved session credential.
function Set-AccountCommonPassword {
  param($Account)
  $password = Get-CommonPassword
  if (-not $password) { throw 'Aucun mot de passe commun : définis-le d''abord (onglet Réglages).' }
  Set-LocalUser -Name $Account.Name -Password $password
  Set-AccountCredential $Account $password
  Write-Log "$($Account.Name) : mot de passe commun appliqué." OK
}

# Windows caps a local account description at 48 characters; with a
# 20-character Roblox name this stays at 33.
# https://learn.microsoft.com/powershell/module/microsoft.powershell.localaccounts/new-localuser
function Get-AccountDescription {
  param([string] $Roblox)
  return "BSS Manager: $Roblox"
}

# ---------------------------------------------------------------------------
# Privacy: no questions, every per-account choice off
# ---------------------------------------------------------------------------
# DisablePrivacyExperience skips the "choose privacy settings" screen at a
# new account's first sign-in; it changes no setting of existing accounts.
# https://learn.microsoft.com/windows/client-management/mdm/policy-csp-privacy#disableprivacyexperience
function Disable-PrivacyPrompt {
  $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'
  if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
  New-ItemProperty -Path $key -Name DisablePrivacyExperience -Value 1 -PropertyType DWord -Force | Out-Null
}

# The per-account answers of that screen, set to "no" in the account's own
# registry hive (loaded while its session is open). Device-wide choices
# (diagnostic data, Find my device, the location service itself) stay as
# the owner set them for the PC.
function Set-AccountPrivacyOff {
  param($Account)
  $sid = (Get-LocalUser -Name $Account.Name).SID.Value
  $hive = "Registry::HKEY_USERS\$sid"
  if (-not (Test-Path $hive)) { Write-Log "$($Account.Name) : session pas chargée, confidentialité non réglée." WARN; return }
  $values = @(
    @('Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo', 'Enabled', 0, 'DWord'),
    @('Software\Microsoft\Windows\CurrentVersion\Privacy', 'TailoredExperiencesWithDiagnosticDataEnabled', 0, 'DWord'),
    @('Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location', 'Value', 'Deny', 'String'),
    @('Software\Microsoft\InputPersonalization', 'RestrictImplicitInkCollection', 1, 'DWord'),
    @('Software\Microsoft\InputPersonalization', 'RestrictImplicitTextCollection', 1, 'DWord'),
    @('Software\Microsoft\InputPersonalization\TrainedDataStore', 'HarvestContacts', 0, 'DWord'),
    @('Software\Microsoft\Personalization\Settings', 'AcceptedPrivacyPolicy', 0, 'DWord'),
    @('Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy', 'HasAccepted', 0, 'DWord')
  )
  foreach ($v in $values) {
    $key = Join-Path $hive $v[0]
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name $v[1] -Value $v[2] -PropertyType $v[3] -Force | Out-Null
  }
  Write-Log "$($Account.Name) : confidentialité réglée sur non (publicité, localisation, saisie, reconnaissance vocale)." OK
}

function Test-ValidAccountName {
  param([string] $Name)
  # Roblox names are 3-20 letters, digits or underscores, which Windows
  # accepts as account names, except the computer's own name.
  return ($Name -match '^[A-Za-z0-9_]{3,20}$' -and $Name -ne $env:COMPUTERNAME -and $Name -ne $env:USERNAME)
}

function Close-AccountSession {
  param($Account)
  $closed = $false
  foreach ($s in @(Get-BssSessions | Where-Object { $_.User -eq $Account.Name })) {
    if ([BssNative]::Logoff($s.Id)) { $closed = $true }
    else { Write-Log "$($Account.Name) : impossible de fermer la session $($s.Id)." ERROR }
  }
  return $closed
}
