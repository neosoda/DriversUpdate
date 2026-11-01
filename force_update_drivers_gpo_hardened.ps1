[CmdletBinding()]
param(
    [string]$LogRoot = "$env:ProgramData\DriversUpdate\logs",
    [string]$StateRoot = "$env:ProgramData\DriversUpdate\state",
    [int]$MinimumScanIntervalHours = 24,
    [switch]$Force,
    [switch]$ScanOnly,
    [switch]$DryRun,
    [string]$ConfigPath = "$env:ProgramData\DriversUpdate\config.json",
    [bool]$AcceptEula = $true,
    [switch]$TemporaryMicrosoftUpdateService,
    [switch]$Interactive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptName = 'DriversUpdateGpo'
$ScriptVersion = '2.0.0'

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
    ConcurrentRun = 150
    PolicyBlocked = 160
    UnexpectedFailure = 199
}

$script:LogFile = Join-Path -Path $LogRoot -ChildPath 'deploy.log'
$script:StateFile = Join-Path -Path $StateRoot -ChildPath 'state.json'
$script:ScanAttempted = $false
$script:ScanSucceeded = $false
$script:DriverResults = New-Object System.Collections.ArrayList
$script:Configuration = $null
$script:UpdateSource = 'Default'

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
    Write-Host $line

    try {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    } catch {
        Write-Host ('{0} [ERROR] Unable to write log file: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff zzz'), $_.Exception.Message)
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

    # Pass an encoded command to avoid Start-Process joining and misquoting
    # arbitrary paths. Keep the boolean as an actual PowerShell literal.
    $quote = { param([string]$Text) "'" + $Text.Replace("'", "''") + "'" }
    $pathLiteral = & $quote $PSCommandPath
    $logRootLiteral = & $quote $LogRoot
    $stateRootLiteral = & $quote $StateRoot
    $configPathLiteral = & $quote $ConfigPath
    $command = '& {0} -LogRoot {1} -StateRoot {2} -MinimumScanIntervalHours {3} -AcceptEula:${4} -ConfigPath {5}' -f $pathLiteral, $logRootLiteral, $stateRootLiteral, $MinimumScanIntervalHours, ([string]$AcceptEula).ToLowerInvariant(), $configPathLiteral

    if ($Force) { $command += ' -Force' }
    if ($ScanOnly) { $command += ' -ScanOnly' }
    if ($DryRun) { $command += ' -DryRun' }
    if ($Interactive) { $command += ' -Interactive' }
    if ($TemporaryMicrosoftUpdateService) { $command += ' -TemporaryMicrosoftUpdateService' }
    $command += '; exit $LASTEXITCODE'

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Write-Log -Message 'Relaunching through 64-bit Windows PowerShell.'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand)
    if ($Interactive) {
        $process = Start-Process -FilePath $nativePowerShell -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    } else {
        $process = Start-Process -FilePath $nativePowerShell -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    }
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


function Get-PreviousState {
    if (-not (Test-Path -LiteralPath $script:StateFile -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $script:StateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
    catch { Write-Log -Level 'WARN' -Message "Ignoring invalid state: $($_.Exception.Message)"; return $null }
}

function Get-PropertyOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return ,$property.Value
}

function Get-DriverConfiguration {
    $config = [ordered]@{
        ExcludedDriverClasses = @('Firmware', 'Net', 'SCSIAdapter', 'HDC', 'DiskDrive')
        ExcludedTitleContains = @('BIOS', 'Firmware')
        IncludedTitleContains = @()
    }
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $inputConfig = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($key in @($config.Keys)) {
            $value = Get-PropertyOrNull -Object $inputConfig -Name $key
            if ($null -ne $value) {
                if ($value -isnot [array]) { throw "$key must be an array in $ConfigPath" }
                foreach ($entry in $value) {
                    if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) {
                        throw "$key contains an invalid string in $ConfigPath"
                    }
                }
                $config[$key] = @($value)
            }
        }
        Write-Log -Message "Loaded driver filters from $ConfigPath"
    } else {
        Write-Log -Message 'Using built-in driver safety filters.'
    }
    return $config
}

function Get-DriverExclusionReason {
    param([Parameter(Mandatory = $true)]$Update)
    $title = [string]$Update.Title
    $driverClass = [string](Get-ComPropertyValue -Object $Update -Name 'DriverClass')
    foreach ($class in $script:Configuration['ExcludedDriverClasses']) {
        if ($driverClass -ieq $class) { return "ExcludedClass:$class" }
    }
    foreach ($part in $script:Configuration['ExcludedTitleContains']) {
        if ($title.IndexOf($part, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return "ExcludedTitle:$part"
        }
    }
    if ($script:Configuration['IncludedTitleContains'].Count -gt 0) {
        $allowed = $false
        foreach ($part in $script:Configuration['IncludedTitleContains']) {
            if ($title.IndexOf($part, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $allowed = $true; break }
        }
        if (-not $allowed) { return 'NotAllowlisted' }
    }
    return $null
}

# One eligibility policy for the preview and for installation.
function Get-DriverEligibilityReason {
    param([Parameter(Mandatory = $true)]$Update)
    try {
        if ([bool]$Update.InstallationBehavior.CanRequestUserInput) { return 'RequiresInteraction' }
    } catch {
        return 'InteractionUnknown' # An unreadable COM flag must fail closed.
    }
    $exclusion = Get-DriverExclusionReason -Update $Update
    if ($null -ne $exclusion) { return $exclusion }
    if (-not $AcceptEula) {
        try { if (-not [bool]$Update.EulaAccepted) { return 'EulaNotAccepted' } }
        catch { return 'EulaUnknown' }
    }
    return $null
}

function ConvertTo-DriverSelection {
    param(
        [AllowEmptyString()][string]$InputText,
        [int[]]$EligibleNumbers,
        [int]$MaxIndex
    )
    $value = $InputText.Trim()
    if ($value -eq '' -or $value -eq '0') { return }
    if ($value -match '^(?i:t|tous|all)$') {
        foreach ($number in $EligibleNumbers) { Write-Output $number }
        return
    }
    $selected = @{}
    foreach ($token in ($value -split ',')) {
        # Positive -match populates $Matches; -notmatch does not update it.
        if ($token -match '^\s*(\d+)(?:\s*-\s*(\d+))?\s*
        if ($first -lt 1 -or $last -lt $first -or $last -gt $MaxIndex) {
            throw "Plage hors limites : $token"
        }
        for ($number = $first; $number -le $last; $number++) {
            if ($number -notin $EligibleNumbers) { throw "Pilote $number exclu ou non eligible." }
            $selected[$number] = $true
        }
    }
    foreach ($number in ($selected.Keys | Sort-Object)) { Write-Output ([int]$number) }
}

function Read-InteractiveDriverChoice {
    param([Parameter(Mandatory = $true)]$Updates)
    $eligible = New-Object 'System.Collections.Generic.List[int]'
    Write-Host ''
    Write-Host 'PILOTES DETECTES - selection manuelle' -ForegroundColor Cyan
    Write-Host 'Les pilotes exclus ne sont pas selectionnables.' -ForegroundColor DarkGray
    for ($index = 0; $index -lt $Updates.Count; $index++) {
        $update = $Updates.Item($index)
        $number = $index + 1
        $reason = Get-DriverEligibilityReason -Update $update
        if ($reason) {
            Write-Host ("[{0,2}] EXCLU ({1}) - {2}" -f $number, $reason, $update.Title) -ForegroundColor DarkYellow
        } else {
            $eligible.Add($number)
            Write-Host ("[{0,2}] OK - {1}" -f $number, $update.Title) -ForegroundColor Green
        }
        Write-Host ("     {0} / {1}" -f (Get-ComPropertyValue -Object $update -Name 'DriverManufacturer'), (Get-ComPropertyValue -Object $update -Name 'DriverClass')) -ForegroundColor DarkGray
    }
    if ($eligible.Count -eq 0) {
        Write-Host 'Aucun pilote eligible.' -ForegroundColor Yellow
        return [pscustomobject]@{ Cancelled = $true; SelectedIndices = @() }
    }
    Write-Host ''
    Write-Host 'Numeros : 1,3-5 | T : tous les eligibles | 0 : annuler'
    while ($true) {
        $answer = Read-Host 'Votre selection'
        try { $selected = @(ConvertTo-DriverSelection -InputText $answer -EligibleNumbers $eligible.ToArray() -MaxIndex $Updates.Count) }
        catch { Write-Host $_.Exception.Message -ForegroundColor Yellow; continue }
        if ($selected.Count -eq 0) { return [pscustomobject]@{ Cancelled = $true; SelectedIndices = @() } }
        Write-Host ''
        Write-Host 'Installation prevue :' -ForegroundColor Yellow
        foreach ($number in $selected) { Write-Host ("  - {0}" -f $Updates.Item($number - 1).Title) }
        Write-Host 'Les pilotes seront telecharges et installes; redemarrage potentiellement necessaire.' -ForegroundColor Yellow
        if ((Read-Host 'Tapez INSTALLER pour confirmer') -cne 'INSTALLER') {
            return [pscustomobject]@{ Cancelled = $true; SelectedIndices = @() }
        }
        return [pscustomobject]@{ Cancelled = $false; SelectedIndices = @($selected) }
    }
}

function Add-DriverResult {
    param($Update, [string]$Status, [string]$Detail = '')
    [void]$script:DriverResults.Add([ordered]@{
        Title = [string]$Update.Title
        Manufacturer = [string](Get-ComPropertyValue -Object $Update -Name 'DriverManufacturer')
        Class = [string](Get-ComPropertyValue -Object $Update -Name 'DriverClass')
        Status = $Status
        Detail = $Detail
    })
}

function Rotate-Log {
    if (-not (Test-Path -LiteralPath $script:LogFile -PathType Leaf)) { return }
    if ((Get-Item -LiteralPath $script:LogFile).Length -lt 5MB) { return }
    for ($i = 3; $i -ge 1; $i--) {
        $old = "$($script:LogFile).$i"
        if (Test-Path -LiteralPath $old) {
            if ($i -eq 3) { Remove-Item -LiteralPath $old -Force }
            else { Move-Item -LiteralPath $old -Destination "$($script:LogFile).$($i + 1)" -Force }
        }
    }
    Move-Item -LiteralPath $script:LogFile -Destination "$($script:LogFile).1" -Force
}

function Save-State {
    param(
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Outcome,
        [int]$UpdatesFound = 0,
        [int]$UpdatesInstalled = 0,
        [bool]$RebootRequired = $false
    )

    $previous = Get-PreviousState
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $lastScan = Get-PropertyOrNull -Object $previous -Name 'LastScanUtc'
    $lastSuccessfulScan = Get-PropertyOrNull -Object $previous -Name 'LastSuccessfulScanUtc'
    $lastDeployment = Get-PropertyOrNull -Object $previous -Name 'LastSuccessfulDeploymentUtc'
    if (-not $lastDeployment -and $null -ne $previous) {
        $oldOutcome = Get-PropertyOrNull -Object $previous -Name 'LastOutcome'
        if ($oldOutcome -in @('Success', 'NoUpdatesFound', 'SuccessRebootRequired')) {
            $lastDeployment = Get-PropertyOrNull -Object $previous -Name 'LastRunUtc'
        }
    }
    if ($script:ScanAttempted) { $lastScan = $now }
    if ($script:ScanSucceeded) { $lastSuccessfulScan = $now }
    if (-not ($ScanOnly -or $DryRun) -and $Outcome -in @('Success', 'NoUpdatesFound', 'SuccessRebootRequired')) { $lastDeployment = $now }
    $scanMode = 'Install'
    if ($ScanOnly) { $scanMode = 'ScanOnly' }
    elseif ($DryRun) { $scanMode = 'DryRun' }
    elseif ($Interactive) { $scanMode = 'Interactive' }
    $state = [ordered]@{
        ScriptName = $ScriptName
        ScriptVersion = $ScriptVersion
        ComputerName = $env:COMPUTERNAME
        LastRunUtc = $now
        LastAttemptUtc = $now
        LastScanUtc = $lastScan
        LastSuccessfulScanUtc = $lastSuccessfulScan
        LastSuccessfulDeploymentUtc = $lastDeployment
        LastExitCode = $ExitCode
        LastOutcome = $Outcome
        ScanMode = $scanMode
        UpdateSource = $script:UpdateSource
        UpdatesFound = $UpdatesFound
        UpdatesInstalled = $UpdatesInstalled
        RebootRequired = $RebootRequired
        DriverResults = @($script:DriverResults.ToArray())
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        OsVersion = [Environment]::OSVersion.VersionString
    }

    # Write to a same-directory temp file, then atomically publish the JSON.
    # A crash must not leave a truncated state file behind.
    $uniqueId = [guid]::NewGuid().ToString('N')
    $tempFile = Join-Path -Path $StateRoot -ChildPath ("state.{0}.tmp" -f $uniqueId)
    $backupFile = Join-Path -Path $StateRoot -ChildPath ("state.{0}.bak" -f $uniqueId)
    try {
        $json = $state | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($tempFile, $json, ([System.Text.UTF8Encoding]::new($false)))
        if (Test-Path -LiteralPath $script:StateFile -PathType Leaf) {
            # .NET Framework 4.x on Windows PowerShell 5.1 requires a valid backup path.
            [System.IO.File]::Replace($tempFile, $script:StateFile, $backupFile)
        } else {
            [System.IO.File]::Move($tempFile, $script:StateFile)
        }
    } finally {
        foreach ($file in @($tempFile, $backupFile)) {
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Test-RecentSuccessfulRun {
    if ($Force -or $ScanOnly -or $DryRun -or $Interactive -or $MinimumScanIntervalHours -le 0) { return $false }
    $state = Get-PreviousState
    $previousDeployment = Get-PropertyOrNull -Object $state -Name 'LastSuccessfulDeploymentUtc'
    if (-not $previousDeployment -and $null -ne $state) {
        $oldOutcome = Get-PropertyOrNull -Object $state -Name 'LastOutcome'
        if ($oldOutcome -in @('Success', 'NoUpdatesFound', 'SuccessRebootRequired')) {
            $previousDeployment = Get-PropertyOrNull -Object $state -Name 'LastRunUtc'
        }
    }
    if (-not $previousDeployment) { return $false }
    try {
        $lastUtc = [datetime]::Parse($previousDeployment).ToUniversalTime()
        $nextUtc = $lastUtc.AddHours($MinimumScanIntervalHours)
        if ((Get-Date).ToUniversalTime() -lt $nextUtc) {
            Write-Log -Message "Skipping scan. Last successful deployment: $($lastUtc.ToString('o')); next: $($nextUtc.ToString('o'))."
            return $true
        }
    } catch { Write-Log -Level 'WARN' -Message "Invalid previous deployment timestamp: $($_.Exception.Message)" }
    return $false
}

function Invoke-DriverUpdateDeployment {
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

        if ($Interactive -and ($ScanOnly -or $DryRun -or (Test-IsLocalSystem) -or
            -not [Environment]::UserInteractive -or [Console]::IsInputRedirected)) {
            Write-Log -Level 'ERROR' -Message 'Interactive mode requires local console, not SYSTEM, and cannot be combined with scan-only switches.'
            Save-State -ExitCode $ExitCodes.PrerequisiteFailed -Outcome 'InteractiveConsoleRequired'
            return $ExitCodes.PrerequisiteFailed
        }

        Write-WindowsUpdatePolicySummary
        if ($TemporaryMicrosoftUpdateService) { Write-Log -Level 'WARN' -Message 'Deprecated switch ignored: V2 does not register Microsoft Update.' }
        try { $script:Configuration = Get-DriverConfiguration }
        catch { Write-Log -Level 'ERROR' -Message "Invalid configuration: $($_.Exception.Message)"; Save-State -ExitCode $ExitCodes.PrerequisiteFailed -Outcome 'InvalidConfig'; return $ExitCodes.PrerequisiteFailed }
        $wuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        if ((Get-RegistryValueOrNull -Path $wuPath -Name 'ExcludeWUDriversInQualityUpdate') -eq 1 -or
            (Get-RegistryValueOrNull -Path $wuPath -Name 'ExcludeWUDriversFromQualityUpdates') -eq 1) {
            Write-Log -Level 'WARN' -Message 'Driver updates are excluded by Windows Update policy. No scan or installation performed.'
            Save-State -ExitCode $ExitCodes.Success -Outcome 'SkippedPolicy'
            return $ExitCodes.Success
        }

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
            $session = New-Object -ComObject Microsoft.Update.Session
            $session.ClientApplicationID = $ScriptName

            $searcher = $session.CreateUpdateSearcher()
            $searcher.SearchScope = 1
            # ssDefault (0) respects the managed Windows Update service (WSUS when configured).
            $searcher.ServerSelection = 0
            $useClassSource = Get-RegistryValueOrNull -Path $auPath -Name 'UseUpdateClassPolicySource'
            $driverSource = Get-RegistryValueOrNull -Path $wuPath -Name 'SetPolicyDrivenUpdateSourceForDriverUpdates'
            if ($useClassSource -eq 1 -and $null -ne $driverSource) {
                if ([int]$driverSource -eq 1) {
                    $searcher.ServerSelection = 1 # ssManagedServer
                    $script:UpdateSource = 'WSUS'
                } elseif ([int]$driverSource -eq 0) {
                    if ((Get-RegistryValueOrNull -Path $wuPath -Name 'DoNotConnectToWindowsUpdateInternetLocations') -eq 1) {
                        Write-Log -Level 'ERROR' -Message 'Contradictory policies: driver source is Windows Update, but internet update locations are blocked.'
                        Save-State -ExitCode $ExitCodes.PolicyBlocked -Outcome 'PolicyConflict'
                        return $ExitCodes.PolicyBlocked
                    }
                    $searcher.ServerSelection = 2 # ssWindowsUpdate
                    $script:UpdateSource = 'WindowsUpdate'
                } else { throw "Unsupported driver update source value: $driverSource" }
            } else {
                $script:UpdateSource = 'PolicyDefault'
            }

            $criteria = "IsInstalled=0 and IsHidden=0 and Type='Driver'"
            Write-Log -Message "Searching driver updates with criteria: $criteria"
            $script:ScanAttempted = $true
            $searchResult = $searcher.Search($criteria)
            if ([int]$searchResult.ResultCode -ne 2) { throw "Search did not succeed: $(Get-OperationResultName -ResultCode ([int]$searchResult.ResultCode))" }
            $script:ScanSucceeded = $true
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

        $interactiveSelectedIndices = $null
        if ($Interactive) {
            $choice = Read-InteractiveDriverChoice -Updates $updates
            if ($choice.Cancelled) {
                Write-Log -Message 'Interactive installation cancelled before any download.'
                Save-State -ExitCode $ExitCodes.Success -Outcome 'CancelledByUser' -UpdatesFound $updatesFound
                return $ExitCodes.Success
            }
            $interactiveSelectedIndices = @($choice.SelectedIndices)
        }

        $installCandidates = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($index = 0; $index -lt $updates.Count; $index++) {
            $update = $updates.Item($index)
            Write-Log -Message "Candidate update: $(Get-UpdateSummary -Update $update)"

            $exclusion = Get-DriverEligibilityReason -Update $update
            if ($null -ne $exclusion) {
                Write-Log -Message "Skipping driver: $($update.Title) ($exclusion)"
                Add-DriverResult -Update $update -Status 'Skipped' -Detail $exclusion
                continue
            }
            if ($null -ne $interactiveSelectedIndices -and (($index + 1) -notin $interactiveSelectedIndices)) {
                Add-DriverResult -Update $update -Status 'Skipped' -Detail 'NotSelected'
                continue
            }

            if (-not $update.EulaAccepted) {
                if ($AcceptEula) {
                    if (-not ($ScanOnly -or $DryRun)) {
                        Write-Log -Message "Accepting EULA for update: $($update.Title)"
                        $update.AcceptEula()
                    }
                } else {
                    Write-Log -Level 'WARN' -Message "Skipping update because EULA is not accepted and AcceptEula is false: $($update.Title)"
                    Add-DriverResult -Update $update -Status 'Skipped' -Detail 'EulaNotAccepted'
                    continue
                }
            }

            Add-DriverResult -Update $update -Status 'Eligible'
            Add-UpdateToCollection -Collection $installCandidates -Update $update
        }

        if ($installCandidates.Count -eq 0) {
            Write-Log -Level 'WARN' -Message 'No silent install candidate remains after filtering.'
            Save-State -ExitCode $ExitCodes.Success -Outcome 'NoEligibleCandidates' -UpdatesFound $updatesFound
            return $ExitCodes.Success
        }

        if ($ScanOnly -or $DryRun) {
            $outcome = if ($ScanOnly) { 'ScanOnly' } else { 'DryRun' }
            Write-Log -Message "$outcome completed; no download, EULA acceptance, or installation performed."
            Save-State -ExitCode $ExitCodes.Success -Outcome $outcome -UpdatesFound $updatesFound
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
                Add-DriverResult -Update $update -Status $resultName -Detail "HResult=$($updateResult.HResult)"
                if ($updateResult.ResultCode -eq 2) {
                    $updatesInstalled++
                } else {
                    $partialFailure = $true
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
        Write-Log -Message "Finished $ScriptName."
    }
}

$mutex = $null
$lockAcquired = $false
try {
    Initialize-LocalPath -Path $LogRoot
    Initialize-LocalPath -Path $StateRoot
    # A 32-bit launcher delegates to a 64-bit child; only the child takes the mutex.
    if (-not ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)) {
        $mutex = New-Object System.Threading.Mutex($false, 'Global\DriversUpdateGpo')
        try { $lockAcquired = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $lockAcquired = $true }
        if (-not $lockAcquired) {
            Write-Output 'DriversUpdate: another execution is already active.'
            exit $ExitCodes.ConcurrentRun
        }
    }
    if ($lockAcquired) {
        try { Rotate-Log } catch { Write-Output "Log rotation warning: $($_.Exception.Message)" }
    }
    $exitCode = Invoke-DriverUpdateDeployment
    Write-Log -Message "Exit code: $exitCode"
    exit $exitCode
} catch {
    Write-Output "DriversUpdate startup error: $($_.Exception.Message)"
    exit $ExitCodes.PrerequisiteFailed
} finally {
    if ($lockAcquired -and $null -ne $mutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
) {
            $first = [int]$Matches[1]
            $last = if ($Matches.ContainsKey('2')) { [int]$Matches[2] } else { $first }
        } else {
            throw "Saisie incorrecte : $token"
        }
        if ($first -lt 1 -or $last -lt $first -or $last -gt $MaxIndex) {
            throw "Plage hors limites : $token"
        }
        for ($number = $first; $number -le $last; $number++) {
            if ($number -notin $EligibleNumbers) { throw "Pilote $number exclu ou non eligible." }
            $selected[$number] = $true
        }
    }
    foreach ($number in ($selected.Keys | Sort-Object)) { Write-Output ([int]$number) }
}

function Read-InteractiveDriverChoice {
    param([Parameter(Mandatory = $true)]$Updates)
    $eligible = New-Object 'System.Collections.Generic.List[int]'
    Write-Host ''
    Write-Host 'PILOTES DETECTES - selection manuelle' -ForegroundColor Cyan
    Write-Host 'Les pilotes exclus ne sont pas selectionnables.' -ForegroundColor DarkGray
    for ($index = 0; $index -lt $Updates.Count; $index++) {
        $update = $Updates.Item($index)
        $number = $index + 1
        $reason = Get-DriverEligibilityReason -Update $update
        if ($reason) {
            Write-Host ("[{0,2}] EXCLU ({1}) - {2}" -f $number, $reason, $update.Title) -ForegroundColor DarkYellow
        } else {
            $eligible.Add($number)
            Write-Host ("[{0,2}] OK - {1}" -f $number, $update.Title) -ForegroundColor Green
        }
        Write-Host ("     {0} / {1}" -f (Get-ComPropertyValue -Object $update -Name 'DriverManufacturer'), (Get-ComPropertyValue -Object $update -Name 'DriverClass')) -ForegroundColor DarkGray
    }
    if ($eligible.Count -eq 0) {
        Write-Host 'Aucun pilote eligible.' -ForegroundColor Yellow
        return [pscustomobject]@{ Cancelled = $true; SelectedIndices = @() }
    }
    Write-Host ''
    Write-Host 'Numeros : 1,3-5 | T : tous les eligibles | 0 : annuler'
    while ($true) {
        $answer = Read-Host 'Votre selection'
        try { $selected = @(ConvertTo-DriverSelection -InputText $answer -EligibleNumbers $eligible.ToArray() -MaxIndex $Updates.Count) }
        catch { Write-Host $_.Exception.Message -ForegroundColor Yellow; continue }
        if ($selected.Count -eq 0) { return [pscustomobject]@{ Cancelled = $true; SelectedIndices = @() } }
        Write-Host ''
        Write-Host 'Installation prevue :' -ForegroundColor Yellow
        foreach ($number in $selected) { Write-Host ("  - {0}" -f $Updates.Item($number - 1).Title) }
        Write-Host 'Les pilotes seront telecharges et installes; redemarrage potentiellement necessaire.' -ForegroundColor Yellow
        if ((Read-Host 'Tapez INSTALLER pour confirmer') -cne 'INSTALLER') {
            return [pscustomobject]@{ Cancelled = $true; SelectedIndices = @() }
        }
        return [pscustomobject]@{ Cancelled = $false; SelectedIndices = @($selected) }
    }
}

function Add-DriverResult {
    param($Update, [string]$Status, [string]$Detail = '')
    [void]$script:DriverResults.Add([ordered]@{
        Title = [string]$Update.Title
        Manufacturer = [string](Get-ComPropertyValue -Object $Update -Name 'DriverManufacturer')
        Class = [string](Get-ComPropertyValue -Object $Update -Name 'DriverClass')
        Status = $Status
        Detail = $Detail
    })
}

function Rotate-Log {
    if (-not (Test-Path -LiteralPath $script:LogFile -PathType Leaf)) { return }
    if ((Get-Item -LiteralPath $script:LogFile).Length -lt 5MB) { return }
    for ($i = 3; $i -ge 1; $i--) {
        $old = "$($script:LogFile).$i"
        if (Test-Path -LiteralPath $old) {
            if ($i -eq 3) { Remove-Item -LiteralPath $old -Force }
            else { Move-Item -LiteralPath $old -Destination "$($script:LogFile).$($i + 1)" -Force }
        }
    }
    Move-Item -LiteralPath $script:LogFile -Destination "$($script:LogFile).1" -Force
}

function Save-State {
    param(
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Outcome,
        [int]$UpdatesFound = 0,
        [int]$UpdatesInstalled = 0,
        [bool]$RebootRequired = $false
    )

    $previous = Get-PreviousState
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $lastScan = Get-PropertyOrNull -Object $previous -Name 'LastScanUtc'
    $lastSuccessfulScan = Get-PropertyOrNull -Object $previous -Name 'LastSuccessfulScanUtc'
    $lastDeployment = Get-PropertyOrNull -Object $previous -Name 'LastSuccessfulDeploymentUtc'
    if (-not $lastDeployment -and $null -ne $previous) {
        $oldOutcome = Get-PropertyOrNull -Object $previous -Name 'LastOutcome'
        if ($oldOutcome -in @('Success', 'NoUpdatesFound', 'SuccessRebootRequired')) {
            $lastDeployment = Get-PropertyOrNull -Object $previous -Name 'LastRunUtc'
        }
    }
    if ($script:ScanAttempted) { $lastScan = $now }
    if ($script:ScanSucceeded) { $lastSuccessfulScan = $now }
    if (-not ($ScanOnly -or $DryRun) -and $Outcome -in @('Success', 'NoUpdatesFound', 'SuccessRebootRequired')) { $lastDeployment = $now }
    $scanMode = 'Install'
    if ($ScanOnly) { $scanMode = 'ScanOnly' }
    elseif ($DryRun) { $scanMode = 'DryRun' }
    elseif ($Interactive) { $scanMode = 'Interactive' }
    $state = [ordered]@{
        ScriptName = $ScriptName
        ScriptVersion = $ScriptVersion
        ComputerName = $env:COMPUTERNAME
        LastRunUtc = $now
        LastAttemptUtc = $now
        LastScanUtc = $lastScan
        LastSuccessfulScanUtc = $lastSuccessfulScan
        LastSuccessfulDeploymentUtc = $lastDeployment
        LastExitCode = $ExitCode
        LastOutcome = $Outcome
        ScanMode = $scanMode
        UpdateSource = $script:UpdateSource
        UpdatesFound = $UpdatesFound
        UpdatesInstalled = $UpdatesInstalled
        RebootRequired = $RebootRequired
        DriverResults = @($script:DriverResults.ToArray())
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        OsVersion = [Environment]::OSVersion.VersionString
    }

    # Write to a same-directory temp file, then atomically publish the JSON.
    # A crash must not leave a truncated state file behind.
    $uniqueId = [guid]::NewGuid().ToString('N')
    $tempFile = Join-Path -Path $StateRoot -ChildPath ("state.{0}.tmp" -f $uniqueId)
    $backupFile = Join-Path -Path $StateRoot -ChildPath ("state.{0}.bak" -f $uniqueId)
    try {
        $json = $state | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($tempFile, $json, ([System.Text.UTF8Encoding]::new($false)))
        if (Test-Path -LiteralPath $script:StateFile -PathType Leaf) {
            # .NET Framework 4.x on Windows PowerShell 5.1 requires a valid backup path.
            [System.IO.File]::Replace($tempFile, $script:StateFile, $backupFile)
        } else {
            [System.IO.File]::Move($tempFile, $script:StateFile)
        }
    } finally {
        foreach ($file in @($tempFile, $backupFile)) {
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Test-RecentSuccessfulRun {
    if ($Force -or $ScanOnly -or $DryRun -or $Interactive -or $MinimumScanIntervalHours -le 0) { return $false }
    $state = Get-PreviousState
    $previousDeployment = Get-PropertyOrNull -Object $state -Name 'LastSuccessfulDeploymentUtc'
    if (-not $previousDeployment -and $null -ne $state) {
        $oldOutcome = Get-PropertyOrNull -Object $state -Name 'LastOutcome'
        if ($oldOutcome -in @('Success', 'NoUpdatesFound', 'SuccessRebootRequired')) {
            $previousDeployment = Get-PropertyOrNull -Object $state -Name 'LastRunUtc'
        }
    }
    if (-not $previousDeployment) { return $false }
    try {
        $lastUtc = [datetime]::Parse($previousDeployment).ToUniversalTime()
        $nextUtc = $lastUtc.AddHours($MinimumScanIntervalHours)
        if ((Get-Date).ToUniversalTime() -lt $nextUtc) {
            Write-Log -Message "Skipping scan. Last successful deployment: $($lastUtc.ToString('o')); next: $($nextUtc.ToString('o'))."
            return $true
        }
    } catch { Write-Log -Level 'WARN' -Message "Invalid previous deployment timestamp: $($_.Exception.Message)" }
    return $false
}

function Invoke-DriverUpdateDeployment {
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

        if ($Interactive -and ($ScanOnly -or $DryRun -or (Test-IsLocalSystem) -or
            -not [Environment]::UserInteractive -or [Console]::IsInputRedirected)) {
            Write-Log -Level 'ERROR' -Message 'Interactive mode requires local console, not SYSTEM, and cannot be combined with scan-only switches.'
            Save-State -ExitCode $ExitCodes.PrerequisiteFailed -Outcome 'InteractiveConsoleRequired'
            return $ExitCodes.PrerequisiteFailed
        }

        Write-WindowsUpdatePolicySummary
        if ($TemporaryMicrosoftUpdateService) { Write-Log -Level 'WARN' -Message 'Deprecated switch ignored: V2 does not register Microsoft Update.' }
        try { $script:Configuration = Get-DriverConfiguration }
        catch { Write-Log -Level 'ERROR' -Message "Invalid configuration: $($_.Exception.Message)"; Save-State -ExitCode $ExitCodes.PrerequisiteFailed -Outcome 'InvalidConfig'; return $ExitCodes.PrerequisiteFailed }
        $wuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $auPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        if ((Get-RegistryValueOrNull -Path $wuPath -Name 'ExcludeWUDriversInQualityUpdate') -eq 1 -or
            (Get-RegistryValueOrNull -Path $wuPath -Name 'ExcludeWUDriversFromQualityUpdates') -eq 1) {
            Write-Log -Level 'WARN' -Message 'Driver updates are excluded by Windows Update policy. No scan or installation performed.'
            Save-State -ExitCode $ExitCodes.Success -Outcome 'SkippedPolicy'
            return $ExitCodes.Success
        }

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
            $session = New-Object -ComObject Microsoft.Update.Session
            $session.ClientApplicationID = $ScriptName

            $searcher = $session.CreateUpdateSearcher()
            $searcher.SearchScope = 1
            # ssDefault (0) respects the managed Windows Update service (WSUS when configured).
            $searcher.ServerSelection = 0
            $useClassSource = Get-RegistryValueOrNull -Path $auPath -Name 'UseUpdateClassPolicySource'
            $driverSource = Get-RegistryValueOrNull -Path $wuPath -Name 'SetPolicyDrivenUpdateSourceForDriverUpdates'
            if ($useClassSource -eq 1 -and $null -ne $driverSource) {
                if ([int]$driverSource -eq 1) {
                    $searcher.ServerSelection = 1 # ssManagedServer
                    $script:UpdateSource = 'WSUS'
                } elseif ([int]$driverSource -eq 0) {
                    if ((Get-RegistryValueOrNull -Path $wuPath -Name 'DoNotConnectToWindowsUpdateInternetLocations') -eq 1) {
                        Write-Log -Level 'ERROR' -Message 'Contradictory policies: driver source is Windows Update, but internet update locations are blocked.'
                        Save-State -ExitCode $ExitCodes.PolicyBlocked -Outcome 'PolicyConflict'
                        return $ExitCodes.PolicyBlocked
                    }
                    $searcher.ServerSelection = 2 # ssWindowsUpdate
                    $script:UpdateSource = 'WindowsUpdate'
                } else { throw "Unsupported driver update source value: $driverSource" }
            } else {
                $script:UpdateSource = 'PolicyDefault'
            }

            $criteria = "IsInstalled=0 and IsHidden=0 and Type='Driver'"
            Write-Log -Message "Searching driver updates with criteria: $criteria"
            $script:ScanAttempted = $true
            $searchResult = $searcher.Search($criteria)
            if ([int]$searchResult.ResultCode -ne 2) { throw "Search did not succeed: $(Get-OperationResultName -ResultCode ([int]$searchResult.ResultCode))" }
            $script:ScanSucceeded = $true
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

        $interactiveSelectedIndices = $null
        if ($Interactive) {
            $choice = Read-InteractiveDriverChoice -Updates $updates
            if ($choice.Cancelled) {
                Write-Log -Message 'Interactive installation cancelled before any download.'
                Save-State -ExitCode $ExitCodes.Success -Outcome 'CancelledByUser' -UpdatesFound $updatesFound
                return $ExitCodes.Success
            }
            $interactiveSelectedIndices = @($choice.SelectedIndices)
        }

        $installCandidates = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($index = 0; $index -lt $updates.Count; $index++) {
            $update = $updates.Item($index)
            Write-Log -Message "Candidate update: $(Get-UpdateSummary -Update $update)"

            $exclusion = Get-DriverEligibilityReason -Update $update
            if ($null -ne $exclusion) {
                Write-Log -Message "Skipping driver: $($update.Title) ($exclusion)"
                Add-DriverResult -Update $update -Status 'Skipped' -Detail $exclusion
                continue
            }
            if ($null -ne $interactiveSelectedIndices -and (($index + 1) -notin $interactiveSelectedIndices)) {
                Add-DriverResult -Update $update -Status 'Skipped' -Detail 'NotSelected'
                continue
            }

            if (-not $update.EulaAccepted) {
                if ($AcceptEula) {
                    if (-not ($ScanOnly -or $DryRun)) {
                        Write-Log -Message "Accepting EULA for update: $($update.Title)"
                        $update.AcceptEula()
                    }
                } else {
                    Write-Log -Level 'WARN' -Message "Skipping update because EULA is not accepted and AcceptEula is false: $($update.Title)"
                    Add-DriverResult -Update $update -Status 'Skipped' -Detail 'EulaNotAccepted'
                    continue
                }
            }

            Add-DriverResult -Update $update -Status 'Eligible'
            Add-UpdateToCollection -Collection $installCandidates -Update $update
        }

        if ($installCandidates.Count -eq 0) {
            Write-Log -Level 'WARN' -Message 'No silent install candidate remains after filtering.'
            Save-State -ExitCode $ExitCodes.Success -Outcome 'NoEligibleCandidates' -UpdatesFound $updatesFound
            return $ExitCodes.Success
        }

        if ($ScanOnly -or $DryRun) {
            $outcome = if ($ScanOnly) { 'ScanOnly' } else { 'DryRun' }
            Write-Log -Message "$outcome completed; no download, EULA acceptance, or installation performed."
            Save-State -ExitCode $ExitCodes.Success -Outcome $outcome -UpdatesFound $updatesFound
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
                Add-DriverResult -Update $update -Status $resultName -Detail "HResult=$($updateResult.HResult)"
                if ($updateResult.ResultCode -eq 2) {
                    $updatesInstalled++
                } else {
                    $partialFailure = $true
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
        Write-Log -Message "Finished $ScriptName."
    }
}

$mutex = $null
$lockAcquired = $false
try {
    Initialize-LocalPath -Path $LogRoot
    Initialize-LocalPath -Path $StateRoot
    # A 32-bit launcher delegates to a 64-bit child; only the child takes the mutex.
    if (-not ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)) {
        $mutex = New-Object System.Threading.Mutex($false, 'Global\DriversUpdateGpo')
        try { $lockAcquired = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $lockAcquired = $true }
        if (-not $lockAcquired) {
            Write-Output 'DriversUpdate: another execution is already active.'
            exit $ExitCodes.ConcurrentRun
        }
    }
    if ($lockAcquired) {
        try { Rotate-Log } catch { Write-Output "Log rotation warning: $($_.Exception.Message)" }
    }
    $exitCode = Invoke-DriverUpdateDeployment
    Write-Log -Message "Exit code: $exitCode"
    exit $exitCode
} catch {
    Write-Output "DriversUpdate startup error: $($_.Exception.Message)"
    exit $ExitCodes.PrerequisiteFailed
} finally {
    if ($lockAcquired -and $null -ne $mutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
