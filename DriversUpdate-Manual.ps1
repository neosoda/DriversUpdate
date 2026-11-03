<#
.SYNOPSIS
    Console independante DriversUpdate : recherche et installation en francais.
.DESCRIPTION
    Contient son propre moteur Windows Update ; aucun script externe requis.
    Les pilotes ne sont installes qu'apres selection et confirmation.
#>
[CmdletBinding()]
param()

# Forcer Windows PowerShell 5.1 x64 pour les composants COM Windows Update.
if (($PSVersionTable.PSEdition -ne 'Desktop') -or
    ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)) {
    $winps = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    } else {
        Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    & $winps -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

# Elevation UAC automatique : un clic droit > "Executer avec PowerShell"
# suffit. Ne jamais demander l'elevation pour une session non interactive.
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
    throw 'Le menu doit etre lance dans une console interactive, pas par GPO ou sous SYSTEM.'
}

if (-not (Test-IsAdministrator)) {
    $powerShellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Write-Host '  Droits administrateur necessaires : demande UAC en cours...' -ForegroundColor Yellow
    try {
        # Start-Process recompose les arguments : proteger le chemin avec des
        # guillemets pour les dossiers contenant des espaces.
        $quotedScriptPath = '"' + $PSCommandPath + '"'
        Start-Process -FilePath $powerShellExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedScriptPath) -Verb RunAs -ErrorAction Stop | Out-Null
    } catch {
        Write-Host ("  Elevation refusee ou impossible : {0}" -f $_.Exception.Message) -ForegroundColor Red
        exit 101
    }
    # Le menu sera affiche dans la nouvelle console elevee uniquement.
    exit 0
}

# Etat partage avec le moteur autonome ci-dessous.
$LogRoot = Join-Path $env:ProgramData 'DriversUpdate\logs'
$StateRoot = Join-Path $env:ProgramData 'DriversUpdate\state'
$MinimumScanIntervalHours = 0
$Force = $false
$ScanOnly = $false
$DryRun = $false
$AcceptEula = $true
$TemporaryMicrosoftUpdateService = $false
$Interactive = $false
$UserFacing = $true

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptName = 'DriversUpdateManual'
$ScriptVersion = '3.1.0'

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
$script:ProxyBackupRoot = Join-Path -Path $StateRoot -ChildPath 'proxy'
$script:ProxyBackupPath = Join-Path -Path $script:ProxyBackupRoot -ChildPath 'winhttp-before-driversupdate.txt'
$script:ProxyRegistryBackupPath = Join-Path -Path $script:ProxyBackupRoot -ChildPath 'winhttp-registry-before-driversupdate.json'
$script:ProxyRecoveryReady = $false

# ============================================================
# CONFIGURATION LOCALE : modifier la copie deployee, jamais GitHub.
# AUCUN autre fichier de configuration ou d'identifiants requis.
# ============================================================
$ProxyEnabled = $false                     # $false : connexion Windows Update habituelle
$ProxyHost = '172.17.0.1'
$ProxyPort = 3128
$ProxyBypassList = '<local>'               # Ex. : '<local>;*.domaine.local'
$ProxyUser = 'UTILISATEUR'                 # Vide si le proxy n'exige pas d'identifiants
$ProxyPassword = 'MOT_DE_PASSE'            # Vide si aucune authentification
$ProxyAuthScheme = 'Basic'                 # Basic, NTLM, Negotiate ou Digest

# Exclusions de securite : a conserver dans tout deploiement automatique.
$ExcludedDriverClasses = @('Firmware', 'Net', 'SCSIAdapter', 'HDC', 'DiskDrive')
$ExcludedTitleContains = @('BIOS', 'Firmware')
$IncludedTitleContains = @()

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
    if (-not $UserFacing) { Write-Host $line }

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
    $command = '& {0} -LogRoot {1} -StateRoot {2} -MinimumScanIntervalHours {3} -AcceptEula:${4}' -f $pathLiteral, $logRootLiteral, $stateRootLiteral, $MinimumScanIntervalHours, ([string]$AcceptEula).ToLowerInvariant()

    if ($Force) { $command += ' -Force' }
    if ($ScanOnly) { $command += ' -ScanOnly' }
    if ($DryRun) { $command += ' -DryRun' }
    if ($Interactive) { $command += ' -Interactive' }
    if ($UserFacing) { $command += ' -UserFacing' }
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
    # Configuration directement dans ce PS1 : pas de JSON ni de fichier DPAPI.
    $mode = if ($ProxyEnabled) { 'Temporary' } else { 'System' }
    if ($ProxyEnabled) {
        if ([string]::IsNullOrWhiteSpace($ProxyHost) -or $ProxyHost -notmatch '^[A-Za-z0-9.-]+$') {
            throw 'ProxyHost invalide : un nom DNS ou une adresse IPv4 est attendu.'
        }
        if ($ProxyPort -lt 1 -or $ProxyPort -gt 65535) { throw 'ProxyPort doit etre compris entre 1 et 65535.' }
        if ($ProxyAuthScheme -notin @('Basic', 'NTLM', 'Negotiate', 'Digest')) {
            throw 'ProxyAuthScheme invalide.'
        }
        if ([bool]$ProxyUser -xor [bool]$ProxyPassword) {
            throw 'Le nom utilisateur et le mot de passe proxy doivent etre tous deux renseignes, ou tous deux vides.'
        }
        if ($ProxyUser -eq 'UTILISATEUR' -or $ProxyPassword -eq 'MOT_DE_PASSE') {
            throw 'Identifiants proxy non configures : renseignez ProxyUser et ProxyPassword dans la copie locale du PS1.'
        }
    }
    return [ordered]@{
        ExcludedDriverClasses = @($ExcludedDriverClasses)
        ExcludedTitleContains = @($ExcludedTitleContains)
        IncludedTitleContains = @($IncludedTitleContains)
        Proxy = [ordered]@{
            Mode = $mode
            Address = "$($ProxyHost):$ProxyPort"
            BypassList = $ProxyBypassList
            AuthenticationScheme = $ProxyAuthScheme
            UseWinHttpGlobalCredentials = $true
        }
    }
}

# Le mode System utilise WinHTTP deja configure sur l'ordinateur.
# Le mode Temporary remplace WinHTTP le temps du traitement et restaure son etat.
function Protect-DriverProxyBackupDirectory {
    # netsh exec lit un script. Seuls SYSTEM et les administrateurs doivent
    # pouvoir modifier une sauvegarde executee avec des privileges eleves.
    Initialize-LocalPath -Path $script:ProxyBackupRoot
    $acl = Get-Acl -LiteralPath $script:ProxyBackupRoot -ErrorAction Stop
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existing in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleSpecific($existing)
    }
    $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inherit,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $script:ProxyBackupRoot -AclObject $acl -ErrorAction Stop
    $script:ProxyRecoveryReady = $true
}

function Invoke-DriversNetsh {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = @(& netsh.exe @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ("netsh {0} a echoue (code {1}): {2}" -f ($Arguments -join ' '), $LASTEXITCODE, ($output -join ' '))
    }
    return ($output -join [Environment]::NewLine)
}

function Restore-DriverProxy {
    $restoredWinHttp = $true
    $restoredRegistry = $true

    if (Test-Path -LiteralPath $script:ProxyBackupPath -PathType Leaf) {
        try {
            $null = Invoke-DriversNetsh -Arguments @('exec', $script:ProxyBackupPath)
            Write-Log -Message 'Configuration WinHTTP precedente restauree.'
            Remove-Item -LiteralPath $script:ProxyBackupPath -Force -ErrorAction Stop
        } catch {
            $restoredWinHttp = $false
            Write-Log -Level 'ERROR' -Message "Echec restauration WinHTTP: $($_.Exception.Message)"
        }
    }

    if (Test-Path -LiteralPath $script:ProxyRegistryBackupPath -PathType Leaf) {
        try {
            $saved = Get-Content -LiteralPath $script:ProxyRegistryBackupPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
            if ($saved.Existed) {
                New-ItemProperty -Path $key -Name 'ShareCredsWithWinHttp' -PropertyType DWord -Value ([int]$saved.Value) -Force -ErrorAction Stop | Out-Null
            } else {
                Remove-ItemProperty -Path $key -Name 'ShareCredsWithWinHttp' -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $script:ProxyRegistryBackupPath -Force -ErrorAction Stop
            Write-Log -Message 'Parametre WinHTTP des identifiants restaure.'
        } catch {
            $restoredRegistry = $false
            Write-Log -Level 'ERROR' -Message "Echec restauration registre WinHTTP: $($_.Exception.Message)"
        }
    }
    if (-not ($restoredWinHttp -and $restoredRegistry)) {
        throw 'Restauration proxy incomplete. Fichiers de sauvegarde conserves dans le repertoire state.'
    }
}

function Set-DriverGlobalProxyCredentials {
    param(
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$Scheme
    )

    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
    $previous = Get-RegistryValueOrNull -Path $key -Name 'ShareCredsWithWinHttp'
    $registryState = [ordered]@{ Existed = ($null -ne $previous); Value = $previous }
    # La sauvegarde precede imperativement la modification de la cle.
    $registryState | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:ProxyRegistryBackupPath -Encoding UTF8 -ErrorAction Stop
    New-ItemProperty -Path $key -Name 'ShareCredsWithWinHttp' -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null

    if (-not ('DriversUpdateWinHttpNative' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DriversUpdateWinHttpNative {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct Credentials {
        [MarshalAs(UnmanagedType.LPStr)] public string UserName;
        [MarshalAs(UnmanagedType.LPStr)] public string Password;
        [MarshalAs(UnmanagedType.LPStr)] public string Realm;
        public UInt32 AuthScheme;
        [MarshalAs(UnmanagedType.LPStr)] public string HostName;
        public UInt32 Port;
        [MarshalAs(UnmanagedType.LPStr)] public string Url;
    }
    [DllImport("winhttp.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool WinHttpSetOption(IntPtr handle, UInt32 option, ref Credentials credentials, UInt32 length);
}
'@
    }

    $parts = $Address.Split(':')
    $schemeValue = switch ($Scheme) {
        'Basic' { 1 }
        'NTLM' { 2 }
        'Negotiate' { 16 }
        'Digest' { 8 }
    }
    $native = New-Object DriversUpdateWinHttpNative+Credentials
    $native.UserName = $Credential.UserName
    $native.Password = $Credential.GetNetworkCredential().Password
    $native.AuthScheme = [uint32]$schemeValue
    $native.HostName = $parts[0]
    $native.Port = [uint32][int]$parts[1]
    $length = [Runtime.InteropServices.Marshal]::SizeOf($native)

    # 97 = WINHTTP_OPTION_GLOBAL_PROXY_CREDS. Aucune valeur n'est ecrite au journal.
    $success = [DriversUpdateWinHttpNative]::WinHttpSetOption([IntPtr]::Zero, [uint32]97, [ref]$native, [uint32]$length)
    $native.Password = $null
    if (-not $success) {
        $win32 = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Injection des identifiants WinHTTP impossible (Win32=$win32)."
    }
    Write-Log -Message "Identifiants proxy WinHTTP transmis ($Scheme)."
}

function Initialize-DriverProxy {
    $proxy = $script:Configuration['Proxy']
    if ($proxy.Mode -ne 'Temporary') {
        Write-Log -Message 'Proxy : configuration WinHTTP machine existante conservee.'
        return
    }

    $credential = $null
    if (-not [string]::IsNullOrWhiteSpace($ProxyUser)) {
        # Identifiants uniquement en memoire (config PS1 locale).
        # Ne jamais inscrire de mot de passe dans les journaux.
        $securePassword = ConvertTo-SecureString -String $ProxyPassword -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($ProxyUser, $securePassword)
    }

    # Fichier persistant permettant la recuperation au prochain lancement
    # apres interruption brutale (seul le mutex de ce script protege ses executions).
    $dump = Invoke-DriversNetsh -Arguments @('winhttp', 'dump')
    if ([string]::IsNullOrWhiteSpace($dump)) { throw 'Sauvegarde WinHTTP vide.' }
    Set-Content -LiteralPath $script:ProxyBackupPath -Value $dump -Encoding ASCII -ErrorAction Stop
    Write-Log -Message "Proxy WinHTTP temporaire : $($proxy.Address)."
    $arguments = @('winhttp', 'set', 'proxy', "proxy-server=$($proxy.Address)")
    if ($proxy.BypassList) { $arguments += "bypass-list=$($proxy.BypassList)" }
    $null = Invoke-DriversNetsh -Arguments $arguments

    if ($null -ne $credential) {
        Set-DriverGlobalProxyCredentials -Credential $credential -Address $proxy.Address -Scheme $proxy.AuthenticationScheme
    }
    $script:ProxyCredential = $credential
}

function Set-DriverSessionProxy {
    param([Parameter(Mandatory = $true)]$Session)
    $proxy = $script:Configuration['Proxy']
    if ($proxy.Mode -ne 'Temporary') { return }

    $webProxy = New-Object -ComObject Microsoft.Update.WebProxy
    $webProxy.Address = $proxy.Address
    $webProxy.AutoDetect = $false
    $webProxy.BypassProxyOnLocal = ($proxy.BypassList -match '(^|;)<local>(;|$)')
    if ($null -ne $script:ProxyCredential) {
        $webProxy.UserName = $script:ProxyCredential.UserName
        $webProxy.SetPassword($script:ProxyCredential.GetNetworkCredential().Password)
    }
    $Session.WebProxy = $webProxy
    Write-Log -Message 'Proxy Windows Update Agent configure pour la session SYSTEM.'
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
        if ($token -match '^\s*(\d+)(?:\s*-\s*(\d+))?\s*$') {
            $first = [int]$Matches[1]
            $last = if ($Matches.ContainsKey(2)) { [int]$Matches[2] } else { $first }
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

function Get-DriverReasonFrench {
    param([string]$Reason)

    switch -Regex ($Reason) {
        '^ExcludedClass:' { return "Catégorie exclue ($($Reason.Substring(14)))" }
        '^ExcludedTitle:' { return "Titre exclu ($($Reason.Substring(14)))" }
        '^NotAllowlisted$' { return "Non autorisé par la liste des pilotes" }
        '^RequiresInteraction$' { return "Nécessite une intervention utilisateur" }
        '^InteractionUnknown$' { return "Installation silencieuse non garantie" }
        '^EulaNotAccepted$' { return "Licence non acceptée" }
        '^EulaUnknown$' { return "Licence impossible à vérifier" }
        default { return $Reason }
    }
}

function Write-DriverOverview {
    param([Parameter(Mandatory = $true)]$Updates)

    $eligible = New-Object 'System.Collections.Generic.List[int]'
    $excluded = 0
    Write-Host ''
    Write-Host '  PILOTES DISPONIBLES SUR CET ORDINATEUR' -ForegroundColor Cyan
    Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray

    for ($index = 0; $index -lt $Updates.Count; $index++) {
        $update = $Updates.Item($index)
        $number = $index + 1
        $reason = Get-DriverEligibilityReason -Update $update
        Write-Host ("  [{0}] {1}" -f $number, $update.Title) -ForegroundColor White
        $manufacturer = Get-ComPropertyValue -Object $update -Name 'DriverManufacturer'
        $className = Get-ComPropertyValue -Object $update -Name 'DriverClass'
        if ($manufacturer -or $className) {
            Write-Host ("      {0} - {1}" -f $manufacturer, $className) -ForegroundColor DarkGray
        }
        if ($reason) {
            $excluded++
            Write-Host ("      EXCLU : {0}" -f (Get-DriverReasonFrench -Reason $reason)) -ForegroundColor DarkYellow
        } else {
            $eligible.Add($number)
            Write-Host '      Autorisé pour une installation silencieuse' -ForegroundColor Green
        }
        Write-Host ''
    }

    Write-Host ("  Bilan : {0} autorisé(s), {1} exclu(s)." -f $eligible.Count, $excluded) -ForegroundColor Cyan
    Write-Host '  Les exclusions protègent notamment les pilotes sensibles.' -ForegroundColor DarkGray
    return [pscustomobject]@{ EligibleNumbers = @($eligible.ToArray()) }
}

# Le mode manuel permet l'installation volontaire de pilotes exclus du mode
# silencieux GPO, apres affichage des risques et confirmation explicite.
function Get-ManualDriverBlockReason {
    param([Parameter(Mandatory = $true)]$Update)
    if (-not $AcceptEula) {
        try {
            if (-not [bool]$Update.EulaAccepted) { return 'EulaNotAccepted' }
        } catch { return 'EulaUnknown' }
    }
    return $null
}

function Test-ManualDriverIsSensitive {
    param([Parameter(Mandatory = $true)]$Update)
    $title = [string]$Update.Title
    $class = [string](Get-ComPropertyValue -Object $Update -Name 'DriverClass')
    return ($class -match '(?i)^(Net|Networking|SCSIAdapter|HDC|DiskDrive|Firmware)$' -or
            $title -match '(?i)(^|[^a-z])(firmware|bios|uefi|network|networking|ethernet|wi-fi|wifi|net driver)([^a-z]|$)')
}

function Get-ManualDriverWarnings {
    param([Parameter(Mandatory = $true)]$Update)
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    try {
        if ([bool]$Update.InstallationBehavior.CanRequestUserInput) {
            $warnings.Add('Le pilote peut demander une intervention pendant son installation.')
        }
    } catch {
        $warnings.Add('Comportement interactif non déterminé.')
    }
    $automaticExclusion = Get-DriverExclusionReason -Update $Update
    if ($null -ne $automaticExclusion) {
        $warnings.Add(("Exclu du mode GPO : {0}" -f (Get-DriverReasonFrench -Reason $automaticExclusion)))
    }
    if (Test-ManualDriverIsSensitive -Update $Update) {
        $warnings.Add('PILOTE SENSIBLE (réseau / firmware / stockage) : risque de coupure ou redémarrage.')
    }
    return $warnings.ToArray()
}

function Write-ManualDriverChecklist {
    param(
        [Parameter(Mandatory = $true)]$Updates,
        [int[]]$SelectedNumbers = @()
    )
    Write-Host ''
    Write-Host '  ÉTAPE 2/3 - COCHER LES PILOTES À INSTALLER' -ForegroundColor Cyan
    Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
    $availableCount = 0
    for ($index = 0; $index -lt $Updates.Count; $index++) {
        $update = $Updates.Item($index)
        $number = $index + 1
        $reason = Get-ManualDriverBlockReason -Update $update
        if ($reason) {
            Write-Host ("  [-] {0}. {1}" -f $number, $update.Title) -ForegroundColor DarkGray
            Write-Host ("      Indisponible : {0}" -f (Get-DriverReasonFrench -Reason $reason)) -ForegroundColor DarkYellow
            continue
        }
        $availableCount++
        $checked = if ($number -in $SelectedNumbers) { 'x' } else { ' ' }
        $color = if ($checked -eq 'x') { 'Green' } else { 'White' }
        Write-Host ("  [{0}] {1}. {2}" -f $checked, $number, $update.Title) -ForegroundColor $color
        $manufacturer = Get-ComPropertyValue -Object $update -Name 'DriverManufacturer'
        $className = Get-ComPropertyValue -Object $update -Name 'DriverClass'
        if ($manufacturer -or $className) {
            Write-Host ("      {0} - {1}" -f $manufacturer, $className) -ForegroundColor DarkGray
        }
        foreach ($warning in @(Get-ManualDriverWarnings -Update $update)) {
            Write-Host ("      ! {0}" -f $warning) -ForegroundColor Yellow
        }
    }
    Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host ("  Sélection : {0} / {1} pilote(s) disponible(s)." -f $SelectedNumbers.Count, $availableCount) -ForegroundColor Cyan
    Write-Host '  Numéro = cocher/décocher | 1,3 = plusieurs | T = tout cocher' -ForegroundColor Gray
    Write-Host '  A = tout décocher | V = vérifier et valider | 0 = annuler' -ForegroundColor Gray
}

function Read-InteractiveDriverChoice {
    param([Parameter(Mandatory = $true)]$Updates)

    $allowed = New-Object 'System.Collections.Generic.List[int]'
    for ($index = 0; $index -lt $Updates.Count; $index++) {
        if ($null -eq (Get-ManualDriverBlockReason -Update $Updates.Item($index))) {
            $allowed.Add(($index + 1))
        }
    }
    if ($allowed.Count -eq 0) {
        Write-Host '  Aucun pilote disponible pour une sélection manuelle.' -ForegroundColor Yellow
        return [pscustomobject]@{ Cancelled = $true; SelectedIndices = @() }
    }

    $checked = New-Object 'System.Collections.Generic.HashSet[int]'
    while ($true) {
        $current = @($checked | Sort-Object)
        Write-ManualDriverChecklist -Updates $Updates -SelectedNumbers $current
        $answer = (Read-Host '  Votre choix').Trim()

        if ($answer -eq '0') {
            Write-Host '  Installation annulée : aucun téléchargement effectué.' -ForegroundColor Yellow
            return [pscustomobject]@{ Cancelled = $true; SelectedIndices = @() }
        }
        if ($answer -match '^(?i:a)$') {
            $checked.Clear()
            continue
        }
        if ($answer -match '^(?i:t|tous)$') {
            $checked.Clear()
            foreach ($number in $allowed) { [void]$checked.Add($number) }
            continue
        }
        if ($answer -match '^(?i:v|valider)$') {
            if ($checked.Count -eq 0) {
                Write-Host '  Cochez au moins un pilote avant de valider.' -ForegroundColor Yellow
                continue
            }
            $selected = @($checked | Sort-Object)
            Write-Host ''
            Write-Host '  ÉTAPE 3/3 - VÉRIFIER AVANT INSTALLATION' -ForegroundColor Cyan
            $sensitive = $false
            foreach ($number in $selected) {
                $update = $Updates.Item($number - 1)
                Write-Host ("  [x] {0}" -f $update.Title) -ForegroundColor White
                if (Test-ManualDriverIsSensitive -Update $update) { $sensitive = $true }
            }
            Write-Host ("  Total : {0} pilote(s) sélectionné(s)." -f $selected.Count) -ForegroundColor Cyan
            Write-Host '  Des pilotes peuvent demander une interaction et provoquer un redémarrage.' -ForegroundColor Yellow
            Write-Host '  Aucun redémarrage automatique ne sera déclenché.' -ForegroundColor Yellow

            if ($sensitive) {
                Write-Host '  ATTENTION : un pilote sensible a été coché (réseau, firmware ou stockage).' -ForegroundColor Red
                $riskConfirmation = Read-Host '  Tapez RISQUES pour accepter explicitement ce risque'
                if ($riskConfirmation -cne 'RISQUES') {
                    Write-Host '  Validation des risques refusée. Retour à la sélection.' -ForegroundColor Yellow
                    continue
                }
            }
            $confirmation = Read-Host '  Tapez INSTALLER pour lancer les pilotes cochés (autre réponse = annuler)'
            if ($confirmation -cne 'INSTALLER') {
                Write-Host '  Installation annulée. Aucun pilote téléchargé.' -ForegroundColor Yellow
                return [pscustomobject]@{ Cancelled = $true; SelectedIndices = @() }
            }
            return [pscustomobject]@{ Cancelled = $false; SelectedIndices = @($selected) }
        }

        if ($answer -eq '?') { continue }
        try {
            $numbers = @(ConvertTo-DriverSelection -InputText $answer -EligibleNumbers @($allowed.ToArray()) -MaxIndex $Updates.Count)
            if ($numbers.Count -eq 0) {
                Write-Host '  Entrez un numéro, T, V ou 0.' -ForegroundColor Yellow
                continue
            }
            foreach ($number in $numbers) {
                if (-not $checked.Add([int]$number)) { [void]$checked.Remove([int]$number) }
            }
        } catch {
            Write-Host ("  Choix incorrect : {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
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
        # Restaurer d'abord WinHTTP, meme si la configuration a ete supprimee ou corrompue.
        try { Protect-DriverProxyBackupDirectory; Restore-DriverProxy }
        catch {
            Save-State -ExitCode $ExitCodes.PrerequisiteFailed -Outcome 'ProxyRestoreFailed'
            return $ExitCodes.PrerequisiteFailed
        }
        if ($TemporaryMicrosoftUpdateService) { Write-Log -Level 'WARN' -Message 'Deprecated switch ignored: V2 does not register Microsoft Update.' }
        try { $script:Configuration = Get-DriverConfiguration }
        catch { Write-Log -Level 'ERROR' -Message "Configuration du script invalide: $($_.Exception.Message)"; Save-State -ExitCode $ExitCodes.PrerequisiteFailed -Outcome 'InvalidConfig'; return $ExitCodes.PrerequisiteFailed }
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
            Initialize-DriverProxy
        } catch {
            Write-Log -Level 'ERROR' -Message "Initialisation du proxy impossible: $($_.Exception.Message)"
            Save-State -ExitCode $ExitCodes.PrerequisiteFailed -Outcome 'ProxySetupFailed'
            return $ExitCodes.PrerequisiteFailed
        }

        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $session.ClientApplicationID = $ScriptName
            # IWebProxy n'est pas pris en charge dans toutes les versions de Windows.
            # Le proxy WinHTTP machine reste la voie principale, y compris sous SYSTEM.
            try { Set-DriverSessionProxy -Session $session }
            catch {
                Write-Log -Level 'WARN' -Message "Proxy WUA indisponible, utilisation de WinHTTP: $($_.Exception.Message)"
            }

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
            if ($UserFacing) {
                Write-Host '  ÉTAPE 1/3 - RECHERCHE WINDOWS UPDATE' -ForegroundColor Cyan
                Write-Host '  Recherche des pilotes en cours...'
                Write-Host "  Cette étape peut prendre quelques minutes." -ForegroundColor DarkGray
            }
            Write-Log -Message "Searching driver updates with criteria: $criteria"
            $script:ScanAttempted = $true
            $searchResult = $searcher.Search($criteria)
            if ([int]$searchResult.ResultCode -ne 2) { throw "Search did not succeed: $(Get-OperationResultName -ResultCode ([int]$searchResult.ResultCode))" }
            $script:ScanSucceeded = $true
            $updates = $searchResult.Updates
            $updatesFound = $updates.Count
            if ($UserFacing) { Write-Host ("  {0} mise(s) à jour détectée(s)." -f $updatesFound) -ForegroundColor Green }
            Write-Log -Message "Search result: $(Get-OperationResultName -ResultCode ([int]$searchResult.ResultCode)); updates found: $updatesFound."
        } catch {
            Write-Log -Level 'ERROR' -Message "Driver update search failed: $($_.Exception.Message)"
            Save-State -ExitCode $ExitCodes.SearchFailed -Outcome 'SearchFailed'
            return $ExitCodes.SearchFailed
        }

        if ($updatesFound -eq 0) {
            if ($UserFacing) { Write-Host '  Aucun nouveau pilote à proposer pour cet ordinateur.' -ForegroundColor Green }
            Write-Log -Message 'No applicable driver update found.'
            Save-State -ExitCode $ExitCodes.Success -Outcome 'NoUpdatesFound' -UpdatesFound 0
            return $ExitCodes.Success
        }

        if ($UserFacing -and ($ScanOnly -or $DryRun)) {
            $null = Write-DriverOverview -Updates $updates
            Write-Host "  Recherche terminée : aucun téléchargement, aucune installation." -ForegroundColor Green
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

            # Le choix manuel explicite prime sur le filtre silencieux GPO.
            if ($Interactive) {
                if (($index + 1) -notin $interactiveSelectedIndices) {
                    Add-DriverResult -Update $update -Status 'Skipped' -Detail 'NotSelected'
                    continue
                }
                $exclusion = Get-ManualDriverBlockReason -Update $update
            } else {
                $exclusion = Get-DriverEligibilityReason -Update $update
            }
            if ($null -ne $exclusion) {
                Write-Log -Message "Skipping driver: $($update.Title) ($exclusion)"
                Add-DriverResult -Update $update -Status 'Skipped' -Detail $exclusion
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
            if ($UserFacing) { Write-Host "  Aucun pilote autorisé n'a été retenu." -ForegroundColor Yellow }
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
                if ($UserFacing) {
                    Write-Host ''
                    Write-Host ("  TÉLÉCHARGEMENT DE {0} PILOTE(S)" -f $downloadCollection.Count) -ForegroundColor Cyan
                    Write-Host '  Merci de ne pas fermer cette fenêtre pendant cette opération.'
                }
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
            if ($UserFacing) {
                Write-Host ''
                Write-Host ("  INSTALLATION DE {0} PILOTE(S)" -f $readyToInstall.Count) -ForegroundColor Cyan
                Write-Host '  Installation en cours... Ne redémarrez pas Windows maintenant.'
            }
            Write-Log -Message "Installing $($readyToInstall.Count) driver update(s)."
            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $readyToInstall
            if ($Interactive) {
                # Autoriser les invites de source lorsque le pilote les utilise.
                # Ne garantit pas que tous les installeurs afficheront une UI.
                try { $installer.AllowSourcePrompts = $true }
                catch { Write-Log -Level 'WARN' -Message "AllowSourcePrompts indisponible: $($_.Exception.Message)" }
            }
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


function Invoke-StandaloneDriverEngine {
    $mutex = $null
    $lockAcquired = $false
    $exitCode = $ExitCodes.PrerequisiteFailed
    try {
        Initialize-LocalPath -Path $LogRoot
        Initialize-LocalPath -Path $StateRoot
        # A 32-bit launcher delegates to a 64-bit child; only the child takes the mutex.
        if (-not ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)) {
            $mutex = New-Object System.Threading.Mutex($false, 'Global\DriversUpdateGpo')
            try { $lockAcquired = $mutex.WaitOne(0) }
            catch [System.Threading.AbandonedMutexException] { $lockAcquired = $true }
        }
        if ($null -ne $mutex -and -not $lockAcquired) {
            Write-Output 'DriversUpdate: another execution is already active.'
            $exitCode = $ExitCodes.ConcurrentRun
        } else {
            if ($lockAcquired) {
                try { Rotate-Log } catch { Write-Output "Log rotation warning: $($_.Exception.Message)" }
            }
            $exitCode = Invoke-DriverUpdateDeployment
        }
    } catch {
        Write-Output "DriversUpdate startup error: $($_.Exception.Message)"
        $exitCode = $ExitCodes.PrerequisiteFailed
    } finally {
        # Restaurer meme si recherche/telechargement/installation a echoue.
        # Ne jamais modifier l'etat du proxy lorsqu'un autre lancement detient le mutex.
        if ($lockAcquired -and $script:ProxyRecoveryReady) {
            try { Restore-DriverProxy }
            catch {
                Write-Output "DriversUpdate proxy restoration failed: $($_.Exception.Message)"
                $exitCode = $ExitCodes.PrerequisiteFailed
                try { Save-State -ExitCode $exitCode -Outcome 'ProxyRestoreFailed' }
                catch { Write-Output "DriversUpdate state write failed: $($_.Exception.Message)" }
            }
        }
        $script:ProxyCredential = $null
        if ($lockAcquired -and $null -ne $mutex) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
    Write-Log -Message "Exit code: $exitCode"
    return $exitCode
}

$programDataPath = Join-Path -Path $env:ProgramData -ChildPath 'DriversUpdate'
$statePath = Join-Path -Path $programDataPath -ChildPath 'state\state.json'
$logPath = Join-Path -Path $programDataPath -ChildPath 'logs\deploy.log'


function Get-ModeLabel {
    param([string]$Mode)
    switch ($Mode) {
        'ScanOnly' { return 'Recherche seule' }
        'DryRun' { return 'Simulation sans installation' }
        'Interactive' { return 'Installation manuelle' }
        'Install' { return 'Installation automatique (GPO)' }
        default { return $Mode }
    }
}

function Get-OutcomeLabel {
    param([string]$Outcome)
    switch ($Outcome) {
        'Success' { return 'Installation terminée' }
        'SuccessRebootRequired' { return 'Installation terminée, redémarrage nécessaire' }
        'NoUpdatesFound' { return 'Aucune mise à jour de pilote disponible' }
        'NoEligibleCandidates' { return 'Aucun pilote autorisé par les filtres' }
        'ScanOnly' { return 'Recherche terminée' }
        'DryRun' { return 'Simulation terminée' }
        'CancelledByUser' { return 'Installation annulée' }
        'SkippedPolicy' { return 'Recherche interdite par les stratégies Windows Update' }
        'SkippedRecentSuccessfulRun' { return 'Recherche non nécessaire (exécution récente)' }
        'InteractiveConsoleRequired' { return 'Console interactive indisponible' }
        'PolicyConflict' { return 'Stratégies Windows Update contradictoires' }
        'InvalidConfig' { return 'Configuration invalide' }
        'SearchFailed' { return 'Échec de la recherche des pilotes' }
        'DownloadFailed' { return 'Échec du téléchargement' }
        'NoDownloadedUpdates' { return 'Aucun pilote téléchargé' }
        'InstallFailed' { return "Échec de l'installation" }
        'PartialFailure' { return 'Installation partiellement réussie' }
        'PrerequisiteFailed' { return 'Prérequis non satisfaits' }
        'NotElevated' { return "Droits administrateur manquants" }
        'UnexpectedFailure' { return 'Erreur inattendue' }
        default { return $Outcome }
    }
}

function Get-DriverReasonLabel {
    param([string]$Detail)
    switch -Regex ($Detail) {
        '^ExcludedClass:' { return "Catégorie protégée : $($Detail.Substring(14))" }
        '^ExcludedTitle:' { return "Mot-clé exclu : $($Detail.Substring(14))" }
        '^NotAllowlisted$' { return 'Non autorisé par la liste des titres' }
        '^RequiresInteraction$' { return "Intervention utilisateur nécessaire" }
        '^InteractionUnknown$' { return "Installation silencieuse non garantie" }
        '^EulaNotAccepted$' { return 'Licence non acceptée' }
        '^EulaUnknown$' { return 'Licence impossible à vérifier' }
        '^NotSelected$' { return "Non sélectionné" }
        default { return $Detail }
    }
}

function Get-DriverResultLabel {
    param([string]$Status, [string]$Detail)
    switch ($Status) {
        'Eligible' { return 'Disponible' }
        'Skipped' { return "Exclu : $(Get-DriverReasonLabel -Detail $Detail)" }
        'Succeeded' { return 'Installé' }
        'SucceededWithErrors' { return 'Installé avec avertissements' }
        'Failed' { return 'Échec' }
        'Aborted' { return 'Interrompu' }
        default { return $Status }
    }
}

function Show-LastState {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        Write-Host 'Aucun bilan disponible. Lancez une recherche pour commencer.' -ForegroundColor Yellow
        return
    }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $dateLabel = [string]$state.LastRunUtc
        try {
            $dateLabel = ([datetime]::Parse($dateLabel)).ToLocalTime().ToString('dd/MM/yyyy à HH:mm')
        } catch {
            # La date brute reste visible si l'horodatage est incorrect.
        }

        Write-Host ''
        Write-Host '  DERNIER BILAN' -ForegroundColor Cyan
        Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host ("  Date                 : {0}" -f $dateLabel)
        Write-Host ("  Machine              : {0}" -f $state.ComputerName)
        Write-Host ("  Mode                 : {0}" -f (Get-ModeLabel -Mode ([string]$state.ScanMode)))
        Write-Host ("  Résultat             : {0}" -f (Get-OutcomeLabel -Outcome ([string]$state.LastOutcome)))
        Write-Host ("  Pilotes détectés     : {0}" -f $state.UpdatesFound)
        Write-Host ("  Pilotes installés    : {0}" -f $state.UpdatesInstalled)
        if ([bool]$state.RebootRequired) {
            Write-Host '  Redémarrage          : nécessaire (non automatique)' -ForegroundColor Yellow
        } else {
            Write-Host '  Redémarrage          : non demandé par Windows Update'
        }

        $results = @($state.DriverResults | Where-Object { $null -ne $_ })
        if ($results.Count -gt 0) {
            Write-Host ''
            Write-Host '  DÉTAIL DES PILOTES' -ForegroundColor Cyan
            Write-Host '  --------------------------------------------------------' -ForegroundColor DarkGray
            $isAudit = ([string]$state.ScanMode -in @('ScanOnly', 'DryRun'))
            foreach ($driver in $results) {
                # Un pilote installé figure d'abord comme candidat, puis comme résultat :
                # ne pas afficher deux fois la même opération dans le bilan final.
                if (-not $isAudit -and $driver.Status -eq 'Eligible') { continue }
                $label = Get-DriverResultLabel -Status ([string]$driver.Status) -Detail ([string]$driver.Detail)
                $color = if ($driver.Status -eq 'Skipped') { 'DarkYellow' } elseif ($driver.Status -in @('Failed', 'Aborted')) { 'Red' } else { 'Green' }
                Write-Host ("  {0}" -f $driver.Title)
                Write-Host ("      {0}" -f $label) -ForegroundColor $color
            }
        }
        Write-Host ''
        Write-Host ("  Journal technique : {0}" -f $logPath) -ForegroundColor DarkGray
    } catch {
        Write-Host ("Impossible de lire le bilan : {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Show-RecentLog {
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        Write-Host 'Aucun journal disponible pour le moment.' -ForegroundColor Yellow
        return
    }
    Write-Host ''
    Write-Host '  JOURNAL TECHNIQUE : 40 DERNIÈRES LIGNES' -ForegroundColor Cyan
    Write-Host '  Les détails techniques peuvent être en anglais.' -ForegroundColor DarkGray
    Write-Host ("  Fichier : {0}" -f $logPath) -ForegroundColor DarkGray
    Write-Host ''
    try {
        Get-Content -LiteralPath $logPath -Tail 40 -ErrorAction Stop | Out-Host
    } catch {
        Write-Host ("Impossible de lire le journal : {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Invoke-ManualDriverUpdate {
    param([Parameter(Mandatory = $true)][ValidateSet('Scan', 'Install')][string]$Mode)

    if (-not (Test-IsAdministrator)) {
        Write-Host ''
        Write-Host 'Cette opération nécessite des droits administrateur.' -ForegroundColor Yellow
        Write-Host "Fermez cette fenêtre et ouvrez Windows PowerShell avec « Exécuter en tant qu’administrateur »."
        return
    }

    Write-Host ''
    if ($Mode -eq 'Scan') {
        Write-Host '  RECHERCHE DES PILOTES' -ForegroundColor Cyan
        Write-Host "  Windows Update va rechercher les pilotes disponibles sur cet ordinateur."
        Write-Host "  Aucun pilote ne sera téléchargé ni installé." -ForegroundColor Green
    } else {
        Write-Host '  INSTALLATION MANUELLE' -ForegroundColor Cyan
        Write-Host '  1. Recherche des pilotes disponibles'
        Write-Host '  2. Cases à cocher, y compris les pilotes nécessitant une intervention'
        Write-Host "  3. Validation explicite avant installation"
        Write-Host ''
        Write-Host '  Aucune modification avant votre confirmation. Les pilotes sensibles sont signalés.' -ForegroundColor Yellow
    }
    Write-Host ''
    try {
        # Appel local du moteur embarque : aucun script supplementaire.
        $script:UserFacing = $true
        $script:Interactive = ($Mode -eq 'Install')
        $script:ScanOnly = ($Mode -eq 'Scan')
        $script:DryRun = $false
        $script:Force = $true
        $script:ScanAttempted = $false
        $script:ScanSucceeded = $false
        $script:UpdateSource = 'Default'
        $script:DriverResults = New-Object System.Collections.ArrayList
        $resultItems = @(Invoke-StandaloneDriverEngine)
        $code = [int]$resultItems[-1]
        Write-Host ''
        if ($code -eq 3010) {
            Write-Host 'Installation effectuée. Un redémarrage sera nécessaire.' -ForegroundColor Yellow
            Write-Host 'Le programme ne redémarre jamais automatiquement le PC.'
        } elseif ($code -eq 0) {
            Write-Host 'Opération terminée.' -ForegroundColor Green
        } else {
            Write-Host ("L'opération a rencontré un problème (code {0})." -f $code) -ForegroundColor Red
            Write-Host 'Le bilan et le journal ci-dessous peuvent aider à comprendre pourquoi.'
        }
        Show-LastState
    } catch {
        Write-Host ("Impossible de lancer Windows Update : {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Show-MainMenu {
    try { Clear-Host } catch { Write-Host '' }
    Write-Host ''
    Write-Host '  ========================================================' -ForegroundColor DarkCyan
    Write-Host '     DRIVERSUPDATE  |  GESTION DES PILOTES WINDOWS' -ForegroundColor Cyan
    Write-Host '  ========================================================' -ForegroundColor DarkCyan
    Write-Host ("  Ordinateur : {0}" -f $env:COMPUTERNAME)
    if (Test-IsAdministrator) {
        Write-Host '  Autorisations : administrateur' -ForegroundColor DarkGreen
    } else {
        Write-Host '  Autorisations : administrateur requis pour agir' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '  QUE VOULEZ-VOUS FAIRE ?' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  [1] Rechercher les pilotes disponibles' -ForegroundColor White
    Write-Host '      Consulter uniquement, sans rien installer.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [2] Cocher les pilotes à installer' -ForegroundColor White
    Write-Host '      Cases [ ]/[x], validation et avertissements pour les pilotes sensibles.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [3] Afficher le dernier bilan'
    Write-Host '  [4] Consulter le journal technique'
    Write-Host '  [0] Quitter'
    Write-Host ''
}

if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
    throw 'Le menu doit être lancé dans une console Windows interactive, et non par GPO ou entrée redirigée.'
}

while ($true) {
    Show-MainMenu
    $choice = Read-Host '  Votre choix (0 à 4)'
    try {
        switch ($choice.Trim()) {
            '1' { Invoke-ManualDriverUpdate -Mode 'Scan' }
            '2' { Invoke-ManualDriverUpdate -Mode 'Install' }
            '3' { Show-LastState }
            '4' { Show-RecentLog }
            '0' { return }
            default { Write-Host 'Choix non reconnu. Saisissez un chiffre entre 0 et 4.' -ForegroundColor Yellow }
        }
    } catch {
        Write-Host ("Une erreur est survenue : {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    Write-Host ''
    [void](Read-Host 'Appuyez sur Entrée pour revenir au menu')
}
