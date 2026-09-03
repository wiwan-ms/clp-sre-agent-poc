#requires -Version 5.1

<#+
.SYNOPSIS
Collects read-only MSMQ, service, storage, network, and event evidence from a Windows VM.

.DESCRIPTION
Designed for CLP administrators to run locally on each MSMQ VM. The script does not stop
services, read or remove message bodies, modify queues, change registry values, or initiate
connections to downstream systems. It writes only to the selected output directory.

OPERATIONAL SAFETY IN PLAIN LANGUAGE
This collector observes the VM; it does not administer MSMQ. It asks Windows and MSMQ for
status and configuration information in the same way that an administrator opens a monitoring
or management view. The script contains no command that sends, receives, peeks at, moves,
purges, creates, deletes, or changes an MSMQ message or queue. It also contains no command that
starts, stops, pauses, or restarts the MSMQ service or an application service.

The expected effect on normal MSMQ processing is low and temporary, but no software can promise
literally zero resource use. The collector uses some local CPU, memory, and disk I/O while it:
- reads Windows inventory and event records;
- asks MSMQ for queue names, properties, and current message COUNTS only;
- optionally samples existing Windows performance counters at a bounded interval; and
- writes local evidence files and compresses them into a ZIP.

The collector does not generate test traffic and does not connect to queue destinations. The
largest temporary workload is normally local file creation and ZIP compression, not MSMQ access.
For the lowest-impact first run, use -SkipPerformanceCapture during a quiet period, retain the
expanded output for inspection, and monitor the pilot VM before approving wider execution.

WHAT THE SCRIPT WRITES
All writes are limited to OutputRoot, which defaults to C:\ProgramData\CLP\MSMQ-Discovery.
The script creates one timestamped evidence folder, one ZIP, one latest-result JSON pointer, and
optionally removes its own expanded evidence folder. A consumed stop marker is also removed; if
StopFilePath was set outside OutputRoot, that one operator-created marker is the only deletion
outside OutputRoot. The script does not write
to MSMQ storage, application folders, the registry, event logs, firewall rules, routes, IIS,
HTTP.sys, MSDTC, Defender settings, scheduled tasks, services, or remote systems.

MSMQ-SPECIFIC COMMAND REVIEW
- Get-MsmqQueue: reads queue names, settings, and MessageCount metadata. No message object is
    requested, opened, peeked, received, moved, or deleted.
- Get-MsmqOutgoingQueue: reads outgoing-delivery status, count, next hop, and last error.
- Get-CimInstance against MSMQ performance classes: reads Windows' already-published counters.
- Get-Counter against MSMQ counter sets: samples already-published numeric counters.
- Commands that could alter operations, such as New-MsmqQueue, Set-MsmqQueue, Remove-MsmqQueue,
    Send-MsmqQueue, Receive-MsmqQueue, Clear-MsmqQueue, Start-Service, Stop-Service, Restart-Service,
    Set-ItemProperty, New-NetFirewallRule, or Set-NetRoute, are not used anywhere in this script.

CODE MAP / TABLE OF CONTENTS
The blocks below appear in the same order as the script. Use this list to locate the purpose of
each part before reviewing its detailed comments and commands.

1. Parameters and run setup
   Selects the output folder, event window, optional counter duration, process names, and graceful
   stop marker. Creates run names and in-memory status lists; it does not access MSMQ data.

2. Safety and output helper functions
   Test-StopRequested checks for the operator's stop marker.
   Add-CollectionError records a failed read for the final report.
   Invoke-CollectionSection runs one read-only block and records its status and duration.
   Export-JsonFile and Export-CsvFile write collected evidence into the collector output folder.
   Protect-SensitiveText redacts common secret patterns from a copy of collected text.

3. Path and endpoint helper functions
   Convert-ServicePathToExecutable extracts a service executable path without running it.
   Get-SafeEndpointValue removes credentials and unnecessary URL details.
   Get-ApplicationEndpointHints reads selected XML configuration values and returns only sanitized
   server, database, URL, WCF, or queue endpoint hints.

4. MSMQ registry, event, and counter helper functions
   Get-MsmqRegistryConfiguration reads only approved MSMQ registry values.
   Get-EventRecords reads a bounded event-log window and redacts message text.
   Get-PerformanceCounterPaths builds a limited list of host, process, and MSMQ counters.

5. Output folder, privilege check, and event-window validation
   Creates only the collector evidence folder, reports whether PowerShell is elevated, and rejects
   incomplete, reversed, or overlong event windows before collection begins.

6. Host inventory
   Records VM hardware, Windows version/build, boot time, BIOS identity, and time zone.

7. Windows features and agents
   Records relevant Windows features, installed-software display metadata, and Azure VM extension
   status. It does not install, remove, enable, disable, or restart anything.

8. MSMQ configuration
   Records MSMQ service status, approved registry settings, queue names/properties/message counts,
   outgoing delivery status, and current numeric performance snapshots. It never reads message
   bodies or sends, receives, peeks, moves, purges, creates, deletes, or changes messages/queues.

9. Storage inventory
   Records fixed-volume capacity/free space and Windows-reported physical disk metadata/status.
   It does not scan or alter MSMQ storage files.

10. Services, processes, application endpoints, and scheduled tasks
    Records service/process/task metadata, service executable metadata, and sanitized endpoint hints
    from adjacent XML config files. It does not execute code, tasks, or applications.

11. Passive network snapshot
    Records existing adapter, TCP/UDP endpoint, hosts-file, DNS-cache, route, and MSMQ firewall-rule
    state. It sends no packets and changes no connection, route, DNS, or firewall setting.

12. IIS and HTTP.sys listener configuration
    Records IIS site/application/binding metadata, selected web.config endpoint hints, `.svc` file
    metadata, and local `netsh http show` output. It does not recycle or reconfigure IIS/HTTP.sys.

13. MSDTC configuration
    Records DTC service, instance, and network-setting metadata without reading transaction data or
    changing DTC/MSMQ operation.

14. Defender exclusions
    Records Defender monitoring state and exclusion lists. It does not run a scan or change policy.

15. Bounded event-log collection
    Records a capped number of historical MSMQ-related events. It does not clear, archive, enable,
    disable, or change event logs.

16. Optional passive performance capture
    Reads existing numeric counters at a bounded interval. Use -SkipPerformanceCapture to omit this
    repeating block during the lowest-impact pilot.

17. Manifest, ZIP packaging, pointer, and cleanup
    Writes collection status/errors, compresses collector-created evidence, writes the latest-result
    pointer, and optionally removes only the expanded collector output and exact stop marker.

Version 2 removes SHA-256 calculation from configuration files, service binaries, IIS files,
individual output files, and the final ZIP archive. File paths, sizes, timestamps, and version
metadata are retained where available so an inspector can identify what was examined.

Run first on one AAPP and one SBS VM. After CLP reviews the output and operational impact,
run it on every active MSMQ VM. Run the dynamic capture within the same coordinated window
on all hosts when cross-VM queue and workload comparison is required.

.PARAMETER OutputRoot
Folder where this script may create and delete its own evidence files. The default is
C:\ProgramData\CLP\MSMQ-Discovery. This is not an MSMQ data folder.

.PARAMETER EventLookbackDays
How many days of local Windows event history to inspect when an exact time window is not given.
The query is read-only and the number of returned events is capped in the code.

.PARAMETER EventStartUtc
Optional exact UTC start of a historical event window. Supply with EventEndUtc. The exact
window may span no more than 31 days and overrides EventLookbackDays. This does not clear,
archive, or change the Windows event logs.

.PARAMETER EventEndUtc
Optional exact UTC end of a historical event window. Supply with EventStartUtc.

.PARAMETER SampleDurationSeconds
How long to read existing Windows performance counters. Default: 300 seconds; allowed range:
30-1800 seconds. Sampling observes counters and does not create MSMQ workload.

.PARAMETER SampleIntervalSeconds
Seconds between counter reads. Default: 15 seconds; allowed range: 5-60 seconds. A longer
interval means fewer reads and lower collection overhead.

.PARAMETER SkipPerformanceCapture
Disables the only timed/repeating collection block. Recommended for the first safety pilot to
minimize runtime and repeated counter reads.

.PARAMETER ProcessNames
Process counter instance names to capture. Defaults to mqsvc. Supply the known MSMQ consumer
process names after architecture discovery. Wildcard collection across every process is avoided
to bound runtime and operational impact.

.PARAMETER KeepUncompressed
Keeps this run's expanded evidence folder after creating the ZIP. This uses more disk space but
makes human review easier. Without this switch, only the ZIP and latest-result pointer remain.

.PARAMETER StopFilePath
Optional cooperative stop-marker path. The default is STOP-<hostname>.flag under OutputRoot.
Creating this file while the collector runs requests a graceful stop. The collector checks it
between sections and between performance samples, then writes a partial ZIP and result pointer.

.EXAMPLE
.\Collect-CLP-MsmqDiscovery-v2.ps1 -SkipPerformanceCapture -KeepUncompressed

Lowest-impact safety pilot. It performs one-time status/configuration reads, skips repeated
performance sampling, and keeps the expanded evidence for inspection.

.EXAMPLE
.\Collect-CLP-MsmqDiscovery-v2.ps1 -SampleDurationSeconds 300 -SampleIntervalSeconds 15

Normal bounded capture. It adds passive counter reads every 15 seconds for five minutes.

.NOTES
Recommended: run from an elevated 64-bit Windows PowerShell 5.1 session.
Review the resulting files for customer-sensitive names and endpoints before sharing them.

INSPECTOR GUIDE
- Every discovery block is wrapped by Invoke-CollectionSection so a failure is recorded and
    later blocks can continue.
- The script reads host, MSMQ, storage, service, process, network, IIS, HTTP.sys, MSDTC,
    Defender, event-log, and optional performance-counter information.
- It does not read MSMQ message bodies, change services or queues, modify registry or network
    configuration, invoke remote endpoints, or calculate file/archive cryptographic hashes.
- Potential secrets found in selected text fields are redacted before export. Configuration
    parsing records endpoint hints only; complete configuration-file content is not exported.
- Output is written as reviewable CSV, JSON, and text files, then packaged into one ZIP.
- "Read-only" in this document means no source-system state is changed. Normal local resource
    consumption still occurs while commands run and while the output ZIP is created.
#>

[CmdletBinding()]
param(
    # All collector-created evidence is placed below this folder. No MSMQ system folder is used.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot = (Join-Path $env:ProgramData 'CLP\MSMQ-Discovery'),

    # Default event-history period when exact UTC start/end values are not supplied.
    [Parameter()]
    [ValidateRange(1, 90)]
    [int]$EventLookbackDays = 30,

    # Optional exact event query start. EventStartUtc and EventEndUtc must be supplied together.
    [Parameter()]
    [DateTime]$EventStartUtc,

    # Optional exact event query end. EventStartUtc and EventEndUtc must be supplied together.
    [Parameter()]
    [DateTime]$EventEndUtc,

    # Total duration for optional passive performance-counter reads.
    [Parameter()]
    [ValidateRange(30, 1800)]
    [int]$SampleDurationSeconds = 300,

    # Interval between optional passive performance-counter reads.
    [Parameter()]
    [ValidateRange(5, 60)]
    [int]$SampleIntervalSeconds = 15,

    # Skip the repeating counter block to minimize pilot runtime and collection overhead.
    [Parameter()]
    [switch]$SkipPerformanceCapture,

    # Limit process counters to explicitly named processes; default is the MSMQ service process.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$ProcessNames = @('mqsvc'),

    # Keep human-readable expanded files after the ZIP has been created.
    [Parameter()]
    [switch]$KeepUncompressed,

    # Optional path for an operator-created file that requests a graceful stop.
    [Parameter()]
    [string]$StopFilePath
)

# Ask PowerShell to report common scripting mistakes and stop the current collection block on an
# error. Invoke-CollectionSection catches block failures so later independent blocks can continue.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Prepare labels and in-memory tracking for this run. These lines read the clock, computer name,
# and environment variables only. They do not query or change MSMQ.
$script:ScriptVersion = '2.0.0'
$script:StartedUtc = [DateTime]::UtcNow
$script:Errors = New-Object System.Collections.Generic.List[object]
$script:SectionResults = New-Object System.Collections.Generic.List[object]
$timestamp = $script:StartedUtc.ToString('yyyyMMddTHHmmssZ')
$computerName = $env:COMPUTERNAME
$resultName = 'CLP-MSMQ-Discovery-{0}-{1}' -f $computerName, $timestamp
$resultDirectory = Join-Path $OutputRoot $resultName
$latestResultPath = Join-Path $OutputRoot ('CLP-MSMQ-Discovery-{0}-latest-result.json' -f $computerName)
# If the operator did not choose a stop-marker path, place it inside the collector output folder.
# Merely defining this path does not create a file.
if ([string]::IsNullOrWhiteSpace($StopFilePath)) {
    $StopFilePath = Join-Path $OutputRoot ('STOP-{0}.flag' -f $computerName)
}

# PLAIN-LANGUAGE PURPOSE: Check whether the operator wants the collector to stop.
# WHAT IT READS: Only whether the stop-marker file exists.
# WHAT IT CHANGES: Nothing. It does not read the marker's contents or interact with MSMQ.
function Test-StopRequested {
    return Test-Path -LiteralPath $StopFilePath -PathType Leaf
}

# PLAIN-LANGUAGE PURPOSE: Remember an error without ending the entire collection.
# WHAT IT READS: The error already returned by another command.
# WHAT IT CHANGES: Only an in-memory list owned by this script. That list is written later to
# collection-errors.csv; no Windows or MSMQ setting is changed.
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

# PLAIN-LANGUAGE PURPOSE: Run one independent evidence block safely.
# HOW IT WORKS: Check the stop marker, run the supplied read block, catch an error, and record the
# block's status and duration. A failed inventory source therefore does not trigger service action
# or prevent unrelated evidence blocks from running.
# MSMQ IMPACT: This wrapper itself does not access MSMQ. It never retries in a tight loop and never
# restarts a service when a read fails.
function Invoke-CollectionSection {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    $sectionStarted = [DateTime]::UtcNow
    Write-Host ('[{0}] {1}' -f $sectionStarted.ToString('HH:mm:ss'), $Name)

    # Stop before starting this block if the operator has created the stop marker.
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

    # Run the caller-supplied read block once. Any failure is recorded below rather than repaired
    # automatically, because automatic repair would be inappropriate for a discovery collector.
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
    # Capture the failure for inspection. No rollback is needed because source settings were not
    # changed by the collection block.
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

# PLAIN-LANGUAGE PURPOSE: Save collected rows in a human-readable JSON file.
# WHAT IT CHANGES: Writes only under this run's evidence folder. It never writes to MSMQ storage.
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

# PLAIN-LANGUAGE PURPOSE: Save table-shaped evidence as a CSV file that can be opened in Excel.
# WHAT IT CHANGES: Writes only under this run's evidence folder. An empty file deliberately means
# "the block ran but found no rows"; it does not mean MSMQ data was deleted.
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

# PLAIN-LANGUAGE PURPOSE: Hide common secret patterns before free-form text is saved.
# WHAT IT READS: A text value already collected by another block.
# WHAT IT CHANGES: A copy of that text in memory only. The source event, status, or configuration
# file is never edited. This is a best-effort safeguard, so CLP must still review output.
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

# PLAIN-LANGUAGE PURPOSE: Separate an executable path from its command-line arguments.
# WHY: The script uses that path to look for an adjacent `<executable>.config` file.
# MSMQ IMPACT: String parsing occurs in memory; the executable is not started, loaded, or changed.
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

# PLAIN-LANGUAGE PURPOSE: Keep useful destination information while reducing sensitive detail.
# For HTTP(S), the saved value contains scheme, server/port, and path but omits credentials, query
# string, and fragment. This function edits only an in-memory copy and makes no network connection.
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

# PLAIN-LANGUAGE PURPOSE: Find which servers, databases, URLs, and queue addresses an application
# appears configured to use, without exporting the complete configuration file.
# WHAT IT READS: Existing service-adjacent `.config` and IIS `web.config` XML files selected by
# other blocks. Each file is opened for a normal read and is not locked for editing.
# WHAT IT SAVES: Source path, hint type/name, and a reduced/redacted endpoint value.
# WHAT IT DOES NOT SAVE: Password fields, secret-looking application settings, full connection
# strings, or the complete configuration file.
# MSMQ IMPACT: No queue API is called here. Reading application config files does not pause or
# restart their services. The only expected overhead is brief local file reading and XML parsing.
function Get-ApplicationEndpointHints {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ConfigurationFiles)

    $endpointHints = New-Object System.Collections.Generic.List[object]
    # Process each unique candidate once. If it disappeared after discovery, skip it safely.
    foreach ($configurationFile in ($ConfigurationFiles | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $configurationFile -PathType Leaf)) {
            continue
        }

        # Read the text into memory and parse a copy as XML. No Save(), Set-Content, or write API
        # is used against the source configuration file.
        try {
            [xml]$configuration = Get-Content -LiteralPath $configurationFile -Raw

            # Connection strings: retain only server/database/address/port fields. Authentication
            # fields and all unrecognized fields are discarded.
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

            # Application settings: skip keys that look secret-bearing and retain only settings
            # whose key or value indicates an endpoint, queue, host, address, URL, VIP, or port.
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

            # WCF clients: record endpoint name and sanitized destination address.
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

            # WCF services: record service endpoint name and sanitized address.
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

            # WCF hosts: record sanitized service base addresses.
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
        # A malformed or inaccessible config is reported; it is not repaired or rewritten.
        catch {
            Add-CollectionError -Section ('Parse config: {0}' -f $configurationFile) -ErrorRecord $_
        }
    }

    return $endpointHints
}

# PLAIN-LANGUAGE PURPOSE: Record selected MSMQ capacity, storage-path, priority, and workgroup
# settings that help explain queue behavior.
# WHAT IT READS: Only named values in two standard HKLM MSMQ registry paths. The allowlist prevents
# unrelated registry values from being collected.
# WHAT IT SAVES: Registry path, value name, and current value.
# MSMQ IMPACT: Get-ItemProperty is a registry read. No Set/New/Remove-ItemProperty command is used,
# so MSMQ configuration is not changed and the service is not restarted.
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

    # Visit the two known MSMQ paths only. Missing paths are normal on hosts without that layout.
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        $properties = Get-ItemProperty -LiteralPath $path
        $propertyNames = @($properties.PSObject.Properties | Select-Object -ExpandProperty Name)
        # Export a value only when its name is on the approved list and exists on this VM.
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

# PLAIN-LANGUAGE PURPOSE: Collect recent errors and warnings that can explain MSMQ symptoms.
# WHAT IT READS: One named local Windows event log, within the approved UTC time window, up to the
# MaxEvents limit. With MsmqOnly, non-MSMQ providers/messages are discarded after the bounded read.
# WHAT IT SAVES: Time, log, provider, event ID, severity, and redacted message text.
# MSMQ IMPACT: Windows Event Log serves this historical copy. MSMQ queues and messages are not
# queried, locked, or changed. Reading many event records uses temporary local CPU/disk I/O, which
# is bounded by the time window and MaxEvents.
function Get-EventRecords {
    param(
        [Parameter(Mandatory = $true)][string]$LogName,
        [Parameter(Mandatory = $true)][DateTime]$StartTime,
        [Parameter(Mandatory = $true)][DateTime]$EndTime,
        [int]$MaxEvents = 1000,
        [switch]$MsmqOnly
    )

    # Ask Windows Event Log for at most MaxEvents records in the stated time range.
    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = $LogName; StartTime = $StartTime; EndTime = $EndTime } -MaxEvents $MaxEvents -ErrorAction Stop
    }
    # "No matching events" is treated as a valid empty result; other failures are reported.
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
            return @()
        }
        throw
    }
    # For broad System/Application logs, keep only records that identify MSMQ in the provider or
    # message text, then cap the exported subset at 500 rows.
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

# PLAIN-LANGUAGE PURPOSE: Build a short, relevant list of existing Windows counters to observe.
# WHAT IT READS: Queue names/counts once, the list of installed MSMQ counter sets, and the explicit
# ProcessNames parameter. This function does not take the timed samples itself.
# WHY ACTIVE QUEUES ONLY: Per-queue counters are included only for queues currently holding messages,
# plus the overall "computer queues" instance. This avoids wildcard sampling of every queue.
# MSMQ IMPACT: Counter discovery and one metadata query create small temporary management overhead.
# They do not consume messages, lock queues, or create traffic. The entire timed block can be
# disabled with SkipPerformanceCapture.
function Get-PerformanceCounterPaths {
    $paths = New-Object System.Collections.Generic.List[string]
    $activeQueueNames = @()
    # Ask only for private queue metadata, then keep queue names whose MessageCount is above zero.
    # No message body or message object is requested.
    if (Get-Command Get-MsmqQueue -ErrorAction SilentlyContinue) {
        $activeQueueNames = @(Get-MsmqQueue -QueueType Private -ErrorAction SilentlyContinue |
            Where-Object { $_.MessageCount -gt 0 } |
            ForEach-Object { ([string]$_.QueueName).ToLowerInvariant() })
    }
    # Host counters show whether collection coincided with CPU, memory, or disk pressure.
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

    # Add counters only for operator-approved process names. Invalid characters are removed so the
    # value cannot become an arbitrary counter path.
    foreach ($processName in $ProcessNames) {
        $safeProcessName = $processName -replace '[^a-zA-Z0-9_.-]', ''
        if ([string]::IsNullOrWhiteSpace($safeProcessName)) {
            continue
        }
        $paths.Add(('\Process({0}*)\% Processor Time' -f $safeProcessName))
        $paths.Add(('\Process({0}*)\Thread Count' -f $safeProcessName))
        $paths.Add(('\Process({0}*)\IO Data Bytes/sec' -f $safeProcessName))
    }

    # Discover numeric counters already published by Windows/MSMQ. This does not enable new logging
    # or instrumentation inside MSMQ.
    $msmqSets = Get-Counter -ListSet '*MSMQ*' -ErrorAction SilentlyContinue
    foreach ($counterSet in @($msmqSets)) {
        foreach ($path in @($counterSet.PathsWithInstances)) {
            # Exclude wildcard instances and counters unrelated to queue depth, bytes, throughput,
            # or journals. This keeps sampling volume predictable.
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

# OUTPUT FOLDER SETUP
# Create only the local timestamped evidence folder. Parent folders are created as needed below
# OutputRoot. This path is separate from the MSMQ storage paths read from the registry, so evidence
# creation does not write into MSMQ queue or log files.
New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
# Remove an old stop marker before this run. This deletion applies only to the exact StopFilePath;
# no wildcard or directory deletion is used. The marker is an operator control file, not MSMQ data.
if (Test-Path -LiteralPath $StopFilePath) {
    Remove-Item -LiteralPath $StopFilePath -Force
}

# PRIVILEGE CHECK
# Record the executing Windows identity and whether it has local Administrator membership. This
# check does not elevate the process or change permissions. Elevation improves access to protected
# evidence; it does not cause this script to perform configuration changes.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ('CLP MSMQ discovery collector {0}' -f $script:ScriptVersion)
Write-Host ('Computer: {0}' -f $computerName)
Write-Host ('Output:   {0}' -f $resultDirectory)
Write-Host ('Elevated: {0}' -f $isAdministrator)
# Warn rather than attempting self-elevation. The script never prompts for credentials or launches
# another privileged process.
if (-not $isAdministrator) {
    Write-Warning 'The script is not elevated. It will continue, but protected MSMQ, process, event, and Defender data may be incomplete.'
}

# EVENT-WINDOW VALIDATION
# Resolve and validate the event-log time window before any event read. Explicit windows require
# both endpoints, must be ordered, and are limited to 31 days; otherwise EventLookbackDays is
# applied from current UTC. Invalid input stops before the event block instead of issuing an
# unbounded query.
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

# HOST INVENTORY -> host-inventory.json
# PLAIN-LANGUAGE PURPOSE: Identify which VM produced the evidence and give enough operating-system
# context to compare it with the other MSMQ receivers.
# WHAT IT READS: Computer manufacturer/model, memory and processor count; Windows name/version/build,
# architecture and boot time; BIOS manufacturer/version/date/serial number; local time zone.
# WHAT IT WRITES: One JSON file in the collector output folder.
# MSMQ IMPACT: None beyond normal shared VM resource use. These are one-time Windows CIM reads; no
# queue, message, MSMQ setting, application setting, or service state is accessed or changed.
Invoke-CollectionSection -Name 'Host inventory' -ScriptBlock {
    # Ask Windows for four small groups of machine facts and combine them into one object.
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

# WINDOWS FEATURES AND AGENTS
# -> windows-features.csv: MSMQ, .NET Framework, WAS, and IIS feature installation state.
# -> installed-software.csv: display name/version/publisher/install date from uninstall registry keys.
# -> azure-extension-status.csv: Azure VM extension status metadata and redacted status messages.
# PLAIN-LANGUAGE PURPOSE: Confirm that MSMQ and related Windows components are installed and identify
# monitoring/security/management software that may affect diagnostics.
# WHAT IT READS: Windows feature status, standard installed-software registry entries, and Azure VM
# extension `.status` files under C:\Packages\Plugins.
# WHAT IT DOES NOT READ: Application data, queue content, user documents, or extension secret files.
# EXPECTED OVERHEAD: One registry/software inventory query plus a local recursive search for small
# `.status` files. This may cause brief disk reads but does not call the MSMQ service.
# MSMQ IMPACT: No feature, product, extension, or service is installed, removed, enabled, disabled,
# started, stopped, or restarted.
Invoke-CollectionSection -Name 'Windows features and agents' -ScriptBlock {
    # Server feature inventory is available on Windows Server when the ServerManager module exists.
    # If the Windows Server feature cmdlet exists, save only MSMQ, .NET, WAS, and IIS-related rows.
    # Get-WindowsFeature reports installation state; it does not change that state.
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $features = Get-WindowsFeature | Where-Object { $_.Name -match 'MSMQ|NET-Framework|WAS|Web-' } |
            Select-Object Name, DisplayName, InstallState
        Export-CsvFile -InputObject $features -FileName 'windows-features.csv'
    }

    # Installed-software inventory uses the standard 64-bit and 32-bit uninstall registry views.
    # Read display metadata from the standard uninstall keys. Despite the registry path name, this
    # is an inventory read only; no uninstall action is invoked.
    $products = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.PSObject.Properties['DisplayName'].Value } |
        Select-Object @{ Name = 'DisplayName'; Expression = { $_.PSObject.Properties['DisplayName'].Value } },
            @{ Name = 'DisplayVersion'; Expression = { $_.PSObject.Properties['DisplayVersion'].Value } },
            @{ Name = 'Publisher'; Expression = { $_.PSObject.Properties['Publisher'].Value } },
            @{ Name = 'InstallDate'; Expression = { $_.PSObject.Properties['InstallDate'].Value } } |
        Sort-Object DisplayName, DisplayVersion -Unique
    Export-CsvFile -InputObject $products -FileName 'installed-software.csv'

    # Azure VM extension status files contain extension name/version, operation, status, code,
    # timestamp, and message. Messages pass through Protect-SensitiveText before export.
    $extensionStatus = New-Object System.Collections.Generic.List[object]
    $pluginRoot = Join-Path $env:SystemDrive 'Packages\Plugins'
    # If this Azure VM folder exists, inspect only files ending in `.status`. Each status message is
    # redacted before export. The extension itself is not contacted or reconfigured.
    if (Test-Path -LiteralPath $pluginRoot -PathType Container) {
        foreach ($statusFile in @(Get-ChildItem -LiteralPath $pluginRoot -Recurse -File -Filter '*.status' -ErrorAction SilentlyContinue)) {
            # Read and parse one existing JSON status file. Any unreadable file is recorded and the
            # collector continues to the next file.
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

# MSMQ CONFIGURATION
# -> msmq-services.csv: MSMQ Windows service state, startup, account, process, path, and exit code.
# -> msmq-registry.csv: only the allowlisted MSMQ operational registry values.
# -> msmq-queues.csv: queue identity and properties, including message count; never message bodies.
# -> msmq-outgoing-queues.csv: destination, state, count, next hop, and last error when available.
# -> Win32_PerfFormattedData_msmq_*.json: current formatted MSMQ performance snapshots.
# PLAIN-LANGUAGE PURPOSE: Capture the minimum MSMQ state needed to identify queue backlog, delivery
# problems, storage limits, and service health across receivers.
# WHAT IT READS: MSMQ service metadata, an approved registry-value list, queue properties/counts,
# outgoing-queue delivery status, and current numeric MSMQ performance snapshots.
# WHAT IT DOES NOT READ: Message bodies, message labels/properties on individual messages, sender
# content, attachments, or journal/dead-letter message content.
# EXPECTED OVERHEAD: A small number of local management queries. Queue enumeration asks MSMQ for
# current metadata and counts, so it uses brief service CPU like an administrator opening a queue
# management view. It does not lock, pause, drain, or otherwise hold a queue.
# MSMQ IMPACT: No create/set/remove/send/receive/peek/purge command appears in this block. The MSMQ
# service and applications continue normal send/receive processing while these reads occur.
Invoke-CollectionSection -Name 'MSMQ configuration' -ScriptBlock {
    # Read the Windows service-control database for services whose names begin with MSMQ. This is
    # service metadata only; no Start-Service, Stop-Service, or Set-Service call follows.
    $msmqServices = @(Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'MSMQ%'" |
        Select-Object Name, DisplayName, State, StartMode, StartName, ProcessId, PathName, ExitCode)
    Export-CsvFile -InputObject $msmqServices -FileName 'msmq-services.csv'
    # Call the allowlisted registry reader documented above. It cannot write registry values.
    $msmqRegistry = @(Get-MsmqRegistryConfiguration)
    Export-CsvFile -InputObject $msmqRegistry -FileName 'msmq-registry.csv'

    # Queue metadata includes names, format names, depth, quotas, journal flags, labels, and multicast
    # addresses. Get-MsmqQueue does not retrieve message content here.
    if (Get-Command Get-MsmqQueue -ErrorAction SilentlyContinue) {
        $queues = @(Get-MsmqQueue -ErrorAction Stop | Select-Object QueueName, PathName, FormatName,
            MessageCount, Transactional, UseJournalQueue, QueueQuota, JournalQuota, Label, MulticastAddress)
        Export-CsvFile -InputObject $queues -FileName 'msmq-queues.csv'
    }
    # If the queue cmdlet is unavailable, write an explanation file rather than loading software,
    # changing Windows features, or trying an alternative invasive method.
    else {
        Set-Content -LiteralPath (Join-Path $resultDirectory 'msmq-queues-unavailable.txt') -Encoding UTF8 -Value @(
            'The Get-MsmqQueue cmdlet was not available in this PowerShell session.'
            'Queue inventory may still appear in the MSMQ performance snapshot.'
        )
    }

    # Outgoing queue state helps identify delivery backlogs and routing failures.
    # Read outgoing delivery state only when the standard cmdlet is already installed. This does
    # not retry, resend, cancel, or move outgoing messages.
    if (Get-Command Get-MsmqOutgoingQueue -ErrorAction SilentlyContinue) {
        $outgoingQueues = @(Get-MsmqOutgoingQueue -ErrorAction Stop |
            Select-Object DestinationQueueFormatName, State, MessageCount, NextHops, LastError)
        Export-CsvFile -InputObject $outgoingQueues -FileName 'msmq-outgoing-queues.csv'
    }

    # Formatted WMI performance classes provide one current snapshot, separate from the optional
    # timed performance-counter capture later in the script.
    $msmqPerformanceClasses = @(
        'Win32_PerfFormattedData_msmq_MSMQQueue',
        'Win32_PerfFormattedData_msmq_MSMQService',
        'Win32_PerfFormattedData_msmq_MSMQOutgoingQueue'
    )
    # Check each known formatted performance class once. Missing classes are skipped; the collector
    # does not enable counters or restart MSMQ to make them appear.
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

# STORAGE INVENTORY
# -> volumes.csv: local fixed-volume name, filesystem, capacity, free bytes, and percent free.
# -> physical-disks.csv: disk model, interface/media type, capacity, and reported health status.
# PLAIN-LANGUAGE PURPOSE: Determine whether low disk capacity or disk health could explain MSMQ
# queue growth or slow persistence.
# WHAT IT READS: Capacity/free-space metadata for fixed volumes and Windows-reported physical disk
# model/interface/media/size/status. No directory is scanned and no source file content is opened.
# EXPECTED OVERHEAD: Two one-time Windows CIM queries.
# MSMQ IMPACT: No MSMQ API or MSMQ storage file is opened, and no disk check/repair/benchmark is run.
Invoke-CollectionSection -Name 'Storage inventory' -ScriptBlock {
    # Read logical fixed-disk totals and calculate percentage free in memory.
    $volumes = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' |
        Select-Object DeviceID, VolumeName, FileSystem, Size, FreeSpace,
            @{ Name = 'PercentFree'; Expression = { if ($_.Size) { [Math]::Round(($_.FreeSpace / $_.Size) * 100, 2) } } }
    Export-CsvFile -InputObject $volumes -FileName 'volumes.csv'

    # Read descriptive and health status metadata already reported by Windows.
    $physicalDisks = Get-CimInstance -ClassName Win32_DiskDrive |
        Select-Object Index, Model, InterfaceType, MediaType, Size, Status
    Export-CsvFile -InputObject $physicalDisks -FileName 'physical-disks.csv'
}

# SERVICES, PROCESSES, AND APPLICATION ENDPOINT HINTS
# -> services.csv: all Windows service identity, state, startup, account, PID, command path, exit code.
# -> processes.csv: PID/parent PID, name/path, thread count, working set, and creation time.
# -> application-config-inventory.csv: discovered service-adjacent config path, size, and timestamp.
# -> application-endpoint-hints.csv: sanitized endpoint-related values parsed from those configs.
# -> service-binary-inventory.csv: service executable path, owning services, size/time/version metadata.
# -> scheduled-tasks.csv: non-Microsoft or MSMQ-related task identity, action, trigger, and run status.
# PLAIN-LANGUAGE PURPOSE: Identify which local application probably consumes or produces MSMQ
# traffic and which configured destinations it references.
# WHAT IT READS: Windows service/process/task metadata; file metadata for registered service
# executables; and selected XML values from service-adjacent configuration files.
# WHAT IT DOES NOT DO: It does not attach to a process, inspect process memory, execute a binary or
# scheduled task, change service/task state, or export complete configuration files.
# EXPECTED OVERHEAD: One-time service/process/task inventory and brief reads of discovered XML config
# files. Only files derived from registered service executable paths are considered.
# MSMQ IMPACT: This block does not invoke an MSMQ cmdlet. Applications remain running and their
# service/process state is not changed.
Invoke-CollectionSection -Name 'Services, processes, and application endpoint hints' -ScriptBlock {
    # Enumerate service and process metadata to map MSMQ listeners/consumers to running software.
    $services = Get-CimInstance -ClassName Win32_Service | Select-Object Name, DisplayName, State,
        StartMode, StartName, ProcessId, PathName, ExitCode
    Export-CsvFile -InputObject $services -FileName 'services.csv'

    # Save process identity and resource-size metadata already exposed by Windows. Command lines,
    # environment variables, memory contents, and open message handles are not collected.
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

    # Locate only `.config` files adjacent to registered service executables.
    $configurationFiles = New-Object System.Collections.Generic.List[string]
    # For each registered service, derive its executable path and check for one adjacent `.config`
    # file. No broad drive search is performed.
    foreach ($service in $services) {
        $executable = Convert-ServicePathToExecutable -PathName $service.PathName
        if ($executable -and (Test-Path -LiteralPath $executable -PathType Leaf)) {
            $candidate = '{0}.config' -f $executable
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $configurationFiles.Add($candidate)
            }
        }
    }

    # Record basic file metadata without calculating cryptographic hashes or copying file content.
    $configInventory = foreach ($configurationFile in ($configurationFiles | Sort-Object -Unique)) {
        $item = Get-Item -LiteralPath $configurationFile
        [pscustomobject]@{
            Path             = $item.FullName
            Length           = $item.Length
            LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
        }
    }
    Export-CsvFile -InputObject $configInventory -FileName 'application-config-inventory.csv'
    # Parse only approved endpoint-like XML values using the redaction function documented above.
    $endpointHints = @(Get-ApplicationEndpointHints -ConfigurationFiles @($configurationFiles))
    Export-CsvFile -InputObject $endpointHints -FileName 'application-endpoint-hints.csv'

    # Record executable metadata exposed by Windows; binaries are not opened, copied, or executed.
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
    # Group services sharing one executable so that file metadata is read only once per binary.
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
            })
        }
        catch {
            Add-CollectionError -Section ('Service binary: {0}' -f $group.Name) -ErrorRecord $_
        }
    }
    Export-CsvFile -InputObject $serviceBinaryRows -FileName 'service-binary-inventory.csv'

    # Include custom tasks plus Microsoft tasks that appear MSMQ-related. Arguments are redacted.
    $scheduledTaskRows = New-Object System.Collections.Generic.List[object]
    # If the task cmdlets exist, collect custom tasks plus Microsoft tasks whose names/actions refer
    # to messaging. Get-ScheduledTaskInfo reads run history; it does not trigger a task.
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $scheduledTasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
            $_.TaskPath -notlike '\Microsoft\*' -or
            $_.TaskName -match '(?i)MSMQ|Message|Queue' -or
            (@($_.Actions.Execute) -join ' ') -match '(?i)MSMQ|Message|Queue'
        })
        # Read current status once for each selected task, then record each configured action.
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

# PASSIVE NETWORK SNAPSHOT
# -> network-adapters.csv: interface descriptions, assigned IPs, gateways, and DNS servers.
# -> tcp-connections.csv / listener-owners.csv: established/listening TCP endpoints and owner mapping.
# -> udp-endpoints.csv: local UDP endpoints and owner mapping.
# -> hosts-file-overrides.csv / dns-client-cache.csv: local name-resolution observations.
# -> ipv4-routes.csv / ipv6-routes.csv: current route table entries.
# -> msmq-firewall-*.csv: MSMQ-related rule state, port filters, and address filters.
# PLAIN-LANGUAGE PURPOSE: Show where the VM is listening, which remote endpoints are already
# connected, how names/routes resolve, and whether MSMQ firewall rules allow expected traffic.
# WHAT IT READS: Local adapter, TCP/UDP endpoint, process-owner, hosts-file, DNS-cache, route-table,
# and MSMQ-related firewall-rule state already held by Windows.
# WHAT IT DOES NOT DO: It does not ping, resolve new DNS names, open a socket, connect to another
# server, capture packets, change a route, or enable/disable a firewall rule.
# EXPECTED OVERHEAD: Several one-time local Windows networking queries and small CSV writes.
# MSMQ IMPACT: Existing MSMQ connections are observed but not closed, reset, tested, or modified.
Invoke-CollectionSection -Name 'Passive network snapshot' -ScriptBlock {
    # Adapter addresses and DNS/gateway configuration.
    $adapters = Get-NetIPConfiguration | Select-Object InterfaceAlias, InterfaceDescription,
        @{ Name = 'IPv4Address'; Expression = { ($_.IPv4Address.IPAddress -join ',') } },
        @{ Name = 'IPv6Address'; Expression = { ($_.IPv6Address.IPAddress -join ',') } },
        @{ Name = 'IPv4DefaultGateway'; Expression = { ($_.IPv4DefaultGateway.NextHop -join ',') } },
        @{ Name = 'DNSServer'; Expression = { ($_.DNSServer.ServerAddresses -join ',') } }
    Export-CsvFile -InputObject $adapters -FileName 'network-adapters.csv'

    # Build local process/service lookup tables, then correlate them with TCP and UDP owners.
    $processById = @{}
    Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
        $processById[[int]$_.ProcessId] = $_
    }
    $serviceNamesByProcessId = @{}
    Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -gt 0 } |
        Group-Object ProcessId | ForEach-Object {
            $serviceNamesByProcessId[[int]$_.Name] = (@($_.Group.Name | Sort-Object -Unique) -join ',')
        }
    # Keep only connections Windows reports as Established or Listen. Reading this table does not
    # create traffic or touch the socket; it is comparable to viewing netstat output.
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

    # Record local UDP listeners and their owning process/service. No datagram is sent.
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

    # Parse active, non-comment hosts-file mappings only; comments and blank lines are excluded.
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

    # Capture selected address, alias, and pointer records already present in the local DNS cache.
    $dnsCache = @(Get-DnsClientCache -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -in @(1, 5, 12, 28) } |
        Select-Object Entry, Name, Data, Type, TimeToLive, Status)
    Export-CsvFile -InputObject $dnsCache -FileName 'dns-client-cache.csv'

    # Read current IPv4 and IPv6 route tables for next-hop and interface correlation.
    $routes = Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop |
        Select-Object DestinationPrefix, NextHop, RouteMetric, InterfaceAlias, Protocol, State
    Export-CsvFile -InputObject $routes -FileName 'ipv4-routes.csv'

    $ipv6Routes = Get-NetRoute -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Select-Object DestinationPrefix, NextHop, RouteMetric, InterfaceAlias, Protocol, State
    Export-CsvFile -InputObject $ipv6Routes -FileName 'ipv6-routes.csv'

    # Restrict firewall collection to rules whose display group or name identifies MSMQ.
    $firewallRules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayGroup -match '(?i)Message Queuing|MSMQ' -or $_.DisplayName -match '(?i)Message Queuing|MSMQ' } |
        Select-Object DisplayName, DisplayGroup, Enabled, Profile, Direction, Action)
    Export-CsvFile -InputObject $firewallRules -FileName 'msmq-firewall-rules.csv'

    # Reuse the same selected rule objects to read their port and address filters. All cmdlet names
    # begin with Get; no New/Set/Enable/Disable/Remove firewall cmdlet is called.
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

# IIS AND HTTP.SYS LISTENER CONFIGURATION
# -> iis-websites.csv / iis-bindings.csv / iis-applications.csv: site/app paths, pools, bindings,
#    SSL flags, and certificate store name. Certificate thumbprints are deliberately excluded.
# -> iis-config-inventory.csv: web.config path, size, and timestamp; no hash or full file copy.
# -> iis-application-endpoint-hints.csv: sanitized endpoint hints parsed from web.config.
# -> iis-service-files.csv: `.svc` path, size, and timestamp, capped at 500 files per site root.
# -> http-sys-*.txt: redacted listener service state, URL ACLs, and SSL certificate bindings.
# PLAIN-LANGUAGE PURPOSE: Determine whether an IIS/WCF/HTTP.sys application is exposing an MSMQ-
# related service and which local URL/listener bindings are in use.
# WHAT IT READS: IIS site/application/binding metadata, root-level web.config endpoint hints, `.svc`
# filenames/metadata, and output from three `netsh http show` commands.
# WHAT IT DOES NOT READ: Web request/response bodies, certificate files/private keys, website content
# other than selected web.config XML, or `.svc` file content. Hash/thumbprint values are excluded.
# EXPECTED OVERHEAD: Loading the standard WebAdministration module, reading IIS metadata/config,
# scanning each discovered IIS root for up to 500 `.svc` filenames, and running local `show` commands.
# The recursive filename scan can cause temporary disk I/O on large site trees; it does not execute
# site code. Run the pilot during a quiet period if IIS roots are large.
# MSMQ IMPACT: No MSMQ API is called. IIS sites/application pools and HTTP.sys listeners are not
# started, stopped, recycled, reset, added, removed, or reconfigured.
Invoke-CollectionSection -Name 'IIS and HTTP.sys listener configuration' -ScriptBlock {
    # Continue with IIS-specific collection only when the standard module is already installed.
    # Import-Module loads PowerShell commands into this session; it does not alter IIS configuration.
    if (Get-Module -ListAvailable -Name WebAdministration) {
        Import-Module WebAdministration -ErrorAction Stop
        # Read website identity/state/path/pool and format its existing bindings for CSV output.
        $websites = @(Get-Website | Select-Object Name, Id, State, PhysicalPath, ApplicationPool,
            @{ Name = 'Bindings'; Expression = {
                (@($_.Bindings.Collection | ForEach-Object {
                    '{0}:{1}' -f $_.Protocol, $_.BindingInformation
                }) -join ',')
            } })
        Export-CsvFile -InputObject $websites -FileName 'iis-websites.csv'

        # Read binding protocol/address and SSL flags. Certificate thumbprints are not selected.
        $webBindings = @(Get-WebBinding | Select-Object protocol, bindingInformation, sslFlags,
            certificateStoreName, ItemXPath)
        Export-CsvFile -InputObject $webBindings -FileName 'iis-bindings.csv'

        # Read application path, pool, and physical-root metadata; applications are not invoked.
        $webApplications = @(Get-WebApplication |
            Select-Object Path, ApplicationPool, PhysicalPath, ItemXPath)
        Export-CsvFile -InputObject $webApplications -FileName 'iis-applications.csv'

        # Resolve IIS physical roots, then inspect only root-level web.config and `.svc` metadata.
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

        # Look only for a web.config at each discovered root. The collector does not recursively
        # search for or copy all configuration files.
        $iisConfigFiles = New-Object System.Collections.Generic.List[string]
        foreach ($iisRoot in @($iisRoots | Sort-Object -Unique)) {
            $webConfig = Join-Path $iisRoot 'web.config'
            if (Test-Path -LiteralPath $webConfig -PathType Leaf) {
                $iisConfigFiles.Add($webConfig)
            }
        }
        # Record config metadata without cryptographic hashing or copying full file content.
        $iisConfigInventory = foreach ($configurationFile in @($iisConfigFiles | Sort-Object -Unique)) {
            $item = Get-Item -LiteralPath $configurationFile
            [pscustomobject]@{
                Path             = $item.FullName
                Length           = $item.Length
                LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
            }
        }
        Export-CsvFile -InputObject $iisConfigInventory -FileName 'iis-config-inventory.csv'
        $iisEndpointHints = @(Get-ApplicationEndpointHints -ConfigurationFiles @($iisConfigFiles))
        Export-CsvFile -InputObject $iisEndpointHints -FileName 'iis-application-endpoint-hints.csv'

        # Search filenames/metadata for `.svc` service declarations. Select-Object caps exported
        # results at 500 per root. File bodies are not opened by this loop.
        $iisServiceFiles = foreach ($iisRoot in @($iisRoots | Sort-Object -Unique)) {
            Get-ChildItem -LiteralPath $iisRoot -Recurse -File -Filter '*.svc' -ErrorAction SilentlyContinue |
                Select-Object -First 500 | ForEach-Object {
                    [pscustomobject]@{
                        SiteRoot         = $iisRoot
                        Path             = $_.FullName
                        Length           = $_.Length
                        LastWriteTimeUtc = $_.LastWriteTimeUtc.ToString('o')
                    }
                }
        }
        Export-CsvFile -InputObject $iisServiceFiles -FileName 'iis-service-files.csv'
    }
    # If IIS administration tools are absent, write a note and continue. The collector does not
    # install the module or enable IIS.
    else {
        Set-Content -LiteralPath (Join-Path $resultDirectory 'iis-unavailable.txt') -Encoding UTF8 -Value @(
            'The WebAdministration module is not installed or available.'
            'HTTP.sys registrations are still collected below when netsh is available.'
        )
    }

    # `netsh http show` commands are read-only views of HTTP.sys registrations. Text passes through
    # redaction before export.
    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    # Run only `netsh http show` variants. "show" reads current state; no add/delete/update/reset
    # verb is present. Standard error is captured as evidence and redacted with normal output.
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

# MSDTC CONFIGURATION
# -> msdtc-services.csv: Distributed Transaction Coordinator service state and identity.
# -> msdtc-instances.json / msdtc-network-settings.json: local DTC instance/network settings when
# PLAIN-LANGUAGE PURPOSE: Show whether Distributed Transaction Coordinator could participate in
# the application flow and whether its network access is enabled.
# WHAT IT READS: DTC service identity/state and local DTC instance/network-setting metadata.
# WHAT IT DOES NOT READ: Transaction payloads or in-flight business data.
# MSMQ IMPACT: Get-Dtc and Get-DtcNetworkSetting are status reads. DTC and MSMQ are not started,
# stopped, reset, recovered, or configured.
Invoke-CollectionSection -Name 'MSDTC configuration' -ScriptBlock {
    # Read the Windows service-control record for the local/default and named DTC services.
    $dtcServices = Get-CimInstance -ClassName Win32_Service |
        Where-Object { $_.Name -eq 'MSDTC' -or $_.Name -like 'MSDTC$*' } |
        Select-Object Name, DisplayName, State, StartMode, StartName, ProcessId, PathName
    Export-CsvFile -InputObject $dtcServices -FileName 'msdtc-services.csv'

    # Use DTC read cmdlets only when already installed. Missing cmdlets are simply skipped.
    if (Get-Command Get-Dtc -ErrorAction SilentlyContinue) {
        Export-JsonFile -InputObject (Get-Dtc) -FileName 'msdtc-instances.json' -Depth 5
    }
    if (Get-Command Get-DtcNetworkSetting -ErrorAction SilentlyContinue) {
        Export-JsonFile -InputObject (Get-DtcNetworkSetting -DtcName Local) -FileName 'msdtc-network-settings.json' -Depth 5
    }
}

# DEFENDER EXCLUSIONS -> defender-exclusions.json
# PLAIN-LANGUAGE PURPOSE: Check whether required MSMQ/application paths or processes are excluded
# from antivirus scanning, which can help explain storage or processing delays.
# WHAT IT READS: Real-time-monitoring enabled/disabled state and configured path, process, and file-
# extension exclusion lists.
# WHAT IT DOES NOT READ: Threat history, quarantined content, scanned file contents, or credentials.
# MSMQ IMPACT: Get-MpPreference is one settings read. It does not run a scan or add/remove exclusions,
# and it does not access the MSMQ service or queues.
Invoke-CollectionSection -Name 'Defender exclusions' -ScriptBlock {
    # Query Defender only if its standard read cmdlet is available on this VM.
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
    # If another security product replaces Defender, record that this source was unavailable rather
    # than attempting to discover or control the other product.
    else {
        Set-Content -LiteralPath (Join-Path $resultDirectory 'defender-unavailable.txt') -Encoding UTF8 -Value @(
            'Microsoft Defender cmdlets were not available.'
            'If another EDR product is authoritative, CLP should provide its MSMQ exclusion policy separately.'
        )
    }
}

# BOUNDED EVENT-LOG COLLECTION
# -> events-system-msmq.csv / events-application-msmq.csv: MSMQ-related events in the chosen window.
# -> events-<MSMQ-log-name>.csv: up to 500 events from each enabled MSMQ-specific log.
# Each row contains UTC time, log/provider, event ID, severity, and redacted message. System and
# PLAIN-LANGUAGE PURPOSE: Preserve historical evidence of MSMQ warnings/errors around the incident.
# WHAT IT READS: Historical copies from local Windows Event Log for the chosen period.
# BOUNDS: System and Application reads request at most 1,000 candidate events each, then export at
# most 500 MSMQ-related rows each. Every enabled MSMQ-specific log requests at most 500 events.
# EXPECTED OVERHEAD: Event Log may perform temporary local disk/cache reads. There is no continuous
# subscription, event tracing session, or logging-level change.
# MSMQ IMPACT: Events are not cleared, archived, acknowledged, or changed. The block does not read
# a queue or message and does not alter current message delivery.
Invoke-CollectionSection -Name 'Bounded event-log collection' -ScriptBlock {
    # Read bounded System and Application candidates and keep only MSMQ-related rows.
    $systemEvents = @(Get-EventRecords -LogName 'System' -StartTime $eventStartTime -EndTime $eventEndTime -MsmqOnly)
    $applicationEvents = @(Get-EventRecords -LogName 'Application' -StartTime $eventStartTime -EndTime $eventEndTime -MsmqOnly)
    Export-CsvFile -InputObject $systemEvents -FileName 'events-system-msmq.csv'
    Export-CsvFile -InputObject $applicationEvents -FileName 'events-application-msmq.csv'

    # Ask Windows which MSMQ-named logs are enabled and nonempty. This lists logs but does not enable
    # disabled channels or change retention/size settings.
    $msmqLogs = Get-WinEvent -ListLog '*MSMQ*' -ErrorAction SilentlyContinue |
        Where-Object { $_.IsEnabled -and $_.RecordCount -gt 0 } |
        Select-Object -ExpandProperty LogName
    # Read each eligible MSMQ log once. Unsafe filename characters are replaced only in the output
    # CSV name; the source log name and source log are not changed.
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

# OPTIONAL PASSIVE PERFORMANCE CAPTURE -> performance-counter-paths.txt and performance-counters.csv
# PLAIN-LANGUAGE PURPOSE: Observe whether queue growth coincides with CPU, memory, disk, MSMQ, or
# named-process pressure during a short approved window.
# WHAT IT READS: Numeric values already published through Windows Performance Counters.
# WHAT IT DOES NOT DO: It does not enable tracing, generate test messages, benchmark disks, inspect
# message content, or change process priority/affinity.
# BOUNDS: Duration is 30-1800 seconds, interval is 5-60 seconds, process names are explicit, wildcard
# queue instances are excluded, and a stop marker is checked between samples.
# EXPECTED OVERHEAD: Each sample uses brief local CPU to read/format counters and memory to retain
# rows until CSV export. `Start-Sleep` consumes no MSMQ resource while waiting. SkipPerformanceCapture
# removes this repeating block entirely and is recommended for the first pilot.
# MSMQ IMPACT: Performance counters are observational. Normal send/receive threads continue; no
# queue lock, service pause, traffic generation, or configuration change is requested.
if (-not $SkipPerformanceCapture) {
    # Enter this block only when the operator did not request the lowest-impact skip option.
    Invoke-CollectionSection -Name 'Passive performance-counter capture' -ScriptBlock {
        # Build the approved counter list, save it for inspection, and calculate the bounded number
        # of samples from duration divided by interval.
        $counterPaths = @(Get-PerformanceCounterPaths)
        Set-Content -LiteralPath (Join-Path $resultDirectory 'performance-counter-paths.txt') -Value $counterPaths -Encoding UTF8

        $maxSamples = [Math]::Max(1, [Math]::Ceiling($SampleDurationSeconds / $SampleIntervalSeconds))
        $counterRows = New-Object System.Collections.Generic.List[object]
        $activeCounterPaths = New-Object System.Collections.Generic.List[string]

        # Try all counters as one batch first. If one unavailable counter breaks the batch, retry
        # each path individually so valid counters can still be sampled and failures are recorded.
        try {
            $counterData = Get-Counter -Counter $counterPaths -MaxSamples 1
            # If the batch read succeeds, remember those paths for later samples and store the first
            # timestamp/value/status rows in memory.
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
        # If one unavailable counter causes the batch preflight to fail, test each path once. This
        # fallback improves evidence completeness; it does not retry forever or change the counter.
        catch {
            Add-CollectionError -Section 'Performance counter batch preflight' -ErrorRecord $_
            foreach ($counterPath in $counterPaths) {
                if (Test-StopRequested) {
                    break
                }
                # Read this one numeric counter once and retain it only when Windows returns it.
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

        # Wait between passive samples and honor the cooperative stop marker before each sample.
        for ($sampleIndex = 1; $sampleIndex -lt $maxSamples; $sampleIndex++) {
            if (Test-StopRequested) {
                break
            }

            # Wait without polling, then request one new numeric sample from each validated path.
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
        # Write all retained numeric samples once at the end of the bounded capture.
        Export-CsvFile -InputObject $counterRows -FileName 'performance-counters.csv'
    }
}
else {
    # Record that the operator intentionally skipped timed sampling. No counter paths are built and
    # no Get-Counter sample is taken in this branch.
    $script:SectionResults.Add([pscustomobject]@{
        Section         = 'Passive performance-counter capture'
        Status          = 'Skipped'
        StartedUtc      = [DateTime]::UtcNow.ToString('o')
        DurationSeconds = 0
        Message         = 'Skipped by parameter.'
    })
}

# FINAL MANIFEST
# PLAIN-LANGUAGE PURPOSE: Make the evidence self-describing for CLP review.
# WHAT IT WRITES: manifest.json records who ran the collector, timing, parameters, the read-only
# safety statement, and status/duration of every section. collection-errors.csv records failed
# reads. These files contain collector bookkeeping, not new VM or MSMQ queries.
# MSMQ IMPACT: None. The collection phase has ended before these files are produced.
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

# PACKAGE RESULTS
# PLAIN-LANGUAGE PURPOSE: Put the evidence into one file for controlled review and transfer.
# WHAT IT CHANGES: If a ZIP with this exact timestamped name already exists, remove that collector
# output ZIP, then compress only this run's evidence files into a replacement ZIP. Version 2 does
# not calculate hashes and does not create file-hashes.csv.
# EXPECTED OVERHEAD: ZIP compression is normally the largest temporary CPU/disk operation in the
# script. It reads collector-created evidence, not MSMQ queue storage. Available free space should
# be checked before running, and the pilot should confirm acceptable resource use.
# MSMQ IMPACT: No MSMQ API is used during compression. Normal MSMQ operations continue, although all
# processes share the VM's CPU and disk; schedule the pilot in a quiet period if the VM is constrained.
$archivePath = '{0}.zip' -f $resultDirectory
# Remove only an exact-name prior collector ZIP; no wildcard and no source-system path is used.
if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force
}
# Compress files already written by this collector. The source path is the timestamped output folder.
Compress-Archive -Path (Join-Path $resultDirectory '*') -DestinationPath $archivePath -CompressionLevel Optimal

# LATEST-RESULT POINTER
# PLAIN-LANGUAGE PURPOSE: Let an operator find the archive created by the latest run without guessing
# from filenames. The JSON contains archive path, version/times, manifest name, warning count, and
# stop-marker path. It contains no message or queue payload.
$resultPointer = [pscustomobject]@{
    Status          = $collectionStatus
    ComputerName    = $computerName
    ScriptVersion   = $script:ScriptVersion
    StartedUtc      = $script:StartedUtc.ToString('o')
    FinishedUtc     = [DateTime]::UtcNow.ToString('o')
    ArchivePath     = $archivePath
    ManifestInZip   = 'manifest.json'
    WarningCount    = $script:Errors.Count
    StopFilePath    = $StopFilePath
}
$resultPointer | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $latestResultPath -Encoding UTF8

# CLEANUP OF COLLECTOR OUTPUT
# Unless KeepUncompressed was selected, remove only this run's expanded evidence folder after the
# ZIP and pointer are successfully written. This path is derived from OutputRoot plus the collector's
# own timestamped result name; it is not an MSMQ storage path. The ZIP remains available.
if (-not $KeepUncompressed) {
    Remove-Item -LiteralPath $resultDirectory -Recurse -Force
}

# Remove the exact consumed cooperative stop marker so it cannot cancel a later run unintentionally.
# No wildcard is used. If the operator supplied a custom StopFilePath outside OutputRoot, that exact
# marker is also removed; inspectors should approve the chosen path before execution.
if (Test-Path -LiteralPath $StopFilePath) {
    Remove-Item -LiteralPath $StopFilePath -Force
}

# FINAL CONSOLE SUMMARY
# Display where the ZIP/pointer were written and how many read operations produced warnings. This
# is screen output only and has no effect on MSMQ or Windows configuration.
Write-Host ''
Write-Host ('Collection status: {0}' -f $collectionStatus) -ForegroundColor Green
Write-Host ('Archive: {0}' -f $archivePath)
Write-Host ('Result pointer: {0}' -f $latestResultPath)
Write-Host ('Individual checks with warnings: {0}' -f $script:Errors.Count)
Write-Host 'CLP must review the archive for customer-sensitive names and endpoints before sharing it.'