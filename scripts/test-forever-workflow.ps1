param([string]$WorkflowPath = (Join-Path $PSScriptRoot '../.github/workflows/forever-release.yml'))
$ErrorActionPreference = 'Stop'

function Assert-ForeverWorkflow {
    param([string]$Text)
    $textLF = $Text.Replace("`r`n", "`n")
    $tagBlock = [regex]::Match($textLF, '(?m)^    tags:\n((?:      [^\n]+\n)+)')
    if (-not $tagBlock.Success -or $tagBlock.Groups[1].Value.Trim() -cne "- 'forever-v*'") {
        throw 'Forever workflow must trigger on its exclusive tag family.'
    }
    $jobs = @{}
    foreach ($match in [regex]::Matches($textLF, '(?ms)^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\z)')) {
        # Only the jobs mapping follows the literal jobs heading.
        if ($match.Index -gt $textLF.IndexOf("`njobs:`n", [StringComparison]::Ordinal)) {
            if ($jobs.ContainsKey($match.Groups[1].Value)) { throw 'Duplicate workflow job.' }
            $jobs[$match.Groups[1].Value] = $match.Groups[2].Value
        }
    }
    if (($jobs.Keys | Sort-Object) -join ',' -cne 'package,publish,verify') { throw 'Unexpected Forever workflow job inventory.' }
    if ($textLF -match '(?m)^permissions:') { throw 'Workflow-level permission escalation is forbidden.' }
    $guard = '    if: ${{ github.event.created == true && github.event.forced == false && github.event.deleted == false }}'
    foreach ($name in @('package', 'publish', 'verify')) {
        $body = $jobs[$name]
        if (@($body -split "`n" | Where-Object { $_ -ceq $guard }).Count -ne 1) { throw "Fresh tag event guard missing on $name." }
        $permissions = [regex]::Match($body, '(?m)^    permissions:\n((?:      [^\n]+\n)+)')
        $expected = if ($name -ceq 'publish') { 'contents: write' } else { 'contents: read' }
        if (-not $permissions.Success -or $permissions.Groups[1].Value.Trim() -cne $expected) { throw "Unexpected permissions on $name." }
        if ($name -cne 'publish' -and $body.Contains('secrets.')) { throw 'Marketplace secrets must remain in the protected publish job.' }
    }
    if ($jobs.publish -notmatch '(?m)^    environment: marketplace-release$') { throw 'Protected marketplace environment missing.' }
    if ($jobs.publish -notmatch '(?m)^    needs: package$' -or $jobs.verify -notmatch '(?m)^    needs: \[package, publish\]$') { throw 'Publication dependency ordering changed.' }
    $canonical = $jobs.package.IndexOf('git config --global core.autocrlf false', [StringComparison]::Ordinal)
    $checkout = $jobs.package.IndexOf('uses: actions/checkout@', [StringComparison]::Ordinal)
    if ($canonical -lt 0 -or $checkout -lt 0 -or $canonical -gt $checkout) { throw 'Canonical LF producer configuration must precede checkout.' }
    foreach ($command in [regex]::Matches($jobs.package, '(?m)^\s*\./scripts/check-repository-settings\.ps1[^\n]*$')) {
        if ($command.Value -notmatch ' -SelfTest(?:\s|$)') { throw 'Unprivileged package job must use the repository settings self-test.' }
    }
    foreach ($name in @('publish', 'verify')) {
        $body = $jobs[$name]
        if ($body -notmatch 'artifact-ids: \$\{\{ needs\.package\.outputs\.artifact_id \}\}' -or
            $body -notmatch 'digest-mismatch: error' -or $body -match '(?m)^          (?:name|run-id|github-token):') {
            throw "Exact same-run artifact handoff missing on $name."
        }
        foreach ($binding in @('ARCHIVE_SHA256: ${{ needs.package.outputs.archive_sha256 }}', 'CANDIDATE_SHA256: ${{ needs.package.outputs.candidate_sha256 }}')) {
            if (-not $body.Contains($binding)) { throw "Candidate hash output binding missing on $name." }
        }
    }
    $attemptGuard = 'if ($env:GITHUB_RUN_ATTEMPT -cne $env:PACKAGE_ATTEMPT)'
    $attemptIndex = $jobs.publish.IndexOf($attemptGuard, [StringComparison]::Ordinal)
    $prepareIndex = $jobs.publish.IndexOf('publish-marketplaces.ps1 -Mode Prepare', [StringComparison]::Ordinal)
    if ($attemptIndex -lt 0 -or $prepareIndex -lt 0 -or $attemptIndex -gt $prepareIndex -or
        -not $jobs.publish.Contains('PACKAGE_ATTEMPT: ${{ needs.package.outputs.run_attempt }}')) {
        throw 'Same-attempt guard must precede marketplace preparation.'
    }
    if (-not $jobs.publish.Contains('ForeverBeta = $true') -or
        -not $jobs.publish.Contains('ExpectedArchiveSha256 = $env:ARCHIVE_SHA256') -or
        -not $jobs.publish.Contains('ExpectedCandidateSha256 = $env:CANDIDATE_SHA256')) {
        throw 'GitHub mutations must use the Forever candidate hash bindings.'
    }
    foreach ($command in [regex]::Matches($textLF, '(?m)^\s*\./scripts/manage-github-release\.ps1[^\n]*$')) {
        if ($command.Value -notmatch ' -ForeverBeta(?:\s|$)| @release(?:\s|$)') { throw 'Stable GitHub release path is forbidden in the Forever workflow.' }
    }
    $marketplaceCommands = [regex]::Matches($textLF, '(?m)^\s*\./scripts/publish-marketplaces\.ps1 -Mode (?:Prepare|Publish)[^\n]*$')
    if ($marketplaceCommands.Count -ne 2) { throw 'Expected one marketplace preparation and one publication.' }
    foreach ($command in $marketplaceCommands) {
        if ($command.Value -notmatch ' -Flavor Forever(?:\s|$)' -or
            -not $command.Value.Contains('-ExpectedSha256 $env:ARCHIVE_SHA256')) { throw 'Marketplace commands require Forever flavor and exact archive hash.' }
    }
    if (-not $jobs.publish.Contains('-ExpectedPlanSha256 $env:PLAN_SHA256') -or
        -not $jobs.publish.Contains('PLAN_SHA256: ${{ steps.plan.outputs.plan_sha256 }}')) { throw 'Marketplace publication must bind the prepared plan hash.' }
    if (-not $jobs.publish.Contains('GH_TOKEN: ${{ secrets.IMMUTABLE_RELEASES_READ_TOKEN }}') -or
        -not $jobs.publish.Contains('-ImmutableReleasePolicyOnly -RequireExplicitToken')) { throw 'Protected immutable-release policy verification missing.' }
}

$workflow = [IO.File]::ReadAllText([IO.Path]::GetFullPath($WorkflowPath)).Replace("`r`n", "`n")
Assert-ForeverWorkflow $workflow
Assert-ForeverWorkflow ($workflow.Replace("`n", "`r`n"))
$mutations = @(
    @{ From = "- 'forever-v*'"; To = "- 'v*'"; Error = 'exclusive tag family' },
    @{ From = 'github.event.forced == false'; To = 'github.event.forced == true'; Error = 'Fresh tag event guard' },
    @{ From = 'contents: read'; To = 'contents: write'; Error = 'Unexpected permissions' },
    @{ From = "jobs:`n"; To = "permissions: write-all`njobs:`n"; Error = 'Workflow-level permission' },
    @{ From = 'GH_TOKEN: ${{ github.token }}'; To = 'GH_TOKEN: ${{ secrets.CF_API_KEY }}'; Error = 'secrets must remain' },
    @{ From = 'environment: marketplace-release'; To = 'environment: marketplace-manual'; Error = 'Protected marketplace' },
    @{ From = 'needs: [package, publish]'; To = 'needs: package'; Error = 'dependency ordering' },
    @{ From = 'core.autocrlf false'; To = 'core.autocrlf true'; Error = 'Canonical LF producer' },
    @{ From = './scripts/check-repository-settings.ps1 -SelfTest'; To = './scripts/check-repository-settings.ps1'; Error = 'Unprivileged package' },
    @{ From = 'artifact-ids: ${{ needs.package.outputs.artifact_id }}'; To = 'name: forever-candidate'; Error = 'Exact same-run artifact' },
    @{ From = 'digest-mismatch: error'; To = 'digest-mismatch: warn'; Error = 'Exact same-run artifact' },
    @{ From = 'CANDIDATE_SHA256: ${{ needs.package.outputs.candidate_sha256 }}'; To = 'CANDIDATE_SHA256: arbitrary'; Error = 'Candidate hash output' },
    @{ From = 'if ($env:GITHUB_RUN_ATTEMPT -cne $env:PACKAGE_ATTEMPT)'; To = 'if ($false)'; Error = 'Same-attempt guard' },
    @{ From = 'ForeverBeta = $true'; To = 'ForeverBeta = $false'; Error = 'Forever candidate hash bindings' },
    @{ From = '-ForeverBeta -Mode RefuseExisting'; To = '-Mode RefuseExisting'; Error = 'Stable GitHub release path' },
    @{ From = '-Mode Publish -Flavor Forever'; To = '-Mode Publish -Flavor Retail'; Error = 'Marketplace commands require' },
    @{ From = '-ExpectedPlanSha256 $env:PLAN_SHA256'; To = '-ExpectedPlanSha256 stale'; Error = 'prepared plan hash' },
    @{ From = '-ImmutableReleasePolicyOnly -RequireExplicitToken'; To = '-ImmutableReleasePolicyOnly'; Error = 'immutable-release policy verification' }
)
foreach ($mutation in $mutations) {
    $changed = $workflow.Replace($mutation.From, $mutation.To)
    if ($changed -ceq $workflow) { throw "Workflow mutation fixture no longer applies: $($mutation.From)" }
    $rejected = $false
    try { Assert-ForeverWorkflow $changed } catch {
        if ($_.Exception.Message -notmatch $mutation.Error) { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw "Workflow trust-boundary mutation was accepted: $($mutation.From)" }
}
Write-Host "Forever workflow contract: PASS (LF/CRLF and $($mutations.Count) trust-boundary rejection cases)."
