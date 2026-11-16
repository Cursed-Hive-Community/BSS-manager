# RDP Wrapper keeps working only while rdpwrap.ini has a section for the exact
# build of termsrv.dll, and Windows Update replaces that file every few weeks.
# This module compares the two, fetches a newer ini when needed and restarts
# the Remote Desktop service.
# https://github.com/stascorp/rdpwrap
# https://github.com/sebaxakerhtc/rdpwrap.ini

$Script:TermServiceKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters'
$Script:TerminalServerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'

function Get-TermsrvVersion {
  $v = (Get-Item "$env:SystemRoot\System32\termsrv.dll").VersionInfo
  return ('{0}.{1}.{2}.{3}' -f $v.FileMajorPart, $v.FileMinorPart, $v.FileBuildPart, $v.FilePrivatePart)
}

function Get-IniUpdated {
  param([string] $Path)
  if (-not (Test-Path $Path)) { return '(absent)' }
  $m = [regex]::Match([IO.File]::ReadAllText($Path), '(?m)^Updated=(.+?)\s*$')
  if ($m.Success) { return $m.Groups[1].Value }
  return '(inconnu)'
}

function Test-IniSupports {
  param([string] $Path, [string] $Version)
  if (-not (Test-Path $Path)) { return $false }
  return [IO.File]::ReadAllText($Path).Contains("[$Version]")
}

# rdpwrap.dll splits its ini on CRLF only. An ini with bare LF line endings
# (the upstream file switched to LF on 2026-10-30) loads without any error
# but yields no section, so nothing is patched and Windows keeps its single
# session limit ("all connections are in use").
function Test-IniCrlf {
  param([string] $Path)
  if (-not (Test-Path $Path)) { return $false }
  return -not ([IO.File]::ReadAllText($Path) -match "(?<!`r)`n")
}

function Copy-IniAsCrlf {
  param([string] $Source, [string] $Destination)
  $text = [IO.File]::ReadAllText($Source) -replace "`r`n", "`n" -replace "`n", "`r`n"
  [IO.File]::WriteAllText($Destination, $text, (New-Object Text.UTF8Encoding $false))
}

function Get-RdpPort {
  $key = "$Script:TerminalServerKey\WinStations\RDP-Tcp"
  $port = (Get-ItemProperty $key -ErrorAction SilentlyContinue).PortNumber
  if ($port) { return [int]$port }
  return 3389
}

function Get-WrapperState {
  param($Cfg)
  $ini = Join-Path $Cfg.RdpWrapperDir 'rdpwrap.ini'
  $dll = Join-Path $Cfg.RdpWrapperDir 'rdpwrap.dll'
  $version = Get-TermsrvVersion
  $serviceDll = [string](Get-ItemProperty $Script:TermServiceKey -ErrorAction SilentlyContinue).ServiceDll
  $port = Get-RdpPort
  $state = [pscustomobject]@{
    TermsrvVersion = $version
    IniUpdated     = (Get-IniUpdated $ini)
    IniSupports    = (Test-IniSupports $ini $version)
    IniCrlf        = (Test-IniCrlf $ini)
    DllExists      = (Test-Path $dll)
    ServiceDllOk   = ([Environment]::ExpandEnvironmentVariables($serviceDll) -eq $dll)
    Service        = (Get-Service TermService).Status.ToString()
    Port           = $port
    Listening      = [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    Healthy        = $false
  }
  $state.Healthy = $state.IniSupports -and $state.IniCrlf -and $state.DllExists -and $state.ServiceDllOk -and $state.Listening
  return $state
}

function Get-RemoteIni {
  param($Cfg)
  # Windows PowerShell 5.1 does not offer TLS 1.2 by default on every build.
  # https://learn.microsoft.com/dotnet/framework/network-programming/tls
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $tmpDir = Join-Path $env:TEMP 'BSS-Manager'
  New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
  $tmp = Join-Path $tmpDir 'rdpwrap.ini'
  $tries = 3
  for ($i = 1; $i -le $tries; $i++) {
    try {
      # The query string defeats the CDN cache, which served a stale file once.
      $url = '{0}?nocache={1}' -f $Cfg.IniUrl, [DateTime]::UtcNow.Ticks
      Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp -TimeoutSec 60 -Headers @{ 'Cache-Control' = 'no-cache' }
      $text = [IO.File]::ReadAllText($tmp)
      if ($text -notmatch '(?m)^\[Main\]' -or $text.Length -lt 50000) { throw 'fichier téléchargé invalide' }
      return $tmp
    } catch {
      Write-Log "Téléchargement de rdpwrap.ini échoué (essai $i/$tries) : $($_.Exception.Message)" WARN
      if ($i -lt $tries) { Start-Sleep -Seconds 10 }
    }
  }
  throw "Impossible de télécharger rdpwrap.ini depuis $($Cfg.IniUrl)"
}

function Restart-RdpService {
  Write-Log 'Redémarrage du service Bureau à distance (TermService)...'
  Restart-Service -Name TermService -Force
  Start-Sleep -Seconds 2
  $um = Get-Service UmRdpService -ErrorAction SilentlyContinue
  if ($um -and $um.Status -ne 'Running') { Start-Service UmRdpService }
  $port = Get-RdpPort
  for ($i = 0; $i -lt 15; $i++) {
    if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
      Write-Log "Service redémarré, le Bureau à distance écoute sur le port $port." OK
      return
    }
    Start-Sleep -Seconds 1
  }
  Write-Log "Le service tourne mais n'écoute pas sur le port $port." ERROR
}

# Returns $true when RDP Wrapper is (now) usable, $false when the online ini
# does not know this termsrv.dll build yet.
function Update-RdpWrapper {
  param($Cfg)
  $dir = $Cfg.RdpWrapperDir
  $ini = Join-Path $dir 'rdpwrap.ini'
  $dll = Join-Path $dir 'rdpwrap.dll'
  if (-not (Test-Path $dll)) {
    throw "rdpwrap.dll introuvable dans $dir : RDP Wrapper n'est pas installé, ou l'antivirus l'a supprimé."
  }
  $version = Get-TermsrvVersion
  Write-Log "termsrv.dll $version, rdpwrap.ini local Updated=$(Get-IniUpdated $ini)"
  $changed = $false

  if ($Script:Bss.Force -or -not (Test-IniSupports $ini $version)) {
    # Only a missing section justifies a download; a wrong line ending is
    # repaired below without touching the network.
    Write-Log 'Téléchargement du dernier rdpwrap.ini...'
    $tmp = Get-RemoteIni $Cfg
    if (-not (Test-IniSupports $tmp $version)) {
      Write-Log "Le rdpwrap.ini en ligne (Updated=$(Get-IniUpdated $tmp)) ne gère pas encore termsrv.dll $version. Réessaie dans quelques jours." ERROR
      return $false
    }
    $crlf = "$tmp.crlf"
    Copy-IniAsCrlf $tmp $crlf
    if ((Test-Path $ini) -and ((Get-FileHash $ini).Hash -eq (Get-FileHash $crlf).Hash)) {
      Write-Log 'Le rdpwrap.ini local est déjà la dernière version.'
    } else {
      if (Test-Path $ini) {
        $backup = "$ini.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $ini $backup -Force
        Write-Log "Ancien fichier sauvegardé : $backup"
      }
      Copy-Item $crlf $ini -Force
      Write-Log "Nouveau rdpwrap.ini installé (Updated=$(Get-IniUpdated $ini))." OK
      $changed = $true
      # Five backups are plenty to roll back, and keep the folder bounded.
      Get-ChildItem $dir -Filter 'rdpwrap.ini.bak-*' | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 5 | Remove-Item -Force -ErrorAction SilentlyContinue
    }
  } else {
    Write-Log "rdpwrap.ini gère déjà termsrv.dll $version." OK
  }

  if (-not (Test-IniCrlf $ini)) {
    $backup = "$ini.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $ini $backup -Force
    Copy-IniAsCrlf $backup $ini
    Write-Log 'rdpwrap.ini avait des fins de ligne Unix (LF) que RDP Wrapper ne lit pas : converti en CRLF.' WARN
    $changed = $true
  }

  $current = [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty $Script:TermServiceKey).ServiceDll)
  if ($current -ne $dll) {
    New-ItemProperty -Path $Script:TermServiceKey -Name ServiceDll -Value $dll -PropertyType ExpandString -Force | Out-Null
    Write-Log "Le service chargeait « $current » : remis sur rdpwrap.dll." WARN
    $changed = $true
  }
  if ((Get-ItemProperty $Script:TerminalServerKey).fDenyTSConnections -ne 0) {
    Set-ItemProperty $Script:TerminalServerKey -Name fDenyTSConnections -Value 0
    Write-Log 'Le Bureau à distance était désactivé : réactivé.' WARN
    $changed = $true
  }

  if ($changed -or $Script:Bss.Force) {
    $connections = @(Get-BssSessions | Where-Object { $_.User -and $_.Station -like 'RDP-Tcp#*' })
    if ($connections.Count -gt 0 -and -not (Confirm-Action "Le redémarrage coupe $($connections.Count) connexion(s) Bureau à distance (les sessions restent ouvertes). Continuer ?")) {
      Write-Log 'Redémarrage du service reporté : la correction sera active au prochain redémarrage du PC.' WARN
      return $true
    }
    Restart-RdpService
  }
  return $true
}
