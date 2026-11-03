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


# Regression : selection simple, sans confirmation RISQUES/INSTALLER.
# Sous Windows, le dialogue WinForms selectionne les pilotes en un clic.
$manualTokens = $null
$manualErrors = $null
$manualAst = [System.Management.Automation.Language.Parser]::ParseFile($menu, [ref]$manualTokens, [ref]$manualErrors)
if ($manualErrors.Count -ne 0) {
    throw ("Manual syntax errors: " + ($manualErrors | ForEach-Object { $_.Message } | Out-String))
}
$manualFunctions = @{}
$manualAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { $manualFunctions[$_.Name] = $_.Extent.Text }
foreach ($name in @('Get-ManualDriverBlockReason', 'Read-ConsoleDriverChoice', 'Show-DriverSelectionDialog', 'Read-InteractiveDriverChoice')) {
    if (-not $manualFunctions.ContainsKey($name)) { throw "Missing manual function: $name" }
    . ([scriptblock]::Create($manualFunctions[$name]))
}

$manualRaw = Get-Content -LiteralPath $menu -Raw -Encoding UTF8
foreach ($required in @('System.Windows.Forms.CheckedListBox', '$checklist.CheckOnClick = $true',
                        '$form.ShowDialog()', "Installer la sélection", 'Tout cocher', 'Tout décocher',
                        '$originalIndices.Add($i + 1)', '$exclusion = Get-ManualDriverBlockReason -Update $update')) {
    if (-not $manualRaw.Contains($required)) { throw "Manual GUI missing: $required" }
}
if ($manualRaw.Contains('Tapez RISQUES') -or $manualRaw.Contains('Tapez INSTALLER')) {
    throw 'Redundant installation confirmation must not return'
}
if (-not $manualRaw.Contains('if ($Interactive) {') -or
    -not $manualRaw.Contains('$installer.AllowSourcePrompts = $true')) {
    throw 'Manual selection must still flow into the WUA installer'
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
    if ($null -ne (Get-ManualDriverBlockReason -Update $update)) { throw 'Manual driver wrongly excluded' }
    if ((Get-DriverEligibilityReason -Update $update) -cne 'RequiresInteraction') { throw 'GPO exclusion unexpectedly relaxed' }
}

function Assert-ManualConsole {
    param([string[]]$Answers, [bool]$Cancelled, [string]$Expected)
    $script:answers = $Answers
    $script:answerIndex = 0
    $result = Read-ConsoleDriverChoice -Updates $manualUpdates
    if ([bool]$result.Cancelled -ne $Cancelled -or (@($result.SelectedIndices) -join ',') -cne $Expected) {
        throw "Console selection failed: $($Answers -join ',')"
    }
}
Assert-ManualConsole -Answers @('1,3') -Cancelled $false -Expected '1,3'
Assert-ManualConsole -Answers @('T') -Cancelled $false -Expected '1,2,3'
Assert-ManualConsole -Answers @('0') -Cancelled $true -Expected ''
Assert-ManualConsole -Answers @('invalid', '2') -Cancelled $false -Expected '2'

# Un dialogue qui se termine par Annuler ne doit jamais etre transforme en
# installation. Le test simule l'interface sans ouvrir de fenetre WinForms.
function Show-DriverSelectionDialog { param($Updates)
    return [pscustomobject]@{ Cancelled = $true; SelectedIndices = @() }
}
$cancelled = Read-InteractiveDriverChoice -Updates $manualUpdates
if (-not $cancelled.Cancelled) { throw 'GUI cancellation must not start an installation' }
Write-Output 'PASS: GUI wiring, immediate install, console fallback and unchanged GPO restrictions'
