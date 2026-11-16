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

function Write-RdpFile {
  param($Cfg, $Account, [int] $Index)
  if (-not (Test-Path $Script:Bss.RdpDir)) { New-Item -ItemType Directory -Path $Script:Bss.RdpDir | Out-Null }
  $w = [int]$Cfg.SessionWidth
  $h = [int]$Cfg.SessionHeight
  $x = 20 + 40 * $Index
  $y = 20 + 40 * $Index
  $port = Get-RdpPort
  $address = $Account.Ip
  if ($port -ne 3389) { $address = "$($Account.Ip):$port" }
  $lines = @(
    "full address:s:$address",
    "username:s:$(Get-QualifiedUser $Account.Name)",
    'prompt for credentials:i:0',
    'promptcredentialonce:i:0',
    # The loopback certificate is self-signed; checking it would prompt.
    'authentication level:i:0',
    'enablecredsspsupport:i:1',
    'negotiate security layer:i:1',
    'screen mode id:i:1',
    "desktopwidth:i:$w",
    "desktopheight:i:$h",
    'session bpp:i:32',
    'smart sizing:i:1',
    'dynamic resolution:i:0',
    "winposstr:s:0,1,$x,$y,$($x + $w + 16),$($y + $h + 39)",
    'audiomode:i:2',
    'audiocapturemode:i:0',
    'redirectclipboard:i:1',
    'redirectprinters:i:0',
    'redirectsmartcards:i:0',
    'redirectcomports:i:0',
    'drivestoredirect:s:',
    'keyboardhook:i:0',
    'autoreconnection enabled:i:1',
    'autoreconnect max retries:i:100',
    'connection type:i:7',
    'networkautodetect:i:1',
    'bandwidthautodetect:i:1',
    'displayconnectionbar:i:1',
    'disable wallpaper:i:1',
    'allow font smoothing:i:0',
    'disable full window drag:i:1',
    'disable menu anims:i:1',
    'bitmapcachepersistenable:i:1'
  )
  $file = Join-Path $Script:Bss.RdpDir "$($Account.Name).rdp"
  Set-Content -Path $file -Value $lines -Encoding Unicode
  return $file
}

# Opens a new session, or reattaches a disconnected one: mstsc does either.
function Open-AccountSession {
  param($Cfg, $Account, [int] $Index)
  if (-not [BssNative]::CredExists((Get-CredTarget $Account))) {
    Write-Log "$($Account.Name) : aucun mot de passe enregistré, Windows va le demander (coche « Mémoriser »)." WARN
  }
  $rdp = Write-RdpFile $Cfg $Account $Index
  Start-Process -FilePath "$env:SystemRoot\System32\mstsc.exe" -ArgumentList ('"{0}"' -f $rdp)
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
