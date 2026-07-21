[CmdletBinding()]
param(
    [string]$NginxServiceName = 'winginx-nginx',
    [string]$PhpServiceName = 'winginx-php',
    [string]$NginxRoot = 'C:\winginx\nginx',
    [switch]$IncludePhp,
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

if (-not (Test-IsAdministrator)) {
    throw 'Run this script from an elevated PowerShell session.'
}

$service = Get-Service -Name $NginxServiceName -ErrorAction SilentlyContinue
if ($null -eq $service) {
    throw "Service '$NginxServiceName' was not found. Install winginx first."
}

if ($service.Status -ne 'Stopped') {
    Write-Host "Stopping $NginxServiceName..."
    Stop-Service -Name $NginxServiceName -Force -ErrorAction SilentlyContinue

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

    try {
        Wait-ForServiceStatus -Name $NginxServiceName -DesiredStatus 'Stopped' -TimeoutSeconds $TimeoutSeconds | Out-Null
    }
    catch {
        Write-Warning $_.Exception.Message
    }
}

if ($KillOrphans -or (Get-Process -Name nginx -ErrorAction SilentlyContinue)) {
    Write-Host 'Stopping leftover nginx processes...'
    Get-Process -Name nginx -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

if ($IncludePhp) {
    $phpService = Get-Service -Name $PhpServiceName -ErrorAction SilentlyContinue
    if ($null -ne $phpService -and $phpService.Status -ne 'Stopped') {
        Write-Host "Stopping $PhpServiceName..."
        Stop-Service -Name $PhpServiceName -Force -ErrorAction SilentlyContinue
        Wait-ForServiceStatus -Name $PhpServiceName -DesiredStatus 'Stopped' -TimeoutSeconds $TimeoutSeconds | Out-Null
    }
}

Write-Host "$NginxServiceName stopped."
Get-Service -Name $NginxServiceName, $PhpServiceName -ErrorAction SilentlyContinue |
    Format-Table Name, Status, StartType -AutoSize
