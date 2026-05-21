[CmdletBinding()]
param(
    [string]$LogRoot = "$env:ProgramData\DriversUpdate\logs",
    [string]$StateRoot = "$env:ProgramData\DriversUpdate\state",
    [int]$MinimumScanIntervalHours = 24,
    [switch]$Force,
    [bool]$AcceptEula = $true,
    [switch]$TemporaryMicrosoftUpdateService
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptName = 'DriversUpdateGpo'
$ScriptVersion = '1.0.0'
$MicrosoftUpdateServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'

$ExitCodes = @{
    Success = 0
    RebootRequired = 3010
    UnsupportedPowerShell = 100
    NotElevated = 101
    Architecture = 102
    PrerequisiteFailed = 103
    SearchFailed = 110
    DownloadFailed = 120
    InstallFailed = 130
    PartialFailure = 140
    UnexpectedFailure = 199
}

$script:LogFile = Join-Path -Path $LogRoot -ChildPath 'deploy.log'
$script:StateFile = Join-Path -Path $StateRoot -ChildPath 'state.json'

function Initialize-LocalPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Write-Log {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff zzz'), $Level, $Message
    Write-Output $line

    try {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    } catch {
        Write-Output ('{0} [ERROR] Unable to write log file: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff zzz'), $_.Exception.Message)
    }
}

function Get-OperationResultName {
    param([int]$ResultCode)

    switch ($ResultCode) {
        0 { 'NotStarted' }
        1 { 'InProgress' }
        2 { 'Succeeded' }
        3 { 'SucceededWithErrors' }
        4 { 'Failed' }
        5 { 'Aborted' }
        default { "Unknown($ResultCode)" }
    }
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsLocalSystem {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ($identity.User.Value -eq 'S-1-5-18')
}

function Invoke-NativePowerShellIfRequired {
    if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::Is64BitProcess) {
        return $null
    }

    $nativePowerShell = Join-Path -Path $env:WINDIR -ChildPath 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $nativePowerShell -PathType Leaf)) {
        Write-Log -Level 'ERROR' -Message "64-bit PowerShell relaunch path not found: $nativePowerShell"
        return $ExitCodes.Architecture
    }

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-LogRoot', ('"{0}"' -f $LogRoot),
        '-StateRoot', ('"{0}"' -f $StateRoot),
        '-MinimumScanIntervalHours', $MinimumScanIntervalHours,
        ('-AcceptEula:{0}' -f $AcceptEula)
    )

    if ($Force) {
        $arguments += '-Force'
    }

    if ($TemporaryMicrosoftUpdateService) {
        $arguments += '-TemporaryMicrosoftUpdateService'
    }

    Write-Log -Message 'Relaunching through 64-bit Windows PowerShell.'
    $process = Start-Process -FilePath $nativePowerShell -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    return $process.ExitCode
}

function Get-RegistryValueOrNull {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    try {
        if (Test-Path -LiteralPath $Path) {
            return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
        }
    } catch {
        return $null
    }

    return $null
}

function Write-WindowsUpdatePolicySummary {
    $wuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'

    $values = [ordered]@{
        WUServer = Get-RegistryValueOrNull -Path $wuPath -Name 'WUServer'
        UseWUServer = Get-RegistryValueOrNull -Path $auPath -Name 'UseWUServer'
        ExcludeWUDriversInQualityUpdate = Get-RegistryValueOrNull -Path $wuPath -Name 'ExcludeWUDriversInQualityUpdate'
        DisableWindowsUpdateAccess = Get-RegistryValueOrNull -Path $wuPath -Name 'DisableWindowsUpdateAccess'
        DoNotConnectToWindowsUpdateInternetLocations = Get-RegistryValueOrNull -Path $wuPath -Name 'DoNotConnectToWindowsUpdateInternetLocations'
        SetPolicyDrivenUpdateSourceForDriverUpdates = Get-RegistryValueOrNull -Path $wuPath -Name 'SetPolicyDrivenUpdateSourceForDriverUpdates'
    }

    foreach ($key in $values.Keys) {
        $value = $values[$key]
        if ($null -ne $value -and $value -ne '') {
            Write-Log -Message "Windows Update policy: $key=$value"
        }
    }
}

function Ensure-ServiceRunning {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    foreach ($name in $Names) {
        $service = Get-Service -Name $name -ErrorAction Stop

        if ($service.Status -eq 'Running') {
            Write-Log -Message "Service $name is already running."
            continue
        }

        Write-Log -Message "Starting service $name. Current status: $($service.Status)."
        Start-Service -Name $name -ErrorAction Stop
        $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
        Write-Log -Message "Service $name is running."
    }
}

function Get-ComPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    try {
        return $Object.$Name
    } catch {
        return $null
    }
}

function Get-UpdateSummary {
    param([Parameter(Mandatory = $true)]$Update)

    $parts = @(
        "Title=$($Update.Title)",
        "Manufacturer=$(Get-ComPropertyValue -Object $Update -Name 'DriverManufacturer')",
        "Class=$(Get-ComPropertyValue -Object $Update -Name 'DriverClass')",
        "Model=$(Get-ComPropertyValue -Object $Update -Name 'DriverModel')",
        "Date=$(Get-ComPropertyValue -Object $Update -Name 'DriverVerDate')"
    )

    return ($parts -join '; ')
}

function Add-UpdateToCollection {
    param(
        [Parameter(Mandatory = $true)]$Collection,
        [Parameter(Mandatory = $true)]$Update
    )

    [void]$Collection.Add($Update)
}

function Save-State {
    param(
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Outcome,
        [int]$UpdatesFound = 0,
        [int]$UpdatesInstalled = 0,
        [bool]$RebootRequired = $false
    )

    $state = [ordered]@{
        ScriptName = $ScriptName
        ScriptVersion = $ScriptVersion
        ComputerName = $env:COMPUTERNAME
        LastRunUtc = (Get-Date).ToUniversalTime().ToString('o')
        LastExitCode = $ExitCode
        LastOutcome = $Outcome
        UpdatesFound = $UpdatesFound
        UpdatesInstalled = $UpdatesInstalled
        RebootRequired = $RebootRequired
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        OsVersion = [Environment]::OSVersion.VersionString
    }

    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
}

function Test-RecentSuccessfulRun {
    if ($Force -or $MinimumScanIntervalHours -le 0) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $script:StateFile -PathType Leaf)) {
        return $false
    }

    try {
        $state = Get-Content -LiteralPath $script:StateFile -Raw -ErrorAction Stop | ConvertFrom-Json
        if ([int]$state.LastExitCode -ne $ExitCodes.Success) {
            return $false
        }

        $lastRunUtc = [datetime]::Parse($state.LastRunUtc).ToUniversalTime()
        $nextRunUtc = $lastRunUtc.AddHours($MinimumScanIntervalHours)

        if ((Get-Date).ToUniversalTime() -lt $nextRunUtc) {
            Write-Log -Message "Skipping scan. Last successful run: $($lastRunUtc.ToString('o')); next allowed run: $($nextRunUtc.ToString('o')). Use -Force to override."
            return $true
        }
    } catch {
        Write-Log -Level 'WARN' -Message "State file is unreadable and will be ignored: $($_.Exception.Message)"
    }

    return $false
}

function Invoke-DriverUpdateDeployment {
    $updateServiceManager = $null
    $microsoftUpdateWasPresent = $false
    $microsoftUpdateAddedByScript = $false
    $updatesFound = 0
    $updatesInstalled = 0
    $rebootRequired = $false

    try {
        Write-Log -Message "Starting $ScriptName version $ScriptVersion."
        Write-Log -Message "Identity: $([Security.Principal.WindowsIdentity]::GetCurrent().Name); LocalSystem=$(Test-IsLocalSystem); Elevated=$(Test-IsElevated)."

        if ($PSVersionTable.PSVersion -lt [version]'5.1') {
            Write-Log -Level 'ERROR' -Message "Unsupported PowerShell version: $($PSVersionTable.PSVersion). Minimum required version is 5.1."
            Save-State -ExitCode $ExitCodes.UnsupportedPowerShell -Outcome 'UnsupportedPowerShell'
            return $ExitCodes.UnsupportedPowerShell
        }

        $nativeExitCode = Invoke-NativePowerShellIfRequired
        if ($null -ne $nativeExitCode) {
            return [int]$nativeExitCode
        }

        if (-not (Test-IsElevated)) {
            Write-Log -Level 'ERROR' -Message 'Administrative rights are required. Deploy through a computer GPO startup script or a GPO scheduled task running as SYSTEM.'
            Save-State -ExitCode $ExitCodes.NotElevated -Outcome 'NotElevated'
            return $ExitCodes.NotElevated
        }

        if ([Environment]::OSVersion.Version.Major -lt 10) {
            Write-Log -Level 'ERROR' -Message "Unsupported Windows version: $([Environment]::OSVersion.VersionString)."
            Save-State -ExitCode $ExitCodes.PrerequisiteFailed -Outcome 'UnsupportedWindows'
            return $ExitCodes.PrerequisiteFailed
        }

        Write-WindowsUpdatePolicySummary

        try {
            Ensure-ServiceRunning -Names @('wuauserv', 'bits', 'cryptsvc')
        } catch {
            Write-Log -Level 'ERROR' -Message "Required Windows Update service check failed: $($_.Exception.Message)"
            Save-State -ExitCode $ExitCodes.PrerequisiteFailed -Outcome 'PrerequisiteFailed'
            return $ExitCodes.PrerequisiteFailed
        }

        if (Test-RecentSuccessfulRun) {
            Save-State -ExitCode $ExitCodes.Success -Outcome 'SkippedRecentSuccessfulRun'
            return $ExitCodes.Success
        }

        try {
            $updateServiceManager = New-Object -ComObject Microsoft.Update.ServiceManager
            $registeredServices = @($updateServiceManager.Services)
            $microsoftUpdateService = $registeredServices | Where-Object { $_.ServiceID -eq $MicrosoftUpdateServiceId } | Select-Object -First 1

            if ($null -eq $microsoftUpdateService) {
                Write-Log -Message 'Microsoft Update service is not registered. Registering it for driver search.'
                [void]$updateServiceManager.AddService2($MicrosoftUpdateServiceId, 7, '')
                $microsoftUpdateAddedByScript = $true
            } else {
                $microsoftUpdateWasPresent = $true
                Write-Log -Message 'Microsoft Update service is already registered.'
            }
        } catch {
            Write-Log -Level 'ERROR' -Message "Unable to register or inspect Microsoft Update service: $($_.Exception.Message)"
            Save-State -ExitCode $ExitCodes.PrerequisiteFailed -Outcome 'MicrosoftUpdateServiceFailed'
            return $ExitCodes.PrerequisiteFailed
        }

        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $session.ClientApplicationID = $ScriptName

            $searcher = $session.CreateUpdateSearcher()
            $searcher.ServiceID = $MicrosoftUpdateServiceId
            $searcher.SearchScope = 1
            $searcher.ServerSelection = 3

            $criteria = "IsInstalled=0 and IsHidden=0 and Type='Driver'"
            Write-Log -Message "Searching driver updates with criteria: $criteria"
            $searchResult = $searcher.Search($criteria)
            $updates = $searchResult.Updates
            $updatesFound = $updates.Count
            Write-Log -Message "Search result: $(Get-OperationResultName -ResultCode ([int]$searchResult.ResultCode)); updates found: $updatesFound."
        } catch {
            Write-Log -Level 'ERROR' -Message "Driver update search failed: $($_.Exception.Message)"
            Save-State -ExitCode $ExitCodes.SearchFailed -Outcome 'SearchFailed'
            return $ExitCodes.SearchFailed
        }

        if ($updatesFound -eq 0) {
            Write-Log -Message 'No applicable driver update found.'
            Save-State -ExitCode $ExitCodes.Success -Outcome 'NoUpdatesFound' -UpdatesFound 0
            return $ExitCodes.Success
        }

        $installCandidates = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($index = 0; $index -lt $updates.Count; $index++) {
            $update = $updates.Item($index)
            Write-Log -Message "Candidate update: $(Get-UpdateSummary -Update $update)"

            $canRequestUserInput = $false
            try {
                $canRequestUserInput = [bool]$update.InstallationBehavior.CanRequestUserInput
            } catch {
                $canRequestUserInput = $false
            }

            if ($canRequestUserInput) {
                Write-Log -Level 'WARN' -Message "Skipping update because it can request user input: $($update.Title)"
                continue
            }

            if (-not $update.EulaAccepted) {
                if ($AcceptEula) {
                    Write-Log -Message "Accepting EULA for update: $($update.Title)"
                    $update.AcceptEula()
                } else {
                    Write-Log -Level 'WARN' -Message "Skipping update because EULA is not accepted and AcceptEula is false: $($update.Title)"
                    continue
                }
            }

            Add-UpdateToCollection -Collection $installCandidates -Update $update
        }

        if ($installCandidates.Count -eq 0) {
            Write-Log -Level 'WARN' -Message 'No silent install candidate remains after filtering.'
            Save-State -ExitCode $ExitCodes.Success -Outcome 'NoSilentCandidates' -UpdatesFound $updatesFound
            return $ExitCodes.Success
        }

        $downloadCollection = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($index = 0; $index -lt $installCandidates.Count; $index++) {
            $update = $installCandidates.Item($index)
            if (-not $update.IsDownloaded) {
                Add-UpdateToCollection -Collection $downloadCollection -Update $update
            }
        }

        $partialFailure = $false
        if ($downloadCollection.Count -gt 0) {
            try {
                Write-Log -Message "Downloading $($downloadCollection.Count) driver update(s)."
                $downloader = $session.CreateUpdateDownloader()
                $downloader.Updates = $downloadCollection
                $downloadResult = $downloader.Download()
                $downloadResultName = Get-OperationResultName -ResultCode ([int]$downloadResult.ResultCode)
                Write-Log -Message "Download result: $downloadResultName."

                if ($downloadResult.ResultCode -eq 3) {
                    $partialFailure = $true
                } elseif ($downloadResult.ResultCode -ne 2) {
                    Save-State -ExitCode $ExitCodes.DownloadFailed -Outcome 'DownloadFailed' -UpdatesFound $updatesFound
                    return $ExitCodes.DownloadFailed
                }
            } catch {
                Write-Log -Level 'ERROR' -Message "Driver update download failed: $($_.Exception.Message)"
                Save-State -ExitCode $ExitCodes.DownloadFailed -Outcome 'DownloadFailed' -UpdatesFound $updatesFound
                return $ExitCodes.DownloadFailed
            }
        } else {
            Write-Log -Message 'All candidate updates are already downloaded.'
        }

        $readyToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($index = 0; $index -lt $installCandidates.Count; $index++) {
            $update = $installCandidates.Item($index)
            if ($update.IsDownloaded) {
                Add-UpdateToCollection -Collection $readyToInstall -Update $update
            } else {
                Write-Log -Level 'WARN' -Message "Update is not downloaded and will not be installed: $($update.Title)"
            }
        }

        if ($readyToInstall.Count -eq 0) {
            Write-Log -Level 'ERROR' -Message 'No downloaded driver update is available for installation.'
            Save-State -ExitCode $ExitCodes.DownloadFailed -Outcome 'NoDownloadedUpdates' -UpdatesFound $updatesFound
            return $ExitCodes.DownloadFailed
        }

        try {
            Write-Log -Message "Installing $($readyToInstall.Count) driver update(s)."
            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $readyToInstall
            $installationResult = $installer.Install()
            $installResultName = Get-OperationResultName -ResultCode ([int]$installationResult.ResultCode)
            $rebootRequired = [bool]$installationResult.RebootRequired
            Write-Log -Message "Installation result: $installResultName; reboot required: $rebootRequired."

            for ($index = 0; $index -lt $readyToInstall.Count; $index++) {
                $update = $readyToInstall.Item($index)
                $updateResult = $installationResult.GetUpdateResult($index)
                $resultName = Get-OperationResultName -ResultCode ([int]$updateResult.ResultCode)
                Write-Log -Message "Per-update result: $resultName; HResult=$($updateResult.HResult); Title=$($update.Title)"
                if ($updateResult.ResultCode -eq 2) {
                    $updatesInstalled++
                }
            }

            if ($installationResult.ResultCode -eq 3) {
                $partialFailure = $true
            } elseif ($installationResult.ResultCode -ne 2) {
                Save-State -ExitCode $ExitCodes.InstallFailed -Outcome 'InstallFailed' -UpdatesFound $updatesFound -UpdatesInstalled $updatesInstalled -RebootRequired $rebootRequired
                return $ExitCodes.InstallFailed
            }
        } catch {
            Write-Log -Level 'ERROR' -Message "Driver update installation failed: $($_.Exception.Message)"
            Save-State -ExitCode $ExitCodes.InstallFailed -Outcome 'InstallFailed' -UpdatesFound $updatesFound -UpdatesInstalled $updatesInstalled -RebootRequired $rebootRequired
            return $ExitCodes.InstallFailed
        }

        if ($partialFailure) {
            Write-Log -Level 'WARN' -Message 'Operation completed with partial errors. See per-update results above.'
            Save-State -ExitCode $ExitCodes.PartialFailure -Outcome 'PartialFailure' -UpdatesFound $updatesFound -UpdatesInstalled $updatesInstalled -RebootRequired $rebootRequired
            return $ExitCodes.PartialFailure
        }

        if ($rebootRequired) {
            Save-State -ExitCode $ExitCodes.RebootRequired -Outcome 'SuccessRebootRequired' -UpdatesFound $updatesFound -UpdatesInstalled $updatesInstalled -RebootRequired $true
            return $ExitCodes.RebootRequired
        }

        Save-State -ExitCode $ExitCodes.Success -Outcome 'Success' -UpdatesFound $updatesFound -UpdatesInstalled $updatesInstalled -RebootRequired $false
        return $ExitCodes.Success
    } catch {
        Write-Log -Level 'ERROR' -Message "Unexpected failure: $($_.Exception.Message)"
        Save-State -ExitCode $ExitCodes.UnexpectedFailure -Outcome 'UnexpectedFailure' -UpdatesFound $updatesFound -UpdatesInstalled $updatesInstalled -RebootRequired $rebootRequired
        return $ExitCodes.UnexpectedFailure
    } finally {
        if ($TemporaryMicrosoftUpdateService -and $microsoftUpdateAddedByScript -and -not $microsoftUpdateWasPresent -and $null -ne $updateServiceManager) {
            try {
                Write-Log -Message 'Removing Microsoft Update service because -TemporaryMicrosoftUpdateService was specified and the service was added by this script.'
                $updateServiceManager.RemoveService($MicrosoftUpdateServiceId)
            } catch {
                Write-Log -Level 'WARN' -Message "Unable to remove Microsoft Update service: $($_.Exception.Message)"
            }
        }

        Write-Log -Message "Finished $ScriptName."
    }
}

try {
    Initialize-LocalPath -Path $LogRoot
    Initialize-LocalPath -Path $StateRoot
} catch {
    Write-Output "Unable to initialize local folders. $($_.Exception.Message)"
    exit $ExitCodes.PrerequisiteFailed
}

$exitCode = Invoke-DriverUpdateDeployment
Write-Log -Message "Exit code: $exitCode"
exit $exitCode
