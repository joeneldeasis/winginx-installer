[CmdletBinding()]
param(
    [string]$NginxServiceName = 'winginx-nginx',
    [string]$PhpServiceName = 'winginx-php',
    [string]$NginxRoot = 'C:\winginx\nginx',
    [switch]$SkipPhp,
    [switch]$KillOrphans,
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

function Stop-WinginxService {
    param(
        [string]$Name,
        [int]$TimeoutSeconds
    )

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Write-Warning "Service '$Name' was not found."
        return
    }

    if ($service.Status -eq 'Stopped') {
        Write-Host "$Name is already stopped."
        return
    }

    Write-Host "Stopping $Name..."
    Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue

    try {
        Wait-ForServiceStatus -Name $Name -DesiredStatus 'Stopped' -TimeoutSeconds $TimeoutSeconds | Out-Null
        Write-Host "$Name stopped."
    }
    catch {
        Write-Warning $_.Exception.Message
    }
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell session.'
}

$nginxService = Get-Service -Name $NginxServiceName -ErrorAction SilentlyContinue
if ($null -eq $nginxService) {
    throw "Service '$NginxServiceName' was not found. Install winginx first."
}

# Stop nginx first (depends on PHP), then PHP.
Stop-WinginxService -Name $NginxServiceName -TimeoutSeconds $TimeoutSeconds

$nginxExe = Join-Path -Path $NginxRoot -ChildPath 'nginx.exe'
if (Test-Path -Path $nginxExe) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & $nginxExe -p $NginxRoot -s quit 2>&1 | Out-Null
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

if ($KillOrphans -or (Get-Process -Name nginx -ErrorAction SilentlyContinue)) {
    Write-Host 'Stopping leftover nginx processes...'
    Get-Process -Name nginx -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

if (-not $SkipPhp) {
    Stop-WinginxService -Name $PhpServiceName -TimeoutSeconds $TimeoutSeconds

    if ($KillOrphans -or (Get-Process -Name php-cgi -ErrorAction SilentlyContinue)) {
        Write-Host 'Stopping leftover php-cgi processes...'
        Get-Process -Name php-cgi -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
}

Write-Host 'Winginx services stop complete.'
Get-Service -Name $NginxServiceName, $PhpServiceName -ErrorAction SilentlyContinue |
    Format-Table Name, Status, StartType -AutoSize
