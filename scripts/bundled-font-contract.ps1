$ErrorActionPreference = 'Stop'

function Get-StatsProBundledFontFiles {
    @(
        'fonts/Audiowide-Regular.ttf',
        'fonts/BadScript-Regular.ttf',
        'fonts/Bangers-Regular.ttf',
        'fonts/BlackOpsOne-Regular.ttf',
        'fonts/DejaVuSans.ttf',
        'fonts/DejaVuSerif.ttf',
        'fonts/DoHyeon-Regular.ttf',
        'fonts/FiraSans-Bold.ttf',
        'fonts/FiraSans-Regular.ttf',
        'fonts/FiraSansCondensed-Bold.ttf',
        'fonts/FiraSansCondensed-Regular.ttf',
        'fonts/Gentium-Regular.ttf',
        'fonts/Hack-Regular.ttf',
        'fonts/KosugiMaru-Regular.ttf',
        'fonts/LiberationSans-Regular.ttf',
        'fonts/LiberationSerif-Regular.ttf',
        'fonts/Lobster-Regular.ttf',
        'fonts/MaShanZheng-Regular.ttf',
        'fonts/Marmelad-Regular.ttf',
        'fonts/NanumPenScript-Regular.ttf',
        'fonts/Neucha.ttf',
        'fonts/NotoSans-Regular.ttf',
        'fonts/OldStandard-Regular.ttf',
        'fonts/Oswald-Regular.ttf',
        'fonts/PTM55FT.ttf',
        'fonts/PT_Sans-Narrow-Web-Bold.ttf',
        'fonts/PT_Sans-Narrow-Web-Regular.ttf',
        'fonts/PT_Sans-Web-Bold.ttf',
        'fonts/PT_Sans-Web-Regular.ttf',
        'fonts/PT_Serif-Web-Bold.ttf',
        'fonts/PT_Serif-Web-Regular.ttf',
        'fonts/Philosopher-Regular.ttf',
        'fonts/PressStart2P-Regular.ttf',
        'fonts/RobotoCondensed-Regular.ttf',
        'fonts/RubikMonoOne-Regular.ttf',
        'fonts/RuslanDisplay-Regular.ttf',
        'fonts/RussoOne-Regular.ttf',
        'fonts/SawarabiMincho-Regular.ttf',
        'fonts/SourceHanSansCN-Regular.otf',
        'fonts/SourceHanSansTW-Regular.otf',
        'fonts/SourceHanSerifCN-Regular.otf',
        'fonts/SourceHanSerifTW-Regular.otf',
        'fonts/SpecialElite-Regular.ttf',
        'fonts/ZCOOLXiaoWei-Regular.ttf',
        'fonts/licenses/Audiowide.txt',
        'fonts/licenses/BadScript-Regular-License.txt',
        'fonts/licenses/Bangers.txt',
        'fonts/licenses/BlackOpsOne.txt',
        'fonts/licenses/DejaVu.txt',
        'fonts/licenses/DoHyeon-Regular-License.txt',
        'fonts/licenses/FiraSans.txt',
        'fonts/licenses/FiraSansCondensed.txt',
        'fonts/licenses/Gentium.txt',
        'fonts/licenses/Hack.txt',
        'fonts/licenses/KosugiMaru-Regular-License.txt',
        'fonts/licenses/Liberation.txt',
        'fonts/licenses/Lobster-Regular-License.txt',
        'fonts/licenses/MaShanZheng-Regular-License.txt',
        'fonts/licenses/Marmelad-Regular-License.txt',
        'fonts/licenses/NanumPenScript-Regular-License.txt',
        'fonts/licenses/Neucha-License.txt',
        'fonts/licenses/NotoSans.txt',
        'fonts/licenses/OldStandard-Regular-License.txt',
        'fonts/licenses/Oswald.txt',
        'fonts/licenses/PTMono.txt',
        'fonts/licenses/PTSans.txt',
        'fonts/licenses/PTSansNarrow.txt',
        'fonts/licenses/PTSerif.txt',
        'fonts/licenses/Philosopher-Regular-License.txt',
        'fonts/licenses/PressStart2P-Regular-License.txt',
        'fonts/licenses/Roboto.txt',
        'fonts/licenses/RubikMonoOne-Regular-License.txt',
        'fonts/licenses/RuslanDisplay-Regular-License.txt',
        'fonts/licenses/RussoOne-Regular-License.txt',
        'fonts/licenses/SawarabiMincho-Regular-License.txt',
        'fonts/licenses/SourceHanSans.txt',
        'fonts/licenses/SourceHanSerif.txt',
        'fonts/licenses/SpecialElite.txt',
        'fonts/licenses/TeX-Gyre-Adventor.txt',
        'fonts/licenses/ZCOOLXiaoWei-Regular-License.txt',
        'fonts/texgyreadventor-bold.otf',
        'fonts/texgyreadventor-regular.otf'
    )
}

function Assert-StatsProBundledFontCatalog {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$SourceText)

    $rows = [regex]::Matches($SourceText, '(?m)^\s*\{\s*name = "(?<name>[^"]+)", file = "(?<file>[^"]+)"(?<attrs>[^\r\n]*)\},?\s*$')
    if ($rows.Count -ne @($Manifest.fonts).Count) { throw 'Runtime font catalog count differs from the provenance manifest.' }
    $byFile = @{}
    foreach ($row in $rows) {
        $file = $row.Groups['file'].Value
        if ($byFile.ContainsKey($file)) { throw "Duplicate runtime font file: $file" }
        $byFile[$file] = $row
    }
    foreach ($font in $Manifest.fonts) {
        $file = [System.IO.Path]::GetFileName($font.path)
        $row = $byFile[$file]
        if (-not $row -or $row.Groups['name'].Value -cne $font.name) { throw "Runtime font name differs from manifest: $file" }
        $attrs = $row.Groups['attrs'].Value
        if ($attrs -match '\b(name|file)\s*=') { throw "Duplicate runtime font identity: $file" }
        foreach ($field in @('latin', 'cyrillic', 'hans', 'hant', 'hangul', 'japanese')) {
            $assignments = [regex]::Matches($attrs, '\b' + $field + '\s*=')
            $declared = [regex]::Match($attrs, '\b' + $field + '\s*=\s*(true|false)\b')
            if ($assignments.Count -gt 1 -or ($assignments.Count -eq 1 -and -not $declared.Success)) {
                throw "Duplicate or invalid runtime font $field attribute: $file"
            }
            $runtimeValue = if ($declared.Success) { $declared.Groups[1].Value -ceq 'true' } else { $field -ceq 'latin' }
            $property = $font.PSObject.Properties[$field]
            $manifestValue = if ($property) { $property.Value } else { $field -ceq 'latin' }
            if ($runtimeValue -cne $manifestValue) { throw "Runtime font $field coverage differs from manifest: $file" }
        }
        if ([regex]::Matches($attrs, '\bregion\s*=').Count -gt 1 -or
            [regex]::Matches($attrs, '\blatinLocales\s*=').Count -gt 1) {
            throw "Duplicate runtime font presentation attribute: $file"
        }
        $region = [regex]::Match($attrs, '\bregion\s*=\s*"([^"]+)"').Groups[1].Value
        $property = $font.PSObject.Properties['region']
        $expectedRegion = if ($property) { $property.Value } else { '' }
        if ($region -cne $expectedRegion) { throw "Runtime font region differs from manifest: $file" }
        $locales = [regex]::Match($attrs, '\blatinLocales\s*=\s*\{([^}]+)\}')
        $localeRows = @([regex]::Matches($locales.Groups[1].Value, '\b([a-z]{2}[A-Z]{2})\s*=\s*(true|false)\b'))
        $runtimeLocales = @($localeRows | ForEach-Object {
            if ($_.Groups[2].Value -cne 'true') { throw "Invalid runtime font locale override: $file" }
            $_.Groups[1].Value
        } | Sort-Object)
        if (@($runtimeLocales | Select-Object -Unique).Count -ne $runtimeLocales.Count) {
            throw "Duplicate runtime font locale override: $file"
        }
        $property = $font.PSObject.Properties['latinLocales']
        $expectedLocales = if ($property) { @($property.Value | Sort-Object) } else { @() }
        if (($runtimeLocales -join ',') -cne ($expectedLocales -join ',')) { throw "Runtime font locale overrides differ from manifest: $file" }
    }
    $aliases = [regex]::Match($SourceText, '(?ms)addon\.retiredFonts\s*=\s*\{(?<body>.*?)^\}')
    $runtimeAliases = @([regex]::Matches($aliases.Groups['body'].Value, '\["([^"]+)"\]\s*=\s*"([^"]+)"'))
    if ($runtimeAliases.Count -ne @($Manifest.retiredFonts.PSObject.Properties).Count) { throw 'Runtime retired font aliases differ from manifest.' }
    $seenAliases = @{}
    foreach ($alias in $runtimeAliases) {
        $old = $alias.Groups[1].Value
        if ($seenAliases.ContainsKey($old)) { throw "Duplicate runtime retired font alias: $old" }
        $seenAliases[$old] = $true
        $target = $alias.Groups[2].Value
        $property = $Manifest.retiredFonts.PSObject.Properties[$old]
        if (-not $property -or $property.Value -cne $target -or -not $byFile.ContainsKey($target)) {
            throw "Runtime retired font alias differs from manifest: $old"
        }
    }
}

function Assert-StatsProBundledFontMaterials {
    param([Parameter(Mandatory)][string]$Root)

    $manifestPath = Join-Path $PSScriptRoot 'bundled-fonts.json'
    $manifest = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or @($manifest.fonts).Count -ne 46) {
        throw 'Bundled font manifest must contain schema 1 and exactly 46 fonts.'
    }
    # The canonical runtime catalog and provenance manifest must describe the
    # same faces. Archive byte parity is checked separately against the source.
    Assert-StatsProBundledFontCatalog -Manifest $manifest -SourceText ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '../StatsPro_Fonts.lua')))
    $expected = @(Get-StatsProBundledFontFiles)
    $fontPaths = @($manifest.fonts | ForEach-Object { $_.path })
    $expectedFonts = @($expected | Where-Object { $_ -match '\.(ttf|otf)$' })
    if (@($fontPaths | Select-Object -Unique).Count -ne 46 -or
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
        foreach ($script in @('latin', 'hans', 'hant', 'hangul', 'japanese')) {
            if ($font.PSObject.Properties.Name -contains $script -and $font.$script -isnot [bool]) {
                throw "Bundled font $($font.path) has invalid $script coverage metadata."
            }
        }
        $property = $font.PSObject.Properties['region']
        if ($property -and $property.Value -cnotin @('zhCN', 'zhTW')) {
            throw "Bundled font $($font.path) has invalid region metadata."
        }
        $property = $font.PSObject.Properties['latinLocales']
        if ($property) {
            $locales = $property.Value
            if ($locales -isnot [array] -or @($locales).Count -eq 0 -or
                @($locales | Select-Object -Unique).Count -ne @($locales).Count) {
                throw "Bundled font $($font.path) has invalid locale overrides."
            }
            foreach ($locale in $locales) {
                if ($locale -cnotin @('enUS', 'deDE', 'esES', 'esMX', 'frFR', 'itIT', 'ptBR')) {
                    throw "Bundled font $($font.path) has unsupported locale override."
                }
            }
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
