param(
    [string]$ArchivePath,
    [string]$ExpectedTag,
    [string]$PackagerProjectVersion,
    [string]$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")),
    [string]$PackageRoot = (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") ".release") "StatsPro"),
    [string]$ReleaseRoot = (Join-Path (Join-Path $PSScriptRoot "..") ".release"),
    [string]$ManifestPath,
    [string]$CompareManifestPath,
    [int]$ArchonMaxAgeDays = 3,
    [switch]$EnforceToolLocks,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

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

function Assert-PowerShell7OrNewer {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "check-package-dry-run.ps1 requires PowerShell 7+ (pwsh). Windows PowerShell 5.1 lacks APIs used by the package repeatability checks."
    }
}

function Assert-ReleaseTag {
    param([string]$Value)

    if ($Value -notmatch "^v\d+\.\d+\.\d+$") {
        throw "Malformed release tag '$Value'. Expected vX.Y.Z."
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

function Get-StatsProSourceVersionTag {
    param([string]$Root)

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $tocPath = Join-Path $resolvedRoot "StatsPro.toc"
    if (-not (Test-Path -LiteralPath $tocPath -PathType Leaf)) {
        throw "Missing StatsPro.toc in source root $resolvedRoot."
    }
    $tocText = Get-Content -LiteralPath $tocPath -Raw -Encoding UTF8
    $version = Get-SingleRegexMatchFromText -Text $tocText -Pattern "^##\s+Version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$" -Description "TOC Version"
    return "v$version"
}

function Resolve-StatsProExpectedTag {
    param([string]$Value, [string]$Root)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = Get-StatsProSourceVersionTag -Root $Root
    }
    Assert-ReleaseTag $Value
    return $Value
}

function Assert-StatsProPackagerProjectVersion {
    param([string]$Value)

    if ($Value -notmatch '^v\d+\.\d+\.\d+(?:-\d+-g[0-9a-fA-F]{7,40})?$') {
        throw "Malformed Packager project version '$Value'. Expected vX.Y.Z or vX.Y.Z-N-gHASH."
    }
}

function Resolve-StatsProPackagerProjectVersion {
    param([string]$Value, [string]$Root)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $output = @(& git -C $Root describe --tags --abbrev=7 '--exclude=*[Aa][Ll][Pp][Hh][Aa]*' 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Could not derive the pinned Packager project version from git: $($output -join ' ')"
        }
        $Value = ($output -join "`n").Trim()
    }
    Assert-StatsProPackagerProjectVersion $Value
    return $Value
}

function Resolve-StatsProArchivePath {
    param([string]$Value, [string]$Root)

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return (Resolve-Path -LiteralPath $Value).Path
    }

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Missing -ArchivePath and release root not found: $Root"
    }
    $candidates = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "StatsPro-*.zip" | Sort-Object FullName)
    if ($candidates.Count -ne 1) {
        throw "Missing -ArchivePath and expected exactly one StatsPro-*.zip in $Root; found $($candidates.Count)."
    }
    return $candidates[0].FullName
}

function Get-StatsProPackageManifestLines {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Package root not found: $Root"
    }
    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $filesByRelativePath = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File)) {
        $relative = [System.IO.Path]::GetRelativePath($resolvedRoot, $file.FullName) -replace "\\", "/"
        if ($filesByRelativePath.ContainsKey($relative)) {
            throw "Package root contains duplicate canonical path $relative."
        }
        $filesByRelativePath[$relative] = $file.FullName
    }
    $paths = [string[]]@($filesByRelativePath.Keys)
    [System.Array]::Sort($paths, [System.StringComparer]::Ordinal)
    $lines = @($paths | ForEach-Object {
        $hash = (Get-FileHash -LiteralPath $filesByRelativePath[$_] -Algorithm SHA256).Hash
        "$_`t$hash"
    })
    if ($lines.Count -eq 0) {
        throw "Package root contains no files: $resolvedRoot"
    }
    return $lines
}

function Assert-StatsProPackageManifestMatches {
    param([string]$Root, [string]$ExpectedManifestPath)

    if (-not (Test-Path -LiteralPath $ExpectedManifestPath -PathType Leaf)) {
        throw "Expected package manifest not found: $ExpectedManifestPath"
    }
    $expected = @(Get-Content -LiteralPath $ExpectedManifestPath)
    $actual = @(Get-StatsProPackageManifestLines -Root $Root)
    if ($expected.Count -ne $actual.Count) {
        throw "Package tree is not repeatable between dry-run builds: manifest line count is $($actual.Count), expected $($expected.Count)."
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if (-not [System.StringComparer]::Ordinal.Equals([string]$expected[$index], [string]$actual[$index])) {
            throw "Package tree is not repeatable between dry-run builds at manifest line $($index + 1): '$($actual[$index])', expected '$($expected[$index])'."
        }
    }
}

function Save-StatsProPackageManifest {
    param([string]$Root, [string]$Path)

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Get-StatsProPackageManifestLines -Root $Root |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-StatsProPackageArtifactCheck {
    param(
        [string]$ZipPath,
        [string]$ExpectedTag,
        [string]$ProjectVersion,
        [string]$Root,
        [int]$MaxAgeDays,
        [bool]$CheckToolLocks
    )

    $checker = Join-Path (Join-Path $Root "scripts") "check-release-artifact.ps1"
    if (-not (Test-Path -LiteralPath $checker -PathType Leaf)) {
        throw "Missing release artifact checker: $checker"
    }

    if ($CheckToolLocks) {
        & $checker `
            -ZipPath $ZipPath `
            -ExpectedTag $ExpectedTag `
            -PackagerProjectVersion $ProjectVersion `
            -SourceRoot $Root `
            -ArchonMaxAgeDays $MaxAgeDays `
            -PackageOnly `
            -EnforceToolLocks
    }
    else {
        & $checker `
            -ZipPath $ZipPath `
            -ExpectedTag $ExpectedTag `
            -PackagerProjectVersion $ProjectVersion `
            -SourceRoot $Root `
            -ArchonMaxAgeDays $MaxAgeDays `
            -PackageOnly
    }
}

function Invoke-SelfTest {
    $sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $tag = Get-StatsProSourceVersionTag -Root $sourceRoot
    if ($tag -notmatch "^v\d+\.\d+\.\d+$") {
        throw "Source version tag must be vX.Y.Z."
    }
    if ((Resolve-StatsProPackagerProjectVersion -Value "v1.2.3-4-gabcdef0" -Root $sourceRoot) -ne "v1.2.3-4-gabcdef0") {
        throw "Explicit Packager project version was not preserved."
    }
    Assert-ThrowsMatch "malformed Packager project version rejected" {
        [void](Resolve-StatsProPackagerProjectVersion -Value "1.2.3" -Root $sourceRoot)
    } "Malformed"

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-package-dry-run-test-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
        $packageRoot = Join-Path $tempDir "StatsPro"
        New-Item -ItemType Directory -Path (Join-Path $packageRoot "nested") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $packageRoot "a.txt") -Value "one" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $packageRoot "nested\b.txt") -Value "two" -Encoding UTF8

        $manifest = Join-Path $tempDir "manifest.tsv"
        Get-StatsProPackageManifestLines -Root $packageRoot |
            Set-Content -LiteralPath $manifest -Encoding UTF8
        Assert-StatsProPackageManifestMatches -Root $packageRoot -ExpectedManifestPath $manifest

        Set-Content -LiteralPath (Join-Path $packageRoot "nested\b.txt") -Value "changed" -Encoding UTF8
        Assert-ThrowsMatch "manifest mismatch rejected" {
            Assert-StatsProPackageManifestMatches -Root $packageRoot -ExpectedManifestPath $manifest
        } "not repeatable"

        $releaseRoot = Join-Path $tempDir "release"
        New-Item -ItemType Directory -Path $releaseRoot | Out-Null
        $singleZip = Join-Path $releaseRoot "StatsPro-v1.2.3-4-gabcdef0.zip"
        Set-Content -LiteralPath $singleZip -Value "zip" -Encoding UTF8
        if ((Resolve-StatsProArchivePath -Value "" -Root $releaseRoot) -ne $singleZip) {
            throw "Archive fallback must return the only StatsPro zip."
        }
        Assert-ThrowsMatch "missing archive fallback rejected" {
            Resolve-StatsProArchivePath -Value "" -Root (Join-Path $tempDir "missing-release")
        } "release root not found"
        Set-Content -LiteralPath (Join-Path $releaseRoot "StatsPro-v1.2.3-5-gabcdef1.zip") -Value "zip" -Encoding UTF8
        Assert-ThrowsMatch "ambiguous archive fallback rejected" {
            Resolve-StatsProArchivePath -Value "" -Root $releaseRoot
        } "exactly one"
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "Package dry-run self-test passed."
}

if ($SelfTest) {
    Assert-PowerShell7OrNewer
    Invoke-SelfTest
    return
}

Assert-PowerShell7OrNewer

$resolvedSourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$resolvedArchivePath = Resolve-StatsProArchivePath -Value $ArchivePath -Root $ReleaseRoot
$resolvedTag = Resolve-StatsProExpectedTag -Value $ExpectedTag -Root $resolvedSourceRoot
$resolvedPackagerProjectVersion = Resolve-StatsProPackagerProjectVersion -Value $PackagerProjectVersion -Root $resolvedSourceRoot

Invoke-StatsProPackageArtifactCheck `
    -ZipPath $resolvedArchivePath `
    -ExpectedTag $resolvedTag `
    -ProjectVersion $resolvedPackagerProjectVersion `
    -Root $resolvedSourceRoot `
    -MaxAgeDays $ArchonMaxAgeDays `
    -CheckToolLocks:$EnforceToolLocks.IsPresent

if (-not [string]::IsNullOrWhiteSpace($ManifestPath) -or -not [string]::IsNullOrWhiteSpace($CompareManifestPath)) {
    $resolvedPackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
    if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
        Save-StatsProPackageManifest -Root $resolvedPackageRoot -Path $ManifestPath
        Write-Host "StatsPro package manifest saved to $ManifestPath."
    }
    if (-not [string]::IsNullOrWhiteSpace($CompareManifestPath)) {
        Assert-StatsProPackageManifestMatches -Root $resolvedPackageRoot -ExpectedManifestPath $CompareManifestPath
        Write-Host "StatsPro package manifest matches $CompareManifestPath."
    }
}
