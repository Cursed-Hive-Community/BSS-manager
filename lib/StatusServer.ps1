# Read-only status page on the local network, for a watchdog (the planned
# Raspberry Pi that power-cycles a frozen PC) and for the fork's fleet (so a
# Roblox window is not taken for a crash).
#
#   GET http://<PC>:<StatusPort>/status   ->  JSON, see Get-StatusDocument
#
# It only reads: config.json and state\supervisor.json. Nothing can be done
# through it, it carries no secret, and its firewall rule admits private
# networks only. It runs as its own process, started and kept alive by the
# supervisor; if the supervisor dies the page goes on answering with an
# ever older supervisor.ageSec, and if the whole PC freezes it stops
# answering at all: both are what a watchdog must act on.
# https://learn.microsoft.com/dotnet/api/system.net.httplistener

$Script:StatusMutexName = 'Global\BSS-Manager-StatusServer'

# The verdict a watchdog reads, separating what the owner chose from what
# went wrong. Closing the window is neither: the window is only a dashboard,
# the supervisor (a scheduled task) does the work.
#   stopped      Stop pressed, or the supervisor disabled by the owner
#   maintenance  a Roblox window is open (macros stopped on purpose)
#   ok           the supervisor passed recently
#   degraded     the supervisor crashed (not running though enabled) or
#                hangs (running, no recent pass): alert, never cut power
# A PC that does not answer this page nor a ping is the only case where
# cutting its power is right.
function Get-StatusVerdict {
  param($Cfg, [string] $TaskState, [bool] $RobloxWindow, [bool] $Alive)
  if (-not $Cfg.Running) { return @('stopped', 'system stopped (Stop)') }
  if ($TaskState -in @('Disabled', 'Missing')) { return @('stopped', 'supervisor disabled') }
  if ($RobloxWindow) { return @('maintenance', 'Roblox update in progress') }
  if ($Alive) { return @('ok', '') }
  if ($TaskState -eq 'Running') { return @('degraded', 'supervisor hung (no recent pass)') }
  return @('degraded', 'supervisor crashed (stopped without being asked)')
}

# The document, built from the configuration and the supervisor's last
# pass. A pure function of its inputs, so it can be tested.
function Get-StatusDocument {
  param($Cfg, $Supervisor, [bool] $RobloxWindow, [datetime] $Now, [string] $TaskState = 'Running')
  $age = $null
  $alive = $false
  if ($Supervisor -and $Supervisor.LastPass) {
    $age = [int]($Now - [datetime]$Supervisor.LastPass).TotalSeconds
    $alive = $age -lt (3 * [int]$Supervisor.Interval + 30)
  }
  $verdict = Get-StatusVerdict $Cfg $TaskState $RobloxWindow $alive
  $accounts = foreach ($a in @($Cfg.Accounts)) {
    $entry = $null
    if ($Supervisor -and $Supervisor.Accounts -and $Supervisor.Accounts.PSObject.Properties.Name -contains $a.Name) { $entry = $Supervisor.Accounts.($a.Name) }
    [ordered]@{
      name    = $a.Name
      roblox  = [string]$a.Roblox
      role    = [string]$a.Role
      active  = [bool]$a.Enabled
      paused  = [bool]$a.Paused
      session = $(if ($entry) { [string]$entry.Session } else { '' })
      natro   = $(if ($entry) { [string]$entry.Natro } else { '' })
      state   = $(if ($entry) { [string]$entry.State } else { '' })
    }
  }
  [ordered]@{
    pc           = $env:COMPUTERNAME
    time         = $Now.ToString('o')
    health       = $verdict[0]
    reason       = $verdict[1]
    running      = [bool]$Cfg.Running
    robloxWindow = $RobloxWindow
    supervisor   = [ordered]@{ task = $TaskState; alive = $alive; lastPass = $(if ($Supervisor) { [string]$Supervisor.LastPass } else { '' }); ageSec = $age }
    accounts     = @($accounts)
  }
}

function Add-StatusFirewallRule {
  param([int] $Port)
  $name = "BSS Manager - status page ($Port)"
  # The rule's name before the application was translated to English.
  Get-NetFirewallRule -DisplayName "BSS Manager - page d'état ($Port)" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  if (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) { return }
  New-NetFirewallRule -DisplayName $name -Group 'BSS Manager' -Direction Inbound -Action Allow -Profile Private -Protocol TCP -LocalPort $Port | Out-Null
  Write-Log "Firewall: status page open on port $Port (private networks only)." OK
}

function Test-StatusServerRunning {
  $m = $null
  if ([Threading.Mutex]::TryOpenExisting($Script:StatusMutexName, [ref]$m)) { $m.Dispose(); return $true }
  return $false
}

# Called by the supervisor every pass: starts the server when enabled and
# not running. Stopping it when disabled is left to a restart of the PC.
function Start-StatusServerIfNeeded {
  param($Cfg)
  if (-not $Cfg.StatusServerEnabled -or (Test-StatusServerRunning)) { return }
  Add-StatusFirewallRule ([int]$Cfg.StatusPort)
  $main = Join-Path $Script:Bss.Root 'BSS-Manager.ps1'
  Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $main), '-Action', 'StatusServer', '-Unattended') | Out-Null
  Write-Log "Status page started: http://$($env:COMPUTERNAME):$($Cfg.StatusPort)/status" OK
}

function Invoke-StatusServer {
  $created = $false
  $mutex = New-Object Threading.Mutex($true, $Script:StatusMutexName, [ref]$created)
  if (-not $created) { return }
  $cfg = Get-BssConfig
  $listener = New-Object Net.HttpListener
  $listener.Prefixes.Add("http://+:$([int]$cfg.StatusPort)/")
  try {
    $listener.Start()
    while ($listener.IsListening) {
      $context = $listener.GetContext()
      try {
        $response = $context.Response
        if ($context.Request.HttpMethod -ne 'GET') {
          $response.StatusCode = 405
        } else {
          $cfg = Get-BssConfig
          $sup = $null
          if (Test-Path $Script:Bss.StatusFile) { $sup = (Read-SharedText $Script:Bss.StatusFile) | ConvertFrom-Json }
          $task = Get-SupervisorTask
          $doc = Get-StatusDocument $cfg $sup (Test-RobloxWindowOpen) (Get-Date) $(if ($task) { [string]$task.State } else { 'Missing' })
          $bytes = [Text.Encoding]::UTF8.GetBytes(($doc | ConvertTo-Json -Depth 5))
          $response.ContentType = 'application/json; charset=utf-8'
          $response.ContentLength64 = $bytes.Length
          $response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
      } catch {
        # A bad request must never stop the page.
        try { $context.Response.StatusCode = 500 } catch { }
      } finally {
        try { $context.Response.Close() } catch { }
      }
    }
  } finally {
    $listener.Close()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
  }
}
