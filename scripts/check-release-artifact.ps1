param(
    [string]$ZipPath,
    [string]$ReleaseJsonPath,
    [string]$ExpectedTag,
    [string]$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")),
    [int]$ArchonMaxAgeDays = 3,
    [string]$ToolLockPath = (Join-Path $PSScriptRoot "tool-version-locks.json"),
    [switch]$EnforceToolLocks,
    [switch]$PackageOnly,
    [switch]$WithReleaseJson,
    [switch]$WriteReleaseJson,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "tool-version-locks.ps1")
. (Join-Path $PSScriptRoot "third-party-contract.ps1")

function Invoke-NativeCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @()
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return @{
        ExitCode = $exitCode
        Output   = $output
    }
}

function ConvertFrom-JsonCompat {
    param([string]$Json)

    $command = Get-Command ConvertFrom-Json
    if ($command.Parameters.ContainsKey("Depth")) {
        return ($Json | ConvertFrom-Json -Depth 100)
    }
    return ($Json | ConvertFrom-Json)
}

function Assert-ThrowsMatch {
    param([string]$Name, [scriptblock]$Script, [string]$Pattern)

    $ok = $false
    try {
        & $Script
        $ok = $true
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Name failed with wrong error: $($_.Exception.Message)"
        }
    }
    if ($ok) {
        throw "$Name should have failed."
    }
}

function Assert-ReleaseTag {
    param([string]$Value)

    if ($Value -notmatch "^v\d+\.\d+\.\d+$") {
        throw "Malformed release tag '$Value'. Expected vX.Y.Z."
    }
}

function Normalize-StatsProZipEntryPath {
    param([string]$Entry)

    if ([string]::IsNullOrWhiteSpace($Entry)) {
        throw "Package contains an empty entry path."
    }
    $path = ($Entry -replace "\\", "/").Trim()
    if ($path.StartsWith("/") -or $path -match "^[A-Za-z]:/" -or $path -match "(^|/)\.\.(/|$)") {
        throw "Package contains unsafe entry path '$Entry'."
    }
    return $path
}

function Get-ZipEntries {
    param([string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        return @($archive.Entries | ForEach-Object { $_.FullName })
    }
    finally {
        $archive.Dispose()
    }
}

function Get-StatsProPackageFileContract {
    $licenseFiles = @(
        Get-StatsProThirdPartyContract |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.LicenseFile) } |
            ForEach-Object { "StatsPro/$($_.LicenseFile)" }
    )
    $requiredFiles = @(
        "StatsPro/CHANGELOG.md",
        "StatsPro/LICENSE",
        "StatsPro/THIRD-PARTY-NOTICES.md"
    ) + $licenseFiles + @(
        "StatsPro/StatsPro.toc",
        "StatsPro/StatsPro.lua",
        "StatsPro/StatsPro_ArchonTargets.lua",
        "StatsPro/textures/logo.png",
        "StatsPro/libs/LibStub/LibStub.lua",
        "StatsPro/libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
        "StatsPro/libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua"
    )
    return [pscustomobject]@{
        RequiredFiles = $requiredFiles
        AllowedFiles  = $requiredFiles
    }
}

function Assert-StatsProPackageEntries {
    param([string[]]$Entries)

    $normalized = @($Entries | ForEach-Object { Normalize-StatsProZipEntryPath $_ })
    if ($normalized.Count -eq 0) {
        throw "Package contains no entries."
    }

    $roots = @($normalized | ForEach-Object { ($_ -split "/", 2)[0] } | Sort-Object -Unique)
    if ($roots.Count -ne 1 -or $roots[0] -ne "StatsPro") {
        throw "Package must contain exactly one root directory named StatsPro. Found: $($roots -join ', ')"
    }

    $fileEntries = @($normalized | Where-Object { -not $_.EndsWith("/") })
    $fileSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in $fileEntries) {
        [void]$fileSet.Add($entry)
    }

    $contract = Get-StatsProPackageFileContract
    foreach ($required in $contract.RequiredFiles) {
        if (-not $fileSet.Contains($required)) {
            throw "Package is missing required file $required."
        }
    }

    $allowedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($allowed in $contract.AllowedFiles) {
        [void]$allowedFiles.Add($allowed)
    }
    foreach ($entry in $fileEntries) {
        if (-not $allowedFiles.Contains($entry)) {
            if ($entry.StartsWith("StatsPro/libs/", [System.StringComparison]::Ordinal)) {
                throw "Package contains unexpected packaged lib file $entry."
            }
            throw "Package contains unexpected packaged file $entry."
        }
    }
}

function Expand-StatsProPackageToTemp {
    param([string]$Path)

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-package-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
        Expand-Archive -LiteralPath $Path -DestinationPath $tempDir -Force
        $packageRoot = Join-Path $tempDir "StatsPro"
        if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
            throw "Expanded package is missing StatsPro root directory."
        }
        return [pscustomobject]@{
            TempDir     = $tempDir
            PackageRoot = $packageRoot
        }
    }
    catch {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Get-SingleRegexMatchFromText {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Description
    )

    $matches = [regex]::Matches($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($matches.Count -eq 0) {
        throw "Missing $Description."
    }
    if ($matches.Count -gt 1) {
        throw "Found multiple $Description values."
    }
    return $matches[0].Groups[1].Value
}

function Get-TocInterfaceValues {
    param([string]$TocPath)

    $tocText = Get-Content -LiteralPath $TocPath -Raw -Encoding UTF8
    $interfaceText = Get-SingleRegexMatchFromText -Text $tocText -Pattern "^##\s+Interface:\s*(.+?)\s*$" -Description "TOC Interface"
    $interfaces = @($interfaceText -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    if ($interfaces.Count -eq 0) {
        throw "TOC Interface contains no values."
    }
    foreach ($interface in $interfaces) {
        if ($interface -notmatch "^\d+$") {
            throw "TOC Interface value '$interface' is not numeric."
        }
    }
    return @($interfaces | ForEach-Object { [int]$_ })
}

function Assert-PackagedStatsProVersionMetadata {
    param(
        [string]$PackageRoot,
        [string]$ExpectedTag
    )

    Assert-ReleaseTag $ExpectedTag
    $expectedVersion = $ExpectedTag.Substring(1)
    $tocPath = Join-Path $PackageRoot "StatsPro.toc"
    $luaPath = Join-Path $PackageRoot "StatsPro.lua"
    $tocText = Get-Content -LiteralPath $tocPath -Raw -Encoding UTF8
    $luaText = Get-Content -LiteralPath $luaPath -Raw -Encoding UTF8

    $tocVersion = Get-SingleRegexMatchFromText -Text $tocText -Pattern "^##\s+Version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$" -Description "TOC Version"
    if ($tocVersion -ne $expectedVersion) {
        throw "Packaged TOC Version is $tocVersion, expected $expectedVersion."
    }

    $currentRelease = Get-SingleRegexMatchFromText -Text $luaText -Pattern 'CURRENT_RELEASE\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"' -Description "StatsPro.lua CURRENT_RELEASE"
    if ($currentRelease -ne $expectedVersion) {
        throw "Packaged CURRENT_RELEASE is $currentRelease, expected $expectedVersion."
    }

    return [pscustomobject]@{
        Version    = $expectedVersion
        Interfaces = @(Get-TocInterfaceValues -TocPath $tocPath)
    }
}

function Assert-StatsProReleaseJson {
    param(
        [string]$JsonText,
        [string]$ExpectedTag,
        [int[]]$ExpectedInterfaces = @(120007, 120100)
    )

    Assert-ReleaseTag $ExpectedTag
    $json = ConvertFrom-JsonCompat $JsonText
    $releases = @($json.releases)
    if ($releases.Count -eq 0) {
        throw "release.json contains no releases."
    }
    $statsProReleases = @($releases | Where-Object { $_.name -eq "StatsPro" })
    if ($statsProReleases.Count -ne 1) {
        throw "release.json must contain exactly one StatsPro release, found $($statsProReleases.Count)."
    }

    $release = $statsProReleases[0]
    if ($release.version -ne $ExpectedTag) {
        throw "release.json StatsPro version is '$($release.version)', expected '$ExpectedTag'."
    }
    $expectedZip = "StatsPro-$ExpectedTag.zip"
    if ($release.filename -ne $expectedZip) {
        throw "release.json StatsPro filename is '$($release.filename)', expected '$expectedZip'."
    }
    if ($null -eq $release.nolib) {
        throw "release.json StatsPro release is missing nolib state."
    }
    if ([bool]$release.nolib) {
        throw "release.json StatsPro release must be a lib-inclusive package, got nolib=true."
    }

    $metadata = @($release.metadata)
    $expectedSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($interface in $ExpectedInterfaces) {
        [void]$expectedSet.Add([int]$interface)
    }
    if ($metadata.Count -ne $expectedSet.Count) {
        throw "release.json metadata entry count is $($metadata.Count), expected $($expectedSet.Count)."
    }
    $actualSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($entry in $metadata) {
        if ($entry.flavor -ne "mainline") {
            throw "release.json metadata flavor is '$($entry.flavor)', expected 'mainline'."
        }
        if ($null -eq $entry.interface) {
            throw "release.json metadata entry is missing interface."
        }
        [void]$actualSet.Add([int]$entry.interface)
    }
    if ($actualSet.Count -ne $expectedSet.Count) {
        throw "release.json interface count is $($actualSet.Count), expected $($expectedSet.Count)."
    }
    foreach ($interface in $expectedSet) {
        if (-not $actualSet.Contains($interface)) {
            throw "release.json is missing interface $interface."
        }
    }
}

function New-StatsProReleaseJsonText {
    param(
        [string]$ExpectedTag,
        [int[]]$Interfaces
    )

    Assert-ReleaseTag $ExpectedTag
    if ($Interfaces.Count -eq 0) {
        throw "Cannot create release.json without TOC Interface values."
    }
    $metadata = @($Interfaces | ForEach-Object {
        [ordered]@{
            flavor    = "mainline"
            interface = [int]$_
        }
    })
    $document = [ordered]@{
        releases = @(
            [ordered]@{
                name     = "StatsPro"
                version  = $ExpectedTag
                filename = "StatsPro-$ExpectedTag.zip"
                nolib    = $false
                metadata = $metadata
            }
        )
    }
    return ($document | ConvertTo-Json -Depth 8 -Compress)
}

function Write-StatsProReleaseJson {
    param(
        [string]$Path,
        [string]$ExpectedTag,
        [int[]]$Interfaces
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Missing release.json output path."
    }
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = New-StatsProReleaseJsonText -ExpectedTag $ExpectedTag -Interfaces $Interfaces
    [System.IO.File]::WriteAllText($Path, "$json`n", [System.Text.UTF8Encoding]::new($false))
}

function Resolve-Lua51 {
    $command = Get-Command "lua5.1" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    throw "lua5.1 is required for Archon target validation."
}

function Assert-Lua51VersionLock {
    param([string]$LuaPath, [string]$LockPath)
    $locks = Read-StatsProToolLocks -Path $LockPath
    $result = Invoke-NativeCapture -FilePath $LuaPath -Arguments @("-v")
    if ($result.ExitCode -ne 0) {
        throw "lua5.1 -v exited with code $($result.ExitCode): $($result.Output -join ' ')"
    }
    Assert-StatsProCommandVersionText -Label "lua5.1" -Text ($result.Output -join "`n") -Pattern (Get-StatsProLockedCommandPattern -Locks $locks -CommandName "lua5.1")
}

function Invoke-ArchonTargetValidator {
    param(
        [string]$LuaPath,
        [string]$ValidatorPath,
        [string[]]$Arguments
    )

    $result = Invoke-NativeCapture -FilePath $LuaPath -Arguments (@($ValidatorPath) + $Arguments)
    if ($result.ExitCode -ne 0) {
        throw "Archon target validator failed with code $($result.ExitCode): $($result.Output -join ' ')"
    }
    return @($result.Output)
}

function Get-ArchonSemanticLines {
    param(
        [string]$LuaPath,
        [string]$ValidatorPath,
        [string]$TargetPath,
        [string]$StatsProLuaPath
    )

    $output = Invoke-ArchonTargetValidator -LuaPath $LuaPath -ValidatorPath $ValidatorPath -Arguments @(
        "--path", $TargetPath,
        "--statspro-lua", $StatsProLuaPath,
        "--semantic-lines",
        "--allow-stale"
    )
    return @($output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

function Assert-PackagedArchonTargets {
    param(
        [string]$PackageRoot,
        [string]$SourceRoot,
        [int]$MaxAgeDays
    )

    $lua = Resolve-Lua51
    if ($EnforceToolLocks) {
        Assert-Lua51VersionLock -LuaPath $lua -LockPath $ToolLockPath
    }
    $validator = Join-Path $SourceRoot "scripts\check-archon-targets.lua"
    if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
        throw "Missing Archon target validator: $validator"
    }

    $packageTarget = Join-Path $PackageRoot "StatsPro_ArchonTargets.lua"
    $packageLua = Join-Path $PackageRoot "StatsPro.lua"
    Invoke-ArchonTargetValidator -LuaPath $lua -ValidatorPath $validator -Arguments @(
        "--path", $packageTarget,
        "--statspro-lua", $packageLua,
        "--max-age-days", [string]$MaxAgeDays
    ) | Out-Null

    $sourceTarget = Join-Path $SourceRoot "StatsPro_ArchonTargets.lua"
    $sourceLua = Join-Path $SourceRoot "StatsPro.lua"
    $packageLines = @(Get-ArchonSemanticLines -LuaPath $lua -ValidatorPath $validator -TargetPath $packageTarget -StatsProLuaPath $packageLua)
    $sourceLines = @(Get-ArchonSemanticLines -LuaPath $lua -ValidatorPath $validator -TargetPath $sourceTarget -StatsProLuaPath $sourceLua)
    if ($packageLines.Count -ne $sourceLines.Count) {
        throw "Packaged Archon target semantic line count $($packageLines.Count) does not match source count $($sourceLines.Count)."
    }
    for ($index = 0; $index -lt $sourceLines.Count; $index++) {
        if ($packageLines[$index] -ne $sourceLines[$index]) {
            throw "Packaged Archon target semantic mismatch at entry $($index + 1)."
        }
    }
}

function Assert-StatsProReleaseArtifact {
    param(
        [string]$ZipPath,
        [string]$ReleaseJsonPath,
        [string]$ExpectedTag,
        [string]$SourceRoot,
        [int]$ArchonMaxAgeDays,
        [bool]$PackageOnly,
        [bool]$WithReleaseJson,
        [bool]$WriteReleaseJson
    )

    if ($PackageOnly -and $WithReleaseJson) {
        throw "Choose only one of -PackageOnly or -WithReleaseJson."
    }
    if (-not $PackageOnly -and -not $WithReleaseJson) {
        $WithReleaseJson = -not [string]::IsNullOrWhiteSpace($ReleaseJsonPath)
        $PackageOnly = -not $WithReleaseJson
    }

    if ([string]::IsNullOrWhiteSpace($ZipPath)) {
        throw "Missing -ZipPath."
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedTag)) {
        throw "Missing -ExpectedTag."
    }
    Assert-ReleaseTag $ExpectedTag
    $zipFullPath = (Resolve-Path $ZipPath).Path
    $sourceFullPath = (Resolve-Path $SourceRoot).Path

    $entries = Get-ZipEntries -Path $zipFullPath
    Assert-StatsProPackageEntries -Entries $entries

    $expanded = $null
    try {
        $expanded = Expand-StatsProPackageToTemp -Path $zipFullPath
        $versionMetadata = Assert-PackagedStatsProVersionMetadata -PackageRoot $expanded.PackageRoot -ExpectedTag $ExpectedTag
        Assert-StatsProThirdPartyMaterials -Root $expanded.PackageRoot
        Assert-PackagedArchonTargets -PackageRoot $expanded.PackageRoot -SourceRoot $sourceFullPath -MaxAgeDays $ArchonMaxAgeDays
        if ($WithReleaseJson) {
            if ([string]::IsNullOrWhiteSpace($ReleaseJsonPath)) {
                throw "-WithReleaseJson requires -ReleaseJsonPath."
            }
            if ($WriteReleaseJson) {
                Write-StatsProReleaseJson -Path $ReleaseJsonPath -ExpectedTag $ExpectedTag -Interfaces $versionMetadata.Interfaces
            }
            $releaseJsonText = Get-Content -LiteralPath (Resolve-Path $ReleaseJsonPath).Path -Raw -Encoding UTF8
            Assert-StatsProReleaseJson -JsonText $releaseJsonText -ExpectedTag $ExpectedTag -ExpectedInterfaces $versionMetadata.Interfaces
        }
    }
    finally {
        if ($expanded -and (Test-Path -LiteralPath $expanded.TempDir)) {
            Remove-Item -LiteralPath $expanded.TempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "StatsPro release artifact checks passed for $ExpectedTag."
}

function New-TestPackageZip {
    param(
        [string]$SourceRoot,
        [string]$ZipPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }
    $archive = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in (Get-StatsProPackageFileContract).RequiredFiles) {
            $relative = $file.Substring("StatsPro/".Length)
            $sourceFile = Join-Path $SourceRoot ($relative -replace "/", [System.IO.Path]::DirectorySeparatorChar)
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $sourceFile, $file) | Out-Null
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-SourceVersionTag {
    param([string]$Root)

    $tocText = Get-Content -LiteralPath (Join-Path $Root "StatsPro.toc") -Raw -Encoding UTF8
    $version = Get-SingleRegexMatchFromText -Text $tocText -Pattern "^##\s+Version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$" -Description "TOC Version"
    return "v$version"
}

function Invoke-SelfTest {
    $sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $tag = Get-SourceVersionTag -Root $sourceRoot
    $interfaces = @(Get-TocInterfaceValues -TocPath (Join-Path $sourceRoot "StatsPro.toc"))
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-artifact-test-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
        [void](Normalize-StatsProZipEntryPath "StatsPro/StatsPro.lua")
        Assert-ThrowsMatch "unsafe zip path rejected" {
            [void](Normalize-StatsProZipEntryPath "StatsPro/../evil.lua")
        } "unsafe"

        $zip = Join-Path $tempDir "StatsPro-$tag.zip"
        New-TestPackageZip -SourceRoot $sourceRoot -ZipPath $zip
        $jsonPath = Join-Path $tempDir "release.json"
        Assert-StatsProReleaseArtifact -ZipPath $zip -ReleaseJsonPath $jsonPath -ExpectedTag $tag -SourceRoot $sourceRoot -ArchonMaxAgeDays 99999 -PackageOnly:$false -WithReleaseJson:$true -WriteReleaseJson:$true
        $expectedJson = New-StatsProReleaseJsonText -ExpectedTag $tag -Interfaces $interfaces
        if ((Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8).Trim() -ne $expectedJson) {
            throw "Generated release.json is not deterministic."
        }
        Assert-StatsProReleaseArtifact -ZipPath $zip -ExpectedTag $tag -SourceRoot $sourceRoot -ArchonMaxAgeDays 99999 -PackageOnly:$true -WithReleaseJson:$false -WriteReleaseJson:$false
        $branchZip = Join-Path $tempDir "StatsPro-$tag-12-gabcdef0.zip"
        Copy-Item -LiteralPath $zip -Destination $branchZip
        Assert-StatsProReleaseArtifact -ZipPath $branchZip -ExpectedTag $tag -SourceRoot $sourceRoot -ArchonMaxAgeDays 99999 -PackageOnly:$true -WithReleaseJson:$false

        Assert-ThrowsMatch "release json mismatch rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"Other"}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "StatsPro"
        Assert-ThrowsMatch "release json wrong version rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"StatsPro","version":"v1.2.2","filename":"StatsPro-v1.2.3.zip","nolib":false,"metadata":[{"flavor":"mainline","interface":120007}]}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "version"
        Assert-ThrowsMatch "release json wrong filename rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"StatsPro","version":"v1.2.3","filename":"StatsPro-v1.2.3-1-gabc.zip","nolib":false,"metadata":[{"flavor":"mainline","interface":120007}]}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "filename"
        Assert-ThrowsMatch "release json missing nolib rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"StatsPro","version":"v1.2.3","filename":"StatsPro-v1.2.3.zip","metadata":[{"flavor":"mainline","interface":120007}]}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "nolib"
        Assert-ThrowsMatch "release json nolib true rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"StatsPro","version":"v1.2.3","filename":"StatsPro-v1.2.3.zip","nolib":true,"metadata":[{"flavor":"mainline","interface":120007}]}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "nolib=true"
        Assert-ThrowsMatch "release json wrong flavor rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"StatsPro","version":"v1.2.3","filename":"StatsPro-v1.2.3.zip","nolib":false,"metadata":[{"flavor":"classic","interface":120007}]}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "flavor"
        Assert-ThrowsMatch "release json missing interface rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"StatsPro","version":"v1.2.3","filename":"StatsPro-v1.2.3.zip","nolib":false,"metadata":[{"flavor":"mainline"}]}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "interface"
        Assert-ThrowsMatch "release json duplicate metadata rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"StatsPro","version":"v1.2.3","filename":"StatsPro-v1.2.3.zip","nolib":false,"metadata":[{"flavor":"mainline","interface":120007},{"flavor":"mainline","interface":120007}]}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "entry count"

        $noticeRoot = Join-Path $tempDir "notice-root"
        $noticeRequirements = @(Get-StatsProThirdPartyContract)
        foreach ($requirement in $noticeRequirements) {
            $runtimeSource = Join-Path $sourceRoot ($requirement.Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
            $runtimeTarget = Join-Path $noticeRoot ($requirement.Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
            New-Item -ItemType Directory -Path (Split-Path -Parent $runtimeTarget) -Force | Out-Null
            Copy-Item -LiteralPath $runtimeSource -Destination $runtimeTarget
            if (-not [string]::IsNullOrWhiteSpace($requirement.LicenseFile)) {
                $licenseSource = Join-Path $sourceRoot ($requirement.LicenseFile -replace "/", [System.IO.Path]::DirectorySeparatorChar)
                $licenseTarget = Join-Path $noticeRoot ($requirement.LicenseFile -replace "/", [System.IO.Path]::DirectorySeparatorChar)
                New-Item -ItemType Directory -Path (Split-Path -Parent $licenseTarget) -Force | Out-Null
                Copy-Item -LiteralPath $licenseSource -Destination $licenseTarget
            }
        }
        $noticePath = Join-Path $noticeRoot "THIRD-PARTY-NOTICES.md"
        Copy-Item -LiteralPath (Join-Path $sourceRoot "THIRD-PARTY-NOTICES.md") -Destination $noticePath
        $validNotice = Get-Content -LiteralPath $noticePath -Raw -Encoding UTF8
        Assert-StatsProThirdPartyMaterials -Root $noticeRoot

        Set-Content -LiteralPath $noticePath -Value ($validNotice -replace "(?ms)^## libs/LibStub/LibStub\.lua.*?(?=^## |\z)", "") -Encoding UTF8
        Assert-ThrowsMatch "notice missing library section rejected" {
            Assert-StatsProThirdPartyMaterials -Root $noticeRoot
        } "missing section"

        Set-Content -LiteralPath $noticePath -Value ($validNotice -replace "License: BSD-2-Clause", "License: MIT") -Encoding UTF8
        Assert-ThrowsMatch "notice wrong license rejected" {
            Assert-StatsProThirdPartyMaterials -Root $noticeRoot
        } "License: BSD-2-Clause"

        Set-Content -LiteralPath $noticePath -Value ($validNotice -replace $noticeRequirements[2].RuntimeSha256, ("0" * 64)) -Encoding UTF8
        Assert-ThrowsMatch "notice stale hash rejected" {
            Assert-StatsProThirdPartyMaterials -Root $noticeRoot
        } "SHA256"

        Set-Content -LiteralPath $noticePath -Value ($validNotice -replace $noticeRequirements[1].LicenseDeclarationSha256, ("0" * 64)) -Encoding UTF8
        Assert-ThrowsMatch "notice stale provenance hash rejected" {
            Assert-StatsProThirdPartyMaterials -Root $noticeRoot
        } "License declaration SHA256"

        Set-Content -LiteralPath $noticePath -Value $validNotice -Encoding UTF8
        Remove-Item -LiteralPath (Join-Path $noticeRoot $noticeRequirements[1].LicenseFile)
        Assert-ThrowsMatch "missing packaged license rejected" {
            Assert-StatsProThirdPartyMaterials -Root $noticeRoot
        } "Missing license text"

        Copy-Item -LiteralPath (Join-Path $sourceRoot $noticeRequirements[1].LicenseFile) -Destination (Join-Path $noticeRoot $noticeRequirements[1].LicenseFile)
        Set-Content -LiteralPath (Join-Path $noticeRoot $noticeRequirements[2].LicenseFile) -Value "modified" -Encoding UTF8
        Assert-ThrowsMatch "modified packaged license rejected" {
            Assert-StatsProThirdPartyMaterials -Root $noticeRoot
        } "License text.*SHA256"

        Copy-Item -LiteralPath (Join-Path $sourceRoot $noticeRequirements[2].LicenseFile) -Destination (Join-Path $noticeRoot $noticeRequirements[2].LicenseFile) -Force
        Set-Content -LiteralPath (Join-Path $noticeRoot $noticeRequirements[1].Path) -Value "modified" -Encoding UTF8
        Assert-ThrowsMatch "modified packaged runtime rejected" {
            Assert-StatsProThirdPartyMaterials -Root $noticeRoot
        } "runtime library.*SHA256"

        Assert-ThrowsMatch "missing package file rejected" {
            Assert-StatsProPackageEntries -Entries @(
                "StatsPro/CHANGELOG.md",
                "StatsPro/LICENSE",
                "StatsPro/StatsPro.toc",
                "StatsPro/StatsPro.lua",
                "StatsPro/StatsPro_ArchonTargets.lua",
                "StatsPro/textures/logo.png",
                "StatsPro/libs/LibStub/LibStub.lua",
                "StatsPro/libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
                "StatsPro/libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua"
            )
        } "THIRD-PARTY-NOTICES"
        foreach ($licenseFile in @($noticeRequirements | Where-Object { -not [string]::IsNullOrWhiteSpace($_.LicenseFile) } | ForEach-Object { "StatsPro/$($_.LicenseFile)" })) {
            Assert-ThrowsMatch "missing packaged license entry rejected" {
                Assert-StatsProPackageEntries -Entries @((Get-StatsProPackageFileContract).RequiredFiles | Where-Object { $_ -ne $licenseFile })
            } ([regex]::Escape($licenseFile))
        }
        Assert-ThrowsMatch "unexpected lib file rejected" {
            Assert-StatsProPackageEntries -Entries ((Get-StatsProPackageFileContract).RequiredFiles + "StatsPro/libs/LibStub/tests/test.lua")
        } "unexpected packaged lib file"
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "Release artifact self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if ($WriteReleaseJson) {
    $WithReleaseJson = $true
}

Assert-StatsProReleaseArtifact `
    -ZipPath $ZipPath `
    -ReleaseJsonPath $ReleaseJsonPath `
    -ExpectedTag $ExpectedTag `
    -SourceRoot $SourceRoot `
    -ArchonMaxAgeDays $ArchonMaxAgeDays `
    -PackageOnly:$PackageOnly.IsPresent `
    -WithReleaseJson:$WithReleaseJson.IsPresent `
    -WriteReleaseJson:$WriteReleaseJson.IsPresent
