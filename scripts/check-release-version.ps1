param(
    [string]$Tag = $env:GITHUB_REF_NAME,
    [switch]$EnforceSemVer,
    [switch]$AllowSemVerMismatch,
    [switch]$SelfTest,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot ".."))
)

$ErrorActionPreference = "Stop"

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
    $tagName = $Value.Trim()
    if ($tagName -match "^refs/tags/(.+)$") {
        $tagName = $Matches[1]
    }
    if ($tagName -notmatch "^v?\d+\.\d+\.\d+$") {
        throw "Malformed release tag '$Value'. Expected vX.Y.Z or X.Y.Z."
    }
    if (-not $tagName.StartsWith("v")) {
        $tagName = "v$tagName"
    }
    return $tagName
}

function Get-ReleaseVersionFromTag {
    param([string]$TagName)

    return $TagName.Substring(1)
}

function ConvertTo-SemVerParts {
    param([string]$Version)

    if ($Version -notmatch "^(\d+)\.(\d+)\.(\d+)$") {
        throw "Malformed SemVer '$Version'. Expected X.Y.Z."
    }
    return @{
        Major = [int]$Matches[1]
        Minor = [int]$Matches[2]
        Patch = [int]$Matches[3]
    }
}

function Get-NextSemVer {
    param(
        [string]$PreviousVersion,
        [ValidateSet("major", "minor", "patch")]
        [string]$Bump
    )

    $parts = ConvertTo-SemVerParts $PreviousVersion
    if ($Bump -eq "major") {
        return "$($parts.Major + 1).0.0"
    }
    if ($Bump -eq "minor") {
        return "$($parts.Major).$($parts.Minor + 1).0"
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
        if ($subject -match "^(fix|perf|refactor|chore|docs|style|test)(?:\([^)]+\))?:") {
            continue
        }
        $unknownSubjects += $subject
    }
    if ($unknownSubjects.Count -gt 0) {
        throw (
            "Cannot derive SemVer bump from non-conventional commit subject(s): " +
            ($unknownSubjects -join "; ") +
            ". Use feat/fix/perf/refactor/chore/docs/style/test or an explicit breaking marker."
        )
    }
    if ($hasMinor) {
        return "minor"
    }
    return "patch"
}

function Get-PreviousReleaseTag {
    param([string]$CurrentTagName)

    $result = Invoke-Git -Arguments @(
        "tag",
        "--merged",
        "HEAD",
        "--list",
        "v[0-9]*.[0-9]*.[0-9]*",
        "--sort=-v:refname"
    )
    foreach ($tag in $result.Output) {
        $name = $tag.Trim()
        if ($name -match "^v\d+\.\d+\.\d+$" -and $name -ne $CurrentTagName) {
            return $name
        }
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

function Assert-ReleaseVersion {
    param(
        [string]$TagValue,
        [bool]$ShouldEnforceSemVer,
        [bool]$PermitSemVerMismatch
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

    $HeadingDash = [regex]::Escape([string][char]0x2014)
    $HeadingPattern = "^##\s+([0-9]+\.[0-9]+\.[0-9]+)\s+-\s+([0-9]{2}-(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)-[0-9]{4})\s+$HeadingDash\s+\S.*$"
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
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-version-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    Push-Location $root
    try {
        [void](Invoke-Git -Arguments @("init"))
        [void](Invoke-Git -Arguments @("config", "user.email", "statspro-tests@example.invalid"))
        [void](Invoke-Git -Arguments @("config", "user.name", "StatsPro Tests"))

        Set-Content -Path "StatsPro.toc" -Value "## Version: 1.0.0" -Encoding UTF8
        Set-Content -Path "StatsPro.lua" -Value 'local CURRENT_RELEASE = "1.0.0"' -Encoding UTF8
        Set-Content -Path "CHANGELOG.md" -Value "## 1.0.0 - 01-Jan-2026 $([char]0x2014) Initial`n" -Encoding UTF8
        [void](Invoke-Git -Arguments @("add", "."))
        [void](Invoke-Git -Arguments @("commit", "-m", "chore: initial release"))
        [void](Invoke-Git -Arguments @("tag", "v1.0.0"))

        Set-Content -Path "StatsPro.toc" -Value "## Version: 1.0.1" -Encoding UTF8
        Set-Content -Path "StatsPro.lua" -Value 'local CURRENT_RELEASE = "1.0.1"' -Encoding UTF8
        Set-Content -Path "CHANGELOG.md" -Value "## 1.0.1 - 02-Jan-2026 $([char]0x2014) Fix`n" -Encoding UTF8
        [void](Invoke-Git -Arguments @("add", "."))
        [void](Invoke-Git -Arguments @("commit", "-m", "fix: repair release gate"))
        Assert-ReleaseVersion -TagValue "v1.0.1" -ShouldEnforceSemVer:$true -PermitSemVerMismatch:$false

        Set-Content -Path "StatsPro.toc" -Value "## Version: 1.1.0" -Encoding UTF8
        Set-Content -Path "StatsPro.lua" -Value 'local CURRENT_RELEASE = "1.1.0"' -Encoding UTF8
        Set-Content -Path "CHANGELOG.md" -Value "## 1.1.0 - 03-Jan-2026 $([char]0x2014) Feature`n" -Encoding UTF8
        Assert-ThrowsMatch "patch commit cannot release minor without override" {
            Assert-ReleaseVersion -TagValue "v1.1.0" -ShouldEnforceSemVer:$true -PermitSemVerMismatch:$false
        } "require patch bump 1\.0\.1"
        Assert-ReleaseVersion -TagValue "v1.1.0" -ShouldEnforceSemVer:$true -PermitSemVerMismatch:$true

        [void](Invoke-Git -Arguments @("commit", "-am", "feat: add target panel"))
        Assert-ReleaseVersion -TagValue "refs/tags/v1.1.0" -ShouldEnforceSemVer:$true -PermitSemVerMismatch:$false
        [void](Invoke-Git -Arguments @("tag", "v1.1.0"))

        Set-Content -Path "StatsPro.toc" -Value "## Version: 2.0.0" -Encoding UTF8
        Set-Content -Path "StatsPro.lua" -Value 'local CURRENT_RELEASE = "2.0.0"' -Encoding UTF8
        Set-Content -Path "CHANGELOG.md" -Value "## 2.0.0 - 05-Jan-2026 $([char]0x2014) Breaking`n" -Encoding UTF8
        [void](Invoke-Git -Arguments @("add", "."))
        [void](Invoke-Git -Arguments @("commit", "-m", "fix!: change saved variables contract"))
        Assert-ReleaseVersion -TagValue "v2.0.0" -ShouldEnforceSemVer:$true -PermitSemVerMismatch:$false

        Assert-ThrowsMatch "unknown conventional prefix rejected" {
            Get-CommitBump -CommitRecords @("misc: unclear release impact")
        } "Cannot derive SemVer"
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
        -PermitSemVerMismatch:$AllowSemVerMismatch.IsPresent
}
finally {
    Pop-Location
}
