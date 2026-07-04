[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(ParameterSetName = 'Interactive')]
    [switch]$Interactive,

    [Parameter(ParameterSetName = 'List')]
    [switch]$List,

    [Parameter(Mandatory = $true, ParameterSetName = 'Search')]
    [string]$Search,

    [Parameter(Mandatory = $true, ParameterSetName = 'Enable')]
    [string]$Enable,

    [Parameter(Mandatory = $true, ParameterSetName = 'Install')]
    [string]$Install,

    [Parameter(Mandatory = $true, ParameterSetName = 'Install')]
    [string]$SourcePath,

    [Parameter(Mandatory = $true, ParameterSetName = 'SearchOnline')]
    [string]$SearchOnline,

    [string]$PhpRoot = 'C:\winginx\php',
    [string]$PhpIniPath,
    [string]$PeclFeedUrl = 'https://pecl.php.net/rest/p/packages.xml'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-PhpIniPath {
    param(
        [string]$ExplicitPath,
        [string]$Root
    )

    if ($ExplicitPath) {
        return (Resolve-Path -Path $ExplicitPath).Path
    }

    $candidate = Join-Path -Path $Root -ChildPath 'php.ini'
    if (-not (Test-Path -Path $candidate)) {
        throw "php.ini was not found at '$candidate'. Pass -PhpIniPath if your file lives elsewhere."
    }

    return $candidate
}

function Get-ManagedBlockRange {
    param([string[]]$Lines)

    $start = [Array]::IndexOf($Lines, '; winginx-managed-extensions:start')
    $end = [Array]::IndexOf($Lines, '; winginx-managed-extensions:end')

    if ($start -lt 0 -or $end -lt 0 -or $end -lt $start) {
        throw 'Managed extension markers were not found in php.ini.'
    }

    return @{
        Start = $start
        End   = $end
    }
}

function Get-AvailableExtensions {
    param([string]$Root)

    $extDir = Join-Path -Path $Root -ChildPath 'ext'
    if (-not (Test-Path -Path $extDir)) {
        throw "PHP extension directory '$extDir' was not found."
    }

    Get-ChildItem -Path $extDir -Filter 'php_*.dll' |
        Sort-Object -Property Name |
        ForEach-Object {
            $_.BaseName -replace '^php_', ''
        }
}

function Get-OnlineExtensionMatches {
    param(
        [string]$Query,
        [string]$FeedUrl
    )

    try {
        $response = Invoke-RestMethod -Uri $FeedUrl -Method Get
    }
    catch {
        throw "Unable to query the online extension feed at '$FeedUrl'. $_"
    }

    $packages = @($response.p)
    if (-not $packages) {
        return @()
    }

    $packages |
        Where-Object { $_ -like "*$Query*" } |
        Sort-Object -Unique
}

function Get-EnabledExtensions {
    param(
        [string[]]$Lines,
        [hashtable]$Range
    )

    if ($Range.End -le ($Range.Start + 1)) {
        return @()
    }

    $managedLines = $Lines[($Range.Start + 1)..($Range.End - 1)]
    $managedLines |
        Where-Object { $_ -match '^\s*extension\s*=' } |
        ForEach-Object {
            ($_ -split '=', 2)[1].Trim().Trim('"', "'")
        }
}

function Save-PhpIni {
    param(
        [string]$Path,
        [string[]]$Lines
    )

    [System.IO.File]::WriteAllLines($Path, $Lines)
}

function Add-ExtensionLine {
    param(
        [string]$Name,
        [string]$IniPath
    )

    $lines = [System.IO.File]::ReadAllLines($IniPath)
    $range = Get-ManagedBlockRange -Lines $lines
    $enabled = @(Get-EnabledExtensions -Lines $lines -Range $range)

    if ($enabled -contains $Name) {
        Write-Host "Extension '$Name' is already enabled."
        return
    }

    $newLines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -le $range.Start; $i++) {
        [void]$newLines.Add($lines[$i])
    }

    foreach ($entry in ($enabled + $Name | Sort-Object -Unique)) {
        [void]$newLines.Add("extension=$entry")
    }

    for ($i = $range.End; $i -lt $lines.Length; $i++) {
        [void]$newLines.Add($lines[$i])
    }

    Save-PhpIni -Path $IniPath -Lines $newLines.ToArray()
    Write-Host "Enabled extension '$Name'. Restart the PHP service to apply changes."
}

function Copy-CustomExtension {
    param(
        [string]$Name,
        [string]$Root,
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Source extension '$Path' was not found."
    }

    $source = Resolve-Path -Path $Path
    $destination = Join-Path -Path (Join-Path -Path $Root -ChildPath 'ext') -ChildPath "php_$Name.dll"
    Copy-Item -Path $source -Destination $destination -Force
    Write-Host "Copied custom extension to '$destination'."
}

function Prompt-YesNo {
    param([string]$Message)

    $answer = Read-Host "$Message [y/N]"
    return $answer -match '^(y|yes)$'
}

function Invoke-InteractiveMode {
    param(
        [string]$Root,
        [string]$IniPath,
        [string[]]$AvailableList,
        [string[]]$EnabledList,
        [string]$FeedUrl
    )

    Write-Host ''
    Write-Host 'winginx PHP extension helper'
    Write-Host "PHP root: $Root"
    Write-Host ''
    Write-Host '1. List bundled and enabled extensions'
    Write-Host '2. Search bundled extensions'
    Write-Host '3. Enable a bundled extension'
    Write-Host '4. Search online extension names'
    Write-Host '5. Install a trusted custom DLL and enable it'
    Write-Host '6. Exit'
    Write-Host ''

    $choice = Read-Host 'Choose an action'
    switch ($choice) {
        '1' {
            Write-Host 'Enabled extensions:'
            foreach ($item in $EnabledList) {
                Write-Host "  - $item"
            }

            Write-Host ''
            Write-Host 'Available bundled extensions:'
            foreach ($item in $AvailableList) {
                $state = if ($EnabledList -contains $item) { 'enabled' } else { 'available' }
                Write-Host ("  - {0} [{1}]" -f $item, $state)
            }
        }
        '2' {
            $query = Read-Host 'Search bundled extension name'
            $matches = $AvailableList | Where-Object { $_ -like "*$query*" }
            if (-not $matches) {
                Write-Warning "No bundled extension matched '$query'."
                return
            }

            foreach ($item in $matches) {
                $state = if ($EnabledList -contains $item) { 'enabled' } else { 'available' }
                Write-Host ("{0} [{1}]" -f $item, $state)
            }
        }
        '3' {
            $name = Read-Host 'Enter the bundled extension name to enable'
            if ($AvailableList -notcontains $name) {
                Write-Warning "Bundled extension '$name' is not available for this PHP build."
                return
            }

            if (Prompt-YesNo -Message "Enable '$name' now and update php.ini?") {
                Add-ExtensionLine -Name $name -IniPath $IniPath
            }
        }
        '4' {
            $query = Read-Host 'Search online extension name'
            $matches = @(Get-OnlineExtensionMatches -Query $query -FeedUrl $FeedUrl)
            if (-not $matches) {
                Write-Warning "No online extension matched '$query'."
                return
            }

            Write-Host 'Online matches:'
            foreach ($item in $matches) {
                Write-Host "  - $item"
            }

            $selected = Read-Host 'Type one match to continue, or press Enter to cancel'
            if ([string]::IsNullOrWhiteSpace($selected)) {
                return
            }

            if ($AvailableList -contains $selected) {
                Write-Host "A bundled DLL already exists for '$selected'."
                if (Prompt-YesNo -Message "Enable bundled extension '$selected'?") {
                    Add-ExtensionLine -Name $selected -IniPath $IniPath
                }
                return
            }

            Write-Warning "No bundled DLL exists for '$selected'. Download a trusted Windows DLL first, then rerun this helper with option 5 or -Install/-SourcePath."
        }
        '5' {
            $name = Read-Host 'Extension name'
            $path = Read-Host 'Full path to a trusted php_<name>.dll file'
            if (Prompt-YesNo -Message "Copy and enable '$name' from '$path'?") {
                Copy-CustomExtension -Name $name -Root $Root -Path $path
                Add-ExtensionLine -Name $name -IniPath $IniPath
            }
        }
        default {
            return
        }
    }
}

$resolvedIniPath = Resolve-PhpIniPath -ExplicitPath $PhpIniPath -Root $PhpRoot
$available = @(Get-AvailableExtensions -Root $PhpRoot)
$lines = [System.IO.File]::ReadAllLines($resolvedIniPath)
$managedRange = Get-ManagedBlockRange -Lines $lines
$enabled = @(Get-EnabledExtensions -Lines $lines -Range $managedRange)

switch ($PSCmdlet.ParameterSetName) {
    'Interactive' {
        Invoke-InteractiveMode -Root $PhpRoot -IniPath $resolvedIniPath -AvailableList $available -EnabledList $enabled -FeedUrl $PeclFeedUrl
    }
    'List' {
        Write-Host 'Enabled extensions:'
        foreach ($item in $enabled) {
            Write-Host "  - $item"
        }

        Write-Host ''
        Write-Host 'Available bundled extensions:'
        foreach ($item in $available) {
            $state = if ($enabled -contains $item) { 'enabled' } else { 'available' }
            Write-Host ("  - {0} [{1}]" -f $item, $state)
        }
    }
    'Search' {
        $matches = $available | Where-Object { $_ -like "*$Search*" }
        if (-not $matches) {
            Write-Warning "No bundled extension matched '$Search'."
            return
        }

        foreach ($item in $matches) {
            $state = if ($enabled -contains $item) { 'enabled' } else { 'available' }
            Write-Host ("{0} [{1}]" -f $item, $state)
        }
    }
    'Enable' {
        if ($available -notcontains $Enable) {
            throw "Bundled extension '$Enable' is not available for this PHP build. Use -Install with -SourcePath to add a custom DLL if you trust the source."
        }

        Add-ExtensionLine -Name $Enable -IniPath $resolvedIniPath
    }
    'SearchOnline' {
        $matches = @(Get-OnlineExtensionMatches -Query $SearchOnline -FeedUrl $PeclFeedUrl)
        if (-not $matches) {
            Write-Warning "No online extension matched '$SearchOnline'."
            return
        }

        Write-Host 'Online matches:'
        foreach ($item in $matches) {
            $bundledState = if ($available -contains $item) { 'bundled' } else { 'not bundled' }
            $enabledState = if ($enabled -contains $item) { 'enabled' } else { 'not enabled' }
            Write-Host ("  - {0} [{1}, {2}]" -f $item, $bundledState, $enabledState)
        }

        $selection = Read-Host 'Type an exact match to continue, or press Enter to cancel'
        if ([string]::IsNullOrWhiteSpace($selection)) {
            return
        }

        if ($available -contains $selection) {
            if (Prompt-YesNo -Message "Enable bundled extension '$selection'?") {
                Add-ExtensionLine -Name $selection -IniPath $resolvedIniPath
            }
        }
        else {
            Write-Warning "No bundled DLL exists for '$selection'. Download a trusted Windows DLL first, then use -Install with -SourcePath."
        }
    }
    'Install' {
        Copy-CustomExtension -Name $Install -Root $PhpRoot -Path $SourcePath
        Add-ExtensionLine -Name $Install -IniPath $resolvedIniPath
    }
}
