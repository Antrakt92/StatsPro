. (Join-Path $PSScriptRoot 'release-tag-contract.ps1')
. (Join-Path $PSScriptRoot 'native-process.ps1')
# The package checker is also an executable script. Its parameter block must
# not replace the manager's supplied archive or mode switches during import.
$foreverLibraryParameterSnapshot = @{}
foreach ($foreverLibraryParameterName in @('ArchivePath','SourceRoot','LibraryOnly','SelfTest')) {
    $foreverLibraryPriorParameter = Get-Variable -Name $foreverLibraryParameterName -Scope Local -ErrorAction SilentlyContinue
    if ($foreverLibraryPriorParameter) { $foreverLibraryParameterSnapshot[$foreverLibraryParameterName] = $foreverLibraryPriorParameter.Value }
}
try { . (Join-Path $PSScriptRoot 'test-forever-package.ps1') -LibraryOnly }
finally {
    foreach ($foreverLibraryParameterName in @('ArchivePath','SourceRoot','LibraryOnly','SelfTest')) {
        if ($foreverLibraryParameterSnapshot.ContainsKey($foreverLibraryParameterName)) {
            Set-Variable -Name $foreverLibraryParameterName -Value $foreverLibraryParameterSnapshot[$foreverLibraryParameterName] -Scope Local
        } else { Remove-Variable -Name $foreverLibraryParameterName -Scope Local -ErrorAction SilentlyContinue }
    }
    Remove-Variable foreverLibraryParameterSnapshot,foreverLibraryParameterName,foreverLibraryPriorParameter
}

function Get-StatsProForeverTextHash {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text.Replace("`r`n", "`n").Replace("`r", "`n"))
    [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function ConvertFrom-StatsProPublishedForeverInventory {
    param([Parameter(Mandatory)][string]$Json)
    $pages = ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate
    if ($pages -isnot [System.Collections.IList]) { throw 'Forever published release inventory must contain paginated arrays' }
    foreach ($page in $pages) {
        if ($page -isnot [System.Collections.IList]) { throw 'Forever published release inventory page is malformed' }
        foreach ($release in $page) {
            if ($release -isnot [System.Collections.IDictionary] -or
                $release.draft -isnot [bool] -or $release.prerelease -isnot [bool] -or
                $release.tag_name -isnot [string] -or -not $release.Contains('published_at')) {
                throw 'Forever published release inventory entry is malformed'
            }
            if (-not $release.draft -and $release.prerelease -and $release.published_at -and
                $release.tag_name.StartsWith('forever-', [System.StringComparison]::Ordinal)) {
                [void][datetimeoffset]::Parse($release.published_at, [System.Globalization.CultureInfo]::InvariantCulture)
                $release.tag_name
            }
        }
    }
}

function Get-StatsProPublishedForeverTags {
    param([string]$Repository = 'Antrakt92/StatsPro')
    if ($Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') { throw 'Forever release inventory requires an exact repository identity' }
    $gh = (Get-Command gh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $result = Invoke-StatsProNativeCapture -FilePath $gh -Arguments @(
        'api', '--paginate', '--slurp', "repos/$Repository/releases?per_page=100"
    ) -TimeoutSeconds 60 -Description 'Read published Forever release history'
    if ($result.ExitCode -ne 0) { throw 'Could not read published Forever release history; publication remains blocked' }
    ConvertFrom-StatsProPublishedForeverInventory -Json ($result.Output -join "`n")
}

function Invoke-StatsProForeverGit {
    param([string]$SourceRoot, [string[]]$Arguments, [switch]$Bytes)
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($key in @($start.Environment.Keys)) {
        if ($key -like 'GIT_*') { [void]$start.Environment.Remove($key) }
    }
    foreach ($arg in @('-C', [System.IO.Path]::GetFullPath($SourceRoot), '--no-replace-objects') + $Arguments) {
        $start.ArgumentList.Add($arg)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    $memory = [System.IO.MemoryStream]::new()
    try {
        [void]$process.Start()
        $outputTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'Forever immutable Git read timed out'
        }
        [void]$outputTask.GetAwaiter().GetResult()
        [void]$errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Forever immutable Git read failed' }
        $result = $memory.ToArray()
        if ($Bytes) { return ,$result }
        return [System.Text.Encoding]::UTF8.GetString($result)
    }
    finally { $memory.Dispose(); $process.Dispose() }
}

function Get-StatsProForeverReleaseContract {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [string]$Repository = 'Antrakt92/StatsPro'
    )
    if ($Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') { throw 'Forever release requires an exact repository identity' }
    if ($ExpectedTag -cnotmatch '\Aforever-(v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\z') {
        throw 'Forever release tag must be exactly forever-vX.Y.Z'
    }
    $packageTag = $Matches[1]
    Assert-StatsProReleaseTag -Value $packageTag
    $root = [System.IO.Path]::GetFullPath($SourceRoot)
    $version = $packageTag.Substring(1)
    $toc = [System.IO.File]::ReadAllText((Join-Path $root 'StatsPro_Forever.toc'))
    Assert-ForeverToc -Text $toc -Version $version
    $retail = [System.IO.File]::ReadAllText((Join-Path $root 'StatsPro.toc'))
    $retailMatches = [regex]::Matches($retail, '(?m)^## Version:[ \t]*([^\r\n]+)')
    if ($retailMatches.Count -ne 1) { throw 'Retail TOC version is ambiguous' }
    $retailVersion = $retailMatches[0].Groups[1].Value.Trim()
    Assert-StatsProReleaseVersion -Value $retailVersion
    $notesPath = Join-Path $root 'CHANGELOG-FOREVER.md'
    $notes = [System.IO.File]::ReadAllText($notesPath)
    $heading = [regex]::Match($notes, '(?m)^## ([0-9]+\.[0-9]+\.[0-9]+) - ([0-9]{2}-[A-Za-z]{3}-[0-9]{4}) — [^\r\n]+')
    if (-not $heading.Success -or $heading.Groups[1].Value -cne $version) {
        throw 'Forever changelog top heading must match the release version and dated heading format'
    }
    [void][datetime]::ParseExact($heading.Groups[2].Value, 'dd-MMM-yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
    if ($ExpectedCommitSha) {
        if ($ExpectedCommitSha -cnotmatch '\A[0-9a-f]{40}\z') { throw 'Forever release requires an exact commit SHA' }
        $head = (Invoke-StatsProForeverGit $root @('rev-parse','--verify','HEAD^{commit}')).Trim()
        if ($head -cne $ExpectedCommitSha) { throw 'Forever checkout HEAD differs from expected commit' }
        $resolved = (Invoke-StatsProForeverGit $root @('rev-parse','--verify', "$ExpectedCommitSha^{commit}")).Trim()
        if ($resolved -cne $ExpectedCommitSha) { throw 'Forever expected commit did not resolve exactly' }
        $tagCommit = (Invoke-StatsProForeverGit $root @('rev-parse','--verify', "refs/tags/$ExpectedTag^{commit}")).Trim()
        if ($tagCommit -cne $ExpectedCommitSha) { throw 'Forever tag differs from expected commit' }
        $main = (Invoke-StatsProForeverGit $root @('merge-base', $ExpectedCommitSha, 'origin/main')).Trim()
        if ($main -cne $ExpectedCommitSha) { throw 'Forever release commit must be an ancestor of origin/main' }
        $paths = @((Get-ForeverPackageMap).Values) + @(
            'StatsPro.toc', 'scripts/forever-release-contract.ps1',
            'scripts/test-forever-package.ps1', 'scripts/build-forever-package.ps1',
            'scripts/release-tag-contract.ps1', 'scripts/saved-variables-contract.ps1',
            'scripts/third-party-contract.ps1', 'scripts/bundled-font-contract.ps1',
            'scripts/bundled-fonts.json', 'scripts/manage-forever-release.ps1',
            'scripts/manage-github-release.ps1', 'scripts/native-process.ps1',
            'scripts/publish-marketplaces.ps1', 'scripts/release-check-contract.ps1',
            'scripts/marketplace-version-contract.ps1', 'scripts/check-marketplace-versions.ps1',
            '.github/workflows/forever-release.yml'
        )
        foreach ($relative in @($paths | Select-Object -Unique)) {
            $entry = (Invoke-StatsProForeverGit $root @('ls-tree', $ExpectedCommitSha, '--', $relative)).Trim()
            if ($entry -cnotmatch ('\A100(?:644|755) blob [0-9a-f]{40}\t' + [regex]::Escape($relative) + '\z')) {
                throw "Forever source must be an ordinary immutable tracked file: $relative"
            }
            $bytes = Invoke-StatsProForeverGit $root @('cat-file','blob', "${ExpectedCommitSha}:$relative") -Bytes
            $path = Join-Path $root $relative
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
                throw "Forever source is absent or linked: $relative"
            }
            $localBytes = [System.IO.File]::ReadAllBytes($path)
            $same = [Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String($localBytes)
            if (-not $same -and $relative -notmatch '\.(png|tga|ttf|otf)$') {
                $decoder = [System.Text.UTF8Encoding]::new($false, $true)
                $same = (Get-StatsProForeverTextHash $decoder.GetString($bytes)) -ceq (Get-StatsProForeverTextHash $decoder.GetString($localBytes))
            }
            if (-not $same) { throw "Forever source differs from immutable commit: $relative" }
        }
        $originalNotes = Invoke-StatsProForeverGit $root @('show','v1.18.0:CHANGELOG.md')
        $originalStart = [regex]::Match($originalNotes, '(?m)^## 1\.18\.0 - ')
        if (-not $originalStart.Success) { throw 'Original Forever release history is unavailable' }
        $history = $originalNotes.Substring($originalStart.Index).Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd()
        if (-not $notes.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd().EndsWith($history, [System.StringComparison]::Ordinal)) {
            throw 'Forever changelog must retain the original cumulative release history'
        }
        # A consumed tag can belong to a failed preparation. Only releases users
        # could actually download establish changelog retention obligations.
        $previousTags = @(Get-StatsProPublishedForeverTags -Repository $Repository | Where-Object { $_ -cne $ExpectedTag })
        $previous = $null
        foreach ($previousTag in $previousTags) {
            if ($previousTag -cnotmatch '\Aforever-(v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\z') {
                throw 'Previous Forever release tag is noncanonical'
            }
            $previousVersion = $Matches[1].Substring(1)
            Assert-StatsProReleaseVersion -Value $previousVersion
            if ([version]$previousVersion -ge [version]$version) { throw 'Forever release must advance the previous beta version' }
            if (-not $previous -or [version]$previousVersion -gt [version]$previous.Version) {
                $previous = [pscustomobject]@{ Tag = $previousTag; Version = $previousVersion }
            }
        }
        if ($previous) {
            $previousNotes = Invoke-StatsProForeverGit $root @('show', "$($previous.Tag):CHANGELOG-FOREVER.md")
            $previousStart = [regex]::Match($previousNotes, ('(?m)^## ' + [regex]::Escape($previous.Version) + ' - '))
            if (-not $previousStart.Success) { throw 'Previous Forever changelog is unavailable' }
            $previousHistory = $previousNotes.Substring($previousStart.Index).Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd()
            if (-not $notes.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd().EndsWith($previousHistory, [System.StringComparison]::Ordinal)) {
                throw 'Forever changelog must retain the previous beta cumulative release history'
            }
        }
    }
    $name = "StatsPro-$packageTag-Forever-beta.zip"
    [pscustomobject][ordered]@{
        Tag = $ExpectedTag; PackageTag = $packageTag; Version = $version
        RetailVersion = $retailVersion; SourceRoot = $root; ExpectedCommitSha = $ExpectedCommitSha
        ArchiveName = $name; AssetNames = @($name)
        ChangelogPath = $notesPath; ChangelogSha256 = Get-StatsProForeverTextHash $notes
    }
}

function Assert-StatsProForeverReleaseArchive {
    param([Parameter(Mandatory)]$Contract, [Parameter(Mandatory)][string]$ArchivePath, [string]$ExpectedSha256)
    $path = [System.IO.Path]::GetFullPath($ArchivePath)
    if ([System.IO.Path]::GetFileName($path) -cne $Contract.ArchiveName) { throw 'Forever archive filename differs from release identity' }
    $sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ExpectedSha256 -and ($ExpectedSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $sha -cne $ExpectedSha256)) {
        throw 'Forever archive digest differs from expected SHA256'
    }
    Assert-ForeverArchive -Path $path -Root $Contract.SourceRoot
    [pscustomobject]@{ Path = $path; Name = $Contract.ArchiveName; Size = (Get-Item -LiteralPath $path).Length; Sha256 = $sha }
}

function Assert-StatsProForeverFreshPublication {
    param([bool]$ReleaseExists, [bool]$JournalExists)
    if ($ReleaseExists -or $JournalExists) { throw 'Forever publication already exists or was attempted; refusing overwrite or upload retry' }
}

function Get-StatsProForeverCandidateObject {
    param($Contract, [string]$Repository, [string]$RunId, [string]$RunAttempt, $Archive)
    if ($Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' -or
        $RunId -cnotmatch '\A[1-9][0-9]*\z' -or $RunAttempt -cnotmatch '\A[1-9][0-9]*\z' -or
        $Contract.ExpectedCommitSha -cnotmatch '\A[0-9a-f]{40}\z') { throw 'Forever candidate requires exact repository, commit and run identity' }
    [ordered]@{
        schemaVersion = 1; flavor = 'Forever'; channel = 'beta'
        repository = $Repository; tag = $Contract.Tag; commitSha = $Contract.ExpectedCommitSha
        runId = $RunId; runAttempt = $RunAttempt; packageTag = $Contract.PackageTag
        archive = [ordered]@{ name = $Archive.Name; size = [long]$Archive.Size; sha256 = $Archive.Sha256 }
        notes = [ordered]@{ name = 'CHANGELOG-FOREVER.md'; sha256 = $Contract.ChangelogSha256 }
    }
}

function New-StatsProForeverReleaseCandidate {
    param($Contract, [string]$Repository, [string]$RunId, [string]$RunAttempt, [string]$ArchivePath, [string]$CandidatePath)
    $archive = Assert-StatsProForeverReleaseArchive -Contract $Contract -ArchivePath $ArchivePath
    $candidate = Get-StatsProForeverCandidateObject $Contract $Repository $RunId $RunAttempt $archive
    $json = ($candidate | ConvertTo-Json -Depth 5) + "`n"
    $path = [System.IO.Path]::GetFullPath($CandidatePath)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    [pscustomobject]@{ CandidatePath = $path; CandidateSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); ArchiveSha256 = $archive.Sha256 }
}

function Read-StatsProForeverReleaseCandidate {
    param($Contract, [string]$Repository, [string]$RunId, [string]$RunAttempt, [string]$ArchivePath,
        [string]$CandidatePath, [string]$ExpectedCandidateSha256, [string]$ExpectedArchiveSha256)
    if ($ExpectedCandidateSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
        (Get-FileHash -LiteralPath $CandidatePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedCandidateSha256) {
        throw 'Forever candidate digest differs from expected SHA256'
    }
    $archive = Assert-StatsProForeverReleaseArchive -Contract $Contract -ArchivePath $ArchivePath -ExpectedSha256 $ExpectedArchiveSha256
    $expected = Get-StatsProForeverCandidateObject $Contract $Repository $RunId $RunAttempt $archive
    $candidateText = [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($CandidatePath))
    $expectedText = ($expected | ConvertTo-Json -Depth 5) + "`n"
    # The handoff has one canonical serialization, rejecting duplicate/foreign
    # keys before a JSON parser could collapse them into an accepted object.
    if ((Get-StatsProForeverTextHash $candidateText) -cne (Get-StatsProForeverTextHash $expectedText)) {
        throw 'Forever candidate fields differ from expected release identity or artifacts'
    }
    $actual = $candidateText | ConvertFrom-Json -AsHashtable
    [pscustomobject]@{ Candidate = $actual; Archive = $archive }
}
