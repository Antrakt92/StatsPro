param(
    [ValidateSet("RefuseExisting", "CreateDraft", "AttachAssets", "Publish")]
    [string]$Mode,
    [string]$Repository,
    [string]$ExpectedTag,
    [string]$ExpectedCommitSha,
    [string]$ArchivePath,
    [string]$ReleaseJsonPath,
    [string]$NotesPath,
    [int]$AttestationAttempts = 6,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

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

    if ($Value -notmatch "^v\d+\.\d+\.\d+$") {
        throw "Malformed release tag '$Value'. Expected vX.Y.Z."
    }
}

function Assert-CommitSha {
    param([string]$Value)

    if ($Value -notmatch "^[0-9a-f]{40}$") {
        throw "Malformed expected commit SHA '$Value'. Expected 40 lowercase hex characters."
    }
}

function Assert-RepositoryName {
    param([string]$Value)

    if ($Value -notmatch "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") {
        throw "Malformed GitHub repository '$Value'. Expected owner/name."
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

    $matches = @($Releases | Where-Object { [string]$_.tag_name -eq $ExpectedTag })
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
    $releases = @(ConvertFrom-JsonCompat ($result.Output -join "`n"))
    return Select-GitHubReleaseByTag -Releases $releases -ExpectedTag $ExpectedTag
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
    if ($actual -ne $ExpectedCommitSha) {
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

function Assert-ExactAssetSet {
    param(
        [object]$Release,
        [string[]]$ExpectedNames
    )

    $actual = @(Get-ReleaseAssetNames -Release $Release)
    $actualUnique = @($actual | Sort-Object -Unique)
    $expectedUnique = @($ExpectedNames | Sort-Object -Unique)
    if ($actual.Count -ne $actualUnique.Count) {
        throw "Release contains duplicate asset names: $($actual -join ', ')"
    }
    if ($actualUnique.Count -ne $expectedUnique.Count -or (Compare-Object -ReferenceObject $expectedUnique -DifferenceObject $actualUnique)) {
        throw "Release assets are '$($actualUnique -join ', ')'; expected '$($expectedUnique -join ', ')'."
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
    if ([string]$Release.tag_name -ne $ExpectedTag) {
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
        if ([string]$asset.state -ne "uploaded") {
            throw "Draft asset $name is in state '$($asset.state)', expected 'uploaded'."
        }
        $expectedSize = (Get-Item -LiteralPath $path).Length
        if ([long]$asset.size -ne $expectedSize) {
            throw "Draft asset $name size is $($asset.size), expected $expectedSize."
        }
        $expectedDigest = "sha256:$(Get-LowercaseFileSha256 -Path $path)"
        if ([string]$asset.digest -ne $expectedDigest) {
            throw "Draft asset $name digest is '$($asset.digest)', expected '$expectedDigest'."
        }
    }
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
    if ([System.IO.Path]::GetFileName($archive) -ne "StatsPro-$ExpectedTag.zip") {
        throw "Archive filename must be StatsPro-$ExpectedTag.zip."
    }
    if ([System.IO.Path]::GetFileName($releaseJson) -ne "release.json") {
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

function Test-ContainsGitHubTokenReference {
    param([string]$Text)

    return $Text -match @'
(?ix)
\b(?:
    secrets\s*(?:\.\s*GITHUB_TOKEN\b|\[\s*['"]\s*GITHUB_TOKEN\s*['"]\s*\])
  | github\s*(?:\.\s*token\b|\[\s*['"]\s*token\s*['"]\s*\])
)
'@
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
            (Test-ContainsGitHubTokenReference -Text $checkoutStep.Value)) {
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

    $allowedStepNames = @(
        'Refuse existing release marker',
        'Create draft release marker',
        'Attach validated assets to draft',
        'Publish immutable GitHub release',
        'Validate published immutable release assets'
    )
    $stepBlocks = @([regex]::Matches($WorkflowText, '(?ms)^\s{6}- name: .+?\s*$.*?(?=^\s{6}- name:|\z)'))
    $allowedBlocks = [System.Collections.Generic.List[System.Text.RegularExpressions.Match]]::new()

    foreach ($allowedName in $allowedStepNames) {
        $matchingBlocks = @($stepBlocks | Where-Object {
            (Get-WorkflowStepName -StepBlock $_) -eq $allowedName
        })
        if ($matchingBlocks.Count -ne 1) {
            throw "Release workflow must contain exactly one GitHub-management step '$allowedName'."
        }
        $block = $matchingBlocks[0]
        $tokenLines = @([regex]::Matches(
            $block.Value,
            '(?m)^\s{10}GH_TOKEN:\s*\$\{\{\s*secrets\.GITHUB_TOKEN\s*\}\}\s*$'
        ))
        $blockWithoutCanonicalToken = if ($tokenLines.Count -eq 1) {
            $block.Value.Remove($tokenLines[0].Index, $tokenLines[0].Length)
        }
        else {
            $block.Value
        }
        if ($tokenLines.Count -ne 1 -or
            $block.Value -match '(?m)^\s{10}(?:GITHUB_TOKEN|GITHUB_OAUTH):' -or
            (Test-ContainsGitHubTokenReference -Text $blockWithoutCanonicalToken) -or
            $block.Value -match '(?m)^\s{8}uses:') {
            throw "GitHub token must be scoped only as GH_TOKEN in GitHub-management shell step '$allowedName'."
        }
        $allowedBlocks.Add($block)
    }

    $outsideAllowedSteps = $WorkflowText
    foreach ($block in @($allowedBlocks | Sort-Object Index -Descending)) {
        $outsideAllowedSteps = $outsideAllowedSteps.Remove($block.Index, $block.Length)
    }
    if ((Test-ContainsGitHubTokenReference -Text $outsideAllowedSteps) -or
        $outsideAllowedSteps -match '(?m)^\s*(?:GH_TOKEN|GITHUB_TOKEN|GITHUB_OAUTH):') {
        throw "GitHub token must not be exposed outside GitHub-management shell steps."
    }
}

function Assert-ReleaseWorkflowBoundary {
    param([string]$WorkflowText)

    Assert-WorkflowCheckoutCredentialBoundary `
        -WorkflowText $WorkflowText `
        -JobNames @('preflight', 'release')
    Assert-ReleaseGitHubTokenScope -WorkflowText $WorkflowText

    $orderedSteps = @(
        "- name: Refuse existing release marker",
        "- name: Recheck release ancestry before final package build",
        "- name: Rebuild package without publishing",
        "- name: Compare rebuilt package and validate again",
        "- name: Create draft release marker",
        "- name: Validate exact package immediately before marketplace upload",
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
        $preUploadStep.Value.IndexOf('STATSPRO_ARCHIVE_PATH: ${{ steps.rebuild-package.outputs.archive_path }}', [System.StringComparison]::Ordinal) -lt 0 -or
        $preUploadStep.Value.IndexOf('STATSPRO_PROJECT_VERSION: ${{ steps.rebuild-package.outputs.project_version }}', [System.StringComparison]::Ordinal) -lt 0) {
        throw "The immediate pre-upload step must bind the exact Packager output, package manifest, tag checkout, and GITHUB_SHA."
    }
    if ($preUploadStep.Index + $preUploadStep.Length -ne $marketplaceStep.Index) {
        throw "The exact package boundary must be the final workflow step before marketplace publication."
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

function Get-AttachAssetsGhArguments {
    param([string]$Repository, [string]$ExpectedTag, [string]$ArchivePath, [string]$ReleaseJsonPath)
    return @(
        "release", "upload", $ExpectedTag,
        $ArchivePath,
        $ReleaseJsonPath,
        "--repo", $Repository
    )
}

function Get-PublishGhArguments {
    param([string]$Repository, [string]$ExpectedTag)
    return @("release", "edit", $ExpectedTag, "--repo", $Repository, "--draft=false", "--latest")
}

function Invoke-SelfTest {
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
    if ($createArguments -notcontains "--draft" -or $createArguments -notcontains "--verify-tag") {
        throw "CreateDraft gh arguments must create a draft for an existing tag."
    }
    $attachArguments = Get-AttachAssetsGhArguments -Repository "owner/repo" -ExpectedTag $tag -ArchivePath "StatsPro-$tag.zip" -ReleaseJsonPath "release.json"
    if ($attachArguments -contains "--clobber") {
        throw "AttachAssets gh arguments must never clobber a draft asset."
    }
    $publishArguments = Get-PublishGhArguments -Repository "owner/repo" -ExpectedTag $tag
    if ($publishArguments -notcontains "--draft=false") {
        throw "Publish gh arguments must publish the prepared draft."
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
    Assert-ThrowsMatch "job-level GitHub token rejected" {
        $replacement = $releaseJobBlock.Value.Replace(
            '  release:',
            "  release:`n    env:`n      GH_TOKEN: $githubTokenExpression")
        Assert-ReleaseWorkflowBoundary -WorkflowText (& $replaceReleaseJob $replacement)
    } "outside GitHub-management shell steps"
    Assert-ThrowsMatch "GitHub token in first Packager rejected" {
        $mutated = $workflowText.Replace(
            '      - name: Build package without publishing',
            "      - name: Build package without publishing`n        env:`n          GH_TOKEN: $githubTokenExpression")
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "outside GitHub-management shell steps"
    Assert-ThrowsMatch "bracket GitHub secret in first Packager rejected" {
        $mutated = $workflowText.Replace(
            '      - name: Build package without publishing',
            "      - name: Build package without publishing`n        env:`n          GH_TOKEN: $bracketSecretTokenExpression")
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "outside GitHub-management shell steps"
    Assert-ThrowsMatch "GitHub token in rebuild Packager rejected" {
        $mutated = $workflowText.Replace(
            '      - name: Rebuild package without publishing',
            "      - name: Rebuild package without publishing`n        env:`n          GH_TOKEN: $githubTokenExpression")
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "outside GitHub-management shell steps"
    Assert-ThrowsMatch "GitHub token in non-management shell step rejected" {
        $mutated = $workflowText.Replace(
            '      - name: Trim release changelog',
            "      - name: Trim release changelog`n        env:`n          GH_TOKEN: $githubTokenExpression")
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "outside GitHub-management shell steps"
    Assert-ThrowsMatch "bracket GitHub context token in non-management step rejected" {
        $mutated = $workflowText.Replace(
            '      - name: Trim release changelog',
            "      - name: Trim release changelog`n        env:`n          GH_TOKEN: $bracketContextTokenExpression")
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "outside GitHub-management shell steps"
    Assert-ThrowsMatch "single-pending release queue rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace "queue: max", "queue: single")
    } "queue: max"
    Assert-ThrowsMatch "missing publication ancestry recheck rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace "check-release-ancestry\.ps1", "echo ancestry-skipped")
    } "fresh ancestry gate"
    Assert-ThrowsMatch "disabled exact pre-upload switch rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace "-RequireExactPackagerProjectVersion", '-RequireExactPackagerProjectVersion:$false')
    } "immediate pre-upload step"
    Assert-ThrowsMatch "marketplace tree reuse flags rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace "args: -c -e -o", "args: -c -e")
    } "reusing the validated tree"
    $publishMarker = "      - name: Publish package to marketplaces"
    $insertedStep = "      - name: Unexpected intervening step`n        run: echo changed`n`n"
    Assert-ThrowsMatch "intervening pre-upload step rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace($publishMarker, $insertedStep + $publishMarker)
    } "final workflow step"
    $preUploadBlock = [regex]::Match($workflowText, "(?ms)^\s{6}- name: Validate exact package immediately before marketplace upload\s*$.*?(?=^\s{6}- name:|\z)")
    $publishBlock = [regex]::Match($workflowText, "(?ms)^\s{6}- name: Publish package to marketplaces\s*$.*?(?=^\s{6}- name:|\z)")
    $swappedWorkflow = $workflowText.Substring(0, $preUploadBlock.Index) +
        $publishBlock.Value + $preUploadBlock.Value +
        $workflowText.Substring($publishBlock.Index + $publishBlock.Length)
    Assert-ThrowsMatch "pre-upload validation after marketplace publish rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $swappedWorkflow
    } "out of the required"
    $postPublishMarker = "      - name: Validate marketplace archive and create release metadata"
    Assert-ThrowsMatch "duplicate publishing Packager step rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            $postPublishMarker,
            $publishBlock.Value + $postPublishMarker)
    } "exactly one publishing Packager step"
    Assert-ThrowsMatch "wrong pre-upload Packager output binding rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace 'steps\.rebuild-package\.outputs\.project_version', 'steps.build-package.outputs.project_version')
    } "immediate pre-upload step"
    Assert-ThrowsMatch "GitHub token in marketplace step rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace "WOWI_API_TOKEN: \$\{\{ secrets\.WOWI_API_TOKEN \}\}", 'GITHUB_OAUTH: ${{ secrets.GITHUB_TOKEN }}')
    } "outside GitHub-management shell steps"
    Assert-ThrowsMatch "bracket GitHub token in marketplace Packager rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace "WOWI_API_TOKEN: \$\{\{ secrets\.WOWI_API_TOKEN \}\}", "WOWI_API_TOKEN: $bracketSecretTokenExpression")
    } "outside GitHub-management shell steps"

    Write-Host "GitHub release management self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if ([string]::IsNullOrWhiteSpace($Mode)) {
    throw "Missing -Mode RefuseExisting|CreateDraft|AttachAssets|Publish."
}
Assert-RepositoryName $Repository
Assert-ReleaseTag $ExpectedTag
if ($Mode -in @("CreateDraft", "Publish")) {
    Assert-CommitSha $ExpectedCommitSha
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
    "CreateDraft" {
        $notes = Resolve-RequiredFile -Path $NotesPath -Description "release notes"
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
        Assert-NoExistingRelease -Release $release -ExpectedTag $ExpectedTag
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha
        [void](Invoke-Gh -Arguments (Get-CreateDraftGhArguments -Repository $Repository -ExpectedTag $ExpectedTag -NotesPath $notes))
        $created = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
        Assert-DraftRelease -Release $created -ExpectedTag $ExpectedTag -ExpectedAssets @()
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha
        Write-Host "Draft release marker created for $ExpectedTag."
    }
    "AttachAssets" {
        $paths = Assert-ReleaseAssetPaths -ArchivePath $ArchivePath -ReleaseJsonPath $ReleaseJsonPath -ExpectedTag $ExpectedTag
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
        Assert-DraftRelease -Release $release -ExpectedTag $ExpectedTag -ExpectedAssets @()
        [void](Invoke-Gh -Arguments (Get-AttachAssetsGhArguments -Repository $Repository -ExpectedTag $ExpectedTag -ArchivePath $paths.Archive -ReleaseJsonPath $paths.ReleaseJson))
        $updated = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
        Assert-DraftAssetsMatchLocalFiles -Release $updated -ExpectedTag $ExpectedTag -ArchivePath $paths.Archive -ReleaseJsonPath $paths.ReleaseJson
        Write-Host "Validated release assets attached to draft $ExpectedTag."
    }
    "Publish" {
        $paths = Assert-ReleaseAssetPaths -ArchivePath $ArchivePath -ReleaseJsonPath $ReleaseJsonPath -ExpectedTag $ExpectedTag
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
        Assert-DraftAssetsMatchLocalFiles -Release $release -ExpectedTag $ExpectedTag -ArchivePath $paths.Archive -ReleaseJsonPath $paths.ReleaseJson
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
        Assert-DraftAssetsMatchLocalFiles -Release $release -ExpectedTag $ExpectedTag -ArchivePath $paths.Archive -ReleaseJsonPath $paths.ReleaseJson
        [void](Invoke-Gh -Arguments (Get-PublishGhArguments -Repository $Repository -ExpectedTag $ExpectedTag))

        $lastError = $null
        for ($attempt = 1; $attempt -le $AttestationAttempts; $attempt++) {
            try {
                $published = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag
                Assert-PublishedImmutableRelease -Release $published -ExpectedTag $ExpectedTag
                Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha
                Invoke-ImmutableReleaseAttestationChecks `
                    -Repository $Repository `
                    -ExpectedTag $ExpectedTag `
                    -ExpectedCommitSha $ExpectedCommitSha `
                    -ArchivePath $paths.Archive `
                    -ReleaseJsonPath $paths.ReleaseJson
                Write-Host "Immutable GitHub release published and attested for $ExpectedTag."
                return
            }
            catch {
                $lastError = $_
                if ($attempt -lt $AttestationAttempts) {
                    Start-Sleep -Seconds ([Math]::Min(30, 5 * $attempt))
                }
            }
        }
        throw "Published release $ExpectedTag did not pass immutable attestation checks: $($lastError.Exception.Message)"
    }
}
