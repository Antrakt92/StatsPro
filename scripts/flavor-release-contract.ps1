function Get-StatsProFlavorReleaseContract {
    param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)][string]$ExpectedTag)
    $path = Join-Path $SourceRoot 'StatsPro_Forever.toc'
    $text = if (Test-Path -LiteralPath $path -PathType Leaf) { [System.IO.File]::ReadAllText($path) } else { $null }
    Get-StatsProFlavorReleaseContractFromTocText -TocText $text -ExpectedTag $ExpectedTag
}

function Get-StatsProFlavorReleaseContractFromTocText {
    param([AllowNull()][string]$TocText, [Parameter(Mandatory)][string]$ExpectedTag)
    Assert-StatsProReleaseTag -Value $ExpectedTag
    $include = $false
    if (-not [string]::IsNullOrEmpty($TocText)) {
        $versions = [regex]::Matches($TocText, '(?m)^##[ \t]+Version:[ \t]*((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))[ \t]*\r?$')
        if ($versions.Count -ne 1 -or [regex]::Matches($TocText, '(?m)^##[ \t]+Version:').Count -ne 1) { throw 'Forever flavor TOC has noncanonical or ambiguous version' }
        Assert-StatsProReleaseVersion -Value $versions[0].Groups[1].Value
        $include = [System.StringComparer]::Ordinal.Equals("v$($versions[0].Groups[1].Value)", $ExpectedTag)
    }
    $foreverName = "StatsPro-$ExpectedTag-Forever-beta.zip"
    $names = @("StatsPro-$ExpectedTag.zip", 'release.json')
    if ($include) { $names += $foreverName }
    [pscustomobject]@{ IncludeForever = $include; ForeverArchiveName = $foreverName; AssetNames = $names }
}

function Invoke-StatsProFlavorGitRead {
    param([string]$SourceRoot, [string[]]$Arguments)
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-C', [System.IO.Path]::GetFullPath($SourceRoot), '--no-replace-objects') + $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill($true); $process.WaitForExit(); throw 'Immutable flavor Git read timed out' }
        $text = $stdout.GetAwaiter().GetResult()
        [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Immutable flavor Git object read failed' }
        return $text
    }
    finally { $process.Dispose() }
}

function Get-StatsProFlavorReleaseContractFromGit {
    param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)][string]$ExpectedCommitSha, [Parameter(Mandatory)][string]$ExpectedTag)
    if ($ExpectedCommitSha -cnotmatch '^[0-9a-f]{40}$') { throw 'Flavor selection requires an exact expected commit SHA' }
    Assert-StatsProReleaseTag -Value $ExpectedTag
    $resolved = (Invoke-StatsProFlavorGitRead -SourceRoot $SourceRoot -Arguments @('rev-parse','--verify',"$ExpectedCommitSha^{commit}")).Trim()
    if ($resolved -cne $ExpectedCommitSha) { throw 'Flavor selection commit does not resolve to the expected object' }
    $paths = @('scripts/flavor-release-contract.ps1', 'StatsPro_Forever.toc')
    $tree = Invoke-StatsProFlavorGitRead -SourceRoot $SourceRoot -Arguments (@('ls-tree', $ExpectedCommitSha, '--') + $paths)
    $tocText = $null
    foreach ($path in $paths) {
        $entries = @($tree -split '\r?\n' | Where-Object { $_ -match ('\t' + [regex]::Escape($path) + '$') })
        $localPath = Join-Path $SourceRoot $path
        if ($entries.Count -eq 0 -and $path -ceq 'StatsPro_Forever.toc') {
            if (Test-Path -LiteralPath $localPath) { throw 'Checkout Forever TOC is absent from the expected commit' }
            continue
        }
        if ($entries.Count -ne 1 -or $entries[0] -cnotmatch '^100(?:644|755) blob [0-9a-f]{40}\t') { throw "Expected commit is missing an ordinary flavor contract file: $path" }
        $text = Invoke-StatsProFlavorGitRead -SourceRoot $SourceRoot -Arguments @('show', "${ExpectedCommitSha}:$path")
        if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) { throw "Checkout is missing flavor contract file: $path" }
        $checkoutText = [System.IO.File]::ReadAllText($localPath)
        $normalizedGit = ($text.Replace("`r`n", "`n")).Replace("`r", "`n")
        $normalizedCheckout = ($checkoutText.Replace("`r`n", "`n")).Replace("`r", "`n")
        if (-not [System.StringComparer]::Ordinal.Equals($normalizedGit, $normalizedCheckout)) { throw "Checkout flavor contract differs from expected commit: $path" }
        if ($path -ceq 'StatsPro_Forever.toc') { $tocText = $text }
    }
    Get-StatsProFlavorReleaseContractFromTocText -TocText $tocText -ExpectedTag $ExpectedTag
}
