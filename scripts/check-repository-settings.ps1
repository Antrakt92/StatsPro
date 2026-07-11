param(
    [string]$Repository = "Antrakt92/StatsPro",
    [switch]$ImmutableReleasePolicyOnly,
    [switch]$RequireExplicitToken,
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

function Invoke-GhJson {
    param([string[]]$Arguments)

    $result = Invoke-NativeCapture -FilePath "gh" -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw "gh $($Arguments -join ' ') failed with code $($result.ExitCode): $($result.Output -join ' ')"
    }
    return ConvertFrom-JsonCompat ($result.Output -join "`n")
}

function Assert-ExactStringSet {
    param(
        [string]$Description,
        [string[]]$Actual,
        [string[]]$Expected
    )

    $actualUnique = @($Actual | Sort-Object -Unique)
    $expectedUnique = @($Expected | Sort-Object -Unique)
    if ($Actual.Count -ne $actualUnique.Count -or $Expected.Count -ne $expectedUnique.Count) {
        throw "$Description contains duplicate values."
    }
    if ($actualUnique.Count -ne $expectedUnique.Count -or (Compare-Object -ReferenceObject $expectedUnique -DifferenceObject $actualUnique)) {
        throw "$Description is '$($actualUnique -join ', ')'; expected '$($expectedUnique -join ', ')'."
    }
}

function Assert-ImmutableReleasePolicy {
    param([object]$Policy)

    if ($null -eq $Policy -or $Policy -is [System.Array]) {
        throw "Immutable release policy response must be one JSON object."
    }
    $enabled = $Policy.PSObject.Properties["enabled"]
    if (-not $enabled -or $enabled.Value -isnot [bool]) {
        throw "Immutable release policy response must contain a boolean enabled field."
    }
    if (-not $enabled.Value) {
        throw "Immutable releases are not enabled for this repository."
    }
    $enforcedByOwner = $Policy.PSObject.Properties["enforced_by_owner"]
    if (-not $enforcedByOwner -or $enforcedByOwner.Value -isnot [bool]) {
        throw "Immutable release policy response must contain a boolean enforced_by_owner field."
    }
}

function Get-ImmutableReleasePolicy {
    param(
        [string]$Repository,
        [scriptblock]$RunGh,
        [switch]$RequireExplicitToken,
        [AllowNull()][string]$Token = $env:GH_TOKEN
    )

    if ($RequireExplicitToken -and [string]::IsNullOrWhiteSpace($Token)) {
        throw "Immutable release policy verification requires an explicit GH_TOKEN."
    }
    $arguments = @(
        "api", "--method", "GET",
        "-H", "Accept: application/vnd.github+json",
        "-H", "X-GitHub-Api-Version: 2026-03-10",
        "repos/$Repository/immutable-releases"
    )
    $result = if ($RunGh) {
        & $RunGh $arguments
    }
    else {
        Invoke-NativeCapture -FilePath "gh" -Arguments $arguments
    }
    if ($null -eq $result -or $result.ExitCode -ne 0) {
        $exitCode = if ($null -eq $result) { "<no result>" } else { [string]$result.ExitCode }
        throw "Could not verify immutable release policy; GitHub API request failed with code $exitCode."
    }

    $json = @($result.Output) -join "`n"
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw "Immutable release policy response was empty."
    }
    try {
        $policy = ConvertFrom-JsonCompat $json
    }
    catch {
        throw "Immutable release policy response was not valid JSON."
    }
    Assert-ImmutableReleasePolicy -Policy $policy
    return $policy
}

function Assert-ActionsWorkflowPermissions {
    param([object]$Settings)

    $propertyNames = @($Settings.PSObject.Properties.Name)
    foreach ($requiredProperty in @("default_workflow_permissions", "can_approve_pull_request_reviews")) {
        if ($propertyNames -notcontains $requiredProperty) {
            throw "Repository Actions settings are missing $requiredProperty."
        }
    }
    if ([string]$Settings.default_workflow_permissions -ne "read") {
        throw "Repository Actions default workflow permissions must be read-only."
    }
    if ([bool]$Settings.can_approve_pull_request_reviews) {
        throw "Repository Actions must not approve pull request reviews."
    }
}

function Assert-RepositoryRulesetInventory {
    param([object[]]$Rulesets)

    if ($Rulesets.Count -ne 2) {
        throw "Repository must have exactly two repository-owned rulesets; found $($Rulesets.Count)."
    }
    Assert-ExactStringSet `
        -Description "Repository ruleset names" `
        -Actual @($Rulesets | ForEach-Object { [string]$_.name }) `
        -Expected @("Protect main history", "Protect release tags")
}

function Assert-MinimalHistoryRuleset {
    param(
        [object[]]$Rulesets,
        [string]$Name,
        [string]$Target,
        [string]$IncludedRef
    )

    $matches = @($Rulesets | Where-Object { [string]$_.name -eq $Name })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one ruleset named '$Name'; found $($matches.Count)."
    }
    $ruleset = $matches[0]
    if ([string]$ruleset.target -ne $Target) {
        throw "Ruleset '$Name' target is '$($ruleset.target)', expected '$Target'."
    }
    if ([string]$ruleset.enforcement -ne "active") {
        throw "Ruleset '$Name' must be active."
    }
    if ([string]$ruleset.source_type -ne "Repository") {
        throw "Ruleset '$Name' must be repository-owned."
    }
    if (@($ruleset.PSObject.Properties.Name) -notcontains "bypass_actors") {
        throw "Ruleset '$Name' response is missing bypass_actors."
    }
    if (@($ruleset.bypass_actors).Count -ne 0) {
        throw "Ruleset '$Name' must not have bypass actors."
    }

    Assert-ExactStringSet `
        -Description "Ruleset '$Name' included refs" `
        -Actual @($ruleset.conditions.ref_name.include | ForEach-Object { [string]$_ }) `
        -Expected @($IncludedRef)
    Assert-ExactStringSet `
        -Description "Ruleset '$Name' excluded refs" `
        -Actual @($ruleset.conditions.ref_name.exclude | ForEach-Object { [string]$_ }) `
        -Expected @()
    Assert-ExactStringSet `
        -Description "Ruleset '$Name' rule types" `
        -Actual @($ruleset.rules | ForEach-Object { [string]$_.type }) `
        -Expected @("deletion", "non_fast_forward")
}

function Assert-ReleaseWorkflowKeepsExplicitWritePermission {
    param([string]$WorkflowText)

    $releaseJob = [regex]::Match($WorkflowText, "(?ms)^  release:\s*$.*?(?=^  [A-Za-z0-9_-]+:\s*$|\z)")
    if (-not $releaseJob.Success) {
        throw "Could not find the release job in release.yml."
    }
    if ($releaseJob.Value -notmatch "(?ms)^    permissions:\s*\r?\n      contents: write\s*$") {
        throw "Release job must keep explicit contents: write permission."
    }
}

function Invoke-SelfTest {
    $branchRuleset = [pscustomobject]@{
        name = "Protect main history"
        target = "branch"
        enforcement = "active"
        source_type = "Repository"
        bypass_actors = @()
        conditions = [pscustomobject]@{
            ref_name = [pscustomobject]@{
                include = @("refs/heads/main")
                exclude = @()
            }
        }
        rules = @(
            [pscustomobject]@{ type = "deletion" },
            [pscustomobject]@{ type = "non_fast_forward" }
        )
    }
    $tagRuleset = [pscustomobject]@{
        name = "Protect release tags"
        target = "tag"
        enforcement = "active"
        source_type = "Repository"
        bypass_actors = @()
        conditions = [pscustomobject]@{
            ref_name = [pscustomobject]@{
                include = @("refs/tags/v*")
                exclude = @()
            }
        }
        rules = @(
            [pscustomobject]@{ type = "deletion" },
            [pscustomobject]@{ type = "non_fast_forward" }
        )
    }
    $rulesets = @($branchRuleset, $tagRuleset)
    Assert-ActionsWorkflowPermissions -Settings ([pscustomobject]@{
        default_workflow_permissions = "read"
        can_approve_pull_request_reviews = $false
    })
    Assert-RepositoryRulesetInventory -Rulesets $rulesets
    Assert-MinimalHistoryRuleset -Rulesets $rulesets -Name "Protect main history" -Target "branch" -IncludedRef "refs/heads/main"
    Assert-MinimalHistoryRuleset -Rulesets $rulesets -Name "Protect release tags" -Target "tag" -IncludedRef "refs/tags/v*"

    Assert-ImmutableReleasePolicy -Policy ([pscustomobject]@{
        enabled = $true
        enforced_by_owner = $false
    })
    Assert-ImmutableReleasePolicy -Policy ([pscustomobject]@{
        enabled = $true
        enforced_by_owner = $true
    })
    Assert-ThrowsMatch "disabled immutable releases rejected" {
        Assert-ImmutableReleasePolicy -Policy ([pscustomobject]@{
            enabled = $false
            enforced_by_owner = $false
        })
    } "not enabled"
    Assert-ThrowsMatch "missing immutable enabled field rejected" {
        Assert-ImmutableReleasePolicy -Policy ([pscustomobject]@{ enforced_by_owner = $false })
    } "boolean enabled"
    Assert-ThrowsMatch "null immutable enabled field rejected" {
        Assert-ImmutableReleasePolicy -Policy ([pscustomobject]@{
            enabled = $null
            enforced_by_owner = $false
        })
    } "boolean enabled"
    Assert-ThrowsMatch "numeric immutable enabled field rejected" {
        Assert-ImmutableReleasePolicy -Policy ([pscustomobject]@{
            enabled = 1
            enforced_by_owner = $false
        })
    } "boolean enabled"
    Assert-ThrowsMatch "string immutable enabled field rejected" {
        Assert-ImmutableReleasePolicy -Policy ([pscustomobject]@{
            enabled = "true"
            enforced_by_owner = $false
        })
    } "boolean enabled"
    Assert-ThrowsMatch "missing immutable owner enforcement rejected" {
        Assert-ImmutableReleasePolicy -Policy ([pscustomobject]@{ enabled = $true })
    } "boolean enforced_by_owner"
    Assert-ThrowsMatch "malformed immutable owner enforcement rejected" {
        Assert-ImmutableReleasePolicy -Policy ([pscustomobject]@{
            enabled = $true
            enforced_by_owner = "false"
        })
    } "boolean enforced_by_owner"
    Assert-ThrowsMatch "array immutable policy rejected" {
        Assert-ImmutableReleasePolicy -Policy @([pscustomobject]@{ enabled = $true })
    } "one JSON object"

    $immutableCalls = [System.Collections.Generic.List[string]]::new()
    $immutablePolicy = Get-ImmutableReleasePolicy -Repository "owner/repo" -RunGh {
        param([string[]]$Arguments)
        $immutableCalls.Add(($Arguments -join " ")) | Out-Null
        return @{
            ExitCode = 0
            Output = @('{"enabled":true,"enforced_by_owner":false}')
        }
    }
    if (-not $immutablePolicy.enabled -or
        $immutableCalls.Count -ne 1 -or
        $immutableCalls[0] -notmatch '^api --method GET ' -or
        $immutableCalls[0] -notmatch '-H Accept: application/vnd\.github\+json ' -or
        $immutableCalls[0] -notmatch '-H X-GitHub-Api-Version: 2026-03-10 ' -or
        $immutableCalls[0] -match '(?i)\b(?:POST|PUT|PATCH|DELETE)\b' -or
        $immutableCalls[0] -notmatch 'repos/owner/repo/immutable-releases$') {
        throw "Immutable release policy request must use the exact read-only repository endpoint."
    }
    foreach ($status in @(401, 403, 404, 429, 500, 503)) {
        Assert-ThrowsMatch "HTTP $status immutable policy rejected" {
            [void](Get-ImmutableReleasePolicy -Repository "owner/repo" -RunGh {
                param([string[]]$Arguments)
                return @{ ExitCode = 1; Output = @("HTTP $status") }
            })
        } "request failed"
    }
    Assert-ThrowsMatch "malformed immutable JSON rejected" {
        [void](Get-ImmutableReleasePolicy -Repository "owner/repo" -RunGh {
            param([string[]]$Arguments)
            return @{ ExitCode = 0; Output = @("not-json") }
        })
    } "not valid JSON"
    Assert-ThrowsMatch "empty immutable response rejected" {
        [void](Get-ImmutableReleasePolicy -Repository "owner/repo" -RunGh {
            param([string[]]$Arguments)
            return @{ ExitCode = 0; Output = @() }
        })
    } "was empty"
    $explicitTokenRunnerCalls = [System.Collections.Generic.List[string]]::new()
    Assert-ThrowsMatch "missing explicit immutable policy token rejected" {
        [void](Get-ImmutableReleasePolicy `
            -Repository "owner/repo" `
            -RequireExplicitToken `
            -Token "  " `
            -RunGh {
                param([string[]]$Arguments)
                $explicitTokenRunnerCalls.Add(($Arguments -join " ")) | Out-Null
                return @{ ExitCode = 0; Output = @('{"enabled":true,"enforced_by_owner":false}') }
            })
    } "requires an explicit GH_TOKEN"
    if ($explicitTokenRunnerCalls.Count -ne 0) {
        throw "Missing explicit immutable policy token must fail before invoking gh."
    }
    $sentinelToken = "STATSPRO_IMMUTABLE_POLICY_SENTINEL"
    try {
        [void](Get-ImmutableReleasePolicy `
            -Repository "owner/repo" `
            -RequireExplicitToken `
            -Token $sentinelToken `
            -RunGh {
                param([string[]]$Arguments)
                return @{ ExitCode = 1; Output = @("authentication failed") }
            })
        throw "Immutable policy failure redaction self-test should have failed."
    }
    catch {
        if ($_.Exception.Message.Contains($sentinelToken)) {
            throw "Immutable policy failure exposed the token value."
        }
        if ($_.Exception.Message -notmatch "request failed") {
            throw
        }
    }

    Assert-ThrowsMatch "write-default Actions permissions rejected" {
        Assert-ActionsWorkflowPermissions -Settings ([pscustomobject]@{
            default_workflow_permissions = "write"
            can_approve_pull_request_reviews = $false
        })
    } "read-only"
    Assert-ThrowsMatch "Actions PR approval rejected" {
        Assert-ActionsWorkflowPermissions -Settings ([pscustomobject]@{
            default_workflow_permissions = "read"
            can_approve_pull_request_reviews = $true
        })
    } "must not approve"
    Assert-ThrowsMatch "missing Actions approval field rejected" {
        Assert-ActionsWorkflowPermissions -Settings ([pscustomobject]@{
            default_workflow_permissions = "read"
        })
    } "missing can_approve"

    Assert-ThrowsMatch "unexpected repository ruleset rejected" {
        Assert-RepositoryRulesetInventory -Rulesets (@($rulesets) + @([pscustomobject]@{ name = "Require pull requests" }))
    } "exactly two"

    $missingBypassField = $branchRuleset.PSObject.Copy()
    $missingBypassField.PSObject.Properties.Remove("bypass_actors")
    Assert-ThrowsMatch "missing ruleset bypass field rejected" {
        Assert-MinimalHistoryRuleset -Rulesets @($missingBypassField) -Name "Protect main history" -Target "branch" -IncludedRef "refs/heads/main"
    } "missing bypass_actors"

    $creationBlocked = $tagRuleset.PSObject.Copy()
    $creationBlocked.rules = @($tagRuleset.rules) + @([pscustomobject]@{ type = "creation" })
    Assert-ThrowsMatch "tag creation restriction rejected" {
        Assert-MinimalHistoryRuleset -Rulesets @($creationBlocked) -Name "Protect release tags" -Target "tag" -IncludedRef "refs/tags/v*"
    } "rule types"

    $updateBlocked = $branchRuleset.PSObject.Copy()
    $updateBlocked.rules = @($branchRuleset.rules) + @([pscustomobject]@{ type = "update" })
    Assert-ThrowsMatch "direct main update restriction rejected" {
        Assert-MinimalHistoryRuleset -Rulesets @($updateBlocked) -Name "Protect main history" -Target "branch" -IncludedRef "refs/heads/main"
    } "rule types"

    $workflowPath = Join-Path (Join-Path $PSScriptRoot "..") ".github\workflows\release.yml"
    $workflowText = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
    Assert-ReleaseWorkflowKeepsExplicitWritePermission -WorkflowText $workflowText
    Assert-ThrowsMatch "missing release write permission rejected" {
        Assert-ReleaseWorkflowKeepsExplicitWritePermission -WorkflowText ($workflowText -replace "contents: write", "contents: read")
    } "contents: write"

    Write-Host "Repository settings self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if ($Repository -notmatch "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") {
    throw "Malformed GitHub repository '$Repository'. Expected owner/name."
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required."
}

$headers = @(
    "-H", "Accept: application/vnd.github+json",
    "-H", "X-GitHub-Api-Version: 2026-03-10"
)
[void](Get-ImmutableReleasePolicy `
    -Repository $Repository `
    -RequireExplicitToken:$RequireExplicitToken `
    -Token $env:GH_TOKEN)
if ($ImmutableReleasePolicyOnly) {
    Write-Host "StatsPro immutable release policy check passed."
    return
}
$actionsSettings = Invoke-GhJson -Arguments (@("api") + $headers + @("repos/$Repository/actions/permissions/workflow"))
$rulesetSummaries = @(Invoke-GhJson -Arguments (@("api", "--paginate", "--slurp") + $headers + @("repos/$Repository/rulesets?per_page=100&includes_parents=false")))
$rulesets = @($rulesetSummaries | ForEach-Object {
    Invoke-GhJson -Arguments (@("api") + $headers + @("repos/$Repository/rulesets/$($_.id)?includes_parents=false"))
})

Assert-ActionsWorkflowPermissions -Settings $actionsSettings
Assert-RepositoryRulesetInventory -Rulesets $rulesets
Assert-MinimalHistoryRuleset -Rulesets $rulesets -Name "Protect main history" -Target "branch" -IncludedRef "refs/heads/main"
Assert-MinimalHistoryRuleset -Rulesets $rulesets -Name "Protect release tags" -Target "tag" -IncludedRef "refs/tags/v*"
$workflowPath = Join-Path (Join-Path $PSScriptRoot "..") ".github\workflows\release.yml"
Assert-ReleaseWorkflowKeepsExplicitWritePermission -WorkflowText (Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8)

Write-Host "StatsPro repository settings checks passed."
