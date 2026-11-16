# Shared helpers: paths, logging, prompts and the configuration file.
#
# Ownership of files, so two processes never fight over one:
# - config.json            written by the menu and the CLI only
# - state\supervisor.json  written by the supervisor only
# - state\updating-*.txt   written by a macro update, read by the supervisor

function Initialize-Bss {
  param([string] $Root, [bool] $Unattended, [bool] $Force)

  $Script:Bss = @{
    Root       = $Root
    ConfigPath = Join-Path $Root 'config.json'
    LogDir     = Join-Path $Root 'logs'
    LogFile    = Join-Path $Root 'logs\bss-manager.log'
    StateDir   = Join-Path $Root 'state'
    StatusFile = Join-Path $Root 'state\supervisor.json'
    InboxDir   = Join-Path $Root 'inbox'
    TaskPath   = '\BSS-Manager\'
    Unattended = $Unattended
    Force      = $Force
    # Logs are capped so a supervisor running for months cannot fill the disk.
    LogMaxBytes = 2MB
  }
  foreach ($dir in $Script:Bss.LogDir, $Script:Bss.StateDir) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  }
}

# ---------------------------------------------------------------------------
# Logging and console
# ---------------------------------------------------------------------------

function Write-Log {
  param([string] $Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')] [string] $Level = 'INFO')

  $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
  try {
    $file = $Script:Bss.LogFile
    if ((Test-Path $file) -and (Get-Item $file).Length -gt $Script:Bss.LogMaxBytes) {
      Move-Item $file "$file.1" -Force
    }
    Add-Content -Path $file -Value $line -Encoding UTF8
  } catch {
    # Two processes may log at the same instant; losing one line is acceptable,
    # stopping the caller is not.
  }
  $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
  Write-Host $Message -ForegroundColor $color
}

function Test-Admin {
  $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Wait-Enter {
  if (-not $Script:Bss.Unattended) { [void](Read-Host "`nEntrée pour continuer") }
}

function Confirm-Action {
  param([string] $Question)
  if ($Script:Bss.Unattended -or $Script:Bss.Force) { return $true }
  return ((Read-Host "$Question (o/n)") -match '^(o|oui|y|yes)$')
}

function Select-Index {
  param([string[]] $Labels, [string] $Prompt)
  for ($i = 0; $i -lt $Labels.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 1), $Labels[$i]) }
  $answer = Read-Host "$Prompt (numéro, vide = annuler)"
  $n = 0
  if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $Labels.Count) { return ($n - 1) }
  return -1
}

function Test-SecureEqual {
  param([Security.SecureString] $A, [Security.SecureString] $B)
  $pa = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($A)
  $pb = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($B)
  try {
    return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pa) -ceq [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pb))
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pa)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pb)
  }
}

function Read-NewPassword {
  param([string] $For)
  while ($true) {
    $first = Read-Host "Mot de passe pour $For" -AsSecureString
    if ($first.Length -eq 0) { Write-Host 'Un mot de passe est obligatoire.' -ForegroundColor Yellow; continue }
    $second = Read-Host 'Confirme le mot de passe' -AsSecureString
    if (Test-SecureEqual $first $second) { return $first }
    Write-Host 'Les mots de passe ne correspondent pas.' -ForegroundColor Yellow
  }
}

# Writes through a temporary file so a reader never sees half a JSON document.
# https://learn.microsoft.com/dotnet/api/system.io.file.replace
function Write-FileAtomic {
  param([string] $Path, [string] $Content)
  $tmp = "$Path.tmp"
  [IO.File]::WriteAllText($tmp, $Content, (New-Object Text.UTF8Encoding $false))
  Move-Item -Path $tmp -Destination $Path -Force
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The single list of settings and their defaults. A config file written by an
# older version gains the missing keys on load.
function Get-BssDefaults {
  [ordered]@{
    SchemaVersion           = 2
    IniUrl                  = 'https://raw.githubusercontent.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini'
    RdpWrapperDir           = 'C:\Program Files\RDP Wrapper'
    MacroRoot               = 'G:\Macro bee swarm'
    DefaultRepoUrl          = 'https://github.com/Cursed-Hive-Community/NatroMacroCursed.git'
    DefaultBranch           = 'feature/rays-extensions'
    UpdateMacrosOnStart     = $true
    # Natro is set up for 1920x1080; every session gets it.
    SessionWidth            = 1920
    SessionHeight           = 1080
    DelayBetweenSessionsSec = 20
    NatroStartDelaySec      = 15
    SupervisorIntervalSec   = 60
    RestartGraceSec         = 120
    InboxEnabled            = $false
    Accounts                = @()
  }
}

function Get-BssConfig {
  $defaults = Get-BssDefaults
  if (Test-Path $Script:Bss.ConfigPath) {
    $cfg = [IO.File]::ReadAllText($Script:Bss.ConfigPath) | ConvertFrom-Json
    foreach ($key in $defaults.Keys) {
      if (-not ($cfg.PSObject.Properties.Name -contains $key)) {
        $cfg | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key]
      }
    }
    $cfg.Accounts = @($cfg.Accounts)
    # Schema 1 accounts had no Roblox name: fill it from what is signed in.
    # In memory only, so a reader (the supervisor) never writes the file.
    foreach ($a in $cfg.Accounts) {
      if (-not ($a.PSObject.Properties.Name -contains 'Roblox')) {
        $a | Add-Member -NotePropertyName Roblox -NotePropertyValue ([string](Get-RobloxSignedIn $a.Name))
      }
      if (-not ($a.PSObject.Properties.Name -contains 'Role')) { $a | Add-Member -NotePropertyName Role -NotePropertyValue '' }
    }
    return $cfg
  }

  $cfg = [pscustomobject]$defaults
  foreach ($name in Get-RdpGroupLocalUsers) {
    $cfg.Accounts = @($cfg.Accounts) + (New-AccountEntry $cfg $name)
  }
  Save-BssConfig $cfg
  Write-Log "Configuration créée ($(@($cfg.Accounts).Count) compte(s) détecté(s))." OK
  return $cfg
}

function Save-BssConfig {
  param($Cfg)
  $Cfg.Accounts = @($Cfg.Accounts)
  Write-FileAtomic $Script:Bss.ConfigPath ($Cfg | ConvertTo-Json -Depth 5)
}

# Name is the Windows account; Roblox the Roblox account it plays (empty
# until learnt at the first sign-in); Role the owner's label for it, when
# it has one (GuidingALT2 for PlayerAlt2).
function New-AccountEntry {
  param($Cfg, [string] $Name, [string] $Roblox, [string] $Role)
  if (-not $Roblox) { $Roblox = [string](Get-RobloxSignedIn $Name) }
  [pscustomobject]@{
    Name      = $Name
    Roblox    = $Roblox
    Role      = $Role
    Enabled   = $true
    Paused    = $false
    Ip        = (Get-NextLoopbackIp $Cfg)
    MacroPath = ''
  }
}

function Select-Accounts {
  param($Cfg, [string[]] $Names, [switch] $IncludeDisabled)
  $all = @($Cfg.Accounts)
  if ($Names -and $Names.Count) {
    $picked = @()
    foreach ($n in $Names) {
      $match = $all | Where-Object { $_.Name -eq $n } | Select-Object -First 1
      if ($match) { $picked += $match } else { Write-Log "Compte inconnu dans la configuration : $n" WARN }
    }
    return $picked
  }
  if ($IncludeDisabled) { return $all }
  return @($all | Where-Object { $_.Enabled })
}

function Select-OneAccount {
  param($Cfg)
  $accounts = @($Cfg.Accounts)
  if (-not $accounts.Count) { Write-Host 'Aucun compte configuré.' -ForegroundColor Yellow; return $null }
  $i = Select-Index ([string[]]($accounts | ForEach-Object { $_.Name })) 'Compte'
  if ($i -lt 0) { return $null }
  return $accounts[$i]
}
