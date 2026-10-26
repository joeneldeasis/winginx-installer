[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\winginx',
    [string]$LogPath = '',
    [string]$NginxServiceName = 'winginx-nginx',
    [string]$PhpServiceName = 'winginx-php',
    [string]$PhpVersion = '8.2.35',
    [switch]$SkipPatch,
    [switch]$SkipHttpTests,
    [int]$HttpTimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$ScriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot = Split-Path -Path $ScriptRoot -Parent

$nginxRoot = Join-Path -Path $InstallRoot -ChildPath 'nginx'
$phpRoot = Join-Path -Path $InstallRoot -ChildPath 'php'
$confDir = Join-Path -Path $nginxRoot -ChildPath 'conf\conf.d'
$nginxExe = Join-Path -Path $nginxRoot -ChildPath 'nginx.exe'
$phpCgiExe = Join-Path -Path $phpRoot -ChildPath 'php-cgi.exe'
$phpIniPath = Join-Path -Path $phpRoot -ChildPath 'php.ini'
$patchScript = Join-Path -Path $ScriptRoot -ChildPath 'patch-php-php2shell.ps1'
$stopScript = Join-Path -Path $ScriptRoot -ChildPath 'stop-nginx.ps1'
$startScript = Join-Path -Path $ScriptRoot -ChildPath 'start-nginx.ps1'

$script:AuditIssues = New-Object System.Collections.Generic.List[string]
$script:LogWriter = $null

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Initialize-TroubleshootLog {
    param([string]$Path)

    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $script:LogWriter = New-Object System.IO.StreamWriter($Path, $false, [System.Text.UTF8Encoding]::new($false))
    Write-AuditLine "Log file: $Path"
}

function Write-AuditLine {
    param([string]$Message)

    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    if ($null -ne $script:LogWriter) {
        $script:LogWriter.WriteLine($line)
        $script:LogWriter.Flush()
    }
}

function Register-AuditIssue {
    param([string]$Message)

    [void]$script:AuditIssues.Add($Message)
    Write-AuditLine "ISSUE: $Message"
}

function Invoke-AuditCommand {
    param(
        [string]$Label,
        [string]$CommandText,
        [scriptblock]$Action
    )

    Write-AuditLine ''
    Write-AuditLine "=== $Label ==="
    Write-AuditLine "COMMAND: $CommandText"

    try {
        & $Action
    }
    catch {
        Register-AuditIssue "$Label failed: $($_.Exception.Message)"
        Write-AuditLine "ERROR: $($_.Exception.Message)"
    }
}

function Get-ListeningPortsFromConf {
    param([string]$Root)

    $ports = New-Object 'System.Collections.Generic.HashSet[int]'
    $files = @()
    if (Test-Path -LiteralPath $Root) {
        $files = @(Get-ChildItem -Path $Root -Filter '*.conf' -File -ErrorAction SilentlyContinue)
    }

    foreach ($file in $files) {
        $content = Get-Content -Path $file.FullName -ErrorAction SilentlyContinue
        foreach ($line in $content) {
            if ($line -match '^\s*listen\s+(?:\[::\]:|0\.0\.0\.0:)?(\d+)') {
                [void]$ports.Add([int]$Matches[1])
            }
            elseif ($line -match '^\s*listen\s+(\d+)') {
                [void]$ports.Add([int]$Matches[1])
            }
        }
    }

    if ($ports.Count -eq 0) {
        [void]$ports.Add(80)
        [void]$ports.Add(8080)
        [void]$ports.Add(8081)
    }

    return @($ports | Sort-Object)
}

function Test-HttpEndpoint {
    param(
        [string]$Url,
        [int]$TimeoutSeconds
    )

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSeconds
        Write-AuditLine "HTTP $($response.StatusCode) $Url"
        $preview = ($response.Content -split "`n" | Select-Object -First 5) -join ' | '
        if (-not [string]::IsNullOrWhiteSpace($preview)) {
            Write-AuditLine "BODY (first lines): $preview"
        }
        return $true
    }
    catch {
        Register-AuditIssue "HTTP test failed for $Url : $($_.Exception.Message)"
        return $false
    }
}

function Invoke-WinginxDiagnostics {
    param([string]$Phase)

    Write-AuditLine ''
    Write-AuditLine "########## DIAGNOSTICS: $Phase ##########"

    Invoke-AuditCommand -Label 'Administrator session' -CommandText '# Must be elevated' -Action {
        if (Test-IsAdministrator) {
            Write-AuditLine 'OK: Running in an elevated PowerShell session.'
        }
        else {
            Register-AuditIssue 'Not running elevated. Re-run PowerShell as Administrator.'
        }
    }

    Invoke-AuditCommand -Label 'Paths' -CommandText "# InstallRoot=$InstallRoot" -Action {
        Write-AuditLine "InstallRoot: $InstallRoot"
        Write-AuditLine "nginx root:  $nginxRoot"
        Write-AuditLine "php root:    $phpRoot"
        Write-AuditLine "conf.d:      $confDir"
        foreach ($path in @($nginxExe, $phpCgiExe, $phpIniPath)) {
            Write-AuditLine ("{0,-7} {1}" -f (Test-Path -LiteralPath $path), $path)
        }
    }

    Invoke-AuditCommand -Label 'Windows services' -CommandText "Get-Service $NginxServiceName, $PhpServiceName | Format-Table -AutoSize" -Action {
        $services = @(Get-Service -Name $NginxServiceName, $PhpServiceName -ErrorAction SilentlyContinue)
        if ($services.Count -eq 0) {
            Register-AuditIssue 'winginx services were not found.'
            return
        }

        foreach ($service in $services) {
            Write-AuditLine ("Service {0}: {1} ({2})" -f $service.Name, $service.Status, $service.StartType)
            if ($service.Status -ne 'Running') {
                Register-AuditIssue "Service $($service.Name) is $($service.Status)."
            }
        }
    }

    Invoke-AuditCommand -Label 'Processes' -CommandText 'Get-Process nginx, php-cgi -ErrorAction SilentlyContinue | Format-Table Id, ProcessName -AutoSize' -Action {
        $nginxProcs = @(Get-Process -Name nginx -ErrorAction SilentlyContinue)
        $phpProcs = @(Get-Process -Name php-cgi -ErrorAction SilentlyContinue)
        Write-AuditLine ("nginx.exe count:  {0}" -f $nginxProcs.Count)
        Write-AuditLine ("php-cgi.exe count: {0}" -f $phpProcs.Count)
        foreach ($proc in $nginxProcs) {
            Write-AuditLine ("  nginx PID {0}" -f $proc.Id)
        }
        foreach ($proc in $phpProcs) {
            Write-AuditLine ("  php-cgi PID {0}" -f $proc.Id)
        }

        if ($nginxProcs.Count -gt 12) {
            Register-AuditIssue "Too many nginx.exe processes ($($nginxProcs.Count)). Run stop-nginx.ps1 and start-nginx.ps1 after clearing orphans."
        }
        if ($phpProcs.Count -eq 0) {
            Register-AuditIssue 'No php-cgi.exe process found (502 likely for PHP sites).'
        }
    }

    Invoke-AuditCommand -Label 'PHP FastCGI port 9000' -CommandText 'Test-NetConnection 127.0.0.1 -Port 9000' -Action {
        $test = Test-NetConnection -ComputerName 127.0.0.1 -Port 9000 -WarningAction SilentlyContinue
        Write-AuditLine ("TcpTestSucceeded: {0}" -f $test.TcpTestSucceeded)
        if (-not $test.TcpTestSucceeded) {
            Register-AuditIssue 'Nothing is listening on 127.0.0.1:9000 (PHP backend down).'
        }
    }

    Invoke-AuditCommand -Label 'PHP version' -CommandText "& `"$phpCgiExe`" -v" -Action {
        if (-not (Test-Path -LiteralPath $phpCgiExe)) {
            Register-AuditIssue "Missing $phpCgiExe"
            return
        }

        $output = & $phpCgiExe -v 2>&1 | Out-String
        Write-AuditLine $output.Trim()
        $global:LASTEXITCODE = 0
    }

    Invoke-AuditCommand -Label 'php.ini' -CommandText "Test-Path `"$phpIniPath`"; Select-String session.upload_progress" -Action {
        if (-not (Test-Path -LiteralPath $phpIniPath)) {
            Register-AuditIssue "Missing php.ini at $phpIniPath"
            return
        }

        $uploadLine = Select-String -Path $phpIniPath -Pattern '^\s*;?\s*session\.upload_progress\.enabled\s*=' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $uploadLine) {
            Write-AuditLine 'session.upload_progress.enabled is not set (patch can add it).'
        }
        else {
            Write-AuditLine $uploadLine.Line
        }
    }

    Invoke-AuditCommand -Label 'conf.d (read-only listing)' -CommandText "Get-ChildItem `"$confDir\*.conf`"" -Action {
        if (-not (Test-Path -LiteralPath $confDir)) {
            Register-AuditIssue "conf.d directory missing: $confDir"
            return
        }

        $configs = @(Get-ChildItem -Path $confDir -Filter '*.conf' -File -ErrorAction SilentlyContinue)
        Write-AuditLine ("conf.d file count: {0}" -f $configs.Count)
        foreach ($file in $configs) {
            Write-AuditLine ("  {0} ({1} bytes)" -f $file.Name, $file.Length)
        }
        if ($configs.Count -eq 0) {
            Register-AuditIssue 'No .conf files in conf.d (custom vhosts may have been lost).'
        }
    }

    Invoke-AuditCommand -Label 'nginx.pid' -CommandText "Test-Path `"$(Join-Path $nginxRoot 'logs\nginx.pid')`"" -Action {
        $pidPath = Join-Path -Path $nginxRoot -ChildPath 'logs\nginx.pid'
        Write-AuditLine ("nginx.pid exists: {0} ({1})" -f (Test-Path -LiteralPath $pidPath), $pidPath)
        if (-not (Test-Path -LiteralPath $pidPath)) {
            Register-AuditIssue 'nginx.pid is missing (reload/stop signals may fail until a clean start).'
        }
    }

    Invoke-AuditCommand -Label 'nginx config test' -CommandText "& `"$nginxExe`" -p `"$nginxRoot`" -c conf\nginx.conf -t" -Action {
        if (-not (Test-Path -LiteralPath $nginxExe)) {
            Register-AuditIssue "Missing $nginxExe"
            return
        }

        Push-Location -LiteralPath $nginxRoot
        try {
            $output = & $nginxExe -p $nginxRoot -c 'conf\nginx.conf' -t 2>&1 | Out-String
            Write-AuditLine $output.Trim()
            if ($output -notmatch 'successful') {
                Register-AuditIssue 'nginx -t did not report successful.'
            }
        }
        finally {
            Pop-Location
            $global:LASTEXITCODE = 0
        }
    }

    Invoke-AuditCommand -Label 'Recent nginx error log' -CommandText "Get-Content `"$(Join-Path $nginxRoot 'logs\error.log')`" -Tail 40" -Action {
        $errorLog = Join-Path -Path $nginxRoot -ChildPath 'logs\error.log'
        if (-not (Test-Path -LiteralPath $errorLog)) {
            Write-AuditLine "No error log at $errorLog"
            return
        }

        Get-Content -Path $errorLog -Tail 40 | ForEach-Object { Write-AuditLine $_ }
    }

    Invoke-AuditCommand -Label 'Recent PHP service stderr' -CommandText "Get-Content `"$(Join-Path $phpRoot 'logs\php-service.err.log')`" -Tail 30" -Action {
        $phpErr = Join-Path -Path $phpRoot -ChildPath 'logs\php-service.err.log'
        if (-not (Test-Path -LiteralPath $phpErr)) {
            Write-AuditLine "No PHP service stderr log at $phpErr"
            return
        }

        Get-Content -Path $phpErr -Tail 30 | ForEach-Object { Write-AuditLine $_ }
    }

    if (-not $SkipHttpTests) {
        Invoke-AuditCommand -Label 'HTTP smoke tests' -CommandText 'Invoke-WebRequest http://127.0.0.1:<port>/ (ports from conf.d listen)' -Action {
            $ports = Get-ListeningPortsFromConf -Root $confDir
            foreach ($port in $ports) {
                [void](Test-HttpEndpoint -Url "http://127.0.0.1:$port/" -TimeoutSeconds $HttpTimeoutSeconds)
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $logsDir = Join-Path -Path $InstallRoot -ChildPath 'logs'
    if (-not (Test-Path -LiteralPath $logsDir)) {
        $logsDir = Join-Path -Path $RepoRoot -ChildPath 'logs'
    }
    Ensure-Directory -Path $logsDir
    $LogPath = Join-Path -Path $logsDir -ChildPath ('winginx-troubleshoot-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

try {
    Initialize-TroubleshootLog -Path $LogPath
    Write-AuditLine "winginx troubleshoot started (repo: $RepoRoot)"
    Write-AuditLine 'NOTE: This script does NOT modify conf.d or nginx vhost files.'

    Invoke-WinginxDiagnostics -Phase 'BEFORE PATCH'

    if (-not $SkipPatch) {
        if (-not (Test-Path -LiteralPath $patchScript)) {
            Register-AuditIssue "Patch script not found: $patchScript"
        }
        elseif (-not (Test-IsAdministrator)) {
            Register-AuditIssue 'Skipping php2shell patch because the session is not elevated.'
        }
        else {
            $patchCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$patchScript`" -InstallRoot `"$InstallRoot`" -PhpVersion $PhpVersion"
            Invoke-AuditCommand -Label 'php2shell patch (PHP only, preserves conf.d)' -CommandText $patchCommand -Action {
                Write-AuditLine 'Running patch-php-php2shell.ps1 (does not touch nginx conf.d)...'
                & $patchScript -InstallRoot $InstallRoot -PhpVersion $PhpVersion
                if ($LASTEXITCODE -ne 0) {
                    Register-AuditIssue "Patch script exited with code $LASTEXITCODE"
                }
                else {
                    Write-AuditLine 'Patch script completed.'
                }
                $global:LASTEXITCODE = 0
            }
        }
    }
    else {
        Write-AuditLine 'SkipPatch: php2shell patch was not run.'
    }

    if (Test-IsAdministrator) {
        Invoke-AuditCommand -Label 'Restart winginx services' -CommandText "& `"$stopScript`"; & `"$startScript`"" -Action {
            if ((Test-Path -LiteralPath $stopScript) -and (Test-Path -LiteralPath $startScript)) {
                & $stopScript -NginxServiceName $NginxServiceName -PhpServiceName $PhpServiceName -NginxRoot $nginxRoot
                Start-Sleep -Seconds 2
                & $startScript -NginxServiceName $NginxServiceName -PhpServiceName $PhpServiceName
                $global:LASTEXITCODE = 0
            }
            else {
                Register-AuditIssue 'stop-nginx.ps1 or start-nginx.ps1 was not found next to this script.'
            }
        }
    }

    Start-Sleep -Seconds 3
    Invoke-WinginxDiagnostics -Phase 'AFTER PATCH / RESTART'

    Write-AuditLine ''
    Write-AuditLine '########## SUMMARY ##########'
    if ($script:AuditIssues.Count -eq 0) {
        Write-AuditLine 'No issues recorded. Review the log anyway for warnings.'
    }
    else {
        Write-AuditLine ("Issue count: {0}" -f $script:AuditIssues.Count)
        foreach ($issue in $script:AuditIssues) {
            Write-AuditLine " - $issue"
        }
    }

    Write-AuditLine ''
    Write-AuditLine 'To re-run this audit:'
    Write-AuditLine ("  powershell -NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -InstallRoot `"$InstallRoot`"")
    Write-AuditLine ("Log saved to: $LogPath")
}
finally {
    if ($null -ne $script:LogWriter) {
        $script:LogWriter.Flush()
        $script:LogWriter.Dispose()
        $script:LogWriter = $null
    }
}

if ($script:AuditIssues.Count -gt 0) {
    exit 1
}

exit 0
