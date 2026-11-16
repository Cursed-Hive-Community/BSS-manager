# The window (WinForms).
#
# Long actions (start, stop, updates, installation) run as a hidden child
# process of this very script with -Unattended, so the window never freezes
# and every action keeps one implementation, shared with the command line.
# The window confirms first, since -Unattended answers yes to everything.
# Quick edits (pause, assignment, passwords) run here, each one re-reading
# config.json first so it never overwrites what a running action wrote.
# https://learn.microsoft.com/dotnet/desktop/winforms/overview/
#
# Event handlers are plain script blocks reading their data from the
# control's Tag: GetNewClosure() would move them out of this script's scope,
# where the module functions live.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not ('BssDpi' -as [type])) {
  Add-Type -TypeDefinition 'public static class BssDpi { [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
}

$Script:Ui = @{}
$Script:UiRefreshMs = 5000
$Script:UiWrapperRefreshSec = 30

# ---------------------------------------------------------------------------
# Small builders
# ---------------------------------------------------------------------------

function Invoke-UiSafe {
  param([scriptblock] $Block)
  try { & $Block } catch {
    Write-Log "Window: $($_.Exception.Message)" ERROR
    # A snapshot run has nobody to close a message box: log and carry on.
    if (-not $Script:Ui.SnapshotDir) { [void][Windows.Forms.MessageBox]::Show($Script:Ui.Form, $_.Exception.Message, 'BSS Manager', 'OK', 'Error') }
  }
}

function Confirm-Ui {
  param([string] $Question)
  return ([Windows.Forms.MessageBox]::Show($Script:Ui.Form, $Question, 'BSS Manager', 'YesNo', 'Question') -eq 'Yes')
}

function Show-UiInfo {
  param([string] $Text)
  [void][Windows.Forms.MessageBox]::Show($Script:Ui.Form, $Text, 'BSS Manager', 'OK', 'Information')
}

function New-UiButton {
  param([string] $Text, [scriptblock] $OnClick)
  $b = New-Object Windows.Forms.Button
  $b.Text = $Text
  $b.AutoSize = $true
  $b.Padding = New-Object Windows.Forms.Padding(6, 2, 6, 2)
  $b.Tag = $OnClick
  $b.Add_Click({ param($sender) Invoke-UiSafe $sender.Tag })
  return $b
}

function New-UiFlow {
  param([object[]] $Controls, [string] $Dock = 'Top')
  $p = New-Object Windows.Forms.FlowLayoutPanel
  $p.Dock = $Dock
  $p.AutoSize = $true
  $p.WrapContents = $true
  $p.Padding = New-Object Windows.Forms.Padding(4)
  foreach ($c in $Controls) { [void]$p.Controls.Add($c) }
  return $p
}

function New-UiLabel {
  param([string] $Text, [bool] $Bold = $false)
  $l = New-Object Windows.Forms.Label
  $l.Text = $Text
  $l.AutoSize = $true
  $l.Margin = New-Object Windows.Forms.Padding(6, 8, 12, 4)
  if ($Bold) { $l.Font = New-Object Drawing.Font($l.Font, [Drawing.FontStyle]::Bold) }
  return $l
}

function New-UiGrid {
  $g = New-Object Windows.Forms.DataGridView
  $g.Dock = 'Fill'
  $g.ReadOnly = $true
  $g.AllowUserToAddRows = $false
  $g.AllowUserToDeleteRows = $false
  $g.SelectionMode = 'FullRowSelect'
  $g.MultiSelect = $false
  $g.RowHeadersVisible = $false
  $g.AutoSizeColumnsMode = 'AllCells'
  $g.BackgroundColor = [Drawing.SystemColors]::Window
  return $g
}

function ConvertTo-SecureText {
  param([string] $Text)
  $s = New-Object Security.SecureString
  foreach ($c in $Text.ToCharArray()) { $s.AppendChar($c) }
  $s.MakeReadOnly()
  return $s
}

# Generic modal dialog. Fields: @{ Key; Label; Kind = text|password|list|check; Items; Value }
# Returns a hashtable (list -> selected index, password -> SecureString) or $null.
function Show-UiDialog {
  param([string] $Title, [object[]] $Fields, [string] $Intro)
  $f = New-Object Windows.Forms.Form
  $f.Text = $Title
  $f.FormBorderStyle = 'FixedDialog'
  $f.StartPosition = 'CenterParent'
  $f.MaximizeBox = $false
  $f.MinimizeBox = $false
  $f.AutoSize = $true
  $f.AutoSizeMode = 'GrowAndShrink'
  $f.Padding = New-Object Windows.Forms.Padding(10)

  $t = New-Object Windows.Forms.TableLayoutPanel
  $t.ColumnCount = 2
  $t.AutoSize = $true
  $t.Dock = 'Fill'
  if ($Intro) {
    $l = New-UiLabel $Intro
    $l.MaximumSize = New-Object Drawing.Size(520, 0)
    $t.Controls.Add($l, 0, 0)
    $t.SetColumnSpan($l, 2)
  }
  $controls = @{}
  foreach ($field in $Fields) {
    $row = $t.RowCount
    $t.RowCount++
    switch ($field.Kind) {
      'check' {
        $c = New-Object Windows.Forms.CheckBox
        $c.Text = $field.Label
        $c.AutoSize = $true
        $c.Checked = [bool]$field.Value
        $t.Controls.Add($c, 1, $row)
      }
      'list' {
        $t.Controls.Add((New-UiLabel $field.Label), 0, $row)
        $c = New-Object Windows.Forms.ComboBox
        $c.DropDownStyle = 'DropDownList'
        $c.Width = 520
        foreach ($item in $field.Items) { [void]$c.Items.Add([string]$item) }
        if ($c.Items.Count) { $c.SelectedIndex = $(if ($null -ne $field.Value) { [int]$field.Value } else { 0 }) }
        $t.Controls.Add($c, 1, $row)
      }
      default {
        $t.Controls.Add((New-UiLabel $field.Label), 0, $row)
        $c = New-Object Windows.Forms.TextBox
        $c.Width = 320
        if ($field.Kind -eq 'password') { $c.UseSystemPasswordChar = $true }
        elseif ($null -ne $field.Value) { $c.Text = [string]$field.Value }
        $t.Controls.Add($c, 1, $row)
      }
    }
    $controls[$field.Key] = $c
  }
  $ok = New-Object Windows.Forms.Button
  $ok.Text = 'OK'
  $ok.DialogResult = 'OK'
  $cancel = New-Object Windows.Forms.Button
  $cancel.Text = 'Cancel'
  $cancel.DialogResult = 'Cancel'
  $buttons = New-UiFlow @($cancel, $ok)
  $buttons.FlowDirection = 'RightToLeft'
  $buttons.Dock = 'Fill'
  $t.RowCount++
  $t.Controls.Add($buttons, 0, $t.RowCount - 1)
  $t.SetColumnSpan($buttons, 2)
  $f.Controls.Add($t)
  $f.AcceptButton = $ok
  $f.CancelButton = $cancel

  try {
    if ($f.ShowDialog($Script:Ui.Form) -ne 'OK') { return $null }
    $result = @{}
    foreach ($field in $Fields) {
      $c = $controls[$field.Key]
      switch ($field.Kind) {
        'check' { $result[$field.Key] = $c.Checked }
        'list' { $result[$field.Key] = $c.SelectedIndex }
        'password' { $result[$field.Key] = ConvertTo-SecureText $c.Text; $c.Text = '' }
        default { $result[$field.Key] = $c.Text.Trim() }
      }
    }
    return $result
  } finally { $f.Dispose() }
}

# ---------------------------------------------------------------------------
# Long actions in a child process
# ---------------------------------------------------------------------------

function Test-UiBusy { return ($Script:Ui.Job -and -not $Script:Ui.Job.HasExited) }

# Actions wait in a queue and run one at a time: two at once could both
# write config.json or fight over the same session. The queue lives only as
# long as the window: closing it drops what has not started.
function Start-UiAction {
  param([string] $Label, [string[]] $Arguments)
  [void]$Script:Ui.Queue.Add(@{ Label = $Label; Arguments = $Arguments })
  $Script:Ui.Tabs.SelectedTab = $Script:Ui.LogTab
  Update-UiJob
}

function Start-UiNextJob {
  $next = $Script:Ui.Queue[0]
  $Script:Ui.Queue.RemoveAt(0)
  $main = Join-Path $Script:Bss.Root 'BSS-Manager.ps1'
  $quoted = @($next.Arguments | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } })
  $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $main)) + $quoted + @('-Unattended')
  $Script:Ui.Job = Start-Process -FilePath 'powershell.exe' -ArgumentList $all -WindowStyle Hidden -PassThru
  $Script:Ui.JobLabel = $next.Label
}

function Update-UiJob {
  if (-not (Test-UiBusy)) {
    if ($Script:Ui.Job) {
      $code = $Script:Ui.Job.ExitCode
      $Script:Ui.LastResult = "Finished: $($Script:Ui.JobLabel) $(if ($code) { "(error, code $code - see the log)" } else { '(ok)' })"
      $Script:Ui.Job = $null
      Update-UiAccounts -Force
    }
    if ($Script:Ui.Queue.Count) { Start-UiNextJob }
  }
  if (Test-UiBusy) {
    $waiting = $(if ($Script:Ui.Queue.Count) { " ($($Script:Ui.Queue.Count) waiting)" } else { '' })
    $Script:Ui.JobStatus.Text = "Running: $($Script:Ui.JobLabel)...$waiting"
  } elseif ($Script:Ui.LastResult) {
    $Script:Ui.JobStatus.Text = $Script:Ui.LastResult
  }
}

# ---------------------------------------------------------------------------
# Refresh
# ---------------------------------------------------------------------------

function Set-UiStatusLabel {
  param($Label, [string] $Text, [string] $Level)
  $Label.Text = $Text
  $Label.ForeColor = switch ($Level) { 'ok' { [Drawing.Color]::DarkGreen } 'warn' { [Drawing.Color]::DarkOrange } 'bad' { [Drawing.Color]::Firebrick } default { [Drawing.SystemColors]::ControlText } }
}

function Update-UiHeader {
  param([switch] $Force)
  $cfg = Get-BssConfig
  if (Test-RobloxWindowOpen) { Set-UiStatusLabel $Script:Ui.SystemLabel 'System: Roblox update in progress' 'warn' }
  elseif ($cfg.Running) { Set-UiStatusLabel $Script:Ui.SystemLabel 'System: STARTED' 'ok' }
  else { Set-UiStatusLabel $Script:Ui.SystemLabel 'System: STOPPED' 'normal' }
  if ($Force -or -not $Script:Ui.WrapperAt -or ((Get-Date) - $Script:Ui.WrapperAt).TotalSeconds -ge $Script:UiWrapperRefreshSec) {
    $Script:Ui.Wrapper = Get-WrapperState $cfg
    $Script:Ui.WrapperAt = Get-Date
  }
  $w = $Script:Ui.Wrapper
  if ($w.Healthy) { Set-UiStatusLabel $Script:Ui.WrapperLabel "RDP Wrapper: OK (termsrv $($w.TermsrvVersion))" 'ok' }
  else {
    $why = @()
    if (-not $w.IniSupports) { $why += 'version not supported' }
    if (-not $w.IniCrlf) { $why += 'LF line endings' }
    if (-not $w.ServiceDllOk) { $why += 'service without rdpwrap.dll' }
    if (-not $w.Listening) { $why += 'not listening' }
    Set-UiStatusLabel $Script:Ui.WrapperLabel "RDP Wrapper: NEEDS REPAIR ($($why -join ', '))" 'bad'
  }

  # Same vocabulary as the status page: what the owner chose (disabled)
  # is told apart from what went wrong (crashed, hung).
  $task = Get-SupervisorTask
  $sup = Get-SupervisorStatus
  if (-not $task) { Set-UiStatusLabel $Script:Ui.SupervisorLabel 'Supervisor: not installed' 'warn' }
  elseif ($task.State -eq 'Disabled') { Set-UiStatusLabel $Script:Ui.SupervisorLabel 'Supervisor: disabled (on purpose)' 'warn' }
  elseif ($sup -and $sup.Alive) { Set-UiStatusLabel $Script:Ui.SupervisorLabel "Supervisor: active ($($sup.AgeSec) s ago)" 'ok' }
  elseif ($task.State -eq 'Running') { Set-UiStatusLabel $Script:Ui.SupervisorLabel 'Supervisor: HUNG (no recent pass)' 'bad' }
  else { Set-UiStatusLabel $Script:Ui.SupervisorLabel 'Supervisor: CRASHED (stopped without being asked)' 'bad' }

  $auto = Get-AutoLogonState
  if ($auto.Enabled -and $auto.SecretStored) { Set-UiStatusLabel $Script:Ui.AutoLogonLabel "Auto sign-in: $($auto.User)" 'ok' }
  elseif ($auto.Enabled) { Set-UiStatusLabel $Script:Ui.AutoLogonLabel 'Auto sign-in: no password' 'bad' }
  else { Set-UiStatusLabel $Script:Ui.AutoLogonLabel 'Auto sign-in: disabled' 'normal' }
}

function Set-UiGridRows {
  param($Grid, [object[]] $Rows, [string] $Key, [switch] $Force)
  # Rebinding resets the scroll position, so skip it when nothing changed.
  $signature = ($Rows | ConvertTo-Json -Compress -Depth 2)
  if (-not $Force -and $Grid.Tag -eq $signature) { return }
  $Grid.Tag = $signature
  $selected = $null
  if ($Grid.CurrentRow) { $selected = [string]$Grid.CurrentRow.Cells[$Key].Value }
  $table = New-Object Data.DataTable
  if ($Rows.Count) {
    foreach ($p in $Rows[0].PSObject.Properties) { [void]$table.Columns.Add($p.Name) }
    foreach ($r in $Rows) {
      $row = $table.NewRow()
      foreach ($p in $r.PSObject.Properties) { $row[$p.Name] = [string]$p.Value }
      $table.Rows.Add($row)
    }
  }
  $Grid.DataSource = $table
  foreach ($row in $Grid.Rows) {
    if ($selected -and [string]$row.Cells[$Key].Value -eq $selected) { $Grid.CurrentCell = $row.Cells[0] }
  }
}

function Set-UiAccountColors {
  foreach ($row in $Script:Ui.AccountsGrid.Rows) {
    $state = [string]$row.Cells['State'].Value
    $color = [Drawing.Color]::White
    if ([string]$row.Cells['Paused'].Value -eq 'yes' -or [string]$row.Cells['Active'].Value -eq 'no') { $color = [Drawing.Color]::Gainsboro }
    elseif ([string]$row.Cells['Natro'].Value -eq 'running') { $color = [Drawing.Color]::Honeydew }
    elseif ($state -like 'not ready*' -or [string]$row.Cells['Session'].Value -like 'DISCONNECTED*') { $color = [Drawing.Color]::MistyRose }
    $row.DefaultCellStyle.BackColor = $color
  }
}

function Update-UiAccounts {
  param([switch] $Force)
  $cfg = Get-BssConfig
  # The window writes config.json, so it records first sign-ins as it sees them.
  [void](Update-LearnedRobloxNames $cfg)
  $rows = @(Get-AccountRows $cfg (Get-SupervisorStatus))
  Set-UiGridRows $Script:Ui.AccountsGrid $rows 'Account' -Force:$Force
}

function Update-UiMacros {
  $cfg = Get-BssConfig
  $rows = @(Find-Macros $cfg | ForEach-Object {
      $path = $_.Path
      [pscustomobject]@{
        Macro    = $_.Name
        Version  = $_.Version
        Type     = $(if ($_.IsGit) { 'Cursed (git)' } else { 'old version' })
        Branch   = $_.Branch
        Accounts = (@($cfg.Accounts | Where-Object { $_.MacroPath -eq $path } | ForEach-Object { $_.Name }) -join ', ')
        'Last used' = $_.LastUsed.ToString('dd.MM.yyyy HH:mm')
        Folder   = $path
      }
    })
  Set-UiGridRows $Script:Ui.MacrosGrid $rows 'Folder' -Force
}

function Update-UiLog {
  $file = $Script:Bss.LogFile
  if (-not (Test-Path $file)) { return }
  $length = (Get-Item $file).Length
  if ($Script:Ui.LogLength -eq $length) { return }
  $Script:Ui.LogLength = $length
  $Script:Ui.LogBox.Lines = @(Get-Content $file -Tail 400 -Encoding UTF8)
  $Script:Ui.LogBox.SelectionStart = $Script:Ui.LogBox.TextLength
  $Script:Ui.LogBox.ScrollToCaret()
}

function Update-UiSettings {
  $cfg = Get-BssConfig
  foreach ($key in $Script:Ui.Settings.Keys) {
    $c = $Script:Ui.Settings[$key]
    if ($c -is [Windows.Forms.NumericUpDown]) { $c.Value = [decimal][Math]::Min([Math]::Max([int]$cfg.$key, $c.Minimum), $c.Maximum) }
    elseif ($c -is [Windows.Forms.CheckBox]) { $c.Checked = [bool]$cfg.$key }
    else { $c.Text = [string]$cfg.$key }
  }
}

# ---------------------------------------------------------------------------
# Account actions
# ---------------------------------------------------------------------------

function Get-UiSelectedName {
  $row = $Script:Ui.AccountsGrid.CurrentRow
  if (-not $row) { Show-UiInfo 'Choose an account in the table first.'; return $null }
  return ([string]$row.Cells['Account'].Value) -replace ' \(my session\)$', ''
}

function Set-UiLocalAccount {
  $cfg = Get-BssConfig
  $current = $cfg.Accounts | Where-Object { $_.Local } | Select-Object -First 1
  $candidates = @($cfg.Accounts | Where-Object { -not $_.Local })
  $labels = @('(none: my session runs no macro)') + @($candidates | ForEach-Object {
      '{0}  -  Windows account {1}, macro {2}' -f $(if ($_.Roblox) { $_.Roblox } elseif ($_.Role) { $_.Role } else { '?' }), $_.Name, $(if ($_.MacroPath) { Split-Path $_.MacroPath -Leaf } else { '(none)' }) })
  $intro = "The chosen account runs in YOUR session ($env:USERNAME), without an RDP session: one session less. Its current Windows account is excluded and its session closed (not deleted). " +
    "Your own Roblox must be signed in with this account, and its settings are the ones Natro requires. Natro takes your session's keyboard and mouse while it runs. " +
    "Current: $(if ($current) { "$($current.Roblox) ($(Split-Path $current.MacroPath -Leaf))" } else { 'none' })."
  $r = Show-UiDialog 'Local account (my session)' @(@{ Key = 'pick'; Label = 'Account'; Kind = 'list'; Items = $labels; Value = 0 }) $intro
  if (-not $r -or $r.pick -lt 0) { return }
  $source = $(if ($r.pick -eq 0) { '' } else { $candidates[$r.pick - 1].Name })
  if ($source -and -not (Confirm-Ui "Run $($candidates[$r.pick - 1].Roblox) in your session? Its RDP session ($source) will be closed.")) { return }
  Set-LocalAccount (Get-BssConfig) $source
  Update-UiAccounts -Force
}

function Invoke-UiAccountAction {
  param([string] $Action, [string] $Verb, [bool] $Ask)
  $name = Get-UiSelectedName
  if (-not $name) { return }
  if ($Ask -and -not (Confirm-Ui "$Verb $name?")) { return }
  Start-UiAction "$Verb $name" @('-Action', $Action, '-Account', $name)
}

function Switch-UiAccountFlag {
  param([string] $Flag)
  $name = Get-UiSelectedName
  if (-not $name) { return }
  $cfg = Get-BssConfig
  $a = Get-AccountByName $cfg $name
  Set-AccountFlag $cfg $name $Flag (-not $a.$Flag)
  Update-UiAccounts -Force
}

function Set-UiAccountMacro {
  $name = Get-UiSelectedName
  if (-not $name) { return }
  $cfg = Get-BssConfig
  $macros = @(Find-Macros $cfg)
  $labels = @('(no macro)') + @($macros | ForEach-Object { Format-MacroLabel $_ })
  $current = 0
  $a = Get-AccountByName $cfg $name
  for ($i = 0; $i -lt $macros.Count; $i++) { if ($macros[$i].Path -eq $a.MacroPath) { $current = $i + 1 } }
  $r = Show-UiDialog "Macro of $name" @(@{ Key = 'macro'; Label = 'Macro'; Kind = 'list'; Items = $labels; Value = $current }) 'Natro starts this macro in the account''s session, with the macro already started.'
  if (-not $r -or $r.macro -lt 0) { return }
  $path = $(if ($r.macro -eq 0) { '' } else { $macros[$r.macro - 1].Path })
  $other = $cfg.Accounts | Where-Object { $path -and $_.Name -ne $name -and $_.MacroPath -eq $path } | Select-Object -First 1
  if ($other -and -not (Confirm-Ui "$($other.Name) already uses this macro. Assign it anyway?")) { return }
  Set-AccountMacroPath $cfg $name $path
  if ($path -and -not $macros[$r.macro - 1].IsGit) { Show-UiInfo 'This macro is an old version. ''Add Roblox accounts'' creates a clean macro on your version from this folder.' }
  Update-UiAccounts -Force
}

# Returns $true when a common password is now set.
function Set-UiCommonPassword {
  $r = Show-UiDialog 'Password of the macro accounts' @(
    @{ Key = 'pwd'; Label = 'Password'; Kind = 'password' },
    @{ Key = 'pwd2'; Label = 'Confirm'; Kind = 'password' }
  ) 'One password for every macro Windows account, to remember: Windows sometimes asks for it. It is kept in Credential Manager to open the sessions without typing anything.'
  if (-not $r) { return $false }
  if ($r.pwd.Length -eq 0) { throw 'Empty password.' }
  if (-not (Test-SecureEqual $r.pwd $r.pwd2)) { throw 'The two passwords do not match.' }
  Set-CommonPassword $r.pwd
  return $true
}

function Reset-UiAccountPassword {
  $name = Get-UiSelectedName
  if (-not $name) { return }
  if (-not (Test-CommonPassword) -and -not (Set-UiCommonPassword)) { return }
  if (-not (Confirm-Ui "Give the Windows account $name the common password of the macro accounts?")) { return }
  Reset-AccountPassword (Get-BssConfig) $name
  Update-UiAccounts -Force
}

function Set-UiAccountNames {
  $name = Get-UiSelectedName
  if (-not $name) { return }
  $a = Get-AccountByName (Get-BssConfig) $name
  $r = Show-UiDialog "Roblox account of $name" @(
    @{ Key = 'roblox'; Label = 'Roblox account (empty = learnt at the next sign-in)'; Kind = 'text'; Value = $a.Roblox },
    @{ Key = 'role'; Label = 'Role (optional)'; Kind = 'text'; Value = $a.Role }
  ) 'The Roblox account is checked at every sign-in: another account blocks the macro. The role is your label (e.g. GuidingALT2); a macro named after it is accepted.'
  if (-not $r) { return }
  Set-AccountRobloxNames (Get-BssConfig) $name $r.roblox $r.role
  Update-UiAccounts -Force
}

function Open-UiSession {
  $name = Get-UiSelectedName
  if (-not $name) { return }
  $cfg = Get-BssConfig
  # Works whatever the readiness: it is how the owner signs in to Roblox.
  if (-not (Open-AccountSession $cfg (Get-AccountByName $cfg $name))) { Show-UiInfo "The connection window of $name is already open." }
}

function Resume-UiSetup {
  $name = Get-UiSelectedName
  if (-not $name) { return }
  $a = Get-AccountByName (Get-BssConfig) $name
  if (-not $a.Roblox) { Show-UiInfo 'This account has no Roblox account: add a Roblox account instead.'; return }
  $arguments = @('-Action', 'AddRoblox', '-Roblox', $a.Roblox, '-WindowsUser', $a.Name)
  if ($a.MacroPath) { $arguments += @('-Path', $a.MacroPath) }
  Start-UiAction "Preparing $($a.Roblox)" $arguments
}

# The add-accounts assistant: one row per Roblox account the folder names
# suggest, editable, with the folder to start from.
function Show-UiAddRobloxWizard {
  $cfg = Get-BssConfig
  $suggestions = @(Get-RobloxAccountSuggestions $cfg | Where-Object { -not $_.Configured })
  $allMacros = @(Find-Macros $cfg)
  $fresh = '(fresh settings)'

  $f = New-Object Windows.Forms.Form
  $f.Text = 'Add Roblox accounts'
  $f.Size = New-Object Drawing.Size(1000, 560)
  $f.StartPosition = 'CenterParent'
  $f.Font = $Script:Ui.Form.Font

  $intro = New-UiLabel ("Tick the accounts to prepare and choose the base folder. 'Roblox account' is optional: left empty, " +
    "it is learnt at your first sign-in. Type it only if you know it for sure. The Windows account and the macro take " +
    "the Roblox account's name if typed, else the role's. For each one: Windows account (common password), clean macro on " +
    "$($cfg.DefaultBranch) with the base folder's settings, old folder moved to $($Script:ArchiveFolderName), session opened, " +
    "Roblox installed. You then only sign in to Roblox in each session.")
  $intro.MaximumSize = New-Object Drawing.Size(950, 0)
  $intro.Dock = 'Top'

  $grid = New-Object Windows.Forms.DataGridView
  $grid.Dock = 'Fill'
  $grid.AllowUserToAddRows = $false
  $grid.RowHeadersVisible = $false
  $grid.AutoSizeColumnsMode = 'Fill'
  $check = New-Object Windows.Forms.DataGridViewCheckBoxColumn
  $check.HeaderText = 'Add'
  $check.FillWeight = 12
  $roleCol = New-Object Windows.Forms.DataGridViewTextBoxColumn
  $roleCol.HeaderText = 'Role / folder name'
  $roleCol.FillWeight = 30
  $robloxCol = New-Object Windows.Forms.DataGridViewTextBoxColumn
  $robloxCol.HeaderText = 'Roblox account (empty = learnt)'
  $robloxCol.FillWeight = 30
  $baseCol = New-Object Windows.Forms.DataGridViewComboBoxColumn
  $baseCol.HeaderText = 'Base macro'
  $baseCol.FillWeight = 90
  [void]$grid.Columns.AddRange([Windows.Forms.DataGridViewColumn[]]@($check, $roleCol, $robloxCol, $baseCol))

  $paths = @{}
  $addRow = {
    param([string] $Roblox, [object[]] $Candidates)
    $i = $grid.Rows.Add()
    $row = $grid.Rows[$i]
    # The folder name may be a role (GuidingALT1), so the Roblox account is
    # left empty and learnt at the first sign-in unless the owner types it:
    # a wrong guess there would block the macro.
    $row.Cells[0].Value = [bool]$Roblox
    $row.Cells[1].Value = $Roblox
    $row.Cells[2].Value = ''
    $cell = $row.Cells[3]
    foreach ($m in $Candidates) {
      $label = Format-MacroLabel $m
      $paths[$label] = $m.Path
      [void]$cell.Items.Add($label)
    }
    [void]$cell.Items.Add($fresh)
    $cell.Value = $cell.Items[0]
  }
  foreach ($s in $suggestions) { & $addRow $s.Roblox $s.Candidates }

  $ok = New-Object Windows.Forms.Button
  $ok.Text = 'Prepare the ticked accounts'
  $ok.AutoSize = $true
  $ok.DialogResult = 'OK'
  $cancel = New-Object Windows.Forms.Button
  $cancel.Text = 'Cancel'
  $cancel.AutoSize = $true
  $cancel.DialogResult = 'Cancel'
  $more = New-Object Windows.Forms.Button
  $more.Text = 'Add a row'
  $more.AutoSize = $true
  $more.Tag = @{ AddRow = $addRow; Macros = $allMacros }
  $more.Add_Click({ param($sender) & $sender.Tag.AddRow '' $sender.Tag.Macros })
  $buttons = New-UiFlow @($cancel, $ok, $more) 'Bottom'
  $buttons.FlowDirection = 'RightToLeft'

  $f.Controls.Add($grid)
  $f.Controls.Add($intro)
  $f.Controls.Add($buttons)
  $f.AcceptButton = $ok
  $f.CancelButton = $cancel
  if ($Script:Ui.SnapshotDir) {
    $f.Add_Shown({ param($sender) Save-UiFormImage $sender (Join-Path $Script:Ui.SnapshotDir '9-assistant.png'); $sender.Close() })
  }

  try {
    if ($f.ShowDialog($Script:Ui.Form) -ne 'OK') { return }
    $grid.EndEdit()
    $jobs = @()
    foreach ($row in $grid.Rows) {
      if (-not [bool]$row.Cells[0].Value) { continue }
      $role = ([string]$row.Cells[1].Value).Trim()
      $roblox = ([string]$row.Cells[2].Value).Trim()
      $label = $(if ($roblox) { $roblox } else { $role })
      foreach ($n in @($role, $roblox) | Where-Object { $_ }) {
        if ($n -notmatch '^[A-Za-z0-9_]{3,20}$') { throw "Invalid name: '$n' (3 to 20 letters, digits or _)." }
      }
      if (-not $label) { throw 'A ticked row has neither a role nor a Roblox account.' }
      if (-not (Test-ValidAccountName $label)) { throw "Invalid Windows account name: '$label'." }
      $arguments = @('-Action', 'AddRoblox')
      if ($roblox) { $arguments += @('-Roblox', $roblox) }
      if ($role -and $role -ne $roblox) { $arguments += @('-Role', $role) }
      $base = [string]$row.Cells[3].Value
      if ($base -and $base -ne $fresh) { $arguments += @('-Path', $paths[$base]) }
      $jobs += @{ Label = "Preparing $label"; Arguments = $arguments }
    }
    if (-not $jobs.Count) { return }
    if (-not (Test-CommonPassword) -and -not (Set-UiCommonPassword)) { return }
    if (-not (Confirm-Ui "Prepare $($jobs.Count) Roblox account(s), one after the other? Allow a few minutes per account (creation, copy, session, Roblox install).")) { return }
    foreach ($job in $jobs) { Start-UiAction $job.Label $job.Arguments }
  } finally { $f.Dispose() }
}

function Remove-UiAccount {
  $name = Get-UiSelectedName
  if (-not $name) { return }
  $r = Show-UiDialog "Remove $name" @(
    @{ Key = 'delete'; Label = "Also delete the Windows account $name (permanent)"; Kind = 'check'; Value = $false }
  ) "$name will be removed from BSS Manager and its session closed. Its folder C:\Users\$name stays on the disk."
  if (-not $r) { return }
  if ($r.delete -and -not (Confirm-Ui "PERMANENTLY delete the Windows account $name?")) { return }
  Remove-ManagedAccount (Get-BssConfig) $name $r.delete
  Update-UiAccounts -Force
}

# ---------------------------------------------------------------------------
# Macro actions
# ---------------------------------------------------------------------------

function Get-UiSelectedMacro {
  $row = $Script:Ui.MacrosGrid.CurrentRow
  if (-not $row) { Show-UiInfo 'Choose a macro in the table first.'; return $null }
  return [pscustomobject]@{ Path = [string]$row.Cells['Folder'].Value; Name = [string]$row.Cells['Macro'].Value; IsGit = ([string]$row.Cells['Type'].Value -like 'Cursed*'); Branch = [string]$row.Cells['Branch'].Value }
}

function Set-UiMacroBranch {
  $m = Get-UiSelectedMacro
  if (-not $m) { return }
  if (-not $m.IsGit) { Show-UiInfo 'Old version: ''Add Roblox accounts'' creates a clean copy of it on your version.'; return }
  $Script:Ui.Form.Cursor = 'WaitCursor'
  try { $branches = @(Get-RemoteBranches $m.Path) } finally { $Script:Ui.Form.Cursor = 'Default' }
  if (-not $branches.Count) { throw 'Cannot list the branches (network?).' }
  $r = Show-UiDialog "Branch of $($m.Name)" @(@{ Key = 'b'; Label = 'Branch'; Kind = 'list'; Items = $branches; Value = [Math]::Max(0, [array]::IndexOf($branches, $m.Branch)) }) 'The macro is stopped if it runs, updated on this branch, then restarted. Its settings do not change.'
  if (-not $r -or $r.b -lt 0) { return }
  Start-UiAction "Branch $($branches[$r.b]) for $($m.Name)" @('-Action', 'SetBranch', '-Path', $m.Path, '-Branch', $branches[$r.b])
}

function New-UiMacro {
  $cfg = Get-BssConfig
  $macros = @(Find-Macros $cfg)
  $labels = @('(fresh settings)') + @($macros | ForEach-Object { Format-MacroLabel $_ })
  $r = Show-UiDialog 'New macro' @(
    @{ Key = 'name'; Label = 'Account name'; Kind = 'text' },
    @{ Key = 'from'; Label = 'Copy the settings of'; Kind = 'list'; Items = $labels; Value = 0 }
  ) "Creates Natro_Macro_<name> in $($cfg.MacroRoot), on $($cfg.DefaultBranch), like the others. The macro whose settings are copied is not changed. To give it a Windows and Roblox account, then use 'Add Roblox accounts' or 'Change the macro'."
  if (-not $r -or -not $r.name) { return }
  if ($r.name -notmatch '^[A-Za-z0-9_]{3,20}$') { throw 'Invalid name (3 to 20 letters, digits or _).' }
  if (Test-Path (Get-RobloxMacroPath $cfg $r.name)) { throw "Natro_Macro_$($r.name) already exists." }
  $arguments = @('-Action', 'NewMacro', '-Roblox', $r.name)
  if ($r.from -gt 0) { $arguments += @('-Path', $macros[$r.from - 1].Path) }
  Start-UiAction "New macro $($r.name)" $arguments
}

function Update-UiMacro {
  $m = Get-UiSelectedMacro
  if (-not $m) { return }
  if (-not $m.IsGit) { Show-UiInfo 'Old version: ''Add Roblox accounts'' creates a clean copy of it on your version.'; return }
  if (-not (Confirm-Ui "Update $($m.Name)? It is stopped during the update, then restarted if its account runs.")) { return }
  Start-UiAction "Updating $($m.Name)" @('-Action', 'UpdateMacros', '-Path', $m.Path)
}

# ---------------------------------------------------------------------------
# Settings actions
# ---------------------------------------------------------------------------

function Save-UiSettings {
  $cfg = Get-BssConfig
  foreach ($key in $Script:Ui.Settings.Keys) {
    $c = $Script:Ui.Settings[$key]
    if ($c -is [Windows.Forms.NumericUpDown]) { $cfg.$key = [int]$c.Value }
    elseif ($c -is [Windows.Forms.CheckBox]) { $cfg.$key = $c.Checked }
    else { $cfg.$key = $c.Text.Trim() }
  }
  Save-BssConfig $cfg
  Write-Log 'Settings saved.' OK
  Show-UiInfo 'Settings saved. The supervisor applies them at its next check. The inbox needs the installation to be run again.'
}

function Enable-UiAutoLogon {
  $r = Show-UiDialog 'Windows automatic sign-in' @(
    @{ Key = 'user'; Label = 'Windows account'; Kind = 'text'; Value = $env:USERNAME },
    @{ Key = 'pwd'; Label = 'Password'; Kind = 'password' },
    @{ Key = 'pwd2'; Label = 'Confirm'; Kind = 'password' }
  ) 'Windows opens this session by itself at startup, then the supervisor restarts everything. For an account linked to Microsoft: the Microsoft account password, not the PIN. It is stored encrypted by Windows (LSA secret), and the ''Windows Hello only'' sign-in is turned off.'
  if (-not $r) { return }
  if (-not (Test-SecureEqual $r.pwd $r.pwd2)) { throw 'The two passwords do not match.' }
  Enable-AutoLogon $r.user $r.pwd
  Update-UiHeader -Force
}

# ---------------------------------------------------------------------------
# Window
# ---------------------------------------------------------------------------

function New-UiAccountsTab {
  $tab = New-Object Windows.Forms.TabPage
  $tab.Text = 'Roblox accounts'
  $Script:Ui.AccountsGrid = New-UiGrid
  $Script:Ui.AccountsGrid.Add_DataBindingComplete({ Set-UiAccountColors })
  $buttons = New-UiFlow @(
    (New-UiButton 'Add Roblox accounts...' { Show-UiAddRobloxWizard }),
    (New-UiButton 'Local account (my session)...' { Set-UiLocalAccount }),
    (New-UiButton 'Start' { Invoke-UiAccountAction 'Start' 'Start' $false }),
    (New-UiButton 'Stop' { Invoke-UiAccountAction 'Stop' 'Stop' $true }),
    (New-UiButton 'Restart the macro' { Invoke-UiAccountAction 'Restart' 'Restart the macro of' $true }),
    (New-UiButton 'Open the session' { Open-UiSession }),
    (New-UiButton 'Open Roblox' { Invoke-UiAccountAction 'OpenRoblox' 'Open Roblox for' $false }),
    (New-UiButton 'Roblox settings' { Invoke-UiAccountAction 'RobloxSettings' 'Apply the Roblox settings (lowest graphics, fullscreen, no haptics, Natro settings; Roblox closes for a moment and Natro reopens it) to' $true }),
    (New-UiButton 'Resume the preparation' { Resume-UiSetup }),
    (New-UiButton 'Pause / resume' { Switch-UiAccountFlag 'Paused' }),
    (New-UiButton 'Active / inactive' { Switch-UiAccountFlag 'Enabled' }),
    (New-UiButton 'Change the macro...' { Set-UiAccountMacro }),
    (New-UiButton 'Roblox account / role...' { Set-UiAccountNames }),
    (New-UiButton 'Common password' { Reset-UiAccountPassword }),
    (New-UiButton 'Remove...' { Remove-UiAccount })
  ) 'Bottom'
  $tab.Controls.Add($Script:Ui.AccountsGrid)
  $tab.Controls.Add($buttons)
  return $tab
}

function New-UiMacrosTab {
  $tab = New-Object Windows.Forms.TabPage
  $tab.Text = 'Macros'
  $Script:Ui.MacrosGrid = New-UiGrid
  $buttons = New-UiFlow @(
    (New-UiButton 'New macro...' { New-UiMacro }),
    (New-UiButton 'Refresh' { Update-UiMacros }),
    (New-UiButton 'Switch branch...' { Set-UiMacroBranch }),
    (New-UiButton 'Update' { Update-UiMacro }),
    (New-UiButton 'Open the folder' { $m = Get-UiSelectedMacro; if ($m) { Start-Process explorer.exe $m.Path } })
  ) 'Bottom'
  $tab.Controls.Add($Script:Ui.MacrosGrid)
  $tab.Controls.Add($buttons)
  return $tab
}

function New-UiGroup {
  param([string] $Title, [object[]] $Controls)
  $g = New-Object Windows.Forms.GroupBox
  $g.Text = $Title
  $g.AutoSize = $true
  $g.Dock = 'Top'
  $g.Padding = New-Object Windows.Forms.Padding(8)
  $flow = New-UiFlow $Controls 'Fill'
  $g.Controls.Add($flow)
  return $g
}

function New-UiNumber {
  param([int] $Min, [int] $Max)
  $n = New-Object Windows.Forms.NumericUpDown
  $n.Minimum = $Min
  $n.Maximum = $Max
  $n.Width = 80
  return $n
}

function New-UiSettingsTab {
  $tab = New-Object Windows.Forms.TabPage
  $tab.Text = 'Settings'
  $tab.AutoScroll = $true

  $Script:Ui.Settings = [ordered]@{
    SessionWidth            = New-UiNumber 640 3840
    SessionHeight           = New-UiNumber 480 2160
    DelayBetweenSessionsSec = New-UiNumber 0 600
    NatroStartDelaySec      = New-UiNumber 0 600
    SupervisorIntervalSec   = New-UiNumber 15 3600
    RestartGraceSec         = New-UiNumber 30 3600
    MacroRoot               = (New-Object Windows.Forms.TextBox)
    DefaultBranch           = (New-Object Windows.Forms.TextBox)
    UpdateMacrosOnStart     = (New-Object Windows.Forms.CheckBox)
    InboxEnabled            = (New-Object Windows.Forms.CheckBox)
    CloseOwnerRobloxForUpdates = (New-Object Windows.Forms.CheckBox)
    StatusServerEnabled     = (New-Object Windows.Forms.CheckBox)
    StatusPort              = New-UiNumber 1024 65535
  }
  $labels = [ordered]@{
    SessionWidth            = 'Session width'
    SessionHeight           = 'Session height'
    DelayBetweenSessionsSec = 'Seconds between two sessions'
    NatroStartDelaySec      = 'Seconds before starting Natro'
    SupervisorIntervalSec   = 'Seconds between two checks'
    RestartGraceSec         = 'Seconds before restarting'
    MacroRoot               = 'Macro folder'
    DefaultBranch           = 'Default branch'
    UpdateMacrosOnStart     = 'Update the macros at every Start'
    InboxEnabled            = 'Accept restart requests (fleet)'
    CloseOwnerRobloxForUpdates = 'Also close MY Roblox to update Roblox in the macro accounts'
    StatusServerEnabled     = 'Status page on the local network (read-only)'
    StatusPort              = 'Status page port'
  }
  $grid = New-Object Windows.Forms.TableLayoutPanel
  $grid.ColumnCount = 2
  $grid.AutoSize = $true
  foreach ($key in $Script:Ui.Settings.Keys) {
    $c = $Script:Ui.Settings[$key]
    $row = $grid.RowCount
    $grid.RowCount++
    if ($c -is [Windows.Forms.CheckBox]) { $c.Text = $labels[$key]; $c.AutoSize = $true; $grid.Controls.Add($c, 1, $row) }
    else {
      if ($c -is [Windows.Forms.TextBox]) { $c.Width = 360 }
      $grid.Controls.Add((New-UiLabel $labels[$key]), 0, $row)
      $grid.Controls.Add($c, 1, $row)
    }
  }
  $grid.RowCount++
  $grid.Controls.Add((New-UiButton 'Save the settings' { Save-UiSettings }), 1, $grid.RowCount - 1)

  $Script:Ui.WrapperDetail = New-UiLabel ''
  # Addresses a watchdog or the fleet can read the status page at.
  $cfgNow = Get-BssConfig
  $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object { $_.IPAddress })
  $statusUrls = @($ips | ForEach-Object { "http://${_}:$($cfgNow.StatusPort)/status" }) -join '   '
  $statusInfo = New-UiLabel "Status page: $statusUrls$(if (-not $cfgNow.StatusServerEnabled) { ' (disabled)' })"
  # Docked groups stack from the bottom up, so they are added in reverse.
  foreach ($g in @(
      (New-UiGroup 'Installation' @(
        (New-UiButton 'Install / repair (supervisor, shortcuts, rights)' { if (Confirm-Ui 'Install or repair BSS Manager? The folder becomes writable by administrators only again.') { Start-UiAction 'Install' @('-Action', 'Install') } }),
        (New-UiButton 'Uninstall...' { if (Confirm-Ui 'Delete the tasks and shortcuts of BSS Manager? Accounts and files stay.') { Start-UiAction 'Uninstall' @('-Action', 'Uninstall') } }))),
      (New-UiGroup 'Parameters' @($grid)),
      (New-UiGroup 'Status page (local network, read-only)' @($statusInfo)),
      (New-UiGroup 'Password of the macro accounts' @(
        (New-UiButton 'Set the common password...' { [void](Set-UiCommonPassword) }),
        (New-UiButton 'Apply to every account' { if (-not (Test-CommonPassword)) { Show-UiInfo 'Set the common password first.'; return }; if (Confirm-Ui 'Give the common password to every macro Windows account?') { Set-CommonPasswordOnAll (Get-BssConfig); Update-UiAccounts -Force } }))),
      (New-UiGroup 'Windows automatic sign-in (after a crash)' @(
        (New-UiButton 'Enable...' { Enable-UiAutoLogon }),
        (New-UiButton 'Disable' { if (Confirm-Ui 'Disable automatic sign-in and erase the stored password?') { Disable-AutoLogon; Update-UiHeader -Force } }))),
      (New-UiGroup 'Supervisor' @(
        (New-UiButton 'Enable' { Set-SupervisorEnabled $true; Update-UiHeader -Force }),
        (New-UiButton 'Disable' { if (Confirm-Ui 'Disable the supervisor? Nothing will be restarted automatically anymore.') { Set-SupervisorEnabled $false; Update-UiHeader -Force } }))),
      (New-UiGroup 'RDP Wrapper' @(
        $Script:Ui.WrapperDetail,
        (New-UiButton 'Repair' { Start-UiAction 'RDP Wrapper repair' @('-Action', 'Update') }),
        (New-UiButton 'Download the .ini again' { if (Confirm-Ui 'Download rdpwrap.ini again and restart the service? Remote Desktop connections drop for a few seconds.') { Start-UiAction 'rdpwrap.ini download' @('-Action', 'Update', '-Force') } })))
    )) { $tab.Controls.Add($g) }
  return $tab
}

function New-UiLogTab {
  $tab = New-Object Windows.Forms.TabPage
  $tab.Text = 'Log'
  $box = New-Object Windows.Forms.TextBox
  $box.Multiline = $true
  $box.ReadOnly = $true
  $box.ScrollBars = 'Both'
  $box.WordWrap = $false
  $box.Dock = 'Fill'
  $box.Font = New-Object Drawing.Font('Consolas', 9)
  $box.BackColor = [Drawing.SystemColors]::Window
  $Script:Ui.LogBox = $box
  $Script:Ui.LogTab = $tab
  $tab.Controls.Add($box)
  $tab.Controls.Add((New-UiFlow @((New-UiButton 'Open the log folder' { Start-Process explorer.exe $Script:Bss.LogDir })) 'Bottom'))
  return $tab
}

function Save-UiFormImage {
  param($Form, [string] $File)
  [Windows.Forms.Application]::DoEvents()
  $bmp = New-Object Drawing.Bitmap($Form.Width, $Form.Height)
  $Form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)))
  $bmp.Save($File, [Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

function Save-UiSnapshots {
  param([string] $Dir)
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  for ($i = 0; $i -lt $Script:Ui.Tabs.TabPages.Count; $i++) {
    $Script:Ui.Tabs.SelectedIndex = $i
    if ($i -eq 1) { Update-UiMacros }
    Save-UiFormImage $Script:Ui.Form (Join-Path $Dir ('{0}-{1}.png' -f $i, $Script:Ui.Tabs.TabPages[$i].Text))
  }
  $Script:Ui.Tabs.SelectedIndex = 0
  Show-UiAddRobloxWizard
}

function Show-ManagerWindow {
  param([string] $SnapshotDir)
  [void][BssDpi]::SetProcessDPIAware()
  [Windows.Forms.Application]::EnableVisualStyles()

  $form = New-Object Windows.Forms.Form
  $form.Text = 'BSS Manager - Natro Macro multi-RDP'
  $form.Size = New-Object Drawing.Size(1200, 760)
  $form.MinimumSize = New-Object Drawing.Size(900, 560)
  $form.StartPosition = 'CenterScreen'
  $form.Font = New-Object Drawing.Font('Segoe UI', 9)
  $form.Icon = [Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\System32\mstsc.exe")
  $Script:Ui.Form = $form
  $Script:Ui.Queue = New-Object Collections.ArrayList

  $Script:Ui.SystemLabel = New-UiLabel '' $true
  $Script:Ui.WrapperLabel = New-UiLabel '' $true
  $Script:Ui.SupervisorLabel = New-UiLabel '' $true
  $Script:Ui.AutoLogonLabel = New-UiLabel '' $true
  $status = New-UiFlow @($Script:Ui.SystemLabel, $Script:Ui.WrapperLabel, $Script:Ui.SupervisorLabel, $Script:Ui.AutoLogonLabel)
  $actions = New-UiFlow @(
    (New-UiButton '▶  Start' { Start-UiAction 'Start' @('-Action', 'Start') }),
    (New-UiButton '■  Stop' { if (Confirm-Ui 'Stop the system? Every session is closed (Roblox and Natro stopped) and the supervisor restarts nothing, even after a PC restart, until the next Start.') { Start-UiAction 'Stop' @('-Action', 'Stop') } }),
    (New-UiButton 'Update the macros' { if (Confirm-Ui 'Update the macros of the accounts? Each one is stopped during its update, then restarted.') { Start-UiAction 'Macro update' @('-Action', 'UpdateMacros') } }),
    (New-UiButton 'Update Roblox' { if (Confirm-Ui 'Update Roblox in every account whose session is open? Every macro is stopped meanwhile (about 15 to 30 s per account), then restarted.') { Start-UiAction 'Roblox update' @('-Action', 'RobloxUpdate') } }),
    (New-UiButton 'Refresh' { Update-UiHeader -Force; Update-UiAccounts -Force; Update-UiLog })
  )

  $tabs = New-Object Windows.Forms.TabControl
  $tabs.Dock = 'Fill'
  foreach ($t in @((New-UiAccountsTab), (New-UiMacrosTab), (New-UiSettingsTab), (New-UiLogTab))) { $tabs.TabPages.Add($t) }
  $tabs.Add_SelectedIndexChanged({
      Invoke-UiSafe {
        if ($Script:Ui.Tabs.SelectedIndex -eq 1 -and $Script:Ui.MacrosGrid.Rows.Count -eq 0) { Update-UiMacros }
        if ($Script:Ui.Tabs.SelectedIndex -eq 2) { Update-UiSettings }
      }
    })
  $Script:Ui.Tabs = $tabs

  $strip = New-Object Windows.Forms.StatusStrip
  $Script:Ui.JobStatus = New-Object Windows.Forms.ToolStripStatusLabel
  $Script:Ui.JobStatus.Text = 'Ready.'
  [void]$strip.Items.Add($Script:Ui.JobStatus)

  # Fill first, then the docked edges, so the tabs take what is left.
  $form.Controls.Add($tabs)
  $form.Controls.Add($actions)
  $form.Controls.Add($status)
  $form.Controls.Add($strip)

  $timer = New-Object Windows.Forms.Timer
  $timer.Interval = $Script:UiRefreshMs
  $timer.Add_Tick({
      Invoke-UiSafe {
        Update-UiJob
        Update-UiHeader
        if ($Script:Ui.Tabs.SelectedIndex -eq 0) { Update-UiAccounts }
        Update-UiLog
        $w = $Script:Ui.Wrapper
        $Script:Ui.WrapperDetail.Text = "termsrv.dll $($w.TermsrvVersion), rdpwrap.ini of $($w.IniUpdated), $(if ($w.IniCrlf) { 'CRLF' } else { 'LF !' }), service $($w.Service)"
      }
    })
  $Script:Ui.Timer = $timer

  $form.Add_Shown({
      Invoke-UiSafe {
        Update-UiHeader -Force
        Update-UiAccounts -Force
        Update-UiLog
        $w = $Script:Ui.Wrapper
        $Script:Ui.WrapperDetail.Text = "termsrv.dll $($w.TermsrvVersion), rdpwrap.ini of $($w.IniUpdated), $(if ($w.IniCrlf) { 'CRLF' } else { 'LF !' }), service $($w.Service)"
        if (-not $Script:Ui.SnapshotDir) { $Script:Ui.Timer.Start() }
      }
      if ($Script:Ui.SnapshotDir) {
        try { Invoke-UiSafe { Save-UiSnapshots $Script:Ui.SnapshotDir } } finally { $Script:Ui.Form.Close() }
      }
    })
  $Script:Ui.SnapshotDir = $SnapshotDir
  [void]$form.ShowDialog()
  $timer.Stop()
  $form.Dispose()
}
