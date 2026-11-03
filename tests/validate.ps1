$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$gpo = Join-Path $root 'force_update_drivers_gpo_hardened.ps1'
$manual = Join-Path $root 'DriversUpdate-Manual.ps1'
$expected = @('DriversUpdate-Manual.ps1', 'force_update_drivers_gpo_hardened.ps1')
$actual = @(Get-ChildItem -LiteralPath $root -File -Filter '*.ps1' |
    Select-Object -ExpandProperty Name | Sort-Object)
if (($actual -join ',') -cne ($expected -join ',')) {
    throw "Expected exactly two independent scripts; found: $($actual -join ', ')"
}

function Read-Functions {
    param([string]$Path)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw ("PowerShell syntax errors in $($Path): " + ($parseErrors | ForEach-Object { $_.Message } | Out-String))
    }
    $functions = @{}
    $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | ForEach-Object { $functions[$_.Name] = $_.Extent.Text }
    return $functions
}

$gpoFns = Read-Functions -Path $gpo
$manualFns = Read-Functions -Path $manual
foreach ($name in @('Invoke-DriverUpdateDeployment', 'Get-DriverConfiguration', 'Get-DriverExclusionReason',
                    'Test-RecentSuccessfulRun', 'Write-Log', 'Save-State', 'Initialize-DriverProxy',
                    'Restore-DriverProxy', 'Set-DriverGlobalProxyCredentials', 'Set-DriverSessionProxy')) {
    if (-not $gpoFns.ContainsKey($name)) { throw "GPO missing $name" }
    if (-not $manualFns.ContainsKey($name)) { throw "Manual not standalone: missing $name" }
}
foreach ($name in @('Invoke-ManualDriverUpdate', 'Invoke-StandaloneDriverEngine',
                    'Show-LastState', 'Show-RecentLog', 'Read-InteractiveDriverChoice')) {
    if (-not $manualFns.ContainsKey($name)) { throw "Manual missing $name" }
}

$gpoText = Get-Content -LiteralPath $gpo -Raw -Encoding UTF8
$manualText = Get-Content -LiteralPath $manual -Raw -Encoding UTF8
foreach ($src in @($gpoText, $manualText)) {
    foreach ($key in @('$ProxyEnabled', '$ProxyHost', '$ProxyPort', '$ProxyUser', '$ProxyPassword', '$ProxyAuthScheme')) {
        if (-not $src.Contains($key)) { throw "Missing inline configuration: $key" }
    }
    if ($src.Contains('config.proxy.json') -or $src.Contains('proxy-credential.xml') -or
        $src.Contains('$ConfigPath') -or $src.Contains('$engineScript')) {
        throw 'A standalone script still depends on external configuration or PS1'
    }
}
# Elevation fiable depuis l'Explorateur ou depuis PowerShell non-admin :
# forcer une console dediee pour le chemin UAC, les hôtes x86 et les
# consoles a entree redirigee. Ne pas fermer le diagnostic au lancement.
foreach ($token in @('[switch]$ChildWindow',
                      '$inputRedirected = [Console]::IsInputRedirected',
                      "if (-not $ChildWindow -and",
                      "Start-Process @start",
                      '$start.Verb = ''RunAs''',
                      '-ExecutionPolicy Bypass -STA -NoExit -File',
                      "if ($ChildWindow) { exit 0 }")) {
    if (-not $manualText.Contains($token)) { throw "Explorer bootstrap missing: $token" }
}
if ($manualText.Contains("if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected)")) {
    throw 'Old redirected-input guard still blocks Explorer shell execution'
}
if ($manualText.IndexOf("Start-Process @start") -gt
    $manualText.IndexOf('function Invoke-StandaloneDriverEngine')) {
    throw 'UAC relaunch must be before driver engine initialization'
}
Write-Output 'PASS: Explorer launch, UAC elevation, redirected input, persistent error console'

if ($manualText.Contains('Invoke-Expression')) { throw 'Do not evaluate external scripts' }
if (-not $manualText.Contains('Rechercher les pilotes disponibles') -or
    -not $manualText.Contains('Cocher les pilotes') -or
    -not $manualText.Contains("Installer la sélection")) {
    throw 'The manual script must retain selection and explicit confirmation'
}
Write-Output 'PASS: two standalone PowerShell 5.1 scripts, inline proxy and manual confirmation'

# Extract only pure functions, never execute the scripts on test startup.
foreach ($name in @('Get-PropertyOrNull', 'Get-DriverConfiguration',
                    'Get-DriverExclusionReason', 'Test-RecentSuccessfulRun', 'Save-State')) {
    . ([scriptblock]::Create($gpoFns[$name]))
}
function Get-ComPropertyValue { param($Object, [string]$Name) return $Object.$Name }
function Get-PreviousState { return $script:FakeState }
function Write-Log { param([string]$Level, [string]$Message) }

function Assert-Equal {
    param($Actual, $Expected, [string]$Description)
    if ($Actual -cne $Expected) { throw "$Description : expected [$Expected], got [$Actual]" }
}

$script:ProxyEnabled = $false
$script:ProxyHost = '172.17.0.1'
$script:ProxyPort = 3128
$script:ProxyBypassList = '<local>'
$script:ProxyUser = ''
$script:ProxyPassword = ''
$script:ProxyAuthScheme = 'Basic'
$script:ExcludedDriverClasses = @('Firmware', 'Net', 'SCSIAdapter', 'HDC', 'DiskDrive')
$script:ExcludedTitleContains = @('BIOS', 'Firmware')
$script:IncludedTitleContains = @()
$config = Get-DriverConfiguration
Assert-Equal $config['Proxy'].Mode 'System' 'Proxy disabled'
Assert-Equal $config['ExcludedDriverClasses'].Count 5 'Default exclusions'

$script:ProxyEnabled = $true
$config = Get-DriverConfiguration
Assert-Equal $config['Proxy'].Mode 'Temporary' 'Proxy activated'
Assert-Equal $config['Proxy'].Address '172.17.0.1:3128' 'Proxy address'
foreach ($bad in @('https://proxy:3128', 'proxy@name')) {
    $script:ProxyHost = $bad
    $rejected = $false
    try { $null = Get-DriverConfiguration } catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid proxy host accepted: $bad" }
}
$script:ProxyHost = 'proxy.internal'
$script:ProxyPort = 99999
$rejected = $false
try { $null = Get-DriverConfiguration } catch { $rejected = $true }
if (-not $rejected) { throw 'Invalid proxy port accepted' }
$script:ProxyPort = 3128
$script:ProxyUser = 'UTILISATEUR'
$script:ProxyPassword = 'MOT_DE_PASSE'
$rejected = $false
try { $null = Get-DriverConfiguration } catch { $rejected = $true }
if (-not $rejected) { throw 'Proxy credential placeholders must be rejected' }
$script:ProxyUser = ''
$script:ProxyPassword = ''
$script:ProxyEnabled = $false
$script:Configuration = Get-DriverConfiguration

$network = [pscustomobject]@{ Title = 'Vendor - Network Adapter'; DriverClass = 'Net' }
$firmware = [pscustomobject]@{ Title = 'Vendor - BIOS revision'; DriverClass = 'System' }
$safe = [pscustomobject]@{ Title = 'Vendor - Audio Adapter'; DriverClass = 'MEDIA' }
Assert-Equal (Get-DriverExclusionReason -Update $network) 'ExcludedClass:Net' 'Network exclusion'
Assert-Equal (Get-DriverExclusionReason -Update $firmware) 'ExcludedTitle:BIOS' 'BIOS exclusion'
Assert-Equal (Get-DriverExclusionReason -Update $safe) $null 'Safe update'
$script:Configuration.IncludedTitleContains = @('Other')
Assert-Equal (Get-DriverExclusionReason -Update $safe) 'NotAllowlisted' 'Allowlist'
Write-Output 'PASS: inline proxy validation and driver filters'

$script:MinimumScanIntervalHours = 24
$script:Force = $false
$script:ScanOnly = $false
$script:DryRun = $false
$script:Interactive = $false
$script:FakeState = [pscustomobject]@{
    LastSuccessfulDeploymentUtc = (Get-Date).ToUniversalTime().AddHours(-25).ToString('o')
    LastRunUtc = (Get-Date).ToUniversalTime().AddMinutes(-2).ToString('o')
    LastOutcome = 'SkippedRecentSuccessfulRun'
}
Assert-Equal (Test-RecentSuccessfulRun) $false 'Old deployment'
$script:FakeState.LastSuccessfulDeploymentUtc = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
Assert-Equal (Test-RecentSuccessfulRun) $true 'Recent deployment'
$script:ScanOnly = $true
Assert-Equal (Test-RecentSuccessfulRun) $false 'Audit scans'
Write-Output 'PASS: recent-run throttling'

$stateRoot = Join-Path $env:TEMP ('driversupdate-test-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $stateRoot -ItemType Directory -Force | Out-Null
try {
    $script:FakeState = $null
    $script:StateFile = Join-Path $stateRoot 'state.json'
    $script:DriverResults = New-Object System.Collections.ArrayList
    $script:ScanAttempted = $true
    $script:ScanSucceeded = $true
    $script:UpdateSource = 'PolicyDefault'
    $ScriptName = 'DriversUpdateGpo'
    $ScriptVersion = '3.0.0'
    $ScanOnly = $true
    $DryRun = $false
    $StateRoot = $stateRoot
    Save-State -ExitCode 0 -Outcome 'ScanOnly' -UpdatesFound 1
    $saved = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json -ErrorAction Stop
    Assert-Equal $saved.LastOutcome 'ScanOnly' 'Atomic state creation'
    Save-State -ExitCode 103 -Outcome 'InvalidConfig'
    $saved = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json -ErrorAction Stop
    Assert-Equal $saved.LastExitCode 103 'Atomic state replacement'
    $leftovers = @(Get-ChildItem -LiteralPath $stateRoot -File | Where-Object { $_.Extension -in @('.tmp','.bak') })
    Assert-Equal $leftovers.Count 0 'No temporary state files'
} finally {
    Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'PASS: state publication'

& (Join-Path $PSScriptRoot 'validate-interactive.ps1')
