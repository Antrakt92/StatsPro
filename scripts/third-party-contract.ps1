$ErrorActionPreference = "Stop"

function Get-StatsProNormalizedTextSha256 {
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

function Get-StatsProThirdPartyContract {
    return @(
        [pscustomobject][ordered]@{
            Path                 = "libs/LibStub/LibStub.lua"
            Project              = "LibStub"
            Source               = "https://repos.curseforge.com/wow/libstub/!svn/rvr/103/trunk/LibStub.lua"
            SourceRevision       = "r103"
            SourceArtifact       = ""
            SourceArtifactSha256 = ""
            RuntimeSha256        = "43C1355A2BED1C426BD33ABB53B8ABD0A7C6E9B3E295A73FA98BEE73CE2CCC50"
            License              = "Public Domain"
            LicenseFile          = ""
            LicenseTextSource    = ""
            LicenseTextSha256    = ""
            LicenseDeclarationSource = ""
            LicenseDeclarationSha256 = ""
            CopyrightNoticeSource    = ""
            CopyrightNoticeSha256    = ""
            LicenseTemplateSource    = ""
            LicenseTemplateSha256    = ""
        }
        [pscustomobject][ordered]@{
            Path                 = "libs/CallbackHandler-1.0/CallbackHandler-1.0.lua"
            Project              = "CallbackHandler-1.0"
            Source               = "https://www.curseforge.com/wow/addons/callbackhandler/files/4167614"
            SourceRevision       = "r26"
            SourceArtifact       = "CallbackHandler-1.0-1.0.9.zip"
            SourceArtifactSha256 = "75B11A307243D2DBBC80D9D4EB83A7824B4179A097470A98F4CD460C07E0299D"
            RuntimeSha256        = "84A15AF505E728AC5E5EB6A8EABA8989D1131D5F8BA14D11ABCFE4CE086DE3C1"
            License              = "BSD-2-Clause"
            LicenseFile          = "LICENSES/CallbackHandler-1.0-BSD-2-Clause.txt"
            LicenseTextSource    = ""
            LicenseTextSha256    = "BB630CB510B8EBAFC0F04C82A2BA1D21BB13598DB5B45C890185E71E96E5D933"
            LicenseDeclarationSource = "https://repos.curseforge.com/wow/callbackhandler/!svn/rvr/26/trunk/CallbackHandler-1.0.toc"
            LicenseDeclarationSha256 = "7350135554CAE47520754A72C4F076555ECC279F51A4EE0F1E16DABF7E1119E2"
            CopyrightNoticeSource    = "https://raw.githubusercontent.com/WoWUIDev/Ace3/9f61bbab1cf384488251fd85b2e9c1e2081b42a2/LICENSE.txt"
            CopyrightNoticeSha256    = "6096327FD5DCE56B74C6C7F1BFD134DBBB78C447F57D900F37064FFFA6CBCCE7"
            LicenseTemplateSource    = "https://raw.githubusercontent.com/spdx/license-list-data/421fbabbe80c94c58c12316af1bc6a2dca2362bc/text/BSD-2-Clause.txt"
            LicenseTemplateSha256    = "F32FB3B417A194167CFAD068223FC975BA96C5960513A10F66A3C28720AEC1DF"
        }
        [pscustomobject][ordered]@{
            Path                 = "libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua"
            Project              = "LibSharedMedia-3.0"
            Source               = "https://www.curseforge.com/wow/addons/libsharedmedia-3-0/files/7908455"
            SourceRevision       = "r164"
            SourceArtifact       = "LibSharedMedia-3.0-v12.0.0.zip"
            SourceArtifactSha256 = "5DEC89B8D48280554E84246A327501AEE10055649396DC23B839AF6701A1BB84"
            RuntimeSha256        = "39445CC0486FB0FDBA7367AAE9979CAA342D2AB194CDBC5ED1C6FED72FDD8D6E"
            License              = "LGPL-2.1-only"
            LicenseFile          = "LICENSES/LibSharedMedia-3.0-LGPL-2.1.txt"
            LicenseTextSource    = "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt"
            LicenseTextSha256    = "20E50FE7AAE3E56378EBF0417D9DE904F55A0E61E4DF315333E632A4D3555D95"
            LicenseDeclarationSource = "https://repos.curseforge.com/wow/libsharedmedia-3-0/!svn/rvr/164/trunk/LibSharedMedia-3.0/LibSharedMedia-3.0.lua"
            LicenseDeclarationSha256 = "7431586B50A01CC6BF562DA69761418AE8FCDB73523E70BFAC1CB8838E815DAE"
            CopyrightNoticeSource    = ""
            CopyrightNoticeSha256    = ""
            LicenseTemplateSource    = ""
            LicenseTemplateSha256    = ""
        }
    )
}

function Assert-StatsProThirdPartyNoticeField {
    param(
        [string]$Body,
        [string]$Path,
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }
    $pattern = "(?m)^\s*-\s*" + [regex]::Escape($Name) + ":\s*" + [regex]::Escape($Value) + "\s*$"
    if ($Body -notmatch $pattern) {
        throw "THIRD-PARTY-NOTICES.md section $Path must include '${Name}: $Value'."
    }
}

function Assert-StatsProThirdPartyMaterials {
    param(
        [string]$Root,
        [object[]]$Requirements = (Get-StatsProThirdPartyContract)
    )

    $noticePath = Join-Path $Root "THIRD-PARTY-NOTICES.md"
    if (-not (Test-Path -LiteralPath $noticePath -PathType Leaf)) {
        throw "Missing THIRD-PARTY-NOTICES.md for bundled runtime library notices."
    }
    $noticeText = Get-Content -LiteralPath $noticePath -Raw -Encoding UTF8

    foreach ($requirement in @($Requirements)) {
        $runtimePath = Join-Path $Root ($requirement.Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
            throw "Missing bundled runtime library $($requirement.Path)."
        }
        $runtimeHash = Get-StatsProNormalizedTextSha256 -Path $runtimePath
        if ($runtimeHash -ne $requirement.RuntimeSha256) {
            throw "Bundled runtime library $($requirement.Path) SHA256 is $runtimeHash, expected frozen upstream SHA256 $($requirement.RuntimeSha256)."
        }

        $sectionPattern = "(?ms)^##\s+" + [regex]::Escape($requirement.Path) + "\s*\r?\n(?<Body>.*?)(?=^##\s+|\z)"
        $section = [regex]::Match($noticeText, $sectionPattern)
        if (-not $section.Success) {
            throw "THIRD-PARTY-NOTICES.md is missing section for $($requirement.Path)."
        }
        $body = $section.Groups["Body"].Value

        Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "Project" -Value $requirement.Project
        Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "Source" -Value $requirement.Source
        Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "Source revision" -Value $requirement.SourceRevision
        Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "Source artifact" -Value $requirement.SourceArtifact
        Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "Source artifact SHA256" -Value $requirement.SourceArtifactSha256
        Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "License" -Value $requirement.License
        Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "License declaration" -Value $requirement.LicenseDeclarationSource
        Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "License declaration SHA256" -Value $requirement.LicenseDeclarationSha256
        Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "Copyright notice" -Value $requirement.CopyrightNoticeSource
        Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "Copyright notice SHA256" -Value $requirement.CopyrightNoticeSha256
        Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "License template" -Value $requirement.LicenseTemplateSource
        Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "License template SHA256" -Value $requirement.LicenseTemplateSha256
        Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "SHA256" -Value $runtimeHash

        if (-not [string]::IsNullOrWhiteSpace($requirement.LicenseFile)) {
            $licensePath = Join-Path $Root ($requirement.LicenseFile -replace "/", [System.IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) {
                throw "Missing license text $($requirement.LicenseFile) for $($requirement.Path)."
            }
            $licenseHash = Get-StatsProNormalizedTextSha256 -Path $licensePath
            if ($licenseHash -ne $requirement.LicenseTextSha256) {
                throw "License text $($requirement.LicenseFile) SHA256 is $licenseHash, expected $($requirement.LicenseTextSha256)."
            }
            Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "License text" -Value $requirement.LicenseFile
            Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "License text source" -Value $requirement.LicenseTextSource
            Assert-StatsProThirdPartyNoticeField -Body $body -Path $requirement.Path -Name "License text SHA256" -Value $licenseHash
        }
    }
}
