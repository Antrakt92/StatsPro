$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'manage-forever-release.ps1') -LibraryOnly
$checks = 0
function Assert-Test([bool]$Value, [string]$Description) {
    if (-not $Value) { throw "Forever manager self-test failed: $Description" }
    $script:checks++
}
function Assert-Rejected([scriptblock]$Action, [string]$Description) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    Assert-Test $rejected $Description
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("statspro-forever-manager-test-" + [guid]::NewGuid().ToString('N') + '.zip')
[IO.File]::WriteAllText($fixture, 'bounded archive fixture')
try {
    $context = [pscustomobject]@{ Repository = 'Owner/StatsPro'; Tag = 'forever-v1.18.1'; Commit = ('a' * 40)
        Version = '1.18.1'; RunId = '123'; RunAttempt = '1'; Notes = "# Forever changelog`n`n## 1.18.1`nCurrent notes`n`n## 1.18.0`nOriginal notes"
        ArchivePath = $fixture; ArchiveName = 'StatsPro-v1.18.1-Forever-beta.zip'; ArchiveSize = (Get-Item $fixture).Length
        ArchiveSha256 = (Get-FileHash $fixture -Algorithm SHA256).Hash.ToLowerInvariant(); CandidateSha256 = ('b' * 64) }
    $script:remote = $null
    $script:mutations = [Collections.Generic.List[string]]::new()
    $script:attestedCommit = $context.Commit
    $script:remoteCommit = $context.Commit
    $script:failUpload = $false
    $script:attestationFailuresRemaining = 0
    function Invoke-ForeverGh {
        param([string[]]$Arguments, [switch]$AllowMissing)
        if ($Arguments[0] -eq 'api') {
            if ($Arguments[1] -like '*/git/ref/tags/*') {
                return (@{ object = @{ type = 'commit'; sha = $script:remoteCommit } } | ConvertTo-Json -Depth 5)
            }
            if ($null -eq $script:remote) { return $null }
            return ($script:remote | ConvertTo-Json -Depth 8)
        }
        switch ($Arguments[1]) {
            'create' {
                $script:mutations.Add('create')
                Assert-Test ($Arguments -contains '--draft' -and $Arguments -contains '--prerelease' -and $Arguments -contains '--latest=false' -and $Arguments -contains '--verify-tag') 'draft command preserves beta/latest/tag boundary'
                $body = [IO.File]::ReadAllText($Arguments[[Array]::IndexOf($Arguments, '--notes-file') + 1])
                $script:remote = [pscustomobject]@{ tag_name = $context.Tag; name = "StatsPro $($context.Version) — Forever Beta"
                    prerelease = $true; draft = $true; body = $body; immutable = $false; assets = @() }
            }
            'edit' {
                $script:mutations.Add('edit')
                if ($Arguments -contains '--notes-file') {
                    $script:remote.body = [IO.File]::ReadAllText($Arguments[[Array]::IndexOf($Arguments, '--notes-file') + 1])
                } else {
                    Assert-Test ($Arguments -contains '--draft=false' -and $Arguments -contains '--prerelease' -and $Arguments -contains '--latest=false') 'publication preserves prerelease and latest=false'
                    $script:remote.draft = $false; $script:remote.immutable = $true
                }
            }
            'upload' {
                $script:mutations.Add('upload')
                if ($script:failUpload) { throw 'unknown upload outcome' }
                Assert-Test (-not ($Arguments -contains '--clobber')) 'asset replacement is forbidden'
                $script:remote.assets = @([pscustomobject]@{ name = $context.ArchiveName; size = $context.ArchiveSize; state = 'uploaded'; digest = "sha256:$($context.ArchiveSha256)" })
            }
            'verify' {
                if ($script:attestationFailuresRemaining -gt 0) { $script:attestationFailuresRemaining--; throw 'attestation not visible yet' }
                return (@{ verificationResult = @{ statement = @{ subject = @(@{ uri = "pkg:github/$($context.Repository)@$($context.Tag)"; digest = @{ sha1 = $script:attestedCommit } }) } } } | ConvertTo-Json -Depth 8)
            }
            'verify-asset' { Assert-Test ($Arguments[2] -ceq $context.Tag -and $Arguments[3] -ceq $fixture) 'exact archive attestation command' }
            'download' {
                $directory = $Arguments[[Array]::IndexOf($Arguments, '--dir') + 1]
                [IO.File]::WriteAllBytes((Join-Path $directory $context.ArchiveName), [IO.File]::ReadAllBytes($fixture))
                Assert-Test ($Arguments -contains $context.ArchiveName -and $Arguments[2] -ceq $context.Tag) 'digest fallback downloads exact tag and asset'
            }
            default { throw "Unexpected mocked GitHub command: $($Arguments -join ' ')" }
        }
        return ''
    }
    Invoke-ForeverReleaseMode $context RefuseExisting
    Assert-Test ($mutations.Count -eq 0) 'read-only preflight does not mutate'
    $script:remoteCommit = 'c' * 40
    Assert-Rejected { Invoke-ForeverReleaseMode $context CreateDraft } 'wrong remote commit fails before creation'
    Assert-Test ($mutations.Count -eq 0) 'wrong commit has no effects'
    $script:remoteCommit = $context.Commit
    Invoke-ForeverReleaseMode $context CreateDraft
    Assert-Rejected { Invoke-ForeverReleaseMode $context RefuseExisting } 'existing draft prevents restart'
    Assert-Rejected { Invoke-ForeverReleaseMode $context CreateDraft } 'existing draft cannot be claimed'
    Assert-Rejected { Invoke-ForeverReleaseMode $context AttachAssets } 'assets cannot bypass marketplace boundary'
    $script:remote.prerelease = $false
    Assert-Rejected { Invoke-ForeverReleaseMode $context MarkMarketplaceStarted } 'stable release state is rejected'
    $script:remote.prerelease = $true
    Invoke-ForeverReleaseMode $context MarkMarketplaceStarted
    Assert-Rejected { Invoke-ForeverReleaseMode $context MarkMarketplaceStarted } 'marketplace-started state cannot be replayed'
    $script:failUpload = $true
    $before = $mutations.Count
    Assert-Rejected { Invoke-ForeverReleaseMode $context AttachAssets } 'unknown upload fails closed'
    Assert-Test ($mutations.Count -eq $before + 2) 'unknown upload performs one boundary mutation and one upload attempt'
    $before = $mutations.Count
    Assert-Rejected { Invoke-ForeverReleaseMode $context AttachAssets } 'unknown upload cannot be replayed even with zero assets'
    Assert-Test ($mutations.Count -eq $before) 'rejected unknown upload retry has no effects'
    $script:failUpload = $false
    # Build a separate pristine mock scenario; production never rewinds a boundary marker.
    $script:remote.body = Get-ForeverReleaseBody -Context $context -Phase marketplace-started
    Invoke-ForeverReleaseMode $context AttachAssets
    Assert-Rejected { Invoke-ForeverReleaseMode $context AttachAssets } 'asset upload cannot be replayed after success'
    $script:remote.assets[0].digest = 'sha256:' + ('c' * 64)
    Assert-Rejected { Invoke-ForeverReleaseMode $context Publish } 'wrong asset digest blocks publication'
    $script:remote.assets[0].digest = "sha256:$($context.ArchiveSha256)"
    $script:remote.assets += $script:remote.assets[0]
    Assert-Rejected { Invoke-ForeverReleaseMode $context Publish } 'extra assets block publication'
    $script:remote.assets = @($script:remote.assets[0])
    $script:remote.assets[0].digest = $null
    Assert-ForeverRelease -Context $context -Release $script:remote -Phase asset-upload-started -AssetCount 1
    Assert-ForeverRemoteAsset -Context $context -Release $script:remote
    $script:remote.assets[0].digest = "sha256:$($context.ArchiveSha256)"
    [IO.File]::AppendAllText($fixture, ' changed')
    Assert-Rejected { Invoke-ForeverReleaseMode $context Publish } 'changed local archive blocks publication'
    [IO.File]::WriteAllText($fixture, 'bounded archive fixture')
    $savedRun = $context.RunAttempt
    $context.RunAttempt = '2'
    Assert-Rejected { Invoke-ForeverReleaseMode $context Publish } 'different run attempt cannot claim started transaction'
    $context.RunAttempt = $savedRun
    $script:attestationFailuresRemaining = 1
    $before = $mutations.Count
    Invoke-ForeverReleaseMode $context Publish
    Assert-Test ($mutations.Count -eq $before + 1) 'attestation visibility retries never repeat publication'
    Invoke-ForeverReleaseMode $context Verify
    $script:attestedCommit = 'c' * 40
    Assert-Rejected { Invoke-ForeverReleaseMode $context Verify } 'wrong attested commit fails verification'
    $script:attestedCommit = $context.Commit
    $script:remote.immutable = $false
    Assert-Rejected { Invoke-ForeverReleaseMode $context Verify } 'mutable publication is rejected'
    $script:remote.immutable = $true
    $script:remote.body += ' changed'
    Assert-Rejected { Invoke-ForeverReleaseMode $context Verify } 'notes and protocol marker cannot change'
    Assert-Rejected { & (Join-Path $PSScriptRoot 'manage-github-release.ps1') -Mode Verify } 'stable dispatcher rejects beta-only Verify'
    Write-Host "Forever release manager self-test: PASS ($checks checks)."
} finally { Remove-Item -LiteralPath $fixture -Force }
