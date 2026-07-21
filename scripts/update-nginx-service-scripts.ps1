[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\winginx',
    [string]$SourceRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell session.'
}

if (-not (Test-Path -Path $InstallRoot)) {
    throw "Install root '$InstallRoot' was not found."
}

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = $scriptRoot
}

$startSource = Join-Path -Path $SourceRoot -ChildPath 'start-nginx.ps1'
$stopSource = Join-Path -Path $SourceRoot -ChildPath 'stop-nginx.ps1'

if (-not (Test-Path -Path $startSource)) {
    throw "Missing source script '$startSource'."
}

if (-not (Test-Path -Path $stopSource)) {
    throw "Missing source script '$stopSource'."
}

$toolsRoot = Join-Path -Path $InstallRoot -ChildPath 'tools'
$binDir = Join-Path -Path $toolsRoot -ChildPath 'bin'
$nginxRoot = Join-Path -Path $InstallRoot -ChildPath 'nginx'

Ensure-Directory -Path $toolsRoot
Ensure-Directory -Path $binDir

$startDest = Join-Path -Path $toolsRoot -ChildPath 'start-nginx.ps1'
$stopDest = Join-Path -Path $toolsRoot -ChildPath 'stop-nginx.ps1'

Copy-Item -Path $startSource -Destination $startDest -Force
Copy-Item -Path $stopSource -Destination $stopDest -Force

$startCmd = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "$startDest" -NginxRoot "$nginxRoot" %*
"@

$stopCmd = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "$stopDest" -NginxRoot "$nginxRoot" %*
"@

Set-Content -Path (Join-Path -Path $binDir -ChildPath 'start-nginx.cmd') -Value $startCmd -Encoding ASCII
Set-Content -Path (Join-Path -Path $binDir -ChildPath 'stop-nginx.cmd') -Value $stopCmd -Encoding ASCII

Write-Host 'Updated nginx service scripts on the installed winginx server.'
Write-Host "Install root: $InstallRoot"
Write-Host "Start: powershell -ExecutionPolicy Bypass -File `"$startDest`""
Write-Host "Stop:  powershell -ExecutionPolicy Bypass -File `"$stopDest`""
Write-Host "CMD:   $binDir\start-nginx.cmd"
Write-Host "CMD:   $binDir\stop-nginx.cmd"
Write-Host ''
Write-Host 'Examples (elevated):'
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$startDest`""
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$startDest`" -IncludePhp"
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$stopDest`" -KillOrphans"
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$stopDest`" -IncludePhp -KillOrphans"
