#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys Claude Desktop (MSIX, machine-wide) and enables the prerequisite for Claude Cowork.
.DESCRIPTION
    Intended to run as a NinjaOne script (executes as SYSTEM). It:
      1. Enables the Windows "Virtual Machine Platform" optional feature (required for Cowork).
      2. Downloads the latest Claude Desktop MSIX for the detected CPU architecture.
      3. Provisions it machine-wide via DISM/Appx so it's available to every user, including
         future ones — this works from a SYSTEM context without a logged-in user.
    Exit codes:
      0     - Success, no reboot needed
      3010  - Success, but a reboot is required before Cowork's VM Platform feature is active
      1     - Failure (see console/NinjaOne output for details)
#>

[CmdletBinding()]
param(
    [switch]$DisableAutoUpdates
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Write-Log {
    param([string]$Message)
    Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

$rebootRequired = $false

try {
    # 1. Enable Virtual Machine Platform (required for Claude Cowork)
    Write-Log "Checking Virtual Machine Platform optional feature..."
    $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
    if ($vmp.State -ne 'Enabled') {
        Write-Log "Enabling Virtual Machine Platform..."
        $result = Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart
        if ($result.RestartNeeded) {
            $rebootRequired = $true
            Write-Log "Virtual Machine Platform enabled; a reboot is required for it to take effect."
        }
        else {
            Write-Log "Virtual Machine Platform enabled."
        }
    }
    else {
        Write-Log "Virtual Machine Platform is already enabled."
    }

    # 2. Determine architecture and download URL
    $arch = $env:PROCESSOR_ARCHITECTURE
    switch ($arch) {
        'AMD64' { $downloadUrl = 'https://claude.ai/api/desktop/win32/x64/msix/latest/redirect' }
        'ARM64' { $downloadUrl = 'https://claude.ai/api/desktop/win32/arm64/msix/latest/redirect' }
        default { throw "Unsupported architecture: $arch" }
    }

    $workDir = Join-Path $env:TEMP "ClaudeDesktopDeploy"
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $msixPath = Join-Path $workDir 'Claude.msix'

    Write-Log "Downloading Claude Desktop MSIX ($arch) from $downloadUrl ..."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $msixPath -UseBasicParsing

    if (-not (Test-Path $msixPath) -or (Get-Item $msixPath).Length -eq 0) {
        throw "Download failed or produced an empty file at $msixPath"
    }

    # 3. Install machine-wide (provisioned for all users, works under SYSTEM)
    Write-Log "Provisioning Claude Desktop machine-wide..."
    Add-AppxProvisionedPackage -Online -PackagePath $msixPath -SkipLicense -Regions "all" | Out-Null
    Write-Log "Claude Desktop provisioned successfully."

    # 4. Optional: disable Claude's in-app auto-updater so it doesn't fight RMM-managed updates
    if ($DisableAutoUpdates) {
        Write-Log "Setting disableAutoUpdates policy..."
        $policyPath = 'HKLM:\SOFTWARE\Policies\Anthropic\Claude'
        New-Item -Path $policyPath -Force | Out-Null
        New-ItemProperty -Path $policyPath -Name 'disableAutoUpdates' -Value 1 -PropertyType DWord -Force | Out-Null
    }

    # Cleanup
    Remove-Item -Path $msixPath -Force -ErrorAction SilentlyContinue

    if ($rebootRequired) {
        Write-Log "Deployment complete. REBOOT REQUIRED before Cowork's VM Platform feature is active."
        exit 3010
    }
    else {
        Write-Log "Deployment complete."
        exit 0
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
