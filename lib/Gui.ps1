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
    Write-Log "Interface : $($_.Exception.Message)" ERROR
    [void][Windows.Forms.MessageBox]::Show($Script:Ui.Form, $_.Exception.Message, 'BSS Manager', 'OK', 'Error')
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
  $cancel.Text = 'Annuler'
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

function Start-UiAction {
  param([string] $Label, [string[]] $Arguments)
  if (Test-UiBusy) { Show-UiInfo "Une action est déjà en cours : $($Script:Ui.JobLabel). Attends qu'elle se termine."; return }
  $main = Join-Path $Script:Bss.Root 'BSS-Manager.ps1'
  $quoted = @($Arguments | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } })
  $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $main)) + $quoted + @('-Unattended')
  $Script:Ui.Job = Start-Process -FilePath 'powershell.exe' -ArgumentList $all -WindowStyle Hidden -PassThru
  $Script:Ui.JobLabel = $Label
  $Script:Ui.Tabs.SelectedTab = $Script:Ui.LogTab
  Update-UiJob
}

function Update-UiJob {
  if (Test-UiBusy) {
    $Script:Ui.JobStatus.Text = "En cours : $($Script:Ui.JobLabel)..."
    return
  }
  if ($Script:Ui.Job) {
    $code = $Script:Ui.Job.ExitCode
    $Script:Ui.JobStatus.Text = "Terminé : $($Script:Ui.JobLabel) $(if ($code) { "(erreur, code $code - voir le journal)" } else { '(ok)' })"
    $Script:Ui.Job = $null
    Update-UiAccounts -Force
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
  if ($Force -or -not $Script:Ui.WrapperAt -or ((Get-Date) - $Script:Ui.WrapperAt).TotalSeconds -ge $Script:UiWrapperRefreshSec) {
    $Script:Ui.Wrapper = Get-WrapperState $cfg
    $Script:Ui.WrapperAt = Get-Date
  }
  $w = $Script:Ui.Wrapper
  if ($w.Healthy) { Set-UiStatusLabel $Script:Ui.WrapperLabel "RDP Wrapper : OK (termsrv $($w.TermsrvVersion))" 'ok' }
  else {
    $why = @()
    if (-not $w.IniSupports) { $why += 'version non gérée' }
    if (-not $w.IniCrlf) { $why += 'fins de ligne LF' }
    if (-not $w.ServiceDllOk) { $why += 'service sans rdpwrap.dll' }
    if (-not $w.Listening) { $why += 'pas en écoute' }
    Set-UiStatusLabel $Script:Ui.WrapperLabel "RDP Wrapper : À RÉPARER ($($why -join ', '))" 'bad'
  }

  $task = Get-SupervisorTask
  $sup = Get-SupervisorStatus
  if (-not $task) { Set-UiStatusLabel $Script:Ui.SupervisorLabel 'Superviseur : pas installé' 'warn' }
  elseif ($task.State -eq 'Disabled') { Set-UiStatusLabel $Script:Ui.SupervisorLabel 'Superviseur : désactivé' 'warn' }
  elseif ($sup -and $sup.Alive) { Set-UiStatusLabel $Script:Ui.SupervisorLabel "Superviseur : actif (il y a $($sup.AgeSec) s)" 'ok' }
  else { Set-UiStatusLabel $Script:Ui.SupervisorLabel 'Superviseur : ARRÊTÉ' 'bad' }

  $auto = Get-AutoLogonState
  if ($auto.Enabled -and $auto.SecretStored) { Set-UiStatusLabel $Script:Ui.AutoLogonLabel "Connexion auto : $($auto.User)" 'ok' }
  elseif ($auto.Enabled) { Set-UiStatusLabel $Script:Ui.AutoLogonLabel 'Connexion auto : sans mot de passe' 'bad' }
  else { Set-UiStatusLabel $Script:Ui.AutoLogonLabel 'Connexion auto : désactivée' 'normal' }
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
    $state = [string]$row.Cells['État'].Value
    $color = [Drawing.Color]::White
    if ([string]$row.Cells['Pause'].Value -eq 'oui' -or [string]$row.Cells['Inclus'].Value -eq 'non') { $color = [Drawing.Color]::Gainsboro }
    elseif ([string]$row.Cells['Natro'].Value -eq 'tourne') { $color = [Drawing.Color]::Honeydew }
    elseif ($state -like 'pas prêt*' -or [string]$row.Cells['Session'].Value -like 'DÉCONNECTÉE*') { $color = [Drawing.Color]::MistyRose }
    $row.DefaultCellStyle.BackColor = $color
  }
}

function Update-UiAccounts {
  param([switch] $Force)
  $cfg = Get-BssConfig
  $rows = @(Get-AccountRows $cfg (Get-SupervisorStatus))
  Set-UiGridRows $Script:Ui.AccountsGrid $rows 'Compte' -Force:$Force
}

function Update-UiMacros {
  $cfg = Get-BssConfig
  $rows = @(Find-Macros $cfg | ForEach-Object {
      $path = $_.Path
      [pscustomobject]@{
        Macro    = $_.Name
        Version  = $_.Version
        Type     = $(if ($_.IsGit) { 'Cursed (git)' } else { 'ancienne version' })
        Branche  = $_.Branch
        Comptes  = (@($cfg.Accounts | Where-Object { $_.MacroPath -eq $path } | ForEach-Object { $_.Name }) -join ', ')
        'Utilisée' = $_.LastUsed.ToString('dd.MM.yyyy HH:mm')
        Dossier  = $path
      }
    })
  Set-UiGridRows $Script:Ui.MacrosGrid $rows 'Dossier' -Force
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
  if (-not $row) { Show-UiInfo 'Choisis d''abord un compte dans le tableau.'; return $null }
  return [string]$row.Cells['Compte'].Value
}

function Invoke-UiAccountAction {
  param([string] $Action, [string] $Verb, [bool] $Ask)
  $name = Get-UiSelectedName
  if (-not $name) { return }
  if ($Ask -and -not (Confirm-Ui "$Verb $name ?")) { return }
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
  $labels = @('(aucune macro)') + @($macros | ForEach-Object { Format-MacroLabel $_ })
  $current = 0
  $a = Get-AccountByName $cfg $name
  for ($i = 0; $i -lt $macros.Count; $i++) { if ($macros[$i].Path -eq $a.MacroPath) { $current = $i + 1 } }
  $r = Show-UiDialog "Macro de $name" @(@{ Key = 'macro'; Label = 'Macro'; Kind = 'list'; Items = $labels; Value = $current }) 'Natro démarrera cette macro dans la session du compte, avec la macro déjà lancée.'
  if (-not $r -or $r.macro -lt 0) { return }
  $path = $(if ($r.macro -eq 0) { '' } else { $macros[$r.macro - 1].Path })
  $other = $cfg.Accounts | Where-Object { $path -and $_.Name -ne $name -and $_.MacroPath -eq $path } | Select-Object -First 1
  if ($other -and -not (Confirm-Ui "$($other.Name) utilise déjà cette macro. L'associer quand même ?")) { return }
  Set-AccountMacroPath $cfg $name $path
  if ($path -and -not $macros[$r.macro - 1].IsGit) { Show-UiInfo 'Cette macro est une ancienne version. Onglet Macros, « Convertir en Cursed », pour la passer sur ta version.' }
  Update-UiAccounts -Force
}

function Set-UiAccountPassword {
  $name = Get-UiSelectedName
  if (-not $name) { return }
  $r = Show-UiDialog "Mot de passe de $name" @(
    @{ Key = 'pwd'; Label = 'Mot de passe'; Kind = 'password' },
    @{ Key = 'pwd2'; Label = 'Confirmation'; Kind = 'password' },
    @{ Key = 'change'; Label = 'Changer aussi le mot de passe Windows du compte'; Kind = 'check'; Value = $false }
  ) "Sans case cochée : enregistre le mot de passe actuel de $name, pour que sa session s'ouvre sans rien demander."
  if (-not $r) { return }
  if (-not (Test-SecureEqual $r.pwd $r.pwd2)) { throw 'Les deux mots de passe ne correspondent pas.' }
  Set-AccountPasswordValue (Get-BssConfig) $name $r.pwd $r.change
  Update-UiAccounts -Force
}

function New-UiAccount {
  $r = Show-UiDialog 'Créer un compte macro' @(
    @{ Key = 'name'; Label = 'Nom (ex : Roblox3)'; Kind = 'text' },
    @{ Key = 'pwd'; Label = 'Mot de passe'; Kind = 'password' },
    @{ Key = 'pwd2'; Label = 'Confirmation'; Kind = 'password' }
  ) 'Crée un compte Windows dédié à une macro. Ensuite : ouvre sa session une fois pour installer Roblox, puis associe-lui une macro.'
  if (-not $r) { return }
  if (-not (Test-SecureEqual $r.pwd $r.pwd2)) { throw 'Les deux mots de passe ne correspondent pas.' }
  [void](New-MacroAccount (Get-BssConfig) $r.name $r.pwd)
  Update-UiAccounts -Force
}

function Add-UiExistingAccount {
  $cfg = Get-BssConfig
  $candidates = @(Get-AddableWindowsAccounts $cfg)
  if (-not $candidates.Count) { Show-UiInfo 'Aucun autre compte Windows disponible.'; return }
  $r = Show-UiDialog 'Ajouter un compte Windows existant' @(
    @{ Key = 'name'; Label = 'Compte'; Kind = 'list'; Items = $candidates },
    @{ Key = 'pwd'; Label = 'Son mot de passe (facultatif)'; Kind = 'password' }
  )
  if (-not $r -or $r.name -lt 0) { return }
  [void](Add-ExistingMacroAccount $cfg $candidates[$r.name] $r.pwd)
  Update-UiAccounts -Force
}

function Remove-UiAccount {
  $name = Get-UiSelectedName
  if (-not $name) { return }
  $r = Show-UiDialog "Retirer $name" @(
    @{ Key = 'delete'; Label = "Supprimer aussi le compte Windows $name (définitif)"; Kind = 'check'; Value = $false }
  ) "$name sera retiré de BSS Manager et sa session fermée. Son dossier C:\Users\$name reste sur le disque."
  if (-not $r) { return }
  if ($r.delete -and -not (Confirm-Ui "Supprimer DÉFINITIVEMENT le compte Windows $name ?")) { return }
  Remove-ManagedAccount (Get-BssConfig) $name $r.delete
  Update-UiAccounts -Force
}

# ---------------------------------------------------------------------------
# Macro actions
# ---------------------------------------------------------------------------

function Get-UiSelectedMacro {
  $row = $Script:Ui.MacrosGrid.CurrentRow
  if (-not $row) { Show-UiInfo 'Choisis d''abord une macro dans le tableau.'; return $null }
  return [pscustomobject]@{ Path = [string]$row.Cells['Dossier'].Value; Name = [string]$row.Cells['Macro'].Value; IsGit = ([string]$row.Cells['Type'].Value -like 'Cursed*'); Branch = [string]$row.Cells['Branche'].Value }
}

function Set-UiMacroBranch {
  $m = Get-UiSelectedMacro
  if (-not $m) { return }
  if (-not $m.IsGit) { Show-UiInfo 'Convertis d''abord cette macro en version Cursed.'; return }
  $Script:Ui.Form.Cursor = 'WaitCursor'
  try { $branches = @(Get-RemoteBranches $m.Path) } finally { $Script:Ui.Form.Cursor = 'Default' }
  if (-not $branches.Count) { throw 'Impossible de lister les branches (réseau ?).' }
  $r = Show-UiDialog "Branche de $($m.Name)" @(@{ Key = 'b'; Label = 'Branche'; Kind = 'list'; Items = $branches; Value = [Math]::Max(0, [array]::IndexOf($branches, $m.Branch)) }) 'La macro est arrêtée si elle tourne, mise à jour sur cette branche, puis relancée. Ses réglages ne changent pas.'
  if (-not $r -or $r.b -lt 0) { return }
  Start-UiAction "Branche $($branches[$r.b]) pour $($m.Name)" @('-Action', 'SetBranch', '-Path', $m.Path, '-Branch', $branches[$r.b])
}

function Update-UiMacro {
  $m = Get-UiSelectedMacro
  if (-not $m) { return }
  if (-not $m.IsGit) { Show-UiInfo 'Convertis d''abord cette macro en version Cursed.'; return }
  if (-not (Confirm-Ui "Mettre à jour $($m.Name) ? Elle est arrêtée pendant la mise à jour puis relancée si son compte tourne.")) { return }
  Start-UiAction "Mise à jour de $($m.Name)" @('-Action', 'UpdateMacros', '-Path', $m.Path)
}

function Convert-UiMacro {
  $m = Get-UiSelectedMacro
  if (-not $m) { return }
  if ($m.IsGit) { Show-UiInfo 'Cette macro est déjà en version Cursed.'; return }
  $cfg = Get-BssConfig
  if (-not (Confirm-Ui "Convertir $($m.Name) en version Cursed ($($cfg.DefaultBranch)) ? Ses fichiers sont remplacés, le dossier settings est gardé.")) { return }
  Start-UiAction "Conversion de $($m.Name)" @('-Action', 'ConvertMacro', '-Path', $m.Path)
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
  Write-Log 'Réglages enregistrés.' OK
  Show-UiInfo 'Réglages enregistrés. Le superviseur les applique à sa prochaine vérification. La boîte de réception demande de relancer l''installation.'
}

function Enable-UiAutoLogon {
  $r = Show-UiDialog 'Connexion automatique de Windows' @(
    @{ Key = 'user'; Label = 'Compte Windows'; Kind = 'text'; Value = $env:USERNAME },
    @{ Key = 'pwd'; Label = 'Mot de passe'; Kind = 'password' },
    @{ Key = 'pwd2'; Label = 'Confirmation'; Kind = 'password' }
  ) 'Windows ouvrira cette session tout seul au démarrage, puis le superviseur relancera tout. Pour un compte lié à Microsoft : le mot de passe du compte Microsoft, pas le code PIN. Il est stocké chiffré par Windows (secret LSA), et la connexion « Windows Hello uniquement » est désactivée.'
  if (-not $r) { return }
  if (-not (Test-SecureEqual $r.pwd $r.pwd2)) { throw 'Les deux mots de passe ne correspondent pas.' }
  Enable-AutoLogon $r.user $r.pwd
  Update-UiHeader -Force
}

# ---------------------------------------------------------------------------
# Window
# ---------------------------------------------------------------------------

function New-UiAccountsTab {
  $tab = New-Object Windows.Forms.TabPage
  $tab.Text = 'Comptes'
  $Script:Ui.AccountsGrid = New-UiGrid
  $Script:Ui.AccountsGrid.Add_DataBindingComplete({ Set-UiAccountColors })
  $buttons = New-UiFlow @(
    (New-UiButton 'Lancer' { Invoke-UiAccountAction 'Start' 'Lancer' $false }),
    (New-UiButton 'Arrêter' { Invoke-UiAccountAction 'Stop' 'Arrêter' $true }),
    (New-UiButton 'Relancer la macro' { Invoke-UiAccountAction 'Restart' 'Relancer la macro de' $true }),
    (New-UiButton 'Pause / reprendre' { Switch-UiAccountFlag 'Paused' }),
    (New-UiButton 'Inclure / exclure' { Switch-UiAccountFlag 'Enabled' }),
    (New-UiButton 'Associer une macro...' { Set-UiAccountMacro }),
    (New-UiButton 'Mot de passe...' { Set-UiAccountPassword }),
    (New-UiButton 'Créer un compte...' { New-UiAccount }),
    (New-UiButton 'Ajouter un compte existant...' { Add-UiExistingAccount }),
    (New-UiButton 'Retirer...' { Remove-UiAccount })
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
    (New-UiButton 'Actualiser' { Update-UiMacros }),
    (New-UiButton 'Changer de branche...' { Set-UiMacroBranch }),
    (New-UiButton 'Mettre à jour' { Update-UiMacro }),
    (New-UiButton 'Convertir en Cursed...' { Convert-UiMacro }),
    (New-UiButton 'Ouvrir le dossier' { $m = Get-UiSelectedMacro; if ($m) { Start-Process explorer.exe $m.Path } })
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
  $tab.Text = 'Réglages'
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
  }
  $labels = [ordered]@{
    SessionWidth            = 'Largeur des sessions'
    SessionHeight           = 'Hauteur des sessions'
    DelayBetweenSessionsSec = 'Secondes entre deux sessions'
    NatroStartDelaySec      = 'Secondes avant de démarrer Natro'
    SupervisorIntervalSec   = 'Secondes entre deux vérifications'
    RestartGraceSec         = 'Secondes avant de relancer'
    MacroRoot               = 'Dossier des macros'
    DefaultBranch           = 'Branche par défaut'
    UpdateMacrosOnStart     = 'Mettre à jour les macros à chaque « Tout lancer »'
    InboxEnabled            = 'Accepter les demandes de redémarrage (fleet)'
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
  $grid.Controls.Add((New-UiButton 'Enregistrer les réglages' { Save-UiSettings }), 1, $grid.RowCount - 1)

  $Script:Ui.WrapperDetail = New-UiLabel ''
  # Docked groups stack from the bottom up, so they are added in reverse.
  foreach ($g in @(
      (New-UiGroup 'Installation' @(
        (New-UiButton 'Installer / réparer (superviseur, raccourcis, droits)' { if (Confirm-Ui 'Installer ou réparer BSS Manager ? Le dossier redevient modifiable par les administrateurs seulement.') { Start-UiAction 'Installation' @('-Action', 'Install') } }),
        (New-UiButton 'Désinstaller...' { if (Confirm-Ui 'Supprimer les tâches et raccourcis de BSS Manager ? Les comptes et les fichiers restent.') { Start-UiAction 'Désinstallation' @('-Action', 'Uninstall') } }))),
      (New-UiGroup 'Paramètres' @($grid)),
      (New-UiGroup 'Connexion automatique de Windows (après un crash)' @(
        (New-UiButton 'Activer...' { Enable-UiAutoLogon }),
        (New-UiButton 'Désactiver' { if (Confirm-Ui 'Désactiver la connexion automatique et effacer le mot de passe stocké ?') { Disable-AutoLogon; Update-UiHeader -Force } }))),
      (New-UiGroup 'Superviseur' @(
        (New-UiButton 'Activer' { Set-SupervisorEnabled $true; Update-UiHeader -Force }),
        (New-UiButton 'Désactiver' { if (Confirm-Ui 'Désactiver le superviseur ? Plus rien ne sera relancé automatiquement.') { Set-SupervisorEnabled $false; Update-UiHeader -Force } }))),
      (New-UiGroup 'RDP Wrapper' @(
        $Script:Ui.WrapperDetail,
        (New-UiButton 'Réparer' { Start-UiAction 'Réparation de RDP Wrapper' @('-Action', 'Update') }),
        (New-UiButton 'Retélécharger le .ini' { if (Confirm-Ui 'Retélécharger rdpwrap.ini et redémarrer le service ? Les connexions Bureau à distance seront coupées quelques secondes.') { Start-UiAction 'Retéléchargement de rdpwrap.ini' @('-Action', 'Update', '-Force') } })))
    )) { $tab.Controls.Add($g) }
  return $tab
}

function New-UiLogTab {
  $tab = New-Object Windows.Forms.TabPage
  $tab.Text = 'Journal'
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
  $tab.Controls.Add((New-UiFlow @((New-UiButton 'Ouvrir le dossier des journaux' { Start-Process explorer.exe $Script:Bss.LogDir })) 'Bottom'))
  return $tab
}

function Save-UiSnapshots {
  param([string] $Dir)
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  for ($i = 0; $i -lt $Script:Ui.Tabs.TabPages.Count; $i++) {
    $Script:Ui.Tabs.SelectedIndex = $i
    if ($i -eq 1) { Update-UiMacros }
    [Windows.Forms.Application]::DoEvents()
    $bmp = New-Object Drawing.Bitmap($Script:Ui.Form.Width, $Script:Ui.Form.Height)
    $Script:Ui.Form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)))
    $bmp.Save((Join-Path $Dir ('{0}-{1}.png' -f $i, $Script:Ui.Tabs.TabPages[$i].Text)), [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
  }
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

  $Script:Ui.WrapperLabel = New-UiLabel '' $true
  $Script:Ui.SupervisorLabel = New-UiLabel '' $true
  $Script:Ui.AutoLogonLabel = New-UiLabel '' $true
  $status = New-UiFlow @($Script:Ui.WrapperLabel, $Script:Ui.SupervisorLabel, $Script:Ui.AutoLogonLabel)
  $actions = New-UiFlow @(
    (New-UiButton 'Tout lancer' { Start-UiAction 'Tout lancer' @('-Action', 'Start') }),
    (New-UiButton 'Tout arrêter' { if (Confirm-Ui 'Arrêter tous les comptes ? Les sessions sont fermées (Roblox et Natro arrêtés) et les comptes mis en pause.') { Start-UiAction 'Tout arrêter' @('-Action', 'Stop') } }),
    (New-UiButton 'Mettre à jour les macros' { if (Confirm-Ui 'Mettre à jour les macros des comptes ? Chacune est arrêtée pendant sa mise à jour puis relancée.') { Start-UiAction 'Mise à jour des macros' @('-Action', 'UpdateMacros') } }),
    (New-UiButton 'Actualiser' { Update-UiHeader -Force; Update-UiAccounts -Force; Update-UiLog })
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
  $Script:Ui.JobStatus.Text = 'Prêt.'
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
        $Script:Ui.WrapperDetail.Text = "termsrv.dll $($w.TermsrvVersion), rdpwrap.ini du $($w.IniUpdated), $(if ($w.IniCrlf) { 'CRLF' } else { 'LF !' }), service $($w.Service)"
      }
    })
  $Script:Ui.Timer = $timer

  $form.Add_Shown({
      Invoke-UiSafe {
        Update-UiHeader -Force
        Update-UiAccounts -Force
        Update-UiLog
        $w = $Script:Ui.Wrapper
        $Script:Ui.WrapperDetail.Text = "termsrv.dll $($w.TermsrvVersion), rdpwrap.ini du $($w.IniUpdated), $(if ($w.IniCrlf) { 'CRLF' } else { 'LF !' }), service $($w.Service)"
        if ($Script:Ui.SnapshotDir) { Save-UiSnapshots $Script:Ui.SnapshotDir; $Script:Ui.Form.Close() }
        else { $Script:Ui.Timer.Start() }
      }
    })
  $Script:Ui.SnapshotDir = $SnapshotDir
  [void]$form.ShowDialog()
  $timer.Stop()
  $form.Dispose()
}
