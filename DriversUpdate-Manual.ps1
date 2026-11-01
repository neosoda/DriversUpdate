<#
.SYNOPSIS
    Console en français pour rechercher et installer les pilotes Windows.
.DESCRIPTION
    Interface utilisateur du moteur partagé avec le déploiement GPO.
    Aucun pilote n'est installé sans sélection et confirmation explicite.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$engineScript = Join-Path -Path $PSScriptRoot -ChildPath 'force_update_drivers_gpo_hardened.ps1'
$programDataPath = Join-Path -Path $env:ProgramData -ChildPath 'DriversUpdate'
$statePath = Join-Path -Path $programDataPath -ChildPath 'state\state.json'
$logPath = Join-Path -Path $programDataPath -ChildPath 'logs\deploy.log'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WindowsPowerShellPath {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $path = Join-Path -Path $env:WINDIR -ChildPath 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    } else {
        $path = Join-Path -Path $env:WINDIR -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Windows PowerShell 5.1 est introuvable : $path"
    }
    return $path
}

function Get-ModeLabel {
    param([string]$Mode)
    switch ($Mode) {
        'ScanOnly' { return 'Recherche seule' }
        'DryRun' { return 'Simulation sans installation' }
        'Interactive' { return 'Installation manuelle' }
        'Install' { return 'Installation automatique (GPO)' }
        default { return $Mode }
    }
}

function Get-OutcomeLabel {
    param([string]$Outcome)
    switch ($Outcome) {
        'Success' { return 'Installation terminée' }
        'SuccessRebootRequired' { return 'Installation terminée, redémarrage nécessaire' }
        'NoUpdatesFound' { return 'Aucune mise à jour de pilote disponible' }
        'NoEligibleCandidates' { return 'Aucun pilote autorisé par les filtres' }
        'ScanOnly' { return 'Recherche terminée' }
        'DryRun' { return 'Simulation terminée' }
        'CancelledByUser' { return 'Installation annulée' }
        'SkippedPolicy' { return 'Recherche interdite par les stratégies Windows Update' }
        'SkippedRecentSuccessfulRun' { return 'Recherche non nécessaire (exécution récente)' }
        'InteractiveConsoleRequired' { return 'Console interactive indisponible' }
        'PolicyConflict' { return 'Stratégies Windows Update contradictoires' }
        'InvalidConfig' { return 'Configuration invalide' }
        'SearchFailed' { return 'Échec de la recherche des pilotes' }
        'DownloadFailed' { return 'Échec du téléchargement' }
        'NoDownloadedUpdates' { return 'Aucun pilote téléchargé' }
        'InstallFailed' { return "Échec de l'installation" }
        'PartialFailure' { return 'Installation partiellement réussie' }
        'PrerequisiteFailed' { return 'Prérequis non satisfaits' }
        'NotElevated' { return "Droits administrateur manquants" }
        'UnexpectedFailure' { return 'Erreur inattendue' }
        default { return $Outcome }
    }
}

function Get-DriverReasonLabel {
    param([string]$Detail)
    switch -Regex ($Detail) {
        '^ExcludedClass:' { return "Catégorie protégée : $($Detail.Substring(14))" }
        '^ExcludedTitle:' { return "Mot-clé exclu : $($Detail.Substring(14))" }
        '^NotAllowlisted$' { return 'Non autorisé par la liste des titres' }
        '^RequiresInteraction$' { return "Intervention utilisateur nécessaire" }
        '^InteractionUnknown$' { return "Installation silencieuse non garantie" }
        '^EulaNotAccepted$' { return 'Licence non acceptée' }
        '^EulaUnknown$' { return 'Licence impossible à vérifier' }
        '^NotSelected$' { return "Non sélectionné" }
        default { return $Detail }
    }
}

function Get-DriverResultLabel {
    param([string]$Status, [string]$Detail)
    switch ($Status) {
        'Eligible' { return 'Disponible' }
        'Skipped' { return "Exclu : $(Get-DriverReasonLabel -Detail $Detail)" }
        'Succeeded' { return 'Installé' }
        'SucceededWithErrors' { return 'Installé avec avertissements' }
        'Failed' { return 'Échec' }
        'Aborted' { return 'Interrompu' }
        default { return $Status }
    }
}

function Show-LastState {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        Write-Host 'Aucun bilan disponible. Lancez une recherche pour commencer.' -ForegroundColor Yellow
        return
    }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $dateLabel = [string]$state.LastRunUtc
        try {
            $dateLabel = ([datetime]::Parse($dateLabel)).ToLocalTime().ToString('dd/MM/yyyy à HH:mm')
        } catch {
            # La date brute reste visible si l'horodatage est incorrect.
        }

        Write-Host ''
        Write-Host '  DERNIER BILAN' -ForegroundColor Cyan
        Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host ("  Date                 : {0}" -f $dateLabel)
        Write-Host ("  Machine              : {0}" -f $state.ComputerName)
        Write-Host ("  Mode                 : {0}" -f (Get-ModeLabel -Mode ([string]$state.ScanMode)))
        Write-Host ("  Résultat             : {0}" -f (Get-OutcomeLabel -Outcome ([string]$state.LastOutcome)))
        Write-Host ("  Pilotes détectés     : {0}" -f $state.UpdatesFound)
        Write-Host ("  Pilotes installés    : {0}" -f $state.UpdatesInstalled)
        if ([bool]$state.RebootRequired) {
            Write-Host '  Redémarrage          : nécessaire (non automatique)' -ForegroundColor Yellow
        } else {
            Write-Host '  Redémarrage          : non demandé par Windows Update'
        }

        $results = @($state.DriverResults | Where-Object { $null -ne $_ })
        if ($results.Count -gt 0) {
            Write-Host ''
            Write-Host '  DÉTAIL DES PILOTES' -ForegroundColor Cyan
            Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
            $isAudit = ([string]$state.ScanMode -in @('ScanOnly', 'DryRun'))
            foreach ($driver in $results) {
                # Un pilote installé figure d'abord comme candidat, puis comme résultat :
                # ne pas afficher deux fois la même opération dans le bilan final.
                if (-not $isAudit -and $driver.Status -eq 'Eligible') { continue }
                $label = Get-DriverResultLabel -Status ([string]$driver.Status) -Detail ([string]$driver.Detail)
                $color = if ($driver.Status -eq 'Skipped') { 'DarkYellow' } elseif ($driver.Status -in @('Failed', 'Aborted')) { 'Red' } else { 'Green' }
                Write-Host ("  {0}" -f $driver.Title)
                Write-Host ("      {0}" -f $label) -ForegroundColor $color
            }
        }
        Write-Host ''
        Write-Host ("  Journal technique : {0}" -f $logPath) -ForegroundColor DarkGray
    } catch {
        Write-Host ("Impossible de lire le bilan : {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Show-RecentLog {
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        Write-Host 'Aucun journal disponible pour le moment.' -ForegroundColor Yellow
        return
    }
    Write-Host ''
    Write-Host '  JOURNAL TECHNIQUE : 40 DERNIÈRES LIGNES' -ForegroundColor Cyan
    Write-Host '  Les détails techniques peuvent être en anglais.' -ForegroundColor DarkGray
    Write-Host ("  Fichier : {0}" -f $logPath) -ForegroundColor DarkGray
    Write-Host ''
    try {
        Get-Content -LiteralPath $logPath -Tail 40 -ErrorAction Stop | Out-Host
    } catch {
        Write-Host ("Impossible de lire le journal : {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Invoke-ManualDriverUpdate {
    param([Parameter(Mandatory = $true)][ValidateSet('Scan', 'Install')][string]$Mode)

    if (-not (Test-IsAdministrator)) {
        Write-Host ''
        Write-Host 'Cette opération nécessite des droits administrateur.' -ForegroundColor Yellow
        Write-Host "Fermez cette fenêtre et ouvrez Windows PowerShell avec « Exécuter en tant qu’administrateur »."
        return
    }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engineScript, '-UserFacing')
    if ($Mode -eq 'Scan') { $arguments += '-ScanOnly' }
    if ($Mode -eq 'Install') { $arguments += '-Interactive' }

    Write-Host ''
    if ($Mode -eq 'Scan') {
        Write-Host '  RECHERCHE DES PILOTES' -ForegroundColor Cyan
        Write-Host "  Windows Update va rechercher les pilotes disponibles sur cet ordinateur."
        Write-Host "  Aucun pilote ne sera téléchargé ni installé." -ForegroundColor Green
    } else {
        Write-Host '  INSTALLATION MANUELLE' -ForegroundColor Cyan
        Write-Host '  1. Recherche des pilotes disponibles'
        Write-Host '  2. Choix des pilotes autorisés'
        Write-Host "  3. Vérification et confirmation avant installation"
        Write-Host ''
        Write-Host '  Aucune modification avant votre confirmation.' -ForegroundColor Yellow
    }
    Write-Host ''
    try {
        $powerShell = Get-WindowsPowerShellPath
        & $powerShell @arguments
        $code = [int]$LASTEXITCODE
        Write-Host ''
        if ($code -eq 3010) {
            Write-Host 'Installation effectuée. Un redémarrage sera nécessaire.' -ForegroundColor Yellow
            Write-Host 'Le programme ne redémarre jamais automatiquement le PC.'
        } elseif ($code -eq 0) {
            Write-Host 'Opération terminée.' -ForegroundColor Green
        } else {
            Write-Host ("L'opération a rencontré un problème (code {0})." -f $code) -ForegroundColor Red
            Write-Host 'Le bilan et le journal ci-dessous peuvent aider à comprendre pourquoi.'
        }
        Show-LastState
    } catch {
        Write-Host ("Impossible de lancer Windows Update : {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Show-MainMenu {
    try { Clear-Host } catch { Write-Host '' }
    Write-Host ''
    Write-Host '  ========================================================' -ForegroundColor DarkCyan
    Write-Host '     DRIVERSUPDATE  |  GESTION DES PILOTES WINDOWS' -ForegroundColor Cyan
    Write-Host '  ========================================================' -ForegroundColor DarkCyan
    Write-Host ("  Ordinateur : {0}" -f $env:COMPUTERNAME)
    if (Test-IsAdministrator) {
        Write-Host '  Autorisations : administrateur' -ForegroundColor DarkGreen
    } else {
        Write-Host '  Autorisations : administrateur requis pour agir' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '  QUE VOULEZ-VOUS FAIRE ?' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  [1] Rechercher les pilotes disponibles' -ForegroundColor White
    Write-Host '      Consulter uniquement, sans rien installer.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [2] Choisir les pilotes à installer' -ForegroundColor White
    Write-Host '      Sélection puis confirmation obligatoire.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [3] Afficher le dernier bilan'
    Write-Host '  [4] Consulter le journal technique'
    Write-Host '  [0] Quitter'
    Write-Host ''
}

if (-not (Test-Path -LiteralPath $engineScript -PathType Leaf)) {
    throw "Le moteur DriversUpdate est introuvable : $engineScript. Conservez les deux scripts dans le même dossier."
}
if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
    throw 'Le menu doit être lancé dans une console Windows interactive, et non par GPO ou entrée redirigée.'
}

while ($true) {
    Show-MainMenu
    $choice = Read-Host '  Votre choix (0 à 4)'
    try {
        switch ($choice.Trim()) {
            '1' { Invoke-ManualDriverUpdate -Mode 'Scan' }
            '2' { Invoke-ManualDriverUpdate -Mode 'Install' }
            '3' { Show-LastState }
            '4' { Show-RecentLog }
            '0' { return }
            default { Write-Host 'Choix non reconnu. Saisissez un chiffre entre 0 et 4.' -ForegroundColor Yellow }
        }
    } catch {
        Write-Host ("Une erreur est survenue : {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    Write-Host ''
    [void](Read-Host 'Appuyez sur Entrée pour revenir au menu')
}
