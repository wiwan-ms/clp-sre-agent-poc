#requires -Version 5.1

<#+
.SYNOPSIS
Collects read-only MSMQ, service, storage, network, and event evidence from a Windows VM.

.DESCRIPTION
Designed for CLP administrators to run locally on each MSMQ VM. The script does not stop
services, read or remove message bodies, modify queues, change registry values, or initiate
connections to downstream systems. It writes only to the selected output directory.

Run first on one AAPP and one SBS VM. After CLP reviews the output and operational impact,
run it on every active MSMQ VM. Run the dynamic capture within the same coordinated window
on all hosts when cross-VM queue and workload comparison is required.

.PARAMETER OutputRoot
Parent directory for the machine-specific result folder.

.PARAMETER EventLookbackDays
Number of days of local Windows events to inspect. The number of exported events is bounded.

.PARAMETER EventStartUtc
Optional exact UTC start of a historical event window. Supply with EventEndUtc. The exact
window may span no more than 31 days and overrides EventLookbackDays.

.PARAMETER EventEndUtc
Optional exact UTC end of a historical event window. Supply with EventStartUtc.

.PARAMETER SampleDurationSeconds
Duration of passive performance-counter capture. Default is 300 seconds.

.PARAMETER SampleIntervalSeconds
Interval between performance-counter samples. Default is 15 seconds.

.PARAMETER SkipPerformanceCapture
Skips the timed performance-counter capture. Useful for the initial safety review.

.PARAMETER ProcessNames
Process counter instance names to capture. Defaults to mqsvc. Supply the known MSMQ consumer
process names after architecture discovery. Wildcard collection across every process is avoided
to bound runtime and operational impact.

.PARAMETER KeepUncompressed
Keeps the uncompressed result directory after creating the ZIP archive.

.PARAMETER StopFilePath
Optional cooperative stop-marker path. The default is STOP-<hostname>.flag under OutputRoot.
Creating this file while the collector runs requests a graceful stop. The collector checks it
between sections and between performance samples, then writes a partial ZIP and result pointer.

.EXAMPLE
.\Collect-CLP-MsmqDiscovery.ps1 -SkipPerformanceCapture

.EXAMPLE
.\Collect-CLP-MsmqDiscovery.ps1 -SampleDurationSeconds 300 -SampleIntervalSeconds 15

.NOTES
Recommended: run from an elevated 64-bit Windows PowerShell 5.1 session.
Review the resulting files for customer-sensitive names and endpoints before sharing them.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot = (Join-Path $env:ProgramData 'CLP\MSMQ-Discovery'),

    [Parameter()]
    [ValidateRange(1, 90)]
    [int]$EventLookbackDays = 30,

    [Parameter()]
    [DateTime]$EventStartUtc,

    [Parameter()]
    [DateTime]$EventEndUtc,

    [Parameter()]
    [ValidateRange(30, 1800)]
    [int]$SampleDurationSeconds = 300,

    [Parameter()]
    [ValidateRange(5, 60)]
    [int]$SampleIntervalSeconds = 15,

    [Parameter()]
    [switch]$SkipPerformanceCapture,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$ProcessNames = @('mqsvc'),

    [Parameter()]
    [switch]$KeepUncompressed,

    [Parameter()]
    [string]$StopFilePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ScriptVersion = '1.2.6'
$script:StartedUtc = [DateTime]::UtcNow
$script:Errors = New-Object System.Collections.Generic.List[object]
$script:SectionResults = New-Object System.Collections.Generic.List[object]
$timestamp = $script:StartedUtc.ToString('yyyyMMddTHHmmssZ')
$computerName = $env:COMPUTERNAME
$resultName = 'CLP-MSMQ-Discovery-{0}-{1}' -f $computerName, $timestamp
$resultDirectory = Join-Path $OutputRoot $resultName
$latestResultPath = Join-Path $OutputRoot ('CLP-MSMQ-Discovery-{0}-latest-result.json' -f $computerName)
if ([string]::IsNullOrWhiteSpace($StopFilePath)) {
    $StopFilePath = Join-Path $OutputRoot ('STOP-{0}.flag' -f $computerName)
}

function Test-StopRequested {
    return Test-Path -LiteralPath $StopFilePath -PathType Leaf
}

function Add-CollectionError {
    param(
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $script:Errors.Add([pscustomobject]@{
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        Section      = $Section
        Error        = $ErrorRecord.Exception.Message
        Category     = [string]$ErrorRecord.CategoryInfo.Category
    })
}

function Invoke-CollectionSection {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    $sectionStarted = [DateTime]::UtcNow
    Write-Host ('[{0}] {1}' -f $sectionStarted.ToString('HH:mm:ss'), $Name)

    if (Test-StopRequested) {
        $script:SectionResults.Add([pscustomobject]@{
            Section         = $Name
            Status          = 'Cancelled'
            StartedUtc      = $sectionStarted.ToString('o')
            DurationSeconds = 0
            Message         = 'Skipped because the cooperative stop marker exists.'
        })
        return
    }

    try {
        & $ScriptBlock
        if (Test-StopRequested) {
            $status = 'Cancelled'
            $message = 'Stopped after the current read-only operation completed.'
        }
        else {
            $status = 'Succeeded'
            $message = $null
        }
    }
    catch {
        $status = 'Failed'
        $message = $_.Exception.Message
        Add-CollectionError -Section $Name -ErrorRecord $_
        Write-Warning ('{0}: {1}' -f $Name, $message)
    }

    $script:SectionResults.Add([pscustomobject]@{
        Section         = $Name
        Status          = $status
        StartedUtc      = $sectionStarted.ToString('o')
        DurationSeconds = [Math]::Round(([DateTime]::UtcNow - $sectionStarted).TotalSeconds, 2)
        Message         = $message
    })
}

function Export-JsonFile {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$InputObject,
        [Parameter(Mandatory = $true)][string]$FileName,
        [int]$Depth = 8
    )

    $path = Join-Path $resultDirectory $FileName
    $items = @($InputObject | ForEach-Object { $_ })
    $items | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $path -Encoding UTF8
}

function Export-CsvFile {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$InputObject,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $path = Join-Path $resultDirectory $FileName
    $items = @($InputObject | ForEach-Object { $_ })
    if ($items.Count -eq 0) {
        Set-Content -LiteralPath $path -Value $null -Encoding UTF8
        return
    }

    $items | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
}

function Protect-SensitiveText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $protected = $Text
    $patterns = @(
        '(?i)(password|pwd|secret|token|accountkey|sharedaccesskey|clientsecret)\s*[=:]\s*[^;\s,]+',
        '(?i)(user\s*id|uid|username)\s*[=:]\s*[^;\s,]+',
        '(?i)(https?://)[^/@\s]+:[^/@\s]+@',
        '(?i)(sig=)[^&\s]+'
    )

    foreach ($pattern in $patterns) {
        $protected = $protected -replace $pattern, '$1=<REDACTED>'
    }

    return $protected
}

function Convert-ServicePathToExecutable {
    param([AllowNull()][string]$PathName)

    if ([string]::IsNullOrWhiteSpace($PathName)) {
        return $null
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($PathName.Trim())
    if ($expanded -match '^"([^"]+)"') {
        return $Matches[1]
    }

    if ($expanded -match '^(.+?\.exe)(?:\s|$)') {
        return $Matches[1]
    }

    return $null
}

function Get-SafeEndpointValue {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $candidate = Protect-SensitiveText -Text $Value
    if ($candidate -match '^(?i)https?://') {
        try {
            $uri = [Uri]$candidate
            return '{0}://{1}{2}' -f $uri.Scheme, $uri.Authority, $uri.AbsolutePath
        }
        catch {
            return $candidate
        }
    }

    return $candidate
}

function Get-ApplicationEndpointHints {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ConfigurationFiles)

    $endpointHints = New-Object System.Collections.Generic.List[object]
    foreach ($configurationFile in ($ConfigurationFiles | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $configurationFile -PathType Leaf)) {
            continue
        }

        try {
            [xml]$configuration = Get-Content -LiteralPath $configurationFile -Raw

            foreach ($entry in @($configuration.SelectNodes('/configuration/connectionStrings/add'))) {
                if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.connectionString)) {
                    continue
                }

                $safeParts = New-Object System.Collections.Generic.List[string]
                foreach ($part in ([string]$entry.connectionString -split ';')) {
                    if ($part -notmatch '=') {
                        continue
                    }

                    $pair = $part -split '=', 2
                    $key = $pair[0].Trim()
                    $value = $pair[1].Trim()
                    if ($key -match '^(?i)(server|data source|address|addr|network address|initial catalog|database|host|port)$') {
                        $safeParts.Add(('{0}={1}' -f $key, (Get-SafeEndpointValue -Value $value)))
                    }
                }

                if ($safeParts.Count -gt 0) {
                    $endpointHints.Add([pscustomobject]@{
                        SourceFile = $configurationFile
                        Type       = 'ConnectionStringEndpoint'
                        Name       = [string]$entry.name
                        Value      = $safeParts -join ';'
                    })
                }
            }

            foreach ($entry in @($configuration.SelectNodes('/configuration/appSettings/add'))) {
                if ($null -eq $entry) {
                    continue
                }

                $key = [string]$entry.key
                $value = [string]$entry.value
                if ($key -match '(?i)password|pwd|secret|token|key|credential') {
                    continue
                }

                $isEndpointKey = $key -match '(?i)endpoint|address|destination|host|server|queue|format.?name|uri|url|vip|port'
                $isEndpointValue = $value -match '^(?i)(https?://|net\.(msmq|tcp)://|msmq\.formatname:|formatname:|direct=|\\\\|[a-z0-9][a-z0-9.-]+\.[a-z]{2,}|(?:\d{1,3}\.){3}\d{1,3})(.*)$'
                if (-not $isEndpointKey -and -not $isEndpointValue) {
                    continue
                }

                $endpointHints.Add([pscustomobject]@{
                    SourceFile = $configurationFile
                    Type       = 'AppSettingEndpoint'
                    Name       = $key
                    Value      = Get-SafeEndpointValue -Value $value
                })
            }

            foreach ($entry in @($configuration.SelectNodes('/configuration/system.serviceModel/client/endpoint'))) {
                if ($null -eq $entry) {
                    continue
                }

                $address = [string]$entry.GetAttribute('address')
                if ([string]::IsNullOrWhiteSpace($address)) {
                    continue
                }

                $endpointHints.Add([pscustomobject]@{
                    SourceFile = $configurationFile
                    Type       = 'WcfClientEndpoint'
                    Name       = [string]$entry.GetAttribute('name')
                    Value      = Get-SafeEndpointValue -Value $address
                })
            }

            foreach ($entry in @($configuration.SelectNodes('/configuration/system.serviceModel/services/service/endpoint'))) {
                if ($null -eq $entry) {
                    continue
                }

                $endpointHints.Add([pscustomobject]@{
                    SourceFile = $configurationFile
                    Type       = 'WcfServiceEndpoint'
                    Name       = [string]$entry.GetAttribute('name')
                    Value      = Get-SafeEndpointValue -Value ([string]$entry.GetAttribute('address'))
                })
            }

            foreach ($entry in @($configuration.SelectNodes('/configuration/system.serviceModel/services/service/host/baseAddresses/add'))) {
                if ($null -eq $entry) {
                    continue
                }

                $baseAddress = [string]$entry.GetAttribute('baseAddress')
                if ([string]::IsNullOrWhiteSpace($baseAddress)) {
                    continue
                }

                $endpointHints.Add([pscustomobject]@{
                    SourceFile = $configurationFile
                    Type       = 'WcfServiceBaseAddress'
                    Name       = $null
                    Value      = Get-SafeEndpointValue -Value $baseAddress
                })
            }
        }
        catch {
            Add-CollectionError -Section ('Parse config: {0}' -f $configurationFile) -ErrorRecord $_
        }
    }

    return $endpointHints
}

function Get-MsmqRegistryConfiguration {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\MSMQ',
        'HKLM:\SOFTWARE\Microsoft\MSMQ\Parameters'
    )
    $allowedNames = @(
        'MachineQuota', 'MachineJournalQuota', 'DefaultOutgoingQueueQuota',
        'StoreReliableLogPath', 'StoreLogPath', 'StoreJournalPath',
        'StoreDeadLetterPath', 'StorePersistentPath', 'BasePriority',
        'LogDataCreated', 'Workgroup', 'AlwaysWithoutDS', 'IgnoreOSNameValidation'
    )
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        $properties = Get-ItemProperty -LiteralPath $path
        $propertyNames = @($properties.PSObject.Properties | Select-Object -ExpandProperty Name)
        foreach ($name in $allowedNames) {
            if ($propertyNames -contains $name) {
                $items.Add([pscustomobject]@{
                    RegistryPath = $path
                    Name         = $name
                    Value        = [string]$properties.$name
                })
            }
        }
    }

    return $items
}

function Get-EventRecords {
    param(
        [Parameter(Mandatory = $true)][string]$LogName,
        [Parameter(Mandatory = $true)][DateTime]$StartTime,
        [Parameter(Mandatory = $true)][DateTime]$EndTime,
        [int]$MaxEvents = 1000,
        [switch]$MsmqOnly
    )

    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = $LogName; StartTime = $StartTime; EndTime = $EndTime } -MaxEvents $MaxEvents -ErrorAction Stop
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
            return @()
        }
        throw
    }
    if ($MsmqOnly) {
        $events = $events | Where-Object {
            $_.ProviderName -match '(?i)MSMQ|Message.?Queu' -or $_.Message -match '(?i)MSMQ|Message Queuing'
        } | Select-Object -First 500
    }

    return $events | ForEach-Object {
        [pscustomobject]@{
            TimeCreated  = $_.TimeCreated.ToUniversalTime().ToString('o')
            LogName      = $_.LogName
            ProviderName = $_.ProviderName
            Id           = $_.Id
            Level        = $_.LevelDisplayName
            Message      = Protect-SensitiveText -Text $_.Message
        }
    }
}

function Get-PerformanceCounterPaths {
    $paths = New-Object System.Collections.Generic.List[string]
    $activeQueueNames = @()
    if (Get-Command Get-MsmqQueue -ErrorAction SilentlyContinue) {
        $activeQueueNames = @(Get-MsmqQueue -QueueType Private -ErrorAction SilentlyContinue |
            Where-Object { $_.MessageCount -gt 0 } |
            ForEach-Object { ([string]$_.QueueName).ToLowerInvariant() })
    }
    $fixedPaths = @(
        '\Processor(_Total)\% Processor Time',
        '\Memory\Available MBytes',
        '\Memory\Pages/sec',
        '\LogicalDisk(*)\% Free Space',
        '\LogicalDisk(*)\Avg. Disk sec/Read',
        '\LogicalDisk(*)\Avg. Disk sec/Write',
        '\LogicalDisk(*)\Current Disk Queue Length',
        '\LogicalDisk(*)\Disk Transfers/sec',
        '\LogicalDisk(*)\Disk Bytes/sec'
    )

    foreach ($path in $fixedPaths) {
        $paths.Add($path)
    }

    foreach ($processName in $ProcessNames) {
        $safeProcessName = $processName -replace '[^a-zA-Z0-9_.-]', ''
        if ([string]::IsNullOrWhiteSpace($safeProcessName)) {
            continue
        }
        $paths.Add(('\Process({0}*)\% Processor Time' -f $safeProcessName))
        $paths.Add(('\Process({0}*)\Thread Count' -f $safeProcessName))
        $paths.Add(('\Process({0}*)\IO Data Bytes/sec' -f $safeProcessName))
    }

    $msmqSets = Get-Counter -ListSet '*MSMQ*' -ErrorAction SilentlyContinue
    foreach ($counterSet in @($msmqSets)) {
        foreach ($path in @($counterSet.PathsWithInstances)) {
            if ($path -match '\(\*\)' -or
                $path -notmatch '(?i)Messages in Queue|Bytes in Queue|Messages/sec|Incoming Messages/sec|Outgoing Messages/sec|Journal') {
                continue
            }

            if ($path -match '(?i)\\MSMQ Queue\(([^)]+)\)') {
                $instanceName = $Matches[1].ToLowerInvariant()
                if ($instanceName -ne 'computer queues' -and
                    -not ($activeQueueNames | Where-Object { $instanceName.EndsWith($_) })) {
                    continue
                }
            }

            $paths.Add($path)
        }
    }

    return $paths | Sort-Object -Unique
}

New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
if (Test-Path -LiteralPath $StopFilePath) {
    Remove-Item -LiteralPath $StopFilePath -Force
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ('CLP MSMQ discovery collector {0}' -f $script:ScriptVersion)
Write-Host ('Computer: {0}' -f $computerName)
Write-Host ('Output:   {0}' -f $resultDirectory)
Write-Host ('Elevated: {0}' -f $isAdministrator)
if (-not $isAdministrator) {
    Write-Warning 'The script is not elevated. It will continue, but protected MSMQ, process, event, and Defender data may be incomplete.'
}

$hasEventStart = $PSBoundParameters.ContainsKey('EventStartUtc')
$hasEventEnd = $PSBoundParameters.ContainsKey('EventEndUtc')
if ($hasEventStart -xor $hasEventEnd) {
    throw 'EventStartUtc and EventEndUtc must be supplied together.'
}
if ($hasEventStart) {
    $eventStartTime = $EventStartUtc.ToUniversalTime()
    $eventEndTime = $EventEndUtc.ToUniversalTime()
    if ($eventEndTime -le $eventStartTime) {
        throw 'EventEndUtc must be later than EventStartUtc.'
    }
    if (($eventEndTime - $eventStartTime).TotalDays -gt 31) {
        throw 'The exact event window cannot exceed 31 days.'
    }
}
else {
    $eventEndTime = [DateTime]::UtcNow
    $eventStartTime = $eventEndTime.AddDays(-$EventLookbackDays)
}

Invoke-CollectionSection -Name 'Host inventory' -ScriptBlock {
    $hostInventory = [pscustomobject]@{
        ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem |
            Select-Object Name, Domain, Manufacturer, Model, TotalPhysicalMemory, NumberOfLogicalProcessors
        OperatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem |
            Select-Object Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime, LocalDateTime
        Bios = Get-CimInstance -ClassName Win32_BIOS |
            Select-Object Manufacturer, SMBIOSBIOSVersion, ReleaseDate, SerialNumber
        TimeZone = Get-TimeZone | Select-Object Id, DisplayName, BaseUtcOffset
    }
    Export-JsonFile -InputObject $hostInventory -FileName 'host-inventory.json'
}

Invoke-CollectionSection -Name 'Windows features and agents' -ScriptBlock {
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $features = Get-WindowsFeature | Where-Object { $_.Name -match 'MSMQ|NET-Framework|WAS|Web-' } |
            Select-Object Name, DisplayName, InstallState
        Export-CsvFile -InputObject $features -FileName 'windows-features.csv'
    }

    $products = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.PSObject.Properties['DisplayName'].Value } |
        Select-Object @{ Name = 'DisplayName'; Expression = { $_.PSObject.Properties['DisplayName'].Value } },
            @{ Name = 'DisplayVersion'; Expression = { $_.PSObject.Properties['DisplayVersion'].Value } },
            @{ Name = 'Publisher'; Expression = { $_.PSObject.Properties['Publisher'].Value } },
            @{ Name = 'InstallDate'; Expression = { $_.PSObject.Properties['InstallDate'].Value } } |
        Sort-Object DisplayName, DisplayVersion -Unique
    Export-CsvFile -InputObject $products -FileName 'installed-software.csv'

    $extensionStatus = New-Object System.Collections.Generic.List[object]
    $pluginRoot = Join-Path $env:SystemDrive 'Packages\Plugins'
    if (Test-Path -LiteralPath $pluginRoot -PathType Container) {
        foreach ($statusFile in @(Get-ChildItem -LiteralPath $pluginRoot -Recurse -File -Filter '*.status' -ErrorAction SilentlyContinue)) {
            try {
                $relativePath = $statusFile.FullName.Substring($pluginRoot.Length).TrimStart('\')
                $pathParts = $relativePath -split '\\'
                $statusDocument = Get-Content -LiteralPath $statusFile.FullName -Raw | ConvertFrom-Json
                foreach ($status in @($statusDocument.status)) {
                    $messages = @($status.formattedMessage | ForEach-Object {
                        Protect-SensitiveText -Text ([string]$_.message)
                    })
                    $extensionStatus.Add([pscustomobject]@{
                        ExtensionName = if ($pathParts.Count -gt 0) { $pathParts[0] } else { $null }
                        Version       = if ($pathParts.Count -gt 1) { $pathParts[1] } else { $null }
                        StatusFile    = $statusFile.FullName
                        TimestampUtc  = [string]$status.timestampUTC
                        Operation     = [string]$status.operation
                        Status        = [string]$status.status
                        Code          = [string]$status.code
                        Message       = $messages -join ' | '
                    })
                }
            }
            catch {
                Add-CollectionError -Section ('Azure extension status: {0}' -f $statusFile.FullName) -ErrorRecord $_
            }
        }
    }
    Export-CsvFile -InputObject $extensionStatus -FileName 'azure-extension-status.csv'
}

Invoke-CollectionSection -Name 'MSMQ configuration' -ScriptBlock {
    $msmqServices = @(Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'MSMQ%'" |
        Select-Object Name, DisplayName, State, StartMode, StartName, ProcessId, PathName, ExitCode)
    Export-CsvFile -InputObject $msmqServices -FileName 'msmq-services.csv'
    $msmqRegistry = @(Get-MsmqRegistryConfiguration)
    Export-CsvFile -InputObject $msmqRegistry -FileName 'msmq-registry.csv'

    if (Get-Command Get-MsmqQueue -ErrorAction SilentlyContinue) {
        $queues = @(Get-MsmqQueue -ErrorAction Stop | Select-Object QueueName, PathName, FormatName,
            MessageCount, Transactional, UseJournalQueue, QueueQuota, JournalQuota, Label, MulticastAddress)
        Export-CsvFile -InputObject $queues -FileName 'msmq-queues.csv'
    }
    else {
        Set-Content -LiteralPath (Join-Path $resultDirectory 'msmq-queues-unavailable.txt') -Encoding UTF8 -Value @(
            'The Get-MsmqQueue cmdlet was not available in this PowerShell session.'
            'Queue inventory may still appear in the MSMQ performance snapshot.'
        )
    }

    if (Get-Command Get-MsmqOutgoingQueue -ErrorAction SilentlyContinue) {
        $outgoingQueues = @(Get-MsmqOutgoingQueue -ErrorAction Stop |
            Select-Object DestinationQueueFormatName, State, MessageCount, NextHops, LastError)
        Export-CsvFile -InputObject $outgoingQueues -FileName 'msmq-outgoing-queues.csv'
    }

    $msmqPerformanceClasses = @(
        'Win32_PerfFormattedData_msmq_MSMQQueue',
        'Win32_PerfFormattedData_msmq_MSMQService',
        'Win32_PerfFormattedData_msmq_MSMQOutgoingQueue'
    )
    foreach ($className in $msmqPerformanceClasses) {
        if (-not (Get-CimClass -ClassName $className -ErrorAction SilentlyContinue)) {
            continue
        }
        try {
            $data = Get-CimInstance -ClassName $className -ErrorAction Stop
            Export-JsonFile -InputObject $data -FileName ('{0}.json' -f $className) -Depth 5
        }
        catch {
            Add-CollectionError -Section ('MSMQ performance class: {0}' -f $className) -ErrorRecord $_
        }
    }
}

Invoke-CollectionSection -Name 'Storage inventory' -ScriptBlock {
    $volumes = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' |
        Select-Object DeviceID, VolumeName, FileSystem, Size, FreeSpace,
            @{ Name = 'PercentFree'; Expression = { if ($_.Size) { [Math]::Round(($_.FreeSpace / $_.Size) * 100, 2) } } }
    Export-CsvFile -InputObject $volumes -FileName 'volumes.csv'

    $physicalDisks = Get-CimInstance -ClassName Win32_DiskDrive |
        Select-Object Index, Model, InterfaceType, MediaType, Size, Status
    Export-CsvFile -InputObject $physicalDisks -FileName 'physical-disks.csv'
}

Invoke-CollectionSection -Name 'Services, processes, and application endpoint hints' -ScriptBlock {
    $services = Get-CimInstance -ClassName Win32_Service | Select-Object Name, DisplayName, State,
        StartMode, StartName, ProcessId, PathName, ExitCode
    Export-CsvFile -InputObject $services -FileName 'services.csv'

    $processes = Get-CimInstance -ClassName Win32_Process | ForEach-Object {
        [pscustomobject]@{
            ProcessId      = $_.ProcessId
            ParentProcessId = $_.ParentProcessId
            Name           = $_.Name
            ExecutablePath = $_.ExecutablePath
            ThreadCount    = $_.ThreadCount
            WorkingSetSize = $_.WorkingSetSize
            CreationDate   = $_.CreationDate
        }
    }
    Export-CsvFile -InputObject $processes -FileName 'processes.csv'

    $configurationFiles = New-Object System.Collections.Generic.List[string]
    foreach ($service in $services) {
        $executable = Convert-ServicePathToExecutable -PathName $service.PathName
        if ($executable -and (Test-Path -LiteralPath $executable -PathType Leaf)) {
            $candidate = '{0}.config' -f $executable
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $configurationFiles.Add($candidate)
            }
        }
    }

    $configInventory = foreach ($configurationFile in ($configurationFiles | Sort-Object -Unique)) {
        $item = Get-Item -LiteralPath $configurationFile
        [pscustomobject]@{
            Path             = $item.FullName
            Length           = $item.Length
            LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
            SHA256           = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        }
    }
    Export-CsvFile -InputObject $configInventory -FileName 'application-config-inventory.csv'
    $endpointHints = @(Get-ApplicationEndpointHints -ConfigurationFiles @($configurationFiles))
    Export-CsvFile -InputObject $endpointHints -FileName 'application-endpoint-hints.csv'

    $serviceBinaryRows = New-Object System.Collections.Generic.List[object]
    $serviceExecutables = foreach ($service in $services) {
        $executable = Convert-ServicePathToExecutable -PathName $service.PathName
        if ($executable -and (Test-Path -LiteralPath $executable -PathType Leaf)) {
            [pscustomobject]@{
                ServiceName   = $service.Name
                ExecutablePath = $executable
            }
        }
    }
    foreach ($group in @($serviceExecutables | Group-Object ExecutablePath)) {
        try {
            $item = Get-Item -LiteralPath $group.Name
            $serviceBinaryRows.Add([pscustomobject]@{
                ExecutablePath   = $item.FullName
                ServiceNames     = (@($group.Group.ServiceName | Sort-Object -Unique) -join ',')
                Length           = $item.Length
                LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
                FileVersion      = $item.VersionInfo.FileVersion
                ProductVersion   = $item.VersionInfo.ProductVersion
                SHA256           = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            })
        }
        catch {
            Add-CollectionError -Section ('Service binary: {0}' -f $group.Name) -ErrorRecord $_
        }
    }
    Export-CsvFile -InputObject $serviceBinaryRows -FileName 'service-binary-inventory.csv'

    $scheduledTaskRows = New-Object System.Collections.Generic.List[object]
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $scheduledTasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
            $_.TaskPath -notlike '\Microsoft\*' -or
            $_.TaskName -match '(?i)MSMQ|Message|Queue' -or
            (@($_.Actions.Execute) -join ' ') -match '(?i)MSMQ|Message|Queue'
        })
        foreach ($task in $scheduledTasks) {
            $taskInfo = $null
            try {
                $taskInfo = Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop
            }
            catch {
                Add-CollectionError -Section ('Scheduled task status: {0}{1}' -f $task.TaskPath, $task.TaskName) -ErrorRecord $_
            }
            foreach ($action in @($task.Actions)) {
                $scheduledTaskRows.Add([pscustomobject]@{
                    TaskPath         = $task.TaskPath
                    TaskName         = $task.TaskName
                    State            = [string]$task.State
                    Author           = [string]$task.Author
                    UserId           = [string]$task.Principal.UserId
                    RunLevel         = [string]$task.Principal.RunLevel
                    Execute          = [string]$action.Execute
                    Arguments        = Protect-SensitiveText -Text ([string]$action.Arguments)
                    WorkingDirectory = [string]$action.WorkingDirectory
                    TriggerTypes     = (@($task.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ',')
                    LastRunTimeUtc   = if ($taskInfo -and $taskInfo.LastRunTime) { $taskInfo.LastRunTime.ToUniversalTime().ToString('o') } else { $null }
                    LastTaskResult   = if ($taskInfo) { $taskInfo.LastTaskResult } else { $null }
                    NextRunTimeUtc   = if ($taskInfo -and $taskInfo.NextRunTime) { $taskInfo.NextRunTime.ToUniversalTime().ToString('o') } else { $null }
                })
            }
        }
    }
    Export-CsvFile -InputObject $scheduledTaskRows -FileName 'scheduled-tasks.csv'
}

Invoke-CollectionSection -Name 'Passive network snapshot' -ScriptBlock {
    $adapters = Get-NetIPConfiguration | Select-Object InterfaceAlias, InterfaceDescription,
        @{ Name = 'IPv4Address'; Expression = { ($_.IPv4Address.IPAddress -join ',') } },
        @{ Name = 'IPv6Address'; Expression = { ($_.IPv6Address.IPAddress -join ',') } },
        @{ Name = 'IPv4DefaultGateway'; Expression = { ($_.IPv4DefaultGateway.NextHop -join ',') } },
        @{ Name = 'DNSServer'; Expression = { ($_.DNSServer.ServerAddresses -join ',') } }
    Export-CsvFile -InputObject $adapters -FileName 'network-adapters.csv'

    $processById = @{}
    Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
        $processById[[int]$_.ProcessId] = $_
    }
    $serviceNamesByProcessId = @{}
    Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -gt 0 } |
        Group-Object ProcessId | ForEach-Object {
            $serviceNamesByProcessId[[int]$_.Name] = (@($_.Group.Name | Sort-Object -Unique) -join ',')
        }
    $connections = Get-NetTCPConnection -ErrorAction Stop | Where-Object { $_.State -in @('Established', 'Listen') } |
        ForEach-Object {
            $owner = $processById[[int]$_.OwningProcess]
            [pscustomobject]@{
                State         = $_.State
                LocalAddress  = $_.LocalAddress
                LocalPort     = $_.LocalPort
                RemoteAddress = $_.RemoteAddress
                RemotePort    = $_.RemotePort
                OwningProcess = $_.OwningProcess
                ProcessName   = if ($owner) { $owner.Name } else { $null }
                ExecutablePath = if ($owner) { $owner.ExecutablePath } else { $null }
                ServiceNames  = $serviceNamesByProcessId[[int]$_.OwningProcess]
            }
        }
    Export-CsvFile -InputObject $connections -FileName 'tcp-connections.csv'
    Export-CsvFile -InputObject @($connections | Where-Object { $_.State -eq 'Listen' }) -FileName 'listener-owners.csv'

    $udpEndpoints = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | ForEach-Object {
        $owner = $processById[[int]$_.OwningProcess]
        [pscustomobject]@{
            LocalAddress   = $_.LocalAddress
            LocalPort      = $_.LocalPort
            OwningProcess  = $_.OwningProcess
            ProcessName    = if ($owner) { $owner.Name } else { $null }
            ExecutablePath = if ($owner) { $owner.ExecutablePath } else { $null }
            ServiceNames   = $serviceNamesByProcessId[[int]$_.OwningProcess]
        }
    })
    Export-CsvFile -InputObject $udpEndpoints -FileName 'udp-endpoints.csv'

    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $hostsEntries = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $hostsPath -PathType Leaf) {
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $hostsPath) {
            $lineNumber++
            $content = ($line -split '#', 2)[0].Trim()
            if ([string]::IsNullOrWhiteSpace($content)) {
                continue
            }
            $parts = @($content -split '\s+' | Where-Object { $_ })
            if ($parts.Count -lt 2) {
                continue
            }
            $hostsEntries.Add([pscustomobject]@{
                LineNumber = $lineNumber
                Address    = $parts[0]
                HostNames  = (@($parts[1..($parts.Count - 1)]) -join ',')
            })
        }
    }
    Export-CsvFile -InputObject $hostsEntries -FileName 'hosts-file-overrides.csv'

    $dnsCache = @(Get-DnsClientCache -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -in @(1, 5, 12, 28) } |
        Select-Object Entry, Name, Data, Type, TimeToLive, Status)
    Export-CsvFile -InputObject $dnsCache -FileName 'dns-client-cache.csv'

    $routes = Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop |
        Select-Object DestinationPrefix, NextHop, RouteMetric, InterfaceAlias, Protocol, State
    Export-CsvFile -InputObject $routes -FileName 'ipv4-routes.csv'

    $ipv6Routes = Get-NetRoute -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Select-Object DestinationPrefix, NextHop, RouteMetric, InterfaceAlias, Protocol, State
    Export-CsvFile -InputObject $ipv6Routes -FileName 'ipv6-routes.csv'

    $firewallRules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayGroup -match '(?i)Message Queuing|MSMQ' -or $_.DisplayName -match '(?i)Message Queuing|MSMQ' } |
        Select-Object DisplayName, DisplayGroup, Enabled, Profile, Direction, Action)
    Export-CsvFile -InputObject $firewallRules -FileName 'msmq-firewall-rules.csv'

    $firewallRuleObjects = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayGroup -match '(?i)Message Queuing|MSMQ' -or $_.DisplayName -match '(?i)Message Queuing|MSMQ' })
    $firewallPortFilters = foreach ($rule in $firewallRuleObjects) {
        foreach ($filter in @(Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue)) {
            [pscustomobject]@{
                RuleName  = $rule.Name
                DisplayName = $rule.DisplayName
                Protocol  = $filter.Protocol
                LocalPort = $filter.LocalPort
                RemotePort = $filter.RemotePort
                IcmpType  = $filter.IcmpType
            }
        }
    }
    Export-CsvFile -InputObject $firewallPortFilters -FileName 'msmq-firewall-port-filters.csv'

    $firewallAddressFilters = foreach ($rule in $firewallRuleObjects) {
        foreach ($filter in @(Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue)) {
            [pscustomobject]@{
                RuleName      = $rule.Name
                DisplayName   = $rule.DisplayName
                LocalAddress  = $filter.LocalAddress
                RemoteAddress = $filter.RemoteAddress
            }
        }
    }
    Export-CsvFile -InputObject $firewallAddressFilters -FileName 'msmq-firewall-address-filters.csv'
}

Invoke-CollectionSection -Name 'IIS and HTTP.sys listener configuration' -ScriptBlock {
    if (Get-Module -ListAvailable -Name WebAdministration) {
        Import-Module WebAdministration -ErrorAction Stop
        $websites = @(Get-Website | Select-Object Name, Id, State, PhysicalPath, ApplicationPool,
            @{ Name = 'Bindings'; Expression = {
                (@($_.Bindings.Collection | ForEach-Object {
                    '{0}:{1}' -f $_.Protocol, $_.BindingInformation
                }) -join ',')
            } })
        Export-CsvFile -InputObject $websites -FileName 'iis-websites.csv'

        $webBindings = @(Get-WebBinding | Select-Object protocol, bindingInformation, sslFlags,
            certificateHash, certificateStoreName, ItemXPath)
        Export-CsvFile -InputObject $webBindings -FileName 'iis-bindings.csv'

        $webApplications = @(Get-WebApplication |
            Select-Object Path, ApplicationPool, PhysicalPath, ItemXPath)
        Export-CsvFile -InputObject $webApplications -FileName 'iis-applications.csv'

        $iisRoots = New-Object System.Collections.Generic.List[string]
        foreach ($physicalPath in @($websites.PhysicalPath) + @($webApplications.PhysicalPath)) {
            if ([string]::IsNullOrWhiteSpace([string]$physicalPath)) {
                continue
            }
            $expandedPath = [Environment]::ExpandEnvironmentVariables([string]$physicalPath)
            if (Test-Path -LiteralPath $expandedPath -PathType Container) {
                $iisRoots.Add($expandedPath)
            }
        }

        $iisConfigFiles = New-Object System.Collections.Generic.List[string]
        foreach ($iisRoot in @($iisRoots | Sort-Object -Unique)) {
            $webConfig = Join-Path $iisRoot 'web.config'
            if (Test-Path -LiteralPath $webConfig -PathType Leaf) {
                $iisConfigFiles.Add($webConfig)
            }
        }
        $iisConfigInventory = foreach ($configurationFile in @($iisConfigFiles | Sort-Object -Unique)) {
            $item = Get-Item -LiteralPath $configurationFile
            [pscustomobject]@{
                Path             = $item.FullName
                Length           = $item.Length
                LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
                SHA256           = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            }
        }
        Export-CsvFile -InputObject $iisConfigInventory -FileName 'iis-config-inventory.csv'
        $iisEndpointHints = @(Get-ApplicationEndpointHints -ConfigurationFiles @($iisConfigFiles))
        Export-CsvFile -InputObject $iisEndpointHints -FileName 'iis-application-endpoint-hints.csv'

        $iisServiceFiles = foreach ($iisRoot in @($iisRoots | Sort-Object -Unique)) {
            Get-ChildItem -LiteralPath $iisRoot -Recurse -File -Filter '*.svc' -ErrorAction SilentlyContinue |
                Select-Object -First 500 | ForEach-Object {
                    [pscustomobject]@{
                        SiteRoot         = $iisRoot
                        Path             = $_.FullName
                        Length           = $_.Length
                        LastWriteTimeUtc = $_.LastWriteTimeUtc.ToString('o')
                        SHA256           = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                    }
                }
        }
        Export-CsvFile -InputObject $iisServiceFiles -FileName 'iis-service-files.csv'
    }
    else {
        Set-Content -LiteralPath (Join-Path $resultDirectory 'iis-unavailable.txt') -Encoding UTF8 -Value @(
            'The WebAdministration module is not installed or available.'
            'HTTP.sys registrations are still collected below when netsh is available.'
        )
    }

    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    if (Test-Path -LiteralPath $netsh -PathType Leaf) {
        @(& $netsh http show servicestate view=requestq verbose=no 2>&1) |
            ForEach-Object { Protect-SensitiveText -Text ([string]$_) } |
            Set-Content -LiteralPath (Join-Path $resultDirectory 'http-sys-service-state.txt') -Encoding UTF8
        @(& $netsh http show urlacl 2>&1) |
            ForEach-Object { Protect-SensitiveText -Text ([string]$_) } |
            Set-Content -LiteralPath (Join-Path $resultDirectory 'http-sys-urlacl.txt') -Encoding UTF8
        @(& $netsh http show sslcert 2>&1) |
            ForEach-Object { Protect-SensitiveText -Text ([string]$_) } |
            Set-Content -LiteralPath (Join-Path $resultDirectory 'http-sys-sslcert.txt') -Encoding UTF8
    }
}

Invoke-CollectionSection -Name 'MSDTC configuration' -ScriptBlock {
    $dtcServices = Get-CimInstance -ClassName Win32_Service |
        Where-Object { $_.Name -eq 'MSDTC' -or $_.Name -like 'MSDTC$*' } |
        Select-Object Name, DisplayName, State, StartMode, StartName, ProcessId, PathName
    Export-CsvFile -InputObject $dtcServices -FileName 'msdtc-services.csv'

    if (Get-Command Get-Dtc -ErrorAction SilentlyContinue) {
        Export-JsonFile -InputObject (Get-Dtc) -FileName 'msdtc-instances.json' -Depth 5
    }
    if (Get-Command Get-DtcNetworkSetting -ErrorAction SilentlyContinue) {
        Export-JsonFile -InputObject (Get-DtcNetworkSetting -DtcName Local) -FileName 'msdtc-network-settings.json' -Depth 5
    }
}

Invoke-CollectionSection -Name 'Defender exclusions' -ScriptBlock {
    if (Get-Command Get-MpPreference -ErrorAction SilentlyContinue) {
        $preference = Get-MpPreference
        $defender = [pscustomobject]@{
            DisableRealtimeMonitoring = $preference.DisableRealtimeMonitoring
            ExclusionPath             = @($preference.ExclusionPath)
            ExclusionProcess          = @($preference.ExclusionProcess)
            ExclusionExtension        = @($preference.ExclusionExtension)
        }
        Export-JsonFile -InputObject $defender -FileName 'defender-exclusions.json' -Depth 4
    }
    else {
        Set-Content -LiteralPath (Join-Path $resultDirectory 'defender-unavailable.txt') -Encoding UTF8 -Value @(
            'Microsoft Defender cmdlets were not available.'
            'If another EDR product is authoritative, CLP should provide its MSMQ exclusion policy separately.'
        )
    }
}

Invoke-CollectionSection -Name 'Bounded event-log collection' -ScriptBlock {
    $systemEvents = @(Get-EventRecords -LogName 'System' -StartTime $eventStartTime -EndTime $eventEndTime -MsmqOnly)
    $applicationEvents = @(Get-EventRecords -LogName 'Application' -StartTime $eventStartTime -EndTime $eventEndTime -MsmqOnly)
    Export-CsvFile -InputObject $systemEvents -FileName 'events-system-msmq.csv'
    Export-CsvFile -InputObject $applicationEvents -FileName 'events-application-msmq.csv'

    $msmqLogs = Get-WinEvent -ListLog '*MSMQ*' -ErrorAction SilentlyContinue |
        Where-Object { $_.IsEnabled -and $_.RecordCount -gt 0 } |
        Select-Object -ExpandProperty LogName
    foreach ($logName in $msmqLogs) {
        try {
            $safeName = $logName -replace '[^a-zA-Z0-9._-]', '_'
            $logEvents = @(Get-EventRecords -LogName $logName -StartTime $eventStartTime -EndTime $eventEndTime -MaxEvents 500)
            Export-CsvFile -InputObject $logEvents -FileName ('events-{0}.csv' -f $safeName)
        }
        catch {
            Add-CollectionError -Section ('Event log: {0}' -f $logName) -ErrorRecord $_
        }
    }
}

if (-not $SkipPerformanceCapture) {
    Invoke-CollectionSection -Name 'Passive performance-counter capture' -ScriptBlock {
        $counterPaths = @(Get-PerformanceCounterPaths)
        Set-Content -LiteralPath (Join-Path $resultDirectory 'performance-counter-paths.txt') -Value $counterPaths -Encoding UTF8

        $maxSamples = [Math]::Max(1, [Math]::Ceiling($SampleDurationSeconds / $SampleIntervalSeconds))
        $counterRows = New-Object System.Collections.Generic.List[object]
        $activeCounterPaths = New-Object System.Collections.Generic.List[string]

        try {
            $counterData = Get-Counter -Counter $counterPaths -MaxSamples 1
            foreach ($counterPath in $counterPaths) {
                $activeCounterPaths.Add($counterPath)
            }
            foreach ($sample in $counterData.CounterSamples) {
                $counterRows.Add([pscustomobject]@{
                    TimestampUtc = $sample.Timestamp.ToUniversalTime().ToString('o')
                    Path         = $sample.Path
                    InstanceName = $sample.InstanceName
                    CookedValue  = $sample.CookedValue
                    Status       = $sample.Status
                })
            }
        }
        catch {
            Add-CollectionError -Section 'Performance counter batch preflight' -ErrorRecord $_
            foreach ($counterPath in $counterPaths) {
                if (Test-StopRequested) {
                    break
                }
                try {
                    $counterData = Get-Counter -Counter $counterPath -MaxSamples 1
                    $activeCounterPaths.Add($counterPath)
                    foreach ($sample in $counterData.CounterSamples) {
                        $counterRows.Add([pscustomobject]@{
                            TimestampUtc = $sample.Timestamp.ToUniversalTime().ToString('o')
                            Path         = $sample.Path
                            InstanceName = $sample.InstanceName
                            CookedValue  = $sample.CookedValue
                            Status       = $sample.Status
                        })
                    }
                }
                catch {
                    Add-CollectionError -Section ('Performance counter: {0}' -f $counterPath) -ErrorRecord $_
                }
            }
        }

        for ($sampleIndex = 1; $sampleIndex -lt $maxSamples; $sampleIndex++) {
            if (Test-StopRequested) {
                break
            }

            Start-Sleep -Seconds $SampleIntervalSeconds
            try {
                $counterData = Get-Counter -Counter $activeCounterPaths -MaxSamples 1
                foreach ($sample in $counterData.CounterSamples) {
                    $counterRows.Add([pscustomobject]@{
                        TimestampUtc = $sample.Timestamp.ToUniversalTime().ToString('o')
                        Path         = $sample.Path
                        InstanceName = $sample.InstanceName
                        CookedValue  = $sample.CookedValue
                        Status       = $sample.Status
                    })
                }
            }
            catch {
                Add-CollectionError -Section ('Performance counter batch sample {0}' -f ($sampleIndex + 1)) -ErrorRecord $_
            }

        }
        Export-CsvFile -InputObject $counterRows -FileName 'performance-counters.csv'
    }
}
else {
    $script:SectionResults.Add([pscustomobject]@{
        Section         = 'Passive performance-counter capture'
        Status          = 'Skipped'
        StartedUtc      = [DateTime]::UtcNow.ToString('o')
        DurationSeconds = 0
        Message         = 'Skipped by parameter.'
    })
}

$script:FinishedUtc = [DateTime]::UtcNow
$collectionStatus = if (Test-StopRequested) { 'Cancelled' } else { 'Completed' }
$manifest = [pscustomobject]@{
    ScriptName                 = $MyInvocation.MyCommand.Name
    ScriptVersion              = $script:ScriptVersion
    ComputerName               = $computerName
    UserName                   = $identity.Name
    IsAdministrator            = $isAdministrator
    StartedUtc                 = $script:StartedUtc.ToString('o')
    FinishedUtc                = $script:FinishedUtc.ToString('o')
    DurationSeconds            = [Math]::Round(($script:FinishedUtc - $script:StartedUtc).TotalSeconds, 2)
    EventLookbackDays          = $EventLookbackDays
    EventWindowStartUtc        = $eventStartTime.ToString('o')
    EventWindowEndUtc          = $eventEndTime.ToString('o')
    ExactEventWindowRequested  = $hasEventStart
    PerformanceCaptureSkipped = [bool]$SkipPerformanceCapture
    SampleDurationSeconds      = if ($SkipPerformanceCapture) { 0 } else { $SampleDurationSeconds }
    SampleIntervalSeconds      = if ($SkipPerformanceCapture) { 0 } else { $SampleIntervalSeconds }
    ProcessNames               = @($ProcessNames)
    Status                     = $collectionStatus
    StopFilePath               = $StopFilePath
    SafetyStatement            = 'Read-only discovery. No service, queue, message, registry, firewall, route, or application configuration changes are performed.'
    ReviewBeforeSharing        = 'Required: review event messages, hostnames, queue names, paths, IP addresses, and endpoint hints before sharing outside CLP.'
    Sections                   = $script:SectionResults
}

Export-JsonFile -InputObject $manifest -FileName 'manifest.json' -Depth 6
Export-CsvFile -InputObject $script:Errors -FileName 'collection-errors.csv'

$hashes = Get-ChildItem -LiteralPath $resultDirectory -File | Where-Object { $_.Name -ne 'file-hashes.csv' } |
    ForEach-Object {
        [pscustomobject]@{
            File   = $_.Name
            Length = $_.Length
            SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    }
Export-CsvFile -InputObject $hashes -FileName 'file-hashes.csv'

$archivePath = '{0}.zip' -f $resultDirectory
if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force
}
Compress-Archive -Path (Join-Path $resultDirectory '*') -DestinationPath $archivePath -CompressionLevel Optimal
$archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash

$resultPointer = [pscustomobject]@{
    Status          = $collectionStatus
    ComputerName    = $computerName
    ScriptVersion   = $script:ScriptVersion
    StartedUtc      = $script:StartedUtc.ToString('o')
    FinishedUtc     = [DateTime]::UtcNow.ToString('o')
    ArchivePath     = $archivePath
    ArchiveSHA256   = $archiveHash
    ManifestInZip   = 'manifest.json'
    WarningCount    = $script:Errors.Count
    StopFilePath    = $StopFilePath
}
$resultPointer | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $latestResultPath -Encoding UTF8

if (-not $KeepUncompressed) {
    Remove-Item -LiteralPath $resultDirectory -Recurse -Force
}

if (Test-Path -LiteralPath $StopFilePath) {
    Remove-Item -LiteralPath $StopFilePath -Force
}

Write-Host ''
Write-Host ('Collection status: {0}' -f $collectionStatus) -ForegroundColor Green
Write-Host ('Archive: {0}' -f $archivePath)
Write-Host ('Result pointer: {0}' -f $latestResultPath)
Write-Host ('Individual checks with warnings: {0}' -f $script:Errors.Count)
Write-Host 'CLP must review the archive for customer-sensitive names and endpoints before sharing it.'