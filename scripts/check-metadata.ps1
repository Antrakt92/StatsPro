param()

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Get-SingleRegexMatch {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Description
    )

    $Text = Get-Content -Path $Path -Raw
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

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing $Description`: $Path"
    }
}

Write-Host "== Metadata =="

$TocPath = "StatsPro.toc"
$PkgmetaPath = ".pkgmeta"
$TocLines = Get-Content -Path $TocPath

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
    -Path $TocPath `
    -Pattern "^##\s+IconTexture:\s*(.+?)\s*$" `
    -Description "TOC IconTexture"
$ExpectedIconPrefix = "Interface\AddOns\$PackageName\"
if (-not $IconTexture.StartsWith($ExpectedIconPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "TOC IconTexture '$IconTexture' must start with '$ExpectedIconPrefix'."
}
$LocalIconPath = $IconTexture.Substring($ExpectedIconPrefix.Length)
Assert-PathExists "TOC IconTexture target" $LocalIconPath

$ExpectedCategories = [ordered]@{
    "Category"      = "Combat"
    "Category-deDE" = "Kampf"
    "Category-esES" = "Combate"
    "Category-esMX" = "Combate"
    "Category-frFR" = "Combat"
    "Category-itIT" = "Combattimento"
    "Category-koKR" = "전투"
    "Category-ptBR" = "Combate"
    "Category-ruRU" = "Бой"
    "Category-zhCN" = "战斗"
    "Category-zhTW" = "戰鬥"
}

foreach ($Key in $ExpectedCategories.Keys) {
    $Actual = Get-SingleRegexMatch `
        -Path $TocPath `
        -Pattern ("^##\s+" + [regex]::Escape($Key) + ":\s*(.+?)\s*$") `
        -Description "TOC $Key"
    if ($Actual -ne $ExpectedCategories[$Key]) {
        throw "TOC $Key is '$Actual', expected '$($ExpectedCategories[$Key])'."
    }
}

$LegacyCategory = Get-SingleRegexMatch `
    -Path $TocPath `
    -Pattern "^##\s+X-Category:\s*(.+?)\s*$" `
    -Description "TOC X-Category"
if ($LegacyCategory -ne "Combat") {
    throw "TOC X-Category is '$LegacyCategory', expected 'Combat'."
}

$TocFileRefs = @()
foreach ($Line in $TocLines) {
    $Trimmed = $Line.Trim()
    if ($Trimmed -eq "" -or $Trimmed.StartsWith("##")) {
        continue
    }
    $TocFileRefs += $Trimmed
}

if ($TocFileRefs.Count -eq 0) {
    throw "No file references found in $TocPath."
}

foreach ($Ref in $TocFileRefs) {
    $LocalPath = $Ref -replace "[/\\]", [System.IO.Path]::DirectorySeparatorChar
    Assert-PathExists "TOC file reference" $LocalPath
}

Write-Host "Metadata checks passed."
