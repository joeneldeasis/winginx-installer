[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\winginx',
    [string]$WorkingDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$phpRoot = Join-Path -Path $InstallRoot -ChildPath 'php'
$binDir = Join-Path -Path $InstallRoot -ChildPath 'tools\bin'
$composerPhar = Join-Path -Path $InstallRoot -ChildPath 'tools\composer\composer.phar'
$phpExe = Join-Path -Path $phpRoot -ChildPath 'php.exe'
$profileScript = Join-Path -Path $InstallRoot -ChildPath 'tools\php-console.profile.ps1'
$installedConsole = Join-Path -Path $InstallRoot -ChildPath 'tools\php-console.ps1'

if (-not (Test-Path -Path $phpExe)) {
    throw "PHP was not found at '$phpExe'. Run install.ps1 first."
}

if (-not (Test-Path -Path $composerPhar)) {
    throw "Composer was not found at '$composerPhar'. Run install.ps1 first."
}

$startDirectory = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    $htmlRoot = Join-Path -Path $InstallRoot -ChildPath 'nginx\html'
    if (Test-Path -Path $htmlRoot) { $htmlRoot } else { $InstallRoot }
}
else {
    $WorkingDirectory
}

if (Test-Path -Path $installedConsole) {
    & $installedConsole
    return
}

if (Test-Path -Path $profileScript) {
    $powershellExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $powershellExe -ArgumentList @(
        '-NoExit'
        '-ExecutionPolicy'
        'Bypass'
        '-NoLogo'
        '-File'
        $profileScript
    ) -WorkingDirectory $startDirectory
    return
}

$env:WINGINX_ROOT = $InstallRoot
$env:WINGINX_PHP_ROOT = $phpRoot
$env:WINGINX_COMPOSER = $composerPhar
$env:Path = "$binDir;$phpRoot;" + $env:Path

function global:php {
    if ($args.Count -gt 0 -and $args[0] -eq 'composer') {
        $composerArgs = @()
        if ($args.Count -gt 1) {
            $composerArgs = $args[1..($args.Count - 1)]
        }

        & $phpExe $composerPhar @composerArgs
        return
    }

    if ($args.Count -gt 0 -and $args[0] -eq 'artisan') {
        if (-not (Test-Path -Path '.\artisan')) {
            Write-Error 'artisan was not found in the current directory. Change into a Laravel project folder first.'
            return
        }

        $artisanArgs = @()
        if ($args.Count -gt 1) {
            $artisanArgs = $args[1..($args.Count - 1)]
        }

        & $phpExe '.\artisan' @artisanArgs
        return
    }

    & $phpExe @args
}

function global:composer {
    & $phpExe $composerPhar @args
}

function global:artisan {
    if (-not (Test-Path -Path '.\artisan')) {
        Write-Error 'artisan was not found in the current directory. Change into a Laravel project folder first.'
        return
    }

    & $phpExe '.\artisan' @args
}

Set-Location -LiteralPath $startDirectory
Write-Host 'winginx PHP console (inline session)'
Write-Host "PHP:      $phpRoot"
Write-Host "Composer: $composerPhar"
Write-Host ''
Write-Host 'Available commands: php, composer, artisan, php artisan, php composer'
