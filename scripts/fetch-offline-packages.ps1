[CmdletBinding()]
param(
    [string]$PackageRoot = '',
    [string]$PhpVersion = '8.2',
    [string]$NginxVersion = '1.31.2',
    [ValidateSet('x64', 'x86')]
    [string]$Architecture = 'x64',
    [ValidateSet('nts', 'ts')]
    [string]$PhpThreadModel = 'nts',
    [string]$PhpCompiler = 'vs16',
    [string]$PhpBaseUrl = 'https://downloads.php.net/~windows/releases',
    [string]$NginxBaseUrl = 'https://nginx.org/download',
    [string]$NssmVersion = '2.24',
    [string]$ComposerUrl = 'https://getcomposer.org/download/latest-stable/composer.phar'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot = Split-Path -Path $ScriptRoot -Parent

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $PackageRoot = Join-Path -Path $RepoRoot -ChildPath 'packages'
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

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Download-File {
    param(
        [string]$Uri,
        [string]$DestinationPath
    )

    Write-Host "Downloading $Uri"
    Invoke-WebRequest -Uri $Uri -OutFile $DestinationPath -UseBasicParsing
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

function Resolve-LatestPhpVersion {
    param(
        [string]$VersionSelector,
        [string]$ThreadModel,
        [string]$Compiler,
        [string]$CpuArch,
        [string]$BaseUrl
    )

    if ($VersionSelector -match '^\d+\.\d+\.\d+$') {
        return $VersionSelector
    }

    $manifestUri = "$BaseUrl/releases.json"
    $response = Invoke-WebRequest -Uri $manifestUri -UseBasicParsing
    $manifest = $response.Content | ConvertFrom-Json
    if (-not ($manifest.PSObject.Properties.Name -contains $VersionSelector)) {
        throw "PHP release line '$VersionSelector' was not found in releases.json."
    }

    $release = $manifest.$VersionSelector
    $threadPrefix = if ($ThreadModel -eq 'nts') { 'nts' } else { 'ts' }
    $buildKey = "$threadPrefix-$Compiler-$CpuArch"
    if (-not ($release.PSObject.Properties.Name -contains $buildKey)) {
        throw "PHP build '$buildKey' is not available for release line '$VersionSelector'."
    }

    return [string]$release.version
}

function Download-FileWithFallbacks {
    param(
        [string[]]$Uris,
        [string]$DestinationPath
    )

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($uri in $Uris) {
        try {
            Download-File -Uri $uri -DestinationPath $DestinationPath
            $bytes = [System.IO.File]::ReadAllBytes($DestinationPath)
            if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B) {
                return
            }

            [void]$errors.Add("Download from '$uri' was not a valid ZIP archive.")
        }
        catch {
            [void]$errors.Add("Download failed for '$uri': $($_.Exception.Message)")
        }
    }

    throw ("Unable to download NSSM from any configured source.`n" + ($errors -join "`n"))
}

Enable-TlsSecurityProtocols
Ensure-Directory -Path $PackageRoot

$resolvedPhpVersion = Resolve-LatestPhpVersion `
    -VersionSelector $PhpVersion `
    -ThreadModel $PhpThreadModel `
    -Compiler $PhpCompiler `
    -CpuArch $Architecture `
    -BaseUrl $PhpBaseUrl

$phpArchiveName = Get-PhpArchiveName -Version $resolvedPhpVersion -ThreadModel $PhpThreadModel -Compiler $PhpCompiler -CpuArch $Architecture
$phpArchivePath = Join-Path -Path $PackageRoot -ChildPath $phpArchiveName
$nginxArchiveName = "nginx-$NginxVersion.zip"
$nginxArchivePath = Join-Path -Path $PackageRoot -ChildPath $nginxArchiveName
$nssmArchivePath = Join-Path -Path $PackageRoot -ChildPath "nssm-$NssmVersion.zip"
$composerPath = Join-Path -Path $PackageRoot -ChildPath 'composer.phar'

Download-File -Uri "$PhpBaseUrl/$phpArchiveName" -DestinationPath $phpArchivePath
Download-File -Uri "$NginxBaseUrl/$nginxArchiveName" -DestinationPath $nginxArchivePath
Download-File -Uri $ComposerUrl -DestinationPath $composerPath

$nssmUrls = @(
    "https://nssm.cc/release/nssm-$NssmVersion.zip"
    "https://web.archive.org/web/2024id_/https://nssm.cc/release/nssm-$NssmVersion.zip"
)

try {
    Download-FileWithFallbacks -Uris $nssmUrls -DestinationPath $nssmArchivePath
}
catch {
    Write-Warning $_.Exception.Message
    $fawnoUrl = if ($Architecture -eq 'x86') {
        'https://github.com/fawno/nssm.cc/releases/download/v2.24.1/nssm-v2.24.1-Win32.zip'
    }
    else {
        'https://github.com/fawno/nssm.cc/releases/download/v2.24.1/nssm-v2.24.1-Win64.zip'
    }

    Download-File -Uri $fawnoUrl -DestinationPath $nssmArchivePath
}

Write-Host ''
Write-Host 'Offline package bundle ready.'
Write-Host "Package root: $PackageRoot"
Write-Host "PHP: $phpArchiveName"
Write-Host "nginx: $nginxArchiveName"
Write-Host "NSSM: $(Split-Path -Path $nssmArchivePath -Leaf)"
Write-Host 'Composer: composer.phar'
Write-Host ''
Write-Host 'Copy the packages folder with this repository to the offline host, then run:'
Write-Host '  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Offline'
