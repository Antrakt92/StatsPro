$ErrorActionPreference = 'Stop'

function Get-StatsProBundledFontFiles {
    @('fonts/AntraktUISans.ttf', 'fonts/NOTICE.txt', 'fonts/licenses/Apache-2.0.txt',
      'fonts/licenses/Droid-NOTICE.txt', 'fonts/licenses/Droid-README.txt', 'fonts/licenses/NotoSans-OFL.txt')
}

function Get-StatsProFontTextHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) |
            ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Get-StatsProFontMaterialHash {
    param([string]$Path, [bool]$Text)
    if (-not $Text) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    $content = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    return Get-StatsProFontTextHash -Text $content
}

function Assert-StatsProBundledFontCatalog {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$SourceText)
    if ($Manifest.schemaVersion -ne 2 -or $Manifest.catalogSha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Invalid baseline catalogue manifest.'
    }
    $normalized = $SourceText.Replace("`r`n", "`n").Replace("`r", "`n")
    $hash = Get-StatsProFontTextHash -Text $normalized
    if ($hash -cne $Manifest.catalogSha256) { throw 'Shared font catalogue differs from its approved SHA256.' }
}

function Assert-StatsProBundledFontMaterials {
    param([Parameter(Mandatory)][string]$Root)
    $manifest = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'bundled-fonts.json')) | ConvertFrom-Json
    Assert-StatsProBundledFontCatalog -Manifest $manifest -SourceText ([System.IO.File]::ReadAllText((Join-Path $Root 'AntraktFontCatalog.lua')))
    $expected = @(Get-StatsProBundledFontFiles | Sort-Object)
    foreach ($path in $expected) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $path) -PathType Leaf)) { throw "Missing bundled font material: $path" }
    }
    $inventoryRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $actual = @(Get-ChildItem -LiteralPath (Join-Path $Root 'fonts') -Recurse -File | ForEach-Object {
        if (-not $_.FullName.StartsWith($inventoryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Font inventory escaped its source root.'
        }
        $_.FullName.Substring($inventoryRoot.Length).Replace('\', '/')
    } | Sort-Object)
    if (Compare-Object $expected $actual -CaseSensitive) { throw 'Core font inventory differs from its exact baseline allowlist.' }
    if (Compare-Object $expected @($manifest.files.path | Sort-Object) -CaseSensitive) { throw 'Baseline manifest inventory differs.' }
    foreach ($file in $manifest.files) {
        if ($file.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $file.text -isnot [bool]) { throw 'Invalid baseline material hash metadata.' }
        $hash = Get-StatsProFontMaterialHash -Path (Join-Path $Root $file.path) -Text $file.text
        if ($hash -cne $file.sha256) { throw "Baseline material differs from its approved SHA256: $($file.path)" }
    }
    $export = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'shared-font-export.json')) | ConvertFrom-Json
    foreach ($module in $export.modules.PSObject.Properties) {
        if ((Get-StatsProFontMaterialHash -Path (Join-Path $Root $module.Name) -Text $true) -cne $module.Value) {
            throw "Portable shared font module differs: $($module.Name)"
        }
    }
}
