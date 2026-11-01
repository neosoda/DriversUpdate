$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'force_update_drivers_gpo_hardened.ps1'
$menu = Join-Path $root 'DriversUpdate-Interactive.ps1'

foreach ($file in @($engine, $menu)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) {
        throw ("Syntax errors in $file : " + ($errors | ForEach-Object { $_.Message } | Out-String))
    }
}

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($engine, [ref]$tokens, [ref]$errors)
$functions = @{}
$ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { $functions[$_.Name] = $_.Extent.Text }
foreach ($name in @('ConvertTo-DriverSelection', 'Read-InteractiveDriverChoice', 'Get-ComPropertyValue', 'Get-DriverExclusionReason')) {
    if (-not $functions.ContainsKey($name)) { throw "Missing function: $name" }
    . ([scriptblock]::Create($functions[$name]))
}

function Assert-Selection {
    param([string]$InputText, [int[]]$Allowed, [int]$Max, [string]$Expected)
    $actual = @(ConvertTo-DriverSelection -InputText $InputText -EligibleNumbers $Allowed -MaxIndex $Max)
    if (($actual -join ',') -cne $Expected) { throw "Selection '$InputText': expected $Expected, got $($actual -join ',')" }
}
function Assert-Rejected {
    param([string]$InputText, [int[]]$Allowed, [int]$Max)
    $rejected = $false
    try { [void]@(ConvertTo-DriverSelection -InputText $InputText -EligibleNumbers $Allowed -MaxIndex $Max) }
    catch { $rejected = $true }
    if (-not $rejected) { throw "Unsafe selection accepted: $InputText" }
}

Assert-Selection -InputText '1,3-4,3' -Allowed @(1,3,4) -Max 5 -Expected '1,3,4'
Assert-Selection -InputText 'tous' -Allowed @(1,3,4) -Max 5 -Expected '1,3,4'
Assert-Selection -InputText '0' -Allowed @(1,3,4) -Max 5 -Expected ''
Assert-Selection -InputText '' -Allowed @(1,3,4) -Max 5 -Expected ''
Assert-Rejected -InputText '2' -Allowed @(1,3,4) -Max 5
Assert-Rejected -InputText '1-3' -Allowed @(1,3,4) -Max 5
Assert-Rejected -InputText '1-100000' -Allowed @(1,3,4) -Max 5
Assert-Rejected -InputText '1,pwsh' -Allowed @(1,3,4) -Max 5

$script:Configuration = @{
    ExcludedDriverClasses = @('Net')
    ExcludedTitleContains = @('BIOS')
    IncludedTitleContains = @()
}
$AcceptEula = $true
$updates = [pscustomobject]@{
    Count = 3
    Items = @(
        [pscustomobject]@{ Title = 'Audio device'; DriverClass = 'MEDIA'; DriverManufacturer = 'VendorA'; InstallationBehavior = [pscustomobject]@{ CanRequestUserInput = $false }; EulaAccepted = $true },
        [pscustomobject]@{ Title = 'Network device'; DriverClass = 'Net'; DriverManufacturer = 'VendorB'; InstallationBehavior = [pscustomobject]@{ CanRequestUserInput = $false }; EulaAccepted = $true },
        [pscustomobject]@{ Title = 'Input device'; DriverClass = 'HIDClass'; DriverManufacturer = 'VendorC'; InstallationBehavior = [pscustomobject]@{ CanRequestUserInput = $false }; EulaAccepted = $true }
    )
}
$updates | Add-Member -MemberType ScriptMethod -Name Item -Value { param([int]$index) return $this.Items[$index] }

function Read-Host {
    param([string]$Prompt)
    if ($script:answerIndex -ge $script:answers.Count) { throw 'Unexpected Read-Host call in test' }
    $answer = $script:answers[$script:answerIndex]
    $script:answerIndex++
    return $answer
}

$script:answers = @('2', '0')
$script:answerIndex = 0
$cancelled = Read-InteractiveDriverChoice -Updates $updates
if (-not $cancelled.Cancelled) { throw 'Excluded driver selection must never proceed' }

$script:answers = @('1,3', 'INSTALLER')
$script:answerIndex = 0
$approved = Read-InteractiveDriverChoice -Updates $updates
if ($approved.Cancelled -or (@($approved.SelectedIndices) -join ',') -cne '1,3') {
    throw 'Explicitly confirmed selection not preserved'
}

$script:answers = @('T', 'non')
$script:answerIndex = 0
$cancelled = Read-InteractiveDriverChoice -Updates $updates
if (-not $cancelled.Cancelled) { throw 'Installation must require explicit INSTALLER confirmation' }

Write-Output 'PASS: interactive syntax, safe selection, exclusions, confirmation and cancellation'
