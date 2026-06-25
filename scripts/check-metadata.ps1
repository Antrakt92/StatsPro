param(
    [switch]$SelfTest,
    [switch]$ListRuntimeLuaRefs,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")),
    [string]$TocPath = "StatsPro.toc"
)

$ErrorActionPreference = "Stop"

function Get-SingleRegexMatch {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Description
    )

    $Text = Get-Content -Path $Path -Raw -Encoding UTF8
    $Matches = [regex]::Matches($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($Matches.Count -eq 0) {
        throw "Missing $Description in $Path"
    }
    if ($Matches.Count -gt 1) {
        throw "Found multiple $Description values in $Path"
    }
    return $Matches[0].Groups[1].Value
}

function Get-PkgmetaListItems {
    param(
        [string]$Path,
        [string]$Section
    )

    $items = @()
    $phase = $null
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match "^\s*#") {
            continue
        }
        if ($line -match "^([^\s:#][^:]*)\s*:") {
            $phase = $Matches[1].Trim()
            continue
        }
        if ($phase -eq $Section -and $line -match "^\s*-\s+(.+?)\s*$") {
            $item = $Matches[1].Trim()
            $item = $item.Trim("'`"")
            $items += $item
        }
    }
    return @($items)
}

function Assert-RequiredPkgmetaIgnores {
    param([string]$Path)

    $expectedIgnores = @(
        "libs/LibStub/tests",
        "libs/LibStub/*.toc",
        "libs/CallbackHandler-1.0/*.xml",
        "libs/LibSharedMedia-3.0/*.xml"
    )
    $actualIgnores = @(Get-PkgmetaListItems -Path $Path -Section "ignore")
    $actualLookup = @{}
    foreach ($item in $actualIgnores) {
        $actualLookup[$item] = $true
    }
    $missing = @($expectedIgnores | Where-Object { -not $actualLookup.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        throw ".pkgmeta ignore is missing package-external guard(s): $($missing -join ', ')"
    }
}

function Get-PkgmetaMappingKeys {
    param(
        [string]$Path,
        [string]$Section
    )

    $items = @()
    $phase = $null
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match "^\s*#") {
            continue
        }
        if ($line -match "^([^\s:#][^:]*)\s*:") {
            $phase = $Matches[1].Trim()
            continue
        }
        if ($phase -eq $Section -and $line -match "^\s{2,}([^:#]+?)\s*:") {
            $item = $Matches[1].Trim()
            $item = $item.Trim("'`"")
            $items += $item
        }
    }
    return @($items)
}

function Assert-NoRuntimeLibExternals {
    param([string]$Path)

    $runtimeLibRoots = @(
        "libs/LibStub",
        "libs/CallbackHandler-1.0",
        "libs/LibSharedMedia-3.0"
    )
    $externalKeys = @(Get-PkgmetaMappingKeys -Path $Path -Section "externals")
    foreach ($externalKey in $externalKeys) {
        $normalized = ($externalKey -replace "\\", "/").TrimEnd("/")
        foreach ($runtimeLibRoot in $runtimeLibRoots) {
            if ($normalized.Equals($runtimeLibRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
                $normalized.StartsWith("$runtimeLibRoot/", [System.StringComparison]::OrdinalIgnoreCase)) {
                throw ".pkgmeta must not declare runtime lib external '$externalKey'; bundled runtime libraries must be vendored and covered by THIRD-PARTY-NOTICES.md."
            }
        }
    }
}

function Get-NormalizedTextSha256 {
    param([string]$Path)

    $text = [System.IO.File]::ReadAllText($Path)
    $normalized = ($text -replace "`r`n", "`n") -replace "`r", "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("X2") }) -join "")
    }
    finally {
        $sha.Dispose()
    }
}

function Get-RuntimeLibNoticeRequirements {
    param([object[]]$RuntimeRefs)

    $knownLicenses = @{
        "libs/LibStub/LibStub.lua" = "Public Domain"
        "libs/CallbackHandler-1.0/CallbackHandler-1.0.lua" = "BSD"
        "libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua" = "LGPL v2.1"
    }
    $requirements = @()
    foreach ($ref in @($RuntimeRefs)) {
        if (-not $ref.IsVendored) {
            continue
        }
        $noticePath = ($ref.RelativePath -replace "\\", "/")
        if (-not $knownLicenses.ContainsKey($noticePath)) {
            throw "No third-party notice requirement is defined for vendored runtime file $noticePath."
        }
        $requirements += [pscustomobject]@{
            Path     = $noticePath
            FullPath = $ref.FullPath
            License  = $knownLicenses[$noticePath]
            Hash     = Get-NormalizedTextSha256 -Path $ref.FullPath
        }
    }
    return @($requirements)
}

function Assert-ThirdPartyNotices {
    param(
        [string]$RepoRoot,
        [object[]]$RuntimeRefs
    )

    $noticePath = Join-Path $RepoRoot "THIRD-PARTY-NOTICES.md"
    if (-not (Test-Path -LiteralPath $noticePath -PathType Leaf)) {
        throw "Missing THIRD-PARTY-NOTICES.md for bundled runtime library notices."
    }

    $text = Get-Content -LiteralPath $noticePath -Raw -Encoding UTF8
    $requirements = @(Get-RuntimeLibNoticeRequirements -RuntimeRefs $RuntimeRefs)
    foreach ($requirement in $requirements) {
        $sectionPattern = "(?ms)^##\s+" + [regex]::Escape($requirement.Path) + "\s*\r?\n(?<Body>.*?)(?=^##\s+|\z)"
        $section = [regex]::Match($text, $sectionPattern)
        if (-not $section.Success) {
            throw "THIRD-PARTY-NOTICES.md is missing section for $($requirement.Path)."
        }

        $body = $section.Groups["Body"].Value
        if ($body -notmatch ("(?m)^\s*-\s*License:\s*" + [regex]::Escape($requirement.License) + "\s*$")) {
            throw "THIRD-PARTY-NOTICES.md section $($requirement.Path) must include license '$($requirement.License)'."
        }
        if ($body -notmatch ("(?m)^\s*-\s*SHA256:\s*" + [regex]::Escape($requirement.Hash) + "\s*$")) {
            throw "THIRD-PARTY-NOTICES.md section $($requirement.Path) must include current SHA256 $($requirement.Hash)."
        }
    }
}

function Assert-PathExists {
    param(
        [string]$Description,
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing $Description`: $Path"
    }
}

function Normalize-RepoRelativePath {
    param([string]$Value)

    return (($Value -replace "[/\\]", "\").Trim())
}

function Resolve-RepoFileRef {
    param(
        [string]$Root,
        [string]$RelativePath,
        [int]$LineNumber,
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "$Description on line $LineNumber is empty."
    }
    if ($RelativePath -match "^[a-zA-Z][a-zA-Z0-9+.-]*:") {
        throw "$Description '$RelativePath' on line $LineNumber must be a repo-relative path, not a URI or drive path."
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Description '$RelativePath' on line $LineNumber must be repo-relative, not rooted."
    }
    if ($RelativePath.IndexOfAny([char[]]"*?") -ge 0) {
        throw "$Description '$RelativePath' on line $LineNumber must not contain wildcards."
    }

    $normalized = Normalize-RepoRelativePath $RelativePath
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $Root $normalized))
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
    $rootPrefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if ($fullPath -ne $rootFull -and -not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description '$RelativePath' on line $LineNumber escapes the repository root."
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Missing $Description '$RelativePath' on line $LineNumber`: $fullPath"
    }
    return [pscustomobject]@{
        RelativePath = $normalized
        FullPath     = $fullPath
        LineNumber   = $LineNumber
        Extension    = [System.IO.Path]::GetExtension($normalized).ToLowerInvariant()
        IsVendored   = $normalized.StartsWith("libs\", [System.StringComparison]::OrdinalIgnoreCase)
        IsGenerated  = $normalized.Equals("StatsPro_ArchonTargets.lua", [System.StringComparison]::OrdinalIgnoreCase)
    }
}

function Get-TocRuntimeContract {
    param(
        [string]$RepoRoot,
        [string]$TocPath
    )

    $root = (Resolve-Path $RepoRoot).Path
    $tocFullPath = if ([System.IO.Path]::IsPathRooted($TocPath)) {
        (Resolve-Path $TocPath).Path
    }
    else {
        (Resolve-Path (Join-Path $root $TocPath)).Path
    }
    $metadata = [ordered]@{}
    $loadRefs = @()
    $seenRefs = @{}
    $lines = Get-Content -LiteralPath $tocFullPath -Encoding UTF8

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $lineNumber = $index + 1
        $trimmed = $lines[$index].Trim()
        if ($trimmed -eq "") {
            continue
        }
        if ($trimmed.StartsWith("##")) {
            if ($trimmed -match "^##\s*([^:]+):\s*(.*?)\s*$") {
                $metadata[$Matches[1]] = $Matches[2]
            }
            continue
        }
        if ($trimmed.StartsWith("#")) {
            throw "Unsupported TOC comment on line ${lineNumber}: use blank lines or ## metadata only."
        }
        if ($trimmed -match "\s+#") {
            throw "Unsupported inline comment in TOC file reference on line ${lineNumber}."
        }

        $ref = Resolve-RepoFileRef -Root $root -RelativePath $trimmed -LineNumber $lineNumber -Description "TOC file reference"
        $key = $ref.RelativePath.ToLowerInvariant()
        if ($seenRefs.ContainsKey($key)) {
            throw "Duplicate TOC file reference '$($ref.RelativePath)' on line $lineNumber."
        }
        $seenRefs[$key] = $true
        $loadRefs += $ref
    }

    if ($loadRefs.Count -eq 0) {
        throw "No file references found in $tocFullPath."
    }

    $expectedRuntimeRefs = @(
        "libs\LibStub\LibStub.lua",
        "libs\CallbackHandler-1.0\CallbackHandler-1.0.lua",
        "libs\LibSharedMedia-3.0\LibSharedMedia-3.0.lua",
        "StatsPro_ArchonTargets.lua",
        "StatsPro.lua"
    )
    $actualRuntimeRefs = @($loadRefs | ForEach-Object { $_.RelativePath })
    if ($actualRuntimeRefs.Count -ne $expectedRuntimeRefs.Count) {
        throw "StatsPro.toc must contain exactly $($expectedRuntimeRefs.Count) runtime file reference(s): $($expectedRuntimeRefs -join ', ')."
    }
    for ($index = 0; $index -lt $expectedRuntimeRefs.Count; $index++) {
        if ($actualRuntimeRefs[$index] -ne $expectedRuntimeRefs[$index]) {
            throw "StatsPro.toc runtime ref $($index + 1) is '$($actualRuntimeRefs[$index])', expected '$($expectedRuntimeRefs[$index])'."
        }
    }

    return [pscustomobject]@{
        RepoRoot       = $root
        TocPath        = $tocFullPath
        Metadata       = $metadata
        LoadRefs       = $loadRefs
        RuntimeLuaRefs = @($loadRefs | Where-Object { $_.Extension -eq ".lua" })
    }
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

function New-TestRuntimeFiles {
    param([string]$Root)

    New-Item -ItemType Directory -Path (Join-Path $Root "libs\LibStub") | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root "libs\CallbackHandler-1.0") | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root "libs\LibSharedMedia-3.0") | Out-Null
    Set-Content -Path (Join-Path $Root "libs\LibStub\LibStub.lua") -Value "" -Encoding UTF8
    Set-Content -Path (Join-Path $Root "libs\CallbackHandler-1.0\CallbackHandler-1.0.lua") -Value "" -Encoding UTF8
    Set-Content -Path (Join-Path $Root "libs\LibSharedMedia-3.0\LibSharedMedia-3.0.lua") -Value "" -Encoding UTF8
    Set-Content -Path (Join-Path $Root "StatsPro_ArchonTargets.lua") -Value "" -Encoding UTF8
    Set-Content -Path (Join-Path $Root "StatsPro.lua") -Value "" -Encoding UTF8
}

function Set-TestToc {
    param(
        [string]$Root,
        [string[]]$Refs
    )

    $content = @("## Interface: 120007, 120100") + $Refs
    Set-Content -Path (Join-Path $Root "StatsPro.toc") -Value ($content -join "`n") -Encoding UTF8
}

function Write-TestThirdPartyNotices {
    param([string]$Root)

    $entries = @(
        @{ Path = "libs\LibStub\LibStub.lua"; License = "Public Domain" },
        @{ Path = "libs\CallbackHandler-1.0\CallbackHandler-1.0.lua"; License = "BSD" },
        @{ Path = "libs\LibSharedMedia-3.0\LibSharedMedia-3.0.lua"; License = "LGPL v2.1" }
    )
    $lines = @("# Third-Party Notices", "")
    foreach ($entry in $entries) {
        $fullPath = Join-Path $Root $entry.Path
        $hash = Get-NormalizedTextSha256 -Path $fullPath
        $normalized = $entry.Path -replace "\\", "/"
        $lines += "## $normalized"
        $lines += ""
        $lines += "- License: $($entry.License)"
        $lines += "- SHA256: $hash"
        $lines += ""
    }
    Set-Content -Path (Join-Path $Root "THIRD-PARTY-NOTICES.md") -Value $lines -Encoding UTF8
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-metadata-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    try {
        New-TestRuntimeFiles -Root $root
        $validRefs = @(
            "libs\LibStub\LibStub.lua",
            "libs\CallbackHandler-1.0\CallbackHandler-1.0.lua",
            "libs\LibSharedMedia-3.0\LibSharedMedia-3.0.lua",
            "StatsPro_ArchonTargets.lua",
            "StatsPro.lua"
        )
        Set-TestToc -Root $root -Refs $validRefs
        Write-TestThirdPartyNotices -Root $root
        $contract = Get-TocRuntimeContract -RepoRoot $root -TocPath (Join-Path $root "StatsPro.toc")
        if ($contract.RuntimeLuaRefs.Count -ne 5) {
            throw "expected five runtime Lua refs, got $($contract.RuntimeLuaRefs.Count)"
        }
        if (-not $contract.RuntimeLuaRefs[0].IsVendored) {
            throw "expected first runtime ref to be marked vendored"
        }
        if (-not $contract.RuntimeLuaRefs[3].IsGenerated) {
            throw "expected Archon target file to be marked generated"
        }

        Set-TestToc -Root $root -Refs @(
            "libs/LibStub/LibStub.lua",
            "libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
            "libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua",
            "StatsPro_ArchonTargets.lua",
            "StatsPro.lua"
        )
        [void](Get-TocRuntimeContract -RepoRoot $root -TocPath (Join-Path $root "StatsPro.toc"))

        Set-TestToc -Root $root -Refs @(
            "libs\LibStub\LibStub.lua",
            "libs\LibSharedMedia-3.0\LibSharedMedia-3.0.lua",
            "libs\CallbackHandler-1.0\CallbackHandler-1.0.lua",
            "StatsPro_ArchonTargets.lua",
            "StatsPro.lua"
        )
        Assert-ThrowsMatch "swapped library order rejected" {
            [void](Get-TocRuntimeContract -RepoRoot $root -TocPath (Join-Path $root "StatsPro.toc"))
        } "expected 'libs\\CallbackHandler-1\.0\\CallbackHandler-1\.0\.lua'"

        Set-TestToc -Root $root -Refs @(
            "libs\LibStub\LibStub.lua",
            "libs\CallbackHandler-1.0\CallbackHandler-1.0.lua",
            "libs\LibSharedMedia-3.0\LibSharedMedia-3.0.lua",
            "StatsPro.lua",
            "StatsPro_ArchonTargets.lua"
        )
        Assert-ThrowsMatch "generated data after addon rejected" {
            [void](Get-TocRuntimeContract -RepoRoot $root -TocPath (Join-Path $root "StatsPro.toc"))
        } "expected 'StatsPro_ArchonTargets\.lua'"

        Set-TestToc -Root $root -Refs @(
            "libs\LibStub\LibStub.lua",
            "libs\CallbackHandler-1.0\CallbackHandler-1.0.lua",
            "libs\LibSharedMedia-3.0\LibSharedMedia-3.0.lua",
            "StatsPro.lua"
        )
        Assert-ThrowsMatch "missing generated data rejected" {
            [void](Get-TocRuntimeContract -RepoRoot $root -TocPath (Join-Path $root "StatsPro.toc"))
        } "exactly 5 runtime"

        Set-TestToc -Root $root -Refs @(
            "libs\LibStub\LibStub.lua",
            "libs\CallbackHandler-1.0\CallbackHandler-1.0.lua",
            "libs\LibSharedMedia-3.0\LibSharedMedia-3.0.lua",
            "StatsPro_ArchonTargets.lua",
            "..\outside.lua"
        )
        Assert-ThrowsMatch "path traversal rejected" {
            [void](Get-TocRuntimeContract -RepoRoot $root -TocPath (Join-Path $root "StatsPro.toc"))
        } "escapes the repository root"

        Set-TestToc -Root $root -Refs @(
            "libs\LibStub\LibStub.lua",
            "libs\CallbackHandler-1.0\CallbackHandler-1.0.lua",
            "libs\LibSharedMedia-3.0\LibSharedMedia-3.0.lua",
            "StatsPro_ArchonTargets.lua",
            "C:\Temp\StatsPro.lua"
        )
        Assert-ThrowsMatch "absolute path rejected" {
            [void](Get-TocRuntimeContract -RepoRoot $root -TocPath (Join-Path $root "StatsPro.toc"))
        } "repo-relative"

        Set-TestToc -Root $root -Refs @(
            "libs\LibStub\LibStub.lua",
            "libs\CallbackHandler-1.0\CallbackHandler-1.0.lua",
            "libs\LibSharedMedia-3.0\LibSharedMedia-3.0.lua",
            "StatsPro_ArchonTargets.lua",
            "StatsPro.lua # inline comment"
        )
        Assert-ThrowsMatch "inline comments rejected" {
            [void](Get-TocRuntimeContract -RepoRoot $root -TocPath (Join-Path $root "StatsPro.toc"))
        } "inline comment"

        Set-Content -Path (Join-Path $root ".pkgmeta") -Value @"
ignore:
  - .github
  - libs/LibStub/tests
  - libs/LibStub/*.toc
  - libs/CallbackHandler-1.0/*.xml
  - libs/LibSharedMedia-3.0/*.xml
"@ -Encoding UTF8
        Assert-RequiredPkgmetaIgnores -Path (Join-Path $root ".pkgmeta")
        Assert-NoRuntimeLibExternals -Path (Join-Path $root ".pkgmeta")
        Assert-ThirdPartyNotices -RepoRoot $root -RuntimeRefs $contract.RuntimeLuaRefs

        Set-Content -Path (Join-Path $root ".pkgmeta") -Value @"
ignore:
  - .github
  - libs/LibStub/tests
  - libs/LibStub/*.toc
"@ -Encoding UTF8
        Assert-ThrowsMatch "missing external ignore rejected" {
            Assert-RequiredPkgmetaIgnores -Path (Join-Path $root ".pkgmeta")
        } "LibSharedMedia-3\.0/\*\.xml"

        Set-Content -Path (Join-Path $root ".pkgmeta") -Value @"
ignore:
  - .github
  - libs/LibStub/tests
  - libs/LibStub/*.toc
  - libs/CallbackHandler-1.0/*.xml
  - libs/LibSharedMedia-3.0/*.xml
externals:
  libs/LibStub:
    url: https://repos.curseforge.com/wow/libstub/trunk
    tag: latest
"@ -Encoding UTF8
        Assert-ThrowsMatch "runtime lib externals rejected" {
            Assert-NoRuntimeLibExternals -Path (Join-Path $root ".pkgmeta")
        } "runtime lib external"

        Remove-Item -LiteralPath (Join-Path $root "THIRD-PARTY-NOTICES.md")
        Assert-ThrowsMatch "missing third-party notices rejected" {
            Assert-ThirdPartyNotices -RepoRoot $root -RuntimeRefs $contract.RuntimeLuaRefs
        } "THIRD-PARTY-NOTICES"
    }
    finally {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
    Write-Host "Metadata self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

$RepoRoot = (Resolve-Path $RepoRoot).Path
Push-Location $RepoRoot
try {
    $contract = Get-TocRuntimeContract -RepoRoot $RepoRoot -TocPath $TocPath
    if ($ListRuntimeLuaRefs) {
        $contract.RuntimeLuaRefs | ConvertTo-Json -Depth 4 -Compress
        return
    }

    Write-Host "== Metadata =="

    $PkgmetaPath = ".pkgmeta"
    $PackageName = Get-SingleRegexMatch `
        -Path $PkgmetaPath `
        -Pattern "^package-as:\s*(\S+)\s*$" `
        -Description ".pkgmeta package-as"

    if ($PackageName -ne "StatsPro") {
        throw ".pkgmeta package-as is '$PackageName', expected 'StatsPro'."
    }

    $ManualChangelog = Get-SingleRegexMatch `
        -Path $PkgmetaPath `
        -Pattern "^\s*filename:\s*(\S+)\s*$" `
        -Description ".pkgmeta manual changelog filename"
    Assert-PathExists ".pkgmeta manual changelog" $ManualChangelog

    Assert-RequiredPkgmetaIgnores -Path $PkgmetaPath
    Assert-NoRuntimeLibExternals -Path $PkgmetaPath
    Assert-ThirdPartyNotices -RepoRoot $RepoRoot -RuntimeRefs $contract.RuntimeLuaRefs

    $InterfaceText = Get-SingleRegexMatch `
        -Path $contract.TocPath `
        -Pattern "^##\s+Interface:\s*(.+?)\s*$" `
        -Description "TOC Interface"
    $ExpectedInterfaceText = "120007, 120100"
    if ($InterfaceText -ne $ExpectedInterfaceText) {
        throw "TOC Interface is '$InterfaceText', expected '$ExpectedInterfaceText'."
    }

    $IconTexture = Get-SingleRegexMatch `
        -Path $contract.TocPath `
        -Pattern "^##\s+IconTexture:\s*(.+?)\s*$" `
        -Description "TOC IconTexture"
    $ExpectedIconPrefix = "Interface\AddOns\$PackageName\"
    if (-not $IconTexture.StartsWith($ExpectedIconPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "TOC IconTexture '$IconTexture' must start with '$ExpectedIconPrefix'."
    }
    $LocalIconPath = $IconTexture.Substring($ExpectedIconPrefix.Length)
    $IconRef = Resolve-RepoFileRef -Root $RepoRoot -RelativePath $LocalIconPath -LineNumber 0 -Description "TOC IconTexture target"
    Assert-PathExists "TOC IconTexture target" $IconRef.FullPath

    $ExpectedCategories = [ordered]@{
        "Category"      = "Combat"
        "Category-deDE" = "Kampf"
        "Category-esES" = "Combate"
        "Category-esMX" = "Combate"
        "Category-frFR" = "Combat"
        "Category-itIT" = "Combattimento"
        "Category-koKR" = ([string][char]0xC804 + [string][char]0xD22C)
        "Category-ptBR" = "Combate"
        "Category-ruRU" = ([string][char]0x0411 + [string][char]0x043E + [string][char]0x0439)
        "Category-zhCN" = ([string][char]0x6218 + [string][char]0x6597)
        "Category-zhTW" = ([string][char]0x6230 + [string][char]0x9B25)
    }

    foreach ($Key in $ExpectedCategories.Keys) {
        $Actual = Get-SingleRegexMatch `
            -Path $contract.TocPath `
            -Pattern ("^##\s+" + [regex]::Escape($Key) + ":\s*(.+?)\s*$") `
            -Description "TOC $Key"
        if ($Actual -ne $ExpectedCategories[$Key]) {
            throw "TOC $Key is '$Actual', expected '$($ExpectedCategories[$Key])'."
        }
    }

    $LegacyCategory = Get-SingleRegexMatch `
        -Path $contract.TocPath `
        -Pattern "^##\s+X-Category:\s*(.+?)\s*$" `
        -Description "TOC X-Category"
    if ($LegacyCategory -ne "Combat") {
        throw "TOC X-Category is '$LegacyCategory', expected 'Combat'."
    }

    Write-Host "Metadata checks passed."
}
finally {
    Pop-Location
}
