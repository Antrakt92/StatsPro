param(
    [string]$ReleaseRoot = (Join-Path (Join-Path $PSScriptRoot "..") ".release"),
    [string]$ExpectedTag,
    [string]$OutputPath = $env:GITHUB_OUTPUT,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "release-tag-contract.ps1")

function Assert-ThrowsMatch {
    param([string]$Name, [scriptblock]$Script, [string]$Pattern)

    $completed = $false
    try {
        & $Script
        $completed = $true
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Name failed with wrong error: $($_.Exception.Message)"
        }
    }
    if ($completed) {
        throw "$Name should have failed."
    }
}

function Assert-ReleaseTag {
    param([string]$Value)

    Assert-StatsProReleaseTag -Value $Value
}

function Resolve-StatsProPackagerOutput {
    param([string]$Root, [string]$Tag)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Packager release root not found: $Root"
    }
    if (-not [string]::IsNullOrWhiteSpace($Tag)) {
        Assert-ReleaseTag $Tag
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $packageRoot = Join-Path $resolvedRoot "StatsPro"
    if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
        throw "Packager package tree not found: $packageRoot"
    }

    $archives = @(Get-ChildItem -LiteralPath $resolvedRoot -File -Filter "StatsPro-*.zip" | Sort-Object Name)
    if ($archives.Count -ne 1) {
        throw "Expected exactly one top-level StatsPro-*.zip in $resolvedRoot; found $($archives.Count)."
    }

    $archive = $archives[0]
    $archivePrefix = 'StatsPro-'
    if (-not $archive.BaseName.StartsWith($archivePrefix, [System.StringComparison]::Ordinal)) {
        throw "Malformed Packager archive name '$($archive.Name)'."
    }
    $projectVersion = $archive.BaseName.Substring($archivePrefix.Length)
    Assert-StatsProPackagerProjectVersion -Value $projectVersion

    if (-not [string]::IsNullOrWhiteSpace($Tag)) {
        $expectedName = "StatsPro-$Tag.zip"
        if (-not [System.StringComparer]::Ordinal.Equals($archive.Name, $expectedName) -or
            -not [System.StringComparer]::Ordinal.Equals($projectVersion, $Tag)) {
            throw "Packager archive '$($archive.Name)' does not exactly match release tag '$Tag'."
        }
    }

    if ($archive.FullName -match '[\r\n]' -or $projectVersion -match '[\r\n]') {
        throw "Packager output contains a newline and cannot be exported safely."
    }

    return [pscustomobject]@{
        ArchivePath = $archive.FullName
        ProjectVersion = $projectVersion
    }
}

function Export-StatsProPackagerOutput {
    param([pscustomobject]$Output, [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Missing GitHub output path. Pass -OutputPath or run inside GitHub Actions."
    }
    @(
        "archive_path=$($Output.ArchivePath)"
        "project_version=$($Output.ProjectVersion)"
    ) | Out-File -LiteralPath $Path -Encoding utf8 -Append
}

function Invoke-SelfTest {
    Assert-StatsProReleaseTagContractSelfTest
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-packager-output-test-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path (Join-Path $tempRoot "StatsPro") -Force | Out-Null
    try {
        $archivePath = Join-Path $tempRoot "StatsPro-v1.2.3.zip"
        Set-Content -LiteralPath $archivePath -Value "fixture" -Encoding UTF8

        $release = Resolve-StatsProPackagerOutput -Root $tempRoot -Tag "v1.2.3"
        if ($release.ProjectVersion -ne "v1.2.3" -or $release.ArchivePath -ne (Resolve-Path -LiteralPath $archivePath).Path) {
            throw "Exact release output was not resolved correctly."
        }

        $outputPath = Join-Path $tempRoot "github-output.txt"
        Export-StatsProPackagerOutput -Output $release -Path $outputPath
        $outputLines = @(Get-Content -LiteralPath $outputPath -Encoding UTF8)
        if ($outputLines.Count -ne 2 -or
            $outputLines[0] -ne "archive_path=$($release.ArchivePath)" -or
            $outputLines[1] -ne "project_version=v1.2.3") {
            throw "GitHub output export was not exact."
        }

        Rename-Item -LiteralPath $archivePath -NewName "StatsPro-v1.2.3-4-gabcdef0.zip"
        $branchPath = Join-Path $tempRoot "StatsPro-v1.2.3-4-gabcdef0.zip"
        $branch = Resolve-StatsProPackagerOutput -Root $tempRoot -Tag ""
        if ($branch.ProjectVersion -ne "v1.2.3-4-gabcdef0") {
            throw "Branch Packager output was not resolved correctly."
        }
        Assert-ThrowsMatch "branch archive rejected for exact release" {
            [void](Resolve-StatsProPackagerOutput -Root $tempRoot -Tag "v1.2.3")
        } "does not exactly match"
        Assert-ThrowsMatch "malformed expected tag rejected" {
            [void](Resolve-StatsProPackagerOutput -Root $tempRoot -Tag "1.2.3")
        } "Malformed StatsPro release tag"
        Assert-ThrowsMatch "leading-zero expected tag rejected" {
            [void](Resolve-StatsProPackagerOutput -Root $tempRoot -Tag "v01.2.3")
        } "Malformed StatsPro release tag"

        Remove-Item -LiteralPath $branchPath -Force
        $malformedBranchPath = Join-Path $tempRoot "StatsPro-v01.2.3-4-gabcdef0.zip"
        Set-Content -LiteralPath $malformedBranchPath -Value "fixture" -Encoding UTF8
        Assert-ThrowsMatch "leading-zero Packager archive rejected" {
            [void](Resolve-StatsProPackagerOutput -Root $tempRoot -Tag "")
        } "Malformed StatsPro Packager project version"
        Remove-Item -LiteralPath $malformedBranchPath -Force
        Set-Content -LiteralPath $branchPath -Value "fixture" -Encoding UTF8
        Assert-ThrowsMatch "blank GitHub output path rejected" {
            Export-StatsProPackagerOutput -Output $branch -Path " "
        } "Missing GitHub output path"

        Set-Content -LiteralPath (Join-Path $tempRoot "StatsPro-v1.2.4.zip") -Value "fixture" -Encoding UTF8
        Assert-ThrowsMatch "multiple archives rejected" {
            [void](Resolve-StatsProPackagerOutput -Root $tempRoot -Tag "")
        } "exactly one"
        Remove-Item -LiteralPath (Join-Path $tempRoot "StatsPro-v1.2.4.zip")

        Remove-Item -LiteralPath (Join-Path $tempRoot "StatsPro-v1.2.3-4-gabcdef0.zip")
        Assert-ThrowsMatch "missing archive rejected" {
            [void](Resolve-StatsProPackagerOutput -Root $tempRoot -Tag "")
        } "exactly one"
        New-Item -ItemType Directory -Path (Join-Path $tempRoot "StatsPro-v1.2.3.zip") | Out-Null
        Assert-ThrowsMatch "archive directory rejected" {
            [void](Resolve-StatsProPackagerOutput -Root $tempRoot -Tag "v1.2.3")
        } "exactly one"
        Remove-Item -LiteralPath (Join-Path $tempRoot "StatsPro-v1.2.3.zip")

        Remove-Item -LiteralPath (Join-Path $tempRoot "StatsPro") -Recurse
        Assert-ThrowsMatch "missing package tree rejected" {
            [void](Resolve-StatsProPackagerOutput -Root $tempRoot -Tag "")
        } "package tree not found"
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }

    Write-Host "Packager output resolver self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

$resolvedOutput = Resolve-StatsProPackagerOutput -Root $ReleaseRoot -Tag $ExpectedTag
Export-StatsProPackagerOutput -Output $resolvedOutput -Path $OutputPath
Write-Host "Resolved Packager output $($resolvedOutput.ProjectVersion): $($resolvedOutput.ArchivePath)"
