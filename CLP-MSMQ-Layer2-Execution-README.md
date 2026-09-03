# CLP MSMQ Layer 2 Execution README

> **Collection scope:** A complete list of the information collected by the
> PowerShell script is provided at the bottom of this README under
> **Appendix: Information Collected by the Layer 2 Collector**. The collector
> is read-only and does not collect MSMQ message bodies.

## Files

| Purpose | File |
| --- | --- |
| PowerShell collector v1.2.6 | `Collect-CLP-MsmqDiscovery.ps1` |
| SRE Agent analysis instructions | `CLP-MSMQ-Layer2-Guest-Evidence-Prompt.txt` |

Source collector path:

```text
C:\Users\wanming\OneDrive - Microsoft\Documents\Customers\CLP\SRE Agent\SMP SRE agent result\SMP SRE agent result\Collect-CLP-MsmqDiscovery.ps1
```

Collector v1.2.6 SHA-256:

```text
ECC2A15FD4EE33404A0F6E6AE9C0513C57BFAB8B4A6A3BB63780A8E83FD1C811
```

The script filename is stable and does not contain the version. Version `1.2.6` is embedded in `$script:ScriptVersion` and is written into `manifest.json` and the latest-result pointer after execution.

## Execution Sequence

```text
Copy collector to approved VM
        |
Run read-only safety pilot on one active AAPP and one active SBS VM
        |
Review ZIP contents, warnings, collection impact, and sensitive information
        |
After CLP approval, run static collection on all remaining active receivers
        |
Collect and review every per-VM ZIP and latest-result JSON pointer
        |
Upload the approved ZIPs and pointers to one SRE Agent thread
        |
Submit the Layer 2 Guest Evidence Prompt once
        |
SRE Agent correlates all receivers and produces the Layer 2 findings
```

Do not run the SRE Agent prompt after each VM. Complete the approved VM collection first, then analyze all bundles together so AAPP and SBS receivers can be compared within their respective pools.

## 1. Copy the Collector to Each VM

Use the customer-approved software-transfer method. Do not download the collector from the Internet on a production VM.

Recommended staging folder on each MSMQ VM:

```text
C:\CLP\MSMQ-Discovery
```

Create the folder and place the script at:

```text
C:\CLP\MSMQ-Discovery\Collect-CLP-MsmqDiscovery.ps1
```

Open an elevated **64-bit Windows PowerShell 5.1** window and run:

```powershell
New-Item -Path 'C:\CLP\MSMQ-Discovery' -ItemType Directory -Force
Set-Location 'C:\CLP\MSMQ-Discovery'

Get-FileHash .\Collect-CLP-MsmqDiscovery.ps1 -Algorithm SHA256
Select-String .\Collect-CLP-MsmqDiscovery.ps1 -Pattern 'ScriptVersion'
```

Confirm:

```text
SHA-256: ECC2A15FD4EE33404A0F6E6AE9C0513C57BFAB8B4A6A3BB63780A8E83FD1C811
Version: 1.2.6
```

Stop if either value differs.

## 2. Run the Two-VM Safety Pilot

Pilot on:

- One active AAPP receiver
- One active SBS receiver

Do not start `VSMPSBS-EASP04` solely for collection if it remains deallocated.

Run the static collector without timed performance capture:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Unblock-File .\Collect-CLP-MsmqDiscovery.ps1

.\Collect-CLP-MsmqDiscovery.ps1 `
    -EventLookbackDays 30 `
    -SkipPerformanceCapture `
    -KeepUncompressed
```

`-KeepUncompressed` is recommended for the pilot so CLP can inspect both the generated ZIP and its expanded files. The collector is read-only against MSMQ, services, registry, queues, firewall, routes, and application configuration. It writes only its local evidence outputs.

## 3. Locate the Results on the VM

Default result folder:

```text
C:\ProgramData\CLP\MSMQ-Discovery
```

Per-VM ZIP naming pattern:

```text
CLP-MSMQ-Discovery-<HOSTNAME>-<UTC-TIMESTAMP>.zip
```

Example:

```text
C:\ProgramData\CLP\MSMQ-Discovery\CLP-MSMQ-Discovery-VSMPAAPP-EASP01-20260818T090000Z.zip
```

Latest-result pointer:

```text
C:\ProgramData\CLP\MSMQ-Discovery\CLP-MSMQ-Discovery-<HOSTNAME>-latest-result.json
```

The pointer records:

- Collection status
- Computer name
- Script version
- Start and finish UTC times
- Exact ZIP path
- ZIP SHA-256
- Warning count

When `-KeepUncompressed` is used, the expanded timestamped result folder remains beside the ZIP. Without that switch, the collector removes the expanded folder after creating the ZIP; the ZIP and latest-result pointer remain.

## 4. Validate and Review Each Result

Run on the VM:

```powershell
$resultRoot = 'C:\ProgramData\CLP\MSMQ-Discovery'
$pointerPath = Get-ChildItem -Path $resultRoot `
    -Filter 'CLP-MSMQ-Discovery-*-latest-result.json' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 -ExpandProperty FullName

$pointer = Get-Content -LiteralPath $pointerPath -Raw | ConvertFrom-Json
$actualHash = (Get-FileHash -LiteralPath $pointer.ArchivePath -Algorithm SHA256).Hash

$pointer | Format-List
"ZIP exists: $([bool](Test-Path -LiteralPath $pointer.ArchivePath))"
"ZIP hash matches pointer: $($actualHash -eq $pointer.ArchiveSHA256)"
```

CLP must review the ZIP before transfer because it can contain customer-sensitive hostnames, queue names, paths, IP addresses, service accounts, event messages, and endpoint hints. It does not intentionally collect message bodies, credentials, private keys, or secrets.

Review at minimum:

- `manifest.json`
- `collection-errors.csv`
- `file-hashes.csv`
- `msmq-queues.csv`
- `listener-owners.csv`
- `tcp-connections.csv`
- `services.csv` and `processes.csv`
- IIS, HTTP.sys, configuration and endpoint-hint files
- MSMQ/Application/System event exports

Confirm the pilot caused no service disruption, sustained resource pressure, endpoint-security alert, or unacceptable collection delay.

## 5. Run Static Collection on the Remaining Active Receivers

After CLP approves the pilot, repeat on every remaining active receiver:

```powershell
Set-Location 'C:\CLP\MSMQ-Discovery'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Unblock-File .\Collect-CLP-MsmqDiscovery.ps1

.\Collect-CLP-MsmqDiscovery.ps1 `
    -EventLookbackDays 30 `
    -SkipPerformanceCapture
```

Expected active receiver scope:

### AAPP

- `VSMPAAPP-EASP01`
- `VSMPAAPP-EASP02`
- `VSMPAAPP-EASP03`
- `VSMPAAPP-EASP04`

### SBS

- `VSMPSBS-EASP01`
- `VSMPSBS-EASP02`
- `VSMPSBS-EASP03`
- `VSMPSBS-EASP04` only if it is running normally and CLP approves collection

Do not start a deallocated receiver only to complete the evidence set. Record the missing bundle as unavailable due to deallocated state.

## 6. Transfer the Approved Evidence

For each collected VM, transfer both files through the approved channel:

1. `CLP-MSMQ-Discovery-<HOST>-<UTC>.zip`
2. `CLP-MSMQ-Discovery-<HOST>-latest-result.json`

Keep each ZIP unchanged after hash validation. Do not rename or recompress it, because the pointer contains its original name and SHA-256.

## 7. Analyze the Bundles in Azure SRE Agent

After all approved bundles are available:

1. Open one SRE Agent thread for the Layer 2 investigation.
2. Upload every approved per-VM ZIP and latest-result pointer.
3. Upload or paste the contents of:

   ```text
   CLP-MSMQ-Layer2-Guest-Evidence-Prompt.txt
   ```

4. Instruct SRE Agent to execute that prompt against all uploaded bundles.
5. Run the prompt once for the complete evidence set.

The Layer 2 prompt directs SRE Agent to:

- Build the queue inventory and queue-depth view
- Identify business-consumer service and process candidates
- Determine whether TCP 443/808 application ingress writes to local MSMQ or whether producers use native/direct MSMQ addressing
- Explain why AAPP01 has materially more inbound flows than AAPP02
- Compare AAPP01/03 with AAPP02 across listeners, producer tuples, queues, services, binaries, configuration, transactions and downstream dependencies
- Treat SBS01-03 as comparatively balanced unless guest evidence proves otherwise
- Detect per-host service, queue, binary, configuration, firewall, route, transaction and endpoint-security drift
- Produce the Layer 3 measurement plan only for questions that still require coordinated runtime evidence

Datadog is excluded from the current Layer 2 scope unless CLP explicitly approves it later.

## 8. Dynamic Capture Is a Separate Later Step

Do not enable performance capture merely to complete Layer 2. Layer 2 static discovery should be analyzed first.

If Layer 2 identifies a decision that requires runtime correlation, schedule Layer 3 during a naturally busy period and run the collector across all active receivers within one coordinated window. Use confirmed consumer process names with `-ProcessNames` when available.

## Completion Checklist

- [ ] Collector source hash equals the approved v1.2.6 SHA-256
- [ ] Embedded script version reports `1.2.6`
- [ ] Pilot completed on one active AAPP and one active SBS receiver
- [ ] Pilot ZIPs reviewed for impact, warnings and sensitive information
- [ ] Static collection approved for remaining active receivers
- [ ] One ZIP and one latest-result pointer retained per collected VM
- [ ] Every ZIP hash matches its pointer
- [ ] Deallocated receivers were not started solely for collection
- [ ] All approved bundles were uploaded to one SRE Agent thread
- [ ] Layer 2 prompt was run once against the complete bundle set
- [ ] Datadog was not used without explicit CLP approval

## Appendix: Information Collected by the Layer 2 Collector

### Collection Metadata and Integrity

- Computer name and executing user
- Collector name and embedded version
- Administrator/elevation state
- Collection start and finish UTC
- Event collection window
- Performance-capture settings and selected process names
- Completed, failed, skipped, or cancelled collection sections
- Collection warnings and errors
- File names, sizes, and SHA-256 hashes
- Final ZIP path and SHA-256 in the latest-result pointer

### MSMQ Configuration and Queue Inventory

- MSMQ Windows service state
- Installed MSMQ Windows features
- Private queue names, paths, and format names
- Current queue `MessageCount`
- Queue transactional and journaling settings
- Queue quota, journal quota, labels, and multicast configuration
- MSMQ machine quota and default outgoing-queue quota
- Reliable log, log, journal, dead-letter, and persistent-storage paths

The collector does not read or export MSMQ message bodies.

### MSMQ Runtime and Delivery State

- Available formatted MSMQ performance information
- Incoming/private queue depth where exposed
- Outgoing queue destination, state, message count, next hop, and last error
- Dead-letter, transactional dead-letter, journal, retry, and error evidence
- MSMQ-related Windows event records

### Business Consumer Discovery

Windows services:

- Service name and display name
- State and startup mode
- Service account
- Executable path
- Process ID and exit code

Running processes:

- Process name and executable path
- Parent process
- Creation time
- Thread count and working set

Service executables:

- File version and product version
- SHA-256 for cross-host drift comparison

Scheduled tasks:

- Non-Microsoft and message-related task names
- Task action, run identity, state, trigger, and last result

### Application Configuration and Endpoint Hints

- Application configuration-file inventory
- Configuration file hashes for cross-host drift comparison
- Sanitized connection-string endpoint fields
- Application settings related to endpoints, destinations, hosts, queues,
  format names, URIs, URLs, VIPs, and ports
- WCF client and service endpoints
- HTTP and HTTPS URLs
- SQL/database server and database names
- Hostnames, IP addresses, and UNC/file-share paths
- MSMQ format names and direct-addressing hints

The collector attempts to redact obvious passwords, secrets, tokens, account
keys, shared-access signatures, and credential-bearing URLs. CLP must still
review the ZIP before transfer.

### Network Connections and Listener Ownership

- Listening and established TCP connections
- Local/remote addresses and ports
- Connection state and owning process
- Listener-to-PID, executable, and Windows-service ownership
- Evidence for listeners such as TCP 443, TCP 808, and TCP 1801
- UDP endpoints and owning processes
- Network-adapter configuration
- IPv4 and IPv6 routes
- DNS client cache
- Windows hosts-file overrides
- MSMQ-related Windows Firewall rules
- Firewall port filters and address filters

### IIS and HTTP.sys Evidence

When IIS is installed:

- IIS websites, bindings, ports, applications, and physical paths
- IIS configuration inventory and sanitized endpoint hints
- Deployed `.svc` files

HTTP.sys evidence:

- HTTP service state
- URL ACL registrations
- SSL certificate bindings

This evidence is used to determine whether TCP 443/808 application ingress
could write to a local MSMQ queue. A deployed `.svc` file or open port alone
does not prove production traffic or a queue write.

### Storage and Capacity

- Logical volumes, drive letters, filesystems, capacity, and free space
- Physical disk information
- MSMQ storage-path-to-volume mapping
- Queue and machine quota evidence

Layer 1 supplies the Azure P10/P20 disk context. Layer 2 establishes the actual
Windows paths and volumes used by MSMQ.

### Transactions and MSDTC

- MSDTC service state
- Available MSDTC configuration and network settings
- Transaction-related Windows events
- Timeout, abort, coordinator, authentication, and name-resolution evidence

MSDTC installation or enablement does not prove that a business consumer uses
a distributed transaction.

### Endpoint Security

- Microsoft Defender exclusions
- Coverage of verified MSMQ storage paths and candidate consumer executables
- Installed-software evidence that may identify a third-party EDR product

The collector does not retrieve the authoritative policy of a third-party EDR.

### Monitoring and Azure Guest Agents

- Azure VM extension status visible inside the guest
- Azure Monitor Agent indicators
- Dependency Agent indicators
- Azure diagnostics extension indicators
- Legacy Microsoft Monitoring Agent indicators
- Installed monitoring services and processes

Extension presence or handler success does not prove telemetry ingestion or
counter coverage.

### Windows Events

Bounded records from relevant Windows logs, including:

- MSMQ operational events
- MSMQ-related Application events
- Relevant System events
- Service failures and restarts
- Queue and outgoing-delivery errors
- Transaction and MSDTC errors
- Authentication and name-resolution failures

Event messages can contain customer-sensitive names, paths, addresses, and
application details and therefore require CLP review before transfer.

### Optional Passive Performance Capture

The initial Layer 2 pilot and static fleet collection use
`-SkipPerformanceCapture`. If CLP later approves a coordinated Layer 3 capture,
the collector can record:

- Total CPU utilization
- Available memory and paging
- Logical-disk free space
- Disk read/write latency
- Current disk queue length
- Disk transfers and bytes per second
- Available MSMQ performance counters
- Selected consumer-process CPU
- Selected consumer-process thread count
- Selected consumer-process I/O

### Explicitly Not Collected or Performed

- MSMQ message bodies
- Intentional collection of passwords, private keys, or secrets
- Active or synthetic test messages
- Packet captures
- Remote commands or remote registry access
- Queue receive, purge, deletion, creation, or modification
- Service restart, stop, start, or configuration change
- Registry, firewall, route, DNS, or application changes
- Network connection tests against downstream systems
- Azure resource changes
- Datadog queries or Datadog evidence
