# Winginx troubleshooting guide

**502 errors, nginx conflicts, and PHP updates (Windows Server / winginx)**

Document version: 2026-10-26 (rev 2)  
Install root (default): `C:\winginx`  
Repository: `C:\winginx\winginx-installer`  
Recommended branch: `fix/install-in-place-upgrade`

---

## 0. One-command audit (recommended first)

Elevated PowerShell — updates PHP via the patch script, **does not modify `conf.d`**, restarts services, and writes a log file for support:

```powershell
cd C:\winginx\winginx-installer
git fetch origin
git checkout fix/install-in-place-upgrade
git pull

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\troubleshoot-winginx.ps1 `
  -InstallRoot C:\winginx
```

Log file (default): `C:\winginx\logs\winginx-troubleshoot-YYYYMMDD-HHmmss.log`

Optional:

```powershell
# Custom log path
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\troubleshoot-winginx.ps1 `
  -InstallRoot C:\winginx `
  -LogPath C:\winginx\logs\support-audit.log

# Diagnostics only (no patch)
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\troubleshoot-winginx.ps1 `
  -InstallRoot C:\winginx -SkipPatch
```

Each section in the log includes a **COMMAND:** line you can copy and run manually.

---

## 1. What HTTP 502 usually means

A **502 Bad Gateway** from nginx almost always means:

- nginx is running and accepted the request, but
- the **PHP FastCGI backend** (`php-cgi` on `127.0.0.1:9000`) did not respond correctly, or
- the **wrong virtual host** handled the request (wrong root / no PHP).

It is **not** the same as php2shell (CVE-2026-109618 / CVE-2026-109619). You can be on PHP 8.2.35 and still see 502 if nginx or vhosts are misconfigured.

---

## 2. Quick health check (elevated PowerShell)

Run:

```powershell
Get-Service winginx-nginx, winginx-php
Get-Process nginx, php-cgi -ErrorAction SilentlyContinue | Format-Table Id, ProcessName -AutoSize
Test-NetConnection 127.0.0.1 -Port 9000
Test-Path C:\winginx\php\php.ini
Get-Content C:\winginx\php\logs\php-service.err.log -Tail 30
Get-Content C:\winginx\php\logs\php-service.out.log -Tail 30
```

### How to read the results

| Check | Good | Problem |
| --- | --- | --- |
| Services | Both **Running** | Stop/start helpers (Section 4) |
| `nginx` process count | Small (about 2–9) | **Many nginx.exe** → multiple masters (Section 4) |
| `php-cgi` | At least **1** | PHP service down → 502 on `.php` |
| Port **9000** | `TcpTestSucceeded : True` | PHP not listening → 502 |
| `php.ini` | **True** | Run Section 5 to create winginx `php.ini` |

**Note:** Searching `error.log` for `502` can match **process IDs** (e.g. `50256#10856`), not HTTP 502. Use Section 6 for better log searches.

---

## 3. Common log messages

### 3.1 `conflicting server name "…" on 0.0.0.0:8081, ignored`

Several files in `C:\winginx\nginx\conf\conf.d\` define the **same** `listen` port and **same** `server_name`. Nginx keeps the **first** block and **ignores** the rest.

**Impact:** Sites like `liptong.pdic.gov.ph` may not use the config you expect → wrong document root, missing PHP, or 502.

**Fix:** Section 5.

### 3.2 `CreateFile() "C:/winginx/nginx/logs/nginx.pid" failed`

Something ran `nginx -s reload` or `nginx -s quit` while **no master** was running with prefix `C:\winginx\nginx` (crashed, never started, or wrong start command).

**Fix:** Section 4 (clean stop/start). After a good start, `C:\winginx\nginx\logs\nginx.pid` should exist.

---

## 4. Stabilize nginx (fix multiple `nginx.exe` processes)

Run in **elevated** PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File C:\winginx\winginx-installer\scripts\stop-nginx.ps1
Start-Sleep -Seconds 3
Get-Process nginx -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
(Get-Process nginx -ErrorAction SilentlyContinue).Count
```

The last command should print **0**.

Ensure the logs directory exists, then start:

```powershell
New-Item -ItemType Directory -Force C:\winginx\nginx\logs | Out-Null
powershell -ExecutionPolicy Bypass -File C:\winginx\tools\start-nginx.ps1
Start-Sleep -Seconds 2
(Get-Process nginx).Count
Test-Path C:\winginx\nginx\logs\nginx.pid
```

**Expect:** A **small** nginx process count (not 15+) and `nginx.pid` **True**.

Use **stop-nginx.ps1** / **start-nginx.ps1** for restarts. Avoid ad-hoc `nginx -s reload` until `nginx.pid` exists.

---

## 5. Fix duplicate virtual hosts on port 8081

List configs that mention port 8081 or your site name:

```powershell
Get-ChildItem C:\winginx\nginx\conf\conf.d\*.conf | ForEach-Object {
  $hits = Select-String -Path $_.FullName -Pattern '8081|liptong\.pdic\.gov\.ph|server_name'
  if ($hits) { "`n=== $($_.Name) ==="; $hits.Line }
}
```

**Action:**

1. For each `listen 8081` + `server_name` combination, keep **one** `.conf` file.
2. Disable duplicates by renaming (example: `site.conf` → `site.conf.disabled`).
3. Test configuration:

```powershell
cd C:\winginx\nginx
.\nginx.exe -p C:\winginx\nginx -c conf\nginx.conf -t
```

4. Restart with **start-nginx.ps1** (Section 4).

---

## 6. Find real 502 and upstream errors in logs

```powershell
Select-String -Path C:\winginx\nginx\logs\error.log `
  -Pattern 'upstream|connect\(\) failed|recv\(\) failed|Primary script unknown' |
  Select-Object -Last 20

Select-String -Path C:\winginx\nginx\logs\access.log -Pattern ' 502 ' |
  Select-Object -Last 20
```

Note the **time**, **Host**, and **URL** when users report 502.

---

## 7. Test the site on the server (bypass front proxy)

```powershell
Invoke-WebRequest -Uri 'http://127.0.0.1:8081/' `
  -Headers @{ Host='liptong.pdic.gov.ph' } -UseBasicParsing
```

Replace host and URL as needed.

| Result | Meaning |
| --- | --- |
| 502 on server | Fix winginx (Sections 4–5, PHP logs) |
| OK on server, 502 in browser | Check load balancer, IIS, firewall, or DNS in front of winginx |

---

## 8. PHP / php2shell updates

**Important:** Do **not** re-run old `install.ps1` builds that delete all `conf.d\*.conf`. Use branch `fix/install-in-place-upgrade`, the patch script, or `install.ps1` with **`-SkipNginxReplace`** (preserves custom vhosts by default on current branch).

### 8.1 PHP-only security patch (recommended on live servers)

Does **not** replace nginx binaries or rewrite full `php.ini` (keeps existing file when present):

```powershell
powershell -ExecutionPolicy Bypass -File C:\winginx\winginx-installer\scripts\stop-nginx.ps1
powershell -ExecutionPolicy Bypass -File C:\winginx\winginx-installer\scripts\patch-php-php2shell.ps1 `
  -InstallRoot C:\winginx
powershell -ExecutionPolicy Bypass -File C:\winginx\tools\start-nginx.ps1
```

If output says **PHP 8.2.35** but **`php.ini` was not found**, run Section 8.2.

### 8.2 Create or refresh `php.ini` without replacing nginx

Use branch `fix/install-in-place-upgrade` (or current main with `-SkipNginxReplace`):

```powershell
cd C:\winginx\winginx-installer
git fetch origin
git checkout fix/install-in-place-upgrade
git pull

powershell -ExecutionPolicy Bypass -File .\scripts\stop-nginx.ps1

powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -InstallRoot C:\winginx `
  -PhpVersion 8.2.35 `
  -SkipNginxReplace

powershell -ExecutionPolicy Bypass -File C:\winginx\tools\start-nginx.ps1
```

Verify:

```powershell
Test-Path C:\winginx\php\php.ini
Select-String -Path C:\winginx\php\php.ini -Pattern 'session.upload_progress'
C:\winginx\php\php-cgi.exe -v
```

---

## 9. If `install.ps1` fails on `C:\winginx\nginx` (Access denied)

Stop services first. Prefer **`-SkipNginxReplace`** (Section 8.2) or the **patch script** (Section 8.1) instead of replacing the whole nginx folder.

Remove leftover stale folders only when services are stopped:

```powershell
Remove-Item C:\winginx\nginx.stale-* -Recurse -Force -ErrorAction SilentlyContinue
```

---

## 10. Suggested order of operations

1. Section 2 — quick health check  
2. Section 4 — clean nginx process sprawl  
3. Section 5 — dedupe vhosts on 8081  
4. Section 6–7 — confirm 502 on box vs in browser  
5. Section 8 — PHP 8.2.35 + `php.ini` if needed  
6. Re-test the affected site  

---

## 11. Support information to collect

When escalating, provide:

- Output of Section 2 (service status, process counts, port 9000, `php.ini`)  
- `(Get-Process nginx).Count` after Section 4  
- Output of `nginx -t`  
- Last 20 lines from Section 6 (access + error log)  
- Host header test result (Section 7)  

---

*Generated for winginx-installer operators on Windows Server.*
