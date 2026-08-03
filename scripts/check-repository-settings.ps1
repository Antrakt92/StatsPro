param(
    [string]$Repository = "Antrakt92/StatsPro",
    [switch]$ImmutableReleasePolicyOnly,
    [switch]$RequireExplicitToken,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "release-check-contract.ps1")

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

function Assert-CredentialEnvironment {
    param(
        [object]$Environment,
        [object[]]$Policies,
        [object[]]$Secrets,
        [string]$ExpectedName,
        [string]$ExpectedPolicyName,
        [string]$ExpectedPolicyType,
        [string[]]$ExpectedSecretNames,
        [AllowEmptyString()][string]$ExpectedReviewerLogin = ""
    )

    if ($null -eq $Environment -or $Environment -is [System.Array] -or
        [string]$Environment.name -ne $ExpectedName) {
        throw "Credential environment '$ExpectedName' must exist as one exact environment."
    }
    if ($Environment.PSObject.Properties.Name -notcontains "can_admins_bypass" -or
        $Environment.can_admins_bypass -isnot [bool] -or
        [bool]$Environment.can_admins_bypass) {
        throw "Credential environment '$ExpectedName' must disable administrator bypass."
    }
    $deploymentPolicy = $Environment.PSObject.Properties["deployment_branch_policy"]
    if (-not $deploymentPolicy -or $null -eq $deploymentPolicy.Value -or
        $deploymentPolicy.Value.protected_branches -isnot [bool] -or
        $deploymentPolicy.Value.custom_branch_policies -isnot [bool] -or
        [bool]$deploymentPolicy.Value.protected_branches -or
        -not [bool]$deploymentPolicy.Value.custom_branch_policies) {
        throw "Credential environment '$ExpectedName' must use custom deployment branch policies only."
    }

    if ($Policies.Count -ne 1 -or
        [string]$Policies[0].name -ne $ExpectedPolicyName -or
        [string]$Policies[0].type -ne $ExpectedPolicyType) {
        throw "Credential environment '$ExpectedName' must allow only $ExpectedPolicyType '$ExpectedPolicyName'."
    }
    Assert-ExactStringSet `
        -Description "Credential environment '$ExpectedName' secrets" `
        -Actual @($Secrets | ForEach-Object { [string]$_.name }) `
        -Expected $ExpectedSecretNames

    $protectionRules = @($Environment.protection_rules)
    $expectedRuleTypes = if ([string]::IsNullOrWhiteSpace($ExpectedReviewerLogin)) {
        @("branch_policy")
    }
    else {
        @("branch_policy", "required_reviewers")
    }
    Assert-ExactStringSet `
        -Description "Credential environment '$ExpectedName' protection rule types" `
        -Actual @($protectionRules | ForEach-Object { [string]$_.type }) `
        -Expected $expectedRuleTypes

    if (-not [string]::IsNullOrWhiteSpace($ExpectedReviewerLogin)) {
        $reviewRules = @($protectionRules | Where-Object { [string]$_.type -eq "required_reviewers" })
        if ($reviewRules.Count -ne 1 -or
            $reviewRules[0].prevent_self_review -isnot [bool] -or
            [bool]$reviewRules[0].prevent_self_review) {
            throw "Credential environment '$ExpectedName' must require an owner review with self-review allowed for the sole owner."
        }
        $reviewers = @($reviewRules[0].reviewers)
        if ($reviewers.Count -ne 1 -or
            [string]$reviewers[0].type -ne "User" -or
            [string]$reviewers[0].reviewer.login -ne $ExpectedReviewerLogin) {
            throw "Credential environment '$ExpectedName' reviewer must be repository owner '$ExpectedReviewerLogin'."
        }
    }
}

function Assert-CredentialEnvironmentSettings {
    param(
        [object[]]$Environments,
        [object]$ManualEnvironment,
        [object[]]$ManualPolicies,
        [object[]]$ManualSecrets,
        [object]$ReleaseEnvironment,
        [object[]]$ReleasePolicies,
        [object[]]$ReleaseSecrets,
        [object[]]$RepositorySecrets,
        [string]$RepositoryOwner
    )

    $marketplaceSecrets = @("CF_API_KEY", "WAGO_API_TOKEN", "WOWI_API_TOKEN")
    $protectedSecrets = @($marketplaceSecrets + "IMMUTABLE_RELEASES_READ_TOKEN")
    Assert-ExactStringSet `
        -Description "Repository credential environment names" `
        -Actual @($Environments | ForEach-Object { [string]$_.name }) `
        -Expected @("marketplace-manual", "marketplace-release")
    Assert-CredentialEnvironment `
        -Environment $ManualEnvironment `
        -Policies $ManualPolicies `
        -Secrets $ManualSecrets `
        -ExpectedName "marketplace-manual" `
        -ExpectedPolicyName "main" `
        -ExpectedPolicyType "branch" `
        -ExpectedSecretNames $marketplaceSecrets
    Assert-CredentialEnvironment `
        -Environment $ReleaseEnvironment `
        -Policies $ReleasePolicies `
        -Secrets $ReleaseSecrets `
        -ExpectedName "marketplace-release" `
        -ExpectedPolicyName "v*" `
        -ExpectedPolicyType "tag" `
        -ExpectedSecretNames $protectedSecrets `
        -ExpectedReviewerLogin $RepositoryOwner

    if ($RepositorySecrets.Count -ne 0) {
        $repositorySecretNames = @($RepositorySecrets | ForEach-Object { [string]$_.name } | Sort-Object)
        throw "Repository-level Actions secrets must be empty; found: $($repositorySecretNames -join ', ')."
    }
}

function Assert-ReleaseWorkflowKeepsExplicitWritePermission {
    param([string]$WorkflowText)

    $jobsMatch = [regex]::Match($WorkflowText, "(?ms)^jobs:\s*$\r?\n(?<body>.*)\z")
    if (-not $jobsMatch.Success) {
        throw "Could not find the jobs mapping in release.yml."
    }

    $workflowHeader = $WorkflowText.Substring(0, $jobsMatch.Index)
    if ($workflowHeader -match "(?m)^permissions:\s*") {
        throw "release.yml must not grant workflow-level permissions."
    }

    $expectedPermissions = [ordered]@{
        "preflight" = "read"
        "package" = "read"
        "github-prepare" = "write"
        "marketplace-upload" = "write"
        "github-finalize" = "write"
        "verify" = "read"
    }
    $jobMatches = [regex]::Matches(
        $jobsMatch.Groups["body"].Value,
        "(?ms)^  (?<name>[A-Za-z0-9_-]+):\s*\r?\n(?<body>.*?)(?=^  [A-Za-z0-9_-]+:\s*$|\z)"
    )
    $jobs = @{}
    foreach ($jobMatch in $jobMatches) {
        $jobName = $jobMatch.Groups["name"].Value
        if ($jobs.ContainsKey($jobName)) {
            throw "release.yml contains duplicate job '$jobName'."
        }
        $jobs[$jobName] = $jobMatch.Groups["body"].Value
    }

    $actualJobNames = @($jobs.Keys | Sort-Object)
    $expectedJobNames = @($expectedPermissions.Keys | Sort-Object)
    if (($actualJobNames -join "`n") -cne ($expectedJobNames -join "`n")) {
        throw "release.yml must contain exactly the permission-audited jobs: $($expectedJobNames -join ', ')."
    }

    foreach ($jobName in $expectedPermissions.Keys) {
        $permissionMatches = [regex]::Matches(
            $jobs[$jobName],
            "(?ms)^    permissions:\s*\r?\n(?<body>(?:^      [^\r\n]*\r?\n?)*)"
        )
        if ($permissionMatches.Count -ne 1) {
            throw "Release job '$jobName' must declare exactly one permissions block."
        }
        $permissionLines = @(
            $permissionMatches[0].Groups["body"].Value -split "\r?\n" |
                Where-Object { $_.Length -gt 0 }
        )
        $expectedLine = "      contents: $($expectedPermissions[$jobName])"
        if ($permissionLines.Count -ne 1 -or $permissionLines[0] -cne $expectedLine) {
            throw "Release job '$jobName' permissions must be exactly 'contents: $($expectedPermissions[$jobName])'."
        }
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

    $newEnvironmentFixture = {
        param([string]$Name, [switch]$RequireReviewer)
        $rules = @([pscustomobject]@{ type = "branch_policy" })
        if ($RequireReviewer) {
            $rules += [pscustomobject]@{
                type = "required_reviewers"
                prevent_self_review = $false
                reviewers = @([pscustomobject]@{
                    type = "User"
                    reviewer = [pscustomobject]@{ login = "owner" }
                })
            }
        }
        return [pscustomobject]@{
            name = $Name
            can_admins_bypass = $false
            protection_rules = $rules
            deployment_branch_policy = [pscustomobject]@{
                protected_branches = $false
                custom_branch_policies = $true
            }
        }
    }
    $manualEnvironment = & $newEnvironmentFixture "marketplace-manual"
    $releaseEnvironment = & $newEnvironmentFixture "marketplace-release" -RequireReviewer
    $manualPolicies = @([pscustomobject]@{ name = "main"; type = "branch" })
    $releasePolicies = @([pscustomobject]@{ name = "v*"; type = "tag" })
    $manualSecrets = @("CF_API_KEY", "WAGO_API_TOKEN", "WOWI_API_TOKEN") |
        ForEach-Object { [pscustomobject]@{ name = $_ } }
    $releaseSecrets = @("CF_API_KEY", "IMMUTABLE_RELEASES_READ_TOKEN", "WAGO_API_TOKEN", "WOWI_API_TOKEN") |
        ForEach-Object { [pscustomobject]@{ name = $_ } }
    Assert-CredentialEnvironmentSettings `
        -Environments @($manualEnvironment, $releaseEnvironment) `
        -ManualEnvironment $manualEnvironment `
        -ManualPolicies $manualPolicies `
        -ManualSecrets $manualSecrets `
        -ReleaseEnvironment $releaseEnvironment `
        -ReleasePolicies $releasePolicies `
        -ReleaseSecrets $releaseSecrets `
        -RepositorySecrets @() `
        -RepositoryOwner "owner"

    $bypassEnvironment = & $newEnvironmentFixture "marketplace-manual"
    $bypassEnvironment.can_admins_bypass = $true
    Assert-ThrowsMatch "credential environment admin bypass rejected" {
        Assert-CredentialEnvironment `
            -Environment $bypassEnvironment `
            -Policies $manualPolicies `
            -Secrets $manualSecrets `
            -ExpectedName "marketplace-manual" `
            -ExpectedPolicyName "main" `
            -ExpectedPolicyType "branch" `
            -ExpectedSecretNames @("CF_API_KEY", "WAGO_API_TOKEN", "WOWI_API_TOKEN")
    } "disable administrator bypass"
    Assert-ThrowsMatch "wildcard manual credential policy rejected" {
        Assert-CredentialEnvironment `
            -Environment $manualEnvironment `
            -Policies @([pscustomobject]@{ name = "*"; type = "branch" }) `
            -Secrets $manualSecrets `
            -ExpectedName "marketplace-manual" `
            -ExpectedPolicyName "main" `
            -ExpectedPolicyType "branch" `
            -ExpectedSecretNames @("CF_API_KEY", "WAGO_API_TOKEN", "WOWI_API_TOKEN")
    } "allow only branch 'main'"
    Assert-ThrowsMatch "manual tag credential policy rejected" {
        Assert-CredentialEnvironment `
            -Environment $manualEnvironment `
            -Policies @([pscustomobject]@{ name = "main"; type = "tag" }) `
            -Secrets $manualSecrets `
            -ExpectedName "marketplace-manual" `
            -ExpectedPolicyName "main" `
            -ExpectedPolicyType "branch" `
            -ExpectedSecretNames @("CF_API_KEY", "WAGO_API_TOKEN", "WOWI_API_TOKEN")
    } "allow only branch 'main'"
    Assert-ThrowsMatch "missing manual environment secret rejected" {
        Assert-CredentialEnvironment `
            -Environment $manualEnvironment `
            -Policies $manualPolicies `
            -Secrets @($manualSecrets | Where-Object { $_.name -ne "WAGO_API_TOKEN" }) `
            -ExpectedName "marketplace-manual" `
            -ExpectedPolicyName "main" `
            -ExpectedPolicyType "branch" `
            -ExpectedSecretNames @("CF_API_KEY", "WAGO_API_TOKEN", "WOWI_API_TOKEN")
    } "secrets is"
    $releaseWithoutReviewer = & $newEnvironmentFixture "marketplace-release"
    Assert-ThrowsMatch "missing release environment reviewer rejected" {
        Assert-CredentialEnvironment `
            -Environment $releaseWithoutReviewer `
            -Policies $releasePolicies `
            -Secrets $releaseSecrets `
            -ExpectedName "marketplace-release" `
            -ExpectedPolicyName "v*" `
            -ExpectedPolicyType "tag" `
            -ExpectedSecretNames @("CF_API_KEY", "IMMUTABLE_RELEASES_READ_TOKEN", "WAGO_API_TOKEN", "WOWI_API_TOKEN") `
            -ExpectedReviewerLogin "owner"
    } "protection rule types"
    Assert-ThrowsMatch "wrong release environment reviewer rejected" {
        Assert-CredentialEnvironment `
            -Environment $releaseEnvironment `
            -Policies $releasePolicies `
            -Secrets $releaseSecrets `
            -ExpectedName "marketplace-release" `
            -ExpectedPolicyName "v*" `
            -ExpectedPolicyType "tag" `
            -ExpectedSecretNames @("CF_API_KEY", "IMMUTABLE_RELEASES_READ_TOKEN", "WAGO_API_TOKEN", "WOWI_API_TOKEN") `
            -ExpectedReviewerLogin "someone-else"
    } "reviewer must be repository owner"
    Assert-ThrowsMatch "repository credential fallback rejected" {
        Assert-CredentialEnvironmentSettings `
            -Environments @($manualEnvironment, $releaseEnvironment) `
            -ManualEnvironment $manualEnvironment `
            -ManualPolicies $manualPolicies `
            -ManualSecrets $manualSecrets `
            -ReleaseEnvironment $releaseEnvironment `
            -ReleasePolicies $releasePolicies `
            -ReleaseSecrets $releaseSecrets `
            -RepositorySecrets @([pscustomobject]@{ name = "CF_API_KEY" }) `
            -RepositoryOwner "owner"
    } "Repository-level Actions secrets must be empty"
    Assert-ThrowsMatch "renamed repository credential fallback rejected" {
        Assert-CredentialEnvironmentSettings `
            -Environments @($manualEnvironment, $releaseEnvironment) `
            -ManualEnvironment $manualEnvironment `
            -ManualPolicies $manualPolicies `
            -ManualSecrets $manualSecrets `
            -ReleaseEnvironment $releaseEnvironment `
            -ReleasePolicies $releasePolicies `
            -ReleaseSecrets $releaseSecrets `
            -RepositorySecrets @([pscustomobject]@{ name = "UNEXPECTED_TOKEN" }) `
            -RepositoryOwner "owner"
    } "Repository-level Actions secrets must be empty"
    Assert-ThrowsMatch "extra credential environment rejected" {
        Assert-CredentialEnvironmentSettings `
            -Environments @($manualEnvironment, $releaseEnvironment, [pscustomobject]@{ name = "unrestricted" }) `
            -ManualEnvironment $manualEnvironment `
            -ManualPolicies $manualPolicies `
            -ManualSecrets $manualSecrets `
            -ReleaseEnvironment $releaseEnvironment `
            -ReleasePolicies $releasePolicies `
            -ReleaseSecrets $releaseSecrets `
            -RepositorySecrets @() `
            -RepositoryOwner "owner"
    } "credential environment names"

    $workflowPath = Join-Path (Join-Path $PSScriptRoot "..") ".github\workflows\release.yml"
    $workflowText = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
    Assert-ReleaseWorkflowKeepsExplicitWritePermission -WorkflowText $workflowText
    Assert-ThrowsMatch "missing release write permission rejected" {
        Assert-ReleaseWorkflowKeepsExplicitWritePermission -WorkflowText ($workflowText -replace "contents: write", "contents: read")
    } "github-prepare.*contents: write"
    Assert-ThrowsMatch "read-only job write permission rejected" {
        $mutated = $workflowText -replace "(?ms)(^  preflight:.*?^      contents:) read\s*$", '$1 write'
        Assert-ReleaseWorkflowKeepsExplicitWritePermission -WorkflowText $mutated
    } "preflight.*contents: read"
    Assert-ThrowsMatch "extra permission scope rejected" {
        $replacement = '$1' + "`r`n      actions: write"
        $mutated = $workflowText -replace "(?m)^(      contents: read)\s*$", $replacement
        Assert-ReleaseWorkflowKeepsExplicitWritePermission -WorkflowText $mutated
    } "permissions must be exactly"
    Assert-ThrowsMatch "workflow-level permission rejected" {
        $mutated = $workflowText -replace "(?m)^jobs:\s*$", "permissions: read-all`r`n`r`njobs:"
        Assert-ReleaseWorkflowKeepsExplicitWritePermission -WorkflowText $mutated
    } "workflow-level permissions"

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
$environmentResponse = Invoke-GhJson -Arguments (@("api") + $headers + @("repos/$Repository/environments?per_page=100"))
$manualEnvironment = Invoke-GhJson -Arguments (@("api") + $headers + @("repos/$Repository/environments/marketplace-manual"))
$manualPolicyResponse = Invoke-GhJson -Arguments (@("api") + $headers + @("repos/$Repository/environments/marketplace-manual/deployment-branch-policies"))
$manualSecretResponse = Invoke-GhJson -Arguments (@("api") + $headers + @("repos/$Repository/environments/marketplace-manual/secrets?per_page=100"))
$releaseEnvironment = Invoke-GhJson -Arguments (@("api") + $headers + @("repos/$Repository/environments/marketplace-release"))
$releasePolicyResponse = Invoke-GhJson -Arguments (@("api") + $headers + @("repos/$Repository/environments/marketplace-release/deployment-branch-policies"))
$releaseSecretResponse = Invoke-GhJson -Arguments (@("api") + $headers + @("repos/$Repository/environments/marketplace-release/secrets?per_page=100"))
$repositorySecretResponse = Invoke-GhJson -Arguments (@("api") + $headers + @("repos/$Repository/actions/secrets?per_page=100"))

Assert-ActionsWorkflowPermissions -Settings $actionsSettings
Assert-RepositoryRulesetInventory -Rulesets $rulesets
Assert-MinimalHistoryRuleset -Rulesets $rulesets -Name "Protect main history" -Target "branch" -IncludedRef "refs/heads/main"
Assert-MinimalHistoryRuleset -Rulesets $rulesets -Name "Protect release tags" -Target "tag" -IncludedRef "refs/tags/v*"
Assert-CredentialEnvironmentSettings `
    -Environments @($environmentResponse.environments) `
    -ManualEnvironment $manualEnvironment `
    -ManualPolicies @($manualPolicyResponse.branch_policies) `
    -ManualSecrets @($manualSecretResponse.secrets) `
    -ReleaseEnvironment $releaseEnvironment `
    -ReleasePolicies @($releasePolicyResponse.branch_policies) `
    -ReleaseSecrets @($releaseSecretResponse.secrets) `
    -RepositorySecrets @($repositorySecretResponse.secrets) `
    -RepositoryOwner ($Repository.Split('/')[0])
$workflowPath = Join-Path (Join-Path $PSScriptRoot "..") ".github\workflows\release.yml"
Assert-ReleaseWorkflowKeepsExplicitWritePermission -WorkflowText (Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8)

Write-Host "StatsPro repository settings checks passed."
