<#
.SYNOPSIS
    Verifies the Windows AltStore / AltServer prerequisite setup and connected Apple device.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Write-Check {
    param(
        [string]$Label,
        [bool]$Passed,
        [string]$Detail = ""
    )
    $status = if ($Passed) { "[OK]  " } else { "[FAIL]" }
    $color  = if ($Passed) { "Green" } else { "Red" }
    $msg = if ($Detail) { "$status $Label - $Detail" } else { "$status $Label" }
    Write-Host $msg -ForegroundColor $color
}

Write-Section "1. Microsoft Store Conflict Check"
$storeAppleApps = Get-AppxPackage | Where-Object {
    $_.Name -match '^(AppleInc\.iTunes|AppleInc\.iCloud|.*iTunes.*|.*iCloud.*)$'
}
if ($storeAppleApps) {
    foreach ($pkg in $storeAppleApps) {
        Write-Check -Label "Store package conflict: $($pkg.Name)" -Passed $false -Detail "Uninstall Microsoft Store version; AltServer requires desktop Apple installers."
    }
} else {
    Write-Check -Label "No Microsoft Store iTunes or iCloud packages detected" -Passed $true
}

Write-Section "2. Desktop Applications (Registry & Program Files)"
$regRoots = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$installedEntries = Get-ItemProperty $regRoots -ErrorAction SilentlyContinue

$iCloudEntry = $installedEntries | Where-Object { $_.DisplayName -match '^iCloud' } | Select-Object -First 1
$iTunesEntry = $installedEntries | Where-Object { $_.DisplayName -match '^iTunes' } | Select-Object -First 1
$altEntry    = $installedEntries | Where-Object { $_.DisplayName -match '^AltServer' } | Select-Object -First 1

$iCloudExe = @("${env:ProgramFiles(x86)}\Common Files\Apple\Internet Services\iCloud.exe", "$env:ProgramFiles\Common Files\Apple\Internet Services\iCloud.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$iTunesExe = @("$env:ProgramFiles\iTunes\iTunes.exe", "${env:ProgramFiles(x86)}\iTunes\iTunes.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$altExe    = @("${env:ProgramFiles(x86)}\AltServer\AltServer.exe", "$env:ProgramFiles\AltServer\AltServer.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1

Write-Check -Label "Desktop iCloud" -Passed ([bool]($iCloudEntry -or $iCloudExe)) -Detail $(if ($iCloudEntry) { "v$($iCloudEntry.DisplayVersion)" } elseif ($iCloudExe) { $iCloudExe } else { "Not found" })
Write-Check -Label "Desktop iTunes" -Passed ([bool]($iTunesEntry -or $iTunesExe)) -Detail $(if ($iTunesEntry) { "v$($iTunesEntry.DisplayVersion)" } elseif ($iTunesExe) { $iTunesExe } else { "Not found" })
Write-Check -Label "AltServer"      -Passed ([bool]($altEntry -or $altExe))       -Detail $(if ($altEntry) { "v$($altEntry.DisplayVersion)" } elseif ($altExe) { $altExe } else { "Not found" })

Write-Section "3. Shared Apple Support Directories"
$supportDirs = @(
    "${env:ProgramFiles(x86)}\Common Files\Apple\Apple Application Support",
    "$env:ProgramFiles\Common Files\Apple\Apple Application Support",
    "${env:ProgramFiles(x86)}\Common Files\Apple\Internet Services",
    "$env:ProgramFiles\Common Files\Apple\Internet Services"
)
foreach ($dir in $supportDirs) {
    $exists = Test-Path $dir
    Write-Check -Label $dir -Passed $exists -Detail $(if ($exists) { "Present" } else { "Missing" })
}

Write-Section "4. Apple Background Services"
$requiredServices = @("Apple Mobile Device Service", "Bonjour Service")
foreach ($svcName in $requiredServices) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
        $svc = Get-Service | Where-Object { $_.DisplayName -eq $svcName } | Select-Object -First 1
    }
    if ($svc) {
        $isRunning = ($svc.Status -eq 'Running')
        Write-Check -Label "$($svc.DisplayName) ($($svc.Name))" -Passed $isRunning -Detail "Status: $($svc.Status), StartType: $($svc.StartType)"
    } else {
        Write-Check -Label $svcName -Passed $false -Detail "Service not installed"
    }
}

Write-Section "5. AltServer Process & Windows Firewall"
$altProc = Get-Process -Name "AltServer" -ErrorAction SilentlyContinue
Write-Check -Label "AltServer process" -Passed ([bool]$altProc) -Detail $(if ($altProc) { "Running (PID: $($altProc.Id -join ', '))" } else { "Not running" })

try {
    $fwRules = Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
        Where-Object { $_.Program -match 'AltServer' } |
        ForEach-Object {
            $appFilter = $_
            Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $appFilter -ErrorAction SilentlyContinue
        }
    if ($fwRules) {
        foreach ($r in $fwRules) {
            $allowed = ($r.Enabled -eq 'True' -and $r.Action -eq 'Allow')
            Write-Check -Label "Firewall rule '$($r.DisplayName)'" -Passed $allowed -Detail "Enabled=$($r.Enabled), Action=$($r.Action), Profile=$($r.Profile)"
        }
    } else {
        Write-Host "[INFO] No explicit AltServer Windows Firewall rule found yet (Windows will prompt when AltServer binds network sockets)." -ForegroundColor Yellow
    }
} catch {
    Write-Host "[INFO] Could not query Windows Firewall rules: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Section "6. Connected Apple USB Devices"
$usbDevices = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
    $_.InstanceId -match 'VID_05AC&PID_12A' -or $_.FriendlyName -match 'Apple iPad|Apple iPhone|Apple Mobile Device'
}
if ($usbDevices) {
    foreach ($dev in $usbDevices) {
        $ok = ($dev.Status -eq 'OK')
        Write-Check -Label "$($dev.FriendlyName) ($($dev.Class))" -Passed $ok -Detail "Status=$($dev.Status) | $($dev.InstanceId)"
    }
} else {
    Write-Check -Label "USB iPad / iPhone" -Passed $false -Detail "No Apple mobile device detected on USB."
}
