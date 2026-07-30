param(
    [ValidateSet("Create", "Verify")]
    [string]$Mode,
    [string]$Repository,
    [string]$ExpectedTag,
    [string]$ExpectedCommitSha,
    [string]$ExpectedRunId,
    [string]$ExpectedRunAttempt,
    [string]$ExpectedProjectVersion,
    [string]$ArchivePath,
    [string]$ReleaseJsonPath,
    [string]$ManifestPath,
    [string]$CandidatePath,
    [string]$ExpectedCandidateSha256,
    [int]$ArchonMaxAgeDays = -1,
    [string]$OutputPath,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "release-tag-contract.ps1")

$CandidateFileName = "statspro-release-candidate.json"
$ReleaseJsonFileName = "release.json"
$ManifestFileName = "statspro-package-tree.sha256"

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

function Assert-RepositoryName {
    param([string]$Value)

    if ($Value -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw "Malformed GitHub repository '$Value'. Expected owner/name."
    }
}

function Assert-CommitSha {
    param([string]$Value)

    if ($Value -cnotmatch '^[0-9a-f]{40}$') {
        throw "Malformed expected commit SHA '$Value'."
    }
}

function Assert-RunId {
    param([string]$Value)

    if ($Value -notmatch '^[1-9][0-9]*$') {
        throw "Malformed GitHub Actions run ID '$Value'."
    }
}

function Assert-RunAttempt {
    param([string]$Value)

    if ($Value -notmatch '^[1-9][0-9]*$') {
        throw "Malformed GitHub Actions run attempt '$Value'."
    }
}

function Assert-ProjectVersion {
    param([string]$Value, [string]$Tag)

    Assert-StatsProPackagerProjectVersion -Value $Value
    if (-not [System.StringComparer]::Ordinal.Equals($Value, $Tag)) {
        throw "Packager project version '$Value' does not match release tag '$Tag'."
    }
}

function Assert-Sha256 {
    param([string]$Value, [string]$Description)

    if ($Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Description must be 64 lowercase hexadecimal characters."
    }
}

function Resolve-RequiredFile {
    param([string]$Path, [string]$Description)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing $Description file '$Path'."
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-LowercaseFileSha256 {
    param([string]$Path)

    return (Get-FileHash -LiteralPath (Resolve-RequiredFile -Path $Path -Description "hash input") -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-FileContract {
    param([string]$Path, [string]$Name)

    $resolved = Resolve-RequiredFile -Path $Path -Description "release handoff"
    $size = (Get-Item -LiteralPath $resolved).Length
    if ($size -le 0) {
        throw "Release handoff '$Name' must be non-empty."
    }
    return [pscustomobject][ordered]@{
        name = $Name
        size = [long]$size
        sha256 = Get-LowercaseFileSha256 -Path $resolved
    }
}

function Assert-ExactPropertySet {
    param([object]$Value, [string[]]$Expected, [string]$Description)

    if ($null -eq $Value) {
        throw "$Description is missing."
    }
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expectedSorted = @($Expected | Sort-Object)
    if ($actual.Count -ne $expectedSorted.Count -or
        (Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actual)) {
        throw "$Description fields are '$($actual -join ', ')'; expected '$($expectedSorted -join ', ')'."
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)

    $resolvedParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $resolvedParent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $resolvedParent -Force)
    }
    [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($Path), $Text, [System.Text.UTF8Encoding]::new($false))
}

function Add-OutputValue {
    param([string]$Path, [string]$Name, [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    if ($Value -match '[\r\n]') {
        throw "Output '$Name' contains a newline."
    }
    [System.IO.File]::AppendAllText(
        [System.IO.Path]::GetFullPath($Path),
        "$Name=$Value`n",
        [System.Text.UTF8Encoding]::new($false))
}

function Get-ExpectedNames {
    param([string]$Tag)

    return [ordered]@{
        Archive = "StatsPro-$Tag.zip"
        ReleaseJson = $ReleaseJsonFileName
        Manifest = $ManifestFileName
    }
}

function Assert-ExpectedFileName {
    param([string]$Path, [string]$ExpectedName, [string]$Description)

    $actualName = [System.IO.Path]::GetFileName($Path)
    if (-not [System.StringComparer]::Ordinal.Equals($actualName, $ExpectedName)) {
        throw "$Description filename is '$actualName', expected '$ExpectedName'."
    }
}

function New-ReleaseCandidate {
    param(
        [string]$RepositoryName,
        [string]$Tag,
        [string]$CommitSha,
        [string]$RunId,
        [string]$RunAttempt,
        [string]$ProjectVersion,
        [string]$Archive,
        [string]$ReleaseJson,
        [string]$Manifest,
        [string]$Destination,
        [string]$GithubOutputPath,
        [scriptblock]$ValidateArtifact
    )

    Assert-RepositoryName $RepositoryName
    Assert-StatsProReleaseTag -Value $Tag
    Assert-CommitSha $CommitSha
    Assert-RunId $RunId
    Assert-RunAttempt $RunAttempt
    Assert-ProjectVersion -Value $ProjectVersion -Tag $Tag
    $names = Get-ExpectedNames -Tag $Tag
    $resolved = [ordered]@{
        Archive = Resolve-RequiredFile -Path $Archive -Description "release archive"
        ReleaseJson = Resolve-RequiredFile -Path $ReleaseJson -Description "release metadata"
        Manifest = Resolve-RequiredFile -Path $Manifest -Description "package manifest"
    }
    foreach ($key in $resolved.Keys) {
        Assert-ExpectedFileName -Path $resolved[$key] -ExpectedName $names[$key] -Description $key
    }
    Assert-ExpectedFileName -Path $Destination -ExpectedName $CandidateFileName -Description "candidate"

    if ($null -ne $ValidateArtifact) {
        & $ValidateArtifact $resolved.Archive $resolved.ReleaseJson $Tag $ProjectVersion
    }
    else {
        & (Join-Path $PSScriptRoot 'check-release-artifact.ps1') `
            -ZipPath $resolved.Archive `
            -ReleaseJsonPath $resolved.ReleaseJson `
            -ExpectedTag $Tag `
            -PackagerProjectVersion $ProjectVersion `
            -EnforceToolLocks `
            -RequireExactPackagerProjectVersion `
            -WithReleaseJson
    }

    $candidate = [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = "statspro-release-candidate"
        repository = $RepositoryName
        tag = $Tag
        commitSha = $CommitSha
        runId = $RunId
        runAttempt = $RunAttempt
        projectVersion = $ProjectVersion
        files = [pscustomobject][ordered]@{
            archive = Get-FileContract -Path $resolved.Archive -Name $names.Archive
            releaseJson = Get-FileContract -Path $resolved.ReleaseJson -Name $names.ReleaseJson
            packageManifest = Get-FileContract -Path $resolved.Manifest -Name $names.Manifest
        }
    }
    $json = $candidate | ConvertTo-Json -Depth 6 -Compress
    Write-Utf8NoBom -Path $Destination -Text ($json + "`n")

    Add-OutputValue -Path $GithubOutputPath -Name "archive_path" -Value $resolved.Archive
    Add-OutputValue -Path $GithubOutputPath -Name "release_json_path" -Value $resolved.ReleaseJson
    Add-OutputValue -Path $GithubOutputPath -Name "manifest_path" -Value $resolved.Manifest
    Add-OutputValue -Path $GithubOutputPath -Name "candidate_path" -Value ([System.IO.Path]::GetFullPath($Destination))
    Add-OutputValue -Path $GithubOutputPath -Name "archive_sha256" -Value $candidate.files.archive.sha256
    Add-OutputValue -Path $GithubOutputPath -Name "candidate_sha256" -Value (Get-LowercaseFileSha256 -Path $Destination)
    return $candidate
}

function Read-ReleaseCandidate {
    param(
        [string]$Path,
        [string]$ExpectedSha256,
        [string]$RepositoryName,
        [string]$Tag,
        [string]$CommitSha,
        [string]$RunId,
        [string]$RunAttempt,
        [string]$ProjectVersion
    )

    $resolved = Resolve-RequiredFile -Path $Path -Description "release candidate"
    Assert-ExpectedFileName -Path $resolved -ExpectedName $CandidateFileName -Description "candidate"
    Assert-Sha256 -Value $ExpectedSha256 -Description "Expected candidate SHA-256"
    $actualSha = Get-LowercaseFileSha256 -Path $resolved
    if (-not [System.StringComparer]::Ordinal.Equals($actualSha, $ExpectedSha256)) {
        throw "Release candidate SHA-256 is '$actualSha', expected '$ExpectedSha256'."
    }
    try {
        $candidate = ConvertFrom-JsonCompat ([System.IO.File]::ReadAllText($resolved))
    }
    catch {
        throw "Release candidate contains invalid JSON: $($_.Exception.Message)"
    }
    Assert-ExactPropertySet -Value $candidate -Expected @('schemaVersion', 'kind', 'repository', 'tag', 'commitSha', 'runId', 'runAttempt', 'projectVersion', 'files') -Description "Release candidate"
    Assert-ExactPropertySet -Value $candidate.files -Expected @('archive', 'releaseJson', 'packageManifest') -Description "Release candidate files"
    foreach ($property in @('archive', 'releaseJson', 'packageManifest')) {
        Assert-ExactPropertySet -Value $candidate.files.$property -Expected @('name', 'size', 'sha256') -Description "Release candidate $property"
        Assert-Sha256 -Value ([string]$candidate.files.$property.sha256) -Description "Release candidate $property SHA-256"
        $size = 0L
        if (-not [long]::TryParse([string]$candidate.files.$property.size, [ref]$size) -or $size -le 0) {
            throw "Release candidate $property size must be a positive integer."
        }
    }
    if ([int]$candidate.schemaVersion -ne 1 -or
        -not [System.StringComparer]::Ordinal.Equals([string]$candidate.kind, 'statspro-release-candidate')) {
        throw "Release candidate has an unsupported schema or kind."
    }
    Assert-RepositoryName ([string]$candidate.repository)
    Assert-StatsProReleaseTag -Value ([string]$candidate.tag)
    Assert-CommitSha ([string]$candidate.commitSha)
    Assert-RunId ([string]$candidate.runId)
    Assert-RunAttempt ([string]$candidate.runAttempt)
    Assert-ProjectVersion -Value ([string]$candidate.projectVersion) -Tag ([string]$candidate.tag)
    foreach ($identity in @(
        [pscustomobject]@{ Name = 'repository'; Actual = [string]$candidate.repository; Expected = $RepositoryName },
        [pscustomobject]@{ Name = 'tag'; Actual = [string]$candidate.tag; Expected = $Tag },
        [pscustomobject]@{ Name = 'commit'; Actual = [string]$candidate.commitSha; Expected = $CommitSha },
        [pscustomobject]@{ Name = 'run'; Actual = [string]$candidate.runId; Expected = $RunId },
        [pscustomobject]@{ Name = 'run attempt'; Actual = [string]$candidate.runAttempt; Expected = $RunAttempt },
        [pscustomobject]@{ Name = 'project version'; Actual = [string]$candidate.projectVersion; Expected = $ProjectVersion }
    )) {
        if (-not [System.StringComparer]::Ordinal.Equals($identity.Actual, $identity.Expected)) {
            throw "Release candidate $($identity.Name) is '$($identity.Actual)', expected '$($identity.Expected)'."
        }
    }
    $expectedNames = Get-ExpectedNames -Tag $Tag
    $candidateNames = [ordered]@{
        Archive = [string]$candidate.files.archive.name
        ReleaseJson = [string]$candidate.files.releaseJson.name
        Manifest = [string]$candidate.files.packageManifest.name
    }
    foreach ($key in $candidateNames.Keys) {
        if (-not [System.StringComparer]::Ordinal.Equals($candidateNames[$key], $expectedNames[$key])) {
            throw "Release candidate $key filename is '$($candidateNames[$key])', expected '$($expectedNames[$key])'."
        }
    }
    return $candidate
}

function Export-ArchiveContractFiles {
    param([string]$Archive, [string]$Root)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $contracts = [ordered]@{
            Toc = "StatsPro/StatsPro.toc"
            Notes = "StatsPro/CHANGELOG.md"
        }
        $outputs = [ordered]@{}
        foreach ($key in $contracts.Keys) {
            $matches = @($zip.Entries | Where-Object {
                [System.StringComparer]::Ordinal.Equals($_.FullName.Replace('\', '/'), $contracts[$key])
            })
            if ($matches.Count -ne 1 -or $matches[0].Length -le 0) {
                throw "Release archive must contain exactly one non-empty '$($contracts[$key])' entry."
            }
            $destinationName = if ($key -eq 'Toc') { 'StatsPro.toc' } else { 'release-notes.md' }
            $destination = Join-Path $Root $destinationName
            $inputStream = $matches[0].Open()
            try {
                $outputStream = [System.IO.File]::Create($destination)
                try {
                    $inputStream.CopyTo($outputStream)
                }
                finally {
                    $outputStream.Dispose()
                }
            }
            finally {
                $inputStream.Dispose()
            }
            $outputs[$key] = (Resolve-Path -LiteralPath $destination).Path
        }
        return $outputs
    }
    finally {
        $zip.Dispose()
    }
}

function Assert-ArchiveArchonFreshness {
    param(
        [string]$Archive,
        [int]$MaxAgeDays,
        [datetime]$TodayUtc = [datetime]::UtcNow.Date
    )

    if ($MaxAgeDays -lt 0) {
        throw "Archon maximum age must be a non-negative integer."
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $matches = @($zip.Entries | Where-Object {
            [System.StringComparer]::Ordinal.Equals(
                $_.FullName.Replace('\', '/'),
                'StatsPro/StatsPro_ArchonTargets.lua')
        })
        if ($matches.Count -ne 1 -or $matches[0].Length -le 0 -or $matches[0].Length -gt 10MB) {
            throw "Release archive must contain exactly one bounded non-empty 'StatsPro/StatsPro_ArchonTargets.lua' entry."
        }

        $stream = $matches[0].Open()
        try {
            $reader = [System.IO.StreamReader]::new(
                $stream,
                [System.Text.UTF8Encoding]::new($false, $true),
                $true)
            try {
                $text = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch [System.Text.DecoderFallbackException] {
        throw "Packaged Archon targets are not valid UTF-8."
    }
    finally {
        $zip.Dispose()
    }

    $dateMatches = @([regex]::Matches(
        $text,
        '(?m)^\s*capturedAt\s*=\s*"([0-9]{4}-[0-9]{2}-[0-9]{2})"\s*,\s*$'))
    if ($dateMatches.Count -ne 2) {
        throw "Packaged Archon targets must contain exactly two capturedAt dates, found $($dateMatches.Count)."
    }

    $today = $TodayUtc.Date
    foreach ($match in $dateMatches) {
        $capturedAt = [datetime]::MinValue
        if (-not [datetime]::TryParseExact(
            $match.Groups[1].Value,
            'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$capturedAt)) {
            throw "Packaged Archon capturedAt '$($match.Groups[1].Value)' is not a valid YYYY-MM-DD date."
        }
        $ageDays = [int]($today - $capturedAt.Date).TotalDays
        if ($ageDays -lt -1) {
            throw "Packaged Archon capturedAt '$($match.Groups[1].Value)' is in the future."
        }
        if ($ageDays -gt $MaxAgeDays) {
            throw "Packaged Archon capturedAt '$($match.Groups[1].Value)' is stale: $ageDays day(s) old, max $MaxAgeDays."
        }
    }
}

function Confirm-ReleaseCandidate {
    param(
        [string]$RepositoryName,
        [string]$Tag,
        [string]$CommitSha,
        [string]$RunId,
        [string]$RunAttempt,
        [string]$ProjectVersion,
        [string]$Candidate,
        [string]$CandidateSha256,
        [string]$GithubOutputPath,
        [int]$ArchonMaximumAgeDays = -1,
        [datetime]$TodayUtc = [datetime]::UtcNow.Date
    )

    $resolvedCandidate = Resolve-RequiredFile -Path $Candidate -Description "release candidate"
    if ($ArchonMaximumAgeDays -lt -1) {
        throw "Archon maximum age must be -1 (disabled) or a non-negative integer."
    }
    $root = Split-Path -Parent $resolvedCandidate
    $contract = Read-ReleaseCandidate `
        -Path $resolvedCandidate `
        -ExpectedSha256 $CandidateSha256 `
        -RepositoryName $RepositoryName `
        -Tag $Tag `
        -CommitSha $CommitSha `
        -RunId $RunId `
        -RunAttempt $RunAttempt `
        -ProjectVersion $ProjectVersion

    $expectedFiles = @($CandidateFileName)
    foreach ($property in @('archive', 'releaseJson', 'packageManifest')) {
        $expectedFiles += [string]$contract.files.$property.name
    }
    $actualItems = @(Get-ChildItem -LiteralPath $root -Force -Recurse)
    foreach ($item in $actualItems) {
        if ($item.PSIsContainer -or (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -or
            -not [System.StringComparer]::Ordinal.Equals($item.DirectoryName, $root)) {
            throw "Release handoff must contain only ordinary top-level files; found '$($item.FullName)'."
        }
    }
    $actualFiles = @($actualItems | ForEach-Object Name | Sort-Object)
    $requiredSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $allowedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($name in $expectedFiles) { [void]$requiredSet.Add($name); [void]$allowedSet.Add($name) }
    foreach ($name in @('StatsPro.toc', 'release-notes.md')) { [void]$allowedSet.Add($name) }
    $missing = @($requiredSet | Where-Object {
        $requiredName = $_
        -not (@($actualFiles | Where-Object { [System.StringComparer]::Ordinal.Equals($_, $requiredName) }).Count -eq 1)
    })
    $unexpected = @($actualFiles | Where-Object { -not $allowedSet.Contains($_) })
    if ($missing.Count -ne 0 -or $unexpected.Count -ne 0) {
        throw "Release handoff files are '$($actualFiles -join ', ')'; missing '$($missing -join ', ')'; unexpected '$($unexpected -join ', ')'."
    }

    $bindings = [ordered]@{
        archive = $contract.files.archive
        release_json = $contract.files.releaseJson
        manifest = $contract.files.packageManifest
    }
    $resolvedPaths = [ordered]@{}
    foreach ($key in $bindings.Keys) {
        $path = Join-Path $root ([string]$bindings[$key].name)
        $actualSha = Get-LowercaseFileSha256 -Path $path
        $actualSize = (Get-Item -LiteralPath $path).Length
        if ($actualSize -ne [long]$bindings[$key].size) {
            throw "Release handoff $key size is '$actualSize', expected '$($bindings[$key].size)'."
        }
        if (-not [System.StringComparer]::Ordinal.Equals($actualSha, [string]$bindings[$key].sha256)) {
            throw "Release handoff $key SHA-256 is '$actualSha', expected '$($bindings[$key].sha256)'."
        }
        $resolvedPaths[$key] = (Resolve-Path -LiteralPath $path).Path
    }

    if ($ArchonMaximumAgeDays -ge 0) {
        Assert-ArchiveArchonFreshness `
            -Archive $resolvedPaths.archive `
            -MaxAgeDays $ArchonMaximumAgeDays `
            -TodayUtc $TodayUtc
    }

    $archiveContracts = Export-ArchiveContractFiles -Archive $resolvedPaths.archive -Root $root
    Add-OutputValue -Path $GithubOutputPath -Name "archive_path" -Value $resolvedPaths.archive
    Add-OutputValue -Path $GithubOutputPath -Name "release_json_path" -Value $resolvedPaths.release_json
    Add-OutputValue -Path $GithubOutputPath -Name "manifest_path" -Value $resolvedPaths.manifest
    Add-OutputValue -Path $GithubOutputPath -Name "notes_path" -Value $archiveContracts.Notes
    return $contract
}

function New-TestZip {
    param(
        [string]$Path,
        [string]$Tag,
        [string[]]$CapturedAt = @('2026-07-25', '2026-07-25')
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = [System.IO.File]::Create($Path)
    try {
        $zip = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $archonText = @"
StatsProArchonTargets = {
  snapshots = {
    mythicPlus = {
      capturedAt = "$($CapturedAt[0])",
    },
    raid = {
      capturedAt = "$($CapturedAt[1])",
    },
  },
}
"@
            foreach ($item in @(
                [pscustomobject]@{ Name = 'StatsPro/StatsPro.toc'; Text = "## Version: $($Tag.Substring(1))`n" },
                [pscustomobject]@{ Name = 'StatsPro/CHANGELOG.md'; Text = "# Changelog`n`n## $($Tag.Substring(1))`n" },
                [pscustomobject]@{ Name = 'StatsPro/StatsPro_ArchonTargets.lua'; Text = $archonText }
            )) {
                $entry = $zip.CreateEntry($item.Name)
                $writer = [System.IO.StreamWriter]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false))
                try { $writer.Write($item.Text) } finally { $writer.Dispose() }
            }
        }
        finally {
            $zip.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-release-candidate-" + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $root)
    try {
        $tag = 'v1.2.3'
        $commit = '0123456789abcdef0123456789abcdef01234567'
        $runId = '12345'
        $runAttempt = '2'
        $projectVersion = $tag
        $validator = { param($a, $r, $t, $v) }
        $archive = Join-Path $root "StatsPro-$tag.zip"
        $releaseJson = Join-Path $root $ReleaseJsonFileName
        $manifest = Join-Path $root $ManifestFileName
        $candidate = Join-Path $root $CandidateFileName
        New-TestZip -Path $archive -Tag $tag
        Write-Utf8NoBom -Path $releaseJson -Text "{}`n"
        Write-Utf8NoBom -Path $manifest -Text "abc  StatsPro/StatsPro.toc`n"
        [void](New-ReleaseCandidate `
            -RepositoryName 'owner/repo' `
            -Tag $tag `
            -CommitSha $commit `
            -RunId $runId `
            -RunAttempt $runAttempt `
            -ProjectVersion $projectVersion `
            -Archive $archive `
            -ReleaseJson $releaseJson `
            -Manifest $manifest `
            -Destination $candidate `
            -ValidateArtifact $validator)
        $candidateSha = Get-LowercaseFileSha256 -Path $candidate
        [void](Confirm-ReleaseCandidate `
            -RepositoryName 'owner/repo' `
            -Tag $tag `
            -CommitSha $commit `
            -RunId $runId `
            -RunAttempt $runAttempt `
            -ProjectVersion $projectVersion `
            -Candidate $candidate `
            -CandidateSha256 $candidateSha `
            -ArchonMaximumAgeDays 3 `
            -TodayUtc ([datetime]'2026-07-25'))
        Assert-ThrowsMatch "invalid Archon maximum age rejected" {
            [void](Confirm-ReleaseCandidate `
                -RepositoryName 'owner/repo' `
                -Tag $tag `
                -CommitSha $commit `
                -RunId $runId `
                -RunAttempt $runAttempt `
                -ProjectVersion $projectVersion `
                -Candidate $candidate `
                -CandidateSha256 $candidateSha `
                -ArchonMaximumAgeDays -2)
        } "must be -1.*non-negative"

        New-TestZip -Path $archive -Tag $tag -CapturedAt @('2026-07-20', '2026-07-20')
        Assert-ThrowsMatch "stale Archon handoff rejected" {
            Assert-ArchiveArchonFreshness -Archive $archive -MaxAgeDays 3 -TodayUtc ([datetime]'2026-07-25')
        } "is stale"
        New-TestZip -Path $archive -Tag $tag -CapturedAt @('2026-07-27', '2026-07-27')
        Assert-ThrowsMatch "future Archon handoff rejected" {
            Assert-ArchiveArchonFreshness -Archive $archive -MaxAgeDays 3 -TodayUtc ([datetime]'2026-07-25')
        } "in the future"
        New-TestZip -Path $archive -Tag $tag -CapturedAt @('2026-02-29', '2026-02-29')
        Assert-ThrowsMatch "invalid Archon handoff date rejected" {
            Assert-ArchiveArchonFreshness -Archive $archive -MaxAgeDays 999 -TodayUtc ([datetime]'2026-07-25')
        } "not a valid YYYY-MM-DD"
        New-TestZip -Path $archive -Tag $tag

        [void](New-ReleaseCandidate `
            -RepositoryName 'owner/repo' `
            -Tag $tag `
            -CommitSha $commit `
            -RunId $runId `
            -RunAttempt $runAttempt `
            -ProjectVersion $projectVersion `
            -Archive $archive `
            -ReleaseJson $releaseJson `
            -Manifest $manifest `
            -Destination $candidate `
            -ValidateArtifact $validator)
        $candidateSha = Get-LowercaseFileSha256 -Path $candidate

        Assert-ThrowsMatch "wrong candidate digest rejected" {
            [void](Read-ReleaseCandidate -Path $candidate -ExpectedSha256 ('f' * 64) -RepositoryName 'owner/repo' -Tag $tag -CommitSha $commit -RunId $runId -RunAttempt $runAttempt -ProjectVersion $projectVersion)
        } "candidate SHA-256"
        $originalArchive = [System.IO.File]::ReadAllBytes($archive)
        [System.IO.File]::AppendAllText($archive, 'tampered')
        Assert-ThrowsMatch "tampered archive rejected" {
            [void](Confirm-ReleaseCandidate -RepositoryName 'owner/repo' -Tag $tag -CommitSha $commit -RunId $runId -RunAttempt $runAttempt -ProjectVersion $projectVersion -Candidate $candidate -CandidateSha256 $candidateSha)
        } "archive (size|SHA-256)"
        [System.IO.File]::WriteAllBytes($archive, $originalArchive)

        Remove-Item -LiteralPath $candidate -Force
        Assert-ThrowsMatch "semantic validation failure blocks candidate creation" {
            [void](New-ReleaseCandidate -RepositoryName 'owner/repo' -Tag $tag -CommitSha $commit -RunId $runId -RunAttempt $runAttempt -ProjectVersion $projectVersion -Archive $archive -ReleaseJson $releaseJson -Manifest $manifest -Destination $candidate -ValidateArtifact { throw 'semantic validation failed' })
        } "semantic validation failed"
        if (Test-Path -LiteralPath $candidate) {
            throw "Failed semantic validation still created a release candidate."
        }
        [void](New-ReleaseCandidate -RepositoryName 'owner/repo' -Tag $tag -CommitSha $commit -RunId $runId -RunAttempt $runAttempt -ProjectVersion $projectVersion -Archive $archive -ReleaseJson $releaseJson -Manifest $manifest -Destination $candidate -ValidateArtifact $validator)
        $candidateSha = Get-LowercaseFileSha256 -Path $candidate

        $json = ConvertFrom-JsonCompat ([System.IO.File]::ReadAllText($candidate))
        $json | Add-Member -NotePropertyName extra -NotePropertyValue $true
        Write-Utf8NoBom -Path $candidate -Text (($json | ConvertTo-Json -Depth 6 -Compress) + "`n")
        Assert-ThrowsMatch "extra candidate field rejected" {
            [void](Read-ReleaseCandidate -Path $candidate -ExpectedSha256 (Get-LowercaseFileSha256 -Path $candidate) -RepositoryName 'owner/repo' -Tag $tag -CommitSha $commit -RunId $runId -RunAttempt $runAttempt -ProjectVersion $projectVersion)
        } "fields"

        [void](New-ReleaseCandidate -RepositoryName 'owner/repo' -Tag $tag -CommitSha $commit -RunId $runId -RunAttempt $runAttempt -ProjectVersion $projectVersion -Archive $archive -ReleaseJson $releaseJson -Manifest $manifest -Destination $candidate -ValidateArtifact $validator)
        $candidateSha = Get-LowercaseFileSha256 -Path $candidate
        Write-Utf8NoBom -Path (Join-Path $root 'unexpected.txt') -Text 'unexpected'
        Assert-ThrowsMatch "extra handoff file rejected" {
            [void](Confirm-ReleaseCandidate -RepositoryName 'owner/repo' -Tag $tag -CommitSha $commit -RunId $runId -RunAttempt $runAttempt -ProjectVersion $projectVersion -Candidate $candidate -CandidateSha256 $candidateSha)
        } "handoff files"
        Remove-Item -LiteralPath (Join-Path $root 'unexpected.txt') -Force

        $nested = Join-Path $root 'nested'
        [void](New-Item -ItemType Directory -Path $nested)
        Write-Utf8NoBom -Path (Join-Path $nested 'unexpected.txt') -Text 'unexpected'
        Assert-ThrowsMatch "nested handoff content rejected" {
            [void](Confirm-ReleaseCandidate -RepositoryName 'owner/repo' -Tag $tag -CommitSha $commit -RunId $runId -RunAttempt $runAttempt -ProjectVersion $projectVersion -Candidate $candidate -CandidateSha256 $candidateSha)
        } "only ordinary top-level files"

        Write-Host "Release candidate self-test passed."
    }
    finally {
        $resolvedRoot = [System.IO.Path]::GetFullPath($root)
        $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if ($resolvedRoot.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if ([string]::IsNullOrWhiteSpace($Mode)) {
    throw "Missing release candidate -Mode."
}
switch ($Mode) {
    "Create" {
        [void](New-ReleaseCandidate `
            -RepositoryName $Repository `
            -Tag $ExpectedTag `
            -CommitSha $ExpectedCommitSha `
            -RunId $ExpectedRunId `
            -RunAttempt $ExpectedRunAttempt `
            -ProjectVersion $ExpectedProjectVersion `
            -Archive $ArchivePath `
            -ReleaseJson $ReleaseJsonPath `
            -Manifest $ManifestPath `
            -Destination $CandidatePath `
            -GithubOutputPath $OutputPath)
    }
    "Verify" {
        [void](Confirm-ReleaseCandidate `
            -RepositoryName $Repository `
            -Tag $ExpectedTag `
            -CommitSha $ExpectedCommitSha `
            -RunId $ExpectedRunId `
            -RunAttempt $ExpectedRunAttempt `
            -ProjectVersion $ExpectedProjectVersion `
            -Candidate $CandidatePath `
            -CandidateSha256 $ExpectedCandidateSha256 `
            -GithubOutputPath $OutputPath `
            -ArchonMaximumAgeDays $ArchonMaxAgeDays)
    }
}
