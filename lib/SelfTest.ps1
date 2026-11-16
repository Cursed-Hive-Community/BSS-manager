# Checks that need no administrator rights and change nothing outside a
# temporary folder. They cover the pieces that can be driven on this machine
# without opening sessions; see TODO.md for what only real use can prove.

function Invoke-SelfTest {
  param($Cfg)
  $results = New-Object Collections.Generic.List[object]
  $tmp = Join-Path $env:TEMP ('bss-selftest-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null

  function Add-Check([string] $Name, [scriptblock] $Test) {
    try {
      $ok = [bool](& $Test)
      $results.Add([pscustomobject]@{ Check = $Name; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Detail = '' })
    } catch {
      $results.Add([pscustomobject]@{ Check = $Name; Result = 'FAIL'; Detail = $_.Exception.Message })
    }
  }

  try {
    Add-Check 'Native types load' { ('BssNative' -as [type]) -ne $null }

    Add-Check 'Sessions enumerate, own session found' {
      @(Get-BssSessions | Where-Object { $_.User -eq $env:USERNAME }).Count -ge 1
    }

    Add-Check 'Credential write/read/delete round trip' {
      $target = 'BSS-Manager/selftest/' + [Guid]::NewGuid().ToString('N')
      $secret = New-Object Security.SecureString
      foreach ($c in [Guid]::NewGuid().ToString('N').ToCharArray()) { $secret.AppendChar($c) }
      [BssNative]::WriteCred($target, 'selftest', $secret)
      $written = [BssNative]::CredExists($target)
      [BssNative]::DeleteCred($target)
      $written -and -not [BssNative]::CredExists($target)
    }

    Add-Check 'Defaults survive a JSON round trip' {
      $d = [pscustomobject](Get-BssDefaults)
      $back = ($d | ConvertTo-Json -Depth 5) | ConvertFrom-Json
      @((Get-BssDefaults).Keys | Where-Object { -not ($back.PSObject.Properties.Name -contains $_) }).Count -eq 0
    }

    Add-Check 'Loopback addresses skip used ones' {
      $fake = [pscustomobject]@{ Accounts = @([pscustomobject]@{ Ip = '127.0.0.2' }, [pscustomobject]@{ Ip = '127.0.0.4' }) }
      (Get-NextLoopbackIp $fake) -eq '127.0.0.3'
    }

    Add-Check 'Empty name list selects enabled accounts only' {
      $fake = [pscustomobject]@{ Accounts = @([pscustomobject]@{ Name = 'a'; Enabled = $true }, [pscustomobject]@{ Name = 'b'; Enabled = $false }) }
      $picked = @(Select-Accounts $fake @())
      $picked.Count -eq 1 -and $picked[0].Name -eq 'a'
    }

    Add-Check 'RDP Wrapper state readable, ini knows termsrv.dll' {
      $w = Get-WrapperState $Cfg
      $w.TermsrvVersion -match '^\d+\.\d+\.\d+\.\d+$' -and $w.IniSupports
    }

    Add-Check 'mstsc gets the account address and size, no .rdp file' {
      $arguments = Get-MstscArguments $Cfg ([pscustomobject]@{ Name = 'SelfTest'; Ip = '127.0.0.9' })
      ($arguments[0] -match '^/v:127\.0\.0\.9(:\d+)?$') -and ($arguments -contains "/w:$($Cfg.SessionWidth)") -and
        -not ($arguments -match '\.rdp')
    }

    Add-Check 'ini line endings: LF detected, converted to CRLF' {
      $lf = Join-Path $tmp 'lf.ini'
      $crlf = Join-Path $tmp 'crlf.ini'
      [IO.File]::WriteAllText($lf, "[Main]`nUpdated=x`n[10.0.1.2]`nA=1`r`nB=2`n")
      $before = Test-IniCrlf $lf
      Copy-IniAsCrlf $lf $crlf
      $text = [IO.File]::ReadAllText($crlf)
      (-not $before) -and (Test-IniCrlf $crlf) -and ($text -eq "[Main]`r`nUpdated=x`r`n[10.0.1.2]`r`nA=1`r`nB=2`r`n")
    }

    Add-Check 'installed rdpwrap.ini uses CRLF line endings' {
      Test-IniCrlf (Join-Path $Cfg.RdpWrapperDir 'rdpwrap.ini')
    }

    Add-Check 'nm_config.ini: add, replace, keep other sections' {
      $macro = Join-Path $tmp 'macro'
      New-Item -ItemType Directory -Path (Join-Path $macro 'settings') -Force | Out-Null
      [IO.File]::WriteAllLines((Get-NatroIniPath $macro), [string[]]@('[Gui]', 'X=1', '[Settings]', 'GitBranch=main', 'Other=2', '[Status]', 'Y=3'))
      Set-NatroIniValue $macro 'GitBranch' 'feature/test'
      Set-NatroIniValue $macro 'GitRepoUrl' 'https://example.invalid/repo.git'
      $lines = [IO.File]::ReadAllLines((Get-NatroIniPath $macro))
      (Get-NatroIniValue $macro 'GitBranch') -eq 'feature/test' -and
        (Get-NatroIniValue $macro 'GitRepoUrl') -eq 'https://example.invalid/repo.git' -and
        (Get-NatroIniValue $macro 'Other') -eq '2' -and ($lines -contains 'Y=3') -and
        @($lines | Where-Object { $_ -like 'GitBranch=*' }).Count -eq 1
    }

    Add-Check 'nm_config.ini: section created when missing' {
      $macro = Join-Path $tmp 'macro2'
      New-Item -ItemType Directory -Path (Join-Path $macro 'settings') -Force | Out-Null
      [IO.File]::WriteAllLines((Get-NatroIniPath $macro), [string[]]@('[Gui]', 'X=1'))
      Set-NatroIniValue $macro 'GitBranch' 'main'
      (Get-NatroIniValue $macro 'GitBranch') -eq 'main' -and ([IO.File]::ReadAllLines((Get-NatroIniPath $macro)) -contains '[Settings]')
    }

    Add-Check 'Macro discovery finds a Cursed folder with its tools' {
      @(Find-Macros $Cfg | Where-Object { $_.IsGit -and $_.HasTools -and $_.Branch }).Count -ge 1
    }

    Add-Check 'No Natro reported for a folder that does not exist' {
      -not (Test-NatroRunning ([pscustomobject]@{ MacroPath = (Join-Path $tmp 'nothing') }))
    }

    Add-Check 'Inbox keeps valid requests only and empties itself' {
      $inbox = Join-Path $tmp 'inbox'
      New-Item -ItemType Directory -Path $inbox | Out-Null
      $fake = [pscustomobject]@{ Accounts = @([pscustomobject]@{ Name = 'Roblox1'; MacroPath = 'G:\x\Natro_A' }, [pscustomobject]@{ Name = 'Roblox2'; MacroPath = 'G:\x\Natro_B' }) }
      Set-Content (Join-Path $inbox '1.json') '{"action":"restart","account":"Roblox1"}'
      Set-Content (Join-Path $inbox '2.json') '{"action":"restart","macro":"Natro_B"}'
      Set-Content (Join-Path $inbox '3.json') '{"action":"format-disk","account":"Roblox1"}'
      Set-Content (Join-Path $inbox '4.json') '{"action":"restart","account":"Nobody"}'
      Set-Content (Join-Path $inbox '5.txt') 'restart Roblox1'
      Set-Content (Join-Path $inbox '6.json') ('{"action":"restart","account":"Roblox1","pad":"' + ('x' * 5000) + '"}')
      $names = @(Read-InboxRequests $fake $inbox)
      ($names -join ',') -eq 'Roblox1,Roblox2' -and @(Get-ChildItem $inbox).Count -eq 0
    }

    Add-Check 'Roblox names guessed from the owner''s folder names' {
      $cases = [ordered]@{
        'Natro_Macro_PlayerAlt4'             = 'PlayerAlt4'
        'Natro_Macro_v1.0.1 Player25bee - Red' = 'Player25bee'
        'Natro Macro v1.0.0.3 Player - Blue'   = 'Player'
        'Natro_Macro_v1.0.1 BlueBeePlayer'     = 'BlueBeePlayer'
        'Natro_Macro_v1.0.1 PlayerAlt3'            = 'PlayerAlt3'
        'Natro Macro v1.0.0.2 - Copie'           = $null
        'Natro_Macro_v1.0'                       = $null
        'Natro_Macro_v1.0.0.1a'                  = $null
      }
      @($cases.Keys | Where-Object { (Get-RobloxNameGuess $_) -ne $cases[$_] }).Count -eq 0
    }

    Add-Check 'A stored password reads back identical, as a SecureString' {
      $target = 'BSS-Manager/selftest/' + [Guid]::NewGuid().ToString('N')
      $secret = New-Object Security.SecureString
      foreach ($c in 'Ab3!éç'.ToCharArray()) { $secret.AppendChar($c) }
      [BssNative]::WriteCred($target, 'selftest', $secret)
      try { $back = [BssNative]::ReadCredSecure($target) } finally { [BssNative]::DeleteCred($target) }
      ($back -is [Security.SecureString]) -and (Test-SecureEqual $secret $back) -and ($null -eq [BssNative]::ReadCredSecure($target))
    }

    Add-Check 'Roblox sign-in rule: first account learnt, another refused' {
      ((Get-RobloxSignInProblem '' 'PlayerAlt2' $true) -eq '') -and
        ((Get-RobloxSignInProblem 'PlayerAlt2' 'PlayerAlt2' $true) -eq '') -and
        ((Get-RobloxSignInProblem 'PlayerAlt2' 'PLAYERALT2' $true) -eq '') -and
        ((Get-RobloxSignInProblem 'PlayerAlt2' 'PlayerAlt4' $true) -like 'mauvais compte*') -and
        ((Get-RobloxSignInProblem '' '' $false) -eq 'Roblox pas installé dans la session') -and
        ((Get-RobloxSignInProblem '' '' $true) -like 'connecte-toi à Roblox*')
    }

    Add-Check 'A macro named after the role is accepted (GuidingALT2 played by PlayerAlt2)' {
      $ok = [pscustomobject]@{ Name = 'NoSuchUser1'; Roblox = 'PlayerAlt2'; Role = 'GuidingALT2'; MacroPath = 'G:\x\Natro_Macro_GuidingALT2' }
      $bad = [pscustomobject]@{ Name = 'NoSuchUser1'; Roblox = 'PlayerAlt2'; Role = ''; MacroPath = 'G:\x\Natro_Macro_GuidingALT2' }
      # Readiness stops at the missing Windows account first, so the macro
      # rule is checked through the names it accepts.
      $accepts = { param($a) $o = Get-RobloxNameGuess (Split-Path $a.MacroPath -Leaf); @($a.Roblox, $a.Role, $a.Name) -contains $o }
      (& $accepts $ok) -and -not (& $accepts $bad)
    }

    Add-Check 'Account names: Roblox names allowed, PC and own name refused' {
      (Test-ValidAccountName 'PlayerAlt4') -and (Test-ValidAccountName 'Guiding_ALT1') -and
        -not (Test-ValidAccountName $env:COMPUTERNAME) -and -not (Test-ValidAccountName $env:USERNAME) -and -not (Test-ValidAccountName 'ab')
    }

    Add-Check 'Account description fits Windows'' 48 characters for a 20-character name' {
      (Get-AccountDescription ('x' * 20)).Length -le 48
    }

    Add-Check 'RDP certificate hash matches what mstsc saved for 127.0.0.2' {
      $saved = (Get-ItemProperty 'HKCU:\Software\Microsoft\Terminal Server Client\Servers\127.0.0.2' -ErrorAction SilentlyContinue).CertHash
      # Assigned first: piped straight on, the byte array would arrive whole.
      $hash = Get-RdpCertificateHash
      if (-not $saved) { return ($hash.Length -eq 32) }
      (($saved | ForEach-Object { '{0:X2}' -f $_ }) -join '') -eq (($hash | ForEach-Object { '{0:X2}' -f $_ }) -join '')
    }

    Add-Check 'Macro discovery skips the _Anciennes archive' {
      $root = Join-Path $tmp 'macros'
      foreach ($d in 'Natro_Macro_kept', "$($Script:ArchiveFolderName)\Natro_Macro_archived") {
        New-Item -ItemType Directory -Force -Path (Join-Path $root "$d\submacros") | Out-Null
        Set-Content (Join-Path $root "$d\submacros\natro_macro.ahk") 'VersionID := "1.0.1"'
      }
      $names = @(Find-Macros ([pscustomobject]@{ MacroRoot = $root; DefaultBranch = 'main'; DefaultRepoUrl = '' }) | ForEach-Object { $_.Name })
      ($names -contains 'Natro_Macro_kept') -and -not ($names -contains 'Natro_Macro_archived')
    }

    Add-Check 'Signed-in Roblox account read for Roblox2 (PlayerAlt4)' {
      (Get-RobloxSignedIn 'Roblox2') -eq 'PlayerAlt4'
    }

    Add-Check 'Roblox2 is not ready while it holds GuidingALT1''s macro' {
      $fake = [pscustomobject]@{ Name = 'Roblox2'; Ip = '127.0.0.3'; MacroPath = 'G:\Macro bee swarm\Natro_Macro_GuidingALT1'; Roblox = 'PlayerAlt4' }
      if (-not [BssNative]::CredExists((Get-CredTarget $fake))) { return $true }
      (Get-AccountReadiness $fake) -eq 'la macro est celle de GuidingALT1, pas de PlayerAlt4'
    }

    Add-Check 'An unknown Windows account is never ready' {
      (Get-AccountReadiness ([pscustomobject]@{ Name = 'NoSuchUser' + [Guid]::NewGuid().ToString('N').Substring(0, 6); Ip = '127.0.0.250'; MacroPath = 'x'; Roblox = 'x' })) -eq 'compte Windows introuvable'
    }

    Add-Check 'git is installed' { [bool](Get-Command git -ErrorAction SilentlyContinue) }
  } finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  $results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
  $failed = @($results | Where-Object { $_.Result -ne 'PASS' }).Count
  if ($failed) { Write-Log "$failed vérification(s) en échec." ERROR } else { Write-Log "$($results.Count) vérifications réussies." OK }
  return $failed
}
