param(
    [string]$Tag = $env:GITHUB_REF_NAME,
    [switch]$EnforceSemVer,
    [switch]$EnforceSemVerWhenAhead,
    [switch]$AllowSemVerMismatch,
    [switch]$SelfTest,
    [string]$ExportTopChangelogPath,
    [switch]$VerifyPublishedChangelog,
    [string]$Repository = $env:GITHUB_REPOSITORY,
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

function ConvertFrom-GhSlurpReleasePages {
    param([string]$Json)

    try {
        $parsed = ConvertFrom-Json $Json
    }
    catch {
        throw "GitHub release inventory contained invalid JSON."
    }

    $items = @()
    foreach ($page in @($parsed)) {
        if ($null -eq $page) {
            throw "GitHub release inventory contains a null page."
        }
        if ($null -ne $page.PSObject.Properties["tag_name"]) {
            $items += $page
            continue
        }
        if ($page -isnot [System.Array]) {
            throw "GitHub release inventory contains a malformed page."
        }
        $items += @($page)
    }
    return @($items)
}

function Get-GitHubReleaseInventory {
    param([string]$RepositoryName)

    if ([string]::IsNullOrWhiteSpace($RepositoryName) -or $RepositoryName -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw "Published changelog verification requires a canonical owner/repository name."
    }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "Published changelog verification requires GitHub CLI (gh)."
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& gh api --paginate --slurp `
            -H "Accept: application/vnd.github+json" `
            -H "X-GitHub-Api-Version: 2026-03-10" `
            "repos/$RepositoryName/releases?per_page=100" 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "Could not fetch the paginated GitHub release inventory for $RepositoryName (gh exit $exitCode)."
    }
    return @(ConvertFrom-GhSlurpReleasePages -Json ($output -join "`n"))
}

function ConvertTo-PublishedReleaseDate {
    param(
        $Value,
        [string]$TagName
    )

    $publishedAt = [DateTimeOffset]::MinValue
    if ($Value -is [DateTimeOffset]) {
        $publishedAt = $Value
    }
    elseif ($Value -is [DateTime]) {
        $publishedAt = [DateTimeOffset]$Value
    }
    elseif (-not [DateTimeOffset]::TryParse(
        [string]$Value,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AllowWhiteSpaces -bor [System.Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$publishedAt
    )) {
        throw "Published release $TagName has an invalid published_at value."
    }
    return $publishedAt.UtcDateTime.ToString(
        "dd-MMM-yyyy",
        [System.Globalization.CultureInfo]::InvariantCulture)
}

function Assert-PublishedChangelogReleaseParity {
    param(
        [string]$ChangelogText,
        [object[]]$Releases,
        [string]$AllowedUnpublishedTag
    )

    $normalized = ($ChangelogText -replace "`r`n", "`n") -replace "`r", "`n"
    if (-not $normalized.StartsWith("# Changelog`n`n", [System.StringComparison]::Ordinal)) {
        throw "CHANGELOG.md must begin with the canonical changelog heading."
    }

    $headingPattern = Get-ChangelogHeadingPattern
    $allHeadings = @([regex]::Matches($normalized, '(?m)^##(?!#)\s+.*$'))
    $canonicalHeadings = @([regex]::Matches(
        $normalized,
        $headingPattern,
        [System.Text.RegularExpressions.RegexOptions]::Multiline))
    if ($canonicalHeadings.Count -eq 0 -or $canonicalHeadings.Count -ne $allHeadings.Count) {
        throw "CHANGELOG.md contains a missing or malformed release heading."
    }

    $headingByTag = @{}
    $headingRecords = @()
    $previousVersion = $null
    foreach ($heading in $canonicalHeadings) {
        $version = $heading.Groups[1].Value
        $tagName = ConvertTo-StatsProReleaseTagName -Value "v$version"
        if ($headingByTag.ContainsKey($tagName)) {
            throw "CHANGELOG.md contains duplicate release heading $tagName."
        }
        if ($null -ne $previousVersion -and (Compare-SemVer -Left $version -Right $previousVersion) -ne -1) {
            throw "CHANGELOG.md release headings must be unique and strictly descending; found $tagName after v$previousVersion."
        }
        $record = [pscustomobject]@{
            Tag = $tagName
            Version = $version
            Date = $heading.Groups[2].Value
        }
        $headingByTag[$tagName] = $record
        $headingRecords += $record
        $previousVersion = $version
    }

    $allowedTag = $null
    if (-not [string]::IsNullOrWhiteSpace($AllowedUnpublishedTag)) {
        $allowedTag = ConvertTo-StatsProReleaseTagName -Value $AllowedUnpublishedTag
        if ($headingRecords[0].Tag -ne $allowedTag) {
            throw "Allowed unpublished tag $allowedTag must match the top changelog heading $($headingRecords[0].Tag)."
        }
    }

    $publishedByTag = @{}
    foreach ($release in @($Releases)) {
        if ($null -eq $release) {
            throw "GitHub release inventory contains a null release."
        }
        $draftProperty = $release.PSObject.Properties["draft"]
        $prereleaseProperty = $release.PSObject.Properties["prerelease"]
        if ($null -eq $draftProperty -or $draftProperty.Value -isnot [bool] -or
            $null -eq $prereleaseProperty -or $prereleaseProperty.Value -isnot [bool]) {
            throw "GitHub release inventory contains a release with malformed draft/prerelease state."
        }
        if ($draftProperty.Value -or $prereleaseProperty.Value) {
            continue
        }

        $tagProperty = $release.PSObject.Properties["tag_name"]
        $publishedProperty = $release.PSObject.Properties["published_at"]
        if ($null -eq $tagProperty -or $tagProperty.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace($tagProperty.Value) -or $null -eq $publishedProperty) {
            throw "GitHub release inventory contains malformed published release metadata."
        }
        $tagName = ConvertTo-StatsProReleaseTagName -Value $tagProperty.Value
        if (-not [System.StringComparer]::Ordinal.Equals($tagName, $tagProperty.Value)) {
            throw "Published release tag '$($tagProperty.Value)' is not canonical."
        }
        if ($publishedByTag.ContainsKey($tagName)) {
            throw "GitHub release inventory contains duplicate published release $tagName."
        }
        $publishedByTag[$tagName] = ConvertTo-PublishedReleaseDate `
            -Value $publishedProperty.Value `
            -TagName $tagName
    }
    if ($publishedByTag.Count -eq 0) {
        throw "GitHub release inventory contains no published stable releases."
    }

    foreach ($tagName in $publishedByTag.Keys) {
        if (-not $headingByTag.ContainsKey($tagName)) {
            throw "Published release $tagName has no changelog heading."
        }
    }
    foreach ($record in $headingRecords) {
        if ($publishedByTag.ContainsKey($record.Tag)) {
            $publishedDate = [string]$publishedByTag[$record.Tag]
            if ($record.Date -ne $publishedDate) {
                throw "Changelog heading $($record.Tag) uses $($record.Date), expected published date $publishedDate."
            }
            continue
        }
        if ($record -eq $headingRecords[0] -and $record.Tag -eq $allowedTag) {
            continue
        }
        throw "Unpublished historical changelog heading $($record.Tag) must be reassigned to the recovery release that actually ships it."
    }

    Write-Host "Published changelog parity passed: $($publishedByTag.Count) stable release(s), $($headingRecords.Count) heading(s)."
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
        [string]$ExportTopChangelogPath,
        [bool]$ShouldVerifyPublishedChangelog = $false,
        [string]$RepositoryName = $null
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

    if ($ShouldVerifyPublishedChangelog) {
        $releases = @(Get-GitHubReleaseInventory -RepositoryName $RepositoryName)
        $changelogText = Get-Content -Path "CHANGELOG.md" -Raw -Encoding UTF8
        Assert-PublishedChangelogReleaseParity `
            -ChangelogText $changelogText `
            -Releases $releases `
            -AllowedUnpublishedTag $TagName
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

    $publishedReleases = @([pscustomobject]@{
        tag_name = "v1.0.0"
        draft = $false
        prerelease = $false
        published_at = "2026-01-01T12:00:00Z"
    })
    $publishedChangelog = "# Changelog`n`n## 1.0.0 - 01-Jan-2026 $([char]0x2014) Initial`n"
    Assert-PublishedChangelogReleaseParity `
        -ChangelogText $publishedChangelog `
        -Releases $publishedReleases `
        -AllowedUnpublishedTag "v1.0.0"

    $reassignedRecoveryChangelog = "# Changelog`n`n## 1.0.2 - 03-Jan-2026 $([char]0x2014) Recovery`n`n## 1.0.0 - 01-Jan-2026 $([char]0x2014) Initial`n"
    Assert-PublishedChangelogReleaseParity `
        -ChangelogText $reassignedRecoveryChangelog `
        -Releases $publishedReleases `
        -AllowedUnpublishedTag "v1.0.2"

    $duplicatedFailedHeading = "# Changelog`n`n## 1.0.2 - 03-Jan-2026 $([char]0x2014) Recovery`n`n## 1.0.1 - 02-Jan-2026 $([char]0x2014) Failed`n`n## 1.0.0 - 01-Jan-2026 $([char]0x2014) Initial`n"
    Assert-ThrowsMatch "failed prepared heading must be reassigned instead of duplicated" {
        Assert-PublishedChangelogReleaseParity `
            -ChangelogText $duplicatedFailedHeading `
            -Releases $publishedReleases `
            -AllowedUnpublishedTag "v1.0.2"
    } "unpublished historical changelog heading.*v1\.0\.1"

    $draftState = @($publishedReleases) + [pscustomobject]@{
        tag_name = "v1.0.1"
        draft = $true
        prerelease = $false
        published_at = $null
    }
    Assert-ThrowsMatch "draft release does not legitimize a changelog heading" {
        Assert-PublishedChangelogReleaseParity `
            -ChangelogText $duplicatedFailedHeading `
            -Releases $draftState `
            -AllowedUnpublishedTag "v1.0.2"
    } "unpublished historical changelog heading.*v1\.0\.1"

    $missingHeadingState = @($publishedReleases) + [pscustomobject]@{
        tag_name = "v0.9.0"
        draft = $false
        prerelease = $false
        published_at = "2025-12-31T12:00:00Z"
    }
    Assert-ThrowsMatch "published release without changelog heading rejected" {
        Assert-PublishedChangelogReleaseParity `
            -ChangelogText $publishedChangelog `
            -Releases $missingHeadingState `
            -AllowedUnpublishedTag "v1.0.0"
    } "published release.*v0\.9\.0.*has no changelog heading"

    $wrongDateChangelog = $publishedChangelog.Replace("01-Jan-2026", "02-Jan-2026")
    Assert-ThrowsMatch "published release date mismatch rejected" {
        Assert-PublishedChangelogReleaseParity `
            -ChangelogText $wrongDateChangelog `
            -Releases $publishedReleases `
            -AllowedUnpublishedTag "v1.0.0"
    } "v1\.0\.0.*02-Jan-2026.*01-Jan-2026"

    $ignoredNonStableState = @($publishedReleases) + @(
        [pscustomobject]@{ tag_name = "v1.0.1"; draft = $true; prerelease = $false; published_at = $null },
        [pscustomobject]@{ tag_name = "v1.1.0"; draft = $false; prerelease = $true; published_at = "2026-01-04T12:00:00Z" }
    )
    Assert-PublishedChangelogReleaseParity `
        -ChangelogText $publishedChangelog `
        -Releases $ignoredNonStableState `
        -AllowedUnpublishedTag "v1.0.0"

    Assert-ThrowsMatch "duplicate published release rejected" {
        Assert-PublishedChangelogReleaseParity `
            -ChangelogText $publishedChangelog `
            -Releases (@($publishedReleases) + @($publishedReleases)) `
            -AllowedUnpublishedTag "v1.0.0"
    } "duplicate published release v1\.0\.0"

    $stringDraftState = @([pscustomobject]@{
        tag_name = "v1.0.0"
        draft = "false"
        prerelease = $false
        published_at = "2026-01-01T12:00:00Z"
    })
    Assert-ThrowsMatch "non-boolean release state rejected" {
        Assert-PublishedChangelogReleaseParity `
            -ChangelogText $publishedChangelog `
            -Releases $stringDraftState `
            -AllowedUnpublishedTag "v1.0.0"
    } "malformed draft/prerelease state"

    $duplicateHeadingChangelog = $publishedChangelog + "`n## 1.0.0 - 01-Jan-2026 $([char]0x2014) Duplicate`n"
    Assert-ThrowsMatch "duplicate changelog heading rejected" {
        Assert-PublishedChangelogReleaseParity `
            -ChangelogText $duplicateHeadingChangelog `
            -Releases $publishedReleases `
            -AllowedUnpublishedTag "v1.0.0"
    } "duplicate release heading v1\.0\.0"

    $ascendingChangelog = "# Changelog`n`n## 1.0.0 - 01-Jan-2026 $([char]0x2014) Initial`n`n## 1.0.1 - 02-Jan-2026 $([char]0x2014) Later`n"
    Assert-ThrowsMatch "non-descending changelog rejected" {
        Assert-PublishedChangelogReleaseParity `
            -ChangelogText $ascendingChangelog `
            -Releases $publishedReleases `
            -AllowedUnpublishedTag "v1.0.0"
    } "strictly descending"

    $pageOne = @(1..100 | ForEach-Object { [pscustomobject]@{ tag_name = "v1.0.$_" } })
    $pageTwo = @([pscustomobject]@{ tag_name = "v1.1.0" })
    $pageList = [System.Collections.Generic.List[object]]::new()
    $pageList.Add($pageOne)
    $pageList.Add($pageTwo)
    $slurpJson = ConvertTo-Json -InputObject $pageList.ToArray() -Depth 4 -Compress
    $slurpReleases = @(ConvertFrom-GhSlurpReleasePages -Json $slurpJson)
    if ($slurpReleases.Count -ne 101) {
        throw "Paginated GitHub release inventory must retain every page; expected 101 releases, got $($slurpReleases.Count)."
    }

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
        -ExportTopChangelogPath $ExportTopChangelogPath `
        -ShouldVerifyPublishedChangelog:$VerifyPublishedChangelog.IsPresent `
        -RepositoryName $Repository
}
finally {
    Pop-Location
}
