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


$script:UserFacing = $false
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

# Proxy SYSTEM : valider les options et refuser une configuration dangereuse.
foreach ($name in @('Initialize-DriverProxy', 'Restore-DriverProxy', 'Protect-DriverProxyBackupDirectory', 'Set-DriverSessionProxy', 'Get-DriverProxyCredential', 'Set-DriverGlobalProxyCredentials')) {
    if (-not $functions.ContainsKey($name)) { throw "Missing SYSTEM proxy function: $name" }
}
$script:ConfigPath = Join-Path $env:TEMP ('driversupdate-proxy-ci-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    '{"Proxy":{"Mode":"Temporary","Address":"172.17.0.1:3128","BypassList":"<local>","CredentialFile":"","AuthenticationScheme":"Basic","UseWinHttpGlobalCredentials":true}}' |
        Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
    $proxyConfig = Get-DriverConfiguration
    if ($proxyConfig['Proxy'].Mode -cne 'Temporary' -or $proxyConfig['Proxy'].Address -cne '172.17.0.1:3128') {
        throw 'Valid SYSTEM proxy configuration was not preserved'
    }
    if ($proxyConfig['ExcludedDriverClasses'].Count -ne 5) { throw 'Proxy config must preserve safe driver exclusions' }

    foreach ($badValue in @('{"Proxy":{"Mode":"Temporary","Address":"https://bad:3128"}}',
                           '{"Proxy":{"Mode":"Temporary","Address":"proxy:99999"}}',
                           '{"Proxy":{"Mode":"Temporary","Address":"proxy:3128","CredentialFile":"relative.xml"}}',
                           '{"Proxy":{"Mode":"Unknown"}}',
                           '{"Proxy":{"UseWinHttpGlobalCredentials":"true"}}',
                           '{"Proxy":{"CredentialPassword":"plaintext"}}')) {
        $badValue | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
        $rejected = $false
        try { $null = Get-DriverConfiguration } catch { $rejected = $true }
        if (-not $rejected) { throw "Unsafe proxy configuration accepted: $badValue" }
    }
} finally {
    Remove-Item -LiteralPath $script:ConfigPath -ErrorAction SilentlyContinue
}
Write-Output 'PASS: SYSTEM proxy config, blocked plaintext credentials, validation and functions'


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

$script:Interactive = $false
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

# Verify the public entry points and reject accidental reintroduction of legacy scripts.
$manual = Join-Path $root 'DriversUpdate-Manual.ps1'
$manualTokens = $null
$manualErrors = $null
$manualAst = [System.Management.Automation.Language.Parser]::ParseFile($manual, [ref]$manualTokens, [ref]$manualErrors)
if ($manualErrors.Count -gt 0) {
    throw ("Manual script PowerShell syntax errors: " + ($manualErrors | ForEach-Object { $_.Message } | Out-String))
}
$entryPoints = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File | Select-Object -ExpandProperty Name | Sort-Object)
$expectedEntryPoints = @('DriversUpdate-Manual.ps1', 'force_update_drivers_gpo_hardened.ps1')
if (($entryPoints -join ',') -cne ($expectedEntryPoints -join ',')) {
    throw "Expected exactly two root scripts. Found: $($entryPoints -join ', ')"
}
$manualFunctions = @($manualAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | ForEach-Object { $_.Name })
foreach ($name in @('Invoke-ManualDriverUpdate', 'Show-LastState', 'Show-RecentLog')) {
    if ($manualFunctions -cnotcontains $name) { throw "Manual menu function missing: $name" }
}
if (-not $manualAst.Extent.Text.Contains("'-Interactive'")) { throw 'Manual must request interactive selection' }
if (-not $manualAst.Extent.Text.Contains("'-UserFacing'")) { throw 'Manual must request user-facing output from the engine' }
$manualText = Get-Content -LiteralPath $manual -Raw -Encoding UTF8
if (-not $manualText.Contains('Rechercher les pilotes disponibles') -or
    -not $manualText.Contains('Choisir les pilotes')) {
    throw 'The manual interface must expose clear French actions'
}
if ($manualText.Contains('Select and install drivers') -or $manualText.Contains('View last result')) {
    throw 'The old English menu must not reappear'
}
if (-not $manualAst.Extent.Text.Contains("force_update_drivers_gpo_hardened.ps1")) { throw 'Manual must call GPO engine' }

# Configuration must reject invalid JSON or unsupported values.
$script:ConfigPath = Join-Path $env:TEMP 'driversupdate-ci-invalid.json'
try {
    '{"ExcludedDriverClasses":' | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
    $rejected = $false
    try { $null = Get-DriverConfiguration } catch { $rejected = $true }
    if (-not $rejected) { throw 'Malformed JSON must be rejected' }

    '{"ExcludedDriverClasses":"Net"}' | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
    $rejected = $false
    try { $null = Get-DriverConfiguration } catch { $rejected = $true }
    if (-not $rejected) { throw 'Non-array config value must be rejected' }
} finally {
    Remove-Item -LiteralPath $script:ConfigPath -ErrorAction SilentlyContinue
}
Write-Output 'PASS: two entry points, interactive confirmation, invalid config rejection'

# Exercise the atomic JSON state publication (create and replace) without COM or Windows Update.
if (-not $functions.ContainsKey('Save-State')) {
    throw 'Save-State must exist'
}
. ([scriptblock]::Create($functions['Save-State']))
$stateTestRoot = Join-Path $env:TEMP ("driversupdate-ci-state-" + [guid]::NewGuid().ToString('N'))
New-Item -Path $stateTestRoot -ItemType Directory -Force | Out-Null
try {
    $StateRoot = $stateTestRoot
    $script:StateFile = Join-Path $stateTestRoot 'state.json'
    $script:DriverResults = New-Object System.Collections.ArrayList
    $script:ScanAttempted = $true
    $script:ScanSucceeded = $true
    $script:UpdateSource = 'PolicyDefault'
    $ScriptName = 'DriversUpdateGpo'
    $ScriptVersion = '2.0.0'
    $ScanOnly = $true
    $DryRun = $false
    $script:FakeState = $null
    Save-State -ExitCode 0 -Outcome 'ScanOnly' -UpdatesFound 1
    $saved = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json -ErrorAction Stop
    Assert-Equal $saved.LastOutcome 'ScanOnly' 'Atomic initial publication'

    Save-State -ExitCode 103 -Outcome 'InvalidConfig'
    $saved = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json -ErrorAction Stop
    Assert-Equal $saved.LastExitCode 103 'Atomic replacement'
    $tempFiles = @(Get-ChildItem -LiteralPath $stateTestRoot -File | Where-Object { $_.Extension -in @('.tmp', '.bak') })
    Assert-Equal $tempFiles.Count 0 'No temporary or backup state files left behind'
} finally {
    Remove-Item -LiteralPath $stateTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'PASS: atomic state create and replace'

& (Join-Path $PSScriptRoot 'validate-interactive.ps1')
