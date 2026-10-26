[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\winginx',
    [string]$LogPath = '',
    [string]$NginxServiceName = 'winginx-nginx',
    [string]$PhpServiceName = 'winginx-php',
    [string]$PhpVersion = '8.2.35',
    [switch]$SkipPatch,
    [switch]$SkipHttpTests,
    [int]$HttpTimeoutSeconds = 15,
    [switch]$AutoFix,
    [switch]$StabilizeNginx,
    [switch]$DisableDuplicateVhosts,
    [switch]$RefreshPhpIniIfMissing
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
$installScript = Join-Path -Path $RepoRoot -ChildPath 'install.ps1'

$script:AuditIssues = New-Object System.Collections.Generic.List[string]
$script:LogWriter = $null

$script:DoStabilizeNginx = $StabilizeNginx -or $AutoFix
$script:DoDisableDuplicateVhosts = $DisableDuplicateVhosts -or $AutoFix
$script:DoRefreshPhpIniIfMissing = $RefreshPhpIniIfMissing -or $AutoFix

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

function Get-ActiveNginxConfFiles {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        return @()
    }

    return @(
        Get-ChildItem -Path $Root -Filter '*.conf' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '\.disabled$' }
    )
}

function Get-ListenPortFromLine {
    param([string]$Line)

    if ($Line -match '^\s*listen\s+(?:\[::\]:|0\.0\.0\.0:)?(\d+)') {
        return [int]$Matches[1]
    }

    if ($Line -match '^\s*listen\s+(\d+)\s*;') {
        return [int]$Matches[1]
    }

    return $null
}

function Get-ServerNamesFromLine {
    param([string]$Line)

    if ($Line -notmatch '^\s*server_name\s+(.+?)\s*;') {
        return @()
    }

    $raw = $Matches[1].Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @('_')
    }

    return @(
        $raw -split '\s+' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-NginxServerBlocksFromFile {
    param([string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath)) {
        return @()
    }

    $lines = @(Get-Content -LiteralPath $FilePath -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) {
        return @()
    }

    $blocks = New-Object System.Collections.Generic.List[object]
    $index = 0
    while ($index -lt $lines.Count) {
        if ($lines[$index] -notmatch '^\s*server\s*\{') {
            $index++
            continue
        }

        $depth = 0
        $blockLines = New-Object System.Collections.Generic.List[string]
        $endIndex = $index
        for ($j = $index; $j -lt $lines.Count; $j++) {
            $line = $lines[$j]
            [void]$blockLines.Add($line)
            $depth += ([regex]::Matches($line, '\{')).Count
            $depth -= ([regex]::Matches($line, '\}')).Count
            $endIndex = $j
            if ($depth -le 0 -and $j -gt $index) {
                break
            }
        }

        $listens = New-Object 'System.Collections.Generic.HashSet[int]'
        $names = New-Object 'System.Collections.Generic.List[string]'
        foreach ($line in $blockLines) {
            $port = Get-ListenPortFromLine -Line $line
            if ($null -ne $port) {
                [void]$listens.Add($port)
            }

            foreach ($name in (Get-ServerNamesFromLine -Line $line)) {
                [void]$names.Add($name.ToLowerInvariant())
            }
        }

        if ($names.Count -eq 0) {
            [void]$names.Add('_')
        }

        if ($listens.Count -eq 0) {
            [void]$listens.Add(80)
        }

        [void]$blocks.Add([pscustomobject]@{
                Listens     = @($listens | Sort-Object)
                ServerNames = @($names | Select-Object -Unique)
            })

        $index = $endIndex + 1
    }

    return @($blocks)
}

function Get-VhostBindingsFromConfDir {
    param([string]$Root)

    $bindings = New-Object System.Collections.Generic.List[object]
    foreach ($file in (Get-ActiveNginxConfFiles -Root $Root)) {
        $blocks = Get-NginxServerBlocksFromFile -FilePath $file.FullName
        foreach ($block in $blocks) {
            foreach ($port in $block.Listens) {
                foreach ($name in $block.ServerNames) {
                    [void]$bindings.Add([pscustomobject]@{
                            File        = $file.Name
                            Port        = [int]$port
                            ServerName  = [string]$name
                        })
                }
            }
        }
    }

    return @($bindings)
}

function Get-ListeningPortsFromConf {
    param([string]$Root)

    $ports = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($binding in (Get-VhostBindingsFromConfDir -Root $Root)) {
        [void]$ports.Add([int]$binding.Port)
    }

    if ($ports.Count -eq 0) {
        [void]$ports.Add(80)
        [void]$ports.Add(8080)
        [void]$ports.Add(8081)
    }

    return @($ports | Sort-Object)
}

function Get-DuplicateVhostReport {
    param([string]$Root)

    $winnerByKey = @{}
    $duplicateRows = New-Object System.Collections.Generic.List[object]
    $filesToDisable = New-Object 'System.Collections.Generic.HashSet[string]'
    $manualFiles = New-Object 'System.Collections.Generic.HashSet[string]'

    $sorted = @(Get-VhostBindingsFromConfDir -Root $Root | Sort-Object File, Port, ServerName)
    foreach ($binding in $sorted) {
        $key = '{0}|{1}' -f $binding.Port, $binding.ServerName
        if (-not $winnerByKey.ContainsKey($key)) {
            $winnerByKey[$key] = $binding.File
            continue
        }

        $winnerFile = $winnerByKey[$key]
        if ($winnerFile -eq $binding.File) {
            continue
        }

        [void]$duplicateRows.Add([pscustomobject]@{
                Key         = $key
                Port        = $binding.Port
                ServerName  = $binding.ServerName
                WinnerFile  = $winnerFile
                DuplicateFile = $binding.File
            })

        $dupPath = Join-Path -Path $Root -ChildPath $binding.File
        $blockCount = @(Get-NginxServerBlocksFromFile -FilePath $dupPath).Count
        if ($blockCount -eq 1) {
            [void]$filesToDisable.Add($binding.File)
        }
        else {
            [void]$manualFiles.Add($binding.File)
        }
    }

    return [pscustomobject]@{
        Duplicates     = @($duplicateRows)
        FilesToDisable = @($filesToDisable | Sort-Object)
        ManualFiles    = @($manualFiles | Sort-Object)
    }
}

function Invoke-RepairDuplicateVhosts {
    param(
        [string]$Root,
        [switch]$Apply
    )

    $report = Get-DuplicateVhostReport -Root $Root
    if ($report.Duplicates.Count -eq 0) {
        Write-AuditLine 'No duplicate listen + server_name pairs found across conf.d files.'
        return
    }

    foreach ($row in $report.Duplicates) {
        Register-AuditIssue (
            "Duplicate vhost {0}:{1} in $($row.DuplicateFile) (nginx keeps $($row.WinnerFile) first)." -f
            $row.Port, $row.ServerName
        )
    }

    foreach ($manual in $report.ManualFiles) {
        Register-AuditIssue "Manual vhost edit required: $manual has multiple server blocks; cannot auto-disable whole file."
    }

    if (-not $Apply) {
        Write-AuditLine 'Duplicate vhosts reported only (pass -AutoFix or -DisableDuplicateVhosts to rename single-block duplicate files to .conf.disabled).'
        return
    }

    foreach ($fileName in $report.FilesToDisable) {
        $source = Join-Path -Path $Root -ChildPath $fileName
        $disabled = '{0}.disabled' -f $source
        if (Test-Path -LiteralPath $disabled) {
            Register-AuditIssue "Cannot disable $fileName : $disabled already exists."
            continue
        }

        Write-AuditLine "FIX: Renaming $fileName -> $($fileName).disabled"
        Rename-Item -LiteralPath $source -NewName ('{0}.disabled' -f $fileName)
    }
}

function Invoke-StabilizeNginxProcesses {
    param([switch]$StartServices)

    if (-not (Test-Path -LiteralPath $stopScript)) {
        Register-AuditIssue "Missing $stopScript"
        return
    }

    & $stopScript -NginxServiceName $NginxServiceName -PhpServiceName $PhpServiceName -NginxRoot $nginxRoot
    Start-Sleep -Seconds 3

    $orphans = @(Get-Process -Name nginx -ErrorAction SilentlyContinue)
    if ($orphans.Count -gt 0) {
        Write-AuditLine ("FIX: Stopping {0} orphan nginx.exe process(es)." -f $orphans.Count)
        $orphans | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    Ensure-Directory -Path (Join-Path -Path $nginxRoot -ChildPath 'logs')

    $remaining = @(Get-Process -Name nginx -ErrorAction SilentlyContinue)
    Write-AuditLine ("nginx.exe count after stabilize: {0}" -f $remaining.Count)
    if ($remaining.Count -gt 0) {
        Register-AuditIssue "Orphan nginx processes remain ($($remaining.Count)) after stop and force-kill."
    }

    if ($StartServices) {
        if (-not (Test-Path -LiteralPath $startScript)) {
            Register-AuditIssue "Missing $startScript"
            return
        }

        & $startScript -NginxServiceName $NginxServiceName -PhpServiceName $PhpServiceName
        $global:LASTEXITCODE = 0
    }
}

function Invoke-NginxConfigTest {
    if (-not (Test-Path -LiteralPath $nginxExe)) {
        Register-AuditIssue "Missing $nginxExe"
        return $false
    }

    Push-Location -LiteralPath $nginxRoot
    try {
        $output = & $nginxExe -p $nginxRoot -c 'conf\nginx.conf' -t 2>&1 | Out-String
        Write-AuditLine $output.Trim()
        if ($output -notmatch 'successful') {
            Register-AuditIssue 'nginx -t did not report successful.'
            return $false
        }

        return $true
    }
    finally {
        Pop-Location
        $global:LASTEXITCODE = 0
    }
}

function Invoke-RefreshPhpIniInstall {
    if (-not (Test-Path -LiteralPath $installScript)) {
        Register-AuditIssue "install.ps1 not found at $installScript"
        return
    }

    $command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$installScript`" -InstallRoot `"$InstallRoot`" -PhpVersion $PhpVersion -SkipNginxReplace -SkipServiceStart"
    Write-AuditLine "FIX: Running install.ps1 to create or refresh php.ini (nginx binaries and conf.d preserved)."
    Write-AuditLine "COMMAND: $command"
    & $installScript -InstallRoot $InstallRoot -PhpVersion $PhpVersion -SkipNginxReplace -SkipServiceStart
    if ($LASTEXITCODE -ne 0) {
        Register-AuditIssue "install.ps1 exited with code $LASTEXITCODE"
    }

    $global:LASTEXITCODE = 0
}

function Test-HttpEndpoint {
    param(
        [string]$Url,
        [int]$TimeoutSeconds,
        [string]$HostHeader = ''
    )

    try {
        $params = @{
            Uri             = $Url
            UseBasicParsing = $true
            TimeoutSec      = $TimeoutSeconds
        }
        if (-not [string]::IsNullOrWhiteSpace($HostHeader)) {
            $params.Headers = @{ Host = $HostHeader }
        }

        $response = Invoke-WebRequest @params
        $hostNote = if ([string]::IsNullOrWhiteSpace($HostHeader)) { '' } else { " Host=$HostHeader" }
        Write-AuditLine "HTTP $($response.StatusCode) $Url$hostNote"
        $preview = ($response.Content -split "`n" | Select-Object -First 5) -join ' | '
        if (-not [string]::IsNullOrWhiteSpace($preview)) {
            Write-AuditLine "BODY (first lines): $preview"
        }
        return $true
    }
    catch {
        $hostNote = if ([string]::IsNullOrWhiteSpace($HostHeader)) { '' } else { " Host=$HostHeader" }
        Register-AuditIssue "HTTP test failed for $Url$hostNote : $($_.Exception.Message)"
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
            Register-AuditIssue "Too many nginx.exe processes ($($nginxProcs.Count)). Use -AutoFix or -StabilizeNginx to stop orphans."
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

        $configs = @(Get-ActiveNginxConfFiles -Root $confDir)
        Write-AuditLine ("conf.d active .conf file count: {0}" -f $configs.Count)
        foreach ($file in $configs) {
            Write-AuditLine ("  {0} ({1} bytes)" -f $file.Name, $file.Length)
        }
        if ($configs.Count -eq 0) {
            Register-AuditIssue 'No active .conf files in conf.d (custom vhosts may have been lost).'
        }
    }

    Invoke-AuditCommand -Label 'Duplicate vhost scan (listen + server_name)' -CommandText 'Parse conf.d server blocks' -Action {
        if (-not (Test-Path -LiteralPath $confDir)) {
            return
        }

        $report = Get-DuplicateVhostReport -Root $confDir
        if ($report.Duplicates.Count -eq 0) {
            Write-AuditLine 'No duplicate listen + server_name pairs detected.'
            return
        }

        foreach ($row in $report.Duplicates) {
            Write-AuditLine (
                "DUPLICATE port {0} server_name {1}: keep $($row.WinnerFile), also in $($row.DuplicateFile)" -f
                $row.Port, $row.ServerName
            )
            Register-AuditIssue (
                "Conflicting server_name on port $($row.Port) for '$($row.ServerName)' ($($row.DuplicateFile) vs $($row.WinnerFile))."
            )
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
        [void](Invoke-NginxConfigTest)
    }

    Invoke-AuditCommand -Label 'nginx log patterns (upstream / 502)' -CommandText 'Select-String error.log and access.log' -Action {
        $errorLog = Join-Path -Path $nginxRoot -ChildPath 'logs\error.log'
        $accessLog = Join-Path -Path $nginxRoot -ChildPath 'logs\access.log'

        if (Test-Path -LiteralPath $errorLog) {
            $errorHits = @(Select-String -Path $errorLog -Pattern 'upstream|connect\(\) failed|recv\(\) failed|Primary script unknown|conflicting server name' -ErrorAction SilentlyContinue |
                Select-Object -Last 20)
            Write-AuditLine ("error.log pattern hits (last 20): {0}" -f $errorHits.Count)
            foreach ($hit in $errorHits) {
                Write-AuditLine $hit.Line
            }
        }
        else {
            Write-AuditLine "No error log at $errorLog"
        }

        if (Test-Path -LiteralPath $accessLog) {
            $accessHits = @(Select-String -Path $accessLog -Pattern ' 502 ' -ErrorAction SilentlyContinue | Select-Object -Last 20)
            Write-AuditLine ("access.log HTTP 502 lines (last 20): {0}" -f $accessHits.Count)
            foreach ($hit in $accessHits) {
                Write-AuditLine $hit.Line
            }
        }
        else {
            Write-AuditLine "No access log at $accessLog"
        }
    }

    Invoke-AuditCommand -Label 'Recent nginx error log (tail)' -CommandText "Get-Content `"$(Join-Path $nginxRoot 'logs\error.log')`" -Tail 40" -Action {
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

    Invoke-AuditCommand -Label 'Recent PHP service stdout' -CommandText "Get-Content `"$(Join-Path $phpRoot 'logs\php-service.out.log')`" -Tail 30" -Action {
        $phpOut = Join-Path -Path $phpRoot -ChildPath 'logs\php-service.out.log'
        if (-not (Test-Path -LiteralPath $phpOut)) {
            Write-AuditLine "No PHP service stdout log at $phpOut"
            return
        }

        Get-Content -Path $phpOut -Tail 30 | ForEach-Object { Write-AuditLine $_ }
    }

    if (-not $SkipHttpTests) {
        Invoke-AuditCommand -Label 'HTTP smoke tests (default Host)' -CommandText 'Invoke-WebRequest http://127.0.0.1:<port>/' -Action {
            $ports = Get-ListeningPortsFromConf -Root $confDir
            foreach ($port in $ports) {
                [void](Test-HttpEndpoint -Url "http://127.0.0.1:$port/" -TimeoutSeconds $HttpTimeoutSeconds)
            }
        }

        Invoke-AuditCommand -Label 'HTTP smoke tests (vhost Host headers)' -CommandText 'Invoke-WebRequest with Host from conf.d server_name' -Action {
            $bindings = @(Get-VhostBindingsFromConfDir -Root $confDir)
            $seen = New-Object 'System.Collections.Generic.HashSet[string]'
            $tested = 0
            foreach ($binding in $bindings) {
                if ($binding.ServerName -eq '_' -or [string]::IsNullOrWhiteSpace($binding.ServerName)) {
                    continue
                }

                $key = '{0}|{1}' -f $binding.Port, $binding.ServerName
                if ($seen.Contains($key)) {
                    continue
                }

                [void]$seen.Add($key)
                [void](Test-HttpEndpoint -Url "http://127.0.0.1:$($binding.Port)/" -TimeoutSeconds $HttpTimeoutSeconds -HostHeader $binding.ServerName)
                $tested++
                if ($tested -ge 40) {
                    Write-AuditLine 'Stopped after 40 Host-header tests (cap).'
                    break
                }
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
    if ($AutoFix) {
        Write-AuditLine 'AutoFix: ON (stabilize nginx, disable single-block duplicate vhosts, refresh php.ini if missing, then patch + restart).'
    }
    else {
        Write-AuditLine 'Default: audit + patch + restart. Vhost files are not edited unless -AutoFix or -DisableDuplicateVhosts is passed.'
    }

    Invoke-WinginxDiagnostics -Phase 'BEFORE FIXES'

    if (Test-IsAdministrator) {
        if ($script:DoStabilizeNginx) {
            Invoke-AuditCommand -Label 'Stabilize nginx (stop services, kill orphan nginx.exe)' -CommandText "& `"$stopScript`"; Get-Process nginx | Stop-Process -Force" -Action {
                Invoke-StabilizeNginxProcesses -StartServices:$false
            }
        }

        if ($script:DoDisableDuplicateVhosts) {
            Invoke-AuditCommand -Label 'Repair duplicate vhosts' -CommandText 'Rename duplicate single-block .conf to .conf.disabled' -Action {
                Invoke-RepairDuplicateVhosts -Root $confDir -Apply
                [void](Invoke-NginxConfigTest)
            }
        }
    }
    elseif ($script:DoStabilizeNginx -or $script:DoDisableDuplicateVhosts) {
        Register-AuditIssue 'AutoFix/stabilize/duplicate-vhost steps require an elevated session.'
    }

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

    if (Test-IsAdministrator -and $script:DoRefreshPhpIniIfMissing -and -not (Test-Path -LiteralPath $phpIniPath)) {
        Invoke-AuditCommand -Label 'Refresh php.ini (install.ps1 -SkipNginxReplace)' -CommandText "& `"$installScript`" -SkipNginxReplace -SkipServiceStart" -Action {
            Invoke-RefreshPhpIniInstall
        }
    }

    if (Test-IsAdministrator) {
        if ($script:DoStabilizeNginx) {
            Invoke-AuditCommand -Label 'Start winginx services after stabilize' -CommandText "& `"$startScript`"" -Action {
                Invoke-StabilizeNginxProcesses -StartServices
            }
        }
        else {
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
    }

    Start-Sleep -Seconds 3
    Invoke-WinginxDiagnostics -Phase 'AFTER FIXES / RESTART'

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
    Write-AuditLine 'To re-run (full playbook automation):'
    Write-AuditLine ("  powershell -NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -InstallRoot `"$InstallRoot`" -AutoFix")
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
