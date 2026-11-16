#Requires -Version 5.1
<#
.SYNOPSIS
  Runs several Natro Macro instances, one per Windows account, each in its own
  loopback Remote Desktop session on this PC, and keeps them running.

.DESCRIPTION
  Without -Action the interactive menu opens. Every action except Status and
  SelfTest needs administrator rights and asks for them.

.EXAMPLE
  BSS-Manager.ps1                                  # menu
  BSS-Manager.ps1 -Action Start                    # one click: update, open, start
  BSS-Manager.ps1 -Action Stop -Account Roblox1    # pause and close one account
  BSS-Manager.ps1 -Action Restart -Account Roblox1 # restart one macro
  BSS-Manager.ps1 -Action UpdateMacros             # update the accounts' macros
  BSS-Manager.ps1 -Action SelfTest                 # checks, no admin needed

.LINK
  README.md
#>
[CmdletBinding()]
param(
  [ValidateSet('Menu', 'Status', 'Start', 'Stop', 'Restart', 'Update', 'UpdateMacros', 'Supervise', 'Install', 'Uninstall', 'SelfTest')]
  [string] $Action = 'Menu',
  [string[]] $Account,
  [switch] $Unattended,
  [switch] $Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
foreach ($module in 'Native', 'Core', 'RdpWrapper', 'Sessions', 'Macros', 'AutoLogon', 'Supervisor', 'Actions', 'Menu', 'SelfTest') {
  . (Join-Path $root "lib\$module.ps1")
}

# "-Account a,b" arrives as one string when the script is run with -File.
if ($Account) { $Account = @($Account | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

if (($Action -notin @('Status', 'SelfTest')) -and -not (Test-Admin)) {
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-Action', $Action)
  if ($Account) { $arguments += @('-Account', ($Account -join ',')) }
  if ($Unattended) { $arguments += '-Unattended' }
  if ($Force) { $arguments += '-Force' }
  try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments | Out-Null
  } catch {
    Write-Host 'Droits administrateur refusés : action annulée.' -ForegroundColor Red
    if (-not $Unattended) { [void](Read-Host 'Entrée pour fermer') }
  }
  exit
}

Initialize-Bss -Root $root -Unattended $Unattended.IsPresent -Force $Force.IsPresent

try {
  $cfg = Get-BssConfig
  switch ($Action) {
    'Menu'         { Show-MainMenu $cfg }
    'Status'       { Show-Status $cfg }
    'Start'        { Start-All $cfg $Account }
    'Stop'         { Stop-All $cfg $Account }
    'Restart'      { Restart-AccountMacro $cfg $Account }
    'Update'       { if (-not (Update-RdpWrapper $cfg)) { exit 2 } }
    'UpdateMacros' { Update-Macros $cfg $Account }
    'Supervise'    { Invoke-Supervisor }
    'Install'      { Install-Manager $cfg }
    'Uninstall'    { Uninstall-Manager }
    'SelfTest'     { exit (Invoke-SelfTest $cfg) }
  }
  # The one-click window closes by itself, but late enough to be read.
  if ($Action -eq 'Start' -and $Unattended) { Start-Sleep -Seconds 10 }
} catch {
  Write-Log "Erreur : $($_.Exception.Message)" ERROR
  if (-not $Unattended -and $Action -ne 'Menu') { Wait-Enter }
  exit 1
}
