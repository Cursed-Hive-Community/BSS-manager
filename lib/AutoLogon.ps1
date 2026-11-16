# Windows automatic sign-in, so the machine gets back to a running desktop
# (and therefore to the supervisor) after a crash or a power cut.
#
# The password is kept as the LSA secret "DefaultPassword", which Winlogon
# reads, never as the plain-text DefaultPassword registry value. This is what
# Microsoft's Sysinternals Autologon does.
# https://learn.microsoft.com/troubleshoot/windows-server/user-profiles-and-logon/turn-on-automatic-logon
# https://learn.microsoft.com/sysinternals/downloads/autologon
#
# Windows 11 refuses automatic sign-in while "only allow Windows Hello sign-in
# for Microsoft accounts" is on (DevicePasswordLessBuildVersion = 2), so it is
# switched off while auto-logon is enabled and its old value restored after.

$Script:WinlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$Script:PasswordLessKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
$Script:AutoLogonSecret = 'DefaultPassword'

function Get-AutoLogonPreviousFile { return (Join-Path $Script:Bss.StateDir 'autologon-previous.json') }

function Get-AutoLogonState {
  $w = Get-ItemProperty $Script:WinlogonKey
  $passwordLess = (Get-ItemProperty $Script:PasswordLessKey -ErrorAction SilentlyContinue).DevicePasswordLessBuildVersion
  $secret = $false
  try { $secret = [BssNative]::LsaSecretExists($Script:AutoLogonSecret) } catch {
    # Reading LSA needs administrator rights; unknown is reported as absent.
  }
  [pscustomobject]@{
    Enabled         = ($w.AutoAdminLogon -eq '1')
    User            = $w.DefaultUserName
    Domain          = $w.DefaultDomainName
    SecretStored    = $secret
    PlainTextStored = [bool]($w.PSObject.Properties.Name -contains 'DefaultPassword')
    PasswordLessOn  = ($passwordLess -eq 2)
  }
}

function Enable-AutoLogon {
  param([string] $User, [Security.SecureString] $Password)
  if (-not $User) { $User = $env:USERNAME }
  if (-not $Password -or $Password.Length -eq 0) { throw 'Mot de passe vide.' }
  $user = $User
  $password = $Password

  $previousFile = Get-AutoLogonPreviousFile
  if (-not (Test-Path $previousFile)) {
    $old = (Get-ItemProperty $Script:PasswordLessKey -ErrorAction SilentlyContinue).DevicePasswordLessBuildVersion
    Write-FileAtomic $previousFile (@{ DevicePasswordLessBuildVersion = $old } | ConvertTo-Json)
  }

  [BssNative]::StoreLsaSecret($Script:AutoLogonSecret, $password)
  Set-ItemProperty $Script:WinlogonKey -Name AutoAdminLogon -Value '1'
  Set-ItemProperty $Script:WinlogonKey -Name DefaultUserName -Value $user
  Set-ItemProperty $Script:WinlogonKey -Name DefaultDomainName -Value $env:COMPUTERNAME
  Remove-ItemProperty $Script:WinlogonKey -Name DefaultPassword -ErrorAction SilentlyContinue
  Remove-ItemProperty $Script:WinlogonKey -Name AutoLogonCount -ErrorAction SilentlyContinue
  if (-not (Test-Path $Script:PasswordLessKey)) { New-Item -Path $Script:PasswordLessKey -Force | Out-Null }
  Set-ItemProperty $Script:PasswordLessKey -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
  Write-Log "Connexion automatique activée pour $user (mot de passe stocké en secret LSA)." OK
  Write-Log "À vérifier une fois : redémarre le PC, la session doit s'ouvrir sans rien taper." WARN
}

function Disable-AutoLogon {
  Set-ItemProperty $Script:WinlogonKey -Name AutoAdminLogon -Value '0'
  Remove-ItemProperty $Script:WinlogonKey -Name DefaultPassword -ErrorAction SilentlyContinue
  [BssNative]::StoreLsaSecret($Script:AutoLogonSecret, $null)
  $previousFile = Get-AutoLogonPreviousFile
  if (Test-Path $previousFile) {
    $old = ([IO.File]::ReadAllText($previousFile) | ConvertFrom-Json).DevicePasswordLessBuildVersion
    if ($null -ne $old) { Set-ItemProperty $Script:PasswordLessKey -Name DevicePasswordLessBuildVersion -Value ([int]$old) -Type DWord }
    Remove-Item $previousFile
  }
  Write-Log 'Connexion automatique désactivée, mot de passe effacé.' OK
}
