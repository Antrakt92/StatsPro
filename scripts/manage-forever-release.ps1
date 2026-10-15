param(
    [ValidateSet('RefuseExisting', 'CreateDraft', 'MarkMarketplaceStarted', 'AttachAssets', 'Publish', 'Verify')]
    [string]$Mode,
    [string]$Repository,
    [string]$ExpectedTag,
    [string]$ExpectedCommitSha,
    [string]$ExpectedRunId,
    [string]$ExpectedRunAttempt,
    [string]$ExpectedArchiveSha256,
    [string]$ExpectedCandidateSha256,
    [string]$ArchivePath,
    [string]$ReleaseJsonPath,
    [string]$NotesPath,
    [switch]$SelfTest,
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-process.ps1')

function Invoke-ForeverGh {
    param([string[]]$Arguments)
    $command = (Get-Command gh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $result = Invoke-StatsProNativeCapture -FilePath $command -Arguments $Arguments -TimeoutSeconds 60 -Description 'Forever release operation'
    $output = $result.Output -join "`n"
    if ($result.ExitCode -ne 0) {
        throw "GitHub operation failed; its outcome must be reconciled before any mutation is repeated: $output"
    }
    return $output
}

function Get-ForeverRelease {
    param([object]$Context)
    # The by-tag REST endpoint can hide drafts. Use the stable manager's complete
    # paginated release inventory so an existing draft never looks like absence.
    $json = Invoke-ForeverGh -Arguments @('api', '--paginate', '--slurp',
        '-H', 'Accept: application/vnd.github+json', '-H', 'X-GitHub-Api-Version: 2026-03-10',
        "repos/$($Context.Repository)/releases?per_page=100")
    $pages = ConvertFrom-Json -InputObject $json -NoEnumerate
    if ($pages -isnot [array] -or $pages.Count -eq 0) { throw 'Malformed GitHub release inventory: expected paginated arrays.' }
    $matches = @()
    foreach ($page in $pages) {
        if ($page -isnot [array]) { throw 'Malformed GitHub release inventory page.' }
        foreach ($release in $page) {
            if ($null -eq $release -or $release.tag_name -isnot [string] -or $release.tag_name -eq '' -or
                $release.draft -isnot [bool] -or ($release.id -isnot [int] -and $release.id -isnot [long]) -or $release.id -le 0) {
                throw 'Malformed GitHub release inventory record.'
            }
            if ($release.tag_name -ceq $Context.Tag) { $matches += $release }
        }
    }
    if ($matches.Count -gt 1) { throw 'Duplicate exact-tag GitHub releases are forbidden.' }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Assert-ForeverRemoteTag {
    param([object]$Context)
    $headers = @('-H', 'Accept: application/vnd.github+json', '-H', 'X-GitHub-Api-Version: 2026-03-10')
    $ref = Invoke-ForeverGh -Arguments (@('api', "repos/$($Context.Repository)/git/ref/tags/$($Context.Tag)") + $headers) | ConvertFrom-Json
    $object = $ref.object
    for ($depth = 0; $object.type -eq 'tag' -and $depth -lt 4; $depth++) {
        $tag = Invoke-ForeverGh -Arguments (@('api', "repos/$($Context.Repository)/git/tags/$($object.sha)") + $headers) | ConvertFrom-Json
        $object = $tag.object
    }
    if ($object.type -cne 'commit' -or $object.sha -cne $Context.Commit) { throw 'Remote Forever tag does not resolve to the expected commit.' }
}

function Get-ForeverReleaseBody {
    param([object]$Context, [ValidateSet('prepared', 'marketplace-started', 'asset-upload-started')][string]$Phase)
    $state = [ordered]@{ protocol = 'statspro-forever-release-v1'; phase = $Phase
        repository = $Context.Repository; tag = $Context.Tag; commit = $Context.Commit
        runId = $Context.RunId; runAttempt = $Context.RunAttempt
        archiveSha256 = $Context.ArchiveSha256; candidateSha256 = $Context.CandidateSha256 }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Compress)))
    return $Context.Notes + "`n`n<!-- statspro-forever-release:$encoded -->"
}

function Assert-ForeverRelease {
    param([object]$Context, [object]$Release, [string]$Phase, [bool]$Published = $false, [int]$AssetCount = 0)
    if ($null -eq $Release -or $Release.tag_name -cne $Context.Tag -or $Release.name -cne "StatsPro $($Context.Version) — Forever Beta" -or
        $Release.prerelease -ne $true -or $Release.draft -ne (-not $Published) -or
        $Release.body -cne (Get-ForeverReleaseBody -Context $Context -Phase $Phase)) {
        throw 'Forever release identity, phase, notes, run ownership or prerelease state mismatch.'
    }
    if (@($Release.assets).Count -ne $AssetCount) { throw 'Forever release must contain exactly the expected asset set.' }
    if ($AssetCount -eq 1) {
        $asset = @($Release.assets)[0]
        if ($asset.name -cne $Context.ArchiveName -or $asset.size -ne $Context.ArchiveSize -or $asset.state -cne 'uploaded') {
            throw 'Forever release asset name, size or upload state mismatch.'
        }
        if ($asset.digest -and $asset.digest -cne "sha256:$($Context.ArchiveSha256)") { throw 'Forever release asset digest mismatch.' }
    }
    if ($Published -and $Release.immutable -ne $true) { throw 'Published Forever release is not immutable.' }
}

function Invoke-ForeverBodyMutation {
    param([object]$Context, [string]$Phase, [switch]$Create)
    $bodyPath = Join-Path ([IO.Path]::GetTempPath()) ("statspro-forever-" + [guid]::NewGuid().ToString('N') + '.md')
    try {
        [IO.File]::WriteAllText($bodyPath, (Get-ForeverReleaseBody -Context $Context -Phase $Phase), [Text.UTF8Encoding]::new($false))
        $argsList = if ($Create) {
            @('release', 'create', $Context.Tag, '--repo', $Context.Repository, '--verify-tag', '--target', $Context.Commit,
                '--title', "StatsPro $($Context.Version) — Forever Beta", '--notes-file', $bodyPath, '--draft', '--prerelease', '--latest=false')
        } else { @('release', 'edit', $Context.Tag, '--repo', $Context.Repository, '--notes-file', $bodyPath) }
        [void](Invoke-ForeverGh -Arguments $argsList)
    } finally { if (Test-Path -LiteralPath $bodyPath) { Remove-Item -LiteralPath $bodyPath -Force } }
}

function Assert-ForeverRemoteAsset {
    param([object]$Context, [object]$Release)
    $asset = @($Release.assets)[0]
    if ($asset.digest) { return } # Assert-ForeverRelease already checked the exact digest.
    $downloadDirectory = Join-Path ([IO.Path]::GetTempPath()) ("statspro-forever-asset-" + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($downloadDirectory)
    $downloadPath = Join-Path $downloadDirectory $Context.ArchiveName
    try {
        [void](Invoke-ForeverGh -Arguments @('release', 'download', $Context.Tag, '--repo', $Context.Repository, '--pattern', $Context.ArchiveName, '--dir', $downloadDirectory))
        if ((Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Context.ArchiveSha256) {
            throw 'Downloaded Forever archive differs from the validated local package.'
        }
    } finally {
        if (Test-Path -LiteralPath $downloadPath) { Remove-Item -LiteralPath $downloadPath -Force }
        Remove-Item -LiteralPath $downloadDirectory -Force
    }
}

function Assert-ForeverLocalArchive {
    param([object]$Context)
    if ((Get-Item -LiteralPath $Context.ArchivePath).Length -ne $Context.ArchiveSize -or
        (Get-FileHash -LiteralPath $Context.ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Context.ArchiveSha256) {
        throw 'Local Forever archive changed after candidate validation.'
    }
}

function Assert-ForeverAttestation {
    param([object]$Context, [object]$Attestation)
    $uri = "pkg:github/$($Context.Repository)@$($Context.Tag)"
    $subjects = @(@($Attestation) | ForEach-Object { @($_.verificationResult.statement.subject) } | Where-Object { $_.uri -ceq $uri })
    if ($subjects.Count -ne 1 -or $subjects[0].digest.sha1 -cne $Context.Commit) {
        throw 'Immutable Forever release attestation does not bind the expected tag and commit.'
    }
}

function Get-ForeverStateDiagnostic {
    param([object]$Context, [object]$Release, [string]$Phase, [bool]$Published, [int]$AssetCount)
    $observedCount = if ($null -eq $Release) { 0 } else { @($Release.assets).Count }
    $expectedBody = Get-ForeverReleaseBody $Context $Phase
    $notesMatch = $Release.body -is [string] -and $Release.body.StartsWith(($Context.Notes + "`n`n"), [StringComparison]::Ordinal)
    $markerMatch = $Release.body -is [string] -and $Release.body.EndsWith($expectedBody.Substring($Context.Notes.Length + 2), [StringComparison]::Ordinal)
    return "exists=$($null -ne $Release) tagMatch=$($Release.tag_name -ceq $Context.Tag) titleMatch=$($Release.name -ceq "StatsPro $($Context.Version) — Forever Beta") draftMatch=$($Release.draft -eq (-not $Published)) prereleaseMatch=$($Release.prerelease -eq $true) bodyMatch=$($Release.body -ceq $expectedBody) notesMatch=$notesMatch markerMatch=$markerMatch assetsMatch=$($observedCount -eq $AssetCount) immutable=$($Release.immutable -eq $true) expectedPhase=$Phase"
}

function Wait-ForeverReleaseState {
    param([object]$Context, [string]$Phase, [bool]$Published = $false, [int]$AssetCount = 0,
        [scriptblock]$AdditionalCheck = $null, [int]$Attempts = 10, [int]$PauseSeconds = 2)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $observed = $null
        $stateAttested = $tagCommitAttested = $evidenceAttested = $false
        try {
            $observed = Get-ForeverRelease -Context $Context
            Assert-ForeverRelease -Context $Context -Release $observed -Phase $Phase -Published $Published -AssetCount $AssetCount
            $stateAttested = $true
            Assert-ForeverRemoteTag -Context $Context
            $tagCommitAttested = $true
            if ($AdditionalCheck) { [void](& $AdditionalCheck $observed) }
            $evidenceAttested = $true
            return $observed
        } catch {
            # Only booleans and the expected phase enter logs: never notes,
            # protocol payloads, credentials or arbitrary API response text.
            $diagnostic = Get-ForeverStateDiagnostic $Context $observed $Phase $Published $AssetCount
            $diagnostic += " stateAttested=$stateAttested tagCommitAttested=$tagCommitAttested evidenceAttested=$evidenceAttested"
            if ($attempt -eq $Attempts) { throw "Forever read-only state attestation exhausted: $diagnostic" }
            Write-Host "Forever state visibility retry $attempt/$Attempts`: $diagnostic"
            Start-Sleep -Seconds $PauseSeconds
        }
    }
}

function Invoke-ForeverMutationAndAttest {
    param([object]$Context, [scriptblock]$Mutation, [string]$Phase, [bool]$Published = $false,
        [int]$AssetCount = 0, [scriptblock]$AdditionalCheck = $null)
    $ambiguous = $false
    try { [void](& $Mutation) } catch { $ambiguous = $true }
    # A failed CLI response is not proof that nothing happened. Reconcile by
    # reads only; this function invokes the mutation exactly once in all cases.
    $observed = Wait-ForeverReleaseState -Context $Context -Phase $Phase -Published $Published -AssetCount $AssetCount -AdditionalCheck $AdditionalCheck
    if ($ambiguous) { Write-Warning "Ambiguous Forever mutation reconciled by exact read-only state attestation; expectedPhase=$Phase." }
    return $observed
}

function Assert-ForeverPublishedEvidence {
    param([object]$Context, [object]$Release)
    Assert-ForeverRemoteAsset -Context $Context -Release $Release
    Assert-ForeverLocalArchive -Context $Context
    $attestation = Invoke-ForeverGh -Arguments @('release', 'verify', $Context.Tag, '--repo', $Context.Repository, '--format', 'json') | ConvertFrom-Json
    Assert-ForeverAttestation -Context $Context -Attestation $attestation
    [void](Invoke-ForeverGh -Arguments @('release', 'verify-asset', $Context.Tag, $Context.ArchivePath, '--repo', $Context.Repository))
}

function Invoke-ForeverReleaseMode {
    param([object]$Context, [string]$SelectedMode)
    Assert-ForeverRemoteTag -Context $Context
    $release = Get-ForeverRelease -Context $Context
    if ($SelectedMode -eq 'RefuseExisting') {
        if ($null -ne $release) { throw 'A release already exists; automatic recovery is forbidden.' }
        return
    }
    switch ($SelectedMode) {
        'CreateDraft' {
            if ($null -ne $release) { throw 'A release already exists; automatic recovery is forbidden.' }
            [void](Invoke-ForeverMutationAndAttest -Context $Context -Phase prepared -Mutation {
                Invoke-ForeverBodyMutation -Context $Context -Phase prepared -Create
            })
        }
        'MarkMarketplaceStarted' {
            Assert-ForeverRelease -Context $Context -Release $release -Phase prepared
            [void](Invoke-ForeverMutationAndAttest -Context $Context -Phase marketplace-started -Mutation {
                Invoke-ForeverBodyMutation -Context $Context -Phase marketplace-started
            })
        }
        'AttachAssets' {
            Assert-ForeverRelease -Context $Context -Release $release -Phase marketplace-started
            Assert-ForeverLocalArchive -Context $Context
            # Persist the boundary before upload so even an unknown zero-asset outcome cannot be retried.
            [void](Invoke-ForeverMutationAndAttest -Context $Context -Phase asset-upload-started -Mutation {
                Invoke-ForeverBodyMutation -Context $Context -Phase asset-upload-started
            })
            [void](Invoke-ForeverMutationAndAttest -Context $Context -Phase asset-upload-started -AssetCount 1 -Mutation {
                [void](Invoke-ForeverGh -Arguments @('release', 'upload', $Context.Tag, $Context.ArchivePath, '--repo', $Context.Repository))
            } -AdditionalCheck { param($observed) Assert-ForeverRemoteAsset -Context $Context -Release $observed })
        }
        'Publish' {
            Assert-ForeverRelease -Context $Context -Release $release -Phase asset-upload-started -AssetCount 1
            Assert-ForeverLocalArchive -Context $Context
            Assert-ForeverRemoteAsset -Context $Context -Release $release
            Assert-ForeverRemoteTag -Context $Context
            [void](Invoke-ForeverMutationAndAttest -Context $Context -Phase asset-upload-started -Published $true -AssetCount 1 -Mutation {
                [void](Invoke-ForeverGh -Arguments @('release', 'edit', $Context.Tag, '--repo', $Context.Repository, '--draft=false', '--prerelease', '--latest=false'))
            } -AdditionalCheck { param($observed) Assert-ForeverPublishedEvidence -Context $Context -Release $observed })
        }
        'Verify' {
            [void](Wait-ForeverReleaseState -Context $Context -Phase asset-upload-started -Published $true -AssetCount 1 -AdditionalCheck {
                param($observed) Assert-ForeverPublishedEvidence -Context $Context -Release $observed
            })
        }
        default { throw "Unsupported Forever release mode '$SelectedMode'." }
    }
}

if ($LibraryOnly) { return }
if ($SelfTest) { & (Join-Path $PSScriptRoot 'test-forever-release-manager.ps1'); return }
if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $ExpectedCommitSha -cnotmatch '^[0-9a-f]{40}$') { throw 'Invalid repository or immutable commit identity.' }
. (Join-Path $PSScriptRoot 'forever-release-contract.ps1')
$sourceRoot = Split-Path -Parent $PSScriptRoot
$contract = Get-StatsProForeverReleaseContract -SourceRoot $sourceRoot -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha
$context = [pscustomobject]@{ Repository = $Repository; Tag = $ExpectedTag; Commit = $ExpectedCommitSha
    Version = $contract.Version; RunId = $ExpectedRunId; RunAttempt = $ExpectedRunAttempt }
if ($Mode -ne 'RefuseExisting') {
    [void](Read-StatsProForeverReleaseCandidate -Contract $contract -Repository $Repository -RunId $ExpectedRunId -RunAttempt $ExpectedRunAttempt -ArchivePath $ArchivePath -CandidatePath $ReleaseJsonPath -ExpectedCandidateSha256 $ExpectedCandidateSha256 -ExpectedArchiveSha256 $ExpectedArchiveSha256)
    if ([IO.Path]::GetFullPath($NotesPath) -cne [IO.Path]::GetFullPath($contract.ChangelogPath)) { throw 'NotesPath must be the validated cumulative Forever changelog.' }
    $context | Add-Member -NotePropertyMembers @{ Notes = ([IO.File]::ReadAllText($NotesPath).Replace("`r`n", "`n").Replace("`r", "`n")).TrimEnd([char[]]"`n")
        ArchivePath = (Resolve-Path -LiteralPath $ArchivePath).Path; ArchiveName = $contract.ArchiveName
        ArchiveSize = (Get-Item -LiteralPath $ArchivePath).Length; ArchiveSha256 = $ExpectedArchiveSha256; CandidateSha256 = $ExpectedCandidateSha256 }
}
Invoke-ForeverReleaseMode -Context $context -SelectedMode $Mode
Write-Host "Forever release $Mode verified for $ExpectedTag."
