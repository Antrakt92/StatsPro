param(
    [string]$Tag = $env:GITHUB_REF_NAME,
    [string]$Remote = "origin",
    [string]$MainRef = "origin/main",
    [switch]$AllowAncestor,
    [switch]$SelfTest,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot ".."))
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "release-tag-contract.ps1")

function Invoke-Git {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& git @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') failed with code ${exitCode}: $($output -join ' ')"
    }
    return @{
        ExitCode = $exitCode
        Output = $output
    }
}

function Normalize-ReleaseTagName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Missing release tag. Pass -Tag vX.Y.Z or set GITHUB_REF_NAME."
    }
    return ConvertTo-StatsProReleaseTagName -Value $Value -AllowFullRef
}

function Resolve-TagCommit {
    param([string]$TagName)

    $result = Invoke-Git -Arguments @("rev-parse", "refs/tags/$TagName^{commit}")
    $commit = ($result.Output | Select-Object -First 1).Trim()
    if ($commit -notmatch "^[0-9a-f]{40}$") {
        throw "Could not resolve $TagName to a commit SHA. Output: $($result.Output -join ' ')"
    }
    return $commit
}

function Fetch-OriginMain {
    param([string]$RemoteName)

    [void](Invoke-Git -Arguments @("fetch", $RemoteName, "+refs/heads/main:refs/remotes/$RemoteName/main", "--tags"))
}

function Resolve-MainHead {
    param([string]$RefName)

    $result = Invoke-Git -Arguments @("rev-parse", $RefName)
    $commit = ($result.Output | Select-Object -First 1).Trim()
    if ($commit -notmatch "^[0-9a-f]{40}$") {
        throw "Could not resolve $RefName to a commit SHA. Output: $($result.Output -join ' ')"
    }
    return $commit
}

function Test-IsAncestor {
    param([string]$Ancestor, [string]$Descendant)

    $result = Invoke-Git -Arguments @("merge-base", "--is-ancestor", $Ancestor, $Descendant) -AllowFailure
    return $result.ExitCode -eq 0
}

function Assert-ReleaseTagAtMainHead {
    param(
        [string]$TagName,
        [string]$RemoteName,
        [string]$MainRefName,
        [bool]$PermitAncestor
    )

    Fetch-OriginMain -RemoteName $RemoteName
    $tagCommit = Resolve-TagCommit -TagName $TagName
    $mainHead = Resolve-MainHead -RefName $MainRefName

    if ($tagCommit -eq $mainHead) {
        Write-Host "Release ancestry check passed: $TagName $tagCommit equals $MainRefName $mainHead"
        return
    }

    if ($PermitAncestor -and (Test-IsAncestor -Ancestor $tagCommit -Descendant $mainHead)) {
        Write-Warning "Release tag $TagName points to ancestor $tagCommit, while $MainRefName is $mainHead. Proceeding only because ancestor override is enabled."
        return
    }

    if (Test-IsAncestor -Ancestor $tagCommit -Descendant $mainHead) {
        throw "Release tag $TagName points to older main ancestor $tagCommit, but $MainRefName is $mainHead. Scheduled/normal releases must tag the current main head."
    }

    throw "Release tag $TagName commit $tagCommit is not reachable from $MainRefName $mainHead. Merge the release commit to main before tagging."
}

function New-TestRepo {
    param([string]$Root)

    $origin = Join-Path $Root "origin.git"
    $work = Join-Path $Root "work"
    [void](Invoke-Git -Arguments @("init", "--bare", $origin))
    [void](Invoke-Git -Arguments @("clone", $origin, $work))
    Push-Location $work
    try {
        [void](Invoke-Git -Arguments @("config", "user.email", "statspro-tests@example.invalid"))
        [void](Invoke-Git -Arguments @("config", "user.name", "StatsPro Tests"))
        Set-Content -Path "file.txt" -Value "one" -Encoding ASCII
        [void](Invoke-Git -Arguments @("add", "file.txt"))
        [void](Invoke-Git -Arguments @("commit", "-m", "chore: initial"))
        [void](Invoke-Git -Arguments @("branch", "-M", "main"))
        [void](Invoke-Git -Arguments @("push", "-u", "origin", "main"))
    }
    finally {
        Pop-Location
    }
    return $work
}

function Assert-ThrowsMatch {
    param([string]$Name, [scriptblock]$Script, [string]$Pattern)

    $ok = $false
    try {
        & $Script
        $ok = $true
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Name failed with wrong error: $($_.Exception.Message)"
        }
    }
    if ($ok) {
        throw "$Name should have failed."
    }
}

function Invoke-SelfTest {
    Assert-StatsProReleaseTagContractSelfTest
    if ((Normalize-ReleaseTagName "refs/tags/v1.2.3") -cne "v1.2.3") {
        throw "Release ancestry tag adapter did not preserve canonical full refs."
    }
    foreach ($invalidTag in @("v01.2.3", "refs/tags/v1.02.3", "V1.2.3", ("v1.2.3" + [char]10))) {
        Assert-ThrowsMatch "noncanonical ancestry tag rejected" {
            [void](Normalize-ReleaseTagName $invalidTag)
        } "Malformed StatsPro release tag"
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-ancestry-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    try {
        $work = New-TestRepo -Root $root
        Push-Location $work
        try {
            [void](Invoke-Git -Arguments @("tag", "v1.0.0"))
            Assert-ReleaseTagAtMainHead -TagName "v1.0.0" -RemoteName "origin" -MainRefName "origin/main" -PermitAncestor:$false

            [void](Invoke-Git -Arguments @("tag", "-a", "v1.0.1", "-m", "v1.0.1"))
            Assert-ReleaseTagAtMainHead -TagName "v1.0.1" -RemoteName "origin" -MainRefName "origin/main" -PermitAncestor:$false

            Set-Content -Path "file.txt" -Value "two" -Encoding ASCII
            [void](Invoke-Git -Arguments @("commit", "-am", "fix: main update"))
            [void](Invoke-Git -Arguments @("push", "origin", "main"))
            [void](Invoke-Git -Arguments @("tag", "v1.0.2"))
            Assert-ReleaseTagAtMainHead -TagName "v1.0.2" -RemoteName "origin" -MainRefName "origin/main" -PermitAncestor:$false
            Assert-ThrowsMatch "older main ancestor rejected" {
                Assert-ReleaseTagAtMainHead -TagName "v1.0.0" -RemoteName "origin" -MainRefName "origin/main" -PermitAncestor:$false
            } "older main ancestor"
            Assert-ReleaseTagAtMainHead -TagName "v1.0.0" -RemoteName "origin" -MainRefName "origin/main" -PermitAncestor:$true

            [void](Invoke-Git -Arguments @("checkout", "-b", "side"))
            Set-Content -Path "file.txt" -Value "side" -Encoding ASCII
            [void](Invoke-Git -Arguments @("commit", "-am", "fix: side update"))
            [void](Invoke-Git -Arguments @("tag", "v1.0.3"))
            Assert-ThrowsMatch "side branch tag rejected" {
                Assert-ReleaseTagAtMainHead -TagName "v1.0.3" -RemoteName "origin" -MainRefName "origin/main" -PermitAncestor:$false
            } "not reachable"

            Assert-ThrowsMatch "malformed tag rejected" {
                [void](Normalize-ReleaseTagName "release-1.0.0")
            } "Malformed StatsPro release tag"
        }
        finally {
            Pop-Location
        }
    }
    finally {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
    Write-Host "Release ancestry self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

$RepoRoot = (Resolve-Path $RepoRoot).Path
Push-Location $RepoRoot
try {
    $TagName = Normalize-ReleaseTagName $Tag
    Assert-ReleaseTagAtMainHead -TagName $TagName -RemoteName $Remote -MainRefName $MainRef -PermitAncestor:$AllowAncestor.IsPresent
}
finally {
    Pop-Location
}
