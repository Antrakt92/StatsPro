param(
    [switch]$SelfTest,
    [switch]$ListRuntimeLuaRefs,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")),
    [string]$TocPath = "StatsPro.toc"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "third-party-contract.ps1")

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

function Get-ExpectedTocNotes {
    return [ordered]@{
        "Notes"      = "Stats and gear HUD: item level, durability, repair cost and Archon stat targets."
        "Notes-deDE" = "HUD für Werte und Ausrüstung: Gegenstandsstufe, Haltbarkeit, Reparaturkosten und Archon-Stat-Ziele."
        "Notes-esES" = "HUD de estadísticas y equipo: nivel de objeto, durabilidad, coste de reparación y objetivos de estadísticas de Archon."
        "Notes-esMX" = "HUD de estadísticas y equipo: nivel de objeto, durabilidad, costo de reparación y objetivos de estadísticas de Archon."
        "Notes-frFR" = "HUD de caractéristiques et d'équipement : niveau d'objet, durabilité, coût de réparation et objectifs de caractéristiques Archon."
        "Notes-itIT" = "HUD di statistiche ed equipaggiamento: livello oggetto, durabilità, costo di riparazione e obiettivi statistiche Archon."
        "Notes-koKR" = "능력치·장비 HUD: 아이템 레벨, 내구도, 수리 비용, Archon 능력치 목표."
        "Notes-ptBR" = "HUD de atributos e equipamento: nível de item, durabilidade, custo de reparo e metas de atributos do Archon."
        "Notes-ruRU" = "HUD характеристик и экипировки: уровень предметов, прочность, стоимость ремонта и цели характеристик Archon."
        "Notes-zhCN" = "属性与装备 HUD：装等、耐久度、修理费用及 Archon 属性目标。"
        "Notes-zhTW" = "屬性與裝備 HUD：裝等、耐久度、修理費用及 Archon 屬性目標。"
    }
}

function Assert-TocNotesContract {
    param(
        [System.Collections.IDictionary]$Metadata,
        [string]$TocPath
    )

    $expected = Get-ExpectedTocNotes
    $actualKeys = @($Metadata.Keys | Where-Object { $_ -eq "Notes" -or $_ -like "Notes-*" })
    $missing = @($expected.Keys | Where-Object { $actualKeys -cnotcontains $_ })
    $unexpected = @($actualKeys | Where-Object { $expected.Keys -cnotcontains $_ })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0) {
        throw "TOC Notes locale set mismatch. Missing: $($missing -join ', '); unexpected: $($unexpected -join ', ')."
    }

    foreach ($key in $expected.Keys) {
        $actual = Get-SingleRegexMatch `
            -Path $TocPath `
            -Pattern ("^##\s+" + [regex]::Escape($key) + ":\s*(.+?)\s*$") `
            -Description "TOC $key"
        if ([string]::IsNullOrWhiteSpace($actual)) {
            throw "TOC $key must not be empty."
        }
        if ($actual -cne $expected[$key]) {
            throw "TOC $key is '$actual', expected '$($expected[$key])'."
        }
    }
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
        ".gitattributes",
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

function Write-TestTocNotes {
    param(
        [string]$Root,
        [System.Collections.IDictionary]$Notes
    )

    $path = Join-Path $Root "notes-contract.toc"
    $lines = @($Notes.Keys | ForEach-Object { "## ${_}: $($Notes[$_])" })
    Set-Content -Path $path -Value $lines -Encoding UTF8
    return $path
}

function Write-TestThirdPartyNotices {
    param([string]$Root)

    New-Item -ItemType Directory -Path (Join-Path $Root "LICENSES") -Force | Out-Null
    Set-Content -Path (Join-Path $Root "LICENSES\CallbackHandler.txt") -Value "callback license" -Encoding UTF8
    Set-Content -Path (Join-Path $Root "LICENSES\LibSharedMedia.txt") -Value "lsm license" -Encoding UTF8

    $entries = @(
        [pscustomobject][ordered]@{
            Path = "libs/LibStub/LibStub.lua"; Project = "LibStub"; Source = "https://example.test/libstub"; SourceRevision = "r1"
            SourceArtifact = ""; SourceArtifactSha256 = ""; RuntimeSha256 = Get-StatsProNormalizedTextSha256 -Path (Join-Path $Root "libs\LibStub\LibStub.lua")
            License = "Public Domain"; LicenseFile = ""; LicenseTextSource = ""; LicenseTextSha256 = ""
            LicenseDeclarationSource = ""; LicenseDeclarationSha256 = ""; CopyrightNoticeSource = ""; CopyrightNoticeSha256 = ""
            LicenseTemplateSource = ""; LicenseTemplateSha256 = ""
        },
        [pscustomobject][ordered]@{
            Path = "libs/CallbackHandler-1.0/CallbackHandler-1.0.lua"; Project = "CallbackHandler-1.0"; Source = "https://example.test/callback"; SourceRevision = "r2"
            SourceArtifact = "callback.zip"; SourceArtifactSha256 = ("A" * 64); RuntimeSha256 = Get-StatsProNormalizedTextSha256 -Path (Join-Path $Root "libs\CallbackHandler-1.0\CallbackHandler-1.0.lua")
            License = "BSD-2-Clause"; LicenseFile = "LICENSES/CallbackHandler.txt"; LicenseTextSource = ""; LicenseTextSha256 = Get-StatsProNormalizedTextSha256 -Path (Join-Path $Root "LICENSES\CallbackHandler.txt")
            LicenseDeclarationSource = "https://example.test/callback.toc"; LicenseDeclarationSha256 = ("B" * 64); CopyrightNoticeSource = "https://example.test/copyright"; CopyrightNoticeSha256 = ("C" * 64)
            LicenseTemplateSource = "https://example.test/bsd"; LicenseTemplateSha256 = ("D" * 64)
        },
        [pscustomobject][ordered]@{
            Path = "libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua"; Project = "LibSharedMedia-3.0"; Source = "https://example.test/lsm"; SourceRevision = "r3"
            SourceArtifact = "lsm.zip"; SourceArtifactSha256 = ("E" * 64); RuntimeSha256 = Get-StatsProNormalizedTextSha256 -Path (Join-Path $Root "libs\LibSharedMedia-3.0\LibSharedMedia-3.0.lua")
            License = "LGPL-2.1-only"; LicenseFile = "LICENSES/LibSharedMedia.txt"; LicenseTextSource = "https://example.test/lgpl"; LicenseTextSha256 = Get-StatsProNormalizedTextSha256 -Path (Join-Path $Root "LICENSES\LibSharedMedia.txt")
            LicenseDeclarationSource = "https://example.test/lsm.lua"; LicenseDeclarationSha256 = ("F" * 64); CopyrightNoticeSource = ""; CopyrightNoticeSha256 = ""
            LicenseTemplateSource = ""; LicenseTemplateSha256 = ""
        }
    )
    $lines = @("# Third-Party Notices", "")
    foreach ($entry in $entries) {
        $lines += "## $($entry.Path)"
        $lines += ""
        $fields = @(
            @{ Name = "Project"; Value = $entry.Project }, @{ Name = "Source"; Value = $entry.Source },
            @{ Name = "Source revision"; Value = $entry.SourceRevision }, @{ Name = "Source artifact"; Value = $entry.SourceArtifact },
            @{ Name = "Source artifact SHA256"; Value = $entry.SourceArtifactSha256 }, @{ Name = "License"; Value = $entry.License },
            @{ Name = "License declaration"; Value = $entry.LicenseDeclarationSource }, @{ Name = "License declaration SHA256"; Value = $entry.LicenseDeclarationSha256 },
            @{ Name = "Copyright notice"; Value = $entry.CopyrightNoticeSource }, @{ Name = "Copyright notice SHA256"; Value = $entry.CopyrightNoticeSha256 },
            @{ Name = "License template"; Value = $entry.LicenseTemplateSource }, @{ Name = "License template SHA256"; Value = $entry.LicenseTemplateSha256 },
            @{ Name = "License text"; Value = $entry.LicenseFile }, @{ Name = "License text source"; Value = $entry.LicenseTextSource },
            @{ Name = "License text SHA256"; Value = $entry.LicenseTextSha256 }, @{ Name = "SHA256"; Value = $entry.RuntimeSha256 }
        )
        foreach ($field in $fields) {
            if (-not [string]::IsNullOrWhiteSpace($field.Value)) {
                $lines += "- $($field.Name): $($field.Value)"
            }
        }
        $lines += ""
    }
    Set-Content -Path (Join-Path $Root "THIRD-PARTY-NOTICES.md") -Value $lines -Encoding UTF8
    return @($entries)
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
        $noticeRequirements = @(Write-TestThirdPartyNotices -Root $root)
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

        $expectedNotes = Get-ExpectedTocNotes
        $newNotesFixture = {
            $copy = [ordered]@{}
            foreach ($key in $expectedNotes.Keys) {
                $copy[$key] = $expectedNotes[$key]
            }
            return $copy
        }

        $notesFixture = & $newNotesFixture
        $notesPath = Write-TestTocNotes -Root $root -Notes $notesFixture
        Assert-TocNotesContract -Metadata $notesFixture -TocPath $notesPath

        $notesFixture = & $newNotesFixture
        $notesFixture.Remove("Notes-zhTW")
        $notesPath = Write-TestTocNotes -Root $root -Notes $notesFixture
        Assert-ThrowsMatch "missing Notes locale rejected" {
            Assert-TocNotesContract -Metadata $notesFixture -TocPath $notesPath
        } "Missing: Notes-zhTW"

        $notesFixture = & $newNotesFixture
        $notesFixture["Notes-enGB"] = $notesFixture["Notes"]
        $notesPath = Write-TestTocNotes -Root $root -Notes $notesFixture
        Assert-ThrowsMatch "unexpected Notes locale rejected" {
            Assert-TocNotesContract -Metadata $notesFixture -TocPath $notesPath
        } "unexpected: Notes-enGB"

        $notesFixture = & $newNotesFixture
        $notesFixture["Notes"] = "On-screen secondary, defensive stats, durability and repair cost"
        $notesPath = Write-TestTocNotes -Root $root -Notes $notesFixture
        Assert-ThrowsMatch "stale Notes copy rejected" {
            Assert-TocNotesContract -Metadata $notesFixture -TocPath $notesPath
        } "TOC Notes is .* expected"

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
  - .gitattributes
  - libs/LibStub/tests
  - libs/LibStub/*.toc
  - libs/CallbackHandler-1.0/*.xml
  - libs/LibSharedMedia-3.0/*.xml
"@ -Encoding UTF8
        Assert-RequiredPkgmetaIgnores -Path (Join-Path $root ".pkgmeta")
        Assert-NoRuntimeLibExternals -Path (Join-Path $root ".pkgmeta")
        Assert-StatsProThirdPartyMaterials -Root $root -Requirements $noticeRequirements

        Set-Content -Path (Join-Path $root ".pkgmeta") -Value @"
ignore:
  - .github
  - .gitattributes
  - libs/LibStub/tests
  - libs/LibStub/*.toc
"@ -Encoding UTF8
        Assert-ThrowsMatch "missing external ignore rejected" {
            Assert-RequiredPkgmetaIgnores -Path (Join-Path $root ".pkgmeta")
        } "LibSharedMedia-3\.0/\*\.xml"

        Set-Content -Path (Join-Path $root ".pkgmeta") -Value @"
ignore:
  - .github
  - .gitattributes
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
            Assert-StatsProThirdPartyMaterials -Root $root -Requirements $noticeRequirements
        } "THIRD-PARTY-NOTICES"

        $noticeRequirements = @(Write-TestThirdPartyNotices -Root $root)
        Remove-Item -LiteralPath (Join-Path $root "LICENSES\CallbackHandler.txt")
        Assert-ThrowsMatch "missing third-party license rejected" {
            Assert-StatsProThirdPartyMaterials -Root $root -Requirements $noticeRequirements
        } "Missing license text"

        $noticeRequirements = @(Write-TestThirdPartyNotices -Root $root)
        Set-Content -LiteralPath (Join-Path $root "LICENSES\LibSharedMedia.txt") -Value "modified" -Encoding UTF8
        Assert-ThrowsMatch "modified third-party license rejected" {
            Assert-StatsProThirdPartyMaterials -Root $root -Requirements $noticeRequirements
        } "License text.*SHA256"

        $noticeRequirements = @(Write-TestThirdPartyNotices -Root $root)
        Set-Content -LiteralPath (Join-Path $root "libs\CallbackHandler-1.0\CallbackHandler-1.0.lua") -Value "modified" -Encoding UTF8
        Assert-ThrowsMatch "modified runtime library rejected" {
            Assert-StatsProThirdPartyMaterials -Root $root -Requirements $noticeRequirements
        } "runtime library.*SHA256"
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
    Assert-StatsProThirdPartyMaterials -Root $RepoRoot

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

    Assert-TocNotesContract -Metadata $contract.Metadata -TocPath $contract.TocPath

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
