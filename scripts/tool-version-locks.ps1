$ErrorActionPreference = "Stop"

function ConvertFrom-StatsProJsonCompat {
    param([string]$Json)
    $command = Get-Command ConvertFrom-Json
    if ($command.Parameters.ContainsKey("Depth")) {
        return ($Json | ConvertFrom-Json -Depth 100)
    }
    return ($Json | ConvertFrom-Json)
}

function Read-StatsProToolLocks {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Tool version lock file not found: $Path"
    }
    return ConvertFrom-StatsProJsonCompat (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

function Get-StatsProLockProperty {
    param($Object, [string]$Name, [string]$Context)
    if ($null -eq $Object) {
        throw "Missing tool lock section: $Context"
    }
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Missing tool lock for ${Context}.${Name}"
    }
    return [string]$property.Value
}

function Get-StatsProLockedChocolateyVersion {
    param($Locks, [string]$PackageName)
    return Get-StatsProLockProperty -Object $Locks.chocolatey -Name $PackageName -Context "chocolatey"
}

function Get-StatsProLockedPortableTool {
    param($Locks, [string]$ToolName)
    if ($null -eq $Locks -or $null -eq $Locks.portable) {
        throw "Missing tool lock section: portable"
    }
    $property = $Locks.portable.PSObject.Properties[$ToolName]
    if (-not $property -or $null -eq $property.Value) {
        throw "Missing tool lock for portable.$ToolName"
    }
    $entry = $property.Value
    return [pscustomobject]@{
        Version = Get-StatsProLockProperty -Object $entry -Name "version" -Context "portable.$ToolName"
        Url = Get-StatsProLockProperty -Object $entry -Name "url" -Context "portable.$ToolName"
        Sha256 = Get-StatsProLockProperty -Object $entry -Name "sha256" -Context "portable.$ToolName"
    }
}

function Get-StatsProLockedLuarocksVersion {
    param($Locks, [string]$PackageName)
    return Get-StatsProLockProperty -Object $Locks.luarocks -Name $PackageName -Context "luarocks"
}

function Get-StatsProLockedCommandPattern {
    param($Locks, [string]$CommandName)
    return Get-StatsProLockProperty -Object $Locks.commands -Name $CommandName -Context "commands"
}

function Get-StatsProChocoInstallArguments {
    param([string]$PackageName, [string]$Version)
    return @("install", $PackageName, "--version", $Version, "-y", "--no-progress")
}

function Assert-StatsProHttpsDownloadUri {
    param([string]$Uri)
    $parsed = $null
    if (-not [System.Uri]::TryCreate($Uri, [System.UriKind]::Absolute, [ref]$parsed) -or
        $parsed.Scheme -ne [System.Uri]::UriSchemeHttps) {
        throw "Pinned tool download URI must use HTTPS: $Uri"
    }
    return $parsed.AbsoluteUri
}

function Get-StatsProPinnedCurlArguments {
    param([string]$Uri, [string]$OutputPath)
    $safeUri = Assert-StatsProHttpsDownloadUri -Uri $Uri
    return @(
        "--fail", "--location", "--silent", "--show-error",
        "--proto", "=https", "--proto-redir", "=https",
        "--retry", "3", "--retry-delay", "2", "--retry-all-errors",
        "--connect-timeout", "15", "--max-time", "120",
        "--output", $OutputPath, $safeUri
    )
}

function Assert-StatsProPinnedArchive {
    param([string]$Path, [string]$ExpectedSha256)
    if ($ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Pinned SHA-256 must contain exactly 64 hexadecimal characters."
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Pinned tool archive not found: $Path"
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $ExpectedSha256.ToLowerInvariant()
    if (-not [System.StringComparer]::Ordinal.Equals($actual, $expected)) {
        throw "Pinned tool archive checksum mismatch."
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-StatsProLuarocksInstallArguments {
    param([string]$PackageName, [string]$Version, [switch]$DepsModeNone)
    $args = @("install", $PackageName, $Version)
    if ($DepsModeNone) {
        $args += "--deps-mode=none"
    }
    return $args
}

function Assert-StatsProPackageVersionLine {
    param(
        [string]$Label,
        [object[]]$Output,
        [string]$ExpectedVersion,
        [ValidateSet("choco", "luarocks")]
        [string]$Format
    )

    $lines = @($Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne "" })
    foreach ($line in $lines) {
        if ($Format -eq "choco") {
            if ($line -match "^$([regex]::Escape($Label))\|(?<version>[^|]+)$" -and $Matches.version -eq $ExpectedVersion) {
                return
            }
        }
        else {
            if ($line -match "^$([regex]::Escape($Label))\s+(?<version>\S+)\s+installed\b" -and $Matches.version -eq $ExpectedVersion) {
                return
            }
        }
    }
    throw "$Label package version must be $ExpectedVersion. Output: $($lines -join ' | ')"
}

function Assert-StatsProCommandVersionText {
    param([string]$Label, [string]$Text, [string]$Pattern)
    if ($Text -notmatch $Pattern) {
        throw "$Label version output did not match <$Pattern>: $Text"
    }
}
