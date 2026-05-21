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

    $content = @("## Interface: 120005, 120007") + $Refs
    Set-Content -Path (Join-Path $Root "StatsPro.toc") -Value ($content -join "`n") -Encoding UTF8
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
