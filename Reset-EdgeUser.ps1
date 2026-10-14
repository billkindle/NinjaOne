#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Resets Microsoft Edge user data for one local user profile. NinjaOne-ready.
.DESCRIPTION
    Light: moves Local State, Preferences and Secure Preferences into a backup folder
           (settings reset; bookmarks, passwords and history stay in place).
    Full:  renames the entire User Data folder (Edge starts as a first run).
    Nothing is deleted. Every change is a rename or move into a timestamped backup.

    NinjaOne script variables (delivered to the script as environment variables):
      Target User  String/Text, mandatory    -> $env:targetUser
      Reset Mode   Drop-down: Light, Full    -> $env:resetMode
    Do NOT name the variable "User Name": $env:userName collides with the built-in
    USERNAME variable (which is the computer account when running as SYSTEM).

    -UserName / -Mode take precedence when the script is run by hand.
.PARAMETER UserName
    Profile folder name under C:\Users. A DOMAIN\ or AzureAD\ prefix is stripped.
.PARAMETER Mode
    Light (default) or Full.
.EXAMPLE
    .\Reset-EdgeUser.ps1 -UserName jdoe -Mode Full
#>
[CmdletBinding()]
param(
    [string]$UserName = $env:targetUser,
    [string]$Mode = $env:resetMode
)

$ErrorActionPreference = 'Stop'

try {
    # --- Validate input ------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($UserName)) {
        throw 'No user supplied. Set the Target User script variable (or -UserName).'
    }
    $UserName = ($UserName.Trim() -split '\\')[-1]

    if ([string]::IsNullOrWhiteSpace($Mode)) { $Mode = 'Light' }
    $Mode = $Mode.Trim()
    if ($Mode -notin 'Light', 'Full') { throw "Invalid mode '$Mode'. Use Light or Full." }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Write-Output "Edge reset requested: user '$UserName', mode $Mode, device $env:COMPUTERNAME"

    # --- Resolve the target profile ($env:LOCALAPPDATA is SYSTEM's, not the user's) ---
    $profiles = @(Get-CimInstance -ClassName Win32_UserProfile |
        Where-Object { -not $_.Special })
    $userProfile = @($profiles |
        Where-Object { (Split-Path $_.LocalPath -Leaf) -eq $UserName })

    if ($userProfile.Count -ne 1) {
        Write-Output "Expected one profile folder named '$UserName', found $($userProfile.Count)."
        Write-Output 'Profiles on this device:'
        $profiles | Sort-Object -Property LocalPath |
            Format-Table -Property LocalPath, SID, Loaded -AutoSize |
            Out-String -Width 200 | Write-Output
        throw 'Profile not resolved. Rerun with a folder name from the list above.'
    }
    $userProfile = $userProfile[0]
    Write-Output "Profile: $($userProfile.LocalPath) ($($userProfile.SID))"

    $edgeData = Join-Path $userProfile.LocalPath 'AppData\Local\Microsoft\Edge\User Data'
    if (-not (Test-Path -LiteralPath $edgeData)) { throw "No Edge user data at $edgeData" }

    # --- Report user-scoped Edge policies (hive only loaded while user is signed in) ---
    $polKey = "Registry::HKEY_USERS\$($userProfile.SID)\Software\Policies\Microsoft\Edge"
    if (-not $userProfile.Loaded) {
        Write-Output 'User is not signed in; user-scoped Edge policy check skipped.'
    }
    elseif (Test-Path -LiteralPath $polKey) {
        Write-Output 'WARNING: user-scoped Edge policies present:'
        Get-ItemProperty -LiteralPath $polKey |
            Select-Object -Property * -ExcludeProperty PS* |
            Format-List | Out-String -Width 200 | Write-Output
    }
    else {
        Write-Output 'No user-scoped Edge policies found.'
    }

    # --- Stop only msedge.exe owned by this profile's SID ------------------------------
    # msedgewebview2.exe (Teams, Outlook) is untouched.
    $edgeProcs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'msedge.exe'" |
        Where-Object {
            $owner = $_ | Invoke-CimMethod -MethodName GetOwnerSid -ErrorAction SilentlyContinue
            $owner.Sid -eq $userProfile.SID
        })
    $edgeProcs | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Write-Output "Stopped $($edgeProcs.Count) msedge.exe process(es) for this user."
    Start-Sleep -Seconds 2

    # --- Reset -------------------------------------------------------------------------
    switch ($Mode) {
        'Light' {
            $backup = Join-Path (Split-Path $edgeData) "EdgeReset-Light.bak-$stamp"
            New-Item -ItemType Directory -Path $backup | Out-Null

            $localState = Join-Path $edgeData 'Local State'
            if (Test-Path -LiteralPath $localState) {
                Move-Item -LiteralPath $localState -Destination $backup
            }

            # Default plus any additional profiles (Profile 1, Profile 2, ...)
            Get-ChildItem -LiteralPath $edgeData -Directory |
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
        }
        'Full' {
            $newName = "User Data.bak-$stamp"
            $backup = Join-Path (Split-Path $edgeData) $newName
            Rename-Item -LiteralPath $edgeData -NewName $newName
        }
    }

    Write-Output "Backup: $backup"
    Write-Output "Result: SUCCESS ($Mode reset)"
    exit 0
}
catch {
    $msg = $_.Exception.Message
    Write-Output "Result: FAILED - $msg"
    if ($msg -match 'being used by another process|denied') {
        Write-Output 'Hint: files are locked. Have the user sign out, then run again.'
    }
    exit 1
}