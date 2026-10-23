# winginx installer

[![windows-latest](https://github.com/joeneldeasis/winginx-installer/actions/workflows/windows-latest.yml/badge.svg?branch=main&event=workflow_dispatch)](https://github.com/joeneldeasis/winginx-installer/actions/workflows/windows-latest.yml)
[![windows-2019](https://github.com/joeneldeasis/winginx-installer/actions/workflows/windows-2019.yml/badge.svg?branch=main&event=workflow_dispatch)](https://github.com/joeneldeasis/winginx-installer/actions/workflows/windows-2019.yml)
[![windows-2022](https://github.com/joeneldeasis/winginx-installer/actions/workflows/windows-2022.yml/badge.svg?branch=main&event=workflow_dispatch)](https://github.com/joeneldeasis/winginx-installer/actions/workflows/windows-2022.yml)
[![windows-2025](https://github.com/joeneldeasis/winginx-installer/actions/workflows/windows-2025.yml/badge.svg?branch=main&event=workflow_dispatch)](https://github.com/joeneldeasis/winginx-installer/actions/workflows/windows-2025.yml)

`winginx` is a PowerShell-based Windows installer for `nginx` plus native Windows PHP FastCGI.

Because native Windows PHP does not ship `php-fpm`, this project installs `php-cgi.exe` behind `nginx`, registers both through NSSM, and creates an `nginx` layout with `conf\conf.d\*.conf` for virtual hosts.

## What it installs

- `nginx` from `https://nginx.org/download/nginx-<version>.zip`
- PHP from `https://downloads.php.net/~windows/releases/`
- NSSM as the Windows service wrapper for both `nginx` and `php-cgi`
- Composer (`composer.phar`) plus `composer` / `artisan` command wrappers
- a PowerShell PHP console for `php`, `composer`, `php composer`, `artisan`, and `php artisan`
- optional offline install from a local `packages\` bundle (`-Offline`)
- a default `index.php` health page
- a managed `php.ini` extension block
- `scripts\manage-php-extension.ps1` for interactive and parameter-driven extension search, enable, and install operations
- `scripts\fetch-offline-packages.ps1` to download an offline package bundle
- `scripts\start-nginx.ps1` / `scripts\stop-nginx.ps1` to control `winginx-nginx` and `winginx-php`
- `scripts\update-nginx-service-scripts.ps1` to copy those helpers onto an existing install under `C:\winginx\tools`

## Layout

By default, running `install.ps1` installs everything under `C:\winginx`.

Default install targets:
- `C:\winginx\nginx` for the `nginx` server files
- `C:\winginx\php` for PHP and `php.ini`
- `C:\winginx\tools` for helper tools such as NSSM
- `C:\winginx\tools\composer` for Composer
- `C:\winginx\tools\bin` for `php`, `composer`, `artisan`, `start-nginx`, and `stop-nginx` command wrappers
- `C:\winginx\tools\php-console.ps1` for the PHP console launcher
- `C:\winginx\tools\start-nginx.ps1` / `C:\winginx\tools\stop-nginx.ps1` for service control (after running the update script)
- `C:\winginx\downloads` for downloaded zip archives
- `C:\winginx\nginx\html` for the default web root when `-WebRoot` is not provided

If you pass `-InstallRoot`, the same folder structure is created under that custom path instead.

After install, the target tree looks like this:

```text
C:\winginx\
  downloads\
  tools\
    bin\
      php.cmd
      composer.cmd
      artisan.cmd
      start-nginx.cmd
      stop-nginx.cmd
    composer\
      composer.phar
    php-console.ps1
    php-console.profile.ps1
    start-nginx.ps1
    stop-nginx.ps1
    run-nginx.ps1
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

`start-nginx.ps1`, `stop-nginx.ps1`, and the matching `.cmd` wrappers are added by running `scripts\update-nginx-service-scripts.ps1` against an existing install (they are not created by `install.ps1` yet).
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
  -PhpVersion 8.2.35 `
  -NginxVersion 1.31.2
```

### Offline install

Clone or copy this repository (including the `packages\` bundle), then run elevated:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Offline
```

`-Offline` never downloads remotely. It reads archives from `packages\` by default, or from `-PackageRoot` if you pass one.

To refresh the shipped package bundle on a machine with internet:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\fetch-offline-packages.ps1
```

Expected package names:

- `php-<version>-nts-Win32-vs16-x64.zip`
- `nginx-<version>.zip`
- `nssm-2.24.zip`
- `composer.phar`

See [packages/README.md](packages/README.md) for the full offline package layout.

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

## PHP console, Composer, and Artisan

Open the winginx PHP console after install:

```powershell
powershell -ExecutionPolicy Bypass -File C:\winginx\tools\php-console.ps1
```

Or from this repository:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\php-console.ps1 -InstallRoot C:\winginx
```

In that console you can run:

```powershell
php -v
composer -V
php composer -V
composer create-project laravel/laravel my-app
cd my-app
php artisan list
artisan list
```

Notes:
- `artisan` / `php artisan` only work inside a Laravel project directory that contains an `artisan` file.
- The installer also adds `C:\winginx\tools\bin` and `C:\winginx\php` to the machine `PATH`, so `php`, `composer`, and `artisan` work in new terminals after you open a new PowerShell window.
- Use `-SkipPathUpdate` if you do not want the installer to modify the machine `PATH`.

## Start and stop nginx / PHP

Windows services created by the installer:

| Service | Role |
| --- | --- |
| `winginx-nginx` | nginx web server (NSSM) |
| `winginx-php` | PHP FastCGI (`php-cgi`) |

The helpers **always** start and stop both services:

- Start: `winginx-php` → `winginx-nginx`
- Stop: `winginx-nginx` → `winginx-php` (also clears leftover `nginx.exe` / `php-cgi.exe` processes)

### Deploy helpers to an existing install

From this repository (elevated):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\update-nginx-service-scripts.ps1
```

Custom install root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\update-nginx-service-scripts.ps1 `
  -InstallRoot D:\winginx
```

That copies:

- `C:\winginx\tools\start-nginx.ps1`
- `C:\winginx\tools\stop-nginx.ps1`
- `C:\winginx\tools\bin\start-nginx.cmd`
- `C:\winginx\tools\bin\stop-nginx.cmd`

### Start both services

```powershell
powershell -ExecutionPolicy Bypass -File C:\winginx\tools\start-nginx.ps1
```

Or:

```powershell
C:\winginx\tools\bin\start-nginx.cmd
```

The start script:

- requires an elevated PowerShell session
- starts `winginx-php` and `winginx-nginx`
- runs `nginx -t` before starting nginx
- recovers when a service is stuck in `Paused`

### Stop both services

```powershell
powershell -ExecutionPolicy Bypass -File C:\winginx\tools\stop-nginx.ps1
```

Or:

```powershell
C:\winginx\tools\bin\stop-nginx.cmd
```

### Check status

```powershell
Get-Service winginx-nginx, winginx-php
```

Raw service commands still work, but prefer the helpers when a service is `Paused` or orphaned processes remain.

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

## php2shell security patch (CVE-2026-109618, CVE-2026-109619)

PHP **8.2.x** needs **8.2.35** or newer (see minimum versions in `config\php-security.psd1`). New installs with default `-PhpVersion 8.2` enforce that floor automatically.

### Patch an existing winginx installation

Use this when winginx is already on the server and you only need to update PHP under the install root. **nginx, vhosts, Composer, and your site files are not reinstalled.**

**Requirements**

- Windows Server or Windows client with winginx already installed.
- **Elevated** PowerShell (Run as administrator).
- Outbound HTTPS to `downloads.php.net` for online patching, **or** an offline PHP ZIP (see below).
- Default install layout: `C:\winginx` (`php\`, `nginx\`, `tools\`).

**1. Check the PHP version in use**

```powershell
C:\winginx\php\php-cgi.exe -v
```

If the version is already **8.2.35** or higher on the 8.2 line, the patch script still applies the recommended `php.ini` mitigation and exits without replacing binaries.

**2. Get the patch script**

Clone or update this repository on the server (or copy at least `scripts\patch-php-php2shell.ps1` and `scripts\lib\PhpReleaseSecurity.ps1` plus `config\php-security.psd1` so paths match the repo layout).

**3. Run the patch (online)**

From the repository root, with the default install root `C:\winginx`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\patch-php-php2shell.ps1
```

Non-default install root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\patch-php-php2shell.ps1 `
  -InstallRoot D:\winginx
```

**4. Run the patch (offline / air-gapped)**

On a machine with internet, refresh the bundle (must include **8.2.35** or your target fixed build):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\fetch-offline-packages.ps1 `
  -PhpVersion 8.2.35
```

Copy the `packages\` folder to the server, then:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\patch-php-php2shell.ps1 `
  -InstallRoot C:\winginx `
  -Offline `
  -PackageRoot C:\path\to\packages
```

**5. Verify after the patch**

```powershell
Get-Service winginx-nginx, winginx-php
C:\winginx\php\php-cgi.exe -v
Invoke-WebRequest -Uri 'http://127.0.0.1/' -UseBasicParsing   # or your -HttpPort, e.g. 8080
```

Confirm services are **Running**, `php-cgi -v` shows **8.2.35+**, and your health or app page loads.

**What the patch does**

- Stops `winginx-nginx`, then `winginx-php` (via `scripts\stop-nginx.ps1`).
- Downloads or uses the fixed PHP Windows ZIP and updates files under `{InstallRoot}\php\` (binaries and bundled `ext\` DLLs from the archive).
- **Keeps** your existing `{InstallRoot}\php\php.ini`, `logs\`, and `tmp\`.
- Sets `session.upload_progress.enabled=0` in `php.ini` when that directive is missing or enabled (defense in depth; **patching PHP is still required**).
- Restarts services (via `scripts\start-nginx.ps1`).

**Optional parameters**

| Parameter | Purpose |
| --- | --- |
| `-PhpVersion 8.2.35` | Target build (default **8.2.35**). |
| `-InstallRoot` | Winginx root if not `C:\winginx`. |
| `-Offline` / `-PackageRoot` | Use a local ZIP instead of downloading. |
| `-SkipIniMitigations` | Do not change `php.ini` (binary upgrade only). |

**If patching is not enough**

Re-running the full installer on the same `-InstallRoot` replaces both nginx and PHP trees. Prefer the patch script when you only need the php2shell PHP fix on a live host.

## Notes

- The default PHP selector is `8.2`, which resolves to the latest `8.2.x` build from the official Windows PHP `releases.json` manifest at install time, but not below **8.2.35** (php2shell fix).
- `nginx` version defaults to `1.31.2` in the installer and uses the fixed archive URL pattern you provided.
- Running the installer again on the same target root replaces the current extracted `nginx` and PHP directories.
- Service logs are written to `nginx\logs\*.log` and `php\logs\*.log`.
- If `nssm.cc` is unavailable, the installer falls back to an Internet Archive mirror and then a GitHub-hosted NSSM build.
- On Windows Server, port `80` is often reserved by IIS or other services. If port `80` is unavailable, the installer automatically falls back to `8080` unless you explicitly pass `-HttpPort`.
- `nginx` is registered with NSSM using the standard Windows service arguments (`-p` and `-c`).

## Troubleshooting

If the installer reports `Can't open service`, that usually means it tried to remove an old service that did not exist yet. The updated installer suppresses that noise.

If `winginx-nginx` shows `Paused` or will not stay running:

1. Deploy the service helpers if needed:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\update-nginx-service-scripts.ps1
```

2. Recover and start:

```powershell
powershell -ExecutionPolicy Bypass -File C:\winginx\tools\stop-nginx.ps1
powershell -ExecutionPolicy Bypass -File C:\winginx\tools\start-nginx.ps1
```

3. Test the config manually:

```powershell
& C:\winginx\nginx\nginx.exe -t -p C:\winginx\nginx
```

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
4. Optionally deploy and verify service helpers:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\update-nginx-service-scripts.ps1
powershell -ExecutionPolicy Bypass -File C:\winginx\tools\stop-nginx.ps1
powershell -ExecutionPolicy Bypass -File C:\winginx\tools\start-nginx.ps1
Get-Service winginx-nginx
```

5. Use `.\scripts\manage-php-extension.ps1 -PhpRoot C:\winginx\php -List` to confirm managed extensions.

## Continuous integration

This repository runs the same installer smoke test on each Windows Server version through separate workflows:

- [`.github/workflows/windows-latest.yml`](.github/workflows/windows-latest.yml)
- [`.github/workflows/windows-2019.yml`](.github/workflows/windows-2019.yml)
- [`.github/workflows/windows-2022.yml`](.github/workflows/windows-2022.yml)
- [`.github/workflows/windows-2025.yml`](.github/workflows/windows-2025.yml)

Shared steps live in [`.github/workflows/install-smoke.yml`](.github/workflows/install-smoke.yml).

CI runs manually from **Actions → Run workflow**. Each workflow:

1. Parses the PowerShell scripts for syntax errors
2. Runs `install.ps1` under `C:\winginx-ci` on port `8080`
3. Checks that `winginx-nginx` and `winginx-php` are running
4. Requests `http://127.0.0.1:8080/` and expects `winginx ok` plus PHP `8.2`

The badges at the top of this README reflect the latest manual (`workflow_dispatch`) run on `main` for each OS.
