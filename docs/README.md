# Winginx documentation

| File | Description |
| --- | --- |
| [winginx-502-troubleshooting.md](winginx-502-troubleshooting.md) | Source: 502 errors, nginx/php checks, php2shell updates |
| [winginx-502-troubleshooting.pdf](winginx-502-troubleshooting.pdf) | PDF export for operators |
| [winginx-502-troubleshooting.docx](winginx-502-troubleshooting.docx) | Word export for operators |

## Quick command (elevated PowerShell)

```powershell
cd C:\winginx\winginx-installer
git pull origin fix/install-in-place-upgrade
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\troubleshoot-winginx.ps1 -InstallRoot C:\winginx
```

Log output: `C:\winginx\logs\winginx-troubleshoot-<timestamp>.log`
