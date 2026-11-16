# Interactive menus. Each choice calls an action from Actions.ps1 or a small
# account/macro editor below; nothing here holds state of its own.

# ---------------------------------------------------------------------------
# Account and macro editors
# ---------------------------------------------------------------------------

function Format-MacroLabel {
  param($Info)
  $kind = $(if ($Info.IsGit) { "Cursed, $($Info.Branch)" } else { 'ancienne version' })
  return ('{0}  v{1}  [{2}]  utilisée le {3:dd.MM.yyyy}' -f $Info.Name, $Info.Version, $kind, $Info.LastUsed)
}

function Set-AccountMacro {
  param($Cfg)
  $a = Select-OneAccount $Cfg
  if (-not $a) { return }
  $macros = @(Find-Macros $Cfg)
  Write-Host "Actuelle : $(if ($a.MacroPath) { $a.MacroPath } else { '(aucune)' })"
  $labels = @($macros | ForEach-Object { Format-MacroLabel $_ }) + @('Aucune macro')
  $i = Select-Index $labels 'Macro'
  if ($i -lt 0) { return }
  if ($i -eq $macros.Count) { $a.MacroPath = '' }
  else {
    $chosen = $macros[$i]
    $other = $Cfg.Accounts | Where-Object { $_.Name -ne $a.Name -and $_.MacroPath -eq $chosen.Path } | Select-Object -First 1
    if ($other -and -not (Confirm-Action "$($other.Name) utilise déjà cette macro. L'associer quand même ?")) { return }
    $a.MacroPath = $chosen.Path
    if (-not $chosen.IsGit) { Write-Host 'Cette macro est une ancienne version : « Convertir une ancienne macro » la passe sur ta version Cursed.' -ForegroundColor Yellow }
  }
  Save-BssConfig $Cfg
  Sync-NatroTask $Cfg $a
  Write-Log "$($a.Name) : macro = $(if ($a.MacroPath) { $a.MacroPath } else { '(aucune)' })." OK
}

function Get-RemoteBranches {
  param([string] $Path)
  $git = @('-c', 'safe.directory=*', '-C', $Path)
  & git @git fetch --quiet --prune origin 2>$null
  return @(& git @git branch -r --format='%(refname:short)' 2>$null |
    Where-Object { $_ -and $_ -notmatch '/HEAD$' -and $_ -ne 'origin' } | ForEach-Object { $_ -replace '^origin/', '' })
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
  $branch = $branches[$j]

  if ($i -eq 0) {
    $Cfg.DefaultBranch = $branch
    Save-BssConfig $Cfg
    Write-Log "Branche par défaut : $branch." OK
    return
  }
  $path = $sample.Path
  $running = [bool](Get-NatroProcesses $path)
  # Natro rewrites nm_config.ini from memory, so the macro is stopped before
  # its GitBranch is changed, and restarted after the update.
  if ($running -and -not (Confirm-Action 'Cette macro tourne : l''arrêter, changer de branche, mettre à jour et la relancer ?')) { return }
  if ($running) { Stop-NatroProcesses $path }
  Set-NatroIniValue $path 'GitBranch' $branch
  if (-not (Get-NatroIniValue $path 'GitRepoUrl')) { Set-NatroIniValue $path 'GitRepoUrl' $Cfg.DefaultRepoUrl }
  Write-Log "$($sample.Name) suit maintenant $branch." OK
  # An empty name list would mean "every account" to Update-Macros.
  $owners = @($Cfg.Accounts | Where-Object { $_.MacroPath -eq $path } | ForEach-Object { $_.Name })
  if ($owners.Count) { Update-Macros $Cfg -Names $owners } else { [void](Update-Macro $Cfg $path) }
}

function Convert-MacroMenu {
  param($Cfg)
  $old = @(Find-Macros $Cfg | Where-Object { -not $_.IsGit })
  if (-not $old.Count) { Write-Host 'Toutes les macros trouvées sont déjà en version Cursed.' -ForegroundColor Green; return }
  Write-Host "Les fichiers de la macro sont remplacés par ceux de $($Cfg.DefaultBranch). Le dossier settings (comptes, champs, webhook) est gardé." -ForegroundColor Yellow
  $i = Select-Index @($old | ForEach-Object { Format-MacroLabel $_ }) 'Macro à convertir'
  if ($i -lt 0) { return }
  [void](Convert-MacroToGit $Cfg $old[$i].Path)
}

function Switch-AccountPause {
  param($Cfg)
  $a = Select-OneAccount $Cfg
  if (-not $a) { return }
  $a.Paused = -not $a.Paused
  Save-BssConfig $Cfg
  if ($a.Paused) { Write-Log "$($a.Name) en pause : le superviseur ne relance plus rien pour ce compte (la session reste ouverte)." OK }
  else { Write-Log "$($a.Name) n'est plus en pause." OK }
}

function Switch-AccountEnabled {
  param($Cfg)
  $a = Select-OneAccount $Cfg
  if (-not $a) { return }
  $a.Enabled = -not $a.Enabled
  Save-BssConfig $Cfg
  Sync-NatroTask $Cfg $a
  Write-Log "$($a.Name) : $(if ($a.Enabled) { 'inclus dans' } else { 'exclu de' }) « Tout lancer » et de la supervision." OK
}

function Add-NewMacroAccount {
  param($Cfg)
  $name = (Read-Host 'Nom du nouveau compte Windows (ex : Roblox3)').Trim()
  if ($name -notmatch '^[A-Za-z0-9_-]{1,20}$') { Write-Host 'Nom invalide (lettres, chiffres, - et _, 20 caractères max).' -ForegroundColor Yellow; return }
  if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) { Write-Host 'Ce compte existe déjà : utilise « Ajouter un compte Windows existant ».' -ForegroundColor Yellow; return }
  $password = Read-NewPassword $name
  New-LocalUser -Name $name -Password $password -PasswordNeverExpires -AccountNeverExpires -Description 'Bee Swarm macro account (BSS Manager)' | Out-Null
  Add-ToRdpGroups $name
  $account = New-AccountEntry $Cfg $name
  Set-AccountCredential $account $password
  $Cfg.Accounts = @($Cfg.Accounts) + $account
  Save-BssConfig $Cfg
  Write-Log "Compte $name créé (adresse $($account.Ip), mot de passe enregistré)." OK
  Write-Host @"

Pour finir de préparer $name :
  1. « Tout lancer » ou le menu ouvre sa session une première fois.
  2. Dans cette session : installe Roblox et connecte le compte Roblox de cette macro.
  3. Ici : « Associer une macro à un compte ».
"@ -ForegroundColor Cyan
}

function Add-ExistingAccount {
  param($Cfg)
  $known = @($Cfg.Accounts | ForEach-Object { $_.Name })
  $candidates = @(Get-LocalUser | Where-Object { $_.Enabled -and $_.Name -ne $env:USERNAME -and $known -notcontains $_.Name } | ForEach-Object { $_.Name })
  if (-not $candidates.Count) { Write-Host 'Aucun autre compte Windows disponible.' -ForegroundColor Yellow; return }
  $i = Select-Index $candidates 'Compte à ajouter'
  if ($i -lt 0) { return }
  Add-ToRdpGroups $candidates[$i]
  $account = New-AccountEntry $Cfg $candidates[$i]
  $Cfg.Accounts = @($Cfg.Accounts) + $account
  Save-BssConfig $Cfg
  Write-Log "$($account.Name) ajouté (adresse $($account.Ip))." OK
  if (Confirm-Action 'Enregistrer son mot de passe maintenant (sinon Windows le demandera à la connexion) ?') {
    Set-AccountCredential $account (Read-Host "Mot de passe Windows actuel de $($account.Name)" -AsSecureString)
    Write-Log "Mot de passe de $($account.Name) enregistré." OK
  }
}

function Set-AccountPassword {
  param($Cfg)
  $a = Select-OneAccount $Cfg
  if (-not $a) { return }
  $i = Select-Index @('Enregistrer le mot de passe actuel (ne change rien dans Windows)', "Changer le mot de passe Windows de $($a.Name)") 'Choix'
  if ($i -lt 0) { return }
  if ($i -eq 0) { $password = Read-Host "Mot de passe Windows actuel de $($a.Name)" -AsSecureString }
  else {
    $password = Read-NewPassword $a.Name
    Set-LocalUser -Name $a.Name -Password $password
    Write-Log "Mot de passe Windows de $($a.Name) changé." OK
  }
  Set-AccountCredential $a $password
  Write-Log "Mot de passe de $($a.Name) enregistré pour la connexion automatique de sa session." OK
}

function Remove-MacroAccount {
  param($Cfg)
  $a = Select-OneAccount $Cfg
  if (-not $a) { return }
  if (-not (Confirm-Action "Retirer $($a.Name) de BSS Manager (sa session sera fermée) ?")) { return }
  [void](Close-AccountSession $a)
  Unregister-ScheduledTask -TaskPath $Script:Bss.TaskPath -TaskName (Get-NatroTaskName $a) -Confirm:$false -ErrorAction SilentlyContinue
  [BssNative]::DeleteCred((Get-CredTarget $a))
  $Cfg.Accounts = @($Cfg.Accounts | Where-Object { $_.Name -ne $a.Name })
  Save-BssConfig $Cfg
  Write-Log "$($a.Name) retiré de BSS Manager." OK
  if (Get-LocalUser -Name $a.Name -ErrorAction SilentlyContinue) {
    $typed = Read-Host "Pour SUPPRIMER aussi le compte Windows (définitif), tape « $($a.Name) ». Sinon Entrée"
    if ($typed -ceq $a.Name) {
      Remove-LocalUser -Name $a.Name
      Write-Log "Compte Windows $($a.Name) supprimé (le dossier C:\Users\$($a.Name) reste sur le disque)." OK
    }
  }
}

function Set-AutoLogonMenu {
  $state = Get-AutoLogonState
  Write-Host ('Connexion automatique : {0}' -f $(if ($state.Enabled) { "activée ($($state.User))" } else { 'désactivée' }))
  if ($state.Enabled) {
    if (Confirm-Action 'La désactiver et effacer le mot de passe stocké ?') { Disable-AutoLogon }
  } else {
    Write-Host 'Windows ouvrira ta session seul au démarrage, puis le superviseur relancera tout.' -ForegroundColor Cyan
    Write-Host 'Le mot de passe est stocké chiffré par Windows (secret LSA). Windows Hello seul sera désactivé.' -ForegroundColor Cyan
    if (Confirm-Action 'Activer la connexion automatique ?') { Enable-AutoLogon }
  }
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
  param($Cfg)
  while ($true) {
    Clear-Host
    Write-Host '=== Comptes et macros ===' -ForegroundColor Cyan
    foreach ($a in @($Cfg.Accounts)) {
      $flags = @()
      if (-not $a.Enabled) { $flags += 'exclu' }
      if ($a.Paused) { $flags += 'pause' }
      Write-Host ('  {0,-12} {1,-11} {2} {3}' -f $a.Name, $a.Ip, $(if ($a.MacroPath) { Split-Path $a.MacroPath -Leaf } else { '(aucune macro)' }), $(if ($flags) { "[$($flags -join ', ')]" } else { '' }))
    }
    Write-Host ''
    Write-Host '  1. Associer une macro à un compte'
    Write-Host '  2. Choisir la branche d''une macro (ou celle par défaut)'
    Write-Host '  3. Convertir une ancienne macro en version Cursed'
    Write-Host '  4. Pause / maintenance d''un compte'
    Write-Host '  5. Inclure / exclure un compte'
    Write-Host '  6. Créer un compte Windows macro'
    Write-Host '  7. Ajouter un compte Windows existant'
    Write-Host '  8. Mot de passe d''un compte'
    Write-Host '  9. Retirer un compte'
    Write-Host '  0. Retour'
    switch (Read-Host "`nChoix") {
      '1' { Invoke-MenuChoice { Set-AccountMacro $Cfg } }
      '2' { Invoke-MenuChoice { Set-MacroBranchMenu $Cfg } }
      '3' { Invoke-MenuChoice { Convert-MacroMenu $Cfg } }
      '4' { Invoke-MenuChoice { Switch-AccountPause $Cfg } }
      '5' { Invoke-MenuChoice { Switch-AccountEnabled $Cfg } }
      '6' { Invoke-MenuChoice { Add-NewMacroAccount $Cfg } }
      '7' { Invoke-MenuChoice { Add-ExistingAccount $Cfg } }
      '8' { Invoke-MenuChoice { Set-AccountPassword $Cfg } }
      '9' { Invoke-MenuChoice { Remove-MacroAccount $Cfg } }
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
  param($Cfg)
  while ($true) {
    Clear-Host
    Write-Host '=========================================' -ForegroundColor Cyan
    Write-Host '   BSS Manager - Natro Macro multi-RDP' -ForegroundColor Cyan
    Write-Host '=========================================' -ForegroundColor Cyan
    try {
      $w = Get-WrapperState $Cfg
      if ($w.Healthy) { Write-Host "RDP Wrapper    : OK (termsrv $($w.TermsrvVersion))" -ForegroundColor Green }
      else { Write-Host "RDP Wrapper    : À RÉPARER (termsrv $($w.TermsrvVersion)) -> 6" -ForegroundColor Red }
      $sup = Get-SupervisorStatus
      if ($sup -and $sup.Alive) { Write-Host "Superviseur    : actif (il y a $($sup.AgeSec) s)" -ForegroundColor Green }
      elseif ($sup) { Write-Host 'Superviseur    : ARRÊTÉ -> 8' -ForegroundColor Red }
      else { Write-Host 'Superviseur    : pas installé -> 8' -ForegroundColor Yellow }
      $sessions = Get-BssSessions
      $up = @($Cfg.Accounts | Where-Object { Test-SessionConnected (Get-AccountSession $_ $sessions) })
      Write-Host "Sessions macro : $($up.Count) / $(@($Cfg.Accounts | Where-Object { $_.Enabled }).Count) connectée(s)"
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
      '1' { Invoke-MenuChoice { Start-All $Cfg } }
      '2' { Invoke-MenuChoice { Show-StopMenu $Cfg } }
      '3' { Invoke-MenuChoice { Show-Status $Cfg } }
      '4' { Invoke-MenuChoice { Show-UpdateMenu $Cfg } }
      '5' { Show-AccountsMenu $Cfg }
      '6' { Invoke-MenuChoice { [void](Update-RdpWrapper $Cfg) } }
      '7' { Invoke-MenuChoice { Set-AutoLogonMenu } }
      '8' { Invoke-MenuChoice { Install-Manager $Cfg } }
      '9' { Invoke-MenuChoice { if (Confirm-Action 'Supprimer les tâches et raccourcis de BSS Manager ?') { Uninstall-Manager } } }
      '0' { return }
    }
  }
}
