# Text menu, kept for consoles and remote shells (-Action Menu). Each choice
# asks its questions here and calls the shared actions in Actions.ps1, the
# same ones the window uses.

function Format-MacroLabel {
  param($Info)
  $kind = $(if ($Info.IsGit) { "Cursed, $($Info.Branch)" } else { 'ancienne version' })
  return ('{0}  v{1}  [{2}]  utilisée le {3:dd.MM.yyyy}' -f $Info.Name, $Info.Version, $kind, $Info.LastUsed)
}

# ---------------------------------------------------------------------------
# Questions, then the shared action
# ---------------------------------------------------------------------------

function Set-AccountMacro {
  param($Cfg)
  $a = Select-OneAccount $Cfg
  if (-not $a) { return }
  $macros = @(Find-Macros $Cfg)
  Write-Host "Actuelle : $(if ($a.MacroPath) { $a.MacroPath } else { '(aucune)' })"
  $i = Select-Index (@($macros | ForEach-Object { Format-MacroLabel $_ }) + @('Aucune macro')) 'Macro'
  if ($i -lt 0) { return }
  $path = $(if ($i -eq $macros.Count) { '' } else { $macros[$i].Path })
  $other = $Cfg.Accounts | Where-Object { $path -and $_.Name -ne $a.Name -and $_.MacroPath -eq $path } | Select-Object -First 1
  if ($other -and -not (Confirm-Action "$($other.Name) utilise déjà cette macro. L'associer quand même ?")) { return }
  Set-AccountMacroPath $Cfg $a.Name $path
  if ($path -and -not $macros[$i].IsGit) { Write-Host 'Ancienne version : « Ajouter un compte Roblox » crée une macro propre à partir de ce dossier.' -ForegroundColor Yellow }
}

function Set-MacroBranchMenu {
  param($Cfg)
  $macros = @(Find-Macros $Cfg | Where-Object { $_.IsGit })
  $labels = @("Branche par défaut des nouvelles macros (actuelle : $($Cfg.DefaultBranch))") + @($macros | ForEach-Object { Format-MacroLabel $_ })
  $i = Select-Index $labels 'Quelle branche changer'
  if ($i -lt 0) { return }
  $sample = $(if ($i -eq 0) { $macros | Select-Object -First 1 } else { $macros[$i - 1] })
  if (-not $sample) { Write-Host 'Aucune macro Cursed pour lister les branches.' -ForegroundColor Yellow; return }
  $branches = @(Get-RemoteBranches $sample.Path)
  if (-not $branches.Count) { Write-Host 'Impossible de lister les branches (réseau ?).' -ForegroundColor Yellow; return }
  $j = Select-Index $branches 'Branche'
  if ($j -lt 0) { return }
  if ($i -eq 0) {
    $Cfg.DefaultBranch = $branches[$j]
    Save-BssConfig $Cfg
    Write-Log "Branche par défaut : $($branches[$j])." OK
    return
  }
  if ((Get-NatroProcesses $sample.Path) -and -not (Confirm-Action 'Cette macro tourne : l''arrêter, changer de branche, mettre à jour et la relancer ?')) { return }
  Set-MacroBranch $Cfg $sample.Path $branches[$j]
}

function Add-RobloxAccountMenu {
  param($Cfg)
  $suggestions = @(Get-RobloxAccountSuggestions $Cfg | Where-Object { -not $_.Configured })
  $labels = @($suggestions | ForEach-Object { '{0}  ({1} dossier(s))' -f $_.Roblox, $_.Candidates.Count }) + @('Autre nom...')
  $i = Select-Index $labels 'Compte Roblox'
  if ($i -lt 0) { return }
  $candidates = @()
  $guess = ''
  if ($i -lt $suggestions.Count) { $guess = $suggestions[$i].Roblox; $candidates = $suggestions[$i].Candidates }
  $roblox = (Read-Host "Compte Roblox exact (Entrée = $(if ($guess) { $guess } else { 'inconnu, retenu à la 1re connexion' }), « - » = inconnu)").Trim()
  if (-not $roblox) { $roblox = $guess }
  if ($roblox -eq '-') { $roblox = '' }
  $role = ''
  if (-not $roblox -or ($guess -and $roblox -ne $guess)) {
    $role = (Read-Host "Rôle (Entrée = $guess)").Trim()
    if (-not $role) { $role = $guess }
  }
  if (-not (Test-CommonPassword)) {
    Write-Host 'Choisis le mot de passe commun des comptes macro (Windows le demande parfois).' -ForegroundColor Cyan
    Set-CommonPassword (Read-NewPassword 'les comptes macro')
  }
  $j = Select-Index (@($candidates | ForEach-Object { Format-MacroLabel $_ }) + @('Aucune base : réglages neufs')) 'Macro de base'
  if ($j -lt 0) { return }
  $source = $(if ($j -lt $candidates.Count) { $candidates[$j].Path } else { '' })
  Add-RobloxAccount $Cfg $roblox $role '' $source
}

function Switch-AccountFlagMenu {
  param($Cfg, [string] $Flag)
  $a = Select-OneAccount $Cfg
  if ($a) { Set-AccountFlag $Cfg $a.Name $Flag (-not $a.$Flag) }
}

function Set-AccountPasswordMenu {
  param($Cfg)
  $a = Select-OneAccount $Cfg
  if (-not $a) { return }
  $i = Select-Index @('Appliquer le mot de passe commun des comptes macro', 'Enregistrer le mot de passe actuel (ne change rien dans Windows)') 'Choix'
  if ($i -eq 0) { Reset-AccountPassword $Cfg $a.Name }
  elseif ($i -eq 1) { Set-AccountPasswordValue $Cfg $a.Name (Read-Host "Mot de passe Windows actuel de $($a.Name)" -AsSecureString) $false }
}

function Remove-MacroAccountMenu {
  param($Cfg)
  $a = Select-OneAccount $Cfg
  if (-not $a) { return }
  if (-not (Confirm-Action "Retirer $($a.Name) de BSS Manager (sa session sera fermée) ?")) { return }
  $typed = Read-Host "Pour SUPPRIMER aussi le compte Windows (définitif), tape « $($a.Name) ». Sinon Entrée"
  Remove-ManagedAccount $Cfg $a.Name ($typed -ceq $a.Name)
}

function Set-AutoLogonMenu {
  $state = Get-AutoLogonState
  Write-Host ('Connexion automatique : {0}' -f $(if ($state.Enabled) { "activée ($($state.User))" } else { 'désactivée' }))
  if ($state.Enabled) {
    if (Confirm-Action 'La désactiver et effacer le mot de passe stocké ?') { Disable-AutoLogon }
    return
  }
  Write-Host 'Windows ouvrira ta session seul au démarrage, puis le superviseur relancera tout.' -ForegroundColor Cyan
  Write-Host 'Le mot de passe est stocké chiffré par Windows (secret LSA). Windows Hello seul sera désactivé.' -ForegroundColor Cyan
  if (-not (Confirm-Action 'Activer la connexion automatique ?')) { return }
  $user = Read-Host "Compte Windows à ouvrir automatiquement (Entrée = $env:USERNAME)"
  if (-not $user) { $user = $env:USERNAME }
  Write-Host 'Pour un compte lié à Microsoft, tape le mot de passe du compte Microsoft (pas le code PIN).' -ForegroundColor Yellow
  Enable-AutoLogon $user (Read-NewPassword $user)
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------

function Invoke-MenuChoice {
  param([scriptblock] $Block)
  try { & $Block } catch { Write-Log "Erreur : $($_.Exception.Message)" ERROR }
  Wait-Enter
}

function Show-AccountsMenu {
  while ($true) {
    # Re-read every time: the supervisor or a window may have changed it.
    $cfg = Get-BssConfig
    Clear-Host
    Write-Host '=== Comptes Roblox ===' -ForegroundColor Cyan
    foreach ($a in @($cfg.Accounts)) {
      $flags = @()
      if (-not $a.Enabled) { $flags += 'exclu' }
      if ($a.Paused) { $flags += 'pause' }
      Write-Host ('  {0,-16} {1,-16} {2,-11} {3} {4}' -f $(if ($a.Roblox) { $a.Roblox } else { '?' }), $a.Name, $a.Ip, $(if ($a.MacroPath) { Split-Path $a.MacroPath -Leaf } else { '(aucune macro)' }), $(if ($flags) { "[$($flags -join ', ')]" } else { '' }))
    }
    Write-Host ''
    Write-Host '  1. Ajouter un compte Roblox (compte Windows, macro, Roblox)'
    Write-Host '  2. Changer la macro d''un compte'
    Write-Host '  3. Choisir la branche d''une macro (ou celle par défaut)'
    Write-Host '  4. Pause / maintenance d''un compte'
    Write-Host '  5. Inclure / exclure un compte'
    Write-Host '  6. Mot de passe d''un compte'
    Write-Host '  7. Retirer un compte'
    Write-Host '  0. Retour'
    switch (Read-Host "`nChoix") {
      '1' { Invoke-MenuChoice { Add-RobloxAccountMenu $cfg } }
      '2' { Invoke-MenuChoice { Set-AccountMacro $cfg } }
      '3' { Invoke-MenuChoice { Set-MacroBranchMenu $cfg } }
      '4' { Invoke-MenuChoice { Switch-AccountFlagMenu $cfg 'Paused' } }
      '5' { Invoke-MenuChoice { Switch-AccountFlagMenu $cfg 'Enabled' } }
      '6' { Invoke-MenuChoice { Set-AccountPasswordMenu $cfg } }
      '7' { Invoke-MenuChoice { Remove-MacroAccountMenu $cfg } }
      '0' { return }
      '' { return }
    }
  }
}

function Show-UpdateMenu {
  param($Cfg)
  $i = Select-Index @('Macros des comptes (relancées ensuite)', "Toutes les macros Cursed de $($Cfg.MacroRoot)") 'Mettre à jour'
  if ($i -eq 0) { Update-Macros $Cfg }
  elseif ($i -eq 1) { Update-Macros $Cfg -AllFolders }
}

function Show-StopMenu {
  param($Cfg)
  $accounts = @($Cfg.Accounts)
  if (-not $accounts.Count) { return }
  $i = Select-Index (@('Tous les comptes') + @($accounts | ForEach-Object { $_.Name })) 'Arrêter'
  if ($i -eq 0) { Stop-All $Cfg }
  elseif ($i -gt 0) { Stop-All $Cfg @($accounts[$i - 1].Name) }
}

function Show-MainMenu {
  while ($true) {
    $cfg = Get-BssConfig
    Clear-Host
    Write-Host '=========================================' -ForegroundColor Cyan
    Write-Host '   BSS Manager - Natro Macro multi-RDP' -ForegroundColor Cyan
    Write-Host '=========================================' -ForegroundColor Cyan
    try {
      $w = Get-WrapperState $cfg
      if ($w.Healthy) { Write-Host "RDP Wrapper    : OK (termsrv $($w.TermsrvVersion))" -ForegroundColor Green }
      else { Write-Host "RDP Wrapper    : À RÉPARER (termsrv $($w.TermsrvVersion)) -> 6" -ForegroundColor Red }
      $sup = Get-SupervisorStatus
      if ($sup -and $sup.Alive) { Write-Host "Superviseur    : actif (il y a $($sup.AgeSec) s)" -ForegroundColor Green }
      elseif ($sup) { Write-Host 'Superviseur    : ARRÊTÉ' -ForegroundColor Red }
      else { Write-Host 'Superviseur    : pas installé -> 8' -ForegroundColor Yellow }
      $sessions = Get-BssSessions
      $up = @($cfg.Accounts | Where-Object { Test-SessionConnected (Get-AccountSession $_ $sessions) })
      Write-Host "Sessions macro : $($up.Count) / $(@($cfg.Accounts | Where-Object { $_.Enabled }).Count) connectée(s)"
    } catch { Write-Host "État indisponible : $($_.Exception.Message)" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '  1. Tout lancer (mises à jour, sessions, macros)'
    Write-Host '  2. Arrêter'
    Write-Host '  3. État détaillé'
    Write-Host '  4. Mettre à jour les macros'
    Write-Host '  5. Comptes et macros'
    Write-Host '  6. Mettre à jour RDP Wrapper'
    Write-Host '  7. Connexion automatique de Windows'
    Write-Host '  8. Installation (superviseur, raccourcis, droits)'
    Write-Host '  9. Désinstallation'
    Write-Host '  0. Quitter'
    switch (Read-Host "`nChoix") {
      '1' { Invoke-MenuChoice { Start-All $cfg } }
      '2' { Invoke-MenuChoice { Show-StopMenu $cfg } }
      '3' { Invoke-MenuChoice { Show-Status $cfg } }
      '4' { Invoke-MenuChoice { Show-UpdateMenu $cfg } }
      '5' { Show-AccountsMenu }
      '6' { Invoke-MenuChoice { [void](Update-RdpWrapper $cfg) } }
      '7' { Invoke-MenuChoice { Set-AutoLogonMenu } }
      '8' { Invoke-MenuChoice { Install-Manager $cfg } }
      '9' { Invoke-MenuChoice { if (Confirm-Action 'Supprimer les tâches et raccourcis de BSS Manager ?') { Uninstall-Manager } } }
      '0' { return }
    }
  }
}
