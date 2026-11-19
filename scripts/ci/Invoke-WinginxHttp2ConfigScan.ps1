# Mirrors docs/winginx-check-http2.md for CI. Exits 0 when commands succeed; does not require http2 to be configured.
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\winginx'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Http2ConfigPattern = '(?i)(^\s*listen\s+.*\bhttp2\b|^\s*http2\s+(on|off)\s*;)'

$nginxConf = Join-Path -Path $InstallRoot -ChildPath 'nginx\conf'
$nginxExe = Join-Path -Path $InstallRoot -ChildPath 'nginx\nginx.exe'

if (-not (Test-Path -LiteralPath $nginxConf)) {
    throw "nginx conf directory was not found: $nginxConf"
}

if (-not (Test-Path -LiteralPath $nginxExe)) {
    throw "nginx.exe was not found: $nginxExe"
}

Write-Host "=== HTTP/2 scan 1: recursive http2 ==="
$scan1 = @(Get-ChildItem -Path $nginxConf -Recurse -File -Include *.conf, *.conf.disabled -ErrorAction Stop |
    Select-String -Pattern $Http2ConfigPattern)
$scan1 | ForEach-Object { Write-Host $_.Path, $_.LineNumber, $_.Line }

Write-Host "=== HTTP/2 scan 2: pattern variants ==="
$scan2 = @(Get-ChildItem -Path $nginxConf -Recurse -File -Include *.conf, *.conf.disabled -ErrorAction Stop |
    Select-String -Pattern $Http2ConfigPattern -AllMatches)
$scan2 | ForEach-Object { Write-Host $_.Path, $_.LineNumber, $_.Line }

Write-Host "=== HTTP/2 scan 3: nginx.conf + conf.d ==="
$paths = @(
    (Join-Path -Path $nginxConf -ChildPath 'nginx.conf')
)
$paths += @(Get-ChildItem -Path (Join-Path -Path $nginxConf -ChildPath 'conf.d') -Filter '*.conf' -File -ErrorAction SilentlyContinue |
    ForEach-Object { $_.FullName })
$scan3 = @(Select-String -Path $paths -Pattern $Http2ConfigPattern -ErrorAction SilentlyContinue)
$scan3 | ForEach-Object { Write-Host $_.Path, $_.LineNumber, $_.Line }

Write-Host "=== HTTP/2 scan 4: listen directives ==="
$listenLines = @(Get-ChildItem -Path $nginxConf -Recurse -Filter *.conf -File |
    Select-String -Pattern '^\s*listen\s+')
if ($listenLines.Count -eq 0) {
    throw 'No listen directives found under nginx conf (unexpected for winginx install).'
}

$listenLines | ForEach-Object { Write-Host $_.Path, $_.LineNumber, $_.Line }

Write-Host "=== HTTP/2 scan 5: nginx version ==="
$previousErrorAction = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $versionLine = @(& $nginxExe -v 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'nginx/' } | Select-Object -First 1)
}
finally {
    $ErrorActionPreference = $previousErrorAction
}

Write-Host $versionLine
if ([string]::IsNullOrWhiteSpace($versionLine)) {
    throw 'nginx -v did not return a version line.'
}

Write-Host "HTTP/2 config scan completed (http2 match count on stock install may be 0)."