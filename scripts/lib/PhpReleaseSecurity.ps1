function Get-PhpSecurityConfigPath {
    param([string]$RepoRoot)

    return Join-Path -Path $RepoRoot -ChildPath 'config\php-security.psd1'
}

function Get-PhpSemverVersion {
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return $Version
    }

    if ($Version -match '^(\d+\.\d+\.\d+)') {
        return $Matches[1]
    }

    return $Version
}

function Get-PhpReleaseLine {
    param([string]$VersionSelector)

    if ($VersionSelector -match '^(\d+\.\d+)(?:\.\d+)?$') {
        return $Matches[1]
    }

    throw "Unable to determine PHP release line from '$VersionSelector'."
}

function Get-PhpWindowsBuildKey {
    param(
        [string]$ThreadModel,
        [string]$Compiler,
        [string]$CpuArch
    )

    $threadPrefix = if ($ThreadModel -eq 'nts') { 'nts' } else { 'ts' }
    return "$threadPrefix-$Compiler-$CpuArch"
}

function Get-PhpWindowsReleasesManifest {
    param([string]$BaseUrl)

    $manifestUri = "$BaseUrl/releases.json"
    $response = Invoke-WebRequest -Uri $manifestUri -UseBasicParsing
    return ($response.Content | ConvertFrom-Json)
}

function Get-PhpArchiveNameFromParts {
    param(
        [string]$Version,
        [string]$ThreadModel,
        [string]$Compiler,
        [string]$CpuArch
    )

    $threadSegment = if ($ThreadModel -eq 'nts') { '-nts' } else { '' }
    return "php-$Version$threadSegment-Win32-$Compiler-$CpuArch.zip"
}

function Resolve-PhpWindowsZipFileName {
    param(
        [string]$VersionSelector,
        [string]$ThreadModel,
        [string]$Compiler,
        [string]$CpuArch,
        [string]$BaseUrl,
        [string]$RepoRoot
    )

    $manifest = Get-PhpWindowsReleasesManifest -BaseUrl $BaseUrl
    $releaseLine = Get-PhpReleaseLine -VersionSelector $VersionSelector
    if (-not ($manifest.PSObject.Properties.Name -contains $releaseLine)) {
        throw "PHP release line '$releaseLine' was not found in releases.json."
    }

    $release = $manifest.$releaseLine
    $buildKey = Get-PhpWindowsBuildKey -ThreadModel $ThreadModel -Compiler $Compiler -CpuArch $CpuArch
    if (-not ($release.PSObject.Properties.Name -contains $buildKey)) {
        throw "PHP build '$buildKey' is not available for release line '$releaseLine'."
    }

    $manifestVersion = [string]$release.version
    $resolvedSemver = Resolve-PatchedPhpVersion -VersionSelector $VersionSelector -ResolvedVersion $manifestVersion -RepoRoot $RepoRoot
    $zipPath = [string]$release.$buildKey.zip.path
    if ([string]::IsNullOrWhiteSpace($zipPath)) {
        $zipPath = Get-PhpArchiveNameFromParts -Version $manifestVersion -ThreadModel $ThreadModel -Compiler $Compiler -CpuArch $CpuArch
    }

    if ($VersionSelector -match '^\d+\.\d+\.\d+$') {
        $pinnedSemver = Get-PhpSemverVersion -Version $VersionSelector
        if ([version]$resolvedSemver -lt [version]$pinnedSemver) {
            throw "The PHP build on the Windows mirror ($manifestVersion) is below pinned $pinnedSemver."
        }
    }

    return @{
        ZipFileName      = $zipPath
        ResolvedSemver   = $resolvedSemver
        ManifestVersion  = $manifestVersion
    }
}

function Find-OfflinePhpZipInPackageRoot {
    param(
        [string]$PackageRootPath,
        [string]$VersionSelector,
        [string]$ThreadModel,
        [string]$Compiler,
        [string]$CpuArch,
        [string]$RepoRoot
    )

    if (-not (Test-Path -Path $PackageRootPath)) {
        return $null
    }

    $candidates = New-Object System.Collections.Generic.List[object]

    if ($VersionSelector -match '^\d+\.\d+\.\d+(?:-\d+)?$') {
        $exact = Get-PhpArchiveNameFromParts -Version $VersionSelector -ThreadModel $ThreadModel -Compiler $Compiler -CpuArch $CpuArch
        $exactPath = Join-Path -Path $PackageRootPath -ChildPath $exact
        if (Test-Path -Path $exactPath) {
            [void]$candidates.Add([pscustomobject]@{
                    Path   = $exactPath
                    Semver = Get-PhpSemverVersion -Version $VersionSelector
                })
        }
    }

    $threadSegment = if ($ThreadModel -eq 'nts') { '-nts' } else { '' }
    $pattern = "^php-(\d+\.\d+\.\d+(?:-\d+)?)$([regex]::Escape($threadSegment))-Win32-$([regex]::Escape($Compiler))-$([regex]::Escape($CpuArch))\.zip$"

    Get-ChildItem -Path $PackageRootPath -File -Filter 'php-*.zip' -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match $pattern) {
            $buildVersion = $Matches[1]
            $semver = Get-PhpSemverVersion -Version $buildVersion
            try {
                $floor = Resolve-PatchedPhpVersion -VersionSelector $VersionSelector -ResolvedVersion $semver -RepoRoot $RepoRoot
                if ([version]$semver -ge [version]$floor) {
                    [void]$candidates.Add([pscustomobject]@{
                            Path    = $_.FullName
                            Semver  = $semver
                            Version = $buildVersion
                        })
                }
            }
            catch {
            }
        }
    }

    if ($candidates.Count -gt 0) {
        $picked = @($candidates | Sort-Object { [version]$_.Semver } -Descending | Select-Object -First 1)
        return $picked[0].Path
    }

    return $null
}

function Get-Php2ShellMinimumVersion {
    param(
        [string]$ReleaseLine,
        [string]$RepoRoot
    )

    $configPath = Get-PhpSecurityConfigPath -RepoRoot $RepoRoot
    if (-not (Test-Path -Path $configPath)) {
        return $null
    }

    $config = Import-PowerShellDataFile -Path $configPath
    if ($null -eq $config.php2shell) {
        return $null
    }

    $minimum = $config.php2shell[$ReleaseLine]
    if ([string]::IsNullOrWhiteSpace($minimum)) {
        return $null
    }

    return [string]$minimum
}

function Resolve-PatchedPhpVersion {
    param(
        [string]$VersionSelector,
        [string]$ResolvedVersion,
        [string]$RepoRoot
    )

    $releaseLine = Get-PhpReleaseLine -VersionSelector $VersionSelector
    $minimum = Get-Php2ShellMinimumVersion -ReleaseLine $releaseLine -RepoRoot $RepoRoot
    if ([string]::IsNullOrWhiteSpace($minimum)) {
        return $ResolvedVersion
    }

    $resolvedSemver = Get-PhpSemverVersion -Version $ResolvedVersion
    if ([version]$resolvedSemver -ge [version]$minimum) {
        return $resolvedSemver
    }

    if ($VersionSelector -match '^\d+\.\d+\.\d+$') {
        throw @"
PHP $ResolvedVersion is affected by php2shell (CVE-2026-109618, CVE-2026-109619).
Use at least $minimum for the $releaseLine release line.
"@
    }

    Write-Warning "PHP $releaseLine resolved to $ResolvedVersion, which is below the php2shell fix ($minimum). Selecting $minimum instead."
    return $minimum
}

function Get-InstalledPhpVersion {
    param([string]$PhpRoot)

    $phpCgi = Join-Path -Path $PhpRoot -ChildPath 'php-cgi.exe'
    if (-not (Test-Path -Path $phpCgi)) {
        throw "php-cgi.exe was not found under '$PhpRoot'."
    }

    $output = & $phpCgi -v 2>&1 | Out-String
    if ($output -notmatch 'PHP (\d+\.\d+\.\d+)') {
        throw "Unable to parse PHP version from: $output"
    }

    return $Matches[1]
}

function Set-PhpIniPhp2ShellMitigations {
    param([string]$PhpIniPath)

    if (-not (Test-Path -Path $PhpIniPath)) {
        Write-Warning "php.ini was not found at '$PhpIniPath'. Skipping php2shell ini mitigations."
        return
    }

    $lines = [System.Collections.Generic.List[string]]@([System.IO.File]::ReadAllLines($PhpIniPath))
    $settingName = 'session.upload_progress.enabled'
    $desiredLine = "${settingName}=0"
    $found = $false
    $updated = $false

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $trimmed = $lines[$index].Trim()
        if ($trimmed -match "^\s*;\s*$([regex]::Escape($settingName))\s*=") {
            $lines[$index] = $desiredLine
            $found = $true
            $updated = $true
            break
        }

        if ($trimmed -match "^\s*$([regex]::Escape($settingName))\s*=") {
            if ($trimmed -ne $desiredLine) {
                $lines[$index] = $desiredLine
                $updated = $true
            }

            $found = $true
            break
        }
    }

    if (-not $found) {
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            [void]$lines.Add('')
        }

        [void]$lines.Add('; php2shell mitigation (CVE-2026-109618, CVE-2026-109619)')
        [void]$lines.Add($desiredLine)
        $updated = $true
    }

    if ($updated) {
        [System.IO.File]::WriteAllLines($PhpIniPath, $lines.ToArray())
        Write-Host "Updated php2shell mitigation in '$PhpIniPath' ($desiredLine)."
    }
}
