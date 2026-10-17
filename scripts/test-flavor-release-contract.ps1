$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-tag-contract.ps1')
. (Join-Path $PSScriptRoot 'release-check-contract.ps1')
. (Join-Path $PSScriptRoot 'flavor-release-contract.ps1')

$tag = 'v1.19.0'
$legacyToc = "## Version: 1.19.0`n"
$independentToc = $legacyToc + "## X-StatsPro-Release-Policy: independent`n"
function Assert-Selection {
    param([AllowNull()][string]$Text, [bool]$Include)
    $actual = Get-StatsProFlavorReleaseContractFromTocText -TocText $Text -ExpectedTag $tag
    $expected = @('StatsPro-v1.19.0.zip', 'release.json')
    if ($Include) { $expected += 'StatsPro-v1.19.0-Forever-beta.zip' }
    if ($actual.IncludeForever -ne $Include -or ($actual.AssetNames -join '|') -cne ($expected -join '|')) {
        throw "Flavor selection or exact asset set differs; expected IncludeForever=$Include"
    }
}
Assert-Selection $independentToc $false
Assert-Selection ($independentToc.Replace("`n", "`r`n")) $false
Assert-Selection $legacyToc $true
Assert-Selection ($legacyToc + "## X-StatsPro-Release-Policy: joint`n") $true
Assert-Selection "## Version: 1.18.6`n" $false
Assert-Selection $null $false
foreach ($directive in @(
    '## X-StatsPro-Release-Policy: unknown',
    '## X-StatsPro-Release-Policy:',
    '## X-StatsPro-Release-Policy',
    '## x-statspro-release-policy: independent',
    '## X-StatsPro-Release-Policy: Independent',
    "## X-StatsPro-Release-Policy: independent`n## X-StatsPro-Release-Policy: joint",
    "## X-StatsPro-Release-Policy: independent`n## X-StatsPro-Release-Policy: independent"
)) {
    Assert-ThrowsMatch 'malformed or duplicate release policy rejected' {
        Assert-Selection ($legacyToc + $directive + "`n") $false
    } 'release policy'
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('statspro-flavor-policy-' + [guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'scripts'))
    $tocPath = Join-Path $root 'StatsPro_Forever.toc'
    $helperPath = Join-Path $root 'scripts/flavor-release-contract.ps1'
    [IO.File]::WriteAllText($tocPath, $independentToc)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'flavor-release-contract.ps1') -Destination $helperPath
    [void](Invoke-StatsProFlavorGitRead $root @('init','--quiet'))
    [void](Invoke-StatsProFlavorGitRead $root @('add','.'))
    [void](Invoke-StatsProFlavorGitRead $root @('-c','core.hooksPath=/dev/null','-c','commit.gpgSign=false','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--quiet','-m','Independent channel fixture'))
    $commit = (Invoke-StatsProFlavorGitRead $root @('rev-parse','HEAD')).Trim()
    if ((Get-StatsProFlavorReleaseContractFromGit $root $commit $tag).IncludeForever) { throw 'Immutable independent channel included Forever' }
    [IO.File]::WriteAllText($tocPath, $legacyToc)
    Assert-ThrowsMatch 'checkout cannot re-enable independently released Forever' {
        Get-StatsProFlavorReleaseContractFromGit $root $commit $tag
    } 'Checkout flavor contract differs'
    [IO.File]::WriteAllText($tocPath, $independentToc)
    [IO.File]::AppendAllText($helperPath, "`n# altered helper")
    Assert-ThrowsMatch 'checkout cannot replace immutable policy implementation' {
        Get-StatsProFlavorReleaseContractFromGit $root $commit $tag
    } 'Checkout flavor contract differs'
}
finally {
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $resolved = [IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^statspro-flavor-policy-[0-9a-f]{32}$') { throw 'Unsafe flavor policy fixture cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host 'Flavor release policy tests passed: independent, legacy joint, malformed policy and immutable source boundaries.'
