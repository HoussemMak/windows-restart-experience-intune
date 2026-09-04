#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Remediation detection script: is this device ready, or is it sitting on a restart
    it will never be told about?

.DESCRIPTION
    Most "pending reboot" scripts answer one question badly: they OR together four registry
    keys and report true. That tells you a restart is pending. It does not tell you whether
    it matters, where it came from, or whether anything is going to resolve it.

    This one answers the three questions that decide whether you need to act:

      1. Is a restart pending, and IS IT FROM WINDOWS UPDATE?
         Only Microsoft.Update.SystemInfo.RebootRequired and the Windows Update registry key
         are specific to Windows Update. CBS.RebootPending, CBS.RebootInProgress and
         PendingFileRenameOperations also fire on an ordinary application install. Treating
         them as equivalent is how you end up chasing update problems that are really an app
         installer, or forcing restarts on people for no reason.

      2. HOW LONG has it been pending?
         Taken from event 22 in the WindowsUpdateClient operational log, because the registry
         key carries no usable date. A device pending restart for a day is normal. One pending
         for three weeks is a device whose security updates are installed but not in effect.

      3. Will anything actually resolve it?
         The device is read for the ConfigureDeadline* policy family, the effective native
         deadline is computed, and the script reports whether that deadline has already passed
         while the restart is STILL pending. That case means the enforcement layer you are
         relying on is not doing its job on this device - a policy conflict, a safeguard hold,
         a changed ring, or a device that was offline at the wrong moment. Nothing in the
         Intune portal surfaces it.

    VERIFIED: the ConfigureDeadline* value names were read off an Intune-enrolled Windows 11
    device. An update ring writes ConfigureDeadlineGracePeriod - the GENERIC name - not
    ConfigureDeadlineGracePeriodForFeatureUpdates. The specific variant only appears when set
    explicitly through the Settings Catalog, and takes precedence when present.

.OUTPUTS
    One compact line on stdout, verdict first, so it stays readable in the Intune
    "Pre-remediation detection output" column, which truncates.

        READY | nothing pending
        READY | WU restart pending 0.4d, within native window, restart due 2026-09-06T15:09Z
        ACTION | WU restart pending 4.1d | native deadline PASSED 2.1d ago - enforcement not applying
        ACTION | WU restart pending 9.0d | no ConfigureDeadline* policy on this device
        REVIEW | non-WU restart pending 6.2d (CBS) - not a Windows Update restart

.NOTES
    Exit codes, for use as a DETECTION script in Intune Remediations:
      0  nothing to do - either no restart pending, or pending and on track
      1  needs attention - surfaces the device in the Remediation report

    Deploy as detection-only (no remediation script) if you just want the fleet picture.
    Enable "Run script in 64-bit PowerShell" so the registry reads are not redirected.

    Read-only. This script changes nothing on the device.

    License: MIT. No warranty.
#>
[CmdletBinding()]
param(
    # A restart pending longer than this, with no native deadline in sight, is worth surfacing.
    [Parameter()][int]$PendingWarningDays = 3,

    # Grace before declaring the native deadline missed. Windows does not restart to the second.
    # Range-guarded: a negative value would invert the comparison and report every device as
    # overdue - a monitoring tool that cries wolf gets switched off within a week.
    [Parameter()][ValidateRange(0, 10080)][int]$OverdueToleranceMinutes = 60
)

$ErrorActionPreference = 'Stop'

function Get-Safe { param([scriptblock]$S) try { & $S } catch { $null } }

try {
    # --- 1. Restart pending, and from where -------------------------------------------------
    # The COM source is the authoritative Windows Update answer. The registry key is the same
    # signal by another route; either one alone is enough to call it a Windows Update restart.
    $wuCom = Get-Safe { [bool](New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired }
    $wuReg = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $fromWindowsUpdate = [bool]($wuCom -or $wuReg)

    $generic = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')    { $generic += 'CBS' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress') { $generic += 'CBS-InProgress' }
    if (Get-Safe { Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop }) { $generic += 'PendingFileRename' }

    if (-not $fromWindowsUpdate -and $generic.Count -eq 0) {
        Write-Output 'READY | nothing pending'
        exit 0
    }

    # --- 2. Since when ----------------------------------------------------------------------
    # Event 22 is the transition into "restart required"; the registry key has no timestamp.
    #
    # CAREFUL: taking the most recent event 22 unconditionally is wrong. An event from an
    # EARLIER cycle - one that was already resolved by a restart - would still be in the log,
    # and would inflate the age of a NEW pending restart into a false ACTION verdict.
    #
    # So the anchor is the most recent event 22 AT OR AFTER the last boot. If there is none,
    # we fall back to the boot time itself and label the age as a lower bound. That can only
    # UNDERSTATE how long the restart has been pending, never overstate it - the same rule
    # applied to the deadline calculation below. This tool must not manufacture alarms.
    $nowUtc  = (Get-Date).ToUniversalTime()
    $bootUtc = Get-Safe { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime() }

    $sinceUtc = Get-Safe {
        $filter = @{ LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'; Id = 22 }
        if ($bootUtc) { $filter['StartTime'] = $bootUtc.ToLocalTime() }
        $e = Get-WinEvent -FilterHashtable $filter -MaxEvents 1 -ErrorAction Stop
        if ($e) { $e.TimeCreated.ToUniversalTime() } else { $null }
    }

    $ageIsLowerBound = $false
    if (-not $sinceUtc -and $bootUtc) { $sinceUtc = $bootUtc; $ageIsLowerBound = $true }

    $ageDays = if ($sinceUtc) { [Math]::Round(($nowUtc - $sinceUtc).TotalDays, 1) } else { $null }
    $ageTxt  = if ($null -ne $ageDays) { $(if ($ageIsLowerBound) { '>=' } else { '' }) + "$ageDays" + 'd' } else { 'age unknown' }

    # --- Non-Windows-Update restart ---------------------------------------------------------
    # Worth surfacing, but it is a different problem and must not be reported as an update one.
    if (-not $fromWindowsUpdate) {
        $src = $generic -join '/'
        if ($null -ne $ageDays -and $ageDays -ge $PendingWarningDays) {
            Write-Output "REVIEW | non-WU restart pending $ageTxt ($src) - not a Windows Update restart"
            exit 1
        }
        Write-Output "READY | non-WU restart pending $ageTxt ($src) - not a Windows Update restart"
        exit 0
    }

    # --- 3. Is anything going to resolve it -------------------------------------------------
    $key = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'
    $pol = Get-Safe { Get-ItemProperty -Path $key -ErrorAction Stop }

    $deadlineDays = if ($pol) { $pol.ConfigureDeadlineForFeatureUpdates } else { $null }
    $graceDays    = if ($pol) { $pol.ConfigureDeadlineGracePeriod }       else { $null }
    if ($pol -and $null -ne $pol.ConfigureDeadlineGracePeriodForFeatureUpdates) {
        $graceDays = $pol.ConfigureDeadlineGracePeriodForFeatureUpdates
    }

    if ($null -eq $deadlineDays -and $null -eq $graceDays) {
        # No deadline policy: nothing will force this restart. It waits on the user, forever.
        Write-Output "ACTION | WU restart pending $ageTxt | no ConfigureDeadline* policy on this device - nothing will enforce it"
        exit 1
    }

    # EffectiveDeadline = MAX(firstDetected + deadline, restartRequired + grace).
    # firstDetected is not reliably readable, so restartRequired is used for both branches:
    # that can only push the computed deadline LATER, never earlier. We never report a device
    # as overdue on an optimistic guess.
    $anchor = if ($sinceUtc) { $sinceUtc } else { $nowUtc }
    $cands = @()
    if ($null -ne $deadlineDays) { $cands += $anchor.AddDays([int]$deadlineDays) }
    if ($null -ne $graceDays)    { $cands += $anchor.AddDays([int]$graceDays) }
    $due = $cands | Sort-Object -Descending | Select-Object -First 1

    $polTxt = "dl=$deadlineDays grace=$graceDays noAutoReboot=$(if ($pol) { $pol.ConfigureDeadlineNoAutoReboot } else { '?' })"

    if ($nowUtc -gt $due.AddMinutes($OverdueToleranceMinutes)) {
        $lateD = [Math]::Round(($nowUtc - $due).TotalDays, 1)
        Write-Output "ACTION | WU restart pending $ageTxt | native deadline PASSED ${lateD}d ago - enforcement not applying | $polTxt"
        exit 1
    }

    if ($null -eq $sinceUtc) {
        # Neither event 22 nor a boot time: nothing to date this against. Report rather
        # than guess - a made-up age here would drive a made-up verdict.
        Write-Output "REVIEW | WU restart pending, age undeterminable | $polTxt"
        exit 1
    }

    Write-Output ("READY | WU restart pending $ageTxt, within native window, restart due " + $due.ToString('yyyy-MM-ddTHH:mmZ') + " | $polTxt")
    exit 0
}
catch {
    Write-Output "REVIEW | detection failed: $($_.Exception.Message)"
    exit 1
}
