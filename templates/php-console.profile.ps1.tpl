$env:WINGINX_ROOT = '{{INSTALL_ROOT}}'
$env:WINGINX_PHP_ROOT = '{{PHP_ROOT}}'
$env:WINGINX_COMPOSER = '{{COMPOSER_PHAR}}'
$env:Path = '{{BIN_DIR}};{{PHP_ROOT}};' + $env:Path

function Invoke-WinginxPhp {
    & '{{PHP_EXE}}' -c '{{PHP_INI}}' @args
}

function php {
    if ($args.Count -gt 0 -and $args[0] -eq 'composer') {
        $composerArgs = @()
        if ($args.Count -gt 1) {
            $composerArgs = $args[1..($args.Count - 1)]
        }

        Invoke-WinginxPhp '{{COMPOSER_PHAR}}' @composerArgs
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

        Invoke-WinginxPhp '.\artisan' @artisanArgs
        return
    }

    Invoke-WinginxPhp @args
}

function composer {
    Invoke-WinginxPhp '{{COMPOSER_PHAR}}' @args
}

function artisan {
    if (-not (Test-Path -Path '.\artisan')) {
        Write-Error 'artisan was not found in the current directory. Change into a Laravel project folder first.'
        return
    }

    Invoke-WinginxPhp '.\artisan' @args
}

Write-Host 'winginx PHP console'
Write-Host "PHP:      {{PHP_ROOT}}"
Write-Host "Composer: {{COMPOSER_PHAR}}"
Write-Host ''
Write-Host 'Available commands:'
Write-Host '  php -v'
Write-Host '  composer -V'
Write-Host '  php composer -V'
Write-Host '  artisan list          (from a Laravel project directory)'
Write-Host '  php artisan list      (from a Laravel project directory)'
Write-Host '  composer create-project laravel/laravel app'
Write-Host ''
