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
  if (-not (Test-Path $file)) { return $null }
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
  return [bool](Get-ChildItem (Join-Path $profilePath 'AppData\Local\Roblox\Versions') -Filter 'RobloxPlayerBeta.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
}

# What an account still lacks to run unattended; empty when ready. Read live
# every time (a state, not a stored stage), so signing in to Roblox is enough
# to make an account ready, whoever is watching.
function Get-AccountReadiness {
  param($Account)
  if (-not (Get-LocalUser -Name $Account.Name -ErrorAction SilentlyContinue)) { return 'compte Windows introuvable' }
  if (-not [BssNative]::CredExists((Get-CredTarget $Account))) { return 'mot de passe non enregistré' }
  if (-not $Account.MacroPath) { return 'aucune macro associée' }
  if (-not $Account.Roblox) { return 'compte Roblox non renseigné' }
  # A macro folder named after another account holds that account's settings
  # (fields, private server, webhook): never run it for this one.
  $macroOwner = Get-RobloxNameGuess (Split-Path $Account.MacroPath -Leaf)
  if ($macroOwner -and $macroOwner -ne $Account.Roblox) { return "la macro est celle de $macroOwner, pas de $($Account.Roblox)" }
  $signedIn = Get-RobloxSignedIn $Account.Name
  if (-not $signedIn) {
    if (-not (Test-RobloxInstalled $Account.Name)) { return 'Roblox pas installé dans la session' }
    return "connecte-toi à Roblox avec $($Account.Roblox) dans la session"
  }
  if ($signedIn -ne $Account.Roblox) { return "mauvais compte Roblox ($signedIn au lieu de $($Account.Roblox))" }
  return ''
}

# A long random password, built straight into a SecureString, with every
# character class so Windows complexity rules always accept it.
# https://learn.microsoft.com/dotnet/api/system.security.cryptography.randomnumbergenerator
function New-RandomPassword {
  $classes = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%+=?@')
  $all = -join $classes
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  $bytes = New-Object byte[] 28
  $rng.GetBytes($bytes)
  $secure = New-Object Security.SecureString
  for ($i = 0; $i -lt 24; $i++) { $secure.AppendChar($all[$bytes[$i] % $all.Length]) }
  for ($i = 0; $i -lt 4; $i++) { $secure.AppendChar($classes[$i][$bytes[24 + $i] % $classes[$i].Length]) }
  $rng.Dispose()
  $secure.MakeReadOnly()
  return $secure
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
