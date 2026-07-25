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
        FileName = Get-StatsProLockProperty -Object $entry -Name "fileName" -Context "portable.$ToolName"
        Sha256 = Get-StatsProLockProperty -Object $entry -Name "sha256" -Context "portable.$ToolName"
    }
}

function Get-StatsProLockedRock {
    param($Locks, [string]$PackageName)
    if ($null -eq $Locks -or $null -eq $Locks.rocks) {
        throw "Missing tool lock section: rocks"
    }
    $property = $Locks.rocks.PSObject.Properties[$PackageName]
    if (-not $property -or $null -eq $property.Value) {
        throw "Missing tool lock for rocks.$PackageName"
    }
    $entry = $property.Value
    return [pscustomobject]@{
        Version = Get-StatsProLockProperty -Object $entry -Name "version" -Context "rocks.$PackageName"
        Url = Get-StatsProLockProperty -Object $entry -Name "url" -Context "rocks.$PackageName"
        FileName = Get-StatsProLockProperty -Object $entry -Name "fileName" -Context "rocks.$PackageName"
        Sha256 = Get-StatsProLockProperty -Object $entry -Name "sha256" -Context "rocks.$PackageName"
    }
}

function Get-StatsProLockedLuarocksVersion {
    param($Locks, [string]$PackageName)
    return (Get-StatsProLockedRock -Locks $Locks -PackageName $PackageName).Version
}

function Get-StatsProLockedCommandPattern {
    param($Locks, [string]$CommandName)
    return Get-StatsProLockProperty -Object $Locks.commands -Name $CommandName -Context "commands"
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

function Get-StatsProPortableToolRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:STATSPRO_OWNED_TOOL_ROOT)) {
        return [System.IO.Path]::GetFullPath($env:STATSPRO_OWNED_TOOL_ROOT)
    }
    $base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    return [System.IO.Path]::GetFullPath((Join-Path $base "statspro-tools"))
}

function Get-StatsProOwnedToolInvocationParent {
    $base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    return [System.IO.Path]::GetFullPath((Join-Path $base "statspro-tool-runs")).TrimEnd('\', '/')
}

function New-StatsProOwnedToolInvocationRoot {
    $parent = Get-StatsProOwnedToolInvocationParent
    $root = [System.IO.Path]::GetFullPath((Join-Path $parent ([System.Guid]::NewGuid().ToString("N"))))
    $prefix = $parent + [System.IO.Path]::DirectorySeparatorChar
    if (-not $root.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Owned tool invocation root escaped its temporary parent."
    }
    return $root
}

function Remove-StatsProOwnedToolInvocationRoot {
    param([string]$Path)

    $parent = Get-StatsProOwnedToolInvocationParent
    $root = [System.IO.Path]::GetFullPath($Path)
    $prefix = $parent + [System.IO.Path]::DirectorySeparatorChar
    $leaf = [System.IO.Path]::GetFileName($root)
    if (-not $root.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notmatch '^[0-9a-f]{32}$') {
        throw "Refusing to remove a non-invocation owned tool root: $root"
    }
    if (-not [System.IO.Directory]::Exists($root)) {
        return
    }
    $rootItem = Get-Item -LiteralPath $root -Force
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to remove a reparse-point owned tool root: $root"
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force)) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to remove an owned tool root containing a reparse point: $($item.FullName)"
        }
    }
    [System.IO.Directory]::Delete($root, $true)
}

function Get-StatsProContentAddressedToolRoot {
    param(
        [string]$ToolRoot,
        [string]$Prefix,
        $Lock
    )

    if ($Prefix -notmatch '^[a-z0-9-]+$') {
        throw "Pinned tool path prefix is malformed: $Prefix"
    }
    if ($Lock.Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Pinned $Prefix version must be a three-part numeric version."
    }
    if ($Lock.Sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Pinned $Prefix SHA-256 is missing or malformed."
    }
    $hashPrefix = $Lock.Sha256.Substring(0, 12).ToLowerInvariant()
    return [System.IO.Path]::GetFullPath((Join-Path $ToolRoot "$Prefix-$($Lock.Version)-$hashPrefix"))
}

function Get-StatsProSha256Text {
    param([string]$Text)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return -join ($algorithm.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") })
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-StatsProOwnedToolLockFingerprint {
    param($Locks)

    $parts = @("statspro-owned-tools-v1")
    foreach ($toolName in @("lua51", "luaLanguageServer", "luaRocks")) {
        $lock = Get-StatsProLockedPortableTool -Locks $Locks -ToolName $toolName
        $parts += @($toolName, $lock.Version, $lock.Url, $lock.FileName, $lock.Sha256.ToLowerInvariant())
    }
    foreach ($packageName in @("argparse", "luafilesystem", "luacheck")) {
        $lock = Get-StatsProLockedRock -Locks $Locks -PackageName $packageName
        $parts += @($packageName, $lock.Version, $lock.Url, $lock.FileName, $lock.Sha256.ToLowerInvariant())
    }
    foreach ($commandName in @("lua5.1", "luac5.1", "lua-language-server", "luarocks", "luacheck")) {
        $parts += @($commandName, (Get-StatsProLockedCommandPattern -Locks $Locks -CommandName $commandName))
    }
    return Get-StatsProSha256Text -Text ($parts -join "`n")
}

function Get-StatsProPortableLuaRocksRoot {
    param($Locks, [string]$ToolRoot = (Get-StatsProPortableToolRoot))

    $luaRocksLock = Get-StatsProLockedPortableTool -Locks $Locks -ToolName "luaRocks"
    $bundleHashes = @($luaRocksLock.Sha256)
    foreach ($packageName in @("argparse", "luafilesystem", "luacheck")) {
        $bundleHashes += (Get-StatsProLockedRock -Locks $Locks -PackageName $packageName).Sha256
    }
    $bundleHash = Get-StatsProSha256Text -Text ($bundleHashes -join "|")
    $bundleLock = [pscustomobject]@{
        Version = $luaRocksLock.Version
        Sha256 = $bundleHash
    }
    return Get-StatsProContentAddressedToolRoot `
        -ToolRoot $ToolRoot `
        -Prefix "luarocks" `
        -Lock $bundleLock
}

function Get-StatsProOwnedToolLayout {
    param(
        $Locks,
        [string]$ToolRoot = (Get-StatsProPortableToolRoot)
    )

    $root = [System.IO.Path]::GetFullPath($ToolRoot)
    $luaLock = Get-StatsProLockedPortableTool -Locks $Locks -ToolName "lua51"
    $luaLanguageServerLock = Get-StatsProLockedPortableTool `
        -Locks $Locks `
        -ToolName "luaLanguageServer"
    $luaRoot = Get-StatsProContentAddressedToolRoot `
        -ToolRoot $root `
        -Prefix "lua" `
        -Lock $luaLock
    $luaLanguageServerRoot = Get-StatsProContentAddressedToolRoot `
        -ToolRoot $root `
        -Prefix "lua-language-server" `
        -Lock $luaLanguageServerLock
    $luaRocksRoot = Get-StatsProPortableLuaRocksRoot -Locks $Locks -ToolRoot $root
    $luacheckLock = Get-StatsProLockedRock -Locks $Locks -PackageName "luacheck"
    $fingerprint = Get-StatsProOwnedToolLockFingerprint -Locks $Locks

    return [pscustomobject]@{
        ToolRoot = $root
        LuaRoot = $luaRoot
        LuaPath = Join-Path $luaRoot "lua5.1.exe"
        LuacPath = Join-Path $luaRoot "luac5.1.exe"
        LuaLanguageServerRoot = $luaLanguageServerRoot
        LuaLanguageServerPath = Join-Path $luaLanguageServerRoot "bin\lua-language-server.exe"
        LuaRocksRoot = $luaRocksRoot
        LuaRocksPath = Join-Path $luaRocksRoot "luarocks.bat"
        LuaRocksLuaPath = Join-Path $luaRocksRoot "lua5.1.exe"
        GeneratedLuacheckPath = Join-Path $luaRocksRoot "systree\bin\luacheck.bat"
        LuacheckScriptPath = Join-Path $luaRocksRoot "systree\lib\luarocks\rocks\luacheck\$($luacheckLock.Version)\bin\luacheck"
        LuacheckShareRoot = Join-Path $luaRocksRoot "systree\share\lua\5.1"
        LuacheckCPathRoot = Join-Path $luaRocksRoot "systree\lib\lua\5.1"
        ManifestPath = Join-Path $root "owned-tools-v1-$($fingerprint.Substring(0, 16)).json"
        LockFingerprint = $fingerprint
    }
}

function Set-StatsProIsolatedLuaProcessEnvironment {
    param(
        [System.Diagnostics.ProcessStartInfo]$StartInfo,
        [hashtable]$Environment = @{}
    )

    foreach ($name in @($StartInfo.EnvironmentVariables.Keys)) {
        if ([string]$name -match '^(?i:LUA_(?:INIT|PATH|CPATH)(?:_|$))') {
            [void]$StartInfo.EnvironmentVariables.Remove([string]$name)
        }
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        $StartInfo.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
    }
}

function Get-StatsProOwnedLuacheckEnvironment {
    param($Layout)

    return @{
        LUA_PATH = (Join-Path $Layout.LuacheckShareRoot "?.lua") + ";" +
            (Join-Path $Layout.LuacheckShareRoot "?\init.lua")
        LUA_CPATH = Join-Path $Layout.LuacheckCPathRoot "?.dll"
    }
}

function Get-StatsProOwnedManifestEntry {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Owned tool manifest input is missing: $Path"
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    return [ordered]@{
        path = $resolved
        sha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Write-StatsProOwnedToolManifest {
    param($Locks, $Layout = (Get-StatsProOwnedToolLayout -Locks $Locks))

    $entries = [ordered]@{
        lua = Get-StatsProOwnedManifestEntry -Path $Layout.LuaPath
        luac = Get-StatsProOwnedManifestEntry -Path $Layout.LuacPath
        luaLanguageServer = Get-StatsProOwnedManifestEntry -Path $Layout.LuaLanguageServerPath
        luaRocks = Get-StatsProOwnedManifestEntry -Path $Layout.LuaRocksPath
        luaRocksLua = Get-StatsProOwnedManifestEntry -Path $Layout.LuaRocksLuaPath
        luacheckScript = Get-StatsProOwnedManifestEntry -Path $Layout.LuacheckScriptPath
        luacheckMain = Get-StatsProOwnedManifestEntry -Path (Join-Path $Layout.LuacheckShareRoot "luacheck\main.lua")
        argparse = Get-StatsProOwnedManifestEntry -Path (Join-Path $Layout.LuacheckShareRoot "argparse.lua")
        luaFileSystem = Get-StatsProOwnedManifestEntry -Path (Join-Path $Layout.LuacheckCPathRoot "lfs.dll")
    }
    $document = [ordered]@{
        schemaVersion = 1
        lockFingerprint = $Layout.LockFingerprint
        tools = $entries
    }
    [System.IO.Directory]::CreateDirectory($Layout.ToolRoot) | Out-Null
    $temporaryPath = "$($Layout.ManifestPath).$([System.Guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $document | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($temporaryPath, "$json`n", [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Layout.ManifestPath -Force
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
    return $Layout.ManifestPath
}

function Read-StatsProOwnedToolManifest {
    param($Locks, $Layout = (Get-StatsProOwnedToolLayout -Locks $Locks))

    if (-not (Test-Path -LiteralPath $Layout.ManifestPath -PathType Leaf)) {
        throw "Owned tool manifest is missing. Run .\scripts\install-check-tools.ps1 -Install -EnforceToolLocks first."
    }
    $manifestPath = (Resolve-Path -LiteralPath $Layout.ManifestPath).Path
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
            $manifestPath, [System.IO.Path]::GetFullPath($Layout.ManifestPath))) {
        throw "Owned tool manifest path does not match the lock-derived path."
    }
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    [void](Assert-StatsProOwnedToolPath `
            -Path $manifestPath `
            -AllowedRoot $Layout.ToolRoot `
            -ExpectedSha256 $manifestHash `
            -Label "owned tool manifest")
    $manifest = ConvertFrom-StatsProJsonCompat (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8)
    if ($manifest.schemaVersion -ne 1 -or
        -not [System.StringComparer]::Ordinal.Equals([string]$manifest.lockFingerprint, $Layout.LockFingerprint)) {
        throw "Owned tool manifest does not match the current tool locks."
    }

    $expected = [ordered]@{
        lua = $Layout.LuaPath
        luac = $Layout.LuacPath
        luaLanguageServer = $Layout.LuaLanguageServerPath
        luaRocks = $Layout.LuaRocksPath
        luaRocksLua = $Layout.LuaRocksLuaPath
        luacheckScript = $Layout.LuacheckScriptPath
        luacheckMain = Join-Path $Layout.LuacheckShareRoot "luacheck\main.lua"
        argparse = Join-Path $Layout.LuacheckShareRoot "argparse.lua"
        luaFileSystem = Join-Path $Layout.LuacheckCPathRoot "lfs.dll"
    }
    $resolved = [ordered]@{}
    foreach ($name in $expected.Keys) {
        $property = $manifest.tools.PSObject.Properties[$name]
        if (-not $property -or $null -eq $property.Value) {
            throw "Owned tool manifest is missing '$name'."
        }
        $entry = $property.Value
        $expectedPath = [System.IO.Path]::GetFullPath($expected[$name])
        $actualPath = [System.IO.Path]::GetFullPath([string]$entry.path)
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($actualPath, $expectedPath)) {
            throw "Owned tool manifest path for '$name' does not match the lock-derived path."
        }
        $resolved[$name] = Assert-StatsProOwnedToolPath `
            -Path $actualPath `
            -AllowedRoot $Layout.ToolRoot `
            -ExpectedSha256 ([string]$entry.sha256) `
            -Label $name
    }
    return [pscustomobject]@{
        LuaPath = $resolved.lua
        LuacPath = $resolved.luac
        LuaLanguageServerPath = $resolved.luaLanguageServer
        LuaRocksPath = $resolved.luaRocks
        LuaRocksLuaPath = $resolved.luaRocksLua
        LuacheckScriptPath = $resolved.luacheckScript
        LuacheckEnvironment = Get-StatsProOwnedLuacheckEnvironment -Layout $Layout
        Layout = $Layout
        ManifestPath = $manifestPath
    }
}

function Assert-StatsProOwnedToolPath {
    param(
        [string]$Path,
        [string]$AllowedRoot,
        [string]$ExpectedSha256,
        [string]$Label
    )

    if ($ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "$Label expected SHA-256 is missing or malformed."
    }
    $rootFull = [System.IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\', '/')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $rootPrefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $pathFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label path escaped the StatsPro-owned tool root."
    }
    if (-not (Test-Path -LiteralPath $pathFull -PathType Leaf)) {
        throw "$Label executable is missing: $pathFull"
    }

    $current = $pathFull
    while ($current.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        [System.StringComparer]::OrdinalIgnoreCase.Equals($current, $rootFull)) {
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label path cannot traverse a reparse point: $current"
        }
        if ([System.StringComparer]::OrdinalIgnoreCase.Equals($current, $rootFull)) {
            break
        }
        $current = [System.IO.Path]::GetDirectoryName($current)
    }

    $actualSha256 = (Get-FileHash -LiteralPath $pathFull -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not [System.StringComparer]::Ordinal.Equals($actualSha256, $ExpectedSha256.ToLowerInvariant())) {
        throw "$Label executable checksum mismatch."
    }
    return $pathFull
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

function Assert-StatsProPackageVersionLine {
    param(
        [string]$Label,
        [object[]]$Output,
        [string]$ExpectedVersion
    )

    $lines = @($Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne "" })
    foreach ($line in $lines) {
        if (($line -match "^$([regex]::Escape($Label))\s+(?<version>\S+)\s+installed\b") -and $Matches.version -eq $ExpectedVersion) {
            return
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
