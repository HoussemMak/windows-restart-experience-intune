#Requires -Version 5.1
<#
.SYNOPSIS
    Collects timestamped, device-side evidence of what Windows Update actually did.

.DESCRIPTION
    Your tenant reports prove that a policy exists and is assigned. They do not prove that
    the device received it, applied it, or acted on it. Those are different claims.

    An assigned policy can fail to apply for reasons no tenant report shows: the device was
    offline, two policies collided and the device fell back to defaults, the MDM sync cycle
    stopped running, or a safeguard hold blocked the update. This script closes that gap by
    reading the device itself.

    It collects seven things:

      1. Real OS identity - build, UBR, DisplayVersion. DisplayVersion is the value that
         settles whether the feature update actually landed.
      2. MDM policy values actually present under PolicyManager, compared one by one against
         the values you expected. This is the only proof the policy reached the device.
      3. "Restart required" state from four independent sources. Only one of them is specific
         to Windows Update; the other three also fire on ordinary app installs. Starting a
         countdown on the wrong source is the classic mistake.
      4. The timestamp at which the device entered "restart required" - the T0 of the grace
         period, taken from the event log, because the registry key carries no usable date.
      5. Windows Update history via the WUA COM API.
      6. A 14-day timeline from the WindowsUpdateClient operational log.
      7. Restart-related System events and the MDM sync task state.

    WHY THE EVENT LOG AND NOT THE PORTAL
    Intune and Autopatch reporting has end-to-end latency that can reach several hours. It
    cannot serve as a stopwatch. The local event log can. If you are measuring a deadline or
    a grace period, the portal will tell you the wrong time.

    WHEN TO RUN IT
    Once per milestone of the cycle, not once at the end. The Intune floor for a feature
    update deadline is 2 days, so a full scenario takes 48 real hours. Without a timestamped
    reading at each milestone, those 48 hours produce nothing you can show, and you have to
    run them again. Instrument the device BEFORE you trigger the offer: with enablement
    packages the device can go from idle to "restart required" between two readings.

.PARAMETER Label
    Milestone label, carried into the report file name. Use it to tell readings apart within
    one run: 'T0', 'RestartRequired', 'T+24h', 'AfterReboot'.

.PARAMETER OutputPath
    Directory for the reports. Defaults to .\evidence next to this script.

.PARAMETER ExpectedValuesPath
    JSON file holding the expected device-side policy values. Defaults to
    expected-values.json next to this script. Pass an empty string to skip the comparison
    and collect only.

.PARAMETER AsJson
    Write the raw JSON reading to standard output and nothing else. Use this when piping the
    reading into your own tooling.

.PARAMETER Quiet
    Suppress console output. Reports are still written.

.EXAMPLE
    .\Get-UpdateEvidence.ps1 -Label T0
    Baseline reading, before triggering the update offer.

.EXAMPLE
    .\Get-UpdateEvidence.ps1 -Label RestartRequired
    Reading at the moment the device enters "restart required". This is the one that matters:
    it fixes the T0 of the grace period.

.EXAMPLE
    .\Get-UpdateEvidence.ps1 -AsJson | ConvertFrom-Json
    Raw reading, no reports, no console output.

.OUTPUTS
    <OutputPath>\Evidence-<timestamp>-<label>.json
    <OutputPath>\Evidence-<timestamp>-<label>.md

.NOTES
    Exit codes:
      0  every expected value matches, or no comparison was requested
      1  at least one expected value is missing or divergent
      2  the reading itself failed

    Run elevated when you can. Most readings work without elevation, but some event logs and
    scheduled task details are only fully readable as administrator.

    License: MIT. No warranty. Read it before you run it on a production device.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Label = 'reading',

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [AllowEmptyString()]
    [string]$ExpectedValuesPath,

    [Parameter()]
    [switch]$AsJson,

    [Parameter()]
    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# =================================================================================================
# Console output
# =================================================================================================

function Write-Log {
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [Parameter(Position = 1)][ValidateSet('Info', 'Success', 'Warning', 'Error', 'Step')][string]$Level = 'Info'
    )
    if ($Quiet -or $AsJson) { return }

    $decor = switch ($Level) {
        'Info'    { @{ Color = 'Gray';        Tag = '   ' } }
        'Success' { @{ Color = 'Green';       Tag = ' + ' } }
        'Warning' { @{ Color = 'Yellow';      Tag = ' ! ' } }
        'Error'   { @{ Color = 'Red';         Tag = ' x ' } }
        'Step'    { @{ Color = 'Cyan';        Tag = '==>' } }
    }
    Write-Host ('{0} {1}' -f $decor.Tag, $Message) -ForegroundColor $decor.Color
}

# =================================================================================================
# Collector - everything below reads the device and nothing else
# =================================================================================================

function Get-Safe {
    <#  try/catch is not an expression in PowerShell, so you cannot write
        'X = try {...} catch {...}' inside a hashtable. This helper makes read
        tolerance usable in a literal.  #>
    param([Parameter(Mandatory)][scriptblock]$Script)
    try { & $Script } catch { $null }
}

function Get-RegistryValues {
    param([Parameter(Mandatory)][string]$Path)
    $values = [ordered]@{}
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            return [ordered]@{ Present = $false; Values = $values }
        }
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        foreach ($p in $item.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $values[$p.Name] = $p.Value
        }
        return [ordered]@{ Present = $true; Values = $values }
    }
    catch {
        return [ordered]@{ Present = $false; Values = $values; Error = $_.Exception.Message }
    }
}

function Get-DeviceReading {

    # --- 1. OS identity ------------------------------------------------------------------
    # DisplayVersion is the value that settles the question. ProductName is unreliable:
    # on Windows 11 it frequently still reads "Windows 10 ...". Trust the build number.
    $cv = Get-Safe { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop }
    $os = [ordered]@{
        ComputerName    = $env:COMPUTERNAME
        ProductName     = Get-Safe { $cv.ProductName }
        DisplayVersion  = Get-Safe { $cv.DisplayVersion }
        CurrentBuild    = Get-Safe { $cv.CurrentBuild }
        UBR             = Get-Safe { $cv.UBR }
        FullBuild       = Get-Safe { '{0}.{1}' -f $cv.CurrentBuild, $cv.UBR }
        EditionID       = Get-Safe { $cv.EditionID }
        IsWindows11     = Get-Safe { [int]$cv.CurrentBuild -ge 22000 }
        InstallDateUtc  = Get-Safe { ([datetime]'1970-01-01Z').AddSeconds([int]$cv.InstallDate).ToString('o') }
        LastBootUtc     = Get-Safe { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o') }
    }

    # --- 2. MDM policy values actually received -------------------------------------------
    # A policy that is assigned in the tenant but absent here is not applied. This is the
    # only place that distinguishes "assigned" from "applied".
    $registry = [ordered]@{
        'PolicyManager.Update' = Get-RegistryValues 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'
        'WindowsUpdate.UX'     = Get-RegistryValues 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        'WindowsUpdate.Policy' = Get-RegistryValues 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\Settings'
        'GPO.WindowsUpdate'    = Get-RegistryValues 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        'GPO.WindowsUpdate.AU' = Get-RegistryValues 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    }

    # --- 3. Restart required, from four independent sources --------------------------------
    # None of these four is trustworthy on its own. Only WindowsUpdate.RebootRequired is
    # specific to Windows Update; the other three also fire on an application install or a
    # cumulative patch. If you are counting or timing anything, this is where you get it
    # wrong: you start the clock on a restart that has nothing to do with your update.
    $reboot = [ordered]@{
        'WindowsUpdate.RebootRequired' = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        'CBS.RebootPending'            = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'CBS.RebootInProgress'         = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'
        'PendingFileRenameOperations'  = [bool](Get-Safe {
                Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
            })
    }
    $reboot['AnySource'] = @($reboot.Values | Where-Object { $_ -eq $true }).Count -gt 0
    $reboot['WindowsUpdateOnly'] = $reboot['WindowsUpdate.RebootRequired']

    # Timestamp of the transition to "restart required" - the T0 of the grace period.
    # The registry key carries no usable date. Event 22 does.
    $reboot['RestartRequiredSinceUtc'] = Get-Safe {
        $evt = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'; Id = 22
        } -MaxEvents 1 -ErrorAction Stop
        if ($evt) { $evt.TimeCreated.ToUniversalTime().ToString('o') } else { $null }
    }

    # --- 4. Windows Update history (WUA COM) -----------------------------------------------
    $history = @()
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $total    = $searcher.GetTotalHistoryCount()
        if ($total -gt 0) {
            foreach ($h in $searcher.QueryHistory(0, [Math]::Min($total, 40))) {
                $history += [ordered]@{
                    DateUtc    = Get-Safe { $h.Date.ToUniversalTime().ToString('o') }
                    Title      = Get-Safe { $h.Title }
                    Operation  = switch ([int](Get-Safe { $h.Operation })) { 1 { 'Install' } 2 { 'Uninstall' } default { 'Other' } }
                    ResultCode = switch ([int](Get-Safe { $h.ResultCode })) {
                        1 { 'InProgress' } 2 { 'Succeeded' } 3 { 'SucceededWithErrors' }
                        4 { 'Failed' } 5 { 'Aborted' } default { 'Unknown' }
                    }
                    HResult    = Get-Safe { '0x{0:X8}' -f $h.HResult }
                }
            }
        }
    }
    catch {
        $history = @([ordered]@{ Error = "WUA history unreadable: $($_.Exception.Message)" })
    }

    # --- 5. WindowsUpdateClient timeline, 14 days ------------------------------------------
    # This is the stopwatch. Portal reporting is not.
    $timeline = @()
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-WindowsUpdateClient/Operational'
            StartTime = (Get-Date).AddDays(-14)
        } -ErrorAction Stop | Sort-Object TimeCreated
        foreach ($e in $events) {
            $timeline += [ordered]@{
                TimeUtc = $e.TimeCreated.ToUniversalTime().ToString('o')
                Id      = $e.Id
                Level   = $e.LevelDisplayName
                Message = ($e.Message -split "`r?`n")[0]
            }
        }
    }
    catch {
        $timeline = @([ordered]@{ Error = "WindowsUpdateClient log unreadable: $($_.Exception.Message)" })
    }

    # --- 6. Restart-related System events --------------------------------------------------
    # 1074 = restart initiated by a process, with the reason. 6005/6006 = log start/stop.
    # 6008 = unexpected shutdown. 41 = kernel power, the machine went down hard.
    # Together they show whether restarts happened on schedule or were forced.
    $systemEvents = @()
    try {
        $systemEvents = @(Get-WinEvent -FilterHashtable @{
                LogName   = 'System'
                Id        = 1074, 6005, 6006, 6008, 41
                StartTime = (Get-Date).AddDays(-14)
            } -ErrorAction Stop | Sort-Object TimeCreated | ForEach-Object {
                [ordered]@{
                    TimeUtc = $_.TimeCreated.ToUniversalTime().ToString('o')
                    Id      = $_.Id
                    Source  = $_.ProviderName
                    Message = ($_.Message -split "`r?`n")[0]
                }
            })
    }
    catch { $systemEvents = @() }

    # --- 7. MDM enrolment health -----------------------------------------------------------
    # A device whose sync cycle has stopped will never receive the policy, however correct
    # the tenant is. Check this before blaming the policy.
    $mdm = [ordered]@{}
    try {
        $task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskName -like '*Schedule*' } | Select-Object -First 1
        if ($task) {
            $info = $task | Get-ScheduledTaskInfo
            $mdm['SyncTask']    = $task.TaskName
            $mdm['LastSyncUtc'] = Get-Safe { $info.LastRunTime.ToUniversalTime().ToString('o') }
            $mdm['LastResult']  = Get-Safe { $info.LastTaskResult }
        }
        else { $mdm['SyncTask'] = '(no EnterpriseMgmt task found - device may not be MDM enrolled)' }
    }
    catch { $mdm['Error'] = $_.Exception.Message }

    return [ordered]@{
        SchemaVersion  = 1
        CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Label          = $Label
        Os             = $os
        Registry       = $registry
        RebootRequired = $reboot
        UpdateHistory  = $history
        Timeline       = $timeline
        SystemEvents   = $systemEvents
        Mdm            = $mdm
    }
}

# =================================================================================================
# Comparison against expected values
# =================================================================================================

function Get-LegacyPolicyFindings {
    <#
        The five notification-shaping policies below are documented by Microsoft as legacy
        and NOT applicable to Windows 11. They may still be written into PolicyManager by
        the MDM channel on a Windows 11 device - and do nothing.

        That is the trap this whole repository exists to name: delivered, applied and
        honoured are three different claims. A collector that reports these as "OK" because
        it found them in the registry is manufacturing false confidence. So we report them
        separately, and on Windows 11 we say plainly that presence proves nothing.
    #>
    param([Parameter(Mandatory)]$Reading)

    $legacyNames = @(
        'ScheduleRestartWarning'
        'ScheduleImminentRestartWarning'
        'AutoRestartNotificationSchedule'
        'AutoRestartRequiredNotificationDismissal'
        'SetAutoRestartNotificationDisable'
        'EngagedRestartDeadline'
        'EngagedRestartDeadlineForFeatureUpdates'
        'EngagedRestartSnoozeSchedule'
        'EngagedRestartSnoozeScheduleForFeatureUpdates'
        'EngagedRestartTransitionSchedule'
        'EngagedRestartTransitionScheduleForFeatureUpdates'
    )

    $actual = $Reading.Registry.'PolicyManager.Update'.Values
    $found = @()
    foreach ($name in $legacyNames) {
        if ($actual.Contains($name)) {
            $found += [ordered]@{ Setting = $name; Value = $actual[$name] }
        }
    }
    return $found
}

function Compare-ExpectedValues {
    param(
        [Parameter(Mandatory)]$Reading,
        [Parameter(Mandatory)]$Expected
    )
    $rows = @()
    $actual = $Reading.Registry.'PolicyManager.Update'.Values

    foreach ($p in $Expected.PSObject.Properties) {
        $name     = $p.Name
        $want     = $p.Value
        $havePropertyPresent = $actual.Contains($name)
        $have     = if ($havePropertyPresent) { $actual[$name] } else { $null }

        $status =
            if (-not $havePropertyPresent) { 'MISSING' }
            elseif ("$have" -eq "$want")   { 'OK' }
            else                           { 'DIVERGENT' }

        $rows += [ordered]@{
            Setting  = $name
            Expected = $want
            Actual   = if ($havePropertyPresent) { $have } else { '(absent)' }
            Status   = $status
        }
    }
    return $rows
}

# =================================================================================================
# Markdown report
# =================================================================================================

function ConvertTo-MarkdownReport {
    param(
        [Parameter(Mandatory)]$Reading,
        [Parameter()]$Comparison,
        [Parameter()]$LegacyFindings
    )
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine("# Update evidence - ``$($Reading.Label)``")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("**Device**: ``$($Reading.Os.ComputerName)`` &nbsp;|&nbsp; **Collected**: $($Reading.CollectedAtUtc)")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('> This reading states what the DEVICE received and applied. It says nothing about')
    $null = $sb.AppendLine('> what the tenant is configured to do - those are different claims.')
    $null = $sb.AppendLine()

    # --- OS
    $null = $sb.AppendLine('## 1. Operating system')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('| Field | Value |')
    $null = $sb.AppendLine('|---|---|')
    $null = $sb.AppendLine("| Display version | **$($Reading.Os.DisplayVersion)** |")
    $null = $sb.AppendLine("| Full build | $($Reading.Os.FullBuild) |")
    $null = $sb.AppendLine("| Edition | $($Reading.Os.EditionID) |")
    $null = $sb.AppendLine("| Product name (registry) | $($Reading.Os.ProductName) |")
    $null = $sb.AppendLine("| Windows 11 (build >= 22000) | $(if ($Reading.Os.IsWindows11) { 'yes' } else { 'no' }) |")
    $null = $sb.AppendLine("| Last boot | $($Reading.Os.LastBootUtc) |")
    $null = $sb.AppendLine()
    if ($Reading.Os.ProductName -like '*Windows 10*' -and $Reading.Os.IsWindows11) {
        $null = $sb.AppendLine('> Note: `ProductName` still reads "Windows 10" on many Windows 11 devices. The build')
        $null = $sb.AppendLine('> number is authoritative, not this string.')
        $null = $sb.AppendLine()
    }

    # --- Expected values
    if ($Comparison) {
        $null = $sb.AppendLine('## 2. Expected policy values, as received by the device')
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('| Setting | Expected | Actual | Status |')
        $null = $sb.AppendLine('|---|---|---|---|')
        foreach ($r in $Comparison) {
            $mark = switch ($r.Status) { 'OK' { 'OK' } 'MISSING' { '**MISSING**' } default { '**DIVERGENT**' } }
            $null = $sb.AppendLine("| ``$($r.Setting)`` | $($r.Expected) | $($r.Actual) | $mark |")
        }
        $null = $sb.AppendLine()
        $drift = @($Comparison | Where-Object { $_.Status -ne 'OK' }).Count
        if ($drift -eq 0) {
            $null = $sb.AppendLine('> Every expected value is present on the device. The policy reached it and applied.')
        }
        else {
            $null = $sb.AppendLine("> $drift value(s) missing or divergent. A policy that is assigned in the tenant but")
            $null = $sb.AppendLine('> absent here has not applied. Check for a competing policy redefining the same CSP,')
            $null = $sb.AppendLine('> an MDM sync that stopped running, or a device that was offline.')
        }
        $null = $sb.AppendLine()
    }

    # --- Legacy policies actually on the device
    if ($LegacyFindings -and @($LegacyFindings).Count -gt 0) {
        $null = $sb.AppendLine('## 2b. Legacy policies present on this device')
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('| Setting | Value on device |')
        $null = $sb.AppendLine('|---|---|')
        foreach ($f in $LegacyFindings) {
            $null = $sb.AppendLine("| ``$($f.Setting)`` | $($f.Value) |")
        }
        $null = $sb.AppendLine()
        if ($Reading.Os.IsWindows11) {
            $null = $sb.AppendLine('> **This device is Windows 11, and these are legacy policies.** Microsoft documents')
            $null = $sb.AppendLine('> them as not applicable to Windows 11 and liable to removal. They were delivered')
            $null = $sb.AppendLine('> into the registry by the MDM channel. That is all their presence proves.')
            $null = $sb.AppendLine('>')
            $null = $sb.AppendLine('> **Do not read this table as evidence that they work.** Delivered, applied and')
            $null = $sb.AppendLine('> honoured are three different claims, and only the first is shown here. If your')
            $null = $sb.AppendLine('> restart experience depends on these values, it rests on nothing supported.')
            $null = $sb.AppendLine('> Enforcement must come from the `ConfigureDeadline*` family instead.')
        }
        else {
            $null = $sb.AppendLine('> This device is not Windows 11, so these legacy policies remain applicable to it.')
            $null = $sb.AppendLine('> They are still legacy: Microsoft may remove them in a future release. Do not')
            $null = $sb.AppendLine('> build anything new on them.')
        }
        $null = $sb.AppendLine()
    }

    # --- Reboot
    $null = $sb.AppendLine('## 3. Restart required')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('| Source | Specific to Windows Update | State |')
    $null = $sb.AppendLine('|---|---|---|')
    $null = $sb.AppendLine("| ``WindowsUpdate.RebootRequired`` | yes | $(if ($Reading.RebootRequired.'WindowsUpdate.RebootRequired') { '**yes**' } else { 'no' }) |")
    $null = $sb.AppendLine("| ``CBS.RebootPending`` | no | $(if ($Reading.RebootRequired.'CBS.RebootPending') { 'yes' } else { 'no' }) |")
    $null = $sb.AppendLine("| ``CBS.RebootInProgress`` | no | $(if ($Reading.RebootRequired.'CBS.RebootInProgress') { 'yes' } else { 'no' }) |")
    $null = $sb.AppendLine("| ``PendingFileRenameOperations`` | no | $(if ($Reading.RebootRequired.'PendingFileRenameOperations') { 'yes' } else { 'no' }) |")
    $null = $sb.AppendLine()
    if ($Reading.RebootRequired.RestartRequiredSinceUtc) {
        $null = $sb.AppendLine("**Entered ``restart required`` at**: $($Reading.RebootRequired.RestartRequiredSinceUtc) (event 22)")
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('> This is the T0 of the grace period. `EffectiveDeadline = MAX(firstDetected + deadline,')
        $null = $sb.AppendLine('> restartRequired + gracePeriod)`.')
    }
    elseif ($Reading.RebootRequired.AnySource -and -not $Reading.RebootRequired.WindowsUpdateOnly) {
        $null = $sb.AppendLine('> A restart is pending, but **not** from Windows Update. Something else - an application')
        $null = $sb.AppendLine('> install or a servicing operation - set one of the three generic sources. Do not start')
        $null = $sb.AppendLine('> an update countdown on this signal.')
    }
    else {
        $null = $sb.AppendLine('> No `restart required` event found. Either the cycle has not reached that stage, or the')
        $null = $sb.AppendLine('> log has rolled over.')
    }
    $null = $sb.AppendLine()

    # --- History
    $null = $sb.AppendLine('## 4. Windows Update history')
    $null = $sb.AppendLine()
    if ($Reading.UpdateHistory.Count -gt 0 -and -not ($Reading.UpdateHistory[0].Contains('Error'))) {
        $null = $sb.AppendLine('| Date (UTC) | Operation | Result | Title |')
        $null = $sb.AppendLine('|---|---|---|---|')
        foreach ($h in ($Reading.UpdateHistory | Select-Object -First 20)) {
            $null = $sb.AppendLine("| $($h.DateUtc) | $($h.Operation) | $($h.ResultCode) | $($h.Title) |")
        }
    }
    else { $null = $sb.AppendLine('_No readable history._') }
    $null = $sb.AppendLine()

    # --- Timeline
    $null = $sb.AppendLine('## 5. WindowsUpdateClient timeline (14 days)')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('> Use this, not the portal. Tenant reporting latency can reach several hours and cannot')
    $null = $sb.AppendLine('> serve as a stopwatch.')
    $null = $sb.AppendLine()
    if ($Reading.Timeline.Count -gt 0 -and -not ($Reading.Timeline[0].Contains('Error'))) {
        $null = $sb.AppendLine('| Time (UTC) | Id | Level | Message |')
        $null = $sb.AppendLine('|---|---|---|---|')
        foreach ($t in ($Reading.Timeline | Select-Object -Last 40)) {
            $null = $sb.AppendLine("| $($t.TimeUtc) | $($t.Id) | $($t.Level) | $($t.Message) |")
        }
    }
    else { $null = $sb.AppendLine('_No readable events._') }
    $null = $sb.AppendLine()

    # --- System events
    $null = $sb.AppendLine('## 6. Restart events (System log)')
    $null = $sb.AppendLine()
    if ($Reading.SystemEvents.Count -gt 0) {
        $null = $sb.AppendLine('| Time (UTC) | Id | Source | Message |')
        $null = $sb.AppendLine('|---|---|---|---|')
        foreach ($e in ($Reading.SystemEvents | Select-Object -Last 25)) {
            $null = $sb.AppendLine("| $($e.TimeUtc) | $($e.Id) | $($e.Source) | $($e.Message) |")
        }
    }
    else { $null = $sb.AppendLine('_No restart events in the window._') }
    $null = $sb.AppendLine()

    # --- MDM
    $null = $sb.AppendLine('## 7. MDM enrolment')
    $null = $sb.AppendLine()
    foreach ($k in $Reading.Mdm.Keys) {
        $null = $sb.AppendLine("- **$k**: $($Reading.Mdm[$k])")
    }
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('---')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('_Generated by Get-UpdateEvidence.ps1._')

    return $sb.ToString()
}

# =================================================================================================
# Main
# =================================================================================================

$exitCode = 0

try {
    if (-not $PSBoundParameters.ContainsKey('OutputPath') -or [string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = Join-Path $PSScriptRoot 'evidence'
    }
    if (-not $PSBoundParameters.ContainsKey('ExpectedValuesPath')) {
        $ExpectedValuesPath = Join-Path $PSScriptRoot 'expected-values.json'
    }

    Write-Log 'Collecting device-side update evidence.' Step
    $reading = Get-DeviceReading

    if ($AsJson) {
        $reading | ConvertTo-Json -Depth 8 -Compress
        exit 0
    }

    # --- Comparison
    $comparison = $null
    if (-not [string]::IsNullOrWhiteSpace($ExpectedValuesPath)) {
        if (Test-Path -LiteralPath $ExpectedValuesPath) {
            $expectedFile = Get-Content -LiteralPath $ExpectedValuesPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $expected = $expectedFile.expectedDeviceRegistry

            # The legacy block is opt-in and Windows 10 only. Merging it into the supported
            # baseline on a Windows 11 device is exactly how you end up reporting a green
            # result for policies the OS ignores.
            $legacyBlock = $expectedFile.PSObject.Properties['legacyWindows10Only']
            if ($legacyBlock -and $legacyBlock.Value -and $legacyBlock.Value.enabled) {
                if ($reading.Os.IsWindows11) {
                    Write-Log 'legacyWindows10Only is enabled but this device is Windows 11. Those policies are not applicable here; comparing them would manufacture false confidence. Skipping them.' Warning
                }
                elseif ($legacyBlock.Value.settings) {
                    foreach ($p in $legacyBlock.Value.settings.PSObject.Properties) {
                        $expected | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
                    }
                    Write-Log 'legacyWindows10Only merged in - device is not Windows 11.' Info
                }
            }

            if ($expected) {
                $comparison = Compare-ExpectedValues -Reading $reading -Expected $expected
                $drift = @($comparison | Where-Object { $_.Status -ne 'OK' }).Count
                if ($drift -gt 0) { $exitCode = 1 }
            }
            else { Write-Log "No 'expectedDeviceRegistry' object in $ExpectedValuesPath - comparison skipped." Warning }
        }
        else { Write-Log "Expected-values file not found: $ExpectedValuesPath - comparison skipped." Warning }

        # Independent of what you asked for: report any legacy policy actually sitting on the
        # device. On Windows 11 this is the finding that matters most.
        $legacyFindings = Get-LegacyPolicyFindings -Reading $reading
    }

    # --- Write reports
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeLabel = ($Label -replace '[^\w\-\.]', '-')
    $jsonPath = Join-Path $OutputPath "Evidence-$stamp-$safeLabel.json"
    $mdPath   = Join-Path $OutputPath "Evidence-$stamp-$safeLabel.md"

    $payload = [ordered]@{ Reading = $reading; Comparison = $comparison; LegacyPolicies = $legacyFindings }
    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    ConvertTo-MarkdownReport -Reading $reading -Comparison $comparison -LegacyFindings $legacyFindings |
        Set-Content -LiteralPath $mdPath -Encoding UTF8

    # --- Console summary
    Write-Log "JSON reading : $jsonPath" Success
    Write-Log "Markdown     : $mdPath" Success
    Write-Log ''
    Write-Log "OS: $($reading.Os.DisplayVersion) build $($reading.Os.FullBuild)"
    Write-Log "Restart required: $(if ($reading.RebootRequired.AnySource) { 'YES' } else { 'no' })$(if ($reading.RebootRequired.AnySource -and -not $reading.RebootRequired.WindowsUpdateOnly) { ' (not from Windows Update)' })"
    if ($reading.RebootRequired.RestartRequiredSinceUtc) {
        Write-Log "Restart required since: $($reading.RebootRequired.RestartRequiredSinceUtc)"
    }
    if ($comparison) {
        if ($exitCode -eq 0) { Write-Log 'All expected policy values are present on the device.' Success }
        else { Write-Log 'At least one expected policy value is missing or divergent on the device.' Warning }
    }
    if ($legacyFindings -and @($legacyFindings).Count -gt 0 -and $reading.Os.IsWindows11) {
        Write-Log ''
        Write-Log "$(@($legacyFindings).Count) legacy policy value(s) present on this Windows 11 device." Warning
        Write-Log 'They were delivered, which does not mean Windows honours them. See section 2b of the report.' Warning
    }
}
catch {
    Write-Log "Reading failed: $($_.Exception.Message)" Error
    $exitCode = 2
}

exit $exitCode
