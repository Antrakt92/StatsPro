param(
    [string[]]$ActionRefs = @(),
    [string]$WorkflowRoot = (Join-Path $PSScriptRoot "..\.github\workflows"),
    [switch]$EnforcePinnedWorkflowRefs,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

function Assert-Equal {
    param(
        [string]$Name,
        [object]$Actual,
        [object]$Expected
    )

    if ($Actual -ne $Expected) {
        throw "$Name expected <$Expected>, got <$Actual>."
    }
}

function Assert-ThrowsMatch {
    param([string]$Name, [scriptblock]$Script, [string]$Pattern)
    try {
        & $Script
    }
    catch {
        if ($_.Exception.Message -match $Pattern) { return }
        throw "$Name expected error matching <$Pattern>, got <$($_.Exception.Message)>."
    }
    throw "$Name expected an error matching <$Pattern>, but no error was thrown."
}

function Resolve-LsRemoteSha {
    param(
        [string[]]$Output,
        [string]$Ref
    )

    foreach ($line in @($Output)) {
        if ($line -match "^([0-9a-f]{40})\s+$([regex]::Escape($Ref))$") {
            return $Matches[1]
        }
    }
    return $null
}

function Format-ActionRefReport {
    param(
        [string]$OwnerRepo,
        [string]$Ref,
        [AllowNull()][string]$Sha
    )

    if ([string]::IsNullOrWhiteSpace($Sha)) {
        return "$OwnerRepo@$Ref -> unresolved"
    }
    return "$OwnerRepo@$Ref -> $Sha"
}

function Split-ActionRef {
    param([string]$ActionRef)
    if ([string]::IsNullOrWhiteSpace($ActionRef)) {
        throw "Empty GitHub Action reference."
    }
    $clean = $ActionRef.Trim().Trim("'").Trim('"')
    if ($clean -match "^(?<target>[^@\s]+)@(?<ref>[^\s]+)$") {
        return [pscustomobject]@{
            Target = $Matches.target
            Ref    = $Matches.ref
        }
    }
    return [pscustomobject]@{
        Target = $clean
        Ref    = $null
    }
}

function Test-LocalActionRef {
    param([string]$ActionRef)
    return $ActionRef -match "^\.{1,2}/"
}

function Test-ShaRef {
    param([string]$Ref)
    return $Ref -match "^[0-9a-fA-F]{40}$"
}

function Read-WorkflowActionRefs {
    param([string]$WorkflowRoot)
    if (-not (Test-Path -LiteralPath $WorkflowRoot -PathType Container)) {
        throw "Workflow root not found: $WorkflowRoot"
    }

    $files = @(
        Get-ChildItem -LiteralPath $WorkflowRoot -Recurse -File |
            Where-Object { $_.Extension -in @(".yml", ".yaml") } |
            Sort-Object FullName
    )
    foreach ($file in $files) {
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $file.FullName) {
            $lineNumber++
            if ($line -match "^\s*(?:-\s*)?uses:\s*(?<ref>[^#\r\n]+?)\s*(?:#.*)?$") {
                $actionRef = $Matches.ref.Trim().Trim("'").Trim('"')
                [pscustomobject]@{
                    Path       = $file.FullName
                    LineNumber = $lineNumber
                    ActionRef  = $actionRef
                }
            }
        }
    }
}

function Assert-WorkflowActionRefsPinned {
    param([object[]]$Refs)
    foreach ($entry in @($Refs)) {
        $actionRef = $entry.ActionRef
        if (Test-LocalActionRef $actionRef) { continue }
        $split = Split-ActionRef $actionRef
        if (-not $split.Ref) {
            throw "$($entry.Path):$($entry.LineNumber) uses '$actionRef' without an explicit ref."
        }
        if ($split.Target -match "^docker://") {
            throw "$($entry.Path):$($entry.LineNumber) uses '$actionRef'; docker actions must be reviewed separately."
        }
        if (-not (Test-ShaRef $split.Ref)) {
            throw "$($entry.Path):$($entry.LineNumber) uses '$actionRef'; external actions must be pinned to a 40-character SHA."
        }
    }
}

function Resolve-ActionRef {
    param([string]$ActionRef)

    $split = Split-ActionRef $ActionRef
    if (-not $split.Ref -or $split.Target -notmatch "^(?<owner>[^/\s@]+)/(?<repo>[^/\s@]+)(?:/.*)?$") {
        throw "Malformed GitHub Action reference '$ActionRef'. Expected owner/repo@ref."
    }

    $ownerRepo = "$($Matches.owner)/$($Matches.repo)"
    $ref = $split.Ref
    if (Test-ShaRef $ref) {
        return [pscustomobject]@{
            OwnerRepo = $ownerRepo
            Ref       = $ref
            Sha       = $ref.ToLowerInvariant()
        }
    }

    $url = "https://github.com/$ownerRepo.git"
    $tagRef = "refs/tags/$ref"
    $headRef = "refs/heads/$ref"
    $output = @(& git ls-remote $url $tagRef $headRef 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not resolve $ActionRef with git ls-remote: $($output -join ' ')"
        return [pscustomobject]@{
            OwnerRepo = $ownerRepo
            Ref       = $ref
            Sha       = $null
        }
    }

    $sha = Resolve-LsRemoteSha -Output $output -Ref $tagRef
    if (-not $sha) {
        $sha = Resolve-LsRemoteSha -Output $output -Ref $headRef
    }
    return [pscustomobject]@{
        OwnerRepo = $ownerRepo
        Ref       = $ref
        Sha       = $sha
    }
}

function Invoke-SelfTest {
    $sha = "de0fac2e4500dabe0009e67214ff5f5447ce83dd"
    $line = "$sha`trefs/tags/v6"
    Assert-Equal "tag sha parsed" (Resolve-LsRemoteSha -Output @($line) -Ref "refs/tags/v6") $sha
    Assert-Equal "missing sha reports unresolved" (Resolve-LsRemoteSha -Output @() -Ref "refs/tags/v6") $null
    Assert-Equal "action ref formats" (Format-ActionRefReport -OwnerRepo "actions/checkout" -Ref "v6" -Sha $sha) "actions/checkout@v6 -> $sha"

    $workflowRoot = Join-Path ([System.IO.Path]::GetTempPath()) "statspro-action-refs-$([System.Guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Path $workflowRoot | Out-Null
        $workflowPath = Join-Path $workflowRoot "checks.yml"
        Set-Content -LiteralPath $workflowPath -Encoding UTF8 -Value @"
name: self-test
jobs:
  test:
    steps:
      - uses: actions/checkout@v6
      - uses: BigWigsMods/packager@$sha
      - uses: ./local/action
"@
        $refs = @(Read-WorkflowActionRefs -WorkflowRoot $workflowRoot)
        Assert-Equal "workflow ref count" $refs.Count 3
        Assert-ThrowsMatch "unpinned workflow ref rejected" {
            Assert-WorkflowActionRefsPinned -Refs $refs
        } "actions/checkout@v6.*40-character SHA"

        $pinnedRefs = @(
            [pscustomobject]@{ Path = "checks.yml"; LineNumber = 1; ActionRef = "actions/checkout@$sha" },
            [pscustomobject]@{ Path = "release.yml"; LineNumber = 2; ActionRef = "owner/repo/.github/workflows/reusable.yml@$sha" },
            [pscustomobject]@{ Path = "local.yml"; LineNumber = 3; ActionRef = "./local/action" }
        )
        Assert-WorkflowActionRefsPinned -Refs $pinnedRefs
    }
    finally {
        if (Test-Path -LiteralPath $workflowRoot) {
            Remove-Item -LiteralPath $workflowRoot -Recurse -Force
        }
    }

    Write-Host "CI action ref reporter self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if ($ActionRefs.Count -eq 0) {
    if (-not $EnforcePinnedWorkflowRefs) {
        throw "Provide at least one -ActionRefs value or pass -EnforcePinnedWorkflowRefs."
    }
}

if ($EnforcePinnedWorkflowRefs) {
    $workflowRefs = @(Read-WorkflowActionRefs -WorkflowRoot $WorkflowRoot)
    Assert-WorkflowActionRefsPinned -Refs $workflowRefs
    Write-Host "Workflow action refs are pinned ($($workflowRefs.Count) uses entries checked)."
}

if ($ActionRefs.Count -gt 0) {
    Write-Host "== CI action refs =="
    foreach ($actionRef in $ActionRefs) {
        $resolved = Resolve-ActionRef -ActionRef $actionRef
        Write-Host (Format-ActionRefReport -OwnerRepo $resolved.OwnerRepo -Ref $resolved.Ref -Sha $resolved.Sha)
    }
}
