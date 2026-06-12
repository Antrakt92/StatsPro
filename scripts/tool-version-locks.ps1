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
