param(
    [string]$Repository = "Antrakt92/StatsPro",
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
