# Resetting Microsoft Edge for a Single User (PowerShell)

**Updated:** October 14, 2026 · **Applies to:** Windows 11 (26H2), Chromium Edge

## Symptom and cause

Edge won't open for one user but opens fine under another account on the same device. The binaries are healthy, so the fault is in that user's data: a corrupt `User Data` folder, a user-scoped policy, or a background `msedge.exe` (startup boost) holding locks.

There's no meaningful AppX reset for Chromium Edge; `Reset-AppxPackage` on the stub package doesn't touch user data. Resetting Edge means resetting the per-user data folder:

`C:\Users\<user>\AppData\Local\Microsoft\Edge\User Data`

## Impact and rollback

| Mode | What moves | What the user notices | Rollback |
| --- | --- | --- | --- |
| **Light** (default) | `Local State`, plus `Preferences` and `Secure Preferences` from `Default` and each `Profile *` folder, into `EdgeReset-Light.bak-<timestamp>` | Startup pages, new tab and search engine reset; extensions may need re-enabling. Bookmarks, passwords and history stay. | Copy the files back |
| **Full** | Whole `User Data` folder renamed to `User Data.bak-<timestamp>` | First-run Edge. Unsynced bookmarks, passwords, history, cookies/sessions, extensions and site permissions appear gone until restored or re-synced. | Rename the folder back |

- Nothing is deleted.
- Saved passwords are DPAPI-encrypted to the user. They restore on the same device for the same user only.
- Only `msedge.exe` processes owned by the target user's SID are stopped. `msedgewebview2.exe` (Teams, Outlook) is untouched.

## Pre-checks

Find the profile folder name. On Entra-joined devices it can differ from the sign-in name:

```powershell
Get-CimInstance -ClassName Win32_UserProfile |
    Where-Object { -not $_.Special } |
    Select-Object -Property LocalPath, SID, Loaded
```

**Diagnose (as the affected user).** If this window opens, the profile is the problem:

```powershell
$appPath  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
$edge     = (Get-ItemProperty -Path $appPath).'(default)'
$testDir  = Join-Path $env:TEMP 'EdgeTest'
$edgeArgs = ('--user-data-dir="{0}"' -f $testDir), '--no-first-run'
Start-Process -FilePath $edge -ArgumentList $edgeArgs
```

Crash events from the last 7 days:

```powershell
$filter = @{ LogName = 'Application'; Id = 1000; StartTime = (Get-Date).AddDays(-7) }
Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'msedge\.exe' } |
    Select-Object -First 10 -Property TimeCreated, Message
```

## Run from NinjaOne

Run **Reset-EdgeUser** against the device. Enter the profile folder name in **Target User** and choose **Light** first, then **Full** only if Light doesn't fix it. Record the `Backup:` path from the activity output, since restore and rollback need it.

### Script configuration

Settings: PowerShell, Windows, All, **Run as System**. Leave **Parameters** empty, because anything entered there overrides the variables.

| Setting | Target User | Reset Mode |
| --- | --- | --- |
| Type | String/Text | Drop-down |
| Variable name | `targetUser` | `resetMode` |
| Options | None | `Light`, `Full` (exact spelling) |
| Default | Blank | `Light` |
| Mandatory | Yes | Yes |

NinjaOne passes script variables as environment variables that exist only for the script's runtime. Empty values arrive as empty strings. The script reads `$env:targetUser` and `$env:resetMode`; confirm NinjaOne's generated names match.

### Reading the activity output

Example of a successful light reset:

```text
Edge reset requested: user 'jdoe', mode Light, device DESKTOP-EXAMPLE
Profile: C:\Users\jdoe (S-1-12-1-...)
No user-scoped Edge policies found.
Stopped 6 msedge.exe process(es) for this user.
Backup: C:\Users\jdoe\AppData\Local\Microsoft\Edge\EdgeReset-Light.bak-20261014-101500
Result: SUCCESS (Light reset)
```

| Output | Meaning and action |
| --- | --- |
| `Result: SUCCESS` | Done. Have the user open Edge. |
| `Expected one profile folder named ...` | No single folder matched. The profile list follows in the output; rerun with the right folder name. |
| `No user supplied` | Variable empty or not named `targetUser`. |
| `Hint: files are locked` | Have the user sign out, then rerun. |
| `WARNING: user-scoped Edge policies present` | A policy under HKCU may be the real blocker. Review it. |

Exit code is 0 on success and 1 on failure, so NinjaOne flags failed runs.

## Run by hand (elevated)

Parameters override the NinjaOne variables.

```powershell
.\Reset-EdgeUser.ps1 -UserName jdoe              # light reset (default)
.\Reset-EdgeUser.ps1 -UserName jdoe -Mode Full   # full reset
```

## Reset-EdgeUser.ps1

This is the same file used in NinjaOne and by hand.

```powershell
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
```

## Restore after a full reset

Close Edge first. Edge must have launched once so the new `Default` folder exists.

| File in `Default` | Restore? |
| --- | --- |
| `Bookmarks` | Yes. Safe. |
| `Login Data` (passwords), `History` | Usually. First suspects if the fault returns. |
| `Preferences`, `Secure Preferences`, `Local State` | No. Likely source of the fault. |

```powershell
$edgeRoot = 'C:\Users\jdoe\AppData\Local\Microsoft\Edge'
$old = "$edgeRoot\User Data.bak-20261014-101500\Default"
$new = "$edgeRoot\User Data\Default"
Copy-Item -LiteralPath "$old\Bookmarks" -Destination $new -Force
```

## Rollback

Rollback is manual. Run these from an elevated session on the device, using the backup path from the NinjaOne output. Have the user close Edge or sign out first.

**Full:**

```powershell
$edgeRoot = 'C:\Users\jdoe\AppData\Local\Microsoft\Edge'
Rename-Item -LiteralPath "$edgeRoot\User Data" -NewName 'User Data.failed'
Rename-Item -LiteralPath "$edgeRoot\User Data.bak-20261014-101500" -NewName 'User Data'
```

**Light:**

```powershell
$edgeRoot = 'C:\Users\jdoe\AppData\Local\Microsoft\Edge'
$backup   = "$edgeRoot\EdgeReset-Light.bak-20261014-101500"
$userData = "$edgeRoot\User Data"
Copy-Item -LiteralPath "$backup\Local State" -Destination $userData -Force
Get-ChildItem -LiteralPath $backup -Directory | ForEach-Object {
    $target = Join-Path $userData $_.Name
    Copy-Item -Path (Join-Path $_.FullName '*') -Destination $target -Force
}
```

## Gotchas

- **Target User is the profile folder name**, not the sign-in name. A `DOMAIN\` or `AzureAD\` prefix is stripped. On a mismatch, the script lists every profile on the device in the output.
- **Never name the variable "User Name".** `$env:userName` collides with the built-in `USERNAME`, which is the computer account under SYSTEM.
- **Parameters field overrides variables.** Leave it empty in NinjaOne.
- **Run as must be System.** `#Requires -RunAsAdministrator` blocks a logged-on-user run.
- **"File in use" on rename.** Something else holds the files (AV, sync client, startup boost relaunch). Sign the user out and rerun.
- **Policy check is silent when the user is signed out.** `HKU\<SID>` is only loaded during their session.
- **Profile containers or redirected AppData\Local.** `User Data` may only exist while the user is signed in.
- **The diagnostic test also fails.** The problem isn't the user's data. Check AppLocker or other per-user controls, then repair via Settings > Apps > Installed apps > Microsoft Edge > Modify.

## Change log

### **NinjaOne version (Oct 14, 2026)**

- Input comes from NinjaOne script variables `targetUser` and `resetMode`, with parameter fallback for manual runs.
- Blank and malformed input is validated; a domain prefix is stripped; an empty mode defaults to Light.
- On a profile mismatch, the script lists every profile on the device instead of failing silently.
- All output uses `Write-Output` for the activity log and ends in a single `Result:` line, with exit code 0 or 1.
- A locked-file failure prints a sign-out hint.

## References

- [Microsoft Edge policies](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies)
- [Chromium user data directory](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md)
- [Get-CimInstance](https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/get-ciminstance)
- [Invoke-CimMethod](https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/invoke-cimmethod)
- [NinjaOne automation script variable types](https://www.ninjaone.com/docs/endpoint-management/scripting-and-automation/automation-script-variable-types/)
- [Win32_Process GetOwnerSid](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/getownersid-method-in-class-win32-process)
