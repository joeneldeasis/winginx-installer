[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\winginx',
    [string]$PhpVersion = '8.2.35',
    [ValidateSet('x64', 'x86')]
    [string]$Architecture = 'x64',
    [ValidateSet('nts', 'ts')]
    [string]$PhpThreadModel = 'nts',
    [string]$PhpCompiler = 'vs16',
    [string]$PhpBaseUrl = 'https://downloads.php.net/~windows/releases',
    [string]$PackageRoot = '',
    [string]$NginxServiceName = 'winginx-nginx',
    [string]$PhpServiceName = 'winginx-php',
    [switch]$Offline,
    [switch]$SkipIniMitigations
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot = Split-Path -Path $ScriptRoot -Parent
. (Join-Path -Path $ScriptRoot -ChildPath 'lib\PhpReleaseSecurity.ps1')

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

function Enable-TlsSecurityProtocols {
    $names = [enum]::GetNames([Net.SecurityProtocolType])
    if ($names -notcontains 'Tls12') {
        throw 'This host does not support TLS 1.2, which is required for HTTPS downloads.'
    }

    $protocols = [Net.SecurityProtocolType]::Tls12
    if ($names -contains 'Tls13') {
        $protocols = $protocols -bor [Net.SecurityProtocolType]::Tls13
    }

    [Net.ServicePointManager]::SecurityProtocol = $protocols
}

function Get-PhpArchiveName {
    param(
        [string]$Version,
        [string]$ThreadModel,
        [string]$Compiler,
        [string]$CpuArch
    )

    $threadSegment = if ($ThreadModel -eq 'nts') { '-nts' } else { '' }
    return "php-$Version$threadSegment-Win32-$Compiler-$CpuArch.zip"
}

function Download-File {
    param(
        [string]$Uri,
        [string]$DestinationPath
    )

    Write-Host "Downloading $Uri"
    Invoke-WebRequest -Uri $Uri -OutFile $DestinationPath -UseBasicParsing
}

function Expand-ZipArchiveToDirectory {
    param(
        [string]$ArchivePath,
        [string]$DestinationPath
    )

    if (Test-Path -Path $DestinationPath) {
        Remove-Item -Path $DestinationPath -Recurse -Force
    }

    Expand-Archive -Path $ArchivePath -DestinationPath $DestinationPath -Force
}

function Get-PhpExtractRoot {
    param([string]$ExtractRoot)

    $directChildren = @(Get-ChildItem -Path $ExtractRoot -ErrorAction Stop)
    if ($directChildren.Count -eq 1 -and $directChildren[0].PSIsContainer) {
        return $directChildren[0].FullName
    }

    return $ExtractRoot
}

function Update-PhpTreeFromArchive {
    param(
        [string]$PhpRoot,
        [string]$ArchivePath
    )

    $phpIniPath = Join-Path -Path $PhpRoot -ChildPath 'php.ini'
    $phpIniBackup = Join-Path -Path $PhpRoot -ChildPath ("php.ini.bak-{0}" -f (Get-Date -Format 'yyyyMMddHHmmss'))
    $preserveDirs = @('logs', 'tmp')

    if (Test-Path -Path $phpIniPath) {
        Copy-Item -Path $phpIniPath -Destination $phpIniBackup -Force
        Write-Host "Backed up php.ini to '$phpIniBackup'."
    }

    $tempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("winginx-php-patch-{0}" -f ([Guid]::NewGuid().ToString('N')))
    try {
        Expand-ZipArchiveToDirectory -ArchivePath $ArchivePath -DestinationPath $tempRoot
        $sourceRoot = Get-PhpExtractRoot -ExtractRoot $tempRoot

        Get-ChildItem -Path $sourceRoot -Force | ForEach-Object {
            if ($_.Name -eq 'php.ini' -or $_.Name -eq 'php.ini-development' -or $_.Name -eq 'php.ini-production') {
                return
            }

            if ($preserveDirs -contains $_.Name) {
                return
            }

            $destination = Join-Path -Path $PhpRoot -ChildPath $_.Name
            if ($_.PSIsContainer) {
                if (Test-Path -Path $destination) {
                    Remove-Item -Path $destination -Recurse -Force
                }

                Copy-Item -Path $_.FullName -Destination $destination -Recurse -Force
            }
            else {
                Copy-Item -Path $_.FullName -Destination $destination -Force
            }
        }
    }
    finally {
        if (Test-Path -Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -Path $phpIniBackup) {
        Copy-Item -Path $phpIniBackup -Destination $phpIniPath -Force
    }
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this patch script from an elevated PowerShell session.'
}

$phpRoot = Join-Path -Path $InstallRoot -ChildPath 'php'
$downloadsRoot = Join-Path -Path $InstallRoot -ChildPath 'downloads'
$stopScript = Join-Path -Path $ScriptRoot -ChildPath 'stop-nginx.ps1'
$startScript = Join-Path -Path $ScriptRoot -ChildPath 'start-nginx.ps1'

if (-not (Test-Path -Path $phpRoot)) {
    throw "PHP directory was not found at '$phpRoot'. Pass -InstallRoot if winginx is installed elsewhere."
}

$targetVersion = Resolve-PatchedPhpVersion -VersionSelector $PhpVersion -ResolvedVersion $PhpVersion -RepoRoot $RepoRoot
$currentVersion = Get-InstalledPhpVersion -PhpRoot $phpRoot
Write-Host "Installed PHP: $currentVersion"
Write-Host "Target PHP:    $targetVersion"

if ([version]$currentVersion -ge [version]$targetVersion) {
    Write-Host 'PHP is already at or above the php2shell fix. Applying ini mitigations only.'
    if (-not $SkipIniMitigations) {
        Set-PhpIniPhp2ShellMitigations -PhpIniPath (Join-Path -Path $phpRoot -ChildPath 'php.ini')
    }

    return
}

if (-not (Test-Path -Path $stopScript) -or -not (Test-Path -Path $startScript)) {
    throw "Service helper scripts were not found next to this patch script."
}

Enable-TlsSecurityProtocols
Ensure-Directory -Path $downloadsRoot

$phpArchiveName = Get-PhpArchiveName -Version $targetVersion -ThreadModel $PhpThreadModel -Compiler $PhpCompiler -CpuArch $Architecture
if ($Offline) {
    if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
        $PackageRoot = Join-Path -Path $RepoRoot -ChildPath 'packages'
    }

    $phpArchivePath = Join-Path -Path $PackageRoot -ChildPath $phpArchiveName
    if (-not (Test-Path -Path $phpArchivePath)) {
        throw "Offline PHP archive '$phpArchiveName' was not found in '$PackageRoot'. Run scripts\fetch-offline-packages.ps1 with -PhpVersion $targetVersion first."
    }
}
else {
    $phpArchivePath = Join-Path -Path $downloadsRoot -ChildPath $phpArchiveName
    Download-File -Uri "$PhpBaseUrl/$phpArchiveName" -DestinationPath $phpArchivePath
}

Write-Host 'Stopping winginx services...'
& $stopScript -NginxServiceName $NginxServiceName -PhpServiceName $PhpServiceName -NginxRoot (Join-Path -Path $InstallRoot -ChildPath 'nginx')

try {
    Update-PhpTreeFromArchive -PhpRoot $phpRoot -ArchivePath $phpArchivePath
    if (-not $SkipIniMitigations) {
        Set-PhpIniPhp2ShellMitigations -PhpIniPath (Join-Path -Path $phpRoot -ChildPath 'php.ini')
    }

    $updatedVersion = Get-InstalledPhpVersion -PhpRoot $phpRoot
    Write-Host "PHP binaries updated to $updatedVersion."
}
finally {
    Write-Host 'Starting winginx services...'
    & $startScript -NginxServiceName $NginxServiceName -PhpServiceName $PhpServiceName
}

Write-Host 'php2shell PHP patch complete.'
