# Manual, interactive entry point. Uses the same GPO engine for every operation.
# Windows PowerShell 5.1 is used by the child process to keep WUA COM compatible.
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
        throw "Windows PowerShell 5.1 not found: $path"
    }
    return $path
}

function Invoke-ManualDriverUpdate {
    param([Parameter(Mandatory = $true)][ValidateSet('Scan', 'DryRun', 'Install')][string]$Mode)

    if (-not (Test-IsAdministrator)) {
        Write-Warning 'Open PowerShell as administrator to scan or install drivers.'
        return
    }
    if ($Mode -eq 'Install') {
        Write-Warning 'Drivers can affect hardware stability. Test on a pilot computer first.'
        if ((Read-Host 'Type INSTALLER to confirm installation') -cne 'INSTALLER') {
            Write-Host 'Installation cancelled.'
            return
        }
    }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $engineScript)
    switch ($Mode) {
        'Scan' { $arguments += '-ScanOnly' }
        'DryRun' { $arguments += '-DryRun' }
    }

    try {
        $powerShell = Get-WindowsPowerShellPath
        Write-Host ''
        Write-Host ("Starting {0} via Windows PowerShell 5.1..." -f $Mode) -ForegroundColor Cyan
        # Direct native invocation preserves individual arguments (including paths with spaces).
        # The engine calls exit, so it must run in a child process.
        & $powerShell @arguments
        $code = $LASTEXITCODE
        Write-Host ''
        if ($code -eq 3010) {
            Write-Warning 'Drivers installed. Reboot required (3010); no reboot will be triggered.'
        } elseif ($code -eq 0) {
            Write-Host 'Completed. Check the state file for details.' -ForegroundColor Green
        } else {
            Write-Warning "The operation returned exit code $code. Consult the log and state."
        }
    } catch {
        Write-Warning "Failed to launch the engine: $($_.Exception.Message)"
    }
}

function Show-LastState {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        Write-Warning "No saved state found: $statePath"
        return
    }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $state | Select-Object LastRunUtc, LastOutcome, LastExitCode, ScanMode, UpdateSource, UpdatesFound, UpdatesInstalled, RebootRequired | Format-List | Out-Host
        if ($state.DriverResults) {
            $state.DriverResults | Select-Object Title, Class, Status, Detail | Format-Table -AutoSize -Wrap | Out-Host
        }
    } catch {
        Write-Warning "Unable to read state: $($_.Exception.Message)"
    }
}

function Show-RecentLog {
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        Write-Warning "No log found: $logPath"
        return
    }
    try {
        Get-Content -LiteralPath $logPath -Tail 50 -ErrorAction Stop | Out-Host
    } catch {
        Write-Warning "Unable to read log: $($_.Exception.Message)"
    }
}

if (-not (Test-Path -LiteralPath $engineScript -PathType Leaf)) {
    throw "Missing required GPO engine beside this file: $engineScript"
}

while ($true) {
    Write-Host ''
    Write-Host '=== DriversUpdate - Manual ===' -ForegroundColor Cyan
    Write-Host '  1. Scan available drivers (no installation)'
    Write-Host '  2. Simulate selection (no installation)'
    Write-Host '  3. Install eligible drivers (confirmation required)'
    Write-Host '  4. View last result'
    Write-Host '  5. View last 50 log lines'
    Write-Host '  0. Quit'

    $choice = Read-Host 'Choice'
    switch ($choice) {
        '1' { Invoke-ManualDriverUpdate -Mode 'Scan' }
        '2' { Invoke-ManualDriverUpdate -Mode 'DryRun' }
        '3' { Invoke-ManualDriverUpdate -Mode 'Install' }
        '4' { Show-LastState }
        '5' { Show-RecentLog }
        '0' { return }
        default { Write-Warning 'Unknown choice.' }
    }
}
