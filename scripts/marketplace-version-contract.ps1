. (Join-Path $PSScriptRoot "release-tag-contract.ps1")

function ConvertTo-StatsProMarketplaceFlavor {
    param([ValidateSet('Retail', 'Forever')][string]$Value = 'Retail')
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($Value, 'Forever')) { return 'Forever' }
    return 'Retail'
}

function Assert-StatsProMarketplaceVersionFormat {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    # SYNC: marketplace versions reuse the strict release-tag contract, so
    # leading zeros and non-canonical forms fail closed here as well.
    try {
        [void](ConvertTo-StatsProReleaseVersionParts -Value $Value)
    }
    catch {
        throw "Marketplace version '$Value' must be canonical X.Y.Z with ASCII digits and no leading zeros."
    }
}

function Get-StatsProExpectedMarketplaceProjectIdMap {
    return [ordered]@{
        CurseForge = "1525100"
        Wago = "EGPemEN1"
        WowInterface = "27130"
    }
}

function Get-RequiredTocMetadataValue {
    param([string]$TocText, [string]$Key, [string]$ExpectedValue, [string]$ValuePattern)

    $pattern = '(?mi)^##[ \t]+' + [regex]::Escape($Key) + '[ \t]*:[ \t]*([^\r\n]*)'
    $matches = [regex]::Matches($TocText, $pattern)
    if ($matches.Count -ne 1) {
        throw "TOC must contain exactly one $Key value; found $($matches.Count)."
    }
    $value = $matches[0].Groups[1].Value.Trim()
    if ($value -cnotmatch $ValuePattern) {
        throw "TOC $Key value has an invalid format."
    }
    if ($value -cne $ExpectedValue) {
        throw "TOC $Key must identify the configured StatsPro project '$ExpectedValue'."
    }
    return $value
}

function Get-StatsProMarketplaceProjectIdsFromToc {
    param([string]$Text, [ValidateSet('Retail', 'Forever')][string]$Flavor = 'Retail')

    $expected = Get-StatsProExpectedMarketplaceProjectIdMap
    $ids = [ordered]@{
        CurseForge = Get-RequiredTocMetadataValue -TocText $Text -Key 'X-Curse-Project-ID' -ExpectedValue $expected.CurseForge -ValuePattern '^[0-9]+$'
        Wago = Get-RequiredTocMetadataValue -TocText $Text -Key 'X-Wago-ID' -ExpectedValue $expected.Wago -ValuePattern '^[A-Za-z0-9]{8}$'
    }
    if ($Flavor -ieq 'Retail') {
        $ids.WowInterface = Get-RequiredTocMetadataValue -TocText $Text -Key 'X-WoWI-ID' -ExpectedValue $expected.WowInterface -ValuePattern '^[0-9]+$'
    }
    return $ids
}

function Get-StatsProAcceptedMarketplaceVersions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [string[]]$RequiredVersions = @(),
        [switch]$AllowEarlierRequiredVersions
    )

    Assert-StatsProMarketplaceVersionFormat -Value $Version
    $parsed = [version]$Version
    $accepted = @($Version)
    $minorAggregate = "$($parsed.Major).$($parsed.Minor).0"
    if ($accepted -notcontains $minorAggregate) {
        $accepted += $minorAggregate
    }
    if ($parsed.Minor -gt 0 -and $parsed.Build -eq 0) {
        $expansionAggregate = "$($parsed.Major).0.0"
        if ($accepted -notcontains $expansionAggregate) {
            $accepted += $expansionAggregate
        }
    }

    if ($AllowEarlierRequiredVersions) {
        foreach ($requiredVersion in @($RequiredVersions)) {
            Assert-StatsProMarketplaceVersionFormat -Value $requiredVersion
            $requiredParsed = [version]$requiredVersion
            if ($requiredParsed.Major -eq $parsed.Major -and
                $requiredParsed -le $parsed -and
                $accepted -notcontains $requiredVersion) {
                $accepted += $requiredVersion
            }
        }
    }

    return @($accepted)
}

function Select-StatsProOrdinalMarketplaceVersion {
    param(
        [string[]]$AvailableVersions,
        [Parameter(Mandatory = $true)]
        [string]$RequestedVersion
    )

    Assert-StatsProMarketplaceVersionFormat -Value $RequestedVersion

    $comparer = [System.StringComparer]::Ordinal
    $seen = [System.Collections.Generic.HashSet[string]]::new($comparer)
    $sawExact = $false
    $bestLower = $null
    $bestOverall = $null
    foreach ($candidate in @($AvailableVersions)) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate -notmatch '^\d+\.\d+\.\d+$') {
            throw "Marketplace compatibility response contains malformed version '$candidate'."
        }
        if (-not $seen.Add($candidate)) {
            throw "Marketplace version '$candidate' is duplicated."
        }
        if ($comparer.Equals($candidate, $RequestedVersion)) {
            $sawExact = $true
        }
        if ($null -eq $bestOverall -or $comparer.Compare($candidate, $bestOverall) -gt 0) {
            $bestOverall = $candidate
        }
        if ($comparer.Compare($candidate, $RequestedVersion) -lt 0 -and
            ($null -eq $bestLower -or $comparer.Compare($candidate, $bestLower) -gt 0)) {
            $bestLower = $candidate
        }
    }

    if ($sawExact) {
        return $RequestedVersion
    }
    if ($null -ne $bestLower) {
        return $bestLower
    }
    return $bestOverall
}

function Test-StatsProMarketplaceVersionSelection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestedVersion,
        [AllowNull()][string]$SelectedVersion,
        [string[]]$RequiredVersions = @(),
        [switch]$AllowEarlierRequiredVersions
    )

    if ([string]::IsNullOrWhiteSpace($SelectedVersion)) {
        return $false
    }
    $accepted = @(Get-StatsProAcceptedMarketplaceVersions `
        -Version $RequestedVersion `
        -RequiredVersions $RequiredVersions `
        -AllowEarlierRequiredVersions:$AllowEarlierRequiredVersions)
    return $accepted -ccontains $SelectedVersion
}

function Resolve-StatsProCurseForgeVersionIdMap {
    param([string]$Json, [string[]]$RequiredVersions, [ValidateSet('Retail', 'Forever')][string]$Flavor = 'Retail')

    $Flavor = ConvertTo-StatsProMarketplaceFlavor -Value $Flavor
    $items = @(ConvertFrom-JsonCompat $Json)
    $typeId = if ($Flavor -ieq 'Forever') { 88568 } else { 517 }
    if ($Flavor -ieq 'Forever' -and (@($RequiredVersions).Count -ne 1 -or $RequiredVersions[0] -cne '1.60.1')) {
        throw 'Forever publication requires exact game version 1.60.1.'
    }
    $ids = @()
    foreach ($version in @($RequiredVersions)) {
        $versionMatches = @($items | Where-Object {
            [string]$_.name -ceq $version -and [int]$_.gameVersionTypeID -eq $typeId
        })
        if ($versionMatches.Count -ne 1) {
            throw "CurseForge must expose exactly one $Flavor game version '$version' with gameVersionTypeID $typeId; found $($versionMatches.Count)."
        }

        $rawId = $versionMatches[0].id
        $isString = $rawId -is [string]
        $typeCode = if ($null -eq $rawId) { [System.TypeCode]::Empty } else { [System.Type]::GetTypeCode($rawId.GetType()) }
        $isInteger = $typeCode -ge [System.TypeCode]::SByte -and $typeCode -le [System.TypeCode]::UInt64
        $id = 0
        if ((-not $isString -and -not $isInteger) -or
            -not [int]::TryParse([string]$rawId, [ref]$id) -or
            $id -le 0) {
            throw "CurseForge version '$version' has an invalid positive Int32 id."
        }
        $ids += $id
    }
    return @($ids)
}

function Resolve-StatsProWagoVersionSelection {
    param([string]$Json, [string[]]$RequiredVersions, [switch]$RequireDirectCompatibilityMatch,
        [ValidateSet('Retail', 'Forever')][string]$Flavor = 'Retail')

    $Flavor = ConvertTo-StatsProMarketplaceFlavor -Value $Flavor

    # SYNC: BigWigs Packager release.sh::upload_wago reads patches.retail from this endpoint.
    $data = ConvertFrom-JsonCompat $Json
    if ($null -eq $data -or $null -eq $data.patches) {
        throw "Wago game data must contain a patches object."
    }
    if ($Flavor -ieq 'Forever') {
        if (@($RequiredVersions).Count -ne 1 -or $RequiredVersions[0] -cne '1.60.1') {
            throw 'Forever publication requires exact game version 1.60.1.'
        }
        $property = $data.patches.PSObject.Properties['forever']
        if ($null -eq $property -or $property.Value -isnot [System.Array]) {
            throw 'Wago game data must contain patches.forever as an array.'
        }
        $seenForever = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($candidate in $property.Value) {
            if ($candidate -isnot [string] -or -not $seenForever.Add($candidate)) {
                throw 'Wago patches.forever contains an invalid or duplicate version.'
            }
            Assert-StatsProMarketplaceVersionFormat -Value $candidate
        }
        if (-not $seenForever.Contains('1.60.1')) {
            throw 'Wago must expose exact patches.forever version 1.60.1; fallback is forbidden.'
        }
        return @('1.60.1')
    }
    $retailProperty = $data.patches.PSObject.Properties["retail"]
    if ($null -eq $retailProperty) {
        throw "Wago game data is missing patches.retail; Packager would ignore Retail versions."
    }

    $retailVersions = @($retailProperty.Value | ForEach-Object { [string]$_ })
    if ($retailVersions.Count -eq 0) {
        throw "Wago patches.retail is empty; Packager would ignore Retail versions."
    }
    $seen = @{}
    foreach ($versionText in $retailVersions) {
        try {
            Assert-StatsProMarketplaceVersionFormat -Value $versionText
        }
        catch {
            throw "Wago patches.retail contains malformed version '$versionText'."
        }
        if ($seen.ContainsKey($versionText)) {
            throw "Wago patches.retail contains duplicate version '$versionText'."
        }
        $seen[$versionText] = $true
    }

    $selected = @()
    foreach ($version in @($RequiredVersions)) {
        if ($RequireDirectCompatibilityMatch) {
            $acceptedVersions = @(Get-StatsProAcceptedMarketplaceVersions -Version $version)
            $directMatches = @($acceptedVersions | Where-Object { $seen.ContainsKey($_) })
            if ($directMatches.Count -eq 0) {
                throw "Wago must expose Retail patch '$version' or accepted aggregate '$($acceptedVersions -join ', ')'; found none."
            }
        }

        $packagerFallback = Select-StatsProOrdinalMarketplaceVersion `
            -AvailableVersions $retailVersions `
            -RequestedVersion $version
        $allowedFallbacks = @(Get-StatsProAcceptedMarketplaceVersions `
            -Version $version `
            -RequiredVersions $RequiredVersions `
            -AllowEarlierRequiredVersions)
        if (-not (Test-StatsProMarketplaceVersionSelection `
                -RequestedVersion $version `
                -SelectedVersion $packagerFallback `
                -RequiredVersions $RequiredVersions `
                -AllowEarlierRequiredVersions)) {
            throw "Wago Packager would replace Retail patch '$version' with unexpected fallback '$packagerFallback'; allowed: $($allowedFallbacks -join ', ')."
        }
        if ($selected -notcontains $packagerFallback) {
            $selected += $packagerFallback
        }
    }

    return @($selected | Sort-Object { [version]$_ } -Descending)
}

function Assert-StatsProWagoProjectPage {
    param([string]$Html, [string]$ExpectedProjectId)

    $expectedCanonical = 'content="https://addons.wago.io/addons/' + [regex]::Escape($ExpectedProjectId) + '"'
    if ([string]::IsNullOrWhiteSpace($Html) -or $Html -notmatch $expectedCanonical) {
        throw "Wago public project page does not identify StatsPro project '$ExpectedProjectId'."
    }
}
