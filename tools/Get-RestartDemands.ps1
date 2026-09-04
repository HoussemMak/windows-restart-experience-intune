#Requires -Version 5.1
<#
.SYNOPSIS
    How many separate things on this device are asking for a restart, and since when.

.DESCRIPTION
    A device does not have "a" pending restart. It has a queue of independent demands, each
    made by a different part of the stack, each with its own idea of how to get one, and none
    of them aware of the others.

    Deploy four Win32 apps in one wave and each can raise its own restart negotiation, with
    its own grace period and its own countdown. Add a feature update, a servicing operation
    and a security policy waiting to take effect, and the user is interrupted several times
    for a single physical restart. Intune does not coalesce them, because nothing in Intune
    sees them all at once.

    This script does. It is the inventory a single restart authority needs before it can
    replace N negotiations with one, and it is worth running on its own: when someone asks
    "why does this machine keep wanting to reboot", this answers it in one line.

    SOURCES, each reported separately rather than OR'd into a single boolean:

      WindowsUpdate  the Windows Update COM signal and its registry key, dated from event 22
      CBS            component servicing - RebootPending / RebootInProgress
      FileRename     PendingFileRenameOperations, with the number of queued operations
      IntuneApp      per Win32 app, from the Intune Management Extension: RebootStatus,
                     RebootReason and RebootSetTimeUTC. One entry per app that wants one
      Config         security configuration applied but not in effect until a restart,
                     from Win32_DeviceGuard configured-versus-running

    ON THE INTUNE APP SOURCE. The IME registry exposes RebootStatus, RebootReason and
    RebootSetTimeUTC per application. Observed value when nothing is pending: RebootStatus
    "Clean", RebootReason "None", RebootSetTimeUTC the 1/1/0001 null sentinel. The full set of
    non-Clean values is not documented, so this script does not pretend to know it: anything
    that is not Clean or empty is reported with its raw value. Better an unfamiliar string in
    the report than a demand silently dropped because it did not match a guessed enum.

.PARAMETER MinDemandsToFlag
    Number of distinct demands at which the device is worth surfacing. Default 2 - one demand
    is normal, two or more is where coalescing starts paying for itself.

.OUTPUTS
    One compact line, verdict first.

        NONE | no restart demand
        SINGLE | 1 demand | WindowsUpdate(0.4d)
        COALESCE | 3 demands, oldest 9.1d | WindowsUpdate(9.1d); IntuneApp:407e33e3(2.0d); Config:MemoryIntegrity

.NOTES
    Exit codes for Intune Remediations:
      0  fewer demands than the threshold
      1  at or above the threshold - this device is being asked to restart by several things

    Enable "Run script in 64-bit PowerShell". Read-only.

    App identifiers are reported as the leading segment of the Intune app GUID. Resolving them
    to display names needs Graph, which has no business in a detection script.

    License: MIT. No warranty.
#>
[CmdletBinding()]
param(
    [Parameter()][ValidateRange(1, 20)][int]$MinDemandsToFlag = 2
)

$ErrorActionPreference = 'Stop'

function Get-Safe { param([scriptblock]$S) try { & $S } catch { $null } }

function New-Demand {
    param([string]$Source, [string]$Detail, [datetime]$SinceUtc = [datetime]::MinValue)
    [pscustomobject]@{ Source = $Source; Detail = $Detail; SinceUtc = $SinceUtc }
}

try {
    $nowUtc  = (Get-Date).ToUniversalTime()
    $demands = @()

    # --- Windows Update --------------------------------------------------------------------
    $wu = [bool](
        (Get-Safe { [bool](New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired }) -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    )
    if ($wu) {
        $since = Get-Safe {
            $e = Get-WinEvent -FilterHashtable @{
                LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'; Id = 22
            } -MaxEvents 1 -ErrorAction Stop
            if ($e) { $e.TimeCreated.ToUniversalTime() } else { $null }
        }
        $demands += New-Demand -Source 'WindowsUpdate' -Detail '' -SinceUtc $(if ($since) { $since } else { [datetime]::MinValue })
    }

    # --- Component servicing ---------------------------------------------------------------
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $demands += New-Demand -Source 'CBS' -Detail 'RebootPending'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress') {
        $demands += New-Demand -Source 'CBS' -Detail 'RebootInProgress'
    }

    # --- Queued file renames ---------------------------------------------------------------
    $pfro = Get-Safe {
        (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations
    }
    if ($pfro) {
        $demands += New-Demand -Source 'FileRename' -Detail ("$(@($pfro).Count) op")
    }

    # --- Intune Win32 apps -----------------------------------------------------------------
    # One demand per app that wants a restart. This is the source that multiplies: a wave of
    # app deployments produces a wave of independent negotiations.
    $w32 = 'HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension\Win32Apps'
    if (Test-Path $w32) {
        $userKeys = Get-Safe { @(Get-ChildItem $w32 -ErrorAction Stop | Where-Object { $_.PSChildName -match '^[0-9a-fA-F-]{36}$' }) }
        foreach ($uk in @($userKeys)) {
            $appKeys = Get-Safe { @(Get-ChildItem $uk.PSPath -ErrorAction Stop | Where-Object { $_.PSChildName -ne 'GRS' }) }
            foreach ($ak in @($appKeys)) {
                $p = Get-Safe { Get-ItemProperty $ak.PSPath -ErrorAction Stop }
                if (-not $p) { continue }
                $status = [string]$p.RebootStatus
                if ([string]::IsNullOrWhiteSpace($status) -or $status -eq 'Clean') { continue }

                # 1/1/0001 is the null sentinel, not a date in the year 1.
                $set = Get-Safe {
                    $d = [datetime]::Parse([string]$p.RebootSetTimeUTC)
                    if ($d.Year -le 1) { $null } else { $d.ToUniversalTime() }
                }
                $appId  = ($ak.PSChildName -split '_')[0]
                $short  = if ($appId.Length -ge 8) { $appId.Substring(0, 8) } else { $appId }
                $reason = if ($p.RebootReason -and $p.RebootReason -ne 'None') { ":$($p.RebootReason)" } else { '' }
                $demands += New-Demand -Source "IntuneApp:$short" -Detail "$status$reason" -SinceUtc $(if ($set) { $set } else { [datetime]::MinValue })
            }
        }
    }

    # --- Security configuration waiting to take effect --------------------------------------
    # Same signal the effectiveness detector uses. Included here because it is a genuine
    # demand for a restart, and because it is the one nobody counts.
    $dg = Get-Safe { Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop }
    if ($dg) {
        # 0 is the "none" sentinel in these arrays, not a service identifier.
        $cfg = @($dg.SecurityServicesConfigured | ForEach-Object { [int]$_ } | Where-Object { $_ -ne 0 })
        $run = @($dg.SecurityServicesRunning    | ForEach-Object { [int]$_ } | Where-Object { $_ -ne 0 })
        foreach ($m in @($cfg | Where-Object { $run -notcontains $_ })) {
            $name = switch ($m) { 1 { 'CredentialGuard' } 2 { 'MemoryIntegrity' } 3 { 'SecureLaunch' } default { "service$m" } }
            $demands += New-Demand -Source 'Config' -Detail $name
        }
    }

    # --- Verdict ----------------------------------------------------------------------------
    if ($demands.Count -eq 0) {
        Write-Output 'NONE | no restart demand'
        exit 0
    }

    $dated  = @($demands | Where-Object { $_.SinceUtc -gt [datetime]::MinValue })
    $oldest = if ($dated.Count) { ($dated | Sort-Object SinceUtc | Select-Object -First 1).SinceUtc } else { $null }
    $ageTxt = if ($oldest) { ', oldest ' + [Math]::Round(($nowUtc - $oldest).TotalDays, 1) + 'd' } else { '' }

    $parts = $demands | ForEach-Object {
        $age = if ($_.SinceUtc -gt [datetime]::MinValue) { '(' + [Math]::Round(($nowUtc - $_.SinceUtc).TotalDays, 1) + 'd)' } else { '' }
        $det = if ($_.Detail) { ':' + $_.Detail } else { '' }
        "$($_.Source)$det$age"
    }
    $list = ($parts -join '; ')

    $noun = if ($demands.Count -eq 1) { 'demand' } else { 'demands' }

    if ($demands.Count -ge $MinDemandsToFlag) {
        Write-Output "COALESCE | $($demands.Count) $noun$ageTxt | $list"
        exit 1
    }

    Write-Output "SINGLE | $($demands.Count) $noun$ageTxt | $list"
    exit 0
}
catch {
    Write-Output "REVIEW | inventory failed: $($_.Exception.Message)"
    exit 1
}
