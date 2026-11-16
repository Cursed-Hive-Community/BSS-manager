#Requires -Version 5.1
<#
.SYNOPSIS
  Runs several Natro Macro instances, one per Windows account, each in its own
  loopback Remote Desktop session on this PC, and keeps them running.

.DESCRIPTION
  Without -Action the window opens; -Action Menu gives the text menu. Every
  action except Status and SelfTest needs administrator rights and asks for
  them.

.EXAMPLE
  BSS-Manager.ps1                                  # window
  BSS-Manager.ps1 -Action Menu                     # text menu
  BSS-Manager.ps1 -Action Start                    # one click: update, open, start
  BSS-Manager.ps1 -Action Stop -Account Roblox1    # pause and close one account
  BSS-Manager.ps1 -Action Restart -Account Roblox1 # restart one macro
  BSS-Manager.ps1 -Action UpdateMacros             # update the accounts' macros
  BSS-Manager.ps1 -Action UpdateMacros -Path <dir> # update one macro folder
  BSS-Manager.ps1 -Action SetBranch -Path <dir> -Branch main
  BSS-Manager.ps1 -Action AddRoblox -Roblox PlayerAlt4 [-Role x] [-WindowsUser x] [-Path <base macro>]
  BSS-Manager.ps1 -Action AddRoblox -Role GuidingALT1  # Roblox account learnt at first sign-in
  BSS-Manager.ps1 -Action SelfTest                 # checks, no admin needed

.LINK
  README.md
#>
[CmdletBinding()]
param(
  [ValidateSet('Gui', 'Menu', 'Status', 'Start', 'Stop', 'Restart', 'Update', 'UpdateMacros', 'SetBranch', 'AddRoblox', 'Supervise', 'Install', 'Uninstall', 'SelfTest')]
  [string] $Action = 'Gui',
  [string[]] $Account,
  [string] $Path,
  [string] $Branch,
  [string] $Roblox,
  [string] $Role,
  [string] $WindowsUser,
  [switch] $Unattended,
  [switch] $Force,
  # Test hook: draws every tab of the window into PNG files, then closes it.
  [string] $SnapshotDir
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
foreach ($module in 'Native', 'Core', 'RdpWrapper', 'Sessions', 'Macros', 'AutoLogon', 'Supervisor', 'Actions', 'Menu', 'Gui', 'SelfTest') {
  . (Join-Path $root "lib\$module.ps1")
}

# "-Account a,b" arrives as one string when the script is run with -File.
if ($Account) { $Account = @($Account | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

$readOnly = ($Action -in @('Status', 'SelfTest')) -or ($Action -eq 'Gui' -and $SnapshotDir)
if (-not $readOnly -and -not (Test-Admin)) {
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
  # The window needs no console behind it.
  if ($Action -eq 'Gui') { $arguments += @('-WindowStyle', 'Hidden') }
  $arguments += @('-File', ('"{0}"' -f $PSCommandPath), '-Action', $Action)
  if ($Account) { $arguments += @('-Account', ($Account -join ',')) }
  if ($Path) { $arguments += @('-Path', ('"{0}"' -f $Path)) }
  if ($Branch) { $arguments += @('-Branch', $Branch) }
  if ($Roblox) { $arguments += @('-Roblox', $Roblox) }
  if ($Role) { $arguments += @('-Role', $Role) }
  if ($WindowsUser) { $arguments += @('-WindowsUser', $WindowsUser) }
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
    'Gui'          { Show-ManagerWindow -SnapshotDir $SnapshotDir }
    'Menu'         { Show-MainMenu }
    'Status'       { Show-Status $cfg }
    'Start'        { Start-All $cfg $Account }
    'Stop'         { Stop-All $cfg $Account }
    'Restart'      { Restart-AccountMacro $cfg $Account }
    'Update'       { if (-not (Update-RdpWrapper $cfg)) { exit 2 } }
    'UpdateMacros' { if ($Path) { Update-Macros $cfg -Paths @($Path) } else { Update-Macros $cfg $Account } }
    'SetBranch'    { if (-not ($Path -and $Branch)) { throw '-Path et -Branch sont obligatoires.' }; Set-MacroBranch $cfg $Path $Branch }
    'AddRoblox'    { if (-not ($Roblox -or $Role)) { throw '-Roblox ou -Role est obligatoire.' }; Add-RobloxAccount $cfg $Roblox $Role $WindowsUser $Path }
    'Supervise'    { Invoke-Supervisor }
    'Install'      { Install-Manager $cfg }
    'Uninstall'    { Uninstall-Manager }
    'SelfTest'     { exit (Invoke-SelfTest $cfg) }
  }
  # The one-click window closes by itself, but late enough to be read.
  if ($Action -eq 'Start' -and $Unattended) { Start-Sleep -Seconds 10 }
} catch {
  Write-Log "Erreur : $($_.Exception.Message)" ERROR
  if ($Action -eq 'Gui') { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'BSS Manager', 'OK', 'Error') }
  elseif (-not $Unattended -and $Action -ne 'Menu') { Wait-Enter }
  exit 1
}
