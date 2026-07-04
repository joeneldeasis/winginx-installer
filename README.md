# winginx installer

[![Installer smoke test](https://github.com/joeneldeasis/winginx-installer/actions/workflows/install-test.yml/badge.svg)](https://github.com/joeneldeasis/winginx-installer/actions/workflows/install-test.yml)

`winginx` is a PowerShell-based Windows installer for `nginx` plus native Windows PHP FastCGI.

Because native Windows PHP does not ship `php-fpm`, this project installs `php-cgi.exe` behind `nginx`, registers both through NSSM, and creates an `nginx` layout with `conf\conf.d\*.conf` for virtual hosts.

## What it installs

- `nginx` from `https://nginx.org/download/nginx-<version>.zip`
- PHP from `https://downloads.php.net/~windows/releases/`
- NSSM as the Windows service wrapper for both `nginx` and `php-cgi`
- a default `index.php` health page
- a managed `php.ini` extension block
- `scripts\manage-php-extension.ps1` for interactive and parameter-driven extension search, enable, and install operations

## Layout

By default, running `install.ps1` installs everything under `C:\winginx`.

Default install targets:
- `C:\winginx\nginx` for the `nginx` server files
- `C:\winginx\php` for PHP and `php.ini`
- `C:\winginx\tools` for helper tools such as NSSM
- `C:\winginx\downloads` for downloaded zip archives
- `C:\winginx\nginx\html` for the default web root when `-WebRoot` is not provided

If you pass `-InstallRoot`, the same folder structure is created under that custom path instead.

After install, the target tree looks like this:

```text
C:\winginx\
  downloads\
  tools\
  nginx\
    conf\
      nginx.conf
      conf.d\
        default.conf
    html\
    logs\
    temp\
  php\
    ext\
    logs\
    tmp\
    php.ini
```

## Default extensions

The installer tries to enable these bundled extensions when their DLLs exist in the selected PHP build:

- `bcmath`
- `bz2`
- `curl`
- `exif`
- `fileinfo`
- `gd`
- `gettext`
- `intl`
- `mbstring`
- `mysqli`
- `openssl`
- `pdo_mysql`
- `pdo_sqlite`
- `soap`
- `sockets`
- `sodium`
- `xml`
- `xmlreader`
- `xmlwriter`
- `zip`
- `opcache`

Missing DLLs are skipped with a warning instead of corrupting `php.ini`.

Some common extensions are compiled into the Windows PHP core and do not ship as separate DLLs, so the installer does not try to enable them explicitly:

- `bcmath`
- `xml`
- `xmlreader`
- `xmlwriter`

## Usage

Run from an elevated PowerShell session:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

This command installs to `C:\winginx` unless you override the location with `-InstallRoot`.

Pin explicit versions:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 `
  -PhpVersion 8.2.32 `
  -NginxVersion 1.31.2
```

Use a custom site root and port:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 `
  -InstallRoot C:\winginx `
  -WebRoot C:\sites\default `
  -HttpPort 8080 `
  -ServerName localhost
```

This example still installs `nginx`, PHP, tools, and downloads under `C:\winginx`, but uses `C:\sites\default` as the website document root.

Use a custom install path:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 `
  -InstallRoot D:\winginx
```

This places the stack under:
- `D:\winginx\nginx`
- `D:\winginx\php`
- `D:\winginx\tools`
- `D:\winginx\downloads`
- `D:\winginx\nginx\html` as the default web root unless `-WebRoot` is also set

## Managing extensions

Open or run `scripts\manage-php-extension.ps1` without action parameters to launch the guided helper. This is the simplest flow for users who want the script to walk them through extension discovery and installation choices.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\manage-php-extension.ps1 `
  -PhpRoot C:\winginx\php
```

The guided helper can:
- list bundled and enabled extensions
- search bundled extensions
- enable bundled extensions after confirmation
- search extension names online through the PECL package feed
- prompt for installation of a trusted custom Windows DLL when a bundled DLL is not available

List bundled and enabled extensions:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\manage-php-extension.ps1 `
  -PhpRoot C:\winginx\php `
  -List
```

Search for a bundled extension:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\manage-php-extension.ps1 `
  -PhpRoot C:\winginx\php `
  -Search sql
```

Search extension names online, then optionally enable them if the DLL is already bundled:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\manage-php-extension.ps1 `
  -PhpRoot C:\winginx\php `
  -SearchOnline redis
```

Enable a bundled extension:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\manage-php-extension.ps1 `
  -PhpRoot C:\winginx\php `
  -Enable ldap
```

Install a trusted custom extension DLL and enable it:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\manage-php-extension.ps1 `
  -PhpRoot C:\winginx\php `
  -Install redis `
  -SourcePath C:\downloads\php_redis.dll
```

The helper only edits the managed extension block in `php.ini`, prevents duplicate entries, and fails clearly when an extension is not bundled for the current PHP build. Online search is discovery-only unless the DLL is already bundled or you explicitly provide a trusted DLL path for installation.

## Notes

- The default PHP selector is `8.2`, which resolves to the latest secure `8.2.x` build from the official Windows PHP `releases.json` manifest at install time.
- `nginx` version defaults to `1.31.2` in the installer and uses the fixed archive URL pattern you provided.
- Running the installer again on the same target root replaces the current extracted `nginx` and PHP directories.
- Service logs are written to `nginx\logs\*.log` and `php\logs\*.log`.
- If `nssm.cc` is unavailable, the installer falls back to an Internet Archive mirror and then a GitHub-hosted NSSM build.
- On Windows Server, port `80` is often reserved by IIS or other services. If port `80` is unavailable, the installer automatically falls back to `8080` unless you explicitly pass `-HttpPort`.
- `nginx` is registered with NSSM using the standard Windows service arguments (`-p` and `-c`).

## Troubleshooting

If the installer reports `Can't open service`, that usually means it tried to remove an old service that did not exist yet. The updated installer suppresses that noise.

If services show `Running` but the site does not load:

1. Re-run the installer from an elevated PowerShell session so the updated NSSM service configuration is applied.
2. If reinstall fails with `Access to the path ... is denied`, the installer now stops `winginx` services before replacing files. Make sure you run it elevated.
3. Check whether port `80` is already in use. Try:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -HttpPort 8080
```

4. Inspect logs:

```text
C:\winginx\nginx\logs\
C:\winginx\php\logs\
```

5. Confirm services:

```powershell
Get-Service winginx-nginx, winginx-php
```

## Validation

After installation:

1. Open `http://localhost/` or the configured host and port.
2. Confirm the page prints `winginx ok` and the running PHP version.
3. Run `Get-Service winginx-nginx, winginx-php` in PowerShell and confirm both are running.
4. Use `.\scripts\manage-php-extension.ps1 -PhpRoot C:\winginx\php -List` to confirm managed extensions.

## Continuous integration

This repository includes a GitHub Actions workflow at [`.github/workflows/install-test.yml`](.github/workflows/install-test.yml).

On push to `main`/`master`, pull requests, and manual runs, it runs the same smoke test on:

- `windows-2019` (Windows Server 2019)
- `windows-2022` (Windows Server 2022)
- `windows-2025` (Windows Server 2025)

Each matrix job:

1. Parses the PowerShell scripts for syntax errors
2. Runs `install.ps1` under `C:\winginx-ci` on port `8080`
3. Checks that `winginx-nginx` and `winginx-php` are running
4. Requests `http://127.0.0.1:8080/` and expects `winginx ok` plus PHP `8.2`

The badge at the top of this README shows the latest workflow status (green for success, red for failure). The workflow fails if any Windows version fails.
