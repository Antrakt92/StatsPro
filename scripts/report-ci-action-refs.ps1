param(
    [string[]]$ActionRefs = @(),
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

function Resolve-ActionRef {
    param([string]$ActionRef)

    if ($ActionRef -notmatch "^(?<owner>[^/\s@]+)/(?<repo>[^/\s@]+)@(?<ref>[^\s@]+)$") {
        throw "Malformed GitHub Action reference '$ActionRef'. Expected owner/repo@ref."
    }

    $ownerRepo = "$($Matches.owner)/$($Matches.repo)"
    $ref = $Matches.ref
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

    Write-Host "CI action ref reporter self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if ($ActionRefs.Count -eq 0) {
    throw "Provide at least one -ActionRefs value."
}

Write-Host "== CI action refs =="
foreach ($actionRef in $ActionRefs) {
    $resolved = Resolve-ActionRef -ActionRef $actionRef
    Write-Host (Format-ActionRefReport -OwnerRepo $resolved.OwnerRepo -Ref $resolved.Ref -Sha $resolved.Sha)
}
