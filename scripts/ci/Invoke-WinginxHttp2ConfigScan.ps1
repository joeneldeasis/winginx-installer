# Mirrors docs/winginx-check-http2.md for CI. Exits 0 when commands succeed; does not require http2 to be configured.
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\winginx'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    Select-String -Pattern 'http2')
$scan1 | ForEach-Object { Write-Host $_.Path, $_.LineNumber, $_.Line }

Write-Host "=== HTTP/2 scan 2: pattern variants ==="
$pattern = 'http2|http2\s*on|http2\s*off|listen\s+.*http2'
$scan2 = @(Get-ChildItem -Path $nginxConf -Recurse -File -Include *.conf, *.conf.disabled -ErrorAction Stop |
    Select-String -Pattern $pattern -AllMatches)
$scan2 | ForEach-Object { Write-Host $_.Path, $_.LineNumber, $_.Line }

Write-Host "=== HTTP/2 scan 3: nginx.conf + conf.d ==="
$paths = @(
    (Join-Path -Path $nginxConf -ChildPath 'nginx.conf')
)
$paths += @(Get-ChildItem -Path (Join-Path -Path $nginxConf -ChildPath 'conf.d') -Filter '*.conf' -File -ErrorAction SilentlyContinue |
    ForEach-Object { $_.FullName })
$scan3 = @(Select-String -Path $paths -Pattern 'http2' -ErrorAction SilentlyContinue)
$scan3 | ForEach-Object { Write-Host $_.Path, $_.LineNumber, $_.Line }

Write-Host "=== HTTP/2 scan 4: listen directives ==="
$listenLines = @(Get-ChildItem -Path $nginxConf -Recurse -Filter *.conf -File |
    Select-String -Pattern '^\s*listen\s+')
if ($listenLines.Count -eq 0) {
    throw 'No listen directives found under nginx conf (unexpected for winginx install).'
}

$listenLines | ForEach-Object { Write-Host $_.Path, $_.LineNumber, $_.Line }

Write-Host "=== HTTP/2 scan 5: nginx version ==="
$versionLine = & $nginxExe -v 2>&1 | Select-Object -First 1
Write-Host $versionLine
if ("$versionLine" -notmatch 'nginx/') {
    throw "nginx -v did not return a version line: $versionLine"
}

Write-Host "HTTP/2 config scan completed (http2 match count on stock install may be 0)."