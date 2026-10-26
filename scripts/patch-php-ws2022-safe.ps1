[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\winginx',
    [string]$PhpVersion = '8.2.35',
    [ValidateSet('x64', 'x86')]
    [string]$Architecture = 'x64',
    [ValidateSet('nts', 'ts')]
    [string]$PhpThreadModel = 'nts',
    [string]$PhpCompiler = 'vs16',
    [string]$PackageRoot = '',
    [string]$NginxServiceName = 'winginx-nginx',
    [string]$PhpServiceName = 'winginx-php',
    [switch]$Offline,
    [switch]$SkipIniMitigations,
    [string]$SimulateInstalledVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows Server 2022 (and other winginx hosts): PHP vulnerability patch entry point.
# This wrapper ONLY replaces files under InstallRoot\php. It never runs install.ps1
# and never deletes or edits nginx configuration (conf\nginx.conf, conf\conf.d\*).

$ScriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$patchScript = Join-Path -Path $ScriptRoot -ChildPath 'patch-php-php2shell.ps1'

function Get-NginxConfigManifest {
    param([string]$Root)

    $manifest = @{}
    $nginxRoot = Join-Path -Path $Root -ChildPath 'nginx'
    $paths = @(
        (Join-Path -Path $nginxRoot -ChildPath 'conf\nginx.conf')
    )

    $confDir = Join-Path -Path $nginxRoot -ChildPath 'conf\conf.d'
    if (Test-Path -LiteralPath $confDir) {
        $paths += @(
            Get-ChildItem -Path $confDir -File -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName }
        )
    }

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        $relative = $path.Substring($nginxRoot.Length).TrimStart('\')
        $manifest[$relative] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }

    return $manifest
}

function Assert-NginxConfigManifestUnchanged {
    param(
        [hashtable]$Before,
        [hashtable]$After
    )

    foreach ($relativePath in $Before.Keys) {
        if (-not $After.ContainsKey($relativePath)) {
            throw "nginx configuration was removed during PHP patch: $relativePath"
        }

        if ($Before[$relativePath] -ne $After[$relativePath]) {
            throw "nginx configuration was modified during PHP patch: $relativePath"
        }
    }

    foreach ($relativePath in $After.Keys) {
        if (-not $Before.ContainsKey($relativePath)) {
            throw "nginx configuration was added during PHP patch: $relativePath"
        }
    }
}

if (-not (Test-Path -LiteralPath $patchScript)) {
    throw "Missing patch script: $patchScript"
}

Write-Host 'patch-php-ws2022-safe: PHP-only update (php2shell). nginx configuration will not be changed.'
$configBefore = Get-NginxConfigManifest -Root $InstallRoot
Write-Host ("nginx config snapshot: {0} file(s) under conf\ and conf.d\" -f $configBefore.Count)

& $patchScript @PSBoundParameters
$patchExit = $LASTEXITCODE
if ($patchExit -ne 0 -and $null -ne $patchExit) {
    exit $patchExit
}

$configAfter = Get-NginxConfigManifest -Root $InstallRoot
Assert-NginxConfigManifestUnchanged -Before $configBefore -After $configAfter
Write-Host 'Verified: nginx configuration files unchanged after PHP patch.'
Write-Host 'patch-php-ws2022-safe complete.'
exit 0
