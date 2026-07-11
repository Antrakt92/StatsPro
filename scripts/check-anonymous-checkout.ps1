param(
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

function Assert-ThrowsMatch {
    param([string]$Label, [scriptblock]$Script, [string]$Pattern)

    try {
        & $Script
    }
    catch {
        if ($_.Exception.Message -match $Pattern) {
            return
        }
        throw "$Label threw an unexpected error: $($_.Exception.Message)"
    }
    throw "$Label did not throw."
}

function Assert-AnonymousGitConfiguration {
    param(
        [object[]]$SensitiveEntries,
        [string]$OriginUrl
    )

    if (@($SensitiveEntries).Count -ne 0) {
        throw "Local Git configuration retains checkout credentials."
    }
    if ([string]::IsNullOrWhiteSpace($OriginUrl)) {
        throw "The checkout is missing remote.origin.url."
    }
    if ($OriginUrl -match '(?i)(?:x-access-token|github_pat_|gh[pousr]_)') {
        throw "remote.origin.url contains credential material."
    }

    $parsed = $null
    if ([System.Uri]::TryCreate($OriginUrl, [System.UriKind]::Absolute, [ref]$parsed) -and
        -not [string]::IsNullOrEmpty($parsed.UserInfo)) {
        throw "remote.origin.url contains user information."
    }
}

function Invoke-SelfTest {
    Assert-AnonymousGitConfiguration -SensitiveEntries @() -OriginUrl "https://github.com/owner/repo"
    Assert-AnonymousGitConfiguration -SensitiveEntries @() -OriginUrl "git@github.com:owner/repo.git"

    Assert-ThrowsMatch "persisted extraheader rejected" {
        Assert-AnonymousGitConfiguration `
            -SensitiveEntries @("http.https://github.com/.extraheader AUTHORIZATION: basic redacted") `
            -OriginUrl "https://github.com/owner/repo"
    } "retains checkout credentials"
    Assert-ThrowsMatch "embedded checkout token rejected" {
        Assert-AnonymousGitConfiguration `
            -SensitiveEntries @() `
            -OriginUrl "https://x-access-token:secret@github.com/owner/repo"
    } "credential material|user information"
    Assert-ThrowsMatch "generic URL user information rejected" {
        Assert-AnonymousGitConfiguration `
            -SensitiveEntries @() `
            -OriginUrl "https://user:secret@example.invalid/repo"
    } "user information"

    Write-Host "Anonymous checkout self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git is required to verify the checkout credential boundary."
}

$sensitiveEntries = @(
    & git config --local --get-regexp '^(http\..*\.extraheader|core\.sshcommand|credential\..*|url\..*\.insteadof)$' 2>$null
)
$sensitiveExitCode = $LASTEXITCODE
if ($sensitiveExitCode -notin @(0, 1)) {
    throw "Could not inspect local Git credential configuration."
}

$originOutput = @(& git config --local --get remote.origin.url 2>$null)
if ($LASTEXITCODE -ne 0 -or $originOutput.Count -ne 1) {
    throw "Could not resolve exactly one local remote.origin.url."
}

Assert-AnonymousGitConfiguration `
    -SensitiveEntries $sensitiveEntries `
    -OriginUrl ([string]$originOutput[0])

Write-Host "Checkout Git configuration is anonymous."
