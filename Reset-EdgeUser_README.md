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

## Run (elevated, or NinjaOne as SYSTEM)

```powershell
.\Reset-EdgeUser.ps1 -UserName jdoe              # light reset (default)
.\Reset-EdgeUser.ps1 -UserName jdoe -Mode Full   # full reset
```

## Reset-EdgeUser.ps1

```powershell
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Resets Microsoft Edge user data for one local user profile.
.DESCRIPTION
    Light: moves Local State, Preferences and Secure Preferences into a backup folder
           (settings reset; bookmarks, passwords and history stay in place).
    Full:  renames the entire User Data folder (Edge starts as a first run).
    Nothing is deleted. Every change is a rename or move into a timestamped backup.
.PARAMETER UserName
    The user's profile FOLDER name under C:\Users (may differ from the sign-in name).
#>
param(
    [Parameter(Mandatory)][string]$UserName,
    [ValidateSet('Light','Full')][string]$Mode = 'Light'
)

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# Resolve the target profile ($env:LOCALAPPDATA is the caller's, not the user's)
$userProfile = Get-CimInstance -ClassName Win32_UserProfile |
    Where-Object { -not $_.Special -and (Split-Path $_.LocalPath -Leaf) -eq $UserName }
if (@($userProfile).Count -ne 1) {
    throw "Expected one profile for '$UserName', found $(@($userProfile).Count)."
}

$edgeData = Join-Path $userProfile.LocalPath 'AppData\Local\Microsoft\Edge\User Data'
if (-not (Test-Path -LiteralPath $edgeData)) { throw "No Edge user data at $edgeData" }

# Report user-scoped Edge policies (hive is only loaded while the user is signed in)
$polKey = "Registry::HKEY_USERS\$($userProfile.SID)\Software\Policies\Microsoft\Edge"
if ($userProfile.Loaded -and (Test-Path -LiteralPath $polKey)) {
    Write-Warning 'User-scoped Edge policies present:'
    Get-ItemProperty -LiteralPath $polKey |
        Select-Object -Property * -ExcludeProperty PS* | Format-List
}

# Stop only msedge.exe owned by this profile's SID (matches even if the sign-in
# name differs from the folder name). msedgewebview2.exe (Teams, Outlook) is untouched.
Get-CimInstance -ClassName Win32_Process -Filter "Name = 'msedge.exe'" |
    Where-Object {
        $owner = $_ | Invoke-CimMethod -MethodName GetOwnerSid -ErrorAction SilentlyContinue
        $owner.Sid -eq $userProfile.SID
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

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
        Write-Output "Light reset complete. Backup: $backup"
    }
    'Full' {
        $newName = "User Data.bak-$stamp"
        $backup = Join-Path (Split-Path $edgeData) $newName
        Rename-Item -LiteralPath $edgeData -NewName $newName
        Write-Output "Full reset complete. Backup: $backup"
    }
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

Have the user close Edge or sign out first.

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

- **`-UserName` is the profile folder name**, not the sign-in name. Zero or two matches means you used the wrong one.
- **"File in use" on rename.** Something else holds the files (AV, sync client, startup boost relaunch). Sign the user out and rerun.
- **Policy check is silent when the user is signed out.** `HKU\<SID>` is only loaded during their session.
- **Profile containers or redirected AppData\Local.** `User Data` may only exist while the user is signed in.
- **The diagnostic test also fails.** The problem isn't the user's data. Check AppLocker or other per-user controls, then repair via Settings > Apps > Installed apps > Microsoft Edge > Modify.

## References

- [Microsoft Edge policies](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies)
- [Chromium user data directory](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md)
- [Get-CimInstance](https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/get-ciminstance)
- [Invoke-CimMethod](https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/invoke-cimmethod)
- [Win32_Process GetOwnerSid](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/getownersid-method-in-class-win32-process)

## NinjaOne Automation Configuration

Add two variables using the **Add** dropdown next to "Script variables."

### **Variable 1: pick "String/Text"**

| Field | Value |
| --- | --- |
| Name | `Target User` |
| Variable name (auto-generated) | Should read `targetUser`. Fix it if it doesn't. |
| Description | `Profile folder name under C:\Users (e.g. jdoe). DOMAIN\ or AzureAD\ prefix is OK.` |
| Mandatory | On |
| Default value | Leave blank |

### **Variable 2: pick "Drop-down"**

| Field | Value |
| --- | --- |
| Name | `Reset Mode` |
| Variable name (auto-generated) | Should read `resetMode` |
| Description | `Light: settings only, keeps bookmarks/passwords/history. Full: first-run Edge.` |
| Options | `Light`, `Full` (exact spelling, since the script compares against these values) |
| Default | `Light` |
| Mandatory | On |

**Leave the Parameters field below empty.** Anything you put there is passed as `-UserName` or `-Mode` and overrides the variables.

The variable name matters more than the display name. NinjaOne generates it from the Name you type, and the script reads exactly `$env:targetUser` and `$env:resetMode`. If NinjaOne produces something different (for example `targetuser` or `target_user`), you have two options: change the name in NinjaOne to match, or edit the two defaults in the script's `param()` block to match what NinjaOne generated. Casing doesn't matter on Windows, but underscores and spelling do.

The rest of your screenshot looks right: PowerShell, Windows, All architectures, and Run as System.
