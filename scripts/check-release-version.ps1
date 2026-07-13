param(
    [string]$Tag = $env:GITHUB_REF_NAME,
    [switch]$EnforceSemVer,
    [switch]$EnforceSemVerWhenAhead,
    [switch]$AllowSemVerMismatch,
    [switch]$SelfTest,
    [string]$ExportTopChangelogPath,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot ".."))
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "release-tag-contract.ps1")

function Get-SingleRegexMatch {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Description
    )

    $Text = Get-Content -Path $Path -Raw -Encoding UTF8
    $Matches = [regex]::Matches($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($Matches.Count -eq 0) {
        throw "Missing $Description in $Path"
    }
    if ($Matches.Count -gt 1) {
        throw "Found multiple $Description values in $Path"
    }
    return $Matches[0].Groups[1].Value
}

function Invoke-Git {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& git @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') failed with code ${exitCode}: $($output -join ' ')"
    }
    return @{
        ExitCode = $exitCode
        Output = $output
    }
}

function Normalize-ReleaseTagName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Missing release tag. Pass -Tag vX.Y.Z or set GITHUB_REF_NAME."
    }
    return ConvertTo-StatsProReleaseTagName -Value $Value -AllowFullRef -AllowBareVersion
}

function Get-ReleaseVersionFromTag {
    param([string]$TagName)

    return (ConvertTo-StatsProReleaseTagParts -Value $TagName).Version
}

function ConvertTo-SemVerParts {
    param([string]$Version)

    $parts = ConvertTo-StatsProReleaseVersionParts -Value $Version
    return @{
        Major = $parts.Major
        Minor = $parts.Minor
        Patch = $parts.Patch
    }
}

function Compare-SemVer {
    param(
        [string]$Left,
        [string]$Right
    )

    $leftParts = ConvertTo-SemVerParts $Left
    $rightParts = ConvertTo-SemVerParts $Right
    foreach ($field in @("Major", "Minor", "Patch")) {
        if ($leftParts[$field] -lt $rightParts[$field]) { return -1 }
        if ($leftParts[$field] -gt $rightParts[$field]) { return 1 }
    }
    return 0
}

function Get-NextSemVer {
    param(
        [string]$PreviousVersion,
        [ValidateSet("major", "minor", "patch")]
        [string]$Bump
    )

    $parts = ConvertTo-SemVerParts $PreviousVersion
    if ($Bump -eq "major") {
        if ($parts.Major -eq [int]::MaxValue) {
            throw "Cannot apply major bump to $PreviousVersion because the major component is already at the supported maximum."
        }
        return "$($parts.Major + 1).0.0"
    }
    if ($Bump -eq "minor") {
        if ($parts.Minor -eq [int]::MaxValue) {
            throw "Cannot apply minor bump to $PreviousVersion because the minor component is already at the supported maximum."
        }
        return "$($parts.Major).$($parts.Minor + 1).0"
    }
    if ($parts.Patch -eq [int]::MaxValue) {
        throw "Cannot apply patch bump to $PreviousVersion because the patch component is already at the supported maximum."
    }
    return "$($parts.Major).$($parts.Minor).$($parts.Patch + 1)"
}

function Get-CommitBump {
    param([string[]]$CommitRecords)

    $hasMinor = $false
    $unknownSubjects = @()
    foreach ($record in $CommitRecords) {
        if ([string]::IsNullOrWhiteSpace($record)) {
            continue
        }
        $parts = $record -split "`n", 2
        $subject = $parts[0].Trim()
        $body = if ($parts.Count -gt 1) { $parts[1] } else { "" }
        if ($subject -match "^[a-z]+(?:\([^)]+\))?!:" -or $body -match "(?m)^BREAKING(?: |-)?CHANGE:") {
            return "major"
        }
        if ($subject -match "^feat(?:\([^)]+\))?:") {
            $hasMinor = $true
            continue
        }
        if ($subject -match "^(fix|perf|refactor|chore|ci|docs|style|test|revert)(?:\([^)]+\))?:") {
            continue
        }
        $unknownSubjects += $subject
    }
    if ($unknownSubjects.Count -gt 0) {
        throw (
            "Cannot derive SemVer bump from non-conventional commit subject(s): " +
            ($unknownSubjects -join "; ") +
            ". Use feat/fix/perf/refactor/chore/ci/docs/style/test/revert or an explicit breaking marker."
        )
    }
    if ($hasMinor) {
        return "minor"
    }
    return "patch"
}

function Assert-AllReleaseTagsCanonical {
    $result = Invoke-Git -Arguments @("tag", "--list", "v*")
    foreach ($tag in $result.Output) {
        $name = $tag.Trim()
        if (-not (Test-StatsProReleaseTag -Value $name)) {
            throw "Repository tag '$name' is not a canonical StatsPro release tag."
        }
    }
}

function Get-PreviousReleaseTag {
    param([string]$CurrentTagName)

    Assert-AllReleaseTagsCanonical
    $result = Invoke-Git -Arguments @(
        "tag",
        "--merged",
        "HEAD",
        "--list",
        "v*",
        "--sort=-v:refname"
    )
    $names = @()
    foreach ($tag in $result.Output) {
        $name = $tag.Trim()
        if (-not (Test-StatsProReleaseTag -Value $name)) {
            throw "Reachable tag '$name' is not a canonical StatsPro release tag."
        }
        $names += $name
    }
    foreach ($name in $names) {
        if ($name -cne $CurrentTagName) {
            return $name
        }
    }
    return $null
}

function Get-LatestReachableReleaseTag {
    Assert-AllReleaseTagsCanonical
    $result = Invoke-Git -Arguments @(
        "tag",
        "--merged",
        "HEAD",
        "--list",
        "v*",
        "--sort=-v:refname"
    )
    $names = @()
    foreach ($tag in $result.Output) {
        $name = $tag.Trim()
        if (-not (Test-StatsProReleaseTag -Value $name)) {
            throw "Reachable tag '$name' is not a canonical StatsPro release tag."
        }
        $names += $name
    }
    if ($names.Count -gt 0) {
        return $names[0]
    }
    return $null
}

function Get-CommitRecordsSinceTag {
    param([string]$PreviousTag)

    $separator = [string][char]0x1e
    $result = Invoke-Git -Arguments @(
        "log",
        "--no-merges",
        "--format=%s%n%b%x1e",
        "$PreviousTag..HEAD"
    )
    $raw = $result.Output -join "`n"
    return @(
        $raw -split [regex]::Escape($separator) |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
}

function Assert-SemVerMatchesCommits {
    param(
        [string]$CurrentTagName,
        [string]$RequestedVersion,
        [bool]$PermitMismatch
    )

    $previousTag = Get-PreviousReleaseTag -CurrentTagName $CurrentTagName
    if (-not $previousTag) {
        Write-Warning "Skipping SemVer-from-commits check: no previous vX.Y.Z tag is reachable from HEAD."
        return
    }

    $commitRecords = Get-CommitRecordsSinceTag -PreviousTag $previousTag
    if ($commitRecords.Count -eq 0) {
        Write-Warning "Skipping SemVer-from-commits check: no commits found after $previousTag."
        return
    }

    $previousVersion = Get-ReleaseVersionFromTag $previousTag
    $requiredBump = Get-CommitBump -CommitRecords $commitRecords
    $expectedVersion = Get-NextSemVer -PreviousVersion $previousVersion -Bump $requiredBump
    if ($RequestedVersion -eq $expectedVersion) {
        Write-Host "SemVer check passed: $previousTag + $requiredBump commits -> $RequestedVersion"
        return
    }

    $message = (
        "Release tag $CurrentTagName requests $RequestedVersion, but commits since " +
        "$previousTag require $requiredBump bump $expectedVersion."
    )
    if ($PermitMismatch) {
        Write-Warning "$message Proceeding only because -AllowSemVerMismatch is set."
        return
    }
    throw "$message Pass -AllowSemVerMismatch only for an intentional exceptional release."
}

function Assert-SemVerWhenAhead {
    param(
        [string]$CurrentTagName,
        [string]$RequestedVersion,
        [bool]$PermitMismatch
    )

    $latestTag = Get-LatestReachableReleaseTag
    if (-not $latestTag) {
        Write-Warning "Skipping prepared-release SemVer check: no vX.Y.Z tag is reachable from HEAD."
        return
    }

    $latestVersion = Get-ReleaseVersionFromTag $latestTag
    $comparison = Compare-SemVer -Left $RequestedVersion -Right $latestVersion
    if ($comparison -lt 0) {
        throw "Release tag $CurrentTagName requests $RequestedVersion, older than latest reachable release tag $latestTag."
    }
    if ($comparison -eq 0) {
        Write-Host "Prepared-release SemVer check skipped: $RequestedVersion equals latest reachable release tag $latestTag."
        return
    }

    Assert-SemVerMatchesCommits `
        -CurrentTagName $CurrentTagName `
        -RequestedVersion $RequestedVersion `
        -PermitMismatch:$PermitMismatch
}

function Get-FirstRegexMatch {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Description
    )

    $Text = Get-Content -Path $Path -Raw -Encoding UTF8
    $Match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $Match.Success) {
        throw "Missing $Description in $Path"
    }
    return $Match.Groups[1].Value
}

function Get-FirstRegexObject {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Description
    )

    $Text = Get-Content -Path $Path -Raw -Encoding UTF8
    $Match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $Match.Success) {
        throw "Missing or malformed $Description in $Path"
    }
    return $Match
}

function Get-ChangelogHeadingPattern {
    $HeadingDash = [regex]::Escape([string][char]0x2014)
    return "^##\s+([0-9]+\.[0-9]+\.[0-9]+)\s+-\s+([0-9]{2}-(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)-[0-9]{4})\s+$HeadingDash\s+\S.*$"
}

function Get-TopChangelogEntry {
    param([string]$Path)

    $text = Get-Content -Path $Path -Raw -Encoding UTF8
    $headingMatches = [regex]::Matches(
        $text,
        (Get-ChangelogHeadingPattern),
        [System.Text.RegularExpressions.RegexOptions]::Multiline
    )
    if ($headingMatches.Count -eq 0) {
        throw "Missing top changelog heading in $Path"
    }

    $firstHeading = $headingMatches[0]
    $endIndex = if ($headingMatches.Count -gt 1) { $headingMatches[1].Index } else { $text.Length }
    $prefix = $text.Substring(0, $firstHeading.Index).TrimEnd()
    $entry = $text.Substring($firstHeading.Index, $endIndex - $firstHeading.Index).TrimEnd()
    if (-not [string]::IsNullOrWhiteSpace($prefix)) {
        return "$prefix`n`n$entry`n"
    }
    return "$entry`n"
}

function Export-TopChangelogEntry {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
        return
    }
    $entry = Get-TopChangelogEntry -Path $SourcePath
    $destinationFullPath = [System.IO.Path]::GetFullPath($DestinationPath)
    [System.IO.File]::WriteAllText($destinationFullPath, $entry, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Exported top changelog entry to $destinationFullPath"
}

function Assert-ReleaseVersion {
    param(
        [string]$TagValue,
        [bool]$ShouldEnforceSemVer,
        [bool]$ShouldEnforceSemVerWhenAhead,
        [bool]$PermitSemVerMismatch,
        [string]$ExportTopChangelogPath
    )

    $TagName = Normalize-ReleaseTagName $TagValue
    $TagVersion = Get-ReleaseVersionFromTag $TagName

    $TocVersion = Get-SingleRegexMatch `
        -Path "StatsPro.toc" `
        -Pattern "^##\s+Version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$" `
        -Description "TOC Version"

    $CurrentRelease = Get-SingleRegexMatch `
        -Path "StatsPro.lua" `
        -Pattern '^\s*local\s+CURRENT_RELEASE\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"\s*$' `
        -Description "CURRENT_RELEASE"

    $HeadingPattern = Get-ChangelogHeadingPattern
    $ChangelogHeading = Get-FirstRegexObject `
        -Path "CHANGELOG.md" `
        -Pattern $HeadingPattern `
        -Description "top changelog heading (`## X.Y.Z - DD-MMM-YYYY [em dash] Title`)"

    $ChangelogVersion = $ChangelogHeading.Groups[1].Value
    $ChangelogDate = $ChangelogHeading.Groups[2].Value
    [void][datetime]::ParseExact(
        $ChangelogDate,
        "dd-MMM-yyyy",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None
    )

    $Errors = @()
    if ($TocVersion -ne $TagVersion) {
        $Errors += "StatsPro.toc ## Version is $TocVersion, expected $TagVersion from tag $TagName."
    }
    if ($CurrentRelease -ne $TagVersion) {
        $Errors += "StatsPro.lua CURRENT_RELEASE is $CurrentRelease, expected $TagVersion from tag $TagName."
    }
    if ($ChangelogVersion -ne $TagVersion) {
        $Errors += "CHANGELOG.md top entry is $ChangelogVersion, expected $TagVersion from tag $TagName."
    }

    if ($Errors.Count -gt 0) {
        throw ($Errors -join "`n")
    }

    if ($ShouldEnforceSemVer) {
        Assert-SemVerMatchesCommits `
            -CurrentTagName $TagName `
            -RequestedVersion $TagVersion `
            -PermitMismatch:$PermitSemVerMismatch
    }
    elseif ($ShouldEnforceSemVerWhenAhead) {
        Assert-SemVerWhenAhead `
            -CurrentTagName $TagName `
            -RequestedVersion $TagVersion `
            -PermitMismatch:$PermitSemVerMismatch
    }

    Export-TopChangelogEntry -SourcePath "CHANGELOG.md" -DestinationPath $ExportTopChangelogPath

    Write-Host "Release version check passed: $TagName -> $TagVersion"
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

function Invoke-SelfTest {
    Assert-StatsProReleaseTagContractSelfTest
    if ((Normalize-ReleaseTagName -Value "refs/tags/v1.2.3") -cne "v1.2.3" -or
        (Normalize-ReleaseTagName -Value "1.2.3") -cne "v1.2.3") {
        throw "Release version tag adapters did not preserve canonical inputs."
    }
    foreach ($invalidTag in @("v01.2.3", "V1.2.3", ("v1.2.3" + [char]10))) {
        Assert-ThrowsMatch "release version rejects noncanonical tag '$invalidTag'" {
            [void](Normalize-ReleaseTagName -Value $invalidTag)
        } "Malformed StatsPro release tag"
    }
    Assert-ThrowsMatch "major bump overflow rejected" {
        [void](Get-NextSemVer -PreviousVersion "2147483647.0.0" -Bump major)
    } "major component.*maximum"
    Assert-ThrowsMatch "minor bump overflow rejected" {
        [void](Get-NextSemVer -PreviousVersion "1.2147483647.0" -Bump minor)
    } "minor component.*maximum"
    Assert-ThrowsMatch "patch bump overflow rejected" {
        [void](Get-NextSemVer -PreviousVersion "1.2.2147483647" -Bump patch)
    } "patch component.*maximum"

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-version-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    Push-Location $root
    try {
        [void](Invoke-Git -Arguments @("init"))
        [void](Invoke-Git -Arguments @("config", "user.email", "statspro-tests@example.invalid"))
        [void](Invoke-Git -Arguments @("config", "user.name", "StatsPro Tests"))

        Set-Content -Path "StatsPro.toc" -Value "## Version: 1.0.0" -Encoding UTF8
        Set-Content -Path "StatsPro.lua" -Value 'local CURRENT_RELEASE = "1.0.0"' -Encoding UTF8
        Set-Content -Path "CHANGELOG.md" -Value "# Changelog`n`n## 1.0.0 - 01-Jan-2026 $([char]0x2014) Initial`n" -Encoding UTF8
        [void](Invoke-Git -Arguments @("add", "."))
        [void](Invoke-Git -Arguments @("commit", "-m", "chore: initial release"))
        [void](Invoke-Git -Arguments @("tag", "v1.0.0"))

        Set-Content -Path "StatsPro.toc" -Value "## Version: 1.0.1" -Encoding UTF8
        Set-Content -Path "StatsPro.lua" -Value 'local CURRENT_RELEASE = "1.0.1"' -Encoding UTF8
        Set-Content -Path "CHANGELOG.md" -Value "# Changelog`n`n## 1.0.1 - 02-Jan-2026 $([char]0x2014) Fix`n`n### Fixed`n`n- Release gate regression.`n`n## 1.0.0 - 01-Jan-2026 $([char]0x2014) Initial`n" -Encoding UTF8
        [void](Invoke-Git -Arguments @("add", "."))
        [void](Invoke-Git -Arguments @("commit", "-m", "fix: repair release gate"))
        $fixtureTree = (Invoke-Git -Arguments @("write-tree")).Output[0]
        $unreachableCommit = (Invoke-Git -Arguments @("commit-tree", $fixtureTree, "-m", "unreachable invalid-tag fixture")).Output[0]
        [void](Invoke-Git -Arguments @("tag", "v01.0.0", $unreachableCommit))
        Assert-ThrowsMatch "previous release discovery rejects noncanonical unreachable tag" {
            [void](Get-PreviousReleaseTag -CurrentTagName "v1.0.1")
        } "not a canonical StatsPro release tag"
        Assert-ThrowsMatch "latest release discovery rejects noncanonical unreachable tag" {
            [void](Get-LatestReachableReleaseTag)
        } "not a canonical StatsPro release tag"
        [void](Invoke-Git -Arguments @("tag", "-d", "v01.0.0"))
        $topChangelogPath = Join-Path $root "TOP-CHANGELOG.md"
        Assert-ReleaseVersion -TagValue "v1.0.1" -ShouldEnforceSemVer:$false -ShouldEnforceSemVerWhenAhead:$true -PermitSemVerMismatch:$false -ExportTopChangelogPath $topChangelogPath
        $topChangelog = Get-Content -Path $topChangelogPath -Raw -Encoding UTF8
        if (-not $topChangelog.StartsWith("# Changelog`n`n## 1.0.1 - 02-Jan-2026 $([char]0x2014) Fix")) {
            throw "exported top changelog must preserve the H1 and current release heading, got: $topChangelog"
        }
        $topHeadingPattern = "(?m)^##\s+$((Get-StatsProReleaseTagContract).VersionPattern)\s+-\s+"
        if ([regex]::Matches($topChangelog, $topHeadingPattern).Count -ne 1) {
            throw "exported top changelog must contain exactly one version heading, got: $topChangelog"
        }
        Assert-ReleaseVersion -TagValue "v1.0.1" -ShouldEnforceSemVer:$true -PermitSemVerMismatch:$false

        Set-Content -Path "StatsPro.toc" -Value "## Version: 1.1.0" -Encoding UTF8
        Set-Content -Path "StatsPro.lua" -Value 'local CURRENT_RELEASE = "1.1.0"' -Encoding UTF8
        Set-Content -Path "CHANGELOG.md" -Value "# Changelog`n`n## 1.1.0 - 03-Jan-2026 $([char]0x2014) Feature`n" -Encoding UTF8
        Assert-ThrowsMatch "patch commit cannot release minor without override" {
            Assert-ReleaseVersion -TagValue "v1.1.0" -ShouldEnforceSemVer:$true -PermitSemVerMismatch:$false
        } "require patch bump 1\.0\.1"
        Assert-ThrowsMatch "when-ahead rejects wrong prepared minor bump" {
            Assert-ReleaseVersion -TagValue "v1.1.0" -ShouldEnforceSemVer:$false -ShouldEnforceSemVerWhenAhead:$true -PermitSemVerMismatch:$false
        } "require patch bump 1\.0\.1"
        Assert-ReleaseVersion -TagValue "v1.1.0" -ShouldEnforceSemVer:$true -PermitSemVerMismatch:$true

        [void](Invoke-Git -Arguments @("commit", "-am", "feat: add target panel"))
        Assert-ReleaseVersion -TagValue "refs/tags/v1.1.0" -ShouldEnforceSemVer:$true -PermitSemVerMismatch:$false
        [void](Invoke-Git -Arguments @("tag", "v1.1.0"))

        Set-Content -Path "notes.txt" -Value "unreleased follow-up" -Encoding UTF8
        [void](Invoke-Git -Arguments @("add", "notes.txt"))
        [void](Invoke-Git -Arguments @("commit", "-m", "fix: unreleased follow-up"))
        Assert-ReleaseVersion -TagValue "v1.1.0" -ShouldEnforceSemVer:$false -ShouldEnforceSemVerWhenAhead:$true -PermitSemVerMismatch:$false

        Set-Content -Path "StatsPro.toc" -Value "## Version: 1.0.9" -Encoding UTF8
        Set-Content -Path "StatsPro.lua" -Value 'local CURRENT_RELEASE = "1.0.9"' -Encoding UTF8
        Set-Content -Path "CHANGELOG.md" -Value "# Changelog`n`n## 1.0.9 - 04-Jan-2026 $([char]0x2014) Regression`n" -Encoding UTF8
        Assert-ThrowsMatch "when-ahead rejects version behind latest tag" {
            Assert-ReleaseVersion -TagValue "v1.0.9" -ShouldEnforceSemVer:$false -ShouldEnforceSemVerWhenAhead:$true -PermitSemVerMismatch:$false
        } "older than latest reachable release tag v1\.1\.0"

        Set-Content -Path "StatsPro.toc" -Value "## Version: 2.0.0" -Encoding UTF8
        Set-Content -Path "StatsPro.lua" -Value 'local CURRENT_RELEASE = "2.0.0"' -Encoding UTF8
        Set-Content -Path "CHANGELOG.md" -Value "# Changelog`n`n## 2.0.0 - 05-Jan-2026 $([char]0x2014) Breaking`n" -Encoding UTF8
        [void](Invoke-Git -Arguments @("add", "."))
        [void](Invoke-Git -Arguments @("commit", "-m", "fix!: change saved variables contract"))
        Assert-ReleaseVersion -TagValue "v2.0.0" -ShouldEnforceSemVer:$true -PermitSemVerMismatch:$false

        Assert-ThrowsMatch "unknown conventional prefix rejected" {
            Get-CommitBump -CommitRecords @("misc: unclear release impact")
        } "Cannot derive SemVer"
        $ciBump = Get-CommitBump -CommitRecords @("ci: update workflow action")
        if ($ciBump -ne "patch") {
            throw "ci prefix should require patch bump, got $ciBump."
        }
        $revertBump = Get-CommitBump -CommitRecords @("revert(config): remove a feature safely")
        if ($revertBump -ne "patch") {
            throw "revert prefix should require patch bump, got $revertBump."
        }
    }
    finally {
        Pop-Location
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
    Write-Host "Release version self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

$RepoRoot = (Resolve-Path $RepoRoot).Path
Push-Location $RepoRoot
try {
    Assert-ReleaseVersion `
        -TagValue $Tag `
        -ShouldEnforceSemVer:$EnforceSemVer.IsPresent `
        -ShouldEnforceSemVerWhenAhead:$EnforceSemVerWhenAhead.IsPresent `
        -PermitSemVerMismatch:$AllowSemVerMismatch.IsPresent `
        -ExportTopChangelogPath $ExportTopChangelogPath
}
finally {
    Pop-Location
}
