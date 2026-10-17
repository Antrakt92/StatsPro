$ErrorActionPreference = 'Stop'
$ArchivePath = 'caller-archive-path'
$SourceRoot = 'caller-source-root'
$LibraryOnly = $false
$SelfTest = $true
. (Join-Path $PSScriptRoot 'forever-release-contract.ps1')
if ($ArchivePath -cne 'caller-archive-path' -or $SourceRoot -cne 'caller-source-root' -or $LibraryOnly -or -not $SelfTest) {
    throw 'Importing the Forever contract replaced caller parameters'
}
$script:publishedForeverTags = @()
$script:publishedInventoryFailure = $false
$script:publishedInventoryReads = 0
$script:realPublishedForeverTagReader = ${function:Get-StatsProPublishedForeverTags}
function Get-StatsProPublishedForeverTags {
    param([string]$Repository)
    $script:publishedInventoryReads++
    if ($script:publishedInventoryFailure) { throw 'Fixture published inventory unavailable' }
    $script:publishedForeverTags
}
$count = 0
function Assert-ForeverTestRejected {
    param([scriptblock]$Action, [string]$Pattern)
    $script:count++
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected Forever release rejection: $Pattern"
}
$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$fixture = Join-Path $tempBase ('statspro-forever-release-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $script:inventoryNativeCalls = 0
    & {
        function Get-Command {
            param([string]$Name, [string]$CommandType, [string]$ErrorAction)
            if ($Name -cne 'gh' -or $CommandType -cne 'Application') { throw 'Unexpected inventory executable lookup' }
            [pscustomobject]@{ Source = '/usr/bin/gh' }
            [pscustomobject]@{ Source = '/bin/gh' }
        }
        function Invoke-StatsProNativeCapture {
            param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [string]$Description)
            $script:inventoryNativeCalls++
            if ($FilePath -cne '/usr/bin/gh' -or
                ($Arguments -join '|') -cne 'api|--paginate|--slurp|repos/Antrakt92/StatsPro/releases?per_page=100') {
                throw 'Inventory must invoke one executable path with the exact read-only release request'
            }
            [pscustomobject]@{ ExitCode = 0; Output = @('[[]]') }
        }
        $tags = @(& $script:realPublishedForeverTagReader -Repository 'Antrakt92/StatsPro')
        if ($tags.Count -ne 0) { throw 'Empty inventory produced published tags' }
    }
    if ($script:inventoryNativeCalls -ne 1) { throw 'Inventory should execute one resolved gh application' }
    $inventoryFixture = @'
[[{"tag_name":"forever-v1.18.1","draft":false,"prerelease":true,"published_at":"2026-10-15T12:00:00Z"},{"tag_name":"forever-v1.18.2","draft":true,"prerelease":true,"published_at":null}],[{"tag_name":"v1.18.2","draft":false,"prerelease":false,"published_at":"2026-10-15T12:00:00Z"},{"tag_name":"forever-v1.18.3","draft":false,"prerelease":false,"published_at":"2026-10-15T12:00:00Z"}]]
'@
    $published = @(ConvertFrom-StatsProPublishedForeverInventory $inventoryFixture)
    if ($published.Count -ne 1 -or $published[0] -cne 'forever-v1.18.1') { throw 'Published release inventory included draft or wrong-channel entries' }
    Assert-ForeverTestRejected { ConvertFrom-StatsProPublishedForeverInventory '{"message":"API failure"}' } 'paginated arrays'
    Assert-ForeverTestRejected { ConvertFrom-StatsProPublishedForeverInventory '[[{"tag_name":"forever-v1.18.1"}]]' } 'malformed'
    $realRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $files = @((Get-ForeverPackageMap).Values) + @(
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
    foreach ($relative in @($files | Select-Object -Unique)) {
        $target = Join-Path $fixture $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        if (Test-Path -LiteralPath (Join-Path $realRoot $relative) -PathType Leaf) {
            Copy-Item -LiteralPath (Join-Path $realRoot $relative) -Destination $target
        } else { [System.IO.File]::WriteAllText($target, 'fixture') }
    }
    [System.IO.File]::WriteAllText((Join-Path $fixture '.gitattributes'), "* -text`n")
    [System.IO.File]::WriteAllText((Join-Path $fixture 'StatsPro.lua'), 'local version = "@project-version@"')
    [System.IO.File]::WriteAllText((Join-Path $fixture 'StatsPro.toc'), "## Version: 1.18.2`n")
    $tocPath = Join-Path $fixture 'StatsPro_Forever.toc'
    $toc = [System.IO.File]::ReadAllText($tocPath)
    $toc = [regex]::Replace($toc, '(?m)^## Version:[^\r\n]+', '## Version: 1.18.1')
    $toc = [regex]::Replace($toc, '(?m)^## IconTexture:[^\r\n]+', '## IconTexture: Interface\AddOns\StatsPro\textures\forever-logo.png')
    [System.IO.File]::WriteAllText($tocPath, $toc)
    $history = "## 1.18.0 - 13-Oct-2026 — Forever beta`n`n- Original beta changes.`n`n## 1.17.21 - 12-Oct-2026 — Earlier`n`n- Earlier history.`n"
    [System.IO.File]::WriteAllText((Join-Path $fixture 'CHANGELOG.md'), "# Changelog`n`n$history")
    $notesPath = Join-Path $fixture 'CHANGELOG-FOREVER.md'
    $notes = "# Forever changelog`n`n## 1.18.1 - 15-Oct-2026 — Clearer settings`n`n- Beta usability improvements.`n`n$history"
    [System.IO.File]::WriteAllText($notesPath, $notes)
    [void](Invoke-StatsProForeverGit $fixture @('init','--initial-branch=main'))
    [void](Invoke-StatsProForeverGit $fixture @('add','.'))
    [void](Invoke-StatsProForeverGit $fixture @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','core.hooksPath=NUL','commit','-m','Fixture release sources'))
    [void](Invoke-StatsProForeverGit $fixture @('tag','v1.18.0'))
    $commit = (Invoke-StatsProForeverGit $fixture @('rev-parse','HEAD')).Trim()
    [void](Invoke-StatsProForeverGit $fixture @('tag','forever-v1.18.1'))
    [void](Invoke-StatsProForeverGit $fixture @('update-ref','refs/remotes/origin/main',$commit))
    $contract = Get-StatsProForeverReleaseContract $fixture 'forever-v1.18.1' $commit
    if ($script:publishedInventoryReads -ne 1) { throw 'Exact release contract should read publication inventory once' }
    $script:publishedInventoryFailure = $true
    Assert-ForeverTestRejected { Get-StatsProForeverReleaseContract $fixture 'forever-v1.18.1' $commit } 'published inventory unavailable'
    $script:publishedInventoryFailure = $false
    if ($contract.RetailVersion -cne '1.18.2' -or $contract.PackageTag -cne 'v1.18.1' -or
        @($contract.AssetNames).Count -ne 1 -or $contract.AssetNames[0] -cne 'StatsPro-v1.18.1-Forever-beta.zip') {
        throw 'Forever release changed Retail identity or selected extra assets'
    }
    foreach ($badTag in @('v1.18.1','forever-v01.18.1','forever-v1.18.1-beta','FOREVER-v1.18.1',"forever-v1.18.1`n",'forever-v2147483648.0.0')) {
        Assert-ForeverTestRejected { Get-StatsProForeverReleaseContract $fixture $badTag } 'tag|component|bounded|maximum|supported'
    }
    Assert-ForeverTestRejected { Get-StatsProForeverReleaseContract $fixture 'forever-v1.18.2' } 'version differs'
    Assert-ForeverTestRejected { Get-StatsProForeverReleaseContract $fixture 'forever-v1.18.1' ('a' * 40) } 'HEAD differs'
    [System.IO.File]::AppendAllText((Join-Path $fixture 'StatsPro.lua'), '-- drift')
    Assert-ForeverTestRejected { Get-StatsProForeverReleaseContract $fixture 'forever-v1.18.1' $commit } 'differs from immutable'
    [System.IO.File]::WriteAllText((Join-Path $fixture 'StatsPro.lua'), 'local version = "@project-version@"')
    [System.IO.File]::WriteAllText($notesPath, $notes.Replace('Original beta changes.', 'Truncated history.'))
    Assert-ForeverTestRejected { Get-StatsProForeverReleaseContract $fixture 'forever-v1.18.1' $commit } 'differs from immutable'
    [System.IO.File]::WriteAllText($notesPath, $notes)
    # Only canonical newline conversion is accepted between Linux and Windows.
    [System.IO.File]::WriteAllText($notesPath, $notes.Replace("`n", "`r`n"))
    $crlf = Get-StatsProForeverReleaseContract $fixture 'forever-v1.18.1' $commit
    if ($crlf.ChangelogSha256 -cne $contract.ChangelogSha256) { throw 'Canonical notes hash changed under CRLF conversion' }
    [System.IO.File]::WriteAllText($notesPath, $notes)
    & (Join-Path $realRoot 'scripts/build-forever-package.ps1') -SourceRoot $fixture -OutputRoot (Join-Path $fixture 'output')
    $archivePath = Join-Path $fixture ('output/' + $contract.ArchiveName)
    $archive = Assert-StatsProForeverReleaseArchive $contract $archivePath
    Assert-ForeverTestRejected { Assert-StatsProForeverReleaseArchive $contract $archivePath ('0' * 64) } 'digest differs'
    $candidatePath = Join-Path $fixture 'candidate.json'
    $created = New-StatsProForeverReleaseCandidate $contract 'owner/repo' '123' '1' $archivePath $candidatePath
    [void](Read-StatsProForeverReleaseCandidate $contract 'owner/repo' '123' '1' $archivePath $candidatePath $created.CandidateSha256 $archive.Sha256)
    Assert-ForeverTestRejected { New-StatsProForeverReleaseCandidate $contract 'owner/repo' '123' '1' $archivePath $candidatePath } 'already exists'
    Assert-ForeverTestRejected { Read-StatsProForeverReleaseCandidate $contract 'owner/repo' '123' '2' $archivePath $candidatePath $created.CandidateSha256 $archive.Sha256 } 'fields differ'
    Assert-ForeverTestRejected { Read-StatsProForeverReleaseCandidate $contract 'other/repo' '123' '1' $archivePath $candidatePath $created.CandidateSha256 $archive.Sha256 } 'fields differ'
    Assert-ForeverTestRejected { Read-StatsProForeverReleaseCandidate $contract 'owner/repo' '123' '1' $archivePath $candidatePath ('0' * 64) $archive.Sha256 } 'candidate digest differs'
    $candidateText = [System.IO.File]::ReadAllText($candidatePath)
    [System.IO.File]::WriteAllText($candidatePath, $candidateText.Replace('"schemaVersion": 1', '"schemaVersion": 1, "schemaVersion": 1'))
    $duplicateHash = (Get-FileHash $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-ForeverTestRejected { Read-StatsProForeverReleaseCandidate $contract 'owner/repo' '123' '1' $archivePath $candidatePath $duplicateHash $archive.Sha256 } 'fields differ'
    [System.IO.File]::WriteAllText($candidatePath, $candidateText)
    foreach ($state in @(@($true,$false),@($false,$true),@($true,$true))) {
        Assert-ForeverTestRejected { Assert-StatsProForeverFreshPublication $state[0] $state[1] } 'refusing overwrite or upload retry'
    }
    Assert-StatsProForeverFreshPublication $false $false
    $zip = [System.IO.Compression.ZipFile]::Open($archivePath, [System.IO.Compression.ZipArchiveMode]::Update)
    try { [void]$zip.CreateEntry('StatsPro/StatsPro_ArchonTargets.lua') } finally { $zip.Dispose() }
    Assert-ForeverTestRejected { Assert-StatsProForeverReleaseArchive $contract $archivePath } 'extra entries'
    $tocNext = $toc.Replace('## Version: 1.18.1', '## Version: 1.18.2')
    $notesStart = [regex]::Match($notes, '(?m)^## 1\.18\.1 - ').Index
    $nextNotes = "# Forever changelog`n`n## 1.18.2 - 16-Oct-2026 — Next beta`n`n- Next changes.`n`n" + $notes.Substring($notesStart)
    [System.IO.File]::WriteAllText($tocPath, $tocNext)
    [System.IO.File]::WriteAllText($notesPath, $nextNotes)
    [void](Invoke-StatsProForeverGit $fixture @('add','StatsPro_Forever.toc','CHANGELOG-FOREVER.md'))
    [void](Invoke-StatsProForeverGit $fixture @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','core.hooksPath=NUL','commit','-m','Next beta'))
    [void](Invoke-StatsProForeverGit $fixture @('tag','forever-v1.18.2'))
    $nextCommit = (Invoke-StatsProForeverGit $fixture @('rev-parse','HEAD')).Trim()
    [void](Invoke-StatsProForeverGit $fixture @('update-ref','refs/remotes/origin/main',$nextCommit))
    $script:publishedForeverTags = @('forever-v1.18.1')
    [void](Get-StatsProForeverReleaseContract $fixture 'forever-v1.18.2' $nextCommit)
    [System.IO.File]::WriteAllText($tocPath, $tocNext.Replace('1.18.2', '1.18.3'))
    [System.IO.File]::WriteAllText($notesPath, "# Forever changelog`n`n## 1.18.3 - 17-Oct-2026 — Incomplete history`n`n- Current changes.`n`n$history")
    [void](Invoke-StatsProForeverGit $fixture @('add','StatsPro_Forever.toc','CHANGELOG-FOREVER.md'))
    [void](Invoke-StatsProForeverGit $fixture @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','core.hooksPath=NUL','commit','-m','Truncated beta history'))
    [void](Invoke-StatsProForeverGit $fixture @('tag','forever-v1.18.3'))
    $truncatedCommit = (Invoke-StatsProForeverGit $fixture @('rev-parse','HEAD')).Trim()
    [void](Invoke-StatsProForeverGit $fixture @('update-ref','refs/remotes/origin/main',$truncatedCommit))
    # Local tags exist for both earlier attempts, but neither publication is
    # required in the changelog when no published release identifies them.
    $script:publishedForeverTags = @()
    [void](Get-StatsProForeverReleaseContract $fixture 'forever-v1.18.3' $truncatedCommit)
    $script:publishedForeverTags = @('forever-v1.18.1')
    Assert-ForeverTestRejected { Get-StatsProForeverReleaseContract $fixture 'forever-v1.18.3' $truncatedCommit } 'previous beta cumulative'
    $script:publishedForeverTags = @('forever-v1.18.1','forever-v1.18.2')
    Assert-ForeverTestRejected { Get-StatsProForeverReleaseContract $fixture 'forever-v1.18.3' $truncatedCommit } 'previous beta cumulative'
    Write-Host "Forever release contract tests passed ($count rejection cases): exact beta identity, independent Retail, immutable source, archive, canonical notes, candidate binding and no replay."
}
finally {
    $resolved = [System.IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith($tempBase.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unsafe Forever test cleanup path'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
