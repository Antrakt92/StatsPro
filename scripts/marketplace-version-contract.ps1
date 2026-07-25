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
        [string]$RequestedVersion
    )

    if ($RequestedVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "Marketplace version '$RequestedVersion' must contain exactly three numeric components."
    }

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

function Resolve-StatsProWowInterfaceVersions {
    param(
        [string[]]$AvailableVersions,
        [string[]]$RequiredVersions
    )

    $selected = @()
    foreach ($requiredVersion in @($RequiredVersions)) {
        $chosen = Select-StatsProOrdinalMarketplaceVersion `
            -AvailableVersions $AvailableVersions `
            -RequestedVersion $requiredVersion
        if (-not (Test-StatsProMarketplaceVersionSelection `
                -RequestedVersion $requiredVersion `
                -SelectedVersion $chosen)) {
            $allowed = @(Get-StatsProAcceptedMarketplaceVersions -Version $requiredVersion)
            throw "WoWInterface would select unsupported fallback '$chosen' for '$requiredVersion'; allowed: $($allowed -join ', ')."
        }
        if ($selected -notcontains $chosen) {
            $selected += $chosen
        }
    }

    return @($selected | Sort-Object { [version]$_ } -Descending)
}
