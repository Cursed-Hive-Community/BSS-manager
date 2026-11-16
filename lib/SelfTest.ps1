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

    Add-Check 'Firewall rules: both AutoHotkey programs, TCP and UDP, inside the macro folder' {
      $rules = @(Get-MacroFirewallRuleNames 'G:\x\Natro_Macro_Test')
      $rules.Count -eq 4 -and @($rules | Where-Object { $_.Program -like 'G:\x\Natro_Macro_Test\submacros\AutoHotkey*.exe' }).Count -eq 4 -and
        @($rules.Name | Sort-Object -Unique).Count -eq 4
    }

    Add-Check 'Edge auto-launch policy is valid JSON, roblox.com only' {
      $p = $Script:RobloxAutoLaunch | ConvertFrom-Json
      $origins = @($p | ForEach-Object { $_.allowed_origins }) | Sort-Object -Unique
      @($p).Count -eq 2 -and @($origins | Where-Object { $_ -notmatch '^https://(www\.)?roblox\.com$' }).Count -eq 0
    }

    Add-Check 'Roblox settings: wanted values set, missing ones added, others kept, file layout kept' {
      $file = Join-Path $tmp 'GlobalBasicSettings_13.xml'
      $sample = "<roblox version=`"4`">`r`n`t<Item class=`"UserGameSettings`" referent=`"RBX1`">`r`n`t`t<Properties>`r`n" +
        "`t`t`t<int name=`"GraphicsQualityLevel`">21</int>`r`n`t`t`t<bool name=`"Fullscreen`">false</bool>`r`n" +
        "`t`t`t<float name=`"MouseSensitivity`">0.2</float>`r`n`t`t</Properties>`r`n`t</Item>`r`n</roblox>`r`n"
      [IO.File]::WriteAllText($file, $sample, (New-Object Text.UTF8Encoding $false))
      $doc = New-Object Xml.XmlDocument
      $doc.PreserveWhitespace = $true
      $doc.Load($file)
      $first = Set-RobloxSettingsXml $doc
      Save-RobloxSettingsXml $doc $file
      $doc2 = New-Object Xml.XmlDocument
      $doc2.Load($file)
      $bytes = [IO.File]::ReadAllBytes($file)
      $text = [IO.File]::ReadAllText($file)
      ($first -eq $Script:RobloxSettings.Count) -and (@(Get-RobloxSettingsDifferences $doc2).Count -eq 0) -and
        ((Set-RobloxSettingsXml $doc2) -eq 0) -and $text.Contains('<float name="MouseSensitivity">0.2</float>') -and
        $text.Contains('<float name="HapticStrength">0</float>') -and -not ($bytes[0] -eq 0xEF) -and $text.StartsWith('<roblox')
    }

    Add-Check 'Roblox settings match what Natro checks (lowest graphics 3, never automatic 0)' {
      $wanted = @{}
      foreach ($s in $Script:RobloxSettings) { $wanted[$s[1]] = $s[2] }
      $wanted.GraphicsQualityLevel -eq '3' -and $wanted.PreferredTextSize -eq '1' -and $wanted.ControlMode -eq '1' -and
        $wanted.ComputerCameraMovementMode -ne '2' -and $wanted.ComputerMovementMode -ne '2' -and $wanted.CameraYInverted -eq 'false' -and
        $wanted.OnScreenProfilerEnabled -eq 'false' -and $wanted.Fullscreen -eq 'true' -and $wanted.HapticStrength -eq '0'
    }

    Add-Check 'roblox:// keys built exactly like the Roblox installer wrote them for the owner' {
      $classes = 'HKCU:\Software\Classes'
      $exe = Get-RegisteredProtocolExe $classes 'roblox-player'
      if (-not $exe) { return $true }
      $same = $true
      foreach ($protocol in 'roblox', 'roblox-player') {
        foreach ($v in Get-RobloxProtocolValues $protocol $exe) {
          $actual = (Get-ItemProperty (Join-Path $classes $v[0]) -ErrorAction SilentlyContinue).($v[1])
          if ([string]$actual -ne [string]$v[2]) { $same = $false }
        }
      }
      $same
    }

    Add-Check 'Roblox window lock: held by a live process, ignored when its process died or it is stale' {
      $saved = $Script:Bss.StateDir
      $Script:Bss.StateDir = $tmp
      try {
        $lock = Get-RobloxLockPath
        $none = Test-RobloxWindowOpen
        Set-Content $lock $PID
        $mine = Test-RobloxWindowOpen
        $dead = 999999
        while (Get-Process -Id $dead -ErrorAction SilentlyContinue) { $dead-- }
        Set-Content $lock $dead
        $deadOpen = Test-RobloxWindowOpen
        Set-Content $lock $PID
        (Get-Item $lock).LastWriteTime = (Get-Date).AddMinutes(-($Script:RobloxLockStaleMinutes + 1))
        $staleOpen = Test-RobloxWindowOpen
        (-not $none) -and $mine -and (-not $deadOpen) -and (-not $staleOpen)
      } finally { $Script:Bss.StateDir = $saved }
    }

    Add-Check 'Installer logs: the access-denied crash is recognised, a success is not' {
      $crash = "2026-11-16T14:16:45.062Z,22.06,4f88,6,Critical [FLog::DesktopInstaller] ...Util.cpp(134)... FailFast(1) tid(4f88) 8000FFFF`n    Msg:[failed to access client process info: Access denied.]"
      $ok = "Info [FLog::DesktopInstaller] Launch client command line: ...`nInfo [FLog::DesktopInstaller] Installer thread completed successfully"
      (Test-InstallerLogCrashed $crash) -and -not (Test-InstallerLogCrashed $ok)
    }

    Add-Check 'Files another program is writing: read when shared, $null (no error) when locked' {
      $file = Join-Path $tmp 'nm_config.ini'
      [IO.File]::WriteAllText($file, "[Settings]`r`nGitBranch=main`r`n")
      $writer = [IO.File]::Open($file, 'Open', 'ReadWrite', 'ReadWrite')
      try {
        $oldWayFails = $false
        try { [void][IO.File]::ReadAllText($file) } catch { $oldWayFails = $true }
        $shared = Read-SharedText $file
      } finally { $writer.Dispose() }
      $locker = [IO.File]::Open($file, 'Open', 'ReadWrite', 'None')
      try { $locked = Read-SharedText $file } finally { $locker.Dispose() }
      $oldWayFails -and $shared.Contains('GitBranch=main') -and ($null -eq $locked)
    }

    Add-Check 'Status page: supervisor alive or silent, accounts listed, no secret or address' {
      $cfgFake = [pscustomobject]@{ Running = $true; Accounts = @(
          [pscustomobject]@{ Name = 'PlayerAlt2'; Roblox = 'PlayerAlt2'; Role = 'GuidingALT2'; Enabled = $true; Paused = $false; Ip = '127.0.0.4'; MacroPath = 'G:\x' }) }
      $now = Get-Date
      $sup = [pscustomobject]@{ LastPass = $now.AddSeconds(-30).ToString('o'); Interval = 60; Accounts = [pscustomobject]@{ PlayerAlt2 = [pscustomobject]@{ Session = 'connectée'; Natro = 'tourne'; State = 'ok' } } }
      $old = [pscustomobject]@{ LastPass = $now.AddMinutes(-10).ToString('o'); Interval = 60; Accounts = $null }
      $fresh = Get-StatusDocument $cfgFake $sup $false $now
      $stale = Get-StatusDocument $cfgFake $old $true $now
      $json = $fresh | ConvertTo-Json -Depth 5
      $fresh.supervisor.alive -and ($fresh.supervisor.ageSec -eq 30) -and -not $stale.supervisor.alive -and $stale.robloxWindow -and
        ($fresh.accounts[0].natro -eq 'tourne') -and ($fresh.accounts[0].role -eq 'GuidingALT2') -and
        -not ($json -match '127\.0\.0\.4|G:\\\\x|password|Password|Cred') -and [bool]($json | ConvertFrom-Json)
    }

    Add-Check 'Status verdict: owner''s stop, maintenance, ok, crash and hang told apart' {
      $on = [pscustomobject]@{ Running = $true }
      $off = [pscustomobject]@{ Running = $false }
      ((Get-StatusVerdict $off 'Running' $false $true)[0] -eq 'stopped') -and
        ((Get-StatusVerdict $on 'Disabled' $false $false)[0] -eq 'stopped') -and
        ((Get-StatusVerdict $on 'Running' $true $false)[0] -eq 'maintenance') -and
        ((Get-StatusVerdict $on 'Running' $false $true)[0] -eq 'ok') -and
        ((Get-StatusVerdict $on 'Running' $false $false)[1] -like '*bloqué*') -and
        ((Get-StatusVerdict $on 'Ready' $false $false)[1] -like '*planté*')
    }

    Add-Check 'New macro: invalid or already existing names are refused before anything is created' {
      $fake = [pscustomobject]@{ MacroRoot = $tmp; DefaultBranch = 'main'; DefaultRepoUrl = '' }
      New-Item -ItemType Directory -Path (Join-Path $tmp 'Natro_Macro_Taken') | Out-Null
      $refused = 0
      foreach ($n in 'ab', 'bad name', 'Taken') { try { [void](New-MacroFolder $fake $n '') } catch { $refused++ } }
      $refused -eq 3
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
