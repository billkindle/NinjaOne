# Reset-EdgeMultiUser.ps1

**Updated:** October 15, 2026 · **Applies to:** Windows Server / Windows 11 multi-user hosts (terminal servers), Chromium Edge · **Runs from:** NinjaOne (System) or elevated PowerShell

## What it does

Resets Microsoft Edge user data for **every user profile on a device** in one run, without entering usernames. Use it as a sweeping fix on a terminal server when Edge is broken for many users. For one user on one device, use **Reset-EdgeUser.ps1** and its KB article instead.

The script enumerates every non-system profile under `C:\Users` that has an Edge `User Data` folder. It then resets each one independently in one of two modes:

| Mode | What moves | What the user notices |
| --- | --- | --- |
| **Light** (default) | `Local State`, plus `Preferences` and `Secure Preferences` from `Default` and each `Profile *` folder, into `EdgeReset-Light.bak-<timestamp>` | Startup pages, new tab and search engine reset; extensions may need re-enabling. Bookmarks, passwords and history stay. |
| **Full** | The whole `User Data` folder, renamed to `User Data.bak-<timestamp>` | First-run Edge. Unsynced bookmarks, passwords, history, cookies/sessions, extensions and site permissions appear gone until restored or re-synced. |

Nothing is deleted. Every change is a rename or move into a backup inside the user's own profile, and all backups from one run share the same timestamp.

## Impact and safeguards

- **Preview Only is on by default.** A run reports what it would do and changes nothing until you turn Preview Only off.
- **Signed-in users are skipped by default.** This includes disconnected sessions, since their registry hive is still loaded. Run during a maintenance window after logoffs. Turning on **Include Signed-In Users** closes Edge in active sessions without warning.
- **Only Edge itself is stopped.** For each user being reset, the script stops only `msedge.exe` processes owned by that user's SID. `msedgewebview2.exe` (Teams, Outlook) is untouched.
- **Failures are isolated.** One profile failing (for example, locked files) doesn't stop the sweep. The run still exits 1 so NinjaOne flags it.
- **Prefer Light for a sweep.** Full mode on a terminal server gives every swept user a first-run Edge. Sweep with Light, then use Reset-EdgeUser.ps1 in Full mode for anyone Light didn't fix.

## Before you run: check how profiles are stored

This script only reaches Edge data that sits on the server's local disk.

- **Local profiles:** fully supported.
- **FSLogix profile containers:** a signed-out user's AppData is inside an unattached VHDX and can't be reached. The script prints a warning when `HKLM\SOFTWARE\FSLogix\Profiles\Enabled` = 1.
- **RDS User Profile Disks:** same limitation, and the script can't detect it.

With FSLogix or User Profile Disks, signed-out users show as `SKIPPED: No Edge data` or don't appear at all. In that case a sweep won't help; the fix has to run at user logon instead.

## NinjaOne setup

Script settings: Name **Reset-EdgeMultiUser**, Language **PowerShell**, Operating System **Windows**, Architecture **All**, Run as **System**. Leave the **Parameters** field empty, because anything entered there overrides the variables.

| Name | Type | Variable name | Default | Purpose |
| --- | --- | --- | --- | --- |
| Reset Mode | Drop-down: `Light`, `Full` | `resetMode` | Light | Applies to every profile in the run |
| Preview Only | Checkbox | `previewOnly` | Checked | Report only; no changes |
| Include Signed-In Users | Checkbox | `includeSignedInUsers` | Unchecked | Also reset users with active or disconnected sessions |
| Exclude Users | String/Text, optional | `excludeUsers` | Blank | Profile folder names to never touch, comma- or semicolon-separated |

NinjaOne passes script variables to the script as environment variables, and checkboxes arrive as the strings `true` / `false`. The script reads `$env:resetMode`, `$env:previewOnly`, `$env:includeSignedInUsers` and `$env:excludeUsers`. Confirm the variable names NinjaOne generates match these; casing doesn't matter, but spelling and underscores do.

## Running a sweep

1. **Preview.** Run with defaults (Light, Preview Only checked). Review the `WOULD RESET` list against who you expect, and add admin or service accounts to Exclude Users.
2. **Pilot.** On a non-production host, or with Exclude Users limiting the scope, run with Preview Only unchecked. Confirm the backup folders exist and that Edge opens for the pilot users.
3. **Sweep.** After users are logged off, run with Preview Only unchecked. Record the timestamp from any `Backup:` path in the output, since it identifies this run's backups for rollback.
4. **Follow up.** Rerun for any `FAILED` profiles once those users are signed out. Use Reset-EdgeUser.ps1 in Full mode for individual users Light didn't fix.

## Running by hand (elevated)

Parameters override the NinjaOne variables. Preview Only defaults to **true** when omitted, so a live run needs `-PreviewOnly false`.

```powershell
.\Reset-EdgeMultiUser.ps1                                           # preview, Light, signed-out users
.\Reset-EdgeMultiUser.ps1 -PreviewOnly false                        # live Light sweep
.\Reset-EdgeMultiUser.ps1 -PreviewOnly false -ExcludeUsers 'administrator, svc-backup'
.\Reset-EdgeMultiUser.ps1 -Mode Full -PreviewOnly false             # live Full sweep
```

## Reading the output

Each profile gets one line with its status, followed by a count per status and a final `Result:` line. The sample below is illustrative.

```text
Edge multi-user reset on TS-EXAMPLE01
Mode: Light | Preview only: False | Include signed-in users: False
Excluded: administrator

RESET        asmith: Backup: C:\Users\asmith\AppData\Local\Microsoft\Edge\EdgeReset-Light.bak-20261015-020000
SKIPPED      administrator: Excluded
SKIPPED      bkindle: Signed in
RESET        jdoe: Backup: C:\Users\jdoe\AppData\Local\Microsoft\Edge\EdgeReset-Light.bak-20261015-020000
SKIPPED      svc-backup: No Edge data

Summary:
  RESET        2
  SKIPPED      3
Result: SUCCESS (2 profile(s) reset, Light)
```

| Status / output | Meaning and action |
| --- | --- |
| `RESET` | Reset completed; the backup path follows. |
| `WOULD RESET` | Preview only. Shows the mode and how many Edge processes would be stopped. |
| `SKIPPED: Excluded` | Listed in Exclude Users. |
| `SKIPPED: No Edge data` | No `User Data` folder, or the data is in an unattached profile container. |
| `SKIPPED: Signed in` | Active or disconnected session. Log the user off and rerun, or turn on Include Signed-In Users. |
| `FAILED: ... (files locked ...)` | Something is holding the files. Have the user sign out and rerun. |
| `...; user-scoped Edge policy present` | A policy under that user's HKCU may be the real blocker. Review it. |
| `WARNING: FSLogix profile containers are enabled` | See **Before you run** above. |
| `Result: SUCCESS` / `PREVIEW ONLY` / `FAILED` | Exit code 0 / 0 / 1. |

## Rollback

Rollback is manual and can be done for the whole run at once, using the shared timestamp. Run the block for the mode that was used, from an elevated session on the server, with affected users signed out. To roll back a single user instead, follow the Rolling Back section of the **Reset-EdgeUser** KB.

**Full sweep:**

```powershell
$stamp = '20261015-020000'   # timestamp from the run's Backup: paths
Get-ChildItem -Path 'C:\Users' -Directory | ForEach-Object {
    $edgeRoot = Join-Path $_.FullName 'AppData\Local\Microsoft\Edge'
    $bak = Join-Path $edgeRoot "User Data.bak-$stamp"
    if (Test-Path -LiteralPath $bak) {
        $cur = Join-Path $edgeRoot 'User Data'
        if (Test-Path -LiteralPath $cur) {
            Rename-Item -LiteralPath $cur -NewName "User Data.failed-$stamp"
        }
        Rename-Item -LiteralPath $bak -NewName 'User Data'
        Write-Output "Restored $($_.Name)"
    }
}
```

**Light sweep:**

```powershell
$stamp = '20261015-020000'   # timestamp from the run's Backup: paths
Get-ChildItem -Path 'C:\Users' -Directory | ForEach-Object {
    $user     = $_.Name
    $edgeRoot = Join-Path $_.FullName 'AppData\Local\Microsoft\Edge'
    $backup   = Join-Path $edgeRoot "EdgeReset-Light.bak-$stamp"
    $userData = Join-Path $edgeRoot 'User Data'
    if (Test-Path -LiteralPath $backup) {
        $ls = Join-Path $backup 'Local State'
        if (Test-Path -LiteralPath $ls) {
            Copy-Item -LiteralPath $ls -Destination $userData -Force
        }
        Get-ChildItem -LiteralPath $backup -Directory | ForEach-Object {
            $target = Join-Path $userData $_.Name
            Copy-Item -Path (Join-Path $_.FullName '*') -Destination $target -Force
        }
        Write-Output "Restored $user"
    }
}
```

To restore individual files after a Full sweep (for example, `Bookmarks` for one user), follow Step 4 of the Reset-EdgeUser KB. The same file guidance applies.

## Gotchas

- **Preview is the default, including by hand.** A run that "did nothing" probably had Preview Only on. Check the `Preview only:` line at the top of the output.
- **Disconnected sessions count as signed in.** Log them off (or reboot during the window) before a sweep, or they'll be skipped.
- **Exclude Users matches profile folder names**, such as `jdoe.CHEMSTATION`, not sign-in names. A `DOMAIN\` or `AzureAD\` prefix is stripped.
- **Backups accumulate.** Each run leaves a backup in every reset profile. Plan a cleanup pass once the fix is confirmed; nothing removes them automatically.
- **Parameters field overrides variables.** Leave it empty in NinjaOne.
- **Run as must be System.** `#Requires -RunAsAdministrator` blocks a logged-on-user run.
- **Not a fix for the Edge install.** If Edge fails for a brand-new user too, the problem isn't user data. Check AppLocker or other application controls, then repair Edge.

## Related

- **Reset-EdgeUser.ps1** — single-user version, prompts for Target User.
- **KB Resetting Microsoft Edge for a Single User Using PowerShell** — diagnosis, per-user restore and rollback.

## Change log

### October 15, 2026 — initial version

- Derived from Reset-EdgeUser.ps1 (NinjaOne version). It sweeps all non-system profiles instead of taking a username.
- Adds Preview Only (default on), Include Signed-In Users (default off) and Exclude Users.
- Adds FSLogix detection, a per-profile status line, a status summary, and exit code 1 if any profile fails.
- Takes one Edge process-owner snapshot per run, and uses one shared backup timestamp per run for bulk rollback.

## References

- [NinjaOne automation script variable types](https://www.ninjaone.com/docs/endpoint-management/scripting-and-automation/automation-script-variable-types/)
- [Microsoft Edge policies](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies)
- [Chromium user data directory](https://chromium.googlesource.com/chromium/src/+/main/docs/user_data_dir.md)
- [Get-CimInstance](https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/get-ciminstance)
- [Invoke-CimMethod](https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/invoke-cimmethod)
- [Win32_Process GetOwnerSid](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/getownersid-method-in-class-win32-process)
