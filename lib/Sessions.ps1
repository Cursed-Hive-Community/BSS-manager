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
  if (-not $Session) { return 'closed' }
  switch ($Session.State) {
    0 { return 'connected' }
    1 { return 'connected' }
    4 { return 'DISCONNECTED (frozen screen)' }
    default { return "state $($Session.State)" }
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
  if (-not $hash) { Write-Log 'Remote Desktop certificate not found: Windows will ask to confirm it.' WARN; return }
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
  # The owner's session is opened by the owner (or by automatic sign-in),
  # never by a Remote Desktop connection to oneself.
  if ($Account.Local) {
    Write-Log "$($Account.Name) : local account, it runs in your session as soon as it is open." WARN
    return $false
  }
  if (Get-AccountClient $Account) {
    Write-Log "$($Account.Name) : a connection window is already open, no second one." WARN
    return $false
  }
  if (-not [BssNative]::CredExists((Get-CredTarget $Account))) {
    Write-Log "$($Account.Name) : no saved password, Windows will ask for it (tick 'Remember me')." WARN
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
    $j = (Read-SharedText $file) | ConvertFrom-Json
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
  if (-not (Get-LocalUser -Name $Account.Name -ErrorAction SilentlyContinue)) { return 'Windows account not found' }
  # The local account runs in the owner's own session: no password to open it.
  if (-not $Account.Local -and -not [BssNative]::CredExists((Get-CredTarget $Account))) { return 'password not saved' }
  if (-not $Account.MacroPath) { return 'no macro assigned' }
  # A macro folder named after another account holds that account's settings
  # (fields, private server, webhook): never run it for this one. The owner
  # names folders after the Roblox account or after a role (GuidingALT2 is
  # played by PlayerAlt2), so any of the account's names is accepted.
  $macroOwner = Get-RobloxNameGuess (Split-Path $Account.MacroPath -Leaf)
  $names = @($Account.Roblox, $Account.Role, $Account.Name) | Where-Object { $_ }
  if ($macroOwner -and $names -notcontains $macroOwner) { return "the macro belongs to $macroOwner, not $($names[0])" }
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
    if (-not $Installed) { return 'Roblox not installed in the session' }
    if ($Expected) { return "sign in to Roblox as $Expected ('Open Roblox' button)" }
    return 'sign in to Roblox (''Open Roblox'' button)'
  }
  if ($Expected -and $SignedIn -ne $Expected) { return "wrong Roblox account ($SignedIn instead of $Expected)" }
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
      Write-Log "$($a.Name) : Roblox account learnt, $signedIn." OK
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
  Write-Log 'Common password of the macro accounts saved.' OK
}

# Gives one Windows account the common password, in Windows and in its
# saved session credential.
function Set-AccountCommonPassword {
  param($Account)
  # The owner's own password is never touched (the local account is theirs).
  if ($Account.Local -or $Account.Name -eq $env:USERNAME) { throw "$($Account.Name) is your own Windows account: its password is never changed." }
  $password = Get-CommonPassword
  if (-not $password) { throw 'No common password: set it first (Settings tab).' }
  Set-LocalUser -Name $Account.Name -Password $password
  Set-AccountCredential $Account $password
  Write-Log "$($Account.Name) : common password applied." OK
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
# Writes values into an account's own registry hive, which is loaded while
# its session is open. Returns $false when it is not loaded.
function Set-AccountHiveValues {
  param($Account, [object[]] $Values)
  $sid = (Get-LocalUser -Name $Account.Name).SID.Value
  $hive = "Registry::HKEY_USERS\$sid"
  if (-not (Test-Path $hive)) { return $false }
  foreach ($v in $Values) {
    $key = Join-Path $hive $v[0]
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name $v[1] -Value $v[2] -PropertyType $v[3] -Force | Out-Null
  }
  return $true
}

# Natro falls back to the browser once every five reconnect attempts, and a
# fresh Edge stops on its first-run questions, then asks before opening
# Roblox. These are Edge policies written for the macro account only (user
# policies in its own hive), so the owner's Edge is untouched. Roblox may be
# opened from roblox.com without asking, and from nowhere else.
# https://learn.microsoft.com/deployedge/microsoft-edge-policies
$Script:RobloxAutoLaunch = '[{"allowed_origins":["https://www.roblox.com","https://roblox.com"],"protocol":"roblox-player"},{"allowed_origins":["https://www.roblox.com","https://roblox.com"],"protocol":"roblox"}]'

function Set-AccountEdgeQuiet {
  param($Account)
  $edge = 'Software\Policies\Microsoft\Edge'
  $values = @(
    @($edge, 'HideFirstRunExperience', 1, 'DWord'),
    @($edge, 'DefaultBrowserSettingEnabled', 0, 'DWord'),
    @($edge, 'BrowserSignin', 0, 'DWord'),
    @($edge, 'SyncDisabled', 1, 'DWord'),
    @($edge, 'ShowRecommendationsEnabled', 0, 'DWord'),
    @($edge, 'PersonalizationReportingEnabled', 0, 'DWord'),
    @($edge, 'AutoLaunchProtocolsFromOrigins', $Script:RobloxAutoLaunch, 'String')
  )
  if (Set-AccountHiveValues $Account $values) { Write-Log "$($Account.Name) : Edge without questions, and Roblox opens from roblox.com without confirmation." OK }
  else { Write-Log "$($Account.Name) : session closed, Edge will be set at its next opening (Open Roblox or Install / repair)." WARN }
}

function Set-AccountPrivacyOff {
  param($Account)
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
  if (Set-AccountHiveValues $Account $values) { Write-Log "$($Account.Name) : privacy set to off (advertising, location, typing, speech recognition)." OK }
  else { Write-Log "$($Account.Name) : session not loaded, privacy not set." WARN }
}

# ---------------------------------------------------------------------------
# Roblox's own settings in each macro account
# ---------------------------------------------------------------------------
# What Natro checks in GlobalBasicSettings (nm_MsgBoxIncorrectRobloxSettings,
# "Web Version", the installed player), plus the owner's choices of
# 2026-11-16: graphics manual and lowest, fullscreen, no haptics. Graphics
# levels are stored as 2 x level + 1 (level 10 is 21), so the lowest manual
# level is 3; 0 means automatic, which Natro refuses.
$Script:RobloxSettings = @(
  @('int', 'GraphicsQualityLevel', '3'),
  @('token', 'SavedQualityLevel', '1'),
  @('token', 'PreferredTextSize', '1'),
  @('token', 'ControlMode', '1'),                 # Shift Lock on
  @('bool', 'CameraYInverted', 'false'),
  @('bool', 'OnScreenProfilerEnabled', 'false'),
  @('token', 'ComputerCameraMovementMode', '1'),  # Classic
  @('token', 'ComputerMovementMode', '1'),        # keyboard and mouse
  @('bool', 'Fullscreen', 'true'),
  @('float', 'HapticStrength', '0')
)

function Get-RobloxSettingsFile {
  param([string] $WindowsUser)
  $profilePath = Get-UserProfilePath $WindowsUser
  if (-not $profilePath) { return $null }
  try {
    return (Get-ChildItem (Join-Path $profilePath 'AppData\Local\Roblox') -Filter 'GlobalBasicSettings_*.xml' -ErrorAction Stop |
      Where-Object { $_.Name -notmatch 'Studio' } | Sort-Object Name -Descending | Select-Object -First 1)
  } catch { return $null }
}

function Get-RobloxSettingsProperties {
  param([xml] $Doc)
  $props = $Doc.SelectSingleNode("//Item[@class='UserGameSettings']/Properties")
  if (-not $props) { throw 'Unexpected Roblox settings file: no UserGameSettings.' }
  return $props
}

# Names of the settings that differ from (or are missing in) what is wanted.
function Get-RobloxSettingsDifferences {
  param([xml] $Doc)
  $props = Get-RobloxSettingsProperties $Doc
  foreach ($s in $Script:RobloxSettings) {
    $node = $props.SelectSingleNode("*[@name='$($s[1])']")
    if (-not $node -or $node.InnerText -ne $s[2]) { $s[1] }
  }
}

# Sets the wanted values, adding a property Roblox has not written yet, and
# leaves every other setting as it is. Returns how many changed.
function Set-RobloxSettingsXml {
  param([xml] $Doc)
  $props = Get-RobloxSettingsProperties $Doc
  $changed = 0
  foreach ($s in $Script:RobloxSettings) {
    $node = $props.SelectSingleNode("*[@name='$($s[1])']")
    if (-not $node) {
      $node = $Doc.CreateElement($s[0])
      [void]$node.SetAttribute('name', $s[1])
      [void]$props.AppendChild($node)
    }
    if ($node.InnerText -ne $s[2]) { $node.InnerText = $s[2]; $changed++ }
  }
  return $changed
}

# Roblox keeps the file's original layout: no BOM, no XML declaration.
function Save-RobloxSettingsXml {
  param([xml] $Doc, [string] $Path)
  $settings = New-Object Xml.XmlWriterSettings
  $settings.Encoding = New-Object Text.UTF8Encoding $false
  $settings.OmitXmlDeclaration = $true
  $writer = [Xml.XmlWriter]::Create($Path, $settings)
  try { $Doc.Save($writer) } finally { $writer.Dispose() }
}

function Get-RobloxProcessesInSession {
  param($Account)
  $session = Get-AccountSession $Account
  if (-not $session) { return @() }
  return @(Get-Process RobloxPlayerBeta -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session.Id })
}

# 'compliant', 'to apply (n)', or why it cannot be read.
function Get-RobloxSettingsState {
  param($Account)
  $file = Get-RobloxSettingsFile $Account.Name
  if (-not $file) { return 'Roblox never started' }
  try {
    $doc = New-Object Xml.XmlDocument
    $doc.Load($file.FullName)
    $diff = @(Get-RobloxSettingsDifferences $doc)
    if ($diff.Count) { return "to apply ($($diff.Count))" }
    return 'compliant'
  } catch { return 'unreadable' }
}

# Roblox rewrites this file from memory when it exits, so it is written
# while Roblox is closed. With -CloseRoblox, a running Roblox in the session
# is killed first: a killed Roblox saves nothing, and Natro reopens it with
# the new settings. Returns $true when the file holds the wanted values.
function Set-AccountRobloxSettings {
  param($Account, [switch] $CloseRoblox)
  $file = Get-RobloxSettingsFile $Account.Name
  if (-not $file) { Write-Log "$($Account.Name) : Roblox was never started, settings applied later." WARN; return $false }
  $doc = New-Object Xml.XmlDocument
  $doc.PreserveWhitespace = $true
  $doc.Load($file.FullName)
  if (-not @(Get-RobloxSettingsDifferences $doc).Count) { return $true }
  $running = Get-RobloxProcessesInSession $Account
  if ($running.Count) {
    if (-not $CloseRoblox) { Write-Log "$($Account.Name) : Roblox is open, settings applied when it next closes." WARN; return $false }
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $doc.Load($file.FullName)
  }
  $backup = "$($file.FullName).bak"
  if (-not (Test-Path $backup)) { Copy-Item $file.FullName $backup }
  $changed = Set-RobloxSettingsXml $doc
  Save-RobloxSettingsXml $doc $file.FullName
  Write-Log "$($Account.Name) : $changed Roblox setting(s) applied (lowest graphics, fullscreen, no haptics, Natro settings)." OK
  return $true
}

# ---------------------------------------------------------------------------
# roblox:// links
# ---------------------------------------------------------------------------
# Natro joins its server through roblox:// links. Without the per-user
# protocol keys Windows answers "get an app to open this 'roblox' link",
# which happened to PlayerAlt3 after a reinstall (2026-11-16) although the app
# was signed in. The keys are the ones the Roblox installer writes in the
# owner's account, value for value.

function Get-RobloxPlayerExe {
  param([string] $WindowsUser)
  $profilePath = Get-UserProfilePath $WindowsUser
  if (-not $profilePath) { return $null }
  try {
    return (Get-ChildItem (Join-Path $profilePath 'AppData\Local\Roblox\Versions') -Filter 'RobloxPlayerBeta.exe' -Recurse -ErrorAction Stop |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1)
  } catch { return $null }
}

# Registry values for one protocol, relative to Software\Classes\<protocol>.
function Get-RobloxProtocolValues {
  param([string] $Protocol, [string] $Exe)
  $version = Split-Path (Split-Path $Exe -Parent) -Leaf
  return @(
    @($Protocol, '(default)', 'URL: Roblox Protocol'),
    @($Protocol, 'URL Protocol', ''),
    @("$Protocol\DefaultIcon", '(default)', $Exe),
    @("$Protocol\shell\open\command", '(default)', ('"{0}" %1' -f $Exe)),
    @("$Protocol\shell\open\command", 'version', $version)
  )
}

# The exe a registered protocol opens, or $null.
function Get-RegisteredProtocolExe {
  param([string] $ClassesRoot, [string] $Protocol)
  $command = (Get-ItemProperty (Join-Path $ClassesRoot "$Protocol\shell\open\command") -ErrorAction SilentlyContinue).'(default)'
  if ($command -match '^"([^"]+)"') { return $Matches[1] }
  return $null
}

# Writes the keys only when missing or pointing at a Roblox that no longer
# exists; a working registration made by Roblox itself is left alone. Needs
# the account's session open (its hive loaded). Returns $true when both
# protocols point at an existing Roblox.
function Register-RobloxProtocols {
  param($Account)
  $exe = Get-RobloxPlayerExe $Account.Name
  if (-not $exe) { return $false }
  $sid = (Get-LocalUser -Name $Account.Name).SID.Value
  $classes = "Registry::HKEY_USERS\$sid\Software\Classes"
  if (-not (Test-Path "Registry::HKEY_USERS\$sid")) { return $false }
  $written = @()
  foreach ($protocol in 'roblox', 'roblox-player') {
    $current = Get-RegisteredProtocolExe $classes $protocol
    if ($current -and (Test-Path $current)) { continue }
    foreach ($v in Get-RobloxProtocolValues $protocol $exe.FullName) {
      $key = Join-Path $classes $v[0]
      if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
      if ($v[1] -eq '(default)') { Set-Item -Path $key -Value $v[2] }
      else { New-ItemProperty -Path $key -Name $v[1] -Value $v[2] -PropertyType String -Force | Out-Null }
    }
    $written += $protocol
  }
  if ($written.Count) { Write-Log "$($Account.Name) : $($written -join ' and ') links registered for Roblox (they were missing)." WARN }
  return $true
}

function Test-ValidAccountName {
  param([string] $Name)
  # Roblox names are 3-20 letters, digits or underscores, which Windows
  # accepts as account names, except the computer's own name.
  return ($Name -match '^[A-Za-z0-9_]{3,20}$' -and $Name -ne $env:COMPUTERNAME -and $Name -ne $env:USERNAME)
}

function Close-AccountSession {
  param($Account)
  # Never log the owner off: for the local account, stopping means stopping
  # its Natro and its Roblox, and the session stays as it is.
  if ($Account.Local -or $Account.Name -eq $env:USERNAME) {
    if ($Account.MacroPath) { Stop-NatroProcesses $Account.MacroPath }
    Get-RobloxProcessesInSession $Account | Stop-Process -Force -ErrorAction SilentlyContinue
    return $true
  }
  $closed = $false
  foreach ($s in @(Get-BssSessions | Where-Object { $_.User -eq $Account.Name })) {
    if ([BssNative]::Logoff($s.Id)) { $closed = $true }
    else { Write-Log "$($Account.Name) : cannot close session $($s.Id)." ERROR }
  }
  return $closed
}
