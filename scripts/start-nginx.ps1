[CmdletBinding()]
param(
    [string]$NginxServiceName = 'winginx-nginx',
    [string]$PhpServiceName = 'winginx-php',
    [string]$NginxRoot = 'C:\winginx\nginx',
    [switch]$IncludePhp,
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

if ($IncludePhp) {
    $phpService = Get-Service -Name $PhpServiceName -ErrorAction SilentlyContinue
    if ($null -eq $phpService) {
        throw "Service '$PhpServiceName' was not found."
    }

    if ($phpService.Status -ne 'Running') {
        Write-Host "Starting $PhpServiceName..."
        Start-Service -Name $PhpServiceName
        Wait-ForServiceStatus -Name $PhpServiceName -DesiredStatus 'Running' -TimeoutSeconds $TimeoutSeconds | Out-Null
    }
}

$nginxExe = Join-Path -Path $NginxRoot -ChildPath 'nginx.exe'
if (Test-Path -Path $nginxExe) {
    Write-Host "Testing nginx config under '$NginxRoot'..."
    & $nginxExe -t -p $NginxRoot
    if ($LASTEXITCODE -ne 0) {
        throw "nginx config test failed for '$NginxRoot'."
    }
}

if ($service.Status -eq 'Running') {
    Write-Host "$NginxServiceName is already running."
}
elseif ($service.Status -eq 'Paused') {
    Write-Host "$NginxServiceName is paused. Recovering..."
    Stop-Service -Name $NginxServiceName -Force -ErrorAction SilentlyContinue
    Get-Process -Name nginx -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service -Name $NginxServiceName
    Wait-ForServiceStatus -Name $NginxServiceName -DesiredStatus 'Running' -TimeoutSeconds $TimeoutSeconds | Out-Null
    Write-Host "$NginxServiceName started."
}
else {
    Write-Host "Starting $NginxServiceName..."
    Start-Service -Name $NginxServiceName
    Wait-ForServiceStatus -Name $NginxServiceName -DesiredStatus 'Running' -TimeoutSeconds $TimeoutSeconds | Out-Null
    Write-Host "$NginxServiceName started."
}

Get-Service -Name $NginxServiceName, $PhpServiceName -ErrorAction SilentlyContinue |
    Format-Table Name, Status, StartType -AutoSize
