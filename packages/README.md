# Offline packages

Place the installer archives here for air-gapped installs. Do not commit large binaries to git.

## Required files

| File | Example |
| --- | --- |
| PHP Windows ZIP | `php-8.2.32-nts-Win32-vs16-x64.zip` |
| nginx Windows ZIP | `nginx-1.31.2.zip` |
| NSSM ZIP | `nssm-2.24.zip` |
| Composer PHAR | `composer.phar` |

## Prepare on a machine with internet

From the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\fetch-offline-packages.ps1
```

Optional pins:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\fetch-offline-packages.ps1 `
  -PhpVersion 8.2.32 `
  -NginxVersion 1.31.2 `
  -NssmVersion 2.24
```

## Install offline

Copy this repository plus the populated `packages` folder to the offline host, then run elevated:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Offline
```

Use a custom package directory if needed:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 `
  -Offline `
  -PackageRoot D:\media\winginx-packages
```
