[CmdletBinding()]
param(
    [string]$EnginePath = (Join-Path -Path $PSScriptRoot -ChildPath 'force_update_drivers_gpo_hardened.ps1'),
    [string]$DataRoot = (Join-Path -Path $env:ProgramData -ChildPath 'DriversUpdate')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$engineHost = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
$stateFile = Join-Path -Path $DataRoot -ChildPath 'state\state.json'
$logFile = Join-Path -Path $DataRoot -ChildPath 'logs\deploy.log'

function Show-Menu {
    Clear-Host
    Write-Host '  +----------------------------------------------+' -ForegroundColor DarkCyan
    Write-Host '  |           DRIVERSUPDATE - CONSOLE             |' -ForegroundColor Cyan
    Write-Host '  |     Pilotes Windows Update / WSUS - V2        |' -ForegroundColor DarkCyan
    Write-Host '  +----------------------------------------------+' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '  [1] Rechercher les pilotes (audit)'
    Write-Host '  [2] Simuler une installation (sans modification)'
    Write-Host '  [3] Selectionner et installer des pilotes' -ForegroundColor Yellow
    Write-Host '  [4] Consulter le dernier rapport'
    Write-Host '  [5] Afficher les 60 dernieres lignes du journal'
    Write-Host '  [0] Quitter'
    Write-Host ''
}

function Invoke-Engine {
    param([Parameter(Mandatory = $true)][string[]]$ModeArgs)
    Write-Host ''
    Write-Host 'Execution du moteur Windows Update...' -ForegroundColor Cyan
    & $engineHost -NoProfile -File $EnginePath @ModeArgs
    $code = [int]$LASTEXITCODE
    Write-Host ''
    if ($code -eq 3010) {
        Write-Host 'Installation terminee : un redemarrage est necessaire (aucun reboot automatique).' -ForegroundColor Yellow
    } elseif ($code -eq 0) {
        Write-Host 'Operation terminee. Consultez le rapport pour le resultat exact.' -ForegroundColor Green
    } else {
        Write-Host "Le moteur a retourne le code $code. Consultez le journal." -ForegroundColor Yellow
    }
}

function Show-LastReport {
    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
        Write-Host "Aucun rapport disponible : $stateFile" -ForegroundColor Yellow
        return
    }

    try {
        $state = Get-Content -LiteralPath $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        Write-Host ''
        Write-Host 'Dernier resultat' -ForegroundColor Cyan
        Write-Host ("  Machine       : {0}" -f $state.ComputerName)
        Write-Host ("  Date UTC      : {0}" -f $state.LastRunUtc)
        Write-Host ("  Mode          : {0}" -f $state.ScanMode)
        Write-Host ("  Source        : {0}" -f $state.UpdateSource)
        Write-Host ("  Statut        : {0} (code {1})" -f $state.LastOutcome, $state.LastExitCode)
        Write-Host ("  Detectes      : {0}" -f $state.UpdatesFound)
        Write-Host ("  Installes     : {0}" -f $state.UpdatesInstalled)
        Write-Host ("  Redemarrage   : {0}" -f $state.RebootRequired)
        $results = @($state.DriverResults)
        if ($results.Count -gt 0) {
            Write-Host ''
            $results | Select-Object Title, Class, Status, Detail | Format-Table -Wrap | Out-Host
        }
    } catch {
        Write-Host "Impossible de lire le rapport : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Show-LastLog {
    if (-not (Test-Path -LiteralPath $logFile -PathType Leaf)) {
        Write-Host "Aucun journal disponible : $logFile" -ForegroundColor Yellow
        return
    }
    Get-Content -LiteralPath $logFile -Tail 60 -ErrorAction Stop | Out-Host
}

if (-not (Test-Path -LiteralPath $EnginePath -PathType Leaf)) {
    throw "Moteur introuvable : $EnginePath. Conservez les deux fichiers dans le meme dossier."
}
if (-not (Test-Path -LiteralPath $engineHost -PathType Leaf)) {
    throw "Windows PowerShell introuvable : $engineHost"
}
if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
    throw 'La console interactive doit etre lancee dans un terminal Windows local.'
}

while ($true) {
    Show-Menu
    $choice = Read-Host '  Votre choix'
    try {
        switch ($choice) {
            '1' { Invoke-Engine -ModeArgs @('-ScanOnly') }
            '2' { Invoke-Engine -ModeArgs @('-DryRun') }
            '3' { Invoke-Engine -ModeArgs @('-Interactive') }
            '4' { Show-LastReport }
            '5' { Show-LastLog }
            '0' { return }
            default { Write-Host 'Choix invalide.' -ForegroundColor Yellow }
        }
    } catch {
        Write-Host "Erreur : $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ''
    [void](Read-Host 'Appuyez sur Entree pour revenir au menu')
}
