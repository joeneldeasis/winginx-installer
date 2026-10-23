# Offline packages

This directory holds the installer archives used by `-Offline`.

The repository ships a default bundle so air-gapped hosts can install without downloading.

## Included files

| File | Purpose |
| --- | --- |
| PHP Windows ZIP | e.g. `php-8.2.35-nts-Win32-vs16-x64.zip` |
| nginx Windows ZIP | e.g. `nginx-1.31.2.zip` |
| NSSM ZIP | e.g. `nssm-2.24.zip` |
| Composer PHAR | `composer.phar` |

## Refresh the bundle on a machine with internet

From the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\fetch-offline-packages.ps1
```

Optional pins:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\fetch-offline-packages.ps1 `
  -PhpVersion 8.2.35 `
  -NginxVersion 1.31.2 `
  -NssmVersion 2.24
```

Bundles must meet the php2shell minimum in `config\php-security.psd1` (8.2 line: **8.2.35**).

## Install offline

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Offline
```

Use a custom package directory if needed:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 `
  -Offline `
  -PackageRoot D:\media\winginx-packages
```
