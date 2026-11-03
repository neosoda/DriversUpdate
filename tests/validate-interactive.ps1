$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'force_update_drivers_gpo_hardened.ps1'
$menu = Join-Path $root 'DriversUpdate-Manual.ps1'

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
foreach ($name in @('ConvertTo-DriverSelection', 'Read-InteractiveDriverChoice', 'Get-ComPropertyValue', 'Get-DriverExclusionReason', 'Get-DriverEligibilityReason', 'Get-DriverReasonFrench', 'Write-DriverOverview')) {
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

$overview = Write-DriverOverview -Updates $updates
if ((@($overview.EligibleNumbers) -join ',') -cne '1,3') {
    throw 'The French overview must preserve only eligible driver numbers'
}

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

$missingFlag = [pscustomobject]@{ Title = 'Unknown interaction driver'; DriverClass = 'MEDIA'; EulaAccepted = $true }
if ((Get-DriverEligibilityReason -Update $missingFlag) -cne 'InteractionUnknown') { throw 'Missing interaction flag must prevent installation' }
if ((Get-DriverEligibilityReason -Update $updates.Items[1]) -cne 'ExcludedClass:Net') { throw 'Shared eligibility rule must enforce excluded driver classes' }
Write-Output 'PASS: fail-closed eligibility'


# Regression: le menu manuel doit pouvoir COCHER meme les pilotes CanRequestUserInput.
# Le filtrage GPO reste inchangé et les classes sensibles exigent RISQUES.
$manualAst = [System.Management.Automation.Language.Parser]::ParseFile($menu, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'Manual PowerShell syntax errors.' }
$manualFunctions = @{}
$manualAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { $manualFunctions[$_.Name] = $_.Extent.Text }
foreach ($name in @('Get-ManualDriverBlockReason', 'Test-ManualDriverIsSensitive',
                    'Get-ManualDriverWarnings', 'Write-ManualDriverChecklist', 'Read-InteractiveDriverChoice')) {
    if (-not $manualFunctions.ContainsKey($name)) { throw "Manual missing $name" }
    . ([scriptblock]::Create($manualFunctions[$name]))
}
$manualRaw = Get-Content -LiteralPath $menu -Raw -Encoding UTF8
if (-not $manualRaw.Contains('$exclusion = Get-ManualDriverBlockReason -Update $update') -or
    -not $manualRaw.Contains('if ($Interactive) {') -or
    -not $manualRaw.Contains('$installer.AllowSourcePrompts = $true')) {
    throw 'The selected manual drivers are not wired into the Windows Update installer.'
}

$AcceptEula = $true
$script:Configuration = @{
    ExcludedDriverClasses = @('Firmware', 'Net', 'SCSIAdapter', 'HDC', 'DiskDrive')
    ExcludedTitleContains = @('BIOS', 'Firmware')
    IncludedTitleContains = @()
}
$manualUpdates = [pscustomobject]@{
    Count = 3
    Items = @(
        [pscustomobject]@{ Title = 'AOC International - Monitor'; DriverClass = 'OtherHardware'; DriverManufacturer = 'AOC'; InstallationBehavior = [pscustomobject]@{ CanRequestUserInput = $true }; EulaAccepted = $true },
        [pscustomobject]@{ Title = 'Dell, Inc. Firmware Driver Update'; DriverClass = 'Firmware'; DriverManufacturer = 'Dell'; InstallationBehavior = [pscustomobject]@{ CanRequestUserInput = $true }; EulaAccepted = $true },
        [pscustomobject]@{ Title = 'ASIX Net Driver Update'; DriverClass = 'Networking'; DriverManufacturer = 'ASIX'; InstallationBehavior = [pscustomobject]@{ CanRequestUserInput = $true }; EulaAccepted = $true }
    )
}
$manualUpdates | Add-Member -MemberType ScriptMethod -Name Item -Value { param([int]$index) return $this.Items[$index] }
foreach ($update in $manualUpdates.Items) {
    if ($null -ne (Get-ManualDriverBlockReason -Update $update)) { throw 'Interactive driver must be selectable' }
    if ((Get-DriverEligibilityReason -Update $update) -cne 'RequiresInteraction') {
        throw 'GPO must still refuse drivers requiring interaction'
    }
}
if (-not (Test-ManualDriverIsSensitive -Update $manualUpdates.Items[1])) { throw 'Firmware risk not identified' }
if (-not (Test-ManualDriverIsSensitive -Update $manualUpdates.Items[2])) { throw 'Network risk not identified' }
if (Test-ManualDriverIsSensitive -Update $manualUpdates.Items[0]) { throw 'Monitor must not be sensitive' }

function Assert-ManualChoice {
    param([string[]]$Answers, [bool]$Cancelled, [string]$Expected)
    $script:answers = $Answers
    $script:answerIndex = 0
    $result = Read-InteractiveDriverChoice -Updates $manualUpdates
    if ([bool]$result.Cancelled -ne $Cancelled -or ((@($result.SelectedIndices) -join ',') -cne $Expected)) {
        throw "Manual choice failed: $($Answers -join ',') -> Cancelled=$($result.Cancelled), indices=$(@($result.SelectedIndices) -join ',')"
    }
    if ($script:answerIndex -ne $script:answers.Count) { throw 'Manual flow did not consume expected confirmations' }
}
Assert-ManualChoice -Answers @('1','V','INSTALLER') -Cancelled $false -Expected '1'
Assert-ManualChoice -Answers @('2','3','V','RISQUES','INSTALLER') -Cancelled $false -Expected '2,3'
Assert-ManualChoice -Answers @('T','V','RISQUES','INSTALLER') -Cancelled $false -Expected '1,2,3'
Assert-ManualChoice -Answers @('1','1','V','0') -Cancelled $true -Expected ''
Assert-ManualChoice -Answers @('2','V','NON','0') -Cancelled $true -Expected ''
Assert-ManualChoice -Answers @('0') -Cancelled $true -Expected ''
Write-Output 'PASS: manual checkboxes, 3 interactive drivers, sensitive warnings, opt-in confirmations and cancellation'
