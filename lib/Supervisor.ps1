# The supervisor runs in the owner's desktop session, started by the task
# scheduler at sign-in, and brings the machine back to the wanted state every
# SupervisorIntervalSec:
#   - RDP Wrapper usable for the current termsrv.dll
#   - every included, unpaused account has a connected session
#   - every such session runs its Natro Macro
#
# It compares states instead of reacting to events, so a missed event costs
# one pass at most. Nothing it starts is restarted within RestartGraceSec,
# which lets Natro boot and keeps a failing start from looping.
#
# Wanted state comes from config.json (written by the menu/CLI only); what the
# supervisor saw and did goes to state\supervisor.json (written by it only),
# which the menu shows.

$Script:SupervisorMutexName = 'Global\BSS-Manager-Supervisor'
$Script:WrapperRetryMinutes = 30
$Script:InboxMaxFiles = 20
$Script:InboxMaxBytes = 4KB

function Invoke-Supervisor {
  $created = $false
  $mutex = New-Object Threading.Mutex($true, $Script:SupervisorMutexName, [ref]$created)
  if (-not $created) {
    Write-Log 'Un superviseur tourne déjà : cette copie s''arrête.' WARN
    return
  }
  try {
    $memory = @{
      StartedAt          = Get-Date
      LastWrapperAttempt = [datetime]::MinValue
      LastRobloxWindow   = $null
      Accounts           = @{}
    }
    $cfg = Get-BssConfig
    foreach ($a in @($cfg.Accounts)) { Sync-NatroTask $cfg $a }
    Write-Log "Superviseur démarré (PID $PID, vérification toutes les $($cfg.SupervisorIntervalSec) s)." OK
    while ($true) {
      try {
        # Re-read every pass: the menu may have paused or added an account.
        $cfg = Get-BssConfig
        Invoke-SupervisorPass $cfg $memory
      } catch {
        # One failing pass must never end supervision.
        Write-Log "Superviseur : $($_.Exception.Message)" ERROR
      }
      Start-Sleep -Seconds ([Math]::Max(15, [int]$cfg.SupervisorIntervalSec))
    }
  } finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
  }
}

function Get-SecondsSince {
  param($Time)
  if (-not $Time) { return [double]::MaxValue }
  return ((Get-Date) - $Time).TotalSeconds
}

function Invoke-SupervisorPass {
  param($Cfg, $Memory)
  $grace = [int]$Cfg.RestartGraceSec
  $status = [ordered]@{
    Pid       = $PID
    StartedAt = $Memory.StartedAt.ToString('o')
    LastPass  = (Get-Date).ToString('o')
    Interval  = [int]$Cfg.SupervisorIntervalSec
    Running   = $true
    Wrapper   = ''
    Accounts  = [ordered]@{}
  }

  # The status page is part of what keeps running while the PC is alive.
  try { Start-StatusServerIfNeeded $Cfg } catch { Write-Log "Page d'état : $($_.Exception.Message)" WARN }

  $status.Running = [bool]$Cfg.Running
  # Stopped by the owner: nothing to look after, not even RDP Wrapper.
  if (-not $Cfg.Running) {
    $status.Wrapper = 'système arrêté'
    Write-FileAtomic $Script:Bss.StatusFile ($status | ConvertTo-Json -Depth 4)
    return
  }

  $wrapper = Get-WrapperState $Cfg
  $status.Wrapper = $(if ($wrapper.Healthy) { 'ok' } else { 'à réparer' })
  if (-not $wrapper.Healthy -and (Get-SecondsSince $Memory.LastWrapperAttempt) -ge $Script:WrapperRetryMinutes * 60) {
    $Memory.LastWrapperAttempt = Get-Date
    Write-Log "Superviseur : RDP Wrapper n'est pas utilisable (termsrv $($wrapper.TermsrvVersion)), réparation..." WARN
    if ($wrapper.IniSupports -and $wrapper.IniCrlf -and $wrapper.ServiceDllOk) { Restart-RdpService } else { [void](Update-RdpWrapper $Cfg) }
  }

  # Another process holds a Roblox window (every Roblox closed on purpose):
  # restarting anything now would break its install or update.
  if (Test-RobloxWindowOpen) {
    $status.Wrapper = "$($status.Wrapper), mise à jour de Roblox en cours"
    Write-FileAtomic $Script:Bss.StatusFile ($status | ConvertTo-Json -Depth 4)
    return
  }

  # An account whose Roblox install or forced update failed (it fails
  # whenever another Roblox runs) gets a window: all Roblox closed, updated
  # one by one, macros restarted. At most once per RobloxAutoMinSeconds, so
  # a Roblox failing for another reason cannot stop the macros in a loop.
  $needs = @()
  foreach ($a in @($Cfg.Accounts | Where-Object { $_.Enabled -and -not $_.Paused })) {
    if (-not (Test-SessionConnected (Get-AccountSession $a))) { continue }
    $need = Get-RobloxUpdateNeed $a
    if ($need) { $needs += "$($a.Name) ($need)" }
  }
  if ($needs.Count) {
    if ((Get-SecondsSince $Memory.LastRobloxWindow) -ge $Script:RobloxAutoMinSeconds) {
      if (Test-OwnerRobloxBlocking $Cfg) {
        $status.Wrapper = "$($status.Wrapper), mise à jour de Roblox en attente : ferme ton Roblox"
      } else {
        $Memory.LastRobloxWindow = Get-Date
        Write-Log "Superviseur : Roblox à réparer pour $($needs -join ', ')." WARN
        try { Invoke-RobloxUpdate $Cfg -Reason 'mise à jour automatique de Roblox' } catch { Write-Log "Superviseur : mise à jour de Roblox impossible, $($_.Exception.Message)" ERROR }
        return
      }
    }
  }

  $restartRequests = @()
  if ($Cfg.InboxEnabled) { $restartRequests = @(Read-InboxRequests $Cfg $Script:Bss.InboxDir) }

  $sessions = Get-BssSessions
  $openedThisPass = $false
  foreach ($account in @($Cfg.Accounts)) {
    if (-not $account.Enabled) { continue }
    if (-not $Memory.Accounts.ContainsKey($account.Name)) {
      $Memory.Accounts[$account.Name] = @{ LastSessionLaunch = $null; NatroMissingSince = $null; LastNatroStart = $null; LastAction = ''; LastActionAt = $null }
    }
    $m = $Memory.Accounts[$account.Name]
    $session = Get-AccountSession $account $sessions
    $entry = [ordered]@{ Session = (Format-SessionState $session); Natro = ''; State = ''; LastAction = $m.LastAction; LastActionAt = $(if ($m.LastActionAt) { $m.LastActionAt.ToString('o') } else { '' }) }
    $status.Accounts[$account.Name] = $entry

    if ($account.Paused) { $entry.State = 'en pause'; continue }
    # Unattended work needs a saved password and a macro; anything less would
    # only leave a password prompt or an idle session on screen.
    $missing = Get-AccountReadiness $account
    if ($missing) { $entry.State = "pas prêt : $missing"; continue }
    # The account just became ready (its owner signed in to Roblox): give
    # it the task that starts Natro.
    if (-not (Get-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName (Get-NatroTaskName $account) -ErrorAction SilentlyContinue)) {
      Sync-NatroTask $Cfg $account
    }
    if (Test-MacroUpdating $account.MacroPath) { $entry.State = 'mise à jour en cours'; continue }

    if (-not (Test-SessionConnected $session)) {
      # The owner's session is the owner's to open (or automatic sign-in's).
      if ($account.Local) { $entry.State = 'ta session n''est pas connectée'; continue }
      $entry.State = 'session à rouvrir'
      if (Get-AccountClient $account) { $entry.State = 'connexion en cours'; continue }
      # One session per pass: a Roblox start is heavy, and staggering them is
      # what DelayBetweenSessionsSec does for the manual launch.
      if (-not $openedThisPass -and (Get-SecondsSince $m.LastSessionLaunch) -ge $grace) {
        Write-Log "Superviseur : $($account.Name) - session $(Format-SessionState $session), ouverture." WARN
        if (Open-AccountSession $Cfg $account) {
          $m.LastSessionLaunch = Get-Date
          $m.NatroMissingSince = $null
          $m.LastAction = 'session rouverte'; $m.LastActionAt = Get-Date
          $openedThisPass = $true
        }
      }
      continue
    }

    $running = Test-NatroRunning $account $session.Id
    $entry.Natro = $(if ($running) { 'tourne' } else { 'arrêté' })

    if ($running -and ($restartRequests -contains $account.Name) -and (Get-SecondsSince $m.LastNatroStart) -ge $grace) {
      Write-Log "Superviseur : $($account.Name) - redémarrage demandé par la boîte de réception." WARN
      Stop-NatroProcesses $account.MacroPath
      [void](Start-Natro $Cfg $account)
      $m.LastNatroStart = Get-Date
      $m.LastAction = 'macro redémarrée (demande)'; $m.LastActionAt = Get-Date
      $entry.State = 'redémarrage'
      continue
    }

    if ($running) { $m.NatroMissingSince = $null; $entry.State = 'ok'; continue }
    if (-not $m.NatroMissingSince) { $m.NatroMissingSince = Get-Date }
    $entry.State = "Natro absent depuis $([int](Get-SecondsSince $m.NatroMissingSince)) s"
    if ((Get-SecondsSince $m.NatroMissingSince) -ge $grace -and
        (Get-SecondsSince $m.LastNatroStart) -ge $grace -and
        (Get-SecondsSince $m.LastSessionLaunch) -ge $grace) {
      Write-Log "Superviseur : $($account.Name) - Natro ne tourne plus, relance." WARN
      [void](Start-Natro $Cfg $account)
      $m.LastNatroStart = Get-Date
      $m.LastAction = 'macro relancée'; $m.LastActionAt = Get-Date
    }
  }

  Write-FileAtomic $Script:Bss.StatusFile ($status | ConvertTo-Json -Depth 4)
}

# Requests other programs (the fork's fleet, later) may drop to ask for a
# macro restart, as small JSON files:
#   {"action": "restart", "account": "Roblox1"}
#   {"action": "restart", "macro": "Natro_Macro_GuidingALT1"}
# Anything else is refused and logged. Every file is deleted once read, at
# most InboxMaxFiles per pass, so the folder cannot grow without bound.
function Read-InboxRequests {
  param($Cfg, [string] $Dir)
  if (-not (Test-Path $Dir)) { return @() }
  $names = @()
  $files = Get-ChildItem $Dir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -First $Script:InboxMaxFiles
  foreach ($file in $files) {
    try {
      if ($file.Extension -ne '.json') { throw 'extension refusée' }
      if ($file.Length -gt $Script:InboxMaxBytes) { throw 'fichier trop gros' }
      $request = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
      if ($request.action -ne 'restart') { throw "action inconnue « $($request.action) »" }
      $target = $Cfg.Accounts | Where-Object {
        ($request.account -and $_.Name -eq [string]$request.account) -or
        ($request.macro -and $_.MacroPath -and (Split-Path $_.MacroPath -Leaf) -eq [string]$request.macro)
      } | Select-Object -First 1
      if (-not $target) { throw 'compte ou macro inconnu' }
      $names += $target.Name
    } catch {
      Write-Log "Boîte de réception : $($file.Name) ignoré ($($_.Exception.Message))." WARN
    } finally {
      Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
    }
  }
  return @($names | Sort-Object -Unique)
}

function Get-SupervisorStatus {
  if (-not (Test-Path $Script:Bss.StatusFile)) { return $null }
  try {
    $s = [IO.File]::ReadAllText($Script:Bss.StatusFile) | ConvertFrom-Json
    $age = ((Get-Date) - [datetime]$s.LastPass).TotalSeconds
    $s | Add-Member -NotePropertyName AgeSec -NotePropertyValue ([int]$age)
    $s | Add-Member -NotePropertyName Alive -NotePropertyValue ($age -lt 3 * [int]$s.Interval + 30)
    return $s
  } catch { return $null }
}
