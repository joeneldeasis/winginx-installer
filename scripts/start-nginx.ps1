[CmdletBinding()]
param(
    [string]$NginxServiceName = 'winginx-nginx',
    [string]$PhpServiceName = 'winginx-php',
    [string]$NginxRoot = 'C:\winginx\nginx',
    [switch]$SkipPhp,
    [int]$TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Wait-ForServiceStatus {
    param(
        [string]$Name,
        [string]$DesiredStatus,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $service = Get-Service -Name $Name -ErrorAction Stop
        if ($service.Status.ToString() -eq $DesiredStatus) {
            return $service
        }

        Start-Sleep -Seconds 1
    }

    throw "Service '$Name' did not reach '$DesiredStatus' within $TimeoutSeconds seconds."
}

function Start-WinginxService {
    param(
        [string]$Name,
        [int]$TimeoutSeconds
    )

    $service = Get-Service -Name $Name -ErrorAction Stop

    if ($service.Status -eq 'Running') {
        Write-Host "$Name is already running."
        return
    }

    if ($service.Status -eq 'Paused') {
        Write-Host "$Name is paused. Recovering..."
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }

    Write-Host "Starting $Name..."
    Start-Service -Name $Name
    Wait-ForServiceStatus -Name $Name -DesiredStatus 'Running' -TimeoutSeconds $TimeoutSeconds | Out-Null
    Write-Host "$Name started."
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell session.'
}

$nginxService = Get-Service -Name $NginxServiceName -ErrorAction SilentlyContinue
if ($null -eq $nginxService) {
    throw "Service '$NginxServiceName' was not found. Install winginx first."
}

if (-not $SkipPhp) {
    $phpService = Get-Service -Name $PhpServiceName -ErrorAction SilentlyContinue
    if ($null -eq $phpService) {
        throw "Service '$PhpServiceName' was not found."
    }

    if ($phpService.Status -eq 'Paused') {
        Write-Host "$PhpServiceName is paused. Recovering..."
        Stop-Service -Name $PhpServiceName -Force -ErrorAction SilentlyContinue
        Get-Process -Name php-cgi -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }

    Start-WinginxService -Name $PhpServiceName -TimeoutSeconds $TimeoutSeconds
}

$nginxExe = Join-Path -Path $NginxRoot -ChildPath 'nginx.exe'
if (Test-Path -Path $nginxExe) {
    Write-Host "Testing nginx config under '$NginxRoot'..."
    & $nginxExe -t -p $NginxRoot
    if ($LASTEXITCODE -ne 0) {
        throw "nginx config test failed for '$NginxRoot'."
    }
}

if ($nginxService.Status -eq 'Paused') {
    Write-Host "$NginxServiceName is paused. Recovering..."
    Stop-Service -Name $NginxServiceName -Force -ErrorAction SilentlyContinue
    Get-Process -Name nginx -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $nginxService = Get-Service -Name $NginxServiceName
}

Start-WinginxService -Name $NginxServiceName -TimeoutSeconds $TimeoutSeconds

Get-Service -Name $NginxServiceName, $PhpServiceName -ErrorAction SilentlyContinue |
    Format-Table Name, Status, StartType -AutoSize
