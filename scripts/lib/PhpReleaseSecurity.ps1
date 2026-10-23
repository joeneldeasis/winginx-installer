function Get-PhpSecurityConfigPath {
    param([string]$RepoRoot)

    return Join-Path -Path $RepoRoot -ChildPath 'config\php-security.psd1'
}

function Get-PhpReleaseLine {
    param([string]$VersionSelector)

    if ($VersionSelector -match '^(\d+\.\d+)(?:\.\d+)?$') {
        return $Matches[1]
    }

    throw "Unable to determine PHP release line from '$VersionSelector'."
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

    if ([version]$ResolvedVersion -ge [version]$minimum) {
        return $ResolvedVersion
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
