#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Remediation detection script: which devices are reported compliant while the
    security feature is configured but not actually running?

.DESCRIPTION
    Enable Credential Guard, VBS or Memory Integrity through Intune and the profile reports
    "Succeeded". The protection is not on. It turns on at the next restart - and unlike a
    Win32 app, a configuration profile has no restart behaviour, no grace period and no
    notification. Nothing tells the user, and nothing tells you.

    On a machine that stays up for three weeks, that is three weeks of a device counted as
    protected in your reporting while the protection is not running. The gap is invisible in
    the portal, because the portal is reporting policy delivery, not policy effect.

    This script closes it, using a comparison Windows already publishes about itself:

        Win32_DeviceGuard.SecurityServicesConfigured   what policy asked for
        Win32_DeviceGuard.SecurityServicesRunning      what is actually running

    Anything in the first list and not the second is configured and not effective. No policy
    parsing, no guesswork, no vendor documentation required.

    THE DISTINCTION THAT MATTERS. Configured-but-not-running has two very different causes,
    and this script separates them:

      * A restart is pending  -> the restart will fix it. This is a scheduling problem, and
                                 it is what the rest of this repository is about.
      * No restart is pending -> the restart will NOT fix it. Something else is blocking:
                                 a hardware requirement, firmware settings, a licence, or a
                                 conflicting policy. This is the more serious finding, and
                                 it is the one that would otherwise sit unnoticed forever.

.PARAMETER IncludeOptionalFeatures
    Also check Windows optional features stuck in EnablePending / DisablePending. Off by
    default: enumerating features through DISM takes seconds, and Intune Remediation scripts
    run under a short timeout. Turn it on when you are deploying Hyper-V, WSL or similar.

.OUTPUTS
    One compact line, verdict first, sized for the Intune detection output column.

        EFFECTIVE | VBS running | services running: CredentialGuard,MemoryIntegrity
        EFFECTIVE | VBS not configured on this device
        ACTION | configured but NOT running: CredentialGuard | restart pending - restart resolves this
        ACTION | configured but NOT running: MemoryIntegrity | NO restart pending - restart will NOT fix it, check hardware/firmware/licence/conflicting policy
        ACTION | VBS enabled but NOT running | NO restart pending - restart will NOT fix it, ...

.NOTES
    Exit codes for Intune Remediations:
      0  nothing configured is failing to run
      1  at least one configured protection is not running

    Enable "Run script in 64-bit PowerShell". Read-only: this script changes nothing.

    Security service identifiers are mapped for 1 (Credential Guard), 2 (Memory Integrity /
    HVCI) and 3 (System Guard Secure Launch). Anything else is reported as "service N"
    rather than guessed at - a wrong label on a security report is worse than no label.

    License: MIT. No warranty.
#>
[CmdletBinding()]
param(
    [Parameter()][switch]$IncludeOptionalFeatures
)

$ErrorActionPreference = 'Stop'

function Get-Safe { param([scriptblock]$S) try { & $S } catch { $null } }

function Get-ServiceName {
    param([int]$Id)
    switch ($Id) {
        1 { 'CredentialGuard' }
        2 { 'MemoryIntegrity' }
        3 { 'SecureLaunch' }
        default { "service$Id" }
    }
}

try {
    $findings = @()
    $notes    = @()

    # --- Is a restart pending? Decides whether a restart is the fix, or a red herring ------
    # Only the Windows Update sources plus CBS are relevant here: a servicing operation that
    # requires a restart is exactly what leaves a feature configured and not yet running.
    $restartPending = [bool](
        (Get-Safe { [bool](New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired }) -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    )

    # --- Device Guard: what was asked for, versus what is running -------------------------
    $dg = Get-Safe {
        Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
    }

    $vbs          = $null
    $hwHypervisor = $true   # assumed present until the platform says otherwise

    if (-not $dg) {
        $notes += 'DeviceGuard WMI unavailable'
    }
    else {
        # AvailableSecurityProperties reports what the platform actually offers.
        # Property 1 is hypervisor support - without it, nothing VBS-based can ever run,
        # and no number of restarts will change that.
        $avail = @($dg.AvailableSecurityProperties | ForEach-Object { [int]$_ })
        if ($avail.Count -gt 0) { $hwHypervisor = ($avail -contains 1) }

        # 0 is the "none" sentinel in these arrays, NOT a service identifier. It must be
        # filtered explicitly. Relying on PowerShell truthiness here is a trap: @(0) happens
        # to evaluate false, so a device reporting "nothing configured" works by accident -
        # but @(0,2) is true, and 0 would then be reported as a security service that is
        # configured and not running. A phantom finding on a security report.
        # Observed on a managed Windows 11 device: configured = [0], running = [1].
        # Credential Guard running while nothing is "configured" is normal - Windows 11
        # enables it by default on eligible installs. Running without configured is not a
        # fault, so only the reverse direction is ever a finding.
        $configured = @($dg.SecurityServicesConfigured | ForEach-Object { [int]$_ } | Where-Object { $_ -ne 0 })
        $running    = @($dg.SecurityServicesRunning    | ForEach-Object { [int]$_ } | Where-Object { $_ -ne 0 })

        # VBS itself: 0 = not enabled, 1 = enabled but NOT running, 2 = running.
        # Status 1 is the whole point of this script.
        $vbs = [int]$dg.VirtualizationBasedSecurityStatus

        switch ($vbs) {
            0 { $notes += 'VBS not configured on this device' }
            1 { $findings += 'VBS enabled but NOT running' }
            2 { $notes += 'VBS running' }
            default { $notes += "VBS status $vbs" }
        }

        $missing = @($configured | Where-Object { $running -notcontains $_ })
        if ($missing.Count -gt 0) {
            $findings += 'configured but NOT running: ' + (($missing | ForEach-Object { Get-ServiceName $_ }) -join ',')
        }
        elseif ($running.Count -gt 0) {
            $notes += 'services running: ' + (($running | ForEach-Object { Get-ServiceName $_ }) -join ',')
        }
    }

    # --- LSA protection: reported, never used as a verdict ---------------------------------
    # RunAsPPL tells us what was CONFIGURED. Proving LSASS actually started protected is the
    # missing half, and there is no dependable way to get it here: the
    # Microsoft-Windows-Wininit/Operational channel does not exist on Windows 11, and the
    # System-log lookup by provider is not reliable across builds. Reading the process
    # protection level needs P/Invoke, which does not belong in a detection script.
    #
    # An earlier version treated "no event found" as "not running". On a machine where LSA
    # protection was working normally, that produced an ACTION verdict on a SECURITY report.
    # A false alarm there is worse than no check at all - it is the fastest way to get the
    # whole deployment switched off. So this is a note, never a finding, and it never
    # influences the exit code.
    $ppl = Get-Safe { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name RunAsPPL -ErrorAction Stop).RunAsPPL }
    if ($ppl) { $notes += "LSA protection configured (RunAsPPL=$ppl, running state not verifiable here)" }

    # --- Optional features stuck mid-flight ------------------------------------------------
    # EnablePending / DisablePending is Windows saying, in its own words, "configured, not
    # effective, waiting for a restart".
    if ($IncludeOptionalFeatures) {
        # Measured: this took 11 s as SYSTEM on a managed Windows 11 device and still failed.
        # The reason is captured rather than swallowed - "not readable" with no cause is the
        # kind of note everyone learns to ignore.
        # An explicit success flag, NOT the emptiness of the result. Assigning from a try
        # expression that outputs nothing yields $null, so "read successfully, nothing
        # pending" - the healthy answer - was being reported as "not readable". A check that
        # cannot tell success from failure is worse than no check.
        $featErr = $null
        $featOk  = $false
        $pending = @()
        try {
            $pending = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object { $_.State -like '*Pending' })
            $featOk  = $true
        }
        catch { $featErr = $_.Exception.Message }

        if (-not $featOk) {
            $short = if ($featErr) { ($featErr -split "`r?`n")[0] } else { 'no reason reported' }
            if ($short.Length -gt 80) { $short = $short.Substring(0, 80) }
            $notes += "optional features not readable ($short)"
        }
        elseif ($pending.Count -gt 0) {
            $findings += 'features pending: ' + (($pending | Select-Object -First 4 | ForEach-Object { "$($_.FeatureName)=$($_.State)" }) -join ',')
        }
    }

    # --- Verdict ---------------------------------------------------------------------------
    if ($findings.Count -eq 0) {
        $line = 'EFFECTIVE | ' + $(if ($notes.Count) { $notes -join ' | ' } else { 'nothing configured that is not running' })
        Write-Output $line
        exit 0
    }

    # This is the sentence that turns a detection into a decision - and the one place where
    # being wrong costs the most.
    #
    # MEASURED CORRECTION. An earlier version keyed this purely on the pending-restart flags:
    # no flag set meant "a restart will not fix this, look at hardware". That is wrong in the
    # MOST COMMON case. Verified on a managed Windows 11 device: writing the Memory Integrity
    # policy moved SecurityServicesConfigured from [0] to [2] immediately - and set no restart
    # flag at all. Applying a security policy is not a servicing operation, so it does not
    # touch WindowsUpdate\RebootRequired or CBS\RebootPending. The tool would have told you to
    # go hunting through firmware for a device that simply needed rebooting.
    #
    # The platform capability is the honest discriminator, in this order:
    $verdict =
        if (-not $hwHypervisor) {
            'platform reports NO hypervisor support - a restart will not fix this'
        }
        elseif ($vbs -eq 1) {
            'VBS is enabled but not starting - check firmware and virtualisation settings; a restart alone may not be enough'
        }
        elseif ($restartPending) {
            'restart pending - restart resolves this'
        }
        else {
            'restart required to apply; if it persists after one, check firmware, licence or conflicting policy'
        }

    Write-Output ('ACTION | ' + ($findings -join ' | ') + ' | ' + $verdict)
    exit 1
}
catch {
    Write-Output "REVIEW | detection failed: $($_.Exception.Message)"
    exit 1
}
