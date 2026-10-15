#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Resets Microsoft Edge user data for every user profile on a device, such as a
    terminal server. NinjaOne-ready. No user names need to be entered.
.DESCRIPTION
    Sweeps every non-system profile under C:\Users that has Edge user data.
    Light: moves Local State, Preferences and Secure Preferences into a backup folder
           (settings reset; bookmarks, passwords and history stay in place).
    Full:  renames the entire User Data folder (Edge starts as a first run).
    Nothing is deleted. Every change is a rename or move into a timestamped backup
    inside each user's own profile.

    Safe by default:
      - Preview Only is ON unless explicitly turned off: the run reports what it would
        do and changes nothing.
      - Signed-in users (including disconnected sessions) are SKIPPED unless
        Include Signed-In Users is turned on, so active sessions are not disrupted.

    NinjaOne script variables (delivered to the script as environment variables):
      Reset Mode               Drop-down: Light, Full      -> $env:resetMode
      Preview Only             Checkbox, default checked   -> $env:previewOnly
      Include Signed-In Users  Checkbox, default clear     -> $env:includeSignedInUsers
      Exclude Users            String/Text, optional       -> $env:excludeUsers
                               Profile folder names, comma- or semicolon-separated

    Parameters take precedence when the script is run by hand.
.EXAMPLE
    .\Reset-EdgeMultiUser.ps1
    Preview of a Light reset for all signed-out users. Changes nothing.
.EXAMPLE
    .\Reset-EdgeMultiUser.ps1 -PreviewOnly false -ExcludeUsers 'administrator, svc-backup'
    Light reset for all signed-out users except the two listed.
#>
[CmdletBinding()]
param(
    [string]$Mode = $env:resetMode,
    [string]$PreviewOnly = $env:previewOnly,
    [string]$IncludeSignedInUsers = $env:includeSignedInUsers,
    [string]$ExcludeUsers = $env:excludeUsers
)

$ErrorActionPreference = 'Stop'

# NinjaOne checkboxes arrive as the strings 'true' / 'false'
function ConvertTo-Flag {
    param([string]$Value, [bool]$Default)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    $parsed = $false
    if ([bool]::TryParse($Value.Trim(), [ref]$parsed)) { return $parsed }
    if ($Value.Trim() -eq '1') { return $true }
    if ($Value.Trim() -eq '0') { return $false }
    throw "Invalid true/false value '$Value'."
}

# Performs the reset for one User Data folder and returns the backup path
function Invoke-EdgeReset {
    param(
        [Parameter(Mandatory)][string]$EdgeData,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Stamp
    )
    if ($Mode -eq 'Full') {
        $newName = "User Data.bak-$Stamp"
        Rename-Item -LiteralPath $EdgeData -NewName $newName
        return (Join-Path (Split-Path $EdgeData) $newName)
    }

    $backup = Join-Path (Split-Path $EdgeData) "EdgeReset-Light.bak-$Stamp"
    New-Item -ItemType Directory -Path $backup | Out-Null

    $localState = Join-Path $EdgeData 'Local State'
    if (Test-Path -LiteralPath $localState) {
        Move-Item -LiteralPath $localState -Destination $backup
    }

    # Default plus any additional profiles (Profile 1, Profile 2, ...)
    Get-ChildItem -LiteralPath $EdgeData -Directory |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
        ForEach-Object {
            $dest = Join-Path $backup $_.Name
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            foreach ($f in 'Preferences', 'Secure Preferences') {
                $p = Join-Path $_.FullName $f
                if (Test-Path -LiteralPath $p) {
                    Move-Item -LiteralPath $p -Destination $dest
                }
            }
        }
    return $backup
}

# --- Validate input ----------------------------------------------------------------
try {
    if ([string]::IsNullOrWhiteSpace($Mode)) { $Mode = 'Light' }
    $Mode = $Mode.Trim()
    if ($Mode -notin 'Light', 'Full') { throw "Invalid mode '$Mode'. Use Light or Full." }

    $preview       = ConvertTo-Flag -Value $PreviewOnly -Default $true
    $includeLoaded = ConvertTo-Flag -Value $IncludeSignedInUsers -Default $false

    $exclude = @("$ExcludeUsers" -split '[,;]' |
        ForEach-Object { ($_.Trim() -split '\\')[-1] } |
        Where-Object { $_ })
}
catch {
    Write-Output "Result: FAILED - $($_.Exception.Message)"
    exit 1
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Write-Output "Edge multi-user reset on $env:COMPUTERNAME"
Write-Output ("Mode: {0} | Preview only: {1} | Include signed-in users: {2}" -f
    $Mode, $preview, $includeLoaded)
if ($exclude.Count) { Write-Output "Excluded: $($exclude -join ', ')" }

# Profile containers keep signed-out users' AppData off the local disk
$fslKey  = 'HKLM:\SOFTWARE\FSLogix\Profiles'
$fslogix = Get-ItemProperty -Path $fslKey -Name Enabled -ErrorAction SilentlyContinue
if ($fslogix.Enabled -eq 1) {
    Write-Output ('WARNING: FSLogix profile containers are enabled. Signed-out users'' ' +
        'Edge data is inside their containers and cannot be reached by this script.')
}
if ($preview) { Write-Output 'PREVIEW ONLY: no changes will be made.' }
Write-Output ''

# --- Snapshot profiles and Edge process owners once ----------------------------------
$profiles = @(Get-CimInstance -ClassName Win32_UserProfile |
    Where-Object { -not $_.Special } |
    Sort-Object -Property LocalPath)

$edgeProcs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'msedge.exe'" |
    ForEach-Object {
        $owner = $_ | Invoke-CimMethod -MethodName GetOwnerSid -ErrorAction SilentlyContinue
        [pscustomobject]@{ ProcessId = $_.ProcessId; OwnerSid = $owner.Sid }
    })

# --- Sweep -------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()

foreach ($prof in $profiles) {
    $name     = Split-Path $prof.LocalPath -Leaf
    $edgeData = Join-Path $prof.LocalPath 'AppData\Local\Microsoft\Edge\User Data'
    $status   = $null
    $detail   = $null

    try {
        if ($name -in $exclude) {
            $status = 'SKIPPED'; $detail = 'Excluded'
        }
        elseif (-not (Test-Path -LiteralPath $edgeData)) {
            $status = 'SKIPPED'; $detail = 'No Edge data'
        }
        elseif ($prof.Loaded -and -not $includeLoaded) {
            $status = 'SKIPPED'; $detail = 'Signed in'
        }
        else {
            # Only this user's msedge.exe; msedgewebview2.exe (Teams, Outlook) untouched
            $mine = @($edgeProcs | Where-Object { $_.OwnerSid -eq $prof.SID })

            if ($preview) {
                $status = 'WOULD RESET'
                $detail = "$Mode; would stop $($mine.Count) Edge process(es)"
            }
            else {
                $mine | ForEach-Object {
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                }
                if ($mine.Count) { Start-Sleep -Seconds 2 }
                $backup = Invoke-EdgeReset -EdgeData $edgeData -Mode $Mode -Stamp $stamp
                $status = 'RESET'
                $detail = "Backup: $backup"
            }

            $polKey = "Registry::HKEY_USERS\$($prof.SID)\Software\Policies\Microsoft\Edge"
            if ($prof.Loaded -and (Test-Path -LiteralPath $polKey)) {
                $detail += '; user-scoped Edge policy present'
            }
        }
    }
    catch {
        $status = 'FAILED'
        $detail = $_.Exception.Message
        if ($detail -match 'being used by another process|denied') {
            $detail += ' (files locked; have the user sign out and rerun)'
        }
    }

    $results.Add([pscustomobject]@{ User = $name; Status = $status; Detail = $detail })
    Write-Output ('{0,-12} {1}: {2}' -f $status, $name, $detail)
}

# --- Summary -----------------------------------------------------------------------
Write-Output ''
Write-Output 'Summary:'
$results | Group-Object -Property Status | Sort-Object -Property Name |
    ForEach-Object { Write-Output ('  {0,-12} {1}' -f $_.Name, $_.Count) }

$failed = @($results | Where-Object { $_.Status -eq 'FAILED' })
$acted  = @($results | Where-Object { $_.Status -in 'RESET', 'WOULD RESET' })

if ($failed.Count) {
    Write-Output "Result: FAILED ($($failed.Count) of $($results.Count) profile(s) failed)"
    exit 1
}
if ($preview) {
    Write-Output "Result: PREVIEW ONLY - no changes made ($($acted.Count) profile(s) would reset)"
    exit 0
}
Write-Output "Result: SUCCESS ($($acted.Count) profile(s) reset, $Mode)"
exit 0
