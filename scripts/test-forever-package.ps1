[CmdletBinding()]
param([string]$ArchivePath, [string]$SourceRoot = (Join-Path $PSScriptRoot '..'), [switch]$LibraryOnly, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'saved-variables-contract.ps1')
. (Join-Path $PSScriptRoot 'third-party-contract.ps1')
function Get-ForeverPackageMap {
    $map = [ordered]@{
        'StatsPro.toc' = 'StatsPro_Forever.toc'
        'StatsPro.lua' = 'StatsPro.lua'
        'AntraktWindowLayers.lua' = 'AntraktWindowLayers.lua'
        'StatsPro_Fonts.lua' = 'StatsPro_Fonts.lua'
        'StatsPro_Forever.lua' = 'StatsPro_Forever.lua'
        'LICENSE' = 'LICENSE'
        'CHANGELOG.md' = 'CHANGELOG-FOREVER.md'
        'THIRD-PARTY-NOTICES.md' = 'THIRD-PARTY-NOTICES.md'
        'LICENSES/CallbackHandler-1.0-BSD-2-Clause.txt' = 'LICENSES/CallbackHandler-1.0-BSD-2-Clause.txt'
        'LICENSES/LibSharedMedia-3.0-LGPL-2.1.txt' = 'LICENSES/LibSharedMedia-3.0-LGPL-2.1.txt'
        'textures/forever-logo.png' = 'textures/forever-logo.png'
        'textures/font-star-filled.tga' = 'textures/font-star-filled.tga'
        'textures/font-star-outline.tga' = 'textures/font-star-outline.tga'
        'libs/LibStub/LibStub.lua' = 'libs/LibStub/LibStub.lua'
        'libs/CallbackHandler-1.0/CallbackHandler-1.0.lua' = 'libs/CallbackHandler-1.0/CallbackHandler-1.0.lua'
        'libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua' = 'libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua'
    }
    foreach ($path in Get-StatsProBundledFontFiles) { $map[$path] = $path }
    return $map
}
function Assert-ForeverToc {
    param([string]$Text, [string]$Version)
    Assert-StatsProSavedVariablesContract -TocText $Text -Description 'Forever TOC'
    foreach ($directive in @(@{ Name = 'Flavor'; Value = 'forever' }, @{ Name = 'Channel'; Value = 'beta' })) {
        $prefix = '^##[ \t]+X-StatsPro-' + $directive.Name + '[ \t]*:'
        if ([regex]::Matches($Text, '(?m)' + $prefix).Count -ne 1 -or
            [regex]::Matches($Text, '(?m)' + $prefix + '[ \t]*' + $directive.Value + '[ \t]*\r?$').Count -ne 1) {
            throw "Forever TOC requires exactly one X-StatsPro-$($directive.Name): $($directive.Value) directive"
        }
    }
    if ([regex]::Matches($Text, '(?m)^## Interface:\s*16001\s*$').Count -ne 1 -or
        [regex]::Matches($Text, '(?m)^## Interface:').Count -ne 1) { throw 'Forever Interface must be exactly 16001' }
    $versions = [regex]::Matches($Text, '(?m)^## Version:\s*([^\r\n]+)')
    if ($versions.Count -ne 1 -or $versions[0].Groups[1].Value.Trim() -cne $Version) { throw 'Forever version differs from expected flavor version' }
    $icons = [regex]::Matches($Text, '(?m)^##[ \t]+IconTexture:[ \t]*([^\r\n]*)')
    if ($icons.Count -ne 1 -or $icons[0].Groups[1].Value.Trim() -cne 'Interface\AddOns\StatsPro\textures\forever-logo.png') {
        throw 'Forever TOC must reference its single packaged Forever icon'
    }
    if ($Text -match '(?i)Archon|X-WoWI-ID') { throw 'Forever beta TOC contains unsupported publication or Archon metadata' }
    $marketplaceKeys = @('X-Curse-Project-ID', 'X-Wago-ID')
    $marketplaceIds = @('1525100', 'EGPemEN1')
    $hasMarketplaceMetadata = $Text -match '(?m)^##\s+X-(Curse-Project-ID|Wago-ID)\s*:'
    if ($hasMarketplaceMetadata) {
        for ($index = 0; $index -lt $marketplaceKeys.Count; $index++) {
            $prefix = '(?m)^##[ \t]+' + [regex]::Escape($marketplaceKeys[$index]) + '[ \t]*:'
            if ([regex]::Matches($Text, $prefix).Count -ne 1 -or
                [regex]::Matches($Text, $prefix + '[ \t]*' + $marketplaceIds[$index] + '[ \t]*\r?$').Count -ne 1) {
                throw 'Forever marketplace metadata must identify the configured StatsPro projects exactly'
            }
        }
    }
    $refs = @($Text -split '\r?\n' | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } | ForEach-Object { $_.Trim().Replace('\', '/') })
    $expected = @('libs/LibStub/LibStub.lua','libs/CallbackHandler-1.0/CallbackHandler-1.0.lua','libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua','AntraktWindowLayers.lua','StatsPro_Fonts.lua','StatsPro_Forever.lua','StatsPro.lua')
    if (($refs -join '|') -cne ($expected -join '|')) { throw 'Forever runtime load order mismatch' }
}
function Get-ForeverSourceVersion {
    param([string]$Root)
    # Flavor metadata is independent: Retail-only data updates must not bump
    # this beta's version or change its generated build identifier.
    $text = [System.IO.File]::ReadAllText((Join-Path $Root 'StatsPro_Forever.toc'))
    $versions = [regex]::Matches($text, '(?m)^## Version:\s*((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\s*$')
    if ($versions.Count -ne 1 -or [regex]::Matches($text, '(?m)^## Version:').Count -ne 1) { throw 'Forever TOC version is missing, noncanonical or ambiguous' }
    return $versions[0].Groups[1].Value
}
function Assert-ForeverArchive {
    param([string]$Path, [string]$Root)
    Assert-StatsProThirdPartyMaterials -Root $Root
    $version = Get-ForeverSourceVersion $Root
    $map = Get-ForeverPackageMap
    $zip = [System.IO.Compression.ZipFile]::OpenRead([System.IO.Path]::GetFullPath($Path))
    try {
        $expected = @($map.Keys | ForEach-Object { "StatsPro/$_" })
        $names = @($zip.Entries.FullName)
        if ($names.Count -ne $expected.Count -or @($names | Select-Object -Unique).Count -ne $names.Count -or
            (Compare-Object $names $expected -CaseSensitive)) { throw 'Forever archive contains missing, duplicate or extra entries' }
        foreach ($entry in $zip.Entries) {
            $relative = $entry.FullName.Substring('StatsPro/'.Length)
            $sourceBytes = [System.IO.File]::ReadAllBytes((Join-Path $Root $map[$relative]))
            if ($relative -ceq 'StatsPro.lua') {
                $sourceText = [System.Text.Encoding]::UTF8.GetString($sourceBytes)
                if ([regex]::Matches($sourceText, '@project-version@').Count -ne 1) { throw 'Expected one version substitution token' }
                $sourceBytes = [System.Text.Encoding]::UTF8.GetBytes($sourceText.Replace('@project-version@', "v$version"))
            }
            $stream = $entry.Open()
            $memory = [System.IO.MemoryStream]::new()
            try { $stream.CopyTo($memory); $actual = $memory.ToArray() } finally { $stream.Dispose(); $memory.Dispose() }
            if ([Convert]::ToBase64String($actual) -cne [Convert]::ToBase64String($sourceBytes)) { throw "Archive/source mismatch: $relative" }
            if ($relative -ceq 'StatsPro.toc') { Assert-ForeverToc ([System.Text.Encoding]::UTF8.GetString($actual)) $version }
        }
    }
    finally { $zip.Dispose() }
}
if ($SelfTest) {
    $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $fixture = Join-Path $tempBase ('statspro-forever-package-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixture | Out-Null
    try {
        foreach ($name in (Get-ForeverPackageMap).Values) {
            $path = Join-Path $fixture $name
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [System.IO.File]::WriteAllText($path, 'fixture')
        }
        $realRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $materialPaths = @('LICENSE','THIRD-PARTY-NOTICES.md') + @(Get-StatsProBundledFontFiles) + @(Get-StatsProThirdPartyContract | ForEach-Object {
            $_.Path
            if ($_.LicenseFile) { $_.LicenseFile }
        })
        foreach ($name in $materialPaths) { Copy-Item -LiteralPath (Join-Path $realRoot $name) -Destination (Join-Path $fixture $name) }
        [System.IO.File]::WriteAllText((Join-Path $fixture 'StatsPro.toc'), "## Version: 1.17.21`n")
        [System.IO.File]::WriteAllText((Join-Path $fixture 'StatsPro.lua'), 'local version = "@project-version@"')
        $iconDirective = '## IconTexture: Interface\AddOns\StatsPro\textures\forever-logo.png'
        $toc = "## Interface: 16001`n## Version: 1.17.21`n$iconDirective`n## SavedVariables: StatsProDB, StatsProSelfTest`n## X-StatsPro-Flavor: forever`n## X-StatsPro-Channel: beta`nlibs\LibStub\LibStub.lua`nlibs\CallbackHandler-1.0\CallbackHandler-1.0.lua`nlibs\LibSharedMedia-3.0\LibSharedMedia-3.0.lua`nAntraktWindowLayers.lua`nStatsPro_Fonts.lua`nStatsPro_Forever.lua`nStatsPro.lua`n"
        [System.IO.File]::WriteAllText((Join-Path $fixture 'StatsPro_Forever.toc'), $toc)
        $publishedToc = $toc + "## X-Curse-Project-ID: 1525100`n## X-Wago-ID: EGPemEN1`n"
        Assert-ForeverToc $publishedToc '1.17.21'
        foreach ($badMarketplaceToc in @(
            $publishedToc.Replace('1525100', '123'),
            $publishedToc.Replace('EGPemEN1', 'Wrong123'),
            $publishedToc.Replace("## X-Wago-ID: EGPemEN1`n", ''),
            ($publishedToc + "## X-Wago-ID: EGPemEN1`n")
        )) {
            $rejected = $false
            try { Assert-ForeverToc $badMarketplaceToc '1.17.21' } catch { $rejected = $true }
            if (-not $rejected) { throw 'Wrong, partial or duplicate Forever marketplace IDs accepted' }
        }
        & (Join-Path $PSScriptRoot 'build-forever-package.ps1') -SourceRoot $fixture -OutputRoot (Join-Path $fixture 'first')
        & (Join-Path $PSScriptRoot 'build-forever-package.ps1') -SourceRoot $fixture -OutputRoot (Join-Path $fixture 'second')
        $first = Join-Path $fixture 'first/StatsPro-v1.17.21-Forever-beta.zip'
        $second = Join-Path $fixture 'second/StatsPro-v1.17.21-Forever-beta.zip'
        if ((Get-FileHash -LiteralPath $first).Hash -cne (Get-FileHash -LiteralPath $second).Hash) { throw 'Builds are not deterministic' }
        [System.IO.File]::WriteAllText((Join-Path $fixture 'StatsPro.toc'), "## Version: 1.17.22`n")
        & (Join-Path $PSScriptRoot 'build-forever-package.ps1') -SourceRoot $fixture -OutputRoot (Join-Path $fixture 'retail-only-update')
        $afterRetail = Join-Path $fixture 'retail-only-update/StatsPro-v1.17.21-Forever-beta.zip'
        if ((Get-FileHash -LiteralPath $first).Hash -cne (Get-FileHash -LiteralPath $afterRetail).Hash) { throw 'Retail-only version update changed Forever archive' }
        foreach ($badVersion in @('01.17.21', '1.17.21-beta', ('1.17.21' + "`n## Version: 1.17.21"))) {
            [System.IO.File]::WriteAllText((Join-Path $fixture 'StatsPro_Forever.toc'), $toc.Replace('1.17.21', $badVersion))
            $rejected = $false
            try { Get-ForeverSourceVersion $fixture | Out-Null } catch { $rejected = $true }
            if (-not $rejected) { throw 'Invalid Forever version accepted' }
        }
        [System.IO.File]::WriteAllText((Join-Path $fixture 'StatsPro_Forever.toc'), $toc)
        foreach ($badIconToc in @(
            $toc.Replace($iconDirective, ''),
            $toc.Replace('textures\forever-logo.png', 'textures\logo.png'),
            ($toc + "$iconDirective`n")
        )) {
            $rejected = $false
            try { Assert-ForeverToc $badIconToc '1.17.21' } catch { $rejected = $true }
            if (-not $rejected) { throw 'Missing, wrong or duplicate Forever icon accepted' }
        }
        foreach ($badToc in @($toc.Replace('16001','120100'), $toc.Replace('1.17.21','1.17.22'), $toc.Replace('StatsPro_Forever.lua','StatsPro_ArchonTargets.lua'), $toc.Replace("StatsPro_Forever.lua`nStatsPro.lua", "StatsPro.lua`nStatsPro_Forever.lua"), $toc.Replace('StatsProDB, StatsProSelfTest','UnrelatedAddonDB'), $toc.Replace('## X-StatsPro-Flavor: forever',''), $toc.Replace('## X-StatsPro-Flavor: forever',"## X-StatsPro-Flavor: forever`n## X-StatsPro-Flavor: forever"), $toc.Replace('## X-StatsPro-Channel: beta',''))) {
            $rejected = $false
            try { Assert-ForeverToc $badToc '1.17.21' } catch { $rejected = $true }
            if (-not $rejected) { throw 'Invalid Forever metadata was accepted' }
        }
        foreach ($relative in Get-StatsProBundledFontFiles) {
            $materialPath = Join-Path $fixture $relative
            $original = [System.IO.File]::ReadAllBytes($materialPath)
            try {
                [System.IO.File]::Delete($materialPath)
                $rejected = $false
                try { Assert-ForeverArchive $first $fixture } catch {
                    if ($_.Exception.Message -notmatch 'Missing bundled font') { throw }
                    $rejected = $true
                }
                if (-not $rejected) { throw "Missing font/license accepted: $relative" }
                [System.IO.File]::WriteAllBytes($materialPath, $original)
                $mutated = [byte[]]$original.Clone()
                $mutated[0] = $mutated[0] -bxor 1
                [System.IO.File]::WriteAllBytes($materialPath, $mutated)
                $rejected = $false
                try { Assert-ForeverArchive $first $fixture } catch {
                    if ($_.Exception.Message -notmatch 'approved SHA256') { throw }
                    $rejected = $true
                }
                if (-not $rejected) { throw "Modified font/license accepted: $relative" }
            }
            finally { [System.IO.File]::WriteAllBytes($materialPath, $original) }
        }
        foreach ($relative in Get-StatsProBundledFontFiles) {
            $badArchive = Join-Path $fixture 'missing-font-material.zip'
            [System.IO.File]::Copy($first, $badArchive, $true)
            $zip = [System.IO.Compression.ZipFile]::Open($badArchive, [System.IO.Compression.ZipArchiveMode]::Update)
            try { $zip.GetEntry("StatsPro/$relative").Delete() } finally { $zip.Dispose() }
            $rejected = $false
            try { Assert-ForeverArchive $badArchive $fixture } catch {
                if ($_.Exception.Message -notmatch 'missing, duplicate or extra entries') { throw }
                $rejected = $true
            }
            if (-not $rejected) { throw "Archive without font/license accepted: $relative" }
        }
        $vendoredPath = Join-Path $fixture 'libs/LibStub/LibStub.lua'
        $vendoredBytes = [System.IO.File]::ReadAllBytes($vendoredPath)
        [System.IO.File]::AppendAllText($vendoredPath, "`n-- unexpected vendored change")
        try {
            $rejected = $false
            try { Assert-ForeverArchive $first $fixture } catch {
                if ($_.Exception.Message -notmatch 'expected frozen upstream SHA256') { throw }
                $rejected = $true
            }
            if (-not $rejected) { throw 'Archive checker accepted modified vendored library' }
            $rejected = $false
            $rejectedBuild = Join-Path $fixture 'rejected-vendored-build'
            try { & (Join-Path $PSScriptRoot 'build-forever-package.ps1') -SourceRoot $fixture -OutputRoot $rejectedBuild } catch {
                if ($_.Exception.Message -notmatch 'expected frozen upstream SHA256') { throw }
                $rejected = $true
            }
            if (-not $rejected -or (Test-Path -LiteralPath $rejectedBuild)) { throw 'Modified dependency was not rejected before build writes' }
        }
        finally { [System.IO.File]::WriteAllBytes($vendoredPath, $vendoredBytes) }
        $zip = [System.IO.Compression.ZipFile]::Open($first, [System.IO.Compression.ZipArchiveMode]::Update)
        try { $zip.CreateEntry('StatsPro/StatsPro_ArchonTargets.lua') | Out-Null } finally { $zip.Dispose() }
        $rejected = $false
        try { Assert-ForeverArchive $first $fixture } catch {
            if ($_.Exception.Message -notmatch 'extra entries') { throw }
            $rejected = $true
        }
        if (-not $rejected) { throw 'Extra archive file was accepted' }
        Write-Host 'Forever package self-tests passed: deterministic builds, independent flavor versions, metadata, load order, no Archon, exact archive root/files.'
    }
    finally {
        $resolved = [System.IO.Path]::GetFullPath($fixture)
        if (-not $resolved.StartsWith($tempBase.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
elseif (-not $LibraryOnly) {
    if (-not $ArchivePath) { throw 'Pass -ArchivePath for the local Forever beta archive' }
    Assert-ForeverArchive $ArchivePath $SourceRoot
    Write-Host 'Forever package passed exact files, source parity, metadata and runtime-order checks.'
}
