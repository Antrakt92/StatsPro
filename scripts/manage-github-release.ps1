param(
    [ValidateSet("RefuseExisting", "ValidateStart", "CreateDraft", "MarkMarketplaceStarted", "AttachAssets", "Publish", "RetirePrepared")]
    [string]$Mode,
    [string]$Repository,
    [string]$ExpectedTag,
    [string]$ExpectedCommitSha,
    [string]$ExpectedRunId,
    [string]$ArchivePath,
    [string]$ReleaseJsonPath,
    [string]$NotesPath,
    [string]$ManifestPath,
    [int]$AttestationAttempts = 6,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "release-tag-contract.ps1")

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

function Assert-CommitSha {
    param([string]$Value)

    if ($Value -cnotmatch "^[0-9a-f]{40}$") {
        throw "Malformed expected commit SHA '$Value'. Expected 40 lowercase hex characters."
    }
}

function Assert-RepositoryName {
    param([string]$Value)

    if ($Value -notmatch "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") {
        throw "Malformed GitHub repository '$Value'. Expected owner/name."
    }
}

function Assert-RunId {
    param([string]$Value)

    if ($Value -notmatch "^[1-9][0-9]*$") {
        throw "Malformed GitHub Actions run ID '$Value'. Expected a positive decimal integer."
    }
}

function Get-CanonicalFileText {
    param(
        [string]$Path,
        [string]$Description
    )

    $resolved = Resolve-RequiredFile -Path $Path -Description $Description
    $text = [System.IO.File]::ReadAllText($resolved)
    $normalized = ($text -replace "`r`n", "`n") -replace "`r", "`n"
    return $normalized.TrimEnd([char[]]"`n")
}

function Get-LowercaseTextSha256 {
    param([string]$Text)

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($hash.ComputeHash($bytes)) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $hash.Dispose()
    }
}

function ConvertTo-Base64Url {
    param([string]$Text)

    return [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-Base64Url {
    param([string]$Value)

    if ($Value -notmatch '^[A-Za-z0-9_-]+$') {
        throw "Release state marker payload is not canonical base64url."
    }
    $padded = $Value.Replace('-', '+').Replace('_', '/')
    switch ($padded.Length % 4) {
        0 { }
        2 { $padded += '==' }
        3 { $padded += '=' }
        default { throw "Release state marker payload has invalid base64url length." }
    }
    try {
        return [System.Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String($padded))
    }
    catch {
        throw "Release state marker payload is not valid UTF-8 base64url: $($_.Exception.Message)"
    }
}

function Get-ReleaseTransactionId {
    param(
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [string]$NotesSha256,
        [string]$ManifestSha256
    )

    return Get-LowercaseTextSha256 -Text ("statspro-release-transaction-v1`n$Repository`n$ExpectedTag`n$ExpectedCommitSha`n$NotesSha256`n$ManifestSha256")
}

function Get-ReleaseStateData {
    param(
        [ValidateSet('prepared', 'marketplace-started')]
        [string]$Phase,
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [string]$ExpectedRunId,
        [string]$NotesSha256,
        [string]$ManifestSha256
    )

    Assert-RepositoryName $Repository
    Assert-ReleaseTag $ExpectedTag
    Assert-CommitSha $ExpectedCommitSha
    Assert-RunId $ExpectedRunId
    foreach ($digest in @($NotesSha256, $ManifestSha256)) {
        if ($digest -cnotmatch '^[0-9a-f]{64}$') {
            throw "Release state digest '$digest' must be 64 lowercase hex characters."
        }
    }
    return [pscustomobject][ordered]@{
        schemaVersion  = 1
        kind           = 'statspro-release-transaction'
        phase          = $Phase
        repository     = $Repository
        tag            = $ExpectedTag
        commitSha      = $ExpectedCommitSha
        runId          = $ExpectedRunId
        notesSha256    = $NotesSha256
        manifestSha256 = $ManifestSha256
        transactionId  = Get-ReleaseTransactionId `
            -Repository $Repository `
            -ExpectedTag $ExpectedTag `
            -ExpectedCommitSha $ExpectedCommitSha `
            -NotesSha256 $NotesSha256 `
            -ManifestSha256 $ManifestSha256
    }
}

function Get-ReleaseStateMarkerLine {
    param([object]$State)

    $json = $State | ConvertTo-Json -Compress
    return "<!-- statspro-release-state:$(ConvertTo-Base64Url -Text $json) -->"
}

function Get-ReleaseBody {
    param(
        [object]$State,
        [string]$CanonicalNotes
    )

    return "$(Get-ReleaseStateMarkerLine -State $State)`n`n$CanonicalNotes"
}

function Read-ReleaseStateMarker {
    param([string]$Body)

    $normalizedBody = (($Body -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd([char[]]"`n")
    $markerPrefix = '<!-- statspro-release-state:'
    if ([regex]::Matches($normalizedBody, [regex]::Escape($markerPrefix)).Count -ne 1) {
        throw "Release body must contain exactly one StatsPro release state marker."
    }
    $match = [regex]::Match($normalizedBody, '\A<!-- statspro-release-state:([A-Za-z0-9_-]+) -->\n\n')
    if (-not $match.Success) {
        throw "Release state marker must be the canonical first line followed by one blank line."
    }
    $encoded = $match.Groups[1].Value
    $json = ConvertFrom-Base64Url -Value $encoded
    try {
        $state = ConvertFrom-JsonCompat $json
    }
    catch {
        throw "Release state marker is not valid JSON: $($_.Exception.Message)"
    }
    $expectedKeys = @('schemaVersion', 'kind', 'phase', 'repository', 'tag', 'commitSha', 'runId', 'notesSha256', 'manifestSha256', 'transactionId') | Sort-Object
    $actualKeys = @($state.PSObject.Properties.Name | Sort-Object)
    if ($actualKeys.Count -ne $expectedKeys.Count -or (Compare-Object -ReferenceObject $expectedKeys -DifferenceObject $actualKeys)) {
        throw "Release state marker fields are not the exact schema."
    }
    if ([int]$state.schemaVersion -ne 1 -or -not [System.StringComparer]::Ordinal.Equals([string]$state.kind, 'statspro-release-transaction')) {
        throw "Release state marker has an unsupported schema or kind."
    }
    if (-not (Test-ContainsOrdinal -Values @('prepared', 'marketplace-started') -Expected ([string]$state.phase))) {
        throw "Release state marker has unsupported phase '$($state.phase)'."
    }
    Assert-RepositoryName ([string]$state.repository)
    Assert-ReleaseTag ([string]$state.tag)
    Assert-CommitSha ([string]$state.commitSha)
    Assert-RunId ([string]$state.runId)
    foreach ($name in @('notesSha256', 'manifestSha256', 'transactionId')) {
        if ([string]$state.$name -cnotmatch '^[0-9a-f]{64}$') {
            throw "Release state marker field '$name' is not a lowercase SHA-256 digest."
        }
    }
    $expectedTransaction = Get-ReleaseTransactionId `
        -Repository ([string]$state.repository) `
        -ExpectedTag ([string]$state.tag) `
        -ExpectedCommitSha ([string]$state.commitSha) `
        -NotesSha256 ([string]$state.notesSha256) `
        -ManifestSha256 ([string]$state.manifestSha256)
    if (-not [System.StringComparer]::Ordinal.Equals([string]$state.transactionId, $expectedTransaction)) {
        throw "Release state marker transaction ID does not match its identity fields."
    }
    $canonicalMarker = Get-ReleaseStateMarkerLine -State (Get-ReleaseStateData `
        -Phase ([string]$state.phase) `
        -Repository ([string]$state.repository) `
        -ExpectedTag ([string]$state.tag) `
        -ExpectedCommitSha ([string]$state.commitSha) `
        -ExpectedRunId ([string]$state.runId) `
        -NotesSha256 ([string]$state.notesSha256) `
        -ManifestSha256 ([string]$state.manifestSha256))
    if (-not [System.StringComparer]::Ordinal.Equals($match.Value.Substring(0, $match.Value.Length - 2), $canonicalMarker)) {
        throw "Release state marker encoding is not canonical."
    }
    $notes = $normalizedBody.Substring($match.Length)
    if (-not [System.StringComparer]::Ordinal.Equals((Get-LowercaseTextSha256 -Text $notes), [string]$state.notesSha256)) {
        throw "Release notes do not match the release state marker digest."
    }
    return [pscustomobject]@{
        State = $state
        Notes = $notes
        Body  = $normalizedBody
    }
}

function Invoke-Gh {
    param([string[]]$Arguments)

    $result = Invoke-NativeCapture -FilePath "gh" -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw "gh $($Arguments -join ' ') failed with code $($result.ExitCode): $($result.Output -join ' ')"
    }
    return @($result.Output)
}

function Select-GitHubReleaseByTag {
    param(
        [object[]]$Releases,
        [string]$ExpectedTag
    )

    $matches = @($Releases | Where-Object { [System.StringComparer]::Ordinal.Equals([string]$_.tag_name, $ExpectedTag) })
    if ($matches.Count -gt 1) {
        throw "Found multiple GitHub release markers for $ExpectedTag."
    }
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[0]
}

function Get-GitHubReleaseByTag {
    param(
        [string]$Repository,
        [string]$ExpectedTag,
        [scriptblock]$RunGh = $null
    )

    if ($null -eq $RunGh) {
        $RunGh = {
            param([string[]]$Arguments)
            Invoke-NativeCapture -FilePath "gh" -Arguments $Arguments
        }
    }
    $arguments = @(
        "api",
        "--paginate",
        "--slurp",
        "-H", "Accept: application/vnd.github+json",
        "-H", "X-GitHub-Api-Version: 2026-03-10",
        "repos/$Repository/releases?per_page=100"
    )
    $result = & $RunGh $arguments
    if ($result.ExitCode -ne 0) {
        throw "Could not list release markers for $ExpectedTag`: $($result.Output -join ' ')"
    }
    $paginated = ConvertFrom-JsonCompat ($result.Output -join "`n")
    $releases = @()
    foreach ($page in @($paginated)) {
        if ($page -is [System.Array]) {
            $releases += @($page)
        }
        elseif ($null -ne $page) {
            $releases += $page
        }
    }
    return Select-GitHubReleaseByTag -Releases $releases -ExpectedTag $ExpectedTag
}

function Wait-GitHubReleaseState {
    param(
        [string]$Repository,
        [string]$ExpectedTag,
        [int]$Attempts,
        [scriptblock]$AssertState,
        [scriptblock]$GetRelease = $null,
        [scriptblock]$Wait = $null
    )

    if ($Attempts -lt 1) {
        throw "Release state attempts must be at least 1."
    }
    if ($null -eq $GetRelease) {
        $GetRelease = {
            param([string]$RepoName, [string]$TagName)
            Get-GitHubReleaseByTag -Repository $RepoName -ExpectedTag $TagName
        }
    }
    if ($null -eq $Wait) {
        $Wait = {
            param([int]$Seconds)
            Start-Sleep -Seconds $Seconds
        }
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $release = & $GetRelease $Repository $ExpectedTag
            & $AssertState $release
            return $release
        }
        catch {
            $lastError = $_
            if ($attempt -lt $Attempts) {
                & $Wait ([Math]::Min(30, 5 * $attempt))
            }
        }
    }
    throw "GitHub release state for $ExpectedTag did not converge after $Attempts attempt(s): $($lastError.Exception.Message)"
}

function Get-GitHubRemoteTagCommitSha {
    param(
        [string]$Repository,
        [string]$ExpectedTag
    )

    $reference = ConvertFrom-JsonCompat ((Invoke-Gh -Arguments @(
        "api",
        "-H", "Accept: application/vnd.github+json",
        "-H", "X-GitHub-Api-Version: 2026-03-10",
        "repos/$Repository/git/ref/tags/$ExpectedTag"
    )) -join "`n")
    $objectType = [string]$reference.object.type
    $objectSha = [string]$reference.object.sha
    for ($depth = 0; $depth -lt 5 -and $objectType -eq "tag"; $depth++) {
        $tagObject = ConvertFrom-JsonCompat ((Invoke-Gh -Arguments @(
            "api",
            "-H", "Accept: application/vnd.github+json",
            "-H", "X-GitHub-Api-Version: 2026-03-10",
            "repos/$Repository/git/tags/$objectSha"
        )) -join "`n")
        $objectType = [string]$tagObject.object.type
        $objectSha = [string]$tagObject.object.sha
    }
    if ($objectType -ne "commit") {
        throw "Remote tag $ExpectedTag did not peel to a commit; final object type is '$objectType'."
    }
    Assert-CommitSha $objectSha
    return $objectSha
}

function Assert-RemoteTagCommit {
    param(
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [scriptblock]$ResolveTagCommit = $null
    )

    Assert-CommitSha $ExpectedCommitSha
    if ($null -eq $ResolveTagCommit) {
        $ResolveTagCommit = {
            param([string]$RepoName, [string]$TagName)
            Get-GitHubRemoteTagCommitSha -Repository $RepoName -ExpectedTag $TagName
        }
    }
    $actual = [string](& $ResolveTagCommit $Repository $ExpectedTag)
    if (-not [System.StringComparer]::Ordinal.Equals($actual, $ExpectedCommitSha)) {
        throw "Remote tag $ExpectedTag points to $actual, expected event commit $ExpectedCommitSha."
    }
}

function Get-ReleaseAssetNames {
    param([object]$Release)
    return @($Release.assets | ForEach-Object { [string]$_.name })
}

function Get-ExpectedReleaseAssetNames {
    param([string]$ExpectedTag)
    return @("StatsPro-$ExpectedTag.zip", "release.json")
}

function Test-ContainsOrdinal {
    param([string[]]$Values, [string]$Expected)

    foreach ($value in $Values) {
        if ([System.StringComparer]::Ordinal.Equals($value, $Expected)) {
            return $true
        }
    }
    return $false
}

function Get-OrdinalStringSet {
    param([string[]]$Values)

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($value in $Values) {
        if (-not $set.Add($value)) {
            throw "Release contains duplicate asset name '$value'."
        }
    }
    return ,$set
}

function Assert-ExactAssetSet {
    param(
        [object]$Release,
        [string[]]$ExpectedNames
    )

    $actual = @(Get-ReleaseAssetNames -Release $Release)
    $actualSet = Get-OrdinalStringSet -Values $actual
    $expectedSet = Get-OrdinalStringSet -Values $ExpectedNames
    if (-not $actualSet.SetEquals($expectedSet)) {
        throw "Release assets are '$($actual -join ', ')'; expected '$($ExpectedNames -join ', ')'."
    }
}

function Assert-ReleaseCoreState {
    param(
        [object]$Release,
        [string]$ExpectedTag
    )

    if ($null -eq $Release) {
        throw "Release marker $ExpectedTag does not exist."
    }
    if (-not [System.StringComparer]::Ordinal.Equals([string]$Release.tag_name, $ExpectedTag)) {
        throw "Release marker tag is '$($Release.tag_name)', expected '$ExpectedTag'."
    }
    if ([bool]$Release.prerelease) {
        throw "Release $ExpectedTag must not be a prerelease."
    }
}

function Assert-NoExistingRelease {
    param(
        [AllowNull()][object]$Release,
        [string]$ExpectedTag
    )

    if ($null -ne $Release) {
        $state = if ([bool]$Release.draft) { "draft marker" } else { "published release" }
        throw "Release $ExpectedTag already has a $state; refusing marketplace republish."
    }
}

function Assert-DraftRelease {
    param(
        [object]$Release,
        [string]$ExpectedTag,
        [string[]]$ExpectedAssets
    )

    Assert-ReleaseCoreState -Release $Release -ExpectedTag $ExpectedTag
    if (-not [bool]$Release.draft) {
        throw "Release $ExpectedTag is already published."
    }
    if ([bool]$Release.immutable) {
        throw "Draft release $ExpectedTag unexpectedly reports immutable state."
    }
    Assert-ExactAssetSet -Release $Release -ExpectedNames $ExpectedAssets
}

function Assert-ReleaseMarkerIdentity {
    param(
        [object]$Release,
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [string]$ExpectedPhase,
        [AllowEmptyString()][string]$ExpectedRunId,
        [AllowEmptyString()][string]$ExpectedNotes,
        [AllowEmptyString()][string]$ExpectedManifestSha256
    )

    Assert-ReleaseCoreState -Release $Release -ExpectedTag $ExpectedTag
    if (-not [System.StringComparer]::Ordinal.Equals([string]$Release.name, $ExpectedTag)) {
        throw "Release title is '$($Release.name)', expected '$ExpectedTag'."
    }
    # WHY: GitHub reports target_commitish as the default branch for releases
    # created from existing tags. The peeled remote tag check is authoritative.
    $parsed = Read-ReleaseStateMarker -Body ([string]$Release.body)
    $state = $parsed.State
    if (-not [System.StringComparer]::Ordinal.Equals([string]$state.repository, $Repository) -or
        -not [System.StringComparer]::Ordinal.Equals([string]$state.tag, $ExpectedTag) -or
        -not [System.StringComparer]::Ordinal.Equals([string]$state.commitSha, $ExpectedCommitSha)) {
        throw "Release state marker identity does not match repository, tag, and commit."
    }
    if (-not [string]::IsNullOrEmpty($ExpectedPhase) -and -not [System.StringComparer]::Ordinal.Equals([string]$state.phase, $ExpectedPhase)) {
        throw "Release state phase is '$($state.phase)', expected '$ExpectedPhase'."
    }
    if (-not [string]::IsNullOrEmpty($ExpectedRunId) -and -not [System.StringComparer]::Ordinal.Equals([string]$state.runId, $ExpectedRunId)) {
        throw "Release state belongs to run '$($state.runId)', expected '$ExpectedRunId'."
    }
    if ($PSBoundParameters.ContainsKey('ExpectedNotes') -and
        -not [System.StringComparer]::Ordinal.Equals((Get-LowercaseTextSha256 -Text $ExpectedNotes), [string]$state.notesSha256)) {
        throw "Release state notes digest does not match the current release notes."
    }
    if (-not [string]::IsNullOrEmpty($ExpectedManifestSha256) -and
        -not [System.StringComparer]::Ordinal.Equals([string]$state.manifestSha256, $ExpectedManifestSha256)) {
        throw "Release state manifest digest does not match the validated package tree."
    }
    return $parsed
}

function Assert-ReleaseProtocolIdentity {
    param(
        [object]$Release,
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [string]$ExpectedPhase,
        [AllowEmptyString()][string]$ExpectedRunId,
        [AllowEmptyString()][string]$ExpectedNotes,
        [AllowEmptyString()][string]$ExpectedManifestSha256
    )

    if ($null -eq $Release) {
        throw "Release marker $ExpectedTag does not exist."
    }
    if (-not [bool]$Release.draft) {
        throw "Release $ExpectedTag is already published; marketplace replay is forbidden."
    }
    if ([bool]$Release.immutable) {
        throw "Draft release $ExpectedTag unexpectedly reports immutable state."
    }
    return Assert-ReleaseMarkerIdentity @PSBoundParameters
}

function Assert-ReleaseStartState {
    param(
        [AllowNull()][object]$Release,
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [string]$ExpectedNotes
    )

    if ($null -eq $Release) {
        return 'fresh'
    }
    $parsed = Assert-ReleaseProtocolIdentity `
        -Release $Release `
        -Repository $Repository `
        -ExpectedTag $ExpectedTag `
        -ExpectedCommitSha $ExpectedCommitSha `
        -ExpectedPhase 'prepared' `
        -ExpectedNotes $ExpectedNotes
    Assert-ExactAssetSet -Release $Release -ExpectedNames @()
    return "prepared:$($parsed.State.runId)"
}

function Assert-PublishedProtocolIdentity {
    param(
        [object]$Release,
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [AllowEmptyString()][string]$ExpectedRunId,
        [string]$ExpectedNotes,
        [string]$ExpectedManifestSha256
    )

    Assert-PublishedImmutableRelease -Release $Release -ExpectedTag $ExpectedTag
    if (-not [System.StringComparer]::Ordinal.Equals([string]$Release.name, $ExpectedTag)) {
        throw "Published release title does not match the release transaction."
    }
    $parsed = Assert-ReleaseMarkerIdentity `
        -Release $Release `
        -Repository $Repository `
        -ExpectedTag $ExpectedTag `
        -ExpectedCommitSha $ExpectedCommitSha `
        -ExpectedPhase 'marketplace-started' `
        -ExpectedRunId $ExpectedRunId `
        -ExpectedNotes $ExpectedNotes `
        -ExpectedManifestSha256 $ExpectedManifestSha256
    $state = $parsed.State
    if (-not [System.StringComparer]::Ordinal.Equals([string]$state.phase, 'marketplace-started')) {
        throw "Published release state marker does not match the expected transaction."
    }
    return $parsed
}

function Assert-ReleaseAssetSubsetMatchesLocalFiles {
    param(
        [object]$Release,
        [hashtable]$LocalFiles
    )

    $expectedNames = @($LocalFiles.Keys)
    $actualNames = @(Get-ReleaseAssetNames -Release $Release)
    [void](Get-OrdinalStringSet -Values $actualNames)
    foreach ($name in $actualNames) {
        if (-not (Test-ContainsOrdinal -Values $expectedNames -Expected $name)) {
            throw "Release contains unexpected asset '$name'."
        }
        $asset = @($Release.assets | Where-Object { [System.StringComparer]::Ordinal.Equals([string]$_.name, $name) })[0]
        $path = $LocalFiles[$name]
        if (-not [System.StringComparer]::Ordinal.Equals([string]$asset.state, 'uploaded')) {
            throw "Draft asset $name is in state '$($asset.state)', expected 'uploaded'."
        }
        $expectedSize = (Get-Item -LiteralPath $path).Length
        if ([long]$asset.size -ne $expectedSize) {
            throw "Draft asset $name size is $($asset.size), expected $expectedSize."
        }
        $expectedDigest = "sha256:$(Get-LowercaseFileSha256 -Path $path)"
        if (-not [System.StringComparer]::Ordinal.Equals([string]$asset.digest, $expectedDigest)) {
            throw "Draft asset $name digest is '$($asset.digest)', expected '$expectedDigest'."
        }
    }
}

function Assert-PublishedImmutableRelease {
    param(
        [object]$Release,
        [string]$ExpectedTag
    )

    Assert-ReleaseCoreState -Release $Release -ExpectedTag $ExpectedTag
    if ([bool]$Release.draft) {
        throw "Release $ExpectedTag is still a draft."
    }
    if (-not [bool]$Release.immutable) {
        throw "Published release $ExpectedTag is not immutable."
    }
    Assert-ExactAssetSet -Release $Release -ExpectedNames (Get-ExpectedReleaseAssetNames -ExpectedTag $ExpectedTag)
}

function Get-LowercaseFileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-DraftAssetsMatchLocalFiles {
    param(
        [object]$Release,
        [string]$ExpectedTag,
        [string]$ArchivePath,
        [string]$ReleaseJsonPath
    )

    Assert-DraftRelease -Release $Release -ExpectedTag $ExpectedTag -ExpectedAssets (Get-ExpectedReleaseAssetNames -ExpectedTag $ExpectedTag)
    $localFiles = @{
        "StatsPro-$ExpectedTag.zip" = $ArchivePath
        "release.json"              = $ReleaseJsonPath
    }
    foreach ($asset in @($Release.assets)) {
        $name = [string]$asset.name
        $path = $localFiles[$name]
        if (-not [System.StringComparer]::Ordinal.Equals([string]$asset.state, "uploaded")) {
            throw "Draft asset $name is in state '$($asset.state)', expected 'uploaded'."
        }
        $expectedSize = (Get-Item -LiteralPath $path).Length
        if ([long]$asset.size -ne $expectedSize) {
            throw "Draft asset $name size is $($asset.size), expected $expectedSize."
        }
        $expectedDigest = "sha256:$(Get-LowercaseFileSha256 -Path $path)"
        if (-not [System.StringComparer]::Ordinal.Equals([string]$asset.digest, $expectedDigest)) {
            throw "Draft asset $name digest is '$($asset.digest)', expected '$expectedDigest'."
        }
    }
}

function Invoke-GitHubMutationAndAttest {
    param(
        [string]$Description,
        [string[]]$Arguments,
        [string]$Repository,
        [string]$ExpectedTag,
        [int]$Attempts,
        [scriptblock]$AssertState,
        [scriptblock]$Mutate = $null,
        [scriptblock]$GetRelease = $null,
        [scriptblock]$Wait = $null
    )

    if ($null -eq $Mutate) {
        $Mutate = { param([string[]]$GhArguments) [void](Invoke-Gh -Arguments $GhArguments) }
    }
    $mutationError = $null
    try {
        & $Mutate $Arguments
    }
    catch {
        $mutationError = $_
    }
    try {
        $release = Wait-GitHubReleaseState `
            -Repository $Repository `
            -ExpectedTag $ExpectedTag `
            -Attempts $Attempts `
            -AssertState $AssertState `
            -GetRelease $GetRelease `
            -Wait $Wait
    }
    catch {
        if ($null -ne $mutationError) {
            throw "$Description returned an error and the desired state was not observed: $($mutationError.Exception.Message); attestation: $($_.Exception.Message)"
        }
        throw
    }
    if ($null -ne $mutationError) {
        Write-Warning "$Description returned an ambiguous error, but read-only attestation confirmed the desired state: $($mutationError.Exception.Message)"
    }
    return $release
}

function Invoke-BoundedReadOnlyCheck {
    param(
        [string]$Description,
        [int]$Attempts,
        [scriptblock]$Check,
        [scriptblock]$Wait = $null
    )

    if ($Attempts -lt 1) {
        throw "$Description attempts must be at least 1."
    }
    if ($null -eq $Wait) {
        $Wait = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
    }
    $lastError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            & $Check
            return
        }
        catch {
            $lastError = $_
            if ($attempt -lt $Attempts) {
                & $Wait ([Math]::Min(30, 5 * $attempt))
            }
        }
    }
    throw "$Description did not pass after $Attempts attempt(s): $($lastError.Exception.Message)"
}

function Resolve-RequiredFile {
    param(
        [string]$Path,
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing $Description file: '$Path'."
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-ReleaseAssetPaths {
    param(
        [string]$ArchivePath,
        [string]$ReleaseJsonPath,
        [string]$ExpectedTag
    )

    $archive = Resolve-RequiredFile -Path $ArchivePath -Description "StatsPro archive"
    $releaseJson = Resolve-RequiredFile -Path $ReleaseJsonPath -Description "release.json"
    if (-not [System.StringComparer]::Ordinal.Equals([System.IO.Path]::GetFileName($archive), "StatsPro-$ExpectedTag.zip")) {
        throw "Archive filename must be StatsPro-$ExpectedTag.zip."
    }
    if (-not [System.StringComparer]::Ordinal.Equals([System.IO.Path]::GetFileName($releaseJson), "release.json")) {
        throw "Release metadata filename must be release.json."
    }
    return [pscustomobject]@{
        Archive     = $archive
        ReleaseJson = $releaseJson
    }
}

function Assert-ReleaseAttestationCommit {
    param(
        [object]$Attestation,
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha
    )

    Assert-CommitSha $ExpectedCommitSha
    $expectedUri = "pkg:github/$Repository@$ExpectedTag"
    $subjects = @(
        @($Attestation) |
            ForEach-Object { @($_.verificationResult.statement.subject) } |
            Where-Object { [string]$_.uri -eq $expectedUri }
    )
    if ($subjects.Count -ne 1) {
        throw "Release attestation must contain exactly one subject URI $expectedUri; found $($subjects.Count)."
    }
    $attestedCommit = [string]$subjects[0].digest.sha1
    if ($attestedCommit -ne $ExpectedCommitSha) {
        throw "Release attestation commit is '$attestedCommit', expected '$ExpectedCommitSha'."
    }
}

function Invoke-ImmutableReleaseAttestationChecks {
    param(
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [string]$ArchivePath,
        [string]$ReleaseJsonPath
    )

    $attestationJson = (Invoke-Gh -Arguments @("release", "verify", $ExpectedTag, "--repo", $Repository, "--format", "json")) -join "`n"
    Assert-ReleaseAttestationCommit `
        -Attestation (ConvertFrom-JsonCompat $attestationJson) `
        -Repository $Repository `
        -ExpectedTag $ExpectedTag `
        -ExpectedCommitSha $ExpectedCommitSha
    [void](Invoke-Gh -Arguments @("release", "verify-asset", $ExpectedTag, $ArchivePath, "--repo", $Repository))
    [void](Invoke-Gh -Arguments @("release", "verify-asset", $ExpectedTag, $ReleaseJsonPath, "--repo", $Repository))
}

function Get-WorkflowJobBlock {
    param([string]$WorkflowText, [string]$JobName)

    $escapedName = [regex]::Escape($JobName)
    $jobBlock = [regex]::Match(
        $WorkflowText,
        "(?ms)^  ${escapedName}:\s*$.*?(?=^  [A-Za-z0-9_-]+:\s*$|\z)"
    )
    if (-not $jobBlock.Success) {
        throw "Workflow is missing job '$JobName'."
    }
    return $jobBlock
}

function Get-WorkflowStepName {
    param([System.Text.RegularExpressions.Match]$StepBlock)

    $name = [regex]::Match($StepBlock.Value, '(?m)^\s{6}- name:\s*(.+?)\s*$')
    if (-not $name.Success) {
        throw "Could not resolve a workflow step name."
    }
    return $name.Groups[1].Value
}

function Assert-WorkflowParameterBinding {
    param(
        [System.Text.RegularExpressions.Match]$StepBlock,
        [string]$StepName,
        [string]$ParameterName,
        [string]$ValuePattern
    )

    $pattern = "(?m)^\s+-$([regex]::Escape($ParameterName))\s+$ValuePattern(?:\s+\x60)?\s*`$"
    if ([regex]::Matches($StepBlock.Value, $pattern).Count -ne 1) {
        throw "Workflow step '$StepName' must bind -$ParameterName exactly once."
    }
}

function Test-ContainsSecretReference {
    param([string]$Text, [string]$SecretName)

    $escapedSecretName = [regex]::Escape($SecretName)
    $pattern = @'
(?ix)
\bsecrets\s*(?:\.\s*__SECRET__\b|\[\s*['"]\s*__SECRET__\s*['"]\s*\])
'@
    return $Text -match $pattern.Replace('__SECRET__', $escapedSecretName)
}

function Test-ContainsGitHubTokenReference {
    param([string]$Text)

    return (Test-ContainsSecretReference -Text $Text -SecretName 'GITHUB_TOKEN') -or
        $Text -match @'
(?ix)
\bgithub\s*(?:\.\s*token\b|\[\s*['"]\s*token\s*['"]\s*\])
'@
}

function Test-ContainsPrivilegedReleaseTokenReference {
    param([string]$Text)

    return (Test-ContainsGitHubTokenReference -Text $Text) -or
        (Test-ContainsSecretReference -Text $Text -SecretName 'IMMUTABLE_RELEASES_READ_TOKEN')
}

function Assert-WorkflowCheckoutCredentialBoundary {
    param(
        [string]$WorkflowText,
        [string[]]$JobNames
    )

    foreach ($jobName in $JobNames) {
        $jobBlock = Get-WorkflowJobBlock -WorkflowText $WorkflowText -JobName $jobName
        $stepBlocks = @([regex]::Matches($jobBlock.Value, '(?ms)^\s{6}- name: .+?\s*$.*?(?=^\s{6}- name:|\z)'))
        $checkoutSteps = @($stepBlocks | Where-Object {
            $_.Value -match '(?m)^\s{8}uses:\s*actions/checkout@[0-9a-f]{40}\s*$'
        })
        if ($checkoutSteps.Count -ne 1) {
            throw "Workflow job '$jobName' must contain exactly one SHA-pinned checkout step."
        }

        $checkoutStep = $checkoutSteps[0]
        $fetchDepth = @([regex]::Matches($checkoutStep.Value, '(?m)^\s{10}fetch-depth:\s*(.*?)\s*$'))
        if ($fetchDepth.Count -ne 1 -or $fetchDepth[0].Groups[1].Value -ne '0') {
            throw "Workflow job '$jobName' checkout must preserve full history with fetch-depth: 0."
        }
        $persistCredentials = @([regex]::Matches($checkoutStep.Value, '(?m)^\s{10}persist-credentials:\s*(.*?)\s*$'))
        if ($persistCredentials.Count -ne 1 -or $persistCredentials[0].Groups[1].Value -ne 'false') {
            throw "Workflow job '$jobName' checkout must contain exactly one literal persist-credentials: false."
        }
        if ($checkoutStep.Value -match '(?m)^\s{10}(?:token|ssh-key):' -or
            (Test-ContainsPrivilegedReleaseTokenReference -Text $checkoutStep.Value)) {
            throw "Workflow job '$jobName' checkout must not receive explicit credentials."
        }

        $checkoutOrdinal = -1
        for ($index = 0; $index -lt $stepBlocks.Count; $index++) {
            if ($stepBlocks[$index].Index -eq $checkoutStep.Index) {
                $checkoutOrdinal = $index
                break
            }
        }
        if ($checkoutOrdinal -lt 0 -or $checkoutOrdinal + 1 -ge $stepBlocks.Count) {
            throw "Workflow job '$jobName' must verify checkout credentials immediately after checkout."
        }
        $verificationStep = $stepBlocks[$checkoutOrdinal + 1]
        if ((Get-WorkflowStepName -StepBlock $verificationStep) -ne 'Verify anonymous checkout boundary' -or
            $verificationStep.Value -notmatch '(?m)^\s{8}shell:\s*pwsh\s*$' -or
            $verificationStep.Value -notmatch '(?m)^\s{8}run:\s*[.\\/]+scripts[\\/]check-anonymous-checkout\.ps1\s*$') {
            throw "Workflow job '$jobName' must verify checkout credentials immediately after checkout."
        }
    }
}

function Assert-ReleaseGitHubTokenScope {
    param([string]$WorkflowText)

    $allowedStepTokens = [ordered]@{
        'Check release version' = 'GITHUB_TOKEN'
        'Validate interrupted release state' = 'GITHUB_TOKEN'
        'Verify immutable release policy' = 'IMMUTABLE_RELEASES_READ_TOKEN'
        'Prepare resumable draft release' = 'GITHUB_TOKEN'
        'Mark marketplace publication started' = 'GITHUB_TOKEN'
        'Attach validated assets to draft' = 'GITHUB_TOKEN'
        'Publish immutable GitHub release' = 'GITHUB_TOKEN'
        'Validate published immutable release assets' = 'GITHUB_TOKEN'
    }
    $stepBlocks = @([regex]::Matches($WorkflowText, '(?ms)^\s{6}- name: .+?\s*$.*?(?=^\s{6}- name:|\z)'))
    $allowedBlocks = [System.Collections.Generic.List[System.Text.RegularExpressions.Match]]::new()

    foreach ($allowedName in $allowedStepTokens.Keys) {
        $matchingBlocks = @($stepBlocks | Where-Object {
            (Get-WorkflowStepName -StepBlock $_) -eq $allowedName
        })
        if ($matchingBlocks.Count -ne 1) {
            throw "Release workflow must contain exactly one GitHub-management step '$allowedName'."
        }
        $block = $matchingBlocks[0]
        $expectedSecretName = [string]$allowedStepTokens[$allowedName]
        $escapedSecretName = [regex]::Escape($expectedSecretName)
        $tokenLines = @([regex]::Matches(
            $block.Value,
            "(?m)^\s{10}GH_TOKEN:\s*\`$\{\{\s*secrets\.${escapedSecretName}\s*\}\}\s*`$"
        ))
        $blockWithoutCanonicalToken = if ($tokenLines.Count -eq 1) {
            $block.Value.Remove($tokenLines[0].Index, $tokenLines[0].Length)
        }
        else {
            $block.Value
        }
        if ($tokenLines.Count -ne 1 -or
            $block.Value -match '(?m)^\s{10}(?:GITHUB_TOKEN|GITHUB_OAUTH):' -or
            (Test-ContainsPrivilegedReleaseTokenReference -Text $blockWithoutCanonicalToken) -or
            $block.Value -match '(?m)^\s{8}uses:') {
            throw "Privileged GitHub token must use the expected step-local GH_TOKEN source in '$allowedName'."
        }
        $allowedBlocks.Add($block)
    }

    $outsideAllowedSteps = $WorkflowText
    foreach ($block in @($allowedBlocks | Sort-Object Index -Descending)) {
        $outsideAllowedSteps = $outsideAllowedSteps.Remove($block.Index, $block.Length)
    }
    if ((Test-ContainsPrivilegedReleaseTokenReference -Text $outsideAllowedSteps) -or
        $outsideAllowedSteps -match '(?m)^\s*(?:GH_TOKEN|GITHUB_TOKEN|GITHUB_OAUTH):') {
        throw "Privileged GitHub token must not be exposed outside its approved shell step."
    }
}

function Test-ContainsMarketplaceTokenReference {
    param([string]$Text)

    foreach ($secretName in @('CF_API_KEY', 'WAGO_API_TOKEN', 'WOWI_API_TOKEN')) {
        if (Test-ContainsSecretReference -Text $Text -SecretName $secretName) {
            return $true
        }
    }
    return $false
}

function Assert-CanonicalMarketplaceEnvironment {
    param(
        [System.Text.RegularExpressions.Match]$StepBlock,
        [string]$StepName
    )

    $expectedNames = @('CF_API_KEY', 'WAGO_API_TOKEN', 'WOWI_API_TOKEN')
    $actualNames = @(
        [regex]::Matches($StepBlock.Value, '(?m)^\s{10}([A-Z][A-Z0-9_]+):') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object
    )
    if ($actualNames.Count -ne $expectedNames.Count -or
        (Compare-Object -ReferenceObject ($expectedNames | Sort-Object) -DifferenceObject $actualNames)) {
        throw "Marketplace step '$StepName' must expose exactly the three marketplace token environment keys."
    }

    $withoutCanonicalReferences = $StepBlock.Value
    foreach ($name in $expectedNames) {
        $linePattern = "(?m)^\s{10}${name}:\s*\`$\{\{\s*secrets\.${name}\s*\}\}\s*`$"
        $lines = @([regex]::Matches($withoutCanonicalReferences, $linePattern))
        if ($lines.Count -ne 1) {
            throw "Marketplace step '$StepName' must bind $name exactly once to secrets.$name."
        }
        $withoutCanonicalReferences = $withoutCanonicalReferences.Remove($lines[0].Index, $lines[0].Length)
    }
    if (Test-ContainsMarketplaceTokenReference -Text $withoutCanonicalReferences) {
        throw "Marketplace step '$StepName' contains a non-canonical marketplace secret reference."
    }
}

function Assert-ReleaseMarketplaceTokenScope {
    param([string]$WorkflowText)

    $allowedStepNames = @(
        'Verify marketplace release credentials and versions',
        'Publish package to marketplaces'
    )
    $stepBlocks = @([regex]::Matches($WorkflowText, '(?ms)^\s{6}- name: .+?\s*$.*?(?=^\s{6}- name:|\z)'))
    $allowedBlocks = [System.Collections.Generic.List[System.Text.RegularExpressions.Match]]::new()
    foreach ($stepName in $allowedStepNames) {
        $matches = @($stepBlocks | Where-Object { (Get-WorkflowStepName -StepBlock $_) -eq $stepName })
        if ($matches.Count -ne 1) {
            throw "Release workflow must contain exactly one marketplace step '$stepName'."
        }
        Assert-CanonicalMarketplaceEnvironment -StepBlock $matches[0] -StepName $stepName
        $allowedBlocks.Add($matches[0])
    }

    $outsideAllowedSteps = $WorkflowText
    foreach ($block in @($allowedBlocks | Sort-Object Index -Descending)) {
        $outsideAllowedSteps = $outsideAllowedSteps.Remove($block.Index, $block.Length)
    }
    if ((Test-ContainsMarketplaceTokenReference -Text $outsideAllowedSteps) -or
        $outsideAllowedSteps -match '(?m)^\s*(?:CF_API_KEY|WAGO_API_TOKEN|WOWI_API_TOKEN):') {
        throw "Marketplace tokens must not be exposed outside the approved preflight and publishing steps."
    }
}

function Assert-MarketplaceCredentialWorkflowBoundary {
    param([string]$WorkflowText)

    Assert-WorkflowCheckoutCredentialBoundary -WorkflowText $WorkflowText -JobNames @('preflight')

    $triggerBlock = [regex]::Match($WorkflowText, '(?ms)^on:\s*$.*?(?=^permissions:\s*$)')
    $normalizedTrigger = if ($triggerBlock.Success) {
        ($triggerBlock.Value -replace "`r", '').Trim()
    }
    else {
        ''
    }
    if ($normalizedTrigger -ne "on:`n  workflow_dispatch:") {
        throw "Marketplace credential workflow must be manual workflow_dispatch only."
    }
    $permissionsBlock = [regex]::Match($WorkflowText, '(?ms)^permissions:\s*$.*?(?=^jobs:\s*$)')
    $normalizedPermissions = if ($permissionsBlock.Success) {
        ($permissionsBlock.Value -replace "`r", '').Trim()
    }
    else {
        ''
    }
    if ($normalizedPermissions -ne "permissions:`n  contents: read") {
        throw "Marketplace credential workflow must have contents: read as its only permission."
    }
    if ($WorkflowText -match 'BigWigsMods/packager@' -or
        $WorkflowText -match '(?i)manage-github-release\.ps1.+CreateDraft' -or
        $WorkflowText -match '(?m)^\s+args:\s*.*(?:^|\s)-o(?:\s|$)') {
        throw "Marketplace credential workflow must not execute Packager, draft creation, or upload commands."
    }

    $stepBlocks = @([regex]::Matches($WorkflowText, '(?ms)^\s{6}- name: .+?\s*$.*?(?=^\s{6}- name:|\z)'))
    $credentialSteps = @($stepBlocks | Where-Object {
        (Get-WorkflowStepName -StepBlock $_) -eq 'Verify marketplace release credentials and versions'
    })
    if ($credentialSteps.Count -ne 1) {
        throw "Marketplace credential workflow must contain exactly one credential preflight step."
    }
    $credentialStep = $credentialSteps[0]
    Assert-CanonicalMarketplaceEnvironment `
        -StepBlock $credentialStep `
        -StepName 'Verify marketplace release credentials and versions'
    if ($credentialStep.Value -notmatch '(?m)^\s{8}shell:\s*pwsh\s*$' -or
        $credentialStep.Value -notmatch '(?m)^\s{8}run:\s*\./scripts/check-marketplace-versions\.ps1\s*$' -or
        $credentialStep.Value -match '(?m)^\s{8}(?:if|continue-on-error|uses):') {
        throw "Marketplace credential workflow must execute the exact mandatory pwsh checker."
    }

    $outsideCredentialStep = $WorkflowText.Remove($credentialStep.Index, $credentialStep.Length)
    if ((Test-ContainsMarketplaceTokenReference -Text $outsideCredentialStep) -or
        $outsideCredentialStep -match '(?m)^\s*(?:CF_API_KEY|WAGO_API_TOKEN|WOWI_API_TOKEN):') {
        throw "Marketplace credential workflow tokens must be scoped to its checker step."
    }
}

function Assert-ReleaseWorkflowBoundary {
    param([string]$WorkflowText)

    Assert-WorkflowCheckoutCredentialBoundary `
        -WorkflowText $WorkflowText `
        -JobNames @('preflight', 'release')
    Assert-ReleaseGitHubTokenScope -WorkflowText $WorkflowText
    Assert-ReleaseMarketplaceTokenScope -WorkflowText $WorkflowText

    $preflightJob = Get-WorkflowJobBlock -WorkflowText $WorkflowText -JobName 'preflight'
    if ($preflightJob.Value -notmatch '(?m)^    permissions:\s*\r?\n      contents: read\s*$') {
        throw "Release preflight must have contents: read as its only permission."
    }
    $preflightSteps = @([regex]::Matches($preflightJob.Value, "(?ms)^\s{6}- name: .+?\s*$.*?(?=^\s{6}- name:|\z)"))
    $releaseVersionSteps = @($preflightSteps | Where-Object {
        (Get-WorkflowStepName -StepBlock $_) -eq 'Check release version'
    })
    if ($releaseVersionSteps.Count -ne 1 -or
        $releaseVersionSteps[0].Value -notmatch '(?m)^\s{8}run:\s*\.\\scripts\\check-release-version\.ps1 -Tag \$env:GITHUB_REF_NAME -EnforceSemVer -VerifyPublishedChangelog -Repository \$env:GITHUB_REPOSITORY\s*$') {
        throw "Release preflight must verify published changelog parity before publication."
    }

    $releaseJob = Get-WorkflowJobBlock -WorkflowText $WorkflowText -JobName 'release'
    if ($releaseJob.Value -notmatch '(?m)^    needs: preflight\s*$') {
        throw "Release publication must depend on the read-only preflight job."
    }

    $orderedSteps = @(
        "- name: Trim release changelog",
        "- name: Validate interrupted release state",
        "- name: Verify immutable release policy",
        "- name: Verify marketplace release credentials and versions",
        "- name: Recheck release ancestry before final package build",
        "- name: Rebuild package without publishing",
        "- name: Compare rebuilt package and validate again",
        "- name: Validate exact package immediately before marketplace upload",
        "- name: Prepare resumable draft release",
        "- name: Mark marketplace publication started",
        "- name: Publish package to marketplaces",
        "- name: Validate marketplace archive and create release metadata",
        "- name: Attach validated assets to draft",
        "- name: Publish immutable GitHub release",
        "- name: Validate published immutable release assets"
    )

    $concurrencyBlock = [regex]::Match($WorkflowText, "(?ms)^concurrency:\s*$.*?(?=^jobs:\s*$)")
    if (-not $concurrencyBlock.Success -or
        $concurrencyBlock.Value -notmatch "(?m)^  group: statspro-release-publication\s*$" -or
        $concurrencyBlock.Value -notmatch "(?m)^  queue: max\s*$") {
        throw "Release workflow must use the shared statspro-release-publication queue with queue: max."
    }
    if ($concurrencyBlock.Value -match "(?m)^\s+cancel-in-progress:") {
        throw "Release publication concurrency must not cancel in-progress runs."
    }
    $previousIndex = -1
    foreach ($step in $orderedSteps) {
        $index = $WorkflowText.IndexOf($step, [System.StringComparison]::Ordinal)
        if ($index -lt 0) {
            throw "Release workflow is missing required step '$step'."
        }
        if ($index -le $previousIndex) {
            throw "Release workflow step '$step' is out of the required draft-first order."
        }
        $previousIndex = $index
    }

    $stepBlocks = @([regex]::Matches($WorkflowText, "(?ms)^\s{6}- name: .+?\s*$.*?(?=^\s{6}- name:|\z)"))
    $policySteps = @($stepBlocks | Where-Object {
        (Get-WorkflowStepName -StepBlock $_) -eq 'Verify immutable release policy'
    })
    if ($policySteps.Count -ne 1) {
        throw "Release workflow must contain exactly one immutable release policy gate."
    }
    $policyStep = $policySteps[0]
    if ($policyStep.Value -notmatch '(?m)^\s{8}shell:\s*pwsh\s*$' -or
        $policyStep.Value -notmatch '(?m)^\s{8}run:\s*\./scripts/check-repository-settings\.ps1 -Repository \$env:GITHUB_REPOSITORY -ImmutableReleasePolicyOnly -RequireExplicitToken\s*$') {
        throw "Immutable release policy gate must execute the exact fail-closed read-only checker."
    }
    $startStateSteps = @($stepBlocks | Where-Object {
        (Get-WorkflowStepName -StepBlock $_) -eq 'Validate interrupted release state'
    })
    if ($startStateSteps.Count -ne 1 -or $startStateSteps[0].Index + $startStateSteps[0].Length -ne $policyStep.Index) {
        throw "Immutable release policy gate must run immediately after validating interrupted release state."
    }
    $startStateStep = $startStateSteps[0]
    $trimSteps = @($stepBlocks | Where-Object {
        (Get-WorkflowStepName -StepBlock $_) -eq 'Trim release changelog'
    })
    if ($trimSteps.Count -ne 1 -or
        $trimSteps[0].Index + $trimSteps[0].Length -ne $startStateStep.Index -or
        $trimSteps[0].Value -notmatch '(?m)^\s{8}run:\s*\./scripts/check-release-version\.ps1 -Tag \$env:GITHUB_REF_NAME -EnforceSemVer -ExportTopChangelogPath CHANGELOG\.md\s*$') {
        throw "Canonical release notes must be prepared immediately before interrupted-state validation."
    }
    foreach ($binding in @(
        [pscustomobject]@{ Name = 'Mode'; Pattern = 'ValidateStart' },
        [pscustomobject]@{ Name = 'Repository'; Pattern = '\$env:GITHUB_REPOSITORY' },
        [pscustomobject]@{ Name = 'ExpectedTag'; Pattern = '\$env:GITHUB_REF_NAME' },
        [pscustomobject]@{ Name = 'ExpectedCommitSha'; Pattern = '\$env:GITHUB_SHA' },
        [pscustomobject]@{ Name = 'NotesPath'; Pattern = 'CHANGELOG\.md' }
    )) {
        Assert-WorkflowParameterBinding -StepBlock $startStateStep -StepName 'Validate interrupted release state' -ParameterName $binding.Name -ValuePattern $binding.Pattern
    }
    if ($startStateStep.Value -match '(?m)^\s{8}(?:if|continue-on-error):') {
        throw "Interrupted release validation must be mandatory."
    }
    $credentialSteps = @($stepBlocks | Where-Object {
        (Get-WorkflowStepName -StepBlock $_) -eq 'Verify marketplace release credentials and versions'
    })
    if ($credentialSteps.Count -ne 1) {
        throw "Release workflow must contain exactly one marketplace credential preflight."
    }
    $credentialStep = $credentialSteps[0]
    if ($credentialStep.Value -notmatch '(?m)^\s{8}shell:\s*pwsh\s*$' -or
        $credentialStep.Value -notmatch '(?m)^\s{8}run:\s*\./scripts/check-marketplace-versions\.ps1\s*$' -or
        $credentialStep.Value -match '(?m)^\s{8}(?:if|continue-on-error|uses):') {
        throw "Marketplace credential preflight must execute the exact fail-closed checker as a mandatory pwsh step."
    }
    if ($policyStep.Index + $policyStep.Length -ne $credentialStep.Index) {
        throw "Marketplace credential preflight must run immediately after the immutable release policy gate."
    }
    $allPackagerSteps = @($stepBlocks | Where-Object { $_.Value -match 'BigWigsMods/packager@' })
    if ($allPackagerSteps.Count -eq 0 -or @($allPackagerSteps | Where-Object { $_.Index -lt $policyStep.Index }).Count -ne 0) {
        throw "Immutable release policy gate must run before every Packager step."
    }
    if (@($allPackagerSteps | Where-Object { $_.Index -lt $credentialStep.Index }).Count -ne 0) {
        throw "Marketplace credential preflight must run before every Packager step."
    }
    $packagerOutputContracts = @(
        [pscustomobject]@{
            PackagerName = "Build package without publishing"
            ResolverName = "Resolve initial package output"
            ResolverId = "build-package-output"
        },
        [pscustomobject]@{
            PackagerName = "Rebuild package without publishing"
            ResolverName = "Resolve rebuilt package output"
            ResolverId = "rebuild-package-output"
        },
        [pscustomobject]@{
            PackagerName = "Publish package to marketplaces"
            ResolverName = "Resolve published package output"
            ResolverId = "publish-package-output"
        }
    )
    if ($allPackagerSteps.Count -ne $packagerOutputContracts.Count) {
        throw "Release workflow must contain exactly $($packagerOutputContracts.Count) Packager steps; found $($allPackagerSteps.Count)."
    }
    foreach ($contract in $packagerOutputContracts) {
        $packagerMatches = @($allPackagerSteps | Where-Object {
            (Get-WorkflowStepName -StepBlock $_) -eq $contract.PackagerName
        })
        $resolverMatches = @($stepBlocks | Where-Object {
            (Get-WorkflowStepName -StepBlock $_) -eq $contract.ResolverName
        })
        if ($packagerMatches.Count -ne 1 -or $resolverMatches.Count -ne 1) {
            throw "Release workflow must contain one '$($contract.PackagerName)' step and one '$($contract.ResolverName)' step."
        }
        $packagerStep = $packagerMatches[0]
        $resolverStep = $resolverMatches[0]
        if ($packagerStep.Index + $packagerStep.Length -ne $resolverStep.Index -or
            $resolverStep.Value -notmatch "(?m)^\s{8}id: $([regex]::Escape($contract.ResolverId))\s*$" -or
            $resolverStep.Value -notmatch '(?m)^\s{8}shell: pwsh\s*$' -or
            $resolverStep.Value -notmatch '(?m)^\s{8}run: \./scripts/resolve-packager-output\.ps1 -ExpectedTag \$env:GITHUB_REF_NAME -OutputPath \$env:GITHUB_OUTPUT\s*$' -or
            $resolverStep.Value -match '(?m)^\s{8}(?:if|continue-on-error|env|uses|with):') {
            throw "Packager step '$($contract.PackagerName)' must be followed immediately by its exact artifact-output resolver."
        }
    }
    $draftSteps = @($stepBlocks | Where-Object {
        (Get-WorkflowStepName -StepBlock $_) -eq 'Prepare resumable draft release'
    })
    if ($draftSteps.Count -ne 1 -or $draftSteps[0].Index -lt $credentialStep.Index) {
        throw "Marketplace credential preflight must run before the single resumable draft preparation step."
    }
    $publishingPackagerSteps = @($stepBlocks | Where-Object {
        $_.Value -match "BigWigsMods/packager@" -and
        $_.Value -notmatch '(?m)^\s+args:.*(?:^|\s)-d(?:\s|$)'
    })
    if ($publishingPackagerSteps.Count -ne 1) {
        throw "Release workflow must contain exactly one publishing Packager step; found $($publishingPackagerSteps.Count)."
    }
    $marketplaceStep = $publishingPackagerSteps[0]
    if (-not $marketplaceStep.Success) {
        throw "Could not isolate the marketplace Packager step."
    }
    if ($marketplaceStep.Value -notmatch "(?m)^\s{6}- name: Publish package to marketplaces\s*$" -or
        $marketplaceStep.Value -notmatch "(?m)^\s{10}args: -c -e -o\s*$" -or
        $marketplaceStep.Value -notmatch "CF_API_KEY:" -or
        $marketplaceStep.Value -notmatch "WAGO_API_TOKEN:" -or
        $marketplaceStep.Value -notmatch "WOWI_API_TOKEN:") {
        throw "Marketplace publication must be the single named Packager step reusing the validated tree with -c -e -o."
    }

    $ancestryStep = [regex]::Match(
        $WorkflowText,
        "(?ms)^\s{6}- name: Recheck release ancestry before final package build\s*$.*?(?=^\s{6}- name:|\z)"
    )
    if (-not $ancestryStep.Success -or $ancestryStep.Value -notmatch "check-release-ancestry\.ps1") {
        throw "Release workflow must run the executable fresh ancestry gate before the final package build."
    }

    $preUploadStep = [regex]::Match(
        $WorkflowText,
        "(?ms)^\s{6}- name: Validate exact package immediately before marketplace upload\s*$.*?(?=^\s{6}- name:|\z)"
    )
    if (-not $preUploadStep.Success -or
        $preUploadStep.Value -notmatch "check-package-dry-run\.ps1" -or
        $preUploadStep.Value -notmatch '(?m)^\s+-ExpectedTag \$env:GITHUB_REF_NAME\s+\x60\s*$' -or
        $preUploadStep.Value -notmatch '(?m)^\s+-PackagerProjectVersion \$env:STATSPRO_PROJECT_VERSION\s+\x60\s*$' -or
        $preUploadStep.Value -notmatch '(?m)^\s+-CompareManifestPath .+statspro-package-tree\.before\.sha256.+\x60\s*$' -or
        $preUploadStep.Value -notmatch '(?m)^\s+-RequireExactPackagerProjectVersion\s+\x60\s*$' -or
        $preUploadStep.Value -notmatch "git rev-parse HEAD" -or
        $preUploadStep.Value -notmatch "GITHUB_SHA" -or
        $preUploadStep.Value.IndexOf('STATSPRO_ARCHIVE_PATH: ${{ steps.rebuild-package-output.outputs.archive_path }}', [System.StringComparison]::Ordinal) -lt 0 -or
        $preUploadStep.Value.IndexOf('STATSPRO_PROJECT_VERSION: ${{ steps.rebuild-package-output.outputs.project_version }}', [System.StringComparison]::Ordinal) -lt 0) {
        throw "The immediate pre-upload step must bind the exact Packager output, package manifest, tag checkout, and GITHUB_SHA."
    }
    $prepareStep = $draftSteps[0]
    $markStartedSteps = @($stepBlocks | Where-Object {
        (Get-WorkflowStepName -StepBlock $_) -eq 'Mark marketplace publication started'
    })
    if ($markStartedSteps.Count -ne 1) {
        throw "Release workflow must contain exactly one marketplace-started marker step."
    }
    $markStartedStep = $markStartedSteps[0]
    if ($preUploadStep.Index + $preUploadStep.Length -ne $prepareStep.Index -or
        $prepareStep.Index + $prepareStep.Length -ne $markStartedStep.Index -or
        $markStartedStep.Index + $markStartedStep.Length -ne $marketplaceStep.Index) {
        throw "The exact package boundary, resumable draft preparation, and durable marketplace marker must be consecutive immediately before marketplace publication."
    }
    foreach ($contract in @(
        [pscustomobject]@{ Step = $prepareStep; Mode = 'CreateDraft' },
        [pscustomobject]@{ Step = $markStartedStep; Mode = 'MarkMarketplaceStarted' }
    )) {
        foreach ($binding in @(
            [pscustomobject]@{ Name = 'Mode'; Pattern = [regex]::Escape($contract.Mode) },
            [pscustomobject]@{ Name = 'Repository'; Pattern = '\$env:GITHUB_REPOSITORY' },
            [pscustomobject]@{ Name = 'ExpectedTag'; Pattern = '\$env:GITHUB_REF_NAME' },
            [pscustomobject]@{ Name = 'ExpectedCommitSha'; Pattern = '\$env:GITHUB_SHA' },
            [pscustomobject]@{ Name = 'ExpectedRunId'; Pattern = '\$env:GITHUB_RUN_ID' },
            [pscustomobject]@{ Name = 'NotesPath'; Pattern = 'CHANGELOG\.md' },
            [pscustomobject]@{ Name = 'ManifestPath'; Pattern = '\(Join-Path \$env:RUNNER_TEMP "statspro-package-tree\.before\.sha256"\)' }
        )) {
            Assert-WorkflowParameterBinding -StepBlock $contract.Step -StepName $contract.Mode -ParameterName $binding.Name -ValuePattern $binding.Pattern
        }
        if ($contract.Step.Value -match '(?m)^\s{8}(?:if|continue-on-error):') {
            throw "Release transaction step '$($contract.Mode)' must be mandatory."
        }
    }
    foreach ($contract in @(
        [pscustomobject]@{ Name = 'Attach validated assets to draft'; Mode = 'AttachAssets' },
        [pscustomobject]@{ Name = 'Publish immutable GitHub release'; Mode = 'Publish' }
    )) {
        $stepMatches = @($stepBlocks | Where-Object { (Get-WorkflowStepName -StepBlock $_) -eq $contract.Name })
        if ($stepMatches.Count -ne 1) {
            throw "Release workflow must contain exactly one '$($contract.Name)' step."
        }
        foreach ($binding in @(
            [pscustomobject]@{ Name = 'Mode'; Pattern = [regex]::Escape($contract.Mode) },
            [pscustomobject]@{ Name = 'Repository'; Pattern = '\$env:GITHUB_REPOSITORY' },
            [pscustomobject]@{ Name = 'ExpectedTag'; Pattern = '\$env:GITHUB_REF_NAME' },
            [pscustomobject]@{ Name = 'ExpectedCommitSha'; Pattern = '\$env:GITHUB_SHA' },
            [pscustomobject]@{ Name = 'ExpectedRunId'; Pattern = '\$env:GITHUB_RUN_ID' },
            [pscustomobject]@{ Name = 'NotesPath'; Pattern = 'CHANGELOG\.md' },
            [pscustomobject]@{ Name = 'ManifestPath'; Pattern = '\(Join-Path \$env:RUNNER_TEMP "statspro-package-tree\.before\.sha256"\)' }
        )) {
            Assert-WorkflowParameterBinding -StepBlock $stepMatches[0] -StepName $contract.Mode -ParameterName $binding.Name -ValuePattern $binding.Pattern
        }
        if ($stepMatches[0].Value -match '(?m)^\s{8}(?:if|continue-on-error):') {
            throw "Release transaction step '$($contract.Mode)' must be mandatory."
        }
    }
    $actualEnvironmentKeys = @(
        [regex]::Matches($marketplaceStep.Value, "(?m)^\s{10}([A-Z][A-Z0-9_]+):") |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique
    )
    $expectedEnvironmentKeys = @("CF_API_KEY", "WAGO_API_TOKEN", "WOWI_API_TOKEN") | Sort-Object
    if ($actualEnvironmentKeys.Count -ne $expectedEnvironmentKeys.Count -or (Compare-Object -ReferenceObject $expectedEnvironmentKeys -DifferenceObject $actualEnvironmentKeys)) {
        throw "Marketplace Packager environment must contain only marketplace tokens. Found: $($actualEnvironmentKeys -join ', ')"
    }
}

function Get-CreateDraftGhArguments {
    param([string]$Repository, [string]$ExpectedTag, [string]$NotesPath)
    return @(
        "release", "create", $ExpectedTag,
        "--repo", $Repository,
        "--draft",
        "--verify-tag",
        "--title", $ExpectedTag,
        "--notes-file", $NotesPath
    )
}

function Get-EditDraftBodyGhArguments {
    param([string]$Repository, [string]$ExpectedTag, [string]$NotesPath)
    return @("release", "edit", $ExpectedTag, "--repo", $Repository, "--notes-file", $NotesPath)
}

function Get-AttachAssetsGhArguments {
    param([string]$Repository, [string]$ExpectedTag, [string]$AssetPath)
    return @(
        "release", "upload", $ExpectedTag,
        $AssetPath,
        "--repo", $Repository
    )
}

function Get-PublishGhArguments {
    param([string]$Repository, [string]$ExpectedTag)
    return @("release", "edit", $ExpectedTag, "--repo", $Repository, "--draft=false", "--latest")
}

function Get-RetirePreparedGhArguments {
    param([string]$Repository, [string]$ExpectedTag)
    return @("release", "delete", $ExpectedTag, "--repo", $Repository, "--yes")
}

function Invoke-WithTemporaryReleaseBody {
    param(
        [string]$Body,
        [scriptblock]$Action
    )

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-release-body-" + [System.Guid]::NewGuid().ToString('N') + '.md')
    try {
        [System.IO.File]::WriteAllText($path, $Body + "`n", [System.Text.UTF8Encoding]::new($false))
        return & $Action $path
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SelfTest {
    Assert-StatsProReleaseTagContractSelfTest
    foreach ($invalidTag in @("v01.2.3", "V1.2.3", ("v1.2.3" + [char]10))) {
        Assert-ThrowsMatch "release manager rejects noncanonical tag '$invalidTag'" {
            Assert-ReleaseTag -Value $invalidTag
        } "Malformed StatsPro release tag"
    }

    $tag = "v1.2.3"
    $commit = "0123456789abcdef0123456789abcdef01234567"
    $draftEmpty = [pscustomobject]@{
        tag_name = $tag
        draft = $true
        prerelease = $false
        immutable = $false
        assets = @()
    }
    $draftReady = [pscustomobject]@{
        tag_name = $tag
        draft = $true
        prerelease = $false
        immutable = $false
        assets = @(
            [pscustomobject]@{ name = "StatsPro-$tag.zip" },
            [pscustomobject]@{ name = "release.json" }
        )
    }
    $published = [pscustomobject]@{
        tag_name = $tag
        draft = $false
        prerelease = $false
        immutable = $true
        assets = $draftReady.assets
    }

    Assert-NoExistingRelease -Release $null -ExpectedTag $tag
    Assert-DraftRelease -Release $draftEmpty -ExpectedTag $tag -ExpectedAssets @()
    Assert-DraftRelease -Release $draftReady -ExpectedTag $tag -ExpectedAssets (Get-ExpectedReleaseAssetNames -ExpectedTag $tag)
    Assert-PublishedImmutableRelease -Release $published -ExpectedTag $tag

    Assert-ThrowsMatch "existing draft marker rejected" {
        Assert-NoExistingRelease -Release $draftEmpty -ExpectedTag $tag
    } "draft marker"
    Assert-ThrowsMatch "existing published release rejected" {
        Assert-NoExistingRelease -Release $published -ExpectedTag $tag
    } "published release"
    Assert-ThrowsMatch "partial draft assets rejected" {
        $partial = [pscustomobject]@{
            tag_name = $tag
            draft = $true
            prerelease = $false
            immutable = $false
            assets = @([pscustomobject]@{ name = "StatsPro-$tag.zip" })
        }
        Assert-DraftRelease -Release $partial -ExpectedTag $tag -ExpectedAssets (Get-ExpectedReleaseAssetNames -ExpectedTag $tag)
    } "expected"
    Assert-ThrowsMatch "mutable published release rejected" {
        $mutable = $published.PSObject.Copy()
        $mutable.immutable = $false
        Assert-PublishedImmutableRelease -Release $mutable -ExpectedTag $tag
    } "not immutable"
    Assert-ThrowsMatch "prerelease rejected" {
        $prerelease = $published.PSObject.Copy()
        $prerelease.prerelease = $true
        Assert-PublishedImmutableRelease -Release $prerelease -ExpectedTag $tag
    } "must not be a prerelease"

    $eventualLookup = [pscustomobject]@{ Count = 0 }
    $eventualWaits = [System.Collections.Generic.List[int]]::new()
    $eventualDraft = Wait-GitHubReleaseState `
        -Repository "owner/repo" `
        -ExpectedTag $tag `
        -Attempts 3 `
        -AssertState {
            param([object]$Release)
            Assert-DraftRelease -Release $Release -ExpectedTag $tag -ExpectedAssets @()
        } `
        -GetRelease {
            param([string]$Repository, [string]$ExpectedTag)
            $eventualLookup.Count++
            if ($eventualLookup.Count -eq 1) {
                return $null
            }
            return $draftEmpty
        } `
        -Wait {
            param([int]$Seconds)
            $eventualWaits.Add($Seconds)
        }
    if ($eventualDraft -ne $draftEmpty -or $eventualLookup.Count -ne 2 -or
        $eventualWaits.Count -ne 1 -or $eventualWaits[0] -ne 5) {
        throw "Eventual release visibility retry did not preserve the expected state."
    }
    Assert-ThrowsMatch "release visibility exhaustion rejected" {
        [void](Wait-GitHubReleaseState `
            -Repository "owner/repo" `
            -ExpectedTag $tag `
            -Attempts 2 `
            -AssertState {
                param([object]$Release)
                Assert-DraftRelease -Release $Release -ExpectedTag $tag -ExpectedAssets @()
            } `
            -GetRelease { param([string]$Repository, [string]$ExpectedTag) return $null } `
            -Wait { param([int]$Seconds) })
    } "did not converge after 2 attempt"
    Assert-ThrowsMatch "malformed repository rejected" {
        Assert-RepositoryName "missing-owner"
    } "owner/name"

    $listCalls = [System.Collections.Generic.List[string]]::new()
    $listedDraft = Get-GitHubReleaseByTag -Repository "owner/repo" -ExpectedTag $tag -RunGh {
        param([string[]]$Arguments)
        $listCalls.Add(($Arguments -join " ")) | Out-Null
        return @{
            ExitCode = 0
            Output = @('[[{"tag_name":"v1.2.3","draft":true,"prerelease":false,"immutable":false,"assets":[]}],[]]')
        }
    }
    if ($null -eq $listedDraft -or -not $listedDraft.draft) {
        throw "Paginated release lookup must return draft markers."
    }
    if ($listCalls.Count -ne 1 -or $listCalls[0] -notmatch "api --paginate --slurp .*releases\?per_page=100") {
        throw "Release lookup must use the paginated list endpoint so drafts are visible."
    }
    Assert-ThrowsMatch "duplicate release markers rejected" {
        [void](Get-GitHubReleaseByTag -Repository "owner/repo" -ExpectedTag $tag -RunGh {
            param([string[]]$Arguments)
            return @{
                ExitCode = 0
                Output = @('[[{"tag_name":"v1.2.3"},{"tag_name":"v1.2.3"}]]')
            }
        })
    } "multiple"

    Assert-RemoteTagCommit -Repository "owner/repo" -ExpectedTag $tag -ExpectedCommitSha $commit -ResolveTagCommit {
        param([string]$Repository, [string]$ExpectedTag)
        return $commit
    }
    Assert-ThrowsMatch "moved remote tag rejected" {
        Assert-RemoteTagCommit -Repository "owner/repo" -ExpectedTag $tag -ExpectedCommitSha $commit -ResolveTagCommit {
            param([string]$Repository, [string]$ExpectedTag)
            return "fedcba9876543210fedcba9876543210fedcba98"
        }
    } "expected event commit"

    $createArguments = Get-CreateDraftGhArguments -Repository "owner/repo" -ExpectedTag $tag -NotesPath "notes.md"
    if ($createArguments -notcontains "--draft" -or $createArguments -notcontains "--verify-tag" -or $createArguments -contains "--target") {
        throw "CreateDraft gh arguments must create a draft for an existing tag."
    }
    $attachArguments = Get-AttachAssetsGhArguments -Repository "owner/repo" -ExpectedTag $tag -AssetPath "StatsPro-$tag.zip"
    if ($attachArguments -contains "--clobber") {
        throw "AttachAssets gh arguments must never clobber a draft asset."
    }
    $publishArguments = Get-PublishGhArguments -Repository "owner/repo" -ExpectedTag $tag
    if ($publishArguments -notcontains "--draft=false") {
        throw "Publish gh arguments must publish the prepared draft."
    }
    $retireArguments = Get-RetirePreparedGhArguments -Repository "owner/repo" -ExpectedTag $tag
    if ($retireArguments -notcontains "--yes" -or $retireArguments -contains "--cleanup-tag") {
        throw "RetirePrepared must delete only the proven-safe draft and preserve its tag."
    }

    $protocolNotes = "## StatsPro $tag`n`nSafe release notes."
    $protocolManifest = "0123456789abcdef  StatsPro/StatsPro.lua"
    $protocolManifestSha = Get-LowercaseTextSha256 -Text $protocolManifest
    $protocolRunId = '12345'
    $preparedState = Get-ReleaseStateData `
        -Phase 'prepared' `
        -Repository 'owner/repo' `
        -ExpectedTag $tag `
        -ExpectedCommitSha $commit `
        -ExpectedRunId $protocolRunId `
        -NotesSha256 (Get-LowercaseTextSha256 -Text $protocolNotes) `
        -ManifestSha256 $protocolManifestSha
    $preparedBody = Get-ReleaseBody -State $preparedState -CanonicalNotes $protocolNotes
    $newProtocolRelease = {
        param([string]$Phase, [string]$RunId, [object[]]$Assets, [bool]$Draft = $true, [bool]$Immutable = $false)
        $state = Get-ReleaseStateData -Phase $Phase -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedRunId $RunId -NotesSha256 (Get-LowercaseTextSha256 -Text $protocolNotes) -ManifestSha256 $protocolManifestSha
        return [pscustomobject]@{
            tag_name = $tag
            name = $tag
            target_commitish = $commit
            draft = $Draft
            prerelease = $false
            immutable = $Immutable
            body = Get-ReleaseBody -State $state -CanonicalNotes $protocolNotes
            assets = @($Assets)
        }
    }
    $preparedProtocolRelease = & $newProtocolRelease 'prepared' $protocolRunId @()
    $parsedPrepared = Read-ReleaseStateMarker -Body $preparedBody
    if ([string]$parsedPrepared.State.transactionId -ne [string]$preparedState.transactionId -or $parsedPrepared.Notes -ne $protocolNotes) {
        throw "Canonical release marker round trip failed."
    }
    Assert-ThrowsMatch "uppercase release tag rejected" {
        Assert-ReleaseTag 'V1.2.3'
    } "Malformed StatsPro release tag"
    if ($null -ne (Select-GitHubReleaseByTag -Releases @([pscustomobject]@{ tag_name = 'V1.2.3' }) -ExpectedTag $tag)) {
        throw "Release lookup must use ordinal tag identity."
    }
    if ((Assert-ReleaseStartState -Release $null -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes) -ne 'fresh') {
        throw "Absent release must classify as fresh."
    }
    if ((Assert-ReleaseStartState -Release $preparedProtocolRelease -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes) -ne "prepared:$protocolRunId") {
        throw "Exact empty prepared release must be resumable."
    }
    $recoverableProtocolRelease = & $newProtocolRelease 'prepared' '98765' @()
    if ((Assert-ReleaseStartState -Release $recoverableProtocolRelease -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes) -ne 'prepared:98765') {
        throw "A protocol-owned empty prepared release from another run must be safely claimable."
    }
    Assert-ThrowsMatch "marketplace-started interruption rejected" {
        [void](Assert-ReleaseStartState -Release (& $newProtocolRelease 'marketplace-started' $protocolRunId @()) -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes)
    } "phase"
    Assert-ThrowsMatch "prepared release with assets rejected" {
        [void](Assert-ReleaseStartState -Release (& $newProtocolRelease 'prepared' $protocolRunId @([pscustomobject]@{ name = "StatsPro-$tag.zip" })) -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes)
    } "expected"
    Assert-ThrowsMatch "published interruption rejected" {
        [void](Assert-ReleaseStartState -Release (& $newProtocolRelease 'marketplace-started' $protocolRunId @() $false $true) -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes)
    } "already published"
    Assert-ThrowsMatch "duplicate protocol marker rejected" {
        [void](Read-ReleaseStateMarker -Body ($preparedBody + "`n" + (Get-ReleaseStateMarkerLine -State $preparedState)))
    } "exactly one"
    Assert-ThrowsMatch "release notes spoof rejected" {
        [void](Read-ReleaseStateMarker -Body ($preparedBody + 'changed'))
    } "notes"
    $extraJson = ($preparedState | ConvertTo-Json -Compress).TrimEnd('}') + ',"extra":true}'
    Assert-ThrowsMatch "unknown protocol field rejected" {
        [void](Read-ReleaseStateMarker -Body ("<!-- statspro-release-state:$(ConvertTo-Base64Url -Text $extraJson) -->`n`n$protocolNotes"))
    } "exact schema"
    $wrongPhaseJson = ($preparedState | ConvertTo-Json -Compress).Replace('"phase":"prepared"', '"phase":"Prepared"')
    Assert-ThrowsMatch "wrong-case protocol phase rejected" {
        [void](Read-ReleaseStateMarker -Body ("<!-- statspro-release-state:$(ConvertTo-Base64Url -Text $wrongPhaseJson) -->`n`n$protocolNotes"))
    } "unsupported phase"
    $leadingZeroTagState = $preparedState.PSObject.Copy()
    $leadingZeroTagState.tag = 'v01.2.3'
    Assert-ThrowsMatch "leading-zero protocol marker tag rejected" {
        [void](Read-ReleaseStateMarker -Body (Get-ReleaseBody -State $leadingZeroTagState -CanonicalNotes $protocolNotes))
    } "Malformed StatsPro release tag"
    $wrongTransaction = $preparedState.PSObject.Copy()
    $wrongTransaction.transactionId = '0' * 64
    Assert-ThrowsMatch "wrong transaction digest rejected" {
        [void](Read-ReleaseStateMarker -Body (Get-ReleaseBody -State $wrongTransaction -CanonicalNotes $protocolNotes))
    } "transaction ID"
    Assert-ThrowsMatch "wrong protocol owner rejected" {
        [void](Assert-ReleaseProtocolIdentity -Release $preparedProtocolRelease -Repository 'other/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedPhase 'prepared' -ExpectedNotes $protocolNotes)
    } "identity"
    Assert-ThrowsMatch "wrong run owner rejected after claim" {
        [void](Assert-ReleaseProtocolIdentity -Release $preparedProtocolRelease -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedPhase 'prepared' -ExpectedRunId '99999' -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha)
    } "belongs to run"
    Assert-ThrowsMatch "wrong package manifest rejected" {
        [void](Assert-ReleaseProtocolIdentity -Release $preparedProtocolRelease -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedPhase 'prepared' -ExpectedRunId $protocolRunId -ExpectedNotes $protocolNotes -ExpectedManifestSha256 ('f' * 64))
    } "manifest digest"

    $ambiguousCounters = [pscustomobject]@{ Mutations = 0; Reads = 0 }
    [void](Invoke-GitHubMutationAndAttest `
        -Description 'self-test ambiguous mutation' `
        -Arguments @('release', 'edit') `
        -Repository 'owner/repo' `
        -ExpectedTag $tag `
        -Attempts 2 `
        -AssertState { param([object]$Observed) if ($Observed -ne $preparedProtocolRelease) { throw 'not visible' } } `
        -Mutate { param([string[]]$Arguments) $ambiguousCounters.Mutations++; throw 'lost response' } `
        -GetRelease { param([string]$Repository, [string]$ExpectedTag) $ambiguousCounters.Reads++; return $preparedProtocolRelease } `
        -Wait { param([int]$Seconds) })
    if ($ambiguousCounters.Mutations -ne 1 -or $ambiguousCounters.Reads -ne 1) {
        throw "Ambiguous mutation recovery must mutate once and then use read-only attestation."
    }
    $failedMutationCounter = [pscustomobject]@{ Mutations = 0 }
    Assert-ThrowsMatch "unconfirmed ambiguous mutation rejected" {
        [void](Invoke-GitHubMutationAndAttest `
            -Description 'self-test failed mutation' `
            -Arguments @('release', 'edit') `
            -Repository 'owner/repo' `
            -ExpectedTag $tag `
            -Attempts 2 `
            -AssertState { param([AllowNull()][object]$Observed) throw 'not visible' } `
            -Mutate { param([string[]]$Arguments) $failedMutationCounter.Mutations++; throw 'lost response' } `
            -GetRelease { param([string]$Repository, [string]$ExpectedTag) return $null } `
            -Wait { param([int]$Seconds) })
    } "returned an error and the desired state was not observed"
    if ($failedMutationCounter.Mutations -ne 1) {
        throw "Failed ambiguous mutation must not be retried."
    }
    $startedProtocolRelease = & $newProtocolRelease 'marketplace-started' $protocolRunId @()
    foreach ($boundary in @(
        [pscustomobject]@{
            Name = 'draft creation'
            Observed = $preparedProtocolRelease
            Assert = {
                param([object]$Observed)
                [void](Assert-ReleaseProtocolIdentity -Release $Observed -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedPhase 'prepared' -ExpectedRunId $protocolRunId -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha)
                Assert-ExactAssetSet -Release $Observed -ExpectedNames @()
            }
        },
        [pscustomobject]@{
            Name = 'marketplace-started transition'
            Observed = $startedProtocolRelease
            Assert = {
                param([object]$Observed)
                [void](Assert-ReleaseProtocolIdentity -Release $Observed -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedPhase 'marketplace-started' -ExpectedRunId $protocolRunId -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha)
                Assert-ExactAssetSet -Release $Observed -ExpectedNames @()
            }
        },
        [pscustomobject]@{
            Name = 'prepared draft retirement'
            Observed = $null
            Assert = {
                param([AllowNull()][object]$Observed)
                if ($null -ne $Observed) { throw 'draft still visible' }
            }
        }
    )) {
        $boundaryCounters = [pscustomobject]@{ Mutations = 0; Reads = 0 }
        [void](Invoke-GitHubMutationAndAttest `
            -Description "self-test $($boundary.Name)" `
            -Arguments @('release', 'mutation') `
            -Repository 'owner/repo' `
            -ExpectedTag $tag `
            -Attempts 2 `
            -AssertState $boundary.Assert `
            -Mutate { param([string[]]$Arguments) $boundaryCounters.Mutations++; throw 'lost response' } `
            -GetRelease { param([string]$Repository, [string]$ExpectedTag) $boundaryCounters.Reads++; return $boundary.Observed } `
            -Wait { param([int]$Seconds) })
        if ($boundaryCounters.Mutations -ne 1 -or $boundaryCounters.Reads -ne 1) {
            throw "Boundary '$($boundary.Name)' must mutate once and then converge read-only."
        }
    }
    $readOnlyRetry = [pscustomobject]@{ Checks = 0; Waits = 0 }
    Invoke-BoundedReadOnlyCheck `
        -Description 'self-test post-publish attestation' `
        -Attempts 3 `
        -Check {
            $readOnlyRetry.Checks++
            if ($readOnlyRetry.Checks -lt 3) {
                throw 'not visible yet'
            }
        } `
        -Wait { param([int]$Seconds) $readOnlyRetry.Waits++ }
    if ($readOnlyRetry.Checks -ne 3 -or $readOnlyRetry.Waits -ne 2) {
        throw "Post-publish attestation retry must remain bounded and read-only."
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-release-manager-test-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
        $archivePath = Join-Path $tempDir "StatsPro-$tag.zip"
        $releaseJsonPath = Join-Path $tempDir "release.json"
        [System.IO.File]::WriteAllBytes($archivePath, [byte[]](1, 2, 3, 4))
        [System.IO.File]::WriteAllText($releaseJsonPath, '{"releases":[]}', [System.Text.UTF8Encoding]::new($false))
        $draftWithDigests = [pscustomobject]@{
            tag_name = $tag
            draft = $true
            prerelease = $false
            immutable = $false
            assets = @(
                [pscustomobject]@{
                    name = "StatsPro-$tag.zip"
                    state = "uploaded"
                    size = (Get-Item -LiteralPath $archivePath).Length
                    digest = "sha256:$(Get-LowercaseFileSha256 -Path $archivePath)"
                },
                [pscustomobject]@{
                    name = "release.json"
                    state = "uploaded"
                    size = (Get-Item -LiteralPath $releaseJsonPath).Length
                    digest = "sha256:$(Get-LowercaseFileSha256 -Path $releaseJsonPath)"
                }
            )
        }
        Assert-DraftAssetsMatchLocalFiles -Release $draftWithDigests -ExpectedTag $tag -ArchivePath $archivePath -ReleaseJsonPath $releaseJsonPath
        $publishedProtocolRelease = & $newProtocolRelease 'marketplace-started' $protocolRunId @($draftWithDigests.assets) $false $true
        [void](Assert-PublishedProtocolIdentity -Release $publishedProtocolRelease -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedRunId $protocolRunId -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha)
        $localFiles = @{
            "StatsPro-$tag.zip" = $archivePath
            'release.json' = $releaseJsonPath
        }
        $partialProtocol = & $newProtocolRelease 'marketplace-started' $protocolRunId @($draftWithDigests.assets[0])
        Assert-ReleaseAssetSubsetMatchesLocalFiles -Release $partialProtocol -LocalFiles $localFiles
        Assert-ThrowsMatch "partial post-marketplace rerun rejected" {
            [void](Assert-ReleaseStartState -Release $partialProtocol -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes)
        } "phase"
        foreach ($boundary in @(
            [pscustomobject]@{
                Name = 'single asset upload'
                Observed = $partialProtocol
                Assert = {
                    param([object]$Observed)
                    [void](Assert-ReleaseProtocolIdentity -Release $Observed -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedPhase 'marketplace-started' -ExpectedRunId $protocolRunId -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha)
                    Assert-ReleaseAssetSubsetMatchesLocalFiles -Release $Observed -LocalFiles $localFiles
                    if (-not (Test-ContainsOrdinal -Values @(Get-ReleaseAssetNames -Release $Observed) -Expected "StatsPro-$tag.zip")) { throw 'asset missing' }
                }
            },
            [pscustomobject]@{
                Name = 'immutable publish'
                Observed = $publishedProtocolRelease
                Assert = {
                    param([object]$Observed)
                    [void](Assert-PublishedProtocolIdentity -Release $Observed -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedRunId $protocolRunId -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha)
                }
            }
        )) {
            $boundaryCounters = [pscustomobject]@{ Mutations = 0; Reads = 0 }
            [void](Invoke-GitHubMutationAndAttest `
                -Description "self-test $($boundary.Name)" `
                -Arguments @('release', 'mutation') `
                -Repository 'owner/repo' `
                -ExpectedTag $tag `
                -Attempts 2 `
                -AssertState $boundary.Assert `
                -Mutate { param([string[]]$Arguments) $boundaryCounters.Mutations++; throw 'lost response' } `
                -GetRelease { param([string]$Repository, [string]$ExpectedTag) $boundaryCounters.Reads++; return $boundary.Observed } `
                -Wait { param([int]$Seconds) })
            if ($boundaryCounters.Mutations -ne 1 -or $boundaryCounters.Reads -ne 1) {
                throw "Boundary '$($boundary.Name)' must mutate once and then converge read-only."
            }
        }
        foreach ($subset in @(
            @(),
            @($draftWithDigests.assets[1]),
            @($draftWithDigests.assets)
        )) {
            Assert-ReleaseAssetSubsetMatchesLocalFiles -Release (& $newProtocolRelease 'marketplace-started' $protocolRunId $subset) -LocalFiles $localFiles
        }
        Assert-ThrowsMatch "duplicate partial asset rejected" {
            Assert-ReleaseAssetSubsetMatchesLocalFiles -Release (& $newProtocolRelease 'marketplace-started' $protocolRunId @($draftWithDigests.assets[0], $draftWithDigests.assets[0])) -LocalFiles $localFiles
        } "duplicate asset"
        foreach ($mutation in @(
            [pscustomobject]@{ Field = 'state'; Value = 'new'; Pattern = 'state' },
            [pscustomobject]@{ Field = 'size'; Value = 999; Pattern = 'size' },
            [pscustomobject]@{ Field = 'digest'; Value = "sha256:$('0' * 64)"; Pattern = 'digest' }
        )) {
            $badAsset = $draftWithDigests.assets[1].PSObject.Copy()
            $badAsset.($mutation.Field) = $mutation.Value
            Assert-ThrowsMatch "partial asset $($mutation.Field) rejected" {
                Assert-ReleaseAssetSubsetMatchesLocalFiles -Release (& $newProtocolRelease 'marketplace-started' $protocolRunId @($badAsset)) -LocalFiles $localFiles
            } $mutation.Pattern
        }
        $unexpectedProtocol = & $newProtocolRelease 'marketplace-started' $protocolRunId @([pscustomobject]@{ name = 'unexpected.txt'; state = 'uploaded'; size = 1; digest = 'sha256:' + ('0' * 64) })
        Assert-ThrowsMatch "unexpected partial asset rejected" {
            Assert-ReleaseAssetSubsetMatchesLocalFiles -Release $unexpectedProtocol -LocalFiles $localFiles
        } "unexpected asset"
        $wrongCaseProtocol = & $newProtocolRelease 'marketplace-started' $protocolRunId @([pscustomobject]@{
            name = "statspro-$tag.zip"
            state = 'uploaded'
            size = (Get-Item -LiteralPath $archivePath).Length
            digest = "sha256:$(Get-LowercaseFileSha256 -Path $archivePath)"
        })
        Assert-ThrowsMatch "wrong-case partial asset rejected" {
            Assert-ReleaseAssetSubsetMatchesLocalFiles -Release $wrongCaseProtocol -LocalFiles $localFiles
        } "unexpected asset"
        $wrongCaseFull = $draftWithDigests.PSObject.Copy()
        $wrongCaseFull.assets = @($draftWithDigests.assets | ForEach-Object { $_.PSObject.Copy() })
        $wrongCaseFull.assets[0].name = "statspro-$tag.zip"
        Assert-ThrowsMatch "wrong-case exact asset rejected" {
            Assert-DraftAssetsMatchLocalFiles -Release $wrongCaseFull -ExpectedTag $tag -ArchivePath $archivePath -ReleaseJsonPath $releaseJsonPath
        } "expected"
        $wrongCaseArchivePath = Join-Path $tempDir "statspro-$tag.zip"
        [System.IO.File]::WriteAllBytes($wrongCaseArchivePath, [byte[]](1, 2, 3, 4))
        Assert-ThrowsMatch "wrong-case local archive rejected" {
            [void](Assert-ReleaseAssetPaths -ArchivePath $wrongCaseArchivePath -ReleaseJsonPath $releaseJsonPath -ExpectedTag $tag)
        } "Archive filename"
        $swapped = $draftWithDigests.PSObject.Copy()
        $swapped.assets = @($draftWithDigests.assets | ForEach-Object { $_.PSObject.Copy() })
        $swapped.assets[0].digest = "sha256:$('0' * 64)"
        Assert-ThrowsMatch "draft asset swap rejected" {
            Assert-DraftAssetsMatchLocalFiles -Release $swapped -ExpectedTag $tag -ArchivePath $archivePath -ReleaseJsonPath $releaseJsonPath
        } "digest"
        $pending = $draftWithDigests.PSObject.Copy()
        $pending.assets = @($draftWithDigests.assets | ForEach-Object { $_.PSObject.Copy() })
        $pending.assets[1].state = "new"
        Assert-ThrowsMatch "incomplete draft asset rejected" {
            Assert-DraftAssetsMatchLocalFiles -Release $pending -ExpectedTag $tag -ArchivePath $archivePath -ReleaseJsonPath $releaseJsonPath
        } "state"
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $attestation = [pscustomobject]@{
        verificationResult = [pscustomobject]@{
            statement = [pscustomobject]@{
                subject = @([pscustomobject]@{
                    uri = "pkg:github/owner/repo@$tag"
                    digest = [pscustomobject]@{ sha1 = $commit }
                })
            }
        }
    }
    Assert-ReleaseAttestationCommit -Attestation $attestation -Repository "owner/repo" -ExpectedTag $tag -ExpectedCommitSha $commit
    $wrongCommitAttestation = $attestation.PSObject.Copy()
    $wrongCommitAttestation.verificationResult = $attestation.verificationResult.PSObject.Copy()
    $wrongCommitAttestation.verificationResult.statement = $attestation.verificationResult.statement.PSObject.Copy()
    $wrongCommitAttestation.verificationResult.statement.subject = @([pscustomobject]@{
        uri = "pkg:github/owner/repo@$tag"
        digest = [pscustomobject]@{ sha1 = "fedcba9876543210fedcba9876543210fedcba98" }
    })
    Assert-ThrowsMatch "wrong attestation commit rejected" {
        Assert-ReleaseAttestationCommit -Attestation $wrongCommitAttestation -Repository "owner/repo" -ExpectedTag $tag -ExpectedCommitSha $commit
    } "attestation commit"

    $workflowPath = Join-Path (Join-Path $PSScriptRoot "..") ".github\workflows\release.yml"
    $workflowText = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
    Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText
    $checksWorkflowPath = Join-Path (Join-Path $PSScriptRoot "..") ".github\workflows\checks.yml"
    $checksWorkflowText = Get-Content -LiteralPath $checksWorkflowPath -Raw -Encoding UTF8
    Assert-WorkflowCheckoutCredentialBoundary `
        -WorkflowText $checksWorkflowText `
        -JobNames @('checks', 'package-contract')
    $marketplaceWorkflowPath = Join-Path (Join-Path $PSScriptRoot "..") ".github\workflows\marketplace-credential-preflight.yml"
    $marketplaceWorkflowText = Get-Content -LiteralPath $marketplaceWorkflowPath -Raw -Encoding UTF8
    Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText
    Assert-ThrowsMatch "non-manual marketplace credential workflow rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            '  workflow_dispatch:',
            '  push:')
    } "workflow_dispatch only"
    Assert-ThrowsMatch "swapped manual marketplace secret bindings rejected" {
        $mutated = $marketplaceWorkflowText.Replace(
            'secrets.CF_API_KEY',
            'secrets.TEMP_MARKETPLACE_TOKEN').Replace(
                'secrets.WAGO_API_TOKEN',
                'secrets.CF_API_KEY').Replace(
                    'secrets.TEMP_MARKETPLACE_TOKEN',
                    'secrets.WAGO_API_TOKEN')
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $mutated
    } "bind CF_API_KEY|bind WAGO_API_TOKEN|non-canonical"
    Assert-ThrowsMatch "job-level manual marketplace secret rejected" {
        $mutated = $marketplaceWorkflowText.Replace(
            '  preflight:',
            "  preflight:`n    env:`n      WAGO_API_TOKEN: `${{ secrets.WAGO_API_TOKEN }}")
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $mutated
    } "scoped to its checker step"
    Assert-ThrowsMatch "fallible manual marketplace checker rejected" {
        $mutated = $marketplaceWorkflowText.Replace(
            '      - name: Verify marketplace release credentials and versions',
            "      - name: Verify marketplace release credentials and versions`n        continue-on-error: true")
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $mutated
    } "exact mandatory pwsh checker"
    Assert-ThrowsMatch "Packager in manual marketplace workflow rejected" {
        $mutated = $marketplaceWorkflowText.Replace(
            '      - name: Verify marketplace release credentials and versions',
            "      - name: Unexpected Packager`n        uses: BigWigsMods/packager@6d50adb6e8517eefef63f4afb16a6518166a6b28`n        with:`n          args: -d`n`n      - name: Verify marketplace release credentials and versions")
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $mutated
    } "must not execute Packager"
    Assert-ThrowsMatch "manual marketplace self-test substitution rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText ($marketplaceWorkflowText -replace '\./scripts/check-marketplace-versions\.ps1', './scripts/check-marketplace-versions.ps1 -SelfTest')
    } "exact mandatory pwsh checker"

    foreach ($reference in @(
        '${{ secrets.GITHUB_TOKEN }}',
        '${{ secrets [ ''GITHUB_TOKEN'' ] }}',
        '${{ secrets["GITHUB_TOKEN"] }}',
        '${{ github.token }}',
        '${{ github [ ''token'' ] }}',
        '${{ github["token"] }}',
        '${{ secrets . GITHUB_TOKEN }}'
    )) {
        if (-not (Test-ContainsGitHubTokenReference -Text $reference)) {
            throw "GitHub token reference detector missed a supported expression form."
        }
    }
    foreach ($reference in @(
        '${{ secrets.CF_API_KEY }}',
        '${{ github.repository }}',
        'GITHUB_TOKEN is named only in documentation text'
    )) {
        if (Test-ContainsGitHubTokenReference -Text $reference) {
            throw "GitHub token reference detector rejected a non-token expression."
        }
    }
    foreach ($reference in @(
        '${{ secrets.IMMUTABLE_RELEASES_READ_TOKEN }}',
        '${{ secrets [ ''IMMUTABLE_RELEASES_READ_TOKEN'' ] }}',
        '${{ secrets["IMMUTABLE_RELEASES_READ_TOKEN"] }}',
        '${{ secrets . IMMUTABLE_RELEASES_READ_TOKEN }}'
    )) {
        if (-not (Test-ContainsSecretReference -Text $reference -SecretName 'IMMUTABLE_RELEASES_READ_TOKEN')) {
            throw "Immutable policy token detector missed a supported expression form."
        }
    }
    if (Test-ContainsSecretReference -Text '${{ secrets.IMMUTABLE_RELEASES_READ_TOKEN_BACKUP }}' -SecretName 'IMMUTABLE_RELEASES_READ_TOKEN') {
        throw "Immutable policy token detector matched a longer secret name."
    }

    $releaseJobBlock = Get-WorkflowJobBlock -WorkflowText $workflowText -JobName 'release'
    $replaceReleaseJob = {
        param([string]$Replacement)
        return $workflowText.Remove($releaseJobBlock.Index, $releaseJobBlock.Length).Insert(
            $releaseJobBlock.Index,
            $Replacement)
    }
    Assert-ThrowsMatch "missing checkout persistence boundary rejected" {
        $replacement = $releaseJobBlock.Value -replace '(?m)^\s{10}persist-credentials:\s*false\s*\r?\n', ''
        Assert-ReleaseWorkflowBoundary -WorkflowText (& $replaceReleaseJob $replacement)
    } "persist-credentials: false"
    Assert-ThrowsMatch "enabled checkout persistence rejected" {
        $replacement = $releaseJobBlock.Value -replace '(?m)^(\s{10}persist-credentials:)\s*false\s*$', '$1 true'
        Assert-ReleaseWorkflowBoundary -WorkflowText (& $replaceReleaseJob $replacement)
    } "persist-credentials: false"
    Assert-ThrowsMatch "dynamic checkout persistence rejected" {
        $replacement = $releaseJobBlock.Value -replace '(?m)^(\s{10}persist-credentials:)\s*false\s*$', '$1 ${{ always() }}'
        Assert-ReleaseWorkflowBoundary -WorkflowText (& $replaceReleaseJob $replacement)
    } "literal persist-credentials: false"
    Assert-ThrowsMatch "duplicate checkout persistence setting rejected" {
        $replacement = $releaseJobBlock.Value.Replace(
            '          persist-credentials: false',
            "          persist-credentials: false`n          persist-credentials: false")
        Assert-ReleaseWorkflowBoundary -WorkflowText (& $replaceReleaseJob $replacement)
    } "exactly one literal persist-credentials: false"
    Assert-ThrowsMatch "explicit checkout token rejected" {
        $replacement = $releaseJobBlock.Value.Replace(
            '          persist-credentials: false',
            "          persist-credentials: false`n          token: `${{ secrets.GITHUB_TOKEN }}")
        Assert-ReleaseWorkflowBoundary -WorkflowText (& $replaceReleaseJob $replacement)
    } "must not receive explicit credentials"
    Assert-ThrowsMatch "missing post-checkout credential verification rejected" {
        $replacement = $releaseJobBlock.Value.Replace(
            '      - name: Verify anonymous checkout boundary',
            '      - name: Credential check removed')
        Assert-ReleaseWorkflowBoundary -WorkflowText (& $replaceReleaseJob $replacement)
    } "verify checkout credentials immediately"
    Assert-ThrowsMatch "write-capable release preflight rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace 'contents: read', 'contents: write')
    } "preflight must have contents: read"
    Assert-ThrowsMatch "release job without preflight dependency rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '(?m)^    needs: preflight\s*\r?\n', '')
    } "publication must depend on the read-only preflight"

    $checksPackageJob = Get-WorkflowJobBlock -WorkflowText $checksWorkflowText -JobName 'package-contract'
    Assert-ThrowsMatch "checks package checkout persistence rejected" {
        $replacement = $checksPackageJob.Value -replace '(?m)^\s{10}persist-credentials:\s*false\s*\r?\n', ''
        $mutated = $checksWorkflowText.Remove($checksPackageJob.Index, $checksPackageJob.Length).Insert(
            $checksPackageJob.Index,
            $replacement)
        Assert-WorkflowCheckoutCredentialBoundary `
            -WorkflowText $mutated `
            -JobNames @('checks', 'package-contract')
    } "persist-credentials: false"

    $githubTokenExpression = '${{ secrets.GITHUB_TOKEN }}'
    $bracketSecretTokenExpression = '${{ secrets[''GITHUB_TOKEN''] }}'
    $bracketContextTokenExpression = '${{ github["token"] }}'
    $immutableTokenExpression = '${{ secrets.IMMUTABLE_RELEASES_READ_TOKEN }}'
    $bracketImmutableTokenExpression = '${{ secrets[''IMMUTABLE_RELEASES_READ_TOKEN''] }}'
    $immutablePolicyBlock = [regex]::Match(
        $workflowText,
        '(?ms)^\s{6}- name: Verify immutable release policy\s*$.*?(?=^\s{6}- name:|\z)'
    )
    $marketplaceCredentialBlock = [regex]::Match(
        $workflowText,
        '(?ms)^\s{6}- name: Verify marketplace release credentials and versions\s*$.*?(?=^\s{6}- name:|\z)'
    )
    Assert-ThrowsMatch "missing immutable policy step rejected" {
        $mutated = $workflowText.Remove($immutablePolicyBlock.Index, $immutablePolicyBlock.Length)
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "Verify immutable release policy|exactly one"
    Assert-ThrowsMatch "duplicate immutable policy step rejected" {
        $mutated = $workflowText.Replace(
            '      - name: Trim release changelog',
            $immutablePolicyBlock.Value + '      - name: Trim release changelog')
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "exactly one GitHub-management step|exactly one immutable"
    Assert-ThrowsMatch "immutable policy after Packager rejected" {
        $withoutPolicy = $workflowText.Remove($immutablePolicyBlock.Index, $immutablePolicyBlock.Length)
        $mutated = $withoutPolicy.Replace(
            '      - name: Validate package artifact',
            $immutablePolicyBlock.Value + '      - name: Validate package artifact')
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "immediately after refusing|before every Packager|out of the required"
    Assert-ThrowsMatch "immutable policy self-test substitution rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '-ImmutableReleasePolicyOnly -RequireExplicitToken', '-SelfTest')
    } "exact fail-closed read-only checker"
    Assert-ThrowsMatch "immutable policy without explicit token gate rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace ' -RequireExplicitToken', '')
    } "exact fail-closed read-only checker"
    Assert-ThrowsMatch "automatic GitHub token for immutable policy rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace 'secrets\.IMMUTABLE_RELEASES_READ_TOKEN', 'secrets.GITHUB_TOKEN')
    } "expected step-local GH_TOKEN source"
    Assert-ThrowsMatch "immutable policy token in first Packager rejected" {
        $mutated = $workflowText.Replace(
            '      - name: Build package without publishing',
            "      - name: Build package without publishing`n        env:`n          POLICY_TOKEN: $immutableTokenExpression")
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "outside its approved shell step"
    Assert-ThrowsMatch "bracket immutable token in marketplace Packager rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace "WOWI_API_TOKEN: \$\{\{ secrets\.WOWI_API_TOKEN \}\}", "WOWI_API_TOKEN: $bracketImmutableTokenExpression")
    } "outside its approved shell step"
    Assert-ThrowsMatch "missing marketplace credential preflight rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Remove(
            $marketplaceCredentialBlock.Index,
            $marketplaceCredentialBlock.Length)
    } "marketplace step|credential preflight|missing required step"
    Assert-ThrowsMatch "duplicate marketplace credential preflight rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            '      - name: Trim release changelog',
            $marketplaceCredentialBlock.Value + '      - name: Trim release changelog')
    } "exactly one marketplace step|exactly one marketplace credential"
    Assert-ThrowsMatch "marketplace credential preflight after first Packager rejected" {
        $withoutCredential = $workflowText.Remove(
            $marketplaceCredentialBlock.Index,
            $marketplaceCredentialBlock.Length)
        $mutated = $withoutCredential.Replace(
            '      - name: Validate package artifact',
            $marketplaceCredentialBlock.Value + '      - name: Validate package artifact')
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "immediately after|before every Packager|out of the required"
    Assert-ThrowsMatch "marketplace credential self-test substitution rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '\./scripts/check-marketplace-versions\.ps1', './scripts/check-marketplace-versions.ps1 -SelfTest')
    } "exact fail-closed checker"
    Assert-ThrowsMatch "fallible marketplace credential step rejected" {
        $mutated = $workflowText -replace `
            '(?m)^(\s{6}- name: Verify marketplace release credentials and versions)\s*$', `
            "`$1`n        continue-on-error: true"
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "mandatory pwsh step"
    foreach ($marketplaceSecretName in @('CF_API_KEY', 'WAGO_API_TOKEN', 'WOWI_API_TOKEN')) {
        Assert-ThrowsMatch "missing $marketplaceSecretName preflight binding rejected" {
            $canonicalLinePattern = "(?m)^\s{10}${marketplaceSecretName}:\s*\`$\{\{\s*secrets\.${marketplaceSecretName}\s*\}\}\s*\r?\n"
            $mutatedBlock = [regex]::Replace($marketplaceCredentialBlock.Value, $canonicalLinePattern, '')
            $mutated = $workflowText.Remove(
                $marketplaceCredentialBlock.Index,
                $marketplaceCredentialBlock.Length).Insert(
                    $marketplaceCredentialBlock.Index,
                    $mutatedBlock)
            Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
        } "exactly the three marketplace|bind $marketplaceSecretName"
        Assert-ThrowsMatch "wrong $marketplaceSecretName preflight source rejected" {
            $mutatedBlock = $marketplaceCredentialBlock.Value.Replace(
                "secrets.${marketplaceSecretName}",
                "secrets.${marketplaceSecretName}_BACKUP")
            $mutated = $workflowText.Remove(
                $marketplaceCredentialBlock.Index,
                $marketplaceCredentialBlock.Length).Insert(
                    $marketplaceCredentialBlock.Index,
                    $mutatedBlock)
            Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
        } "bind $marketplaceSecretName|non-canonical"
    }
    Assert-ThrowsMatch "swapped marketplace preflight sources rejected" {
        $mutatedBlock = $marketplaceCredentialBlock.Value.Replace(
            'secrets.CF_API_KEY',
            'secrets.TEMP_MARKETPLACE_TOKEN').Replace(
                'secrets.WAGO_API_TOKEN',
                'secrets.CF_API_KEY').Replace(
                    'secrets.TEMP_MARKETPLACE_TOKEN',
                    'secrets.WAGO_API_TOKEN')
        $mutated = $workflowText.Remove(
            $marketplaceCredentialBlock.Index,
            $marketplaceCredentialBlock.Length).Insert(
                $marketplaceCredentialBlock.Index,
                $mutatedBlock)
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "bind CF_API_KEY|bind WAGO_API_TOKEN|non-canonical"
    Assert-ThrowsMatch "marketplace secret in first Packager rejected" {
        $mutated = $workflowText.Replace(
            '      - name: Build package without publishing',
            "      - name: Build package without publishing`n        env:`n          CF_API_KEY: `${{ secrets.CF_API_KEY }}")
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "outside the approved preflight"
    Assert-ThrowsMatch "job-level marketplace secret rejected" {
        $replacement = $releaseJobBlock.Value.Replace(
            '  release:',
            "  release:`n    env:`n      WAGO_API_TOKEN: `${{ secrets.WAGO_API_TOKEN }}")
        Assert-ReleaseWorkflowBoundary -WorkflowText (& $replaceReleaseJob $replacement)
    } "outside the approved preflight"
    Assert-ThrowsMatch "job-level GitHub token rejected" {
        $replacement = $releaseJobBlock.Value.Replace(
            '  release:',
            "  release:`n    env:`n      GH_TOKEN: $githubTokenExpression")
        Assert-ReleaseWorkflowBoundary -WorkflowText (& $replaceReleaseJob $replacement)
    } "outside its approved shell step"
    Assert-ThrowsMatch "GitHub token in first Packager rejected" {
        $mutated = $workflowText.Replace(
            '      - name: Build package without publishing',
            "      - name: Build package without publishing`n        env:`n          GH_TOKEN: $githubTokenExpression")
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "outside its approved shell step"
    Assert-ThrowsMatch "bracket GitHub secret in first Packager rejected" {
        $mutated = $workflowText.Replace(
            '      - name: Build package without publishing',
            "      - name: Build package without publishing`n        env:`n          GH_TOKEN: $bracketSecretTokenExpression")
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "outside its approved shell step"
    Assert-ThrowsMatch "GitHub token in rebuild Packager rejected" {
        $mutated = $workflowText.Replace(
            '      - name: Rebuild package without publishing',
            "      - name: Rebuild package without publishing`n        env:`n          GH_TOKEN: $githubTokenExpression")
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "outside its approved shell step"
    Assert-ThrowsMatch "GitHub token in changelog trim step rejected" {
        $mutated = $workflowText.Replace(
            '      - name: Trim release changelog',
            "      - name: Trim release changelog`n        env:`n          GH_TOKEN: $githubTokenExpression")
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "outside its approved shell step"
    Assert-ThrowsMatch "bracket GitHub context token in changelog trim step rejected" {
        $mutated = $workflowText.Replace(
            '      - name: Trim release changelog',
            "      - name: Trim release changelog`n        env:`n          GH_TOKEN: $bracketContextTokenExpression")
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "outside its approved shell step"
    Assert-ThrowsMatch "single-pending release queue rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace "queue: max", "queue: single")
    } "queue: max"
    Assert-ThrowsMatch "missing publication ancestry recheck rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace "check-release-ancestry\.ps1", "echo ancestry-skipped")
    } "fresh ancestry gate"
    Assert-ThrowsMatch "disabled exact pre-upload switch rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace "-RequireExactPackagerProjectVersion", '-RequireExactPackagerProjectVersion:$false')
    } "immediate pre-upload step"
    Assert-ThrowsMatch "run attempt substituted for stable run ID rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '\$env:GITHUB_RUN_ID', '$env:GITHUB_RUN_ATTEMPT')
    } "ExpectedRunId"
    Assert-ThrowsMatch "wrong release repository binding rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '\$env:GITHUB_REPOSITORY', '$env:OTHER_REPOSITORY')
    } "Repository|exact fail-closed|published changelog parity"
    Assert-ThrowsMatch "wrong release tag binding rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '\$env:GITHUB_REF_NAME', '$env:OTHER_TAG')
    } "ExpectedTag|exact fail-closed|Canonical release notes|published changelog parity"
    Assert-ThrowsMatch "conditional interrupted-state validation rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '(?m)^(\s{6}- name: Validate interrupted release state\s*)$', "`$1`n        if: always()")
    } "must be mandatory"
    Assert-ThrowsMatch "missing durable marketplace-started transition rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '-Mode MarkMarketplaceStarted', '-Mode CreateDraft')
    } "MarkMarketplaceStarted"
    Assert-ThrowsMatch "noncanonical interrupted-state notes rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '-ExportTopChangelogPath CHANGELOG\.md', '-ExportTopChangelogPath release-notes.md')
    } "Canonical release notes"
    Assert-ThrowsMatch "conditional draft preparation rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '(?m)^(\s{6}- name: Prepare resumable draft release\s*)$', "`$1`n        if: always()")
    } "must be mandatory"
    Assert-ThrowsMatch "marketplace tree reuse flags rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace "args: -c -e -o", "args: -c -e")
    } "reusing the validated tree"
    $publishMarker = "      - name: Publish package to marketplaces"
    $insertedStep = "      - name: Unexpected intervening step`n        run: echo changed`n`n"
    Assert-ThrowsMatch "intervening pre-upload step rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace($publishMarker, $insertedStep + $publishMarker)
    } "must be consecutive"
    $preUploadBlock = [regex]::Match($workflowText, "(?ms)^\s{6}- name: Validate exact package immediately before marketplace upload\s*$.*?(?=^\s{6}- name:|\z)")
    $publishBlock = [regex]::Match($workflowText, "(?ms)^\s{6}- name: Publish package to marketplaces\s*$.*?(?=^\s{6}- name:|\z)")
    $swappedWorkflow = $workflowText.Substring(0, $preUploadBlock.Index) +
        $publishBlock.Value + $preUploadBlock.Value +
        $workflowText.Substring($publishBlock.Index + $publishBlock.Length)
    Assert-ThrowsMatch "pre-upload validation after marketplace publish rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $swappedWorkflow
    } "out of the required|exactly one GitHub-management step"
    $postPublishMarker = "      - name: Validate marketplace archive and create release metadata"
    foreach ($marketplaceSecretName in @('CF_API_KEY', 'WAGO_API_TOKEN', 'WOWI_API_TOKEN')) {
        Assert-ThrowsMatch "missing $marketplaceSecretName publishing binding rejected" {
            $canonicalLinePattern = "(?m)^\s{10}${marketplaceSecretName}:\s*\`$\{\{\s*secrets\.${marketplaceSecretName}\s*\}\}\s*\r?\n"
            $mutatedPublishBlock = [regex]::Replace($publishBlock.Value, $canonicalLinePattern, '')
            $mutated = $workflowText.Remove($publishBlock.Index, $publishBlock.Length).Insert(
                $publishBlock.Index,
                $mutatedPublishBlock)
            Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
        } "exactly the three marketplace|bind $marketplaceSecretName"
    }
    Assert-ThrowsMatch "swapped publishing marketplace sources rejected" {
        $mutatedPublishBlock = $publishBlock.Value.Replace(
            'secrets.CF_API_KEY',
            'secrets.TEMP_MARKETPLACE_TOKEN').Replace(
                'secrets.WAGO_API_TOKEN',
                'secrets.CF_API_KEY').Replace(
                    'secrets.TEMP_MARKETPLACE_TOKEN',
                    'secrets.WAGO_API_TOKEN')
        $mutated = $workflowText.Remove($publishBlock.Index, $publishBlock.Length).Insert(
            $publishBlock.Index,
            $mutatedPublishBlock)
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "bind CF_API_KEY|bind WAGO_API_TOKEN|non-canonical"
    Assert-ThrowsMatch "duplicate publishing Packager step rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            $postPublishMarker,
            $publishBlock.Value + $postPublishMarker)
    } "exactly one publishing Packager step|exactly one marketplace step"
    Assert-ThrowsMatch "wrong pre-upload Packager output binding rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace 'steps\.rebuild-package-output\.outputs\.project_version', 'steps.build-package-output.outputs.project_version')
    } "immediate pre-upload step"
    Assert-ThrowsMatch "missing Packager artifact resolver rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace 'resolve-packager-output\.ps1', 'missing-packager-output.ps1')
    } "artifact-output resolver"
    Assert-ThrowsMatch "conditional Packager artifact resolver rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '(?m)^(\s{8}id: build-package-output\s*)$', "`$1`n        if: always()")
    } "artifact-output resolver"
    Assert-ThrowsMatch "extra Packager step rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            $publishMarker,
            "      - name: Unexpected dry run`n        uses: BigWigsMods/packager@6d50adb6e8517eefef63f4afb16a6518166a6b28`n        with:`n          args: -d`n`n$publishMarker")
    } "exactly 3 Packager steps"
    Assert-ThrowsMatch "GitHub token in marketplace step rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace "WOWI_API_TOKEN: \$\{\{ secrets\.WOWI_API_TOKEN \}\}", 'GITHUB_OAUTH: ${{ secrets.GITHUB_TOKEN }}')
    } "outside its approved shell step"
    Assert-ThrowsMatch "bracket GitHub token in marketplace Packager rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace "WOWI_API_TOKEN: \$\{\{ secrets\.WOWI_API_TOKEN \}\}", "WOWI_API_TOKEN: $bracketSecretTokenExpression")
    } "outside its approved shell step"

    Write-Host "GitHub release management self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if ([string]::IsNullOrWhiteSpace($Mode)) {
    throw "Missing release-management -Mode."
}
Assert-RepositoryName $Repository
Assert-ReleaseTag $ExpectedTag
if ($Mode -ne "RefuseExisting") {
    Assert-CommitSha $ExpectedCommitSha
}
if ($Mode -in @("CreateDraft", "MarkMarketplaceStarted", "AttachAssets", "Publish")) {
    Assert-RunId $ExpectedRunId
}
if ($AttestationAttempts -lt 1) {
    throw "-AttestationAttempts must be at least 1."
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required."
}

switch ($Mode) {
    "RefuseExisting" {
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
        Assert-NoExistingRelease -Release $release -ExpectedTag $ExpectedTag
        Write-Host "No existing GitHub release marker found for $ExpectedTag."
    }
    "ValidateStart" {
        $notesText = Get-CanonicalFileText -Path $NotesPath -Description "release notes"
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
        $state = Assert-ReleaseStartState `
            -Release $release `
            -Repository $Repository `
            -ExpectedTag $ExpectedTag `
            -ExpectedCommitSha $ExpectedCommitSha `
            -ExpectedNotes $notesText
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha
        Write-Host "Release start state for $ExpectedTag is $state."
    }
    "CreateDraft" {
        $notesText = Get-CanonicalFileText -Path $NotesPath -Description "release notes"
        $manifestText = Get-CanonicalFileText -Path $ManifestPath -Description "validated package manifest"
        $manifestSha256 = Get-LowercaseTextSha256 -Text $manifestText
        $desiredState = Get-ReleaseStateData `
            -Phase 'prepared' `
            -Repository $Repository `
            -ExpectedTag $ExpectedTag `
            -ExpectedCommitSha $ExpectedCommitSha `
            -ExpectedRunId $ExpectedRunId `
            -NotesSha256 (Get-LowercaseTextSha256 -Text $notesText) `
            -ManifestSha256 $manifestSha256
        $desiredBody = Get-ReleaseBody -State $desiredState -CanonicalNotes $notesText
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha
        if ($null -eq $release) {
            Invoke-WithTemporaryReleaseBody -Body $desiredBody -Action {
                param([string]$BodyPath)
                [void](Invoke-GitHubMutationAndAttest `
                    -Description "Draft creation for $ExpectedTag" `
                    -Arguments (Get-CreateDraftGhArguments -Repository $Repository -ExpectedTag $ExpectedTag -NotesPath $BodyPath) `
                    -Repository $Repository `
                    -ExpectedTag $ExpectedTag `
                    -Attempts $AttestationAttempts `
                    -AssertState {
                        param([object]$Observed)
                        [void](Assert-ReleaseProtocolIdentity -Release $Observed -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'prepared' -ExpectedRunId $ExpectedRunId -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256)
                        Assert-ExactAssetSet -Release $Observed -ExpectedNames @()
                    })
            }
            Write-Host "Prepared draft release marker created for $ExpectedTag."
        }
        else {
            $parsed = Assert-ReleaseProtocolIdentity -Release $release -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'prepared' -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256
            Assert-ExactAssetSet -Release $release -ExpectedNames @()
            if ([string]$parsed.State.runId -eq $ExpectedRunId) {
                Write-Host "Prepared draft release marker already belongs to run $ExpectedRunId; no mutation needed."
            }
            else {
                Invoke-WithTemporaryReleaseBody -Body $desiredBody -Action {
                    param([string]$BodyPath)
                    [void](Invoke-GitHubMutationAndAttest `
                        -Description "Prepared draft claim for $ExpectedTag" `
                        -Arguments (Get-EditDraftBodyGhArguments -Repository $Repository -ExpectedTag $ExpectedTag -NotesPath $BodyPath) `
                        -Repository $Repository `
                        -ExpectedTag $ExpectedTag `
                        -Attempts $AttestationAttempts `
                        -AssertState {
                            param([object]$Observed)
                            [void](Assert-ReleaseProtocolIdentity -Release $Observed -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'prepared' -ExpectedRunId $ExpectedRunId -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256)
                            Assert-ExactAssetSet -Release $Observed -ExpectedNames @()
                        })
                }
                Write-Host "Prepared draft release marker safely claimed by run $ExpectedRunId."
            }
        }
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha
    }
    "MarkMarketplaceStarted" {
        $notesText = Get-CanonicalFileText -Path $NotesPath -Description "release notes"
        $manifestSha256 = Get-LowercaseTextSha256 -Text (Get-CanonicalFileText -Path $ManifestPath -Description "validated package manifest")
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
        [void](Assert-ReleaseProtocolIdentity -Release $release -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'prepared' -ExpectedRunId $ExpectedRunId -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256)
        Assert-ExactAssetSet -Release $release -ExpectedNames @()
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha
        $startedState = Get-ReleaseStateData -Phase 'marketplace-started' -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedRunId $ExpectedRunId -NotesSha256 (Get-LowercaseTextSha256 -Text $notesText) -ManifestSha256 $manifestSha256
        $startedBody = Get-ReleaseBody -State $startedState -CanonicalNotes $notesText
        Invoke-WithTemporaryReleaseBody -Body $startedBody -Action {
            param([string]$BodyPath)
            [void](Invoke-GitHubMutationAndAttest `
                -Description "Marketplace-started marker for $ExpectedTag" `
                -Arguments (Get-EditDraftBodyGhArguments -Repository $Repository -ExpectedTag $ExpectedTag -NotesPath $BodyPath) `
                -Repository $Repository `
                -ExpectedTag $ExpectedTag `
                -Attempts $AttestationAttempts `
                -AssertState {
                    param([object]$Observed)
                    [void](Assert-ReleaseProtocolIdentity -Release $Observed -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'marketplace-started' -ExpectedRunId $ExpectedRunId -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256)
                    Assert-ExactAssetSet -Release $Observed -ExpectedNames @()
                })
        }
        Write-Host "Marketplace publication boundary durably marked for $ExpectedTag."
    }
    "AttachAssets" {
        $paths = Assert-ReleaseAssetPaths -ArchivePath $ArchivePath -ReleaseJsonPath $ReleaseJsonPath -ExpectedTag $ExpectedTag
        $notesText = Get-CanonicalFileText -Path $NotesPath -Description "release notes"
        $manifestSha256 = Get-LowercaseTextSha256 -Text (Get-CanonicalFileText -Path $ManifestPath -Description "validated package manifest")
        $localFiles = @{
            "StatsPro-$ExpectedTag.zip" = $paths.Archive
            "release.json"              = $paths.ReleaseJson
        }
        foreach ($assetName in @("StatsPro-$ExpectedTag.zip", "release.json")) {
            $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
            [void](Assert-ReleaseProtocolIdentity -Release $release -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'marketplace-started' -ExpectedRunId $ExpectedRunId -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256)
            Assert-ReleaseAssetSubsetMatchesLocalFiles -Release $release -LocalFiles $localFiles
            if (-not (Test-ContainsOrdinal -Values @(Get-ReleaseAssetNames -Release $release) -Expected $assetName)) {
                [void](Invoke-GitHubMutationAndAttest `
                    -Description "Asset upload '$assetName' for $ExpectedTag" `
                    -Arguments (Get-AttachAssetsGhArguments -Repository $Repository -ExpectedTag $ExpectedTag -AssetPath $localFiles[$assetName]) `
                    -Repository $Repository `
                    -ExpectedTag $ExpectedTag `
                    -Attempts $AttestationAttempts `
                    -AssertState {
                        param([object]$Observed)
                        [void](Assert-ReleaseProtocolIdentity -Release $Observed -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'marketplace-started' -ExpectedRunId $ExpectedRunId -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256)
                        Assert-ReleaseAssetSubsetMatchesLocalFiles -Release $Observed -LocalFiles $localFiles
                        if (-not (Test-ContainsOrdinal -Values @(Get-ReleaseAssetNames -Release $Observed) -Expected $assetName)) {
                            throw "Uploaded asset '$assetName' is not visible."
                        }
                    })
            }
        }
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
        [void](Assert-ReleaseProtocolIdentity -Release $release -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'marketplace-started' -ExpectedRunId $ExpectedRunId -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256)
        Assert-DraftAssetsMatchLocalFiles -Release $release -ExpectedTag $ExpectedTag -ArchivePath $paths.Archive -ReleaseJsonPath $paths.ReleaseJson
        Write-Host "Validated release assets attached to draft $ExpectedTag."
    }
    "Publish" {
        $paths = Assert-ReleaseAssetPaths -ArchivePath $ArchivePath -ReleaseJsonPath $ReleaseJsonPath -ExpectedTag $ExpectedTag
        $notesText = Get-CanonicalFileText -Path $NotesPath -Description "release notes"
        $manifestSha256 = Get-LowercaseTextSha256 -Text (Get-CanonicalFileText -Path $ManifestPath -Description "validated package manifest")
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
        [void](Assert-ReleaseProtocolIdentity -Release $release -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'marketplace-started' -ExpectedRunId $ExpectedRunId -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256)
        Assert-DraftAssetsMatchLocalFiles -Release $release -ExpectedTag $ExpectedTag -ArchivePath $paths.Archive -ReleaseJsonPath $paths.ReleaseJson
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
        [void](Assert-ReleaseProtocolIdentity -Release $release -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'marketplace-started' -ExpectedRunId $ExpectedRunId -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256)
        Assert-DraftAssetsMatchLocalFiles -Release $release -ExpectedTag $ExpectedTag -ArchivePath $paths.Archive -ReleaseJsonPath $paths.ReleaseJson
        [void](Invoke-GitHubMutationAndAttest `
            -Description "Immutable publication for $ExpectedTag" `
            -Arguments (Get-PublishGhArguments -Repository $Repository -ExpectedTag $ExpectedTag) `
            -Repository $Repository `
            -ExpectedTag $ExpectedTag `
            -Attempts $AttestationAttempts `
            -AssertState {
                param([object]$Observed)
                [void](Assert-PublishedProtocolIdentity -Release $Observed -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedRunId $ExpectedRunId -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256)
            })
        Invoke-BoundedReadOnlyCheck `
            -Description "Published immutable release attestation for $ExpectedTag" `
            -Attempts $AttestationAttempts `
            -Check {
                $published = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
                [void](Assert-PublishedProtocolIdentity -Release $published -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedRunId $ExpectedRunId -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256)
                Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha
                Invoke-ImmutableReleaseAttestationChecks -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ArchivePath $paths.Archive -ReleaseJsonPath $paths.ReleaseJson
            }
        Write-Host "Immutable GitHub release published and attested for $ExpectedTag."
    }
    "RetirePrepared" {
        $notesText = Get-CanonicalFileText -Path $NotesPath -Description "release notes"
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
        [void](Assert-ReleaseProtocolIdentity -Release $release -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'prepared' -ExpectedNotes $notesText)
        Assert-ExactAssetSet -Release $release -ExpectedNames @()
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha
        [void](Invoke-GitHubMutationAndAttest `
            -Description "Prepared draft retirement for $ExpectedTag" `
            -Arguments (Get-RetirePreparedGhArguments -Repository $Repository -ExpectedTag $ExpectedTag) `
            -Repository $Repository `
            -ExpectedTag $ExpectedTag `
            -Attempts $AttestationAttempts `
            -AssertState {
                param([AllowNull()][object]$Observed)
                if ($null -ne $Observed) {
                    throw "Prepared draft $ExpectedTag still exists after retirement."
                }
            })
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha
        Write-Host "Safely retired empty prepared draft $ExpectedTag; tag was preserved."
    }
}
