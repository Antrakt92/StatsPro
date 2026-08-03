function Get-StatsProExpectedMarketplaceProjectIdMap {
    return [ordered]@{
        CurseForge = "1525100"
        Wago = "EGPemEN1"
        WowInterface = "27130"
    }
}

function Get-StatsProAcceptedMarketplaceVersions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [string[]]$RequiredVersions = @(),
        [switch]$AllowEarlierRequiredVersions
    )

    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Marketplace version '$Version' must contain exactly three numeric components."
    }

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
            if ($requiredVersion -notmatch '^\d+\.\d+\.\d+$') {
                throw "Marketplace version '$requiredVersion' must contain exactly three numeric components."
            }
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
        [string]$RequestedVersion,
        [switch]$AllowLegacyTwoComponentVersions
    )

    if ($RequestedVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "Marketplace version '$RequestedVersion' must contain exactly three numeric components."
    }

    $comparer = [System.StringComparer]::Ordinal
    $seen = [System.Collections.Generic.HashSet[string]]::new($comparer)
    # SYNC: BigWigs Packager compares the raw WoWInterface IDs ordinally. The
    # compatibility endpoint retains historical two-component Retail IDs.
    $availableVersionPattern = if ($AllowLegacyTwoComponentVersions) {
        '^\d+\.\d+(?:\.\d+)?$'
    }
    else {
        '^\d+\.\d+\.\d+$'
    }
    $sawExact = $false
    $bestLower = $null
    $bestOverall = $null
    foreach ($candidate in @($AvailableVersions)) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate -notmatch $availableVersionPattern) {
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

function Resolve-StatsProWowInterfaceVersions {
    param(
        [string[]]$AvailableVersions,
        [string[]]$RequiredVersions
    )

    $selected = @()
    foreach ($requiredVersion in @($RequiredVersions)) {
        $chosen = Select-StatsProOrdinalMarketplaceVersion `
            -AvailableVersions $AvailableVersions `
            -RequestedVersion $requiredVersion `
            -AllowLegacyTwoComponentVersions
        if (-not (Test-StatsProMarketplaceVersionSelection `
                -RequestedVersion $requiredVersion `
                -SelectedVersion $chosen `
                -RequiredVersions $RequiredVersions `
                -AllowEarlierRequiredVersions)) {
            $allowed = @(Get-StatsProAcceptedMarketplaceVersions `
                -Version $requiredVersion `
                -RequiredVersions $RequiredVersions `
                -AllowEarlierRequiredVersions)
            throw "WoWInterface would select unsupported fallback '$chosen' for '$requiredVersion'; allowed: $($allowed -join ', ')."
        }
        if ($selected -notcontains $chosen) {
            $selected += $chosen
        }
    }

    return @($selected | Sort-Object { [version]$_ } -Descending)
}

function Resolve-StatsProCurseForgeVersionIdMap {
    param([string]$Json, [string[]]$RequiredVersions)

    $items = @(ConvertFrom-JsonCompat $Json)
    $ids = @()
    foreach ($version in @($RequiredVersions)) {
        $versionMatches = @($items | Where-Object {
            [string]$_.name -eq $version -and [int]$_.gameVersionTypeID -eq 517
        })
        if ($versionMatches.Count -ne 1) {
            throw "CurseForge must expose exactly one Retail game version '$version' with gameVersionTypeID 517; found $($versionMatches.Count)."
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

function Resolve-StatsProWowInterfaceVersionsFromJson {
    param([string]$Json, [string[]]$RequiredVersions)

    $items = @(ConvertFrom-JsonCompat $Json)
    $availableVersions = @($items | Where-Object {
        [string]$_.game -ceq "Retail"
    } | ForEach-Object { [string]$_.id })
    return @(Resolve-StatsProWowInterfaceVersions `
        -AvailableVersions $availableVersions `
        -RequiredVersions $RequiredVersions)
}

function Resolve-StatsProWagoVersionSelection {
    param([string]$Json, [string[]]$RequiredVersions, [switch]$RequireDirectCompatibilityMatch)

    # SYNC: BigWigs Packager release.sh::upload_wago reads patches.retail from this endpoint.
    $data = ConvertFrom-JsonCompat $Json
    if ($null -eq $data -or $null -eq $data.patches) {
        throw "Wago game data must contain a patches object."
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
        if ($versionText -notmatch "^\d+\.\d+\.\d+$") {
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

function Assert-StatsProWowInterfaceProjectAccess {
    param([string]$Json, [string]$ExpectedProjectId)

    try {
        $items = @(ConvertFrom-JsonCompat $Json)
    }
    catch {
        throw "WoWInterface project-access response contained invalid JSON."
    }
    $projectMatches = @($items | Where-Object {
        $null -ne $_.id -and [System.StringComparer]::Ordinal.Equals([string]$_.id, $ExpectedProjectId)
    })
    if ($projectMatches.Count -ne 1) {
        throw "WoWInterface credential must expose exactly one StatsPro project '$ExpectedProjectId'; found $($projectMatches.Count)."
    }
}

function Assert-StatsProWagoProjectPage {
    param([string]$Html, [string]$ExpectedProjectId)

    $expectedCanonical = 'content="https://addons.wago.io/addons/' + [regex]::Escape($ExpectedProjectId) + '"'
    if ([string]::IsNullOrWhiteSpace($Html) -or $Html -notmatch $expectedCanonical) {
        throw "Wago public project page does not identify StatsPro project '$ExpectedProjectId'."
    }
}
