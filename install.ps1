[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\winginx',
    [string]$PhpVersion = '8.2',
    [string]$NginxVersion = '1.31.2',
    [ValidateSet('x64', 'x86')]
    [string]$Architecture = 'x64',
    [ValidateSet('nts', 'ts')]
    [string]$PhpThreadModel = 'nts',
    [string]$PhpCompiler = 'vs16',
    [string]$PhpBaseUrl = 'https://downloads.php.net/~windows/releases',
    [string]$NginxBaseUrl = 'https://nginx.org/download',
    [string]$NssmVersion = '2.24',
    [string]$ServerName = 'localhost',
    [int]$HttpPort = 80,
    [string]$FastCgiHost = '127.0.0.1',
    [int]$FastCgiPort = 9000,
    [string]$Timezone = 'UTC',
    [string]$NginxServiceName = 'winginx-nginx',
    [string]$PhpServiceName = 'winginx-php',
    [string]$WebRoot = '',
    [string]$ComposerUrl = 'https://getcomposer.org/download/latest-stable/composer.phar',
    [switch]$SkipServiceStart,
    [switch]$SkipPathUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$ConfigRoot = Join-Path -Path $ScriptRoot -ChildPath 'config'
$TemplateRoot = Join-Path -Path $ScriptRoot -ChildPath 'templates'
$HelperScript = Join-Path -Path $ScriptRoot -ChildPath 'scripts\manage-php-extension.ps1'

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-IsAdministrator)) {
        throw 'Run this installer from an elevated PowerShell session.'
    }
}

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Get-PhpArchiveName {
    param(
        [string]$Version,
        [string]$ThreadModel,
        [string]$Compiler,
        [string]$CpuArch
    )

    $threadSegment = if ($ThreadModel -eq 'nts') { '-nts' } else { '' }
    return "php-$Version$threadSegment-Win32-$Compiler-$CpuArch.zip"
}

function Get-PhpReleasesManifest {
    param([string]$BaseUrl)

    $manifestUri = "$BaseUrl/releases.json"
    $response = Invoke-WebRequest -Uri $manifestUri -UseBasicParsing
    return ($response.Content | ConvertFrom-Json)
}

function Get-PhpBuildKey {
    param(
        [string]$ThreadModel,
        [string]$Compiler,
        [string]$CpuArch
    )

    $threadPrefix = if ($ThreadModel -eq 'nts') { 'nts' } else { 'ts' }
    return "$threadPrefix-$Compiler-$CpuArch"
}

function Resolve-LatestPhpVersion {
    param(
        [string]$VersionSelector,
        [string]$ThreadModel,
        [string]$Compiler,
        [string]$CpuArch,
        [string]$BaseUrl
    )

    if ($VersionSelector -match '^\d+\.\d+\.\d+$') {
        return $VersionSelector
    }

    $manifest = Get-PhpReleasesManifest -BaseUrl $BaseUrl
    if (-not ($manifest.PSObject.Properties.Name -contains $VersionSelector)) {
        throw "PHP release line '$VersionSelector' was not found in releases.json. Supply an explicit -PhpVersion like '8.2.32'."
    }

    $release = $manifest.$VersionSelector
    $buildKey = Get-PhpBuildKey -ThreadModel $ThreadModel -Compiler $Compiler -CpuArch $CpuArch
    if (-not ($release.PSObject.Properties.Name -contains $buildKey)) {
        throw "PHP build '$buildKey' is not available for release line '$VersionSelector'. Check -Architecture, -PhpThreadModel, or -PhpCompiler."
    }

    return [string]$release.version
}

function Test-IsZipFile {
    param([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        return $false
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B)
}

function Download-File {
    param(
        [string]$Uri,
        [string]$DestinationPath
    )

    Write-Host "Downloading $Uri"
    Invoke-WebRequest -Uri $Uri -OutFile $DestinationPath -UseBasicParsing
}

function Download-FileWithFallbacks {
    param(
        [string[]]$Uris,
        [string]$DestinationPath
    )

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($uri in $Uris) {
        try {
            Download-File -Uri $uri -DestinationPath $DestinationPath
            if (Test-IsZipFile -Path $DestinationPath) {
                return
            }

            $message = "Download from '$uri' was not a valid ZIP archive."
            Write-Warning $message
            [void]$errors.Add($message)
        }
        catch {
            $message = "Download failed for '$uri': $($_.Exception.Message)"
            Write-Warning $message
            [void]$errors.Add($message)
        }
    }

    throw ("Unable to download file from any configured source.`n" + ($errors -join "`n"))
}

function Expand-ZipArchive {
    param(
        [string]$ArchivePath,
        [string]$DestinationPath
    )

    if (Test-Path -Path $DestinationPath) {
        try {
            Remove-Item -Path $DestinationPath -Recurse -Force
        }
        catch {
            throw "Unable to replace '$DestinationPath'. Stop the winginx services first, then run the installer again from an elevated PowerShell session. $($_.Exception.Message)"
        }
    }

    Expand-Archive -Path $ArchivePath -DestinationPath $DestinationPath -Force
}

function Get-FileContent {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}

function Set-FileContent {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Path $Path -Parent
    Ensure-Directory -Path $directory
    [System.IO.File]::WriteAllText($Path, $Content)
}

function Render-Template {
    param(
        [string]$TemplatePath,
        [hashtable]$Variables,
        [string]$OutputPath
    )

    $content = Get-FileContent -Path $TemplatePath
    foreach ($key in $Variables.Keys) {
        $content = $content.Replace("{{${key}}}", [string]$Variables[$key])
    }

    Set-FileContent -Path $OutputPath -Content $content
}

function Get-ExtensionConfig {
    $configPath = Join-Path -Path $ConfigRoot -ChildPath 'php-extensions.psd1'
    return Import-PowerShellDataFile -Path $configPath
}

function Get-DefaultExtensions {
    $config = Get-ExtensionConfig
    return @($config.Default)
}

function Get-BuiltInExtensions {
    $config = Get-ExtensionConfig
    if ($config.BuiltIn) {
        return @($config.BuiltIn)
    }

    return @()
}

function Get-ExtensionLines {
    param(
        [string]$PhpRootPath,
        [string[]]$DesiredExtensions
    )

    $extDir = Join-Path -Path $PhpRootPath -ChildPath 'ext'
    $builtIn = Get-BuiltInExtensions
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($name in $DesiredExtensions | Sort-Object -Unique) {
        if ($builtIn -contains $name) {
            continue
        }

        $dllName = "php_$name.dll"
        if (Test-Path -Path (Join-Path -Path $extDir -ChildPath $dllName)) {
            [void]$result.Add("extension=$name")
        }
        else {
            Write-Warning "Skipping unavailable bundled extension '$name'."
        }
    }

    return ($result -join [Environment]::NewLine)
}

function Ensure-FastCgiDirectories {
    param(
        [string]$NginxRoot,
        [string]$PhpRootPath
    )

    @(
        (Join-Path -Path $NginxRoot -ChildPath 'conf')
        (Join-Path -Path $NginxRoot -ChildPath 'conf\conf.d')
        (Join-Path -Path $NginxRoot -ChildPath 'logs')
        (Join-Path -Path $NginxRoot -ChildPath 'temp')
        (Join-Path -Path $NginxRoot -ChildPath 'temp\client_body_temp')
        (Join-Path -Path $NginxRoot -ChildPath 'temp\proxy_temp')
        (Join-Path -Path $NginxRoot -ChildPath 'temp\fastcgi_temp')
        (Join-Path -Path $NginxRoot -ChildPath 'temp\uwsgi_temp')
        (Join-Path -Path $NginxRoot -ChildPath 'temp\scgi_temp')
        (Join-Path -Path $PhpRootPath -ChildPath 'logs')
        (Join-Path -Path $PhpRootPath -ChildPath 'tmp')
        (Join-Path -Path $PhpRootPath -ChildPath 'tmp\session')
    ) | ForEach-Object {
        Ensure-Directory -Path $_
    }
}

function Get-NssmExecutable {
    param(
        [string]$ToolsRoot,
        [string]$Version,
        [string]$CpuArch
    )

    $nssmRoot = Join-Path -Path $ToolsRoot -ChildPath 'nssm'
    $nssmExe = Join-Path -Path $nssmRoot -ChildPath "win64\nssm.exe"
    if ($CpuArch -eq 'x86') {
        $nssmExe = Join-Path -Path $nssmRoot -ChildPath "win32\nssm.exe"
    }

    if (Test-Path -Path $nssmExe) {
        return $nssmExe
    }

    $archivePath = Join-Path -Path $ToolsRoot -ChildPath "nssm-$Version.zip"
    $extractRoot = Join-Path -Path $ToolsRoot -ChildPath "nssm-$Version"
    $archFolder = if ($CpuArch -eq 'x86') { 'win32' } else { 'win64' }
    Ensure-Directory -Path $ToolsRoot
    Ensure-Directory -Path (Join-Path -Path $nssmRoot -ChildPath $archFolder)

    $officialUrls = @(
        "https://nssm.cc/release/nssm-$Version.zip"
        "https://web.archive.org/web/2024id_/https://nssm.cc/release/nssm-$Version.zip"
    )

    try {
        Download-FileWithFallbacks -Uris $officialUrls -DestinationPath $archivePath
        Expand-ZipArchive -ArchivePath $archivePath -DestinationPath $extractRoot

        $nestedRoot = Join-Path -Path $extractRoot -ChildPath "nssm-$Version"
        if (Test-Path -Path $nestedRoot) {
            Copy-Item -Path (Join-Path -Path $nestedRoot -ChildPath '*') -Destination $nssmRoot -Recurse -Force
        }
        else {
            Copy-Item -Path (Join-Path -Path $extractRoot -ChildPath '*') -Destination $nssmRoot -Recurse -Force
        }
    }
    catch {
        Write-Warning "Official NSSM archive could not be downloaded. Trying GitHub fallback."
    }

    if (-not (Test-Path -Path $nssmExe)) {
        $fawnoUrl = if ($CpuArch -eq 'x86') {
            'https://github.com/fawno/nssm.cc/releases/download/v2.24.1/nssm-v2.24.1-Win32.zip'
        }
        else {
            'https://github.com/fawno/nssm.cc/releases/download/v2.24.1/nssm-v2.24.1-Win64.zip'
        }

        $fawnoArchivePath = Join-Path -Path $ToolsRoot -ChildPath 'nssm-fawno.zip'
        $fawnoExtractRoot = Join-Path -Path $ToolsRoot -ChildPath 'nssm-fawno'
        Download-File -Uri $fawnoUrl -DestinationPath $fawnoArchivePath
        if (-not (Test-IsZipFile -Path $fawnoArchivePath)) {
            throw "NSSM fallback download from '$fawnoUrl' was not a valid ZIP archive."
        }

        Expand-ZipArchive -ArchivePath $fawnoArchivePath -DestinationPath $fawnoExtractRoot
        $fawnoExe = Join-Path -Path $fawnoExtractRoot -ChildPath 'nssm.exe'
        if (-not (Test-Path -Path $fawnoExe)) {
            throw "NSSM fallback archive did not contain nssm.exe."
        }

        Copy-Item -Path $fawnoExe -Destination $nssmExe -Force
    }

    if (-not (Test-Path -Path $nssmExe)) {
        throw "Unable to locate NSSM executable at '$nssmExe'."
    }

    return $nssmExe
}

function Test-TcpPortAvailable {
    param([int]$Port)

    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
        $listener.Start()
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $listener) {
            $listener.Stop()
        }
    }
}

function Resolve-HttpPort {
    param(
        [int]$RequestedPort,
        [bool]$ExplicitPortRequested
    )

    if (Test-TcpPortAvailable -Port $RequestedPort) {
        return $RequestedPort
    }

    if (-not $ExplicitPortRequested -and $RequestedPort -eq 80 -and (Test-TcpPortAvailable -Port 8080)) {
        Write-Warning 'Port 80 is not available on this server. Falling back to port 8080.'
        return 8080
    }

    throw "Port $RequestedPort is not available. Choose another port with -HttpPort, or stop the service currently using it."
}

function Stop-OrphanedStackProcesses {
    Get-Process -Name nginx, php-cgi -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*run-nginx.ps1*' } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Wait-StackProcessesStopped {
    param([int]$TimeoutSeconds = 30)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $running = @(Get-Process -Name nginx, php-cgi -ErrorAction SilentlyContinue)
        if ($running.Count -eq 0) {
            return
        }

        Start-Sleep -Seconds 1
    }

    throw 'nginx or php-cgi processes are still running. Stop the winginx services manually, then rerun the installer.'
}

function Stop-InstalledStack {
    param(
        [string]$NginxServiceName,
        [string]$PhpServiceName,
        [string]$NginxRoot = ''
    )

    foreach ($serviceName in @($NginxServiceName, $PhpServiceName)) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -ne $service -and $service.Status -ne 'Stopped') {
            Write-Host "Stopping service $serviceName..."
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            try {
                $service.WaitForStatus('Stopped', (New-TimeSpan -Seconds 30))
            }
            catch {
                Write-Warning "Service '$serviceName' did not stop within 30 seconds."
            }
        }
    }

    if ($NginxRoot -and (Test-Path -Path (Join-Path -Path $NginxRoot -ChildPath 'nginx.exe'))) {
        $logsDir = Join-Path -Path $NginxRoot -ChildPath 'logs'
        if (-not (Test-Path -Path $logsDir)) {
            Ensure-Directory -Path $logsDir
        }

        $nginxExe = Join-Path -Path $NginxRoot -ChildPath 'nginx.exe'
        $previousErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'SilentlyContinue'
            & $nginxExe -p $NginxRoot -s quit 2>&1 | Out-Null
        }
        catch {
            # nginx may already be stopped or the install tree may be incomplete
        }
        finally {
            $ErrorActionPreference = $previousErrorAction
        }

        Start-Sleep -Seconds 1
    }

    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        Stop-OrphanedStackProcesses
        Start-Sleep -Seconds 2
        if (-not (Get-Process -Name nginx, php-cgi -ErrorAction SilentlyContinue)) {
            break
        }
    }

    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        if (Get-Process -Name nginx -ErrorAction SilentlyContinue) {
            & taskkill.exe /F /IM nginx.exe /T 2>&1 | Out-Null
        }
        if (Get-Process -Name php-cgi -ErrorAction SilentlyContinue) {
            & taskkill.exe /F /IM php-cgi.exe /T 2>&1 | Out-Null
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }

    Wait-StackProcessesStopped
}

function Replace-DirectoryContent {
    param(
        [string]$TargetPath,
        [string]$SourcePath
    )

    if (Test-Path -Path $TargetPath) {
        try {
            Remove-Item -Path $TargetPath -Recurse -Force -ErrorAction Stop
        }
        catch {
            $stalePath = '{0}.stale-{1}' -f $TargetPath, ([Guid]::NewGuid().ToString('N'))
            Write-Warning "Unable to delete '$TargetPath'. Moving it aside to '$stalePath'."
            Rename-Item -Path $TargetPath -NewPath $stalePath -Force
        }
    }

    Ensure-Directory -Path $TargetPath
    Copy-Item -Path (Join-Path -Path $SourcePath -ChildPath '*') -Destination $TargetPath -Recurse -Force

    Get-ChildItem -Path (Split-Path -Path $TargetPath -Parent) -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$(Split-Path -Path $TargetPath -Leaf).stale-*" } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Invoke-Nssm {
    param(
        [string]$NssmPath,
        [string[]]$Arguments
    )

    $output = & $NssmPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($output | Out-String).Trim()
        throw "NSSM command failed: nssm $($Arguments -join ' '). $message"
    }
}

function Remove-ServiceIfExists {
    param(
        [string]$NssmPath,
        [string]$ServiceName
    )

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        return
    }

    if ($service.Status -eq 'Running') {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    & $NssmPath remove $ServiceName confirm 2>&1 | Out-Null
}

function Install-ServiceWithNssm {
    param(
        [string]$NssmPath,
        [string]$ServiceName,
        [string]$ExecutablePath,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$StdoutPath,
        [string]$StderrPath,
        [string[]]$Dependencies = @()
    )

    Remove-ServiceIfExists -NssmPath $NssmPath -ServiceName $ServiceName
    Invoke-Nssm -NssmPath $NssmPath -Arguments @('install', $ServiceName, $ExecutablePath)
    Invoke-Nssm -NssmPath $NssmPath -Arguments @('set', $ServiceName, 'AppDirectory', $WorkingDirectory)
    Invoke-Nssm -NssmPath $NssmPath -Arguments @('set', $ServiceName, 'AppParameters', $Arguments)
    Invoke-Nssm -NssmPath $NssmPath -Arguments @('set', $ServiceName, 'Start', 'SERVICE_AUTO_START')
    Invoke-Nssm -NssmPath $NssmPath -Arguments @('set', $ServiceName, 'AppStdout', $StdoutPath)
    Invoke-Nssm -NssmPath $NssmPath -Arguments @('set', $ServiceName, 'AppStderr', $StderrPath)
    Invoke-Nssm -NssmPath $NssmPath -Arguments @('set', $ServiceName, 'AppRotateFiles', '1')
    Invoke-Nssm -NssmPath $NssmPath -Arguments @('set', $ServiceName, 'AppRotateOnline', '1')
    Invoke-Nssm -NssmPath $NssmPath -Arguments @('set', $ServiceName, 'AppExit', 'Default', 'Restart')
    Invoke-Nssm -NssmPath $NssmPath -Arguments @('set', $ServiceName, 'AppThrottle', '15000')
    Invoke-Nssm -NssmPath $NssmPath -Arguments @('set', $ServiceName, 'AppRestartDelay', '3000')

    foreach ($dependency in $Dependencies) {
        Invoke-Nssm -NssmPath $NssmPath -Arguments @('set', $ServiceName, 'DependOnService', $dependency)
    }
}

function Wait-ForServiceRunning {
    param(
        [string]$Name,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            throw "Service '$Name' was not created."
        }

        if ($service.Status -eq 'Running') {
            return
        }

        Start-Sleep -Seconds 1
    }

    throw "Service '$Name' did not reach the Running state within $TimeoutSeconds seconds."
}

function Test-TcpPortListening {
    param([int]$Port)

    return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Test-HttpEndpoint {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 15
    )

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSeconds
        return ($response.StatusCode -eq 200)
    }
    catch {
        return $false
    }
}

function Start-InstalledService {
    param([string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        throw "Service '$Name' was not created."
    }

    if ($service.Status -eq 'Paused') {
        Restart-Service -Name $Name -Force
    }
    elseif ($service.Status -ne 'Running') {
        Start-Service -Name $Name -ErrorAction Stop
    }

    Wait-ForServiceRunning -Name $Name
}

function Add-ToMachinePath {
    param([string[]]$PathsToAdd)

    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ([string]::IsNullOrWhiteSpace($current)) {
        $parts = @()
    }
    else {
        $parts = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $changed = $false
    foreach ($path in $PathsToAdd) {
        $exists = $parts | Where-Object { $_.TrimEnd('\') -ieq $path.TrimEnd('\') }
        if (-not $exists) {
            $parts += $path
            $changed = $true
        }
    }

    if ($changed) {
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'Machine')
        $env:Path = ($parts -join ';') + ';' + $env:Path
    }
}

function Install-PhpTooling {
    param(
        [string]$InstallRootPath,
        [string]$PhpRootPath,
        [string]$ToolsRootPath,
        [string]$DownloadsRootPath,
        [string]$WebRootPath,
        [string]$ComposerDownloadUrl,
        [bool]$UpdateMachinePath
    )

    $binDir = Join-Path -Path $ToolsRootPath -ChildPath 'bin'
    $composerDir = Join-Path -Path $ToolsRootPath -ChildPath 'composer'
    $composerPhar = Join-Path -Path $composerDir -ChildPath 'composer.phar'
    $composerArchive = Join-Path -Path $DownloadsRootPath -ChildPath 'composer.phar'
    $phpExe = Join-Path -Path $PhpRootPath -ChildPath 'php.exe'
    $phpCliIni = Join-Path -Path $PhpRootPath -ChildPath 'php.ini'

    Ensure-Directory -Path $binDir
    Ensure-Directory -Path $composerDir

    Download-File -Uri $ComposerDownloadUrl -DestinationPath $composerArchive
    Copy-Item -Path $composerArchive -Destination $composerPhar -Force

    Render-Template -TemplatePath (Join-Path -Path $TemplateRoot -ChildPath 'bin\composer.cmd.tpl') -OutputPath (Join-Path -Path $binDir -ChildPath 'composer.cmd') -Variables @{
        PHP_EXE       = $phpExe
        PHP_INI       = $phpCliIni
        COMPOSER_PHAR = $composerPhar
    }

    Render-Template -TemplatePath (Join-Path -Path $TemplateRoot -ChildPath 'bin\artisan.cmd.tpl') -OutputPath (Join-Path -Path $binDir -ChildPath 'artisan.cmd') -Variables @{
        PHP_EXE = $phpExe
        PHP_INI = $phpCliIni
    }

    $profileScript = Join-Path -Path $ToolsRootPath -ChildPath 'php-console.profile.ps1'
    Render-Template -TemplatePath (Join-Path -Path $TemplateRoot -ChildPath 'php-console.profile.ps1.tpl') -OutputPath $profileScript -Variables @{
        INSTALL_ROOT  = $InstallRootPath
        PHP_ROOT      = $PhpRootPath
        BIN_DIR       = $binDir
        PHP_EXE       = $phpExe
        PHP_INI       = $phpCliIni
        COMPOSER_PHAR = $composerPhar
    }

    $consoleScript = Join-Path -Path $ToolsRootPath -ChildPath 'php-console.ps1'
    Render-Template -TemplatePath (Join-Path -Path $TemplateRoot -ChildPath 'php-console.ps1.tpl') -OutputPath $consoleScript -Variables @{
        PROFILE_SCRIPT = $profileScript
        WEB_ROOT       = $WebRootPath
    }

    # Ensure CLI uses the managed php.ini when launched from PATH.
    $phpCmd = @"
@echo off
"$phpExe" -c "$phpCliIni" %*
"@
    Set-FileContent -Path (Join-Path -Path $binDir -ChildPath 'php.cmd') -Content $phpCmd

    if ($UpdateMachinePath) {
        Add-ToMachinePath -PathsToAdd @($binDir, $PhpRootPath)
    }

    # Composer prints PHP version details to stderr; ignore that with Stop preference.
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $composerOutput = @(& $phpExe -c $phpCliIni $composerPhar -V 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" }
        })
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Composer verification failed with exit code $LASTEXITCODE."
    }

    $composerVersion = $composerOutput | Where-Object { $_ -match '^Composer version ' } | Select-Object -First 1
    if (-not $composerVersion) {
        throw "Composer verification failed. Output:`n$($composerOutput -join [Environment]::NewLine)"
    }

    Write-Host "Composer installed: $composerVersion"

    return @{
        BinDir         = $binDir
        ComposerPhar   = $composerPhar
        ConsoleScript  = $consoleScript
        ProfileScript  = $profileScript
    }
}

Assert-Administrator

$resolvedWebRoot = if ([string]::IsNullOrWhiteSpace($WebRoot)) {
    Join-Path -Path $InstallRoot -ChildPath 'nginx\html'
}
else {
    $WebRoot
}

$toolsRoot = Join-Path -Path $InstallRoot -ChildPath 'tools'
$downloadsRoot = Join-Path -Path $InstallRoot -ChildPath 'downloads'
$nginxRoot = Join-Path -Path $InstallRoot -ChildPath 'nginx'
$phpRoot = Join-Path -Path $InstallRoot -ChildPath 'php'

Ensure-Directory -Path $InstallRoot
Ensure-Directory -Path $toolsRoot
Ensure-Directory -Path $downloadsRoot

Stop-InstalledStack -NginxServiceName $NginxServiceName -PhpServiceName $PhpServiceName -NginxRoot $nginxRoot

$HttpPort = Resolve-HttpPort -RequestedPort $HttpPort -ExplicitPortRequested $PSBoundParameters.ContainsKey('HttpPort')

$resolvedPhpVersion = Resolve-LatestPhpVersion -VersionSelector $PhpVersion -ThreadModel $PhpThreadModel -Compiler $PhpCompiler -CpuArch $Architecture -BaseUrl $PhpBaseUrl
$phpArchiveName = Get-PhpArchiveName -Version $resolvedPhpVersion -ThreadModel $PhpThreadModel -Compiler $PhpCompiler -CpuArch $Architecture
$phpArchivePath = Join-Path -Path $downloadsRoot -ChildPath $phpArchiveName
$phpArchiveUri = "$PhpBaseUrl/$phpArchiveName"

$nginxArchiveName = "nginx-$NginxVersion.zip"
$nginxArchivePath = Join-Path -Path $downloadsRoot -ChildPath $nginxArchiveName
$nginxArchiveUri = "$NginxBaseUrl/$nginxArchiveName"

Download-File -Uri $phpArchiveUri -DestinationPath $phpArchivePath
Download-File -Uri $nginxArchiveUri -DestinationPath $nginxArchivePath

Stop-InstalledStack -NginxServiceName $NginxServiceName -PhpServiceName $PhpServiceName -NginxRoot $nginxRoot

Expand-ZipArchive -ArchivePath $phpArchivePath -DestinationPath $phpRoot

$nginxExtractRoot = Join-Path -Path $downloadsRoot -ChildPath "nginx-$NginxVersion"
Expand-ZipArchive -ArchivePath $nginxArchivePath -DestinationPath $nginxExtractRoot
$nginxSourceRoot = Join-Path -Path $nginxExtractRoot -ChildPath "nginx-$NginxVersion"
if (-not (Test-Path -Path $nginxSourceRoot)) {
    $nginxSourceRoot = $nginxExtractRoot
}

Replace-DirectoryContent -TargetPath $nginxRoot -SourcePath $nginxSourceRoot

Ensure-FastCgiDirectories -NginxRoot $nginxRoot -PhpRootPath $phpRoot
Ensure-Directory -Path $resolvedWebRoot

$confDir = Join-Path -Path $nginxRoot -ChildPath 'conf\conf.d'
Get-ChildItem -Path $confDir -Filter '*.conf' -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

$defaultExtensions = Get-DefaultExtensions
$extensionLines = Get-ExtensionLines -PhpRootPath $phpRoot -DesiredExtensions $defaultExtensions

Render-Template -TemplatePath (Join-Path -Path $TemplateRoot -ChildPath 'nginx.conf.tpl') -OutputPath (Join-Path -Path $nginxRoot -ChildPath 'conf\nginx.conf') -Variables @{
    NGINX_LOG_DIR    = ($nginxRoot.Replace('\', '/')) + '/logs'
    NGINX_ROOT       = $nginxRoot.Replace('\', '/')
    NGINX_TEMP_DIR   = ($nginxRoot.Replace('\', '/')) + '/temp'
    PHP_FASTCGI_HOST = $FastCgiHost
    PHP_FASTCGI_PORT = $FastCgiPort
}

Render-Template -TemplatePath (Join-Path -Path $TemplateRoot -ChildPath 'conf.d\default.conf.tpl') -OutputPath (Join-Path -Path $nginxRoot -ChildPath 'conf\conf.d\default.conf') -Variables @{
    HTTP_PORT   = $HttpPort
    SERVER_NAME = $ServerName
    WEB_ROOT    = $resolvedWebRoot.Replace('\', '/')
    PHP_ROOT    = $phpRoot.Replace('\', '/')
}

Render-Template -TemplatePath (Join-Path -Path $TemplateRoot -ChildPath 'php.ini.tpl') -OutputPath (Join-Path -Path $phpRoot -ChildPath 'php.ini') -Variables @{
    PHP_ROOT        = $phpRoot.Replace('\', '/')
    TIMEZONE        = $Timezone
    EXTENSION_LINES = $extensionLines
}

$phpTooling = Install-PhpTooling `
    -InstallRootPath $InstallRoot `
    -PhpRootPath $phpRoot `
    -ToolsRootPath $toolsRoot `
    -DownloadsRootPath $downloadsRoot `
    -WebRootPath $resolvedWebRoot `
    -ComposerDownloadUrl $ComposerUrl `
    -UpdateMachinePath (-not $SkipPathUpdate)

$healthPhp = @'
<?php
header('Content-Type: text/plain; charset=utf-8');
echo "winginx ok\n";
echo 'PHP ' . PHP_VERSION . "\n";
'@
Set-FileContent -Path (Join-Path -Path $resolvedWebRoot -ChildPath 'index.php') -Content $healthPhp

$nssmPath = Get-NssmExecutable -ToolsRoot $toolsRoot -Version $NssmVersion -CpuArch $Architecture
$nginxExe = Join-Path -Path $nginxRoot -ChildPath 'nginx.exe'
$phpExe = Join-Path -Path $phpRoot -ChildPath 'php-cgi.exe'
$powershellExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
$nginxLauncher = Join-Path -Path $toolsRoot -ChildPath 'run-nginx.ps1'

Render-Template -TemplatePath (Join-Path -Path $TemplateRoot -ChildPath 'run-nginx.ps1.tpl') -OutputPath $nginxLauncher -Variables @{
    NGINX_ROOT_WIN = $nginxRoot
}

Stop-InstalledStack -NginxServiceName $NginxServiceName -PhpServiceName $PhpServiceName -NginxRoot $nginxRoot

Install-ServiceWithNssm -NssmPath $nssmPath -ServiceName $PhpServiceName -ExecutablePath $phpExe -Arguments "-b $FastCgiHost`:$FastCgiPort -c `"$phpRoot\php.ini`"" -WorkingDirectory $phpRoot -StdoutPath (Join-Path -Path $phpRoot -ChildPath 'logs\php-service.out.log') -StderrPath (Join-Path -Path $phpRoot -ChildPath 'logs\php-service.err.log')

$nginxArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$nginxLauncher`""
Install-ServiceWithNssm -NssmPath $nssmPath -ServiceName $NginxServiceName -ExecutablePath $powershellExe -Arguments $nginxArguments -WorkingDirectory $nginxRoot -StdoutPath (Join-Path -Path $nginxRoot -ChildPath 'logs\nginx-service.out.log') -StderrPath (Join-Path -Path $nginxRoot -ChildPath 'logs\nginx-service.err.log') -Dependencies @($PhpServiceName)

$healthUrl = "http://$ServerName`:$HttpPort/"
if (-not $SkipServiceStart) {
    Start-InstalledService -Name $PhpServiceName
    Start-InstalledService -Name $NginxServiceName
    Start-Sleep -Seconds 3

    if (-not (Test-TcpPortListening -Port $HttpPort)) {
        Write-Warning "nginx is not listening on port $HttpPort. Check '$nginxRoot\logs\error.log'."
    }
    elseif (Test-HttpEndpoint -Url $healthUrl) {
        Write-Host "Health check passed: $healthUrl"
    }
    else {
        Write-Warning "Services are running, but the health check failed for $healthUrl. Check logs under '$nginxRoot\logs' and '$phpRoot\logs'."
    }
}

Write-Host ''
Write-Host 'Installation complete.'
Write-Host "Install root: $InstallRoot"
Write-Host "PHP version:  $resolvedPhpVersion"
Write-Host "nginx version: $NginxVersion"
Write-Host "Site URL: $healthUrl"
Write-Host "Web root: $resolvedWebRoot"
Write-Host "Composer: $($phpTooling.ComposerPhar)"
Write-Host "PHP console: powershell -ExecutionPolicy Bypass -File `"$($phpTooling.ConsoleScript)`""
Write-Host "Manage extensions: powershell -ExecutionPolicy Bypass -File `"$HelperScript`" -PhpRoot `"$phpRoot`" -List"
Write-Host ''
Write-Host 'In the PHP console you can run:'
Write-Host '  php -v'
Write-Host '  composer -V'
Write-Host '  php composer -V'
Write-Host '  php artisan list   (inside a Laravel project)'
Write-Host '  artisan list       (inside a Laravel project)'
