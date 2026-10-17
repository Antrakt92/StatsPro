$ErrorActionPreference = 'Stop'

function Get-StatsProBundledFontFiles {
    @(
        'fonts/DejaVuSans.ttf', 'fonts/DejaVuSerif.ttf',
        'fonts/Gentium-Regular.ttf', 'fonts/Hack-Regular.ttf',
        'fonts/LiberationSans-Regular.ttf', 'fonts/LiberationSerif-Regular.ttf',
        'fonts/LiberationMono-Regular.ttf', 'fonts/texgyreadventor-regular.otf',
        'fonts/texgyreadventor-bold.otf', 'fonts/NotoSans-Regular.ttf',
        'fonts/RobotoCondensed-Regular.ttf', 'fonts/Oswald-Regular.ttf',
        'fonts/licenses/DejaVu.txt', 'fonts/licenses/Gentium.txt',
        'fonts/licenses/Hack.txt', 'fonts/licenses/Liberation.txt',
        'fonts/licenses/TeX-Gyre-Adventor.txt', 'fonts/licenses/NotoSans.txt',
        'fonts/licenses/Roboto.txt', 'fonts/licenses/Oswald.txt',
        'fonts/Audiowide-Regular.ttf',
        'fonts/Bangers-Regular.ttf',
        'fonts/BlackOpsOne-Regular.ttf',
        'fonts/FiraMono-Regular.ttf',
        'fonts/FiraSans-Bold.ttf',
        'fonts/FiraSans-Regular.ttf',
        'fonts/FiraSansCondensed-Bold.ttf',
        'fonts/FiraSansCondensed-Regular.ttf',
        'fonts/PTM55FT.ttf',
        'fonts/PT_Sans-Narrow-Web-Bold.ttf',
        'fonts/PT_Sans-Narrow-Web-Regular.ttf',
        'fonts/PT_Sans-Web-Bold.ttf',
        'fonts/PT_Sans-Web-Regular.ttf',
        'fonts/PT_Serif-Web-Bold.ttf',
        'fonts/PT_Serif-Web-Regular.ttf',
        'fonts/SpecialElite-Regular.ttf',
        'fonts/licenses/Audiowide.txt',
        'fonts/licenses/Bangers.txt',
        'fonts/licenses/BlackOpsOne.txt',
        'fonts/licenses/FiraMono.txt',
        'fonts/licenses/FiraSans.txt',
        'fonts/licenses/FiraSansCondensed.txt',
        'fonts/licenses/PTMono.txt',
        'fonts/licenses/PTSans.txt',
        'fonts/licenses/PTSansNarrow.txt',
        'fonts/licenses/PTSerif.txt',
        'fonts/licenses/SpecialElite.txt'
    )
}

function Assert-StatsProBundledFontMaterials {
    param([Parameter(Mandatory)][string]$Root)

    $manifestPath = Join-Path $PSScriptRoot 'bundled-fonts.json'
    $manifest = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or @($manifest.fonts).Count -ne 28) {
        throw 'Bundled font manifest must contain schema 1 and exactly 28 fonts.'
    }
    $expected = @(Get-StatsProBundledFontFiles)
    $fontPaths = @($manifest.fonts | ForEach-Object { $_.path })
    $expectedFonts = @($expected | Where-Object { $_ -match '\.(ttf|otf)$' })
    if (@($fontPaths | Select-Object -Unique).Count -ne 28 -or
        (Compare-Object $fontPaths $expectedFonts -CaseSensitive)) {
        throw 'Bundled font manifest paths differ from the exact approved font set.'
    }
    $licensePaths = @($manifest.fonts | ForEach-Object { $_.licenseFile } | Select-Object -Unique)
    if (Compare-Object $licensePaths @($expected | Where-Object { $_ -like 'fonts/licenses/*' }) -CaseSensitive) {
        throw 'Bundled font manifest licenses differ from the exact approved license set.'
    }
    $notice = [System.IO.File]::ReadAllText((Join-Path $Root 'THIRD-PARTY-NOTICES.md'))
    foreach ($font in $manifest.fonts) {
        foreach ($field in @('name', 'license', 'sourceRevision')) {
            if ($font.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($font.$field)) {
                throw "Bundled font $($font.path) has invalid $field metadata."
            }
        }
        if ($font.source -isnot [string] -or $font.source -cnotmatch '\Ahttps://[^\s]+\z' -or
            $font.cyrillic -isnot [bool] -or $font.sha256 -cnotmatch '\A[A-F0-9]{64}\z' -or
            $font.licenseSha256 -cnotmatch '\A[A-F0-9]{64}\z') {
            throw "Bundled font $($font.path) has invalid provenance or hash metadata."
        }
        $fontPath = Join-Path $Root $font.path
        $licensePath = Join-Path $Root $font.licenseFile
        if (-not (Test-Path -LiteralPath $fontPath -PathType Leaf)) { throw "Missing bundled font $($font.path)." }
        if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) { throw "Missing bundled font license $($font.licenseFile)." }
        if ((Get-FileHash -LiteralPath $fontPath -Algorithm SHA256).Hash -cne $font.sha256) {
            throw "Bundled font $($font.path) differs from its approved SHA256."
        }
        $licenseText = [System.IO.File]::ReadAllText($licensePath).Replace("`r`n", "`n").Replace("`r", "`n")
        $licenseBytes = [System.Text.Encoding]::UTF8.GetBytes($licenseText)
        $licenseHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($licenseBytes))
        if ($licenseHash -cne $font.licenseSha256) { throw "Bundled font license $($font.licenseFile) differs from its approved SHA256." }
        foreach ($path in @($font.path, $font.licenseFile)) {
            if (-not $notice.Contains($path, [System.StringComparison]::Ordinal)) {
                throw "THIRD-PARTY-NOTICES.md is missing bundled font material $path."
            }
        }
    }
}
