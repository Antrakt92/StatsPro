param(
    [string]$ArchivePath,
    [string]$ExpectedTag,
    [string]$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")),
    [string]$PackageRoot = (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") ".release") "StatsPro"),
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

function Get-StatsProPackageManifestLines {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Package root not found: $Root"
    }
    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $lines = @(
        Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File |
            Sort-Object FullName |
            ForEach-Object {
                $relative = [System.IO.Path]::GetRelativePath($resolvedRoot, $_.FullName) -replace "\\", "/"
                $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                "$relative`t$hash"
            }
    )
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
    $diff = Compare-Object -ReferenceObject $expected -DifferenceObject $actual
    if ($diff) {
        $text = ($diff | Format-Table -AutoSize | Out-String).Trim()
        throw "Package tree is not repeatable between dry-run builds.`n$text"
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
        [string]$Root,
        [int]$MaxAgeDays,
        [bool]$CheckToolLocks
    )

    $checker = Join-Path $Root "scripts\check-release-artifact.ps1"
    if (-not (Test-Path -LiteralPath $checker -PathType Leaf)) {
        throw "Missing release artifact checker: $checker"
    }

    $args = @(
        "-ZipPath", $ZipPath,
        "-ExpectedTag", $ExpectedTag,
        "-SourceRoot", $Root,
        "-ArchonMaxAgeDays", [string]$MaxAgeDays,
        "-PackageOnly"
    )
    if ($CheckToolLocks) {
        $args += "-EnforceToolLocks"
    }
    & $checker @args
}

function Invoke-SelfTest {
    $sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $tag = Get-StatsProSourceVersionTag -Root $sourceRoot
    if ($tag -notmatch "^v\d+\.\d+\.\d+$") {
        throw "Source version tag must be vX.Y.Z."
    }

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

if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    throw "Missing -ArchivePath."
}

$resolvedSourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$resolvedArchivePath = (Resolve-Path -LiteralPath $ArchivePath).Path
$resolvedTag = Resolve-StatsProExpectedTag -Value $ExpectedTag -Root $resolvedSourceRoot

Invoke-StatsProPackageArtifactCheck `
    -ZipPath $resolvedArchivePath `
    -ExpectedTag $resolvedTag `
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
