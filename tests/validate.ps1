$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root 'force_update_drivers_gpo_hardened.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    throw ("PowerShell syntax errors: " + ($errors | ForEach-Object { $_.Message } | Out-String))
}

$exampleConfig = Get-Content -Raw -LiteralPath (Join-Path $root 'config.example.json') | ConvertFrom-Json -ErrorAction Stop
foreach ($property in @('ExcludedDriverClasses', 'ExcludedTitleContains', 'IncludedTitleContains')) {
    if ($null -eq $exampleConfig.PSObject.Properties[$property]) { throw "Missing configuration property: $property" }
}

$functions = @{}
$ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | ForEach-Object { $functions[$_.Name] = $_.Extent.Text }
foreach ($required in @('Get-DriverExclusionReason', 'Test-RecentSuccessfulRun', 'Get-PropertyOrNull', 'Get-DriverConfiguration', 'Write-Log')) {
    if (-not $functions.ContainsKey($required)) { throw "Missing function $required" }
    . ([scriptblock]::Create($functions[$required]))
}


$script:LogFile = Join-Path $env:TEMP 'driversupdate-ci-test.log'
$testLogOutput = @(Write-Log -Message 'Pipeline purity check')
if ($testLogOutput.Count -ne 0) { throw 'Write-Log must not emit data on the success pipeline' }
$script:ConfigPath = Join-Path $root 'config.example.json'
$loadedConfig = Get-DriverConfiguration
if ($loadedConfig['ExcludedDriverClasses'].Count -ne 5) { throw 'Default configuration did not load correctly' }
$script:ConfigPath = Join-Path $env:TEMP 'driversupdate-ci-config.json'
'{"ExcludedDriverClasses":[],"ExcludedTitleContains":["BIOS"],"IncludedTitleContains":["Audio"]}' |
    Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
$loadedConfig = Get-DriverConfiguration
if ($loadedConfig['ExcludedDriverClasses'].Count -ne 0) { throw 'Empty config array must override defaults' }
if ($loadedConfig['IncludedTitleContains'].Count -ne 1) { throw 'Single-item config array must be preserved' }
Remove-Item -LiteralPath $script:ConfigPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $script:LogFile -ErrorAction SilentlyContinue

function Get-ComPropertyValue { param($Object, [string]$Name) return $Object.$Name }
function Get-PreviousState { return $script:FakeState }
function Write-Log { param([string]$Level, [string]$Message) }

function Assert-Equal {
    param($Actual, $Expected, [string]$Description)
    if ($Actual -cne $Expected) { throw "$Description : expected [$Expected], got [$Actual]" }
}

$script:Configuration = @{
    ExcludedDriverClasses = @('Firmware', 'Net', 'SCSIAdapter', 'HDC', 'DiskDrive')
    ExcludedTitleContains = @('BIOS', 'Firmware')
    IncludedTitleContains = @()
}
$network = [pscustomobject]@{ Title = 'Vendor - Network Adapter'; DriverClass = 'Net' }
$firmware = [pscustomobject]@{ Title = 'Vendor - BIOS revision'; DriverClass = 'System' }
$safe = [pscustomobject]@{ Title = 'Vendor - Audio Adapter'; DriverClass = 'MEDIA' }
Assert-Equal (Get-DriverExclusionReason -Update $network) 'ExcludedClass:Net' 'Network exclusion'
Assert-Equal (Get-DriverExclusionReason -Update $firmware) 'ExcludedTitle:BIOS' 'BIOS exclusion'
Assert-Equal (Get-DriverExclusionReason -Update $safe) $null 'Safe update eligible'
$script:Configuration.IncludedTitleContains = @('Realtek')
Assert-Equal (Get-DriverExclusionReason -Update $safe) 'NotAllowlisted' 'Allowlist exclusion'
$script:Configuration.IncludedTitleContains = @('Audio')
Assert-Equal (Get-DriverExclusionReason -Update $safe) $null 'Allowlist match'

$script:MinimumScanIntervalHours = 24
$script:Force = $false
$script:ScanOnly = $false
$script:DryRun = $false
$script:FakeState = [pscustomobject]@{
    LastSuccessfulDeploymentUtc = (Get-Date).ToUniversalTime().AddHours(-25).ToString('o')
    LastRunUtc = (Get-Date).ToUniversalTime().AddMinutes(-2).ToString('o')
    LastOutcome = 'SkippedRecentSuccessfulRun'
}
Assert-Equal (Test-RecentSuccessfulRun) $false 'Skipped task must not postpone next scan'
$script:FakeState.LastSuccessfulDeploymentUtc = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
Assert-Equal (Test-RecentSuccessfulRun) $true 'Recent successful deployment is throttled'
$script:ScanOnly = $true
Assert-Equal (Test-RecentSuccessfulRun) $false 'Audit mode always scans'
$script:ScanOnly = $false
$script:Force = $true
Assert-Equal (Test-RecentSuccessfulRun) $false 'Force bypasses throttle'

Write-Output 'PASS: syntax, config, filters, scan interval, audit/force bypass'
