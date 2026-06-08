#
# Copyright (c) Microsoft Corporation. All rights reserved.
#
# Description:
# PowerShell script to build CVM images using Docker via WSL2
# Note: WSL integration must be enabled in Docker Desktop settings:
#   Docker Desktop > Settings > Resources > WSL Integration
#   Toggle ON for your distro, then click 'Apply & Restart'
#
#

param(
    [Parameter(Mandatory=$true)]
    [string]$Username,
    
    [Parameter(Mandatory=$true)]
    [string]$Image,
    
    [string]$Packages,
    [string]$RootfsOverlay,
    [string]$PackageDir,
    [string]$SshKey,
    [switch]$Password,
    [string]$PasswordHash,
    [switch]$PasswordlessSudo,
    [switch]$InsidersFast,
    [switch]$AllowSshPassword,
    [switch]$AllowSerialConsole,
    [switch]$VerboseOutput,
    [string]$WslDistro,
    [switch]$DockerRebuild
)

function RunInWSL {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$WslArgs)
    $cmdArgs = [System.Collections.Generic.List[string]]::new()
    if ($WslDistro) {
        $cmdArgs.Add('-d')
        $cmdArgs.Add($WslDistro)
    }
    $cmdArgs.AddRange([string[]]$WslArgs)
    & wsl $cmdArgs
}

Write-Host "Docker Desktop with WSL2 is required for this build process" -ForegroundColor Yellow
Write-Host ""

# Check if Docker is running
try {
    docker info | Out-Null
} catch {
    Write-Error "Docker is not running. Please start Docker Desktop."
    exit 1
}

# Check if WSL2 backend is being used
$dockerInfo = docker info --format "{{.OSType}}"
if ($dockerInfo -ne "linux") {
    Write-Error "Docker must be configured to use WSL2 backend (Linux containers)"
    Write-Host "To enable WSL2 backend:" -ForegroundColor Yellow
    Write-Host "1. Open Docker Desktop" -ForegroundColor Yellow
    Write-Host "2. Go to Settings > General" -ForegroundColor Yellow
    Write-Host "3. Enable 'Use the WSL 2 based engine'" -ForegroundColor Yellow
    exit 1
}


$wslos = RunInWSL bash -c 'cat /etc/os-release'
$prettyName = ($wslos | Where-Object { $_ -match '^PRETTY_NAME=' }) -replace '^PRETTY_NAME="?([^"]*)"?$', '$1'
Write-Host "WSL OS: $prettyName" -ForegroundColor Cyan
# Convert Windows paths to WSL paths if needed
$scriptDir = $PSScriptRoot
$wslScriptDir = RunInWSL wslpath -a "'$scriptDir'"

Write-Host "Script directory (Windows): $scriptDir" -ForegroundColor Cyan
Write-Host "Script directory (WSL): $wslScriptDir" -ForegroundColor Cyan
Write-Host ""

# Build Docker arguments
$dockerArgs = @(
    "--username", $Username,
    "--image", $Image
)

if ($Packages) { $dockerArgs += "--packages", $Packages }
if ($RootfsOverlay) { $dockerArgs += "--rootfs-overlay", $RootfsOverlay }
if ($PackageDir) { $dockerArgs += "--package-dir", $PackageDir }
if ($SshKey) { $dockerArgs += "--ssh-key", $SshKey }
if ($Password) { $dockerArgs += "--password" }
if ($PasswordHash) { $dockerArgs += "--password-hash", $PasswordHash }
if ($PasswordlessSudo) { $dockerArgs += "--passwordless-sudo" }
if ($InsidersFast) { $dockerArgs += "--insiders-fast" }
if ($AllowSshPassword) { $dockerArgs += "--allow-ssh-password" }
if ($AllowSerialConsole) { $dockerArgs += "--allow-serial-console" }
if ($VerboseOutput) { $dockerArgs += "--verbose-output" }

# Prepare docker-build.sh arguments
$bashArgs = $dockerArgs -join " "
if ($DockerRebuild) {
    $bashArgs = "--docker-rebuild $bashArgs"
}

Write-Host "Executing build via WSL2..." -ForegroundColor Green
Write-Host "Arguments: $bashArgs" -ForegroundColor Cyan
Write-Host ""

# Execute docker-build.sh via WSL
RunInWSL bash -c "cd '$wslScriptDir' && ./docker-build.sh $bashArgs"

$exitCode = $LASTEXITCODE

if ($exitCode -eq 0) {
    Write-Host ""
    Write-Host "Build completed successfully!" -ForegroundColor Green
    Write-Host "Output VHDX location (Windows): $scriptDir\out\$Image" -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Error "Build failed with exit code: $exitCode"
}

exit $exitCode
