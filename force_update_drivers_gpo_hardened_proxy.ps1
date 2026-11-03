<# 
.SYNOPSIS
    Pilotes Windows Update derriere proxy, y compris sous SYSTEM sans session utilisateur.
.DESCRIPTION
    Lanceur proxy distinct : valide config.proxy.json puis delegue au moteur GPO
    commun. Le moteur gere WinHTTP, l'authentification, les sauvegardes
    et la restauration (meme apres echec).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$env:ProgramData\DriversUpdate\config.proxy.json",
    [string]$LogRoot = "$env:ProgramData\DriversUpdate\logs",
    [string]$StateRoot = "$env:ProgramData\DriversUpdate\state",
    [int]$MinimumScanIntervalHours = 24,
    [switch]$Force,
    [switch]$ScanOnly,
    [switch]$DryRun,
    [bool]$AcceptEula = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$engineScript = Join-Path -Path $PSScriptRoot -ChildPath 'force_update_drivers_gpo_hardened.ps1'

try {
    if (-not (Test-Path -LiteralPath $engineScript -PathType Leaf)) {
        throw "Moteur DriversUpdate introuvable : $engineScript"
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuration proxy introuvable : $ConfigPath. Copiez config.proxy.example.json vers cet emplacement."
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $config.Proxy -or [string]$config.Proxy.Mode -ne 'Temporary') {
        throw "Cette version exige Proxy.Mode = Temporary dans $ConfigPath."
    }

    $arguments = @{
        ConfigPath = $ConfigPath
        LogRoot = $LogRoot
        StateRoot = $StateRoot
        MinimumScanIntervalHours = $MinimumScanIntervalHours
        AcceptEula = $AcceptEula
    }
    if ($Force)    { $arguments.Force = $true }
    if ($ScanOnly) { $arguments.ScanOnly = $true }
    if ($DryRun)   { $arguments.DryRun = $true }

    # Le moteur conserve les codes retour existants : 0, 3010, 103, 110...
    & $engineScript @arguments
    exit $LASTEXITCODE
} catch {
    Write-Error -Message ("DriversUpdate Proxy : {0}" -f $_.Exception.Message) -ErrorAction Continue
    exit 103
}
