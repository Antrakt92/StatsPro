function Get-StatsProReleaseTagContract {
    $versionPattern = '(?<major>0|[1-9][0-9]*)\.(?<minor>0|[1-9][0-9]*)\.(?<patch>0|[1-9][0-9]*)'
    return [pscustomobject][ordered]@{
        ContractId                    = 'statspro-release-tag-v1'
        MaxComponent                  = [int]::MaxValue
        VersionPattern                = $versionPattern
        ReleaseTagPattern             = "\Av$versionPattern\z"
        PackagerProjectVersionPattern = "\A(?<tag>v$versionPattern)(?:-(?<distance>0|[1-9][0-9]*)-g(?<commit>[0-9a-fA-F]{7,40}))?\z"
    }
}

function ConvertTo-StatsProReleaseVersionParts {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    $contract = Get-StatsProReleaseTagContract
    $match = [regex]::Match(
        [string]$Value,
        "\A$($contract.VersionPattern)\z",
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) {
        throw "Malformed StatsPro release version '$Value'. Expected canonical X.Y.Z with ASCII digits and no leading zeros."
    }

    $parts = [ordered]@{}
    foreach ($name in @('major', 'minor', 'patch')) {
        $parsed = 0
        if (-not [int]::TryParse(
                $match.Groups[$name].Value,
                [System.Globalization.NumberStyles]::None,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$parsed)) {
            throw "StatsPro release version '$Value' has $name outside the supported range 0..$($contract.MaxComponent)."
        }
        $parts[$name] = $parsed
    }

    $canonical = "$($parts.major).$($parts.minor).$($parts.patch)"
    if (-not [System.StringComparer]::Ordinal.Equals($canonical, [string]$Value)) {
        throw "StatsPro release version '$Value' is not canonical; expected '$canonical'."
    }
    return [pscustomobject][ordered]@{
        Version = $canonical
        Major   = $parts.major
        Minor   = $parts.minor
        Patch   = $parts.patch
    }
}

function Test-StatsProReleaseVersion {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    try {
        [void](ConvertTo-StatsProReleaseVersionParts -Value $Value)
        return $true
    }
    catch {
        return $false
    }
}

function Assert-StatsProReleaseVersion {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    [void](ConvertTo-StatsProReleaseVersionParts -Value $Value)
}

function ConvertTo-StatsProReleaseTagParts {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    $contract = Get-StatsProReleaseTagContract
    $match = [regex]::Match(
        [string]$Value,
        $contract.ReleaseTagPattern,
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) {
        throw "Malformed StatsPro release tag '$Value'. Expected canonical vX.Y.Z with lowercase v, ASCII digits, and no leading zeros."
    }

    $versionParts = ConvertTo-StatsProReleaseVersionParts -Value ([string]$Value).Substring(1)
    return [pscustomobject][ordered]@{
        Tag     = [string]$Value
        Version = $versionParts.Version
        Major   = $versionParts.Major
        Minor   = $versionParts.Minor
        Patch   = $versionParts.Patch
    }
}

function Test-StatsProReleaseTag {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    try {
        [void](ConvertTo-StatsProReleaseTagParts -Value $Value)
        return $true
    }
    catch {
        return $false
    }
}

function Assert-StatsProReleaseTag {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    [void](ConvertTo-StatsProReleaseTagParts -Value $Value)
}

function ConvertTo-StatsProReleaseTagName {
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [switch]$AllowFullRef,
        [switch]$AllowBareVersion
    )

    if (Test-StatsProReleaseTag -Value $Value) {
        return [string]$Value
    }
    if ($AllowFullRef -and
        $null -ne $Value -and
        $Value.StartsWith('refs/tags/', [System.StringComparison]::Ordinal)) {
        $candidate = $Value.Substring('refs/tags/'.Length)
        Assert-StatsProReleaseTag -Value $candidate
        return $candidate
    }
    if ($AllowBareVersion -and (Test-StatsProReleaseVersion -Value $Value)) {
        return "v$Value"
    }

    $allowed = @('vX.Y.Z')
    if ($AllowFullRef) {
        $allowed += 'refs/tags/vX.Y.Z'
    }
    if ($AllowBareVersion) {
        $allowed += 'X.Y.Z'
    }
    throw "Malformed StatsPro release tag '$Value'. Expected $($allowed -join ' or ') with ASCII digits and no leading zeros."
}

function ConvertTo-StatsProPackagerProjectVersionParts {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    $contract = Get-StatsProReleaseTagContract
    $match = [regex]::Match(
        [string]$Value,
        $contract.PackagerProjectVersionPattern,
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) {
        throw "Malformed StatsPro Packager project version '$Value'. Expected canonical vX.Y.Z or vX.Y.Z-N-gHASH."
    }

    $tagParts = ConvertTo-StatsProReleaseTagParts -Value $match.Groups['tag'].Value
    $distance = $null
    $commit = $null
    if ($match.Groups['distance'].Success) {
        $parsedDistance = 0
        if (-not [int]::TryParse(
                $match.Groups['distance'].Value,
                [System.Globalization.NumberStyles]::None,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$parsedDistance)) {
            throw "StatsPro Packager project version '$Value' has commit distance outside the supported range 0..$($contract.MaxComponent)."
        }
        $distance = $parsedDistance
        $commit = $match.Groups['commit'].Value
    }

    return [pscustomobject][ordered]@{
        ProjectVersion = [string]$Value
        Tag            = $tagParts.Tag
        Version        = $tagParts.Version
        Distance       = $distance
        Commit         = $commit
    }
}

function Test-StatsProPackagerProjectVersion {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    try {
        [void](ConvertTo-StatsProPackagerProjectVersionParts -Value $Value)
        return $true
    }
    catch {
        return $false
    }
}

function Assert-StatsProPackagerProjectVersion {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    [void](ConvertTo-StatsProPackagerProjectVersionParts -Value $Value)
}

function Assert-StatsProReleaseTagContractSelfTest {
    foreach ($tag in @(
            'v0.0.0',
            'v1.2.3',
            'v10.20.30',
            'v2147483647.2147483647.2147483647')) {
        $parsed = ConvertTo-StatsProReleaseTagParts -Value $tag
        if (-not [System.StringComparer]::Ordinal.Equals($parsed.Tag, $tag) -or
            -not [System.StringComparer]::Ordinal.Equals("v$($parsed.Version)", $tag)) {
            throw "StatsPro release tag contract did not round-trip '$tag'."
        }
    }

    $invalidTags = @(
        $null,
        '',
        ' ',
        [string][char]9,
        [string][char]13,
        [string][char]10,
        ('v1.2.3' + [char]10),
        ' v1.2.3',
        ('v1.2.3' + [char]9),
        ([char]0x00A0 + 'v1.2.3'),
        ('v1.2.3' + [char]0x00A0),
        'v00.0.0',
        'v01.2.3',
        'v1.02.3',
        'v1.2.03',
        'V1.2.3',
        '1.2.3',
        'refs/tags/v1.2.3',
        'v1.2.3-alpha',
        'v1.2.3-rc.1',
        'v1.2.3+build',
        'v1.2.3-alpha+build',
        'v',
        'v1',
        'v1.2',
        'v1.2.3.4',
        'v1..3',
        'v1.2.',
        'vv1.2.3',
        'v1,2,3',
        'v+1.2.3',
        'v-1.2.3',
        'v1.-2.3',
        ('v' + [char]0xFF11 + '.' + [char]0xFF12 + '.' + [char]0xFF13),
        ('v' + [char]0x0661 + '.' + [char]0x0662 + '.' + [char]0x0663),
        ('v1' + [char]0x0661 + '.2.3'),
        ('v1.' + [char]10 + '2.3'),
        ('v1.' + [char]13 + '2.3'),
        ('v1.' + [char]0 + '2.3'),
        'v2147483648.0.0',
        'v0.2147483648.0',
        'v0.0.2147483648',
        ('v' + ('9' * 1000) + '.0.0'))
    foreach ($tag in $invalidTags) {
        if (Test-StatsProReleaseTag -Value $tag) {
            throw "StatsPro release tag contract accepted invalid value '$tag'."
        }
    }

    if ((ConvertTo-StatsProReleaseTagName -Value 'refs/tags/v1.2.3' -AllowFullRef) -cne 'v1.2.3' -or
        (ConvertTo-StatsProReleaseTagName -Value '1.2.3' -AllowBareVersion) -cne 'v1.2.3') {
        throw "StatsPro release tag adapters did not normalize canonical inputs."
    }
    foreach ($wrapped in @('refs/tags/V1.2.3', 'refs/tags/v01.2.3', 'refs/tags/refs/tags/v1.2.3', ' 1.2.3')) {
        $accepted = $false
        try {
            if ($wrapped.StartsWith('refs/tags/', [System.StringComparison]::Ordinal)) {
                [void](ConvertTo-StatsProReleaseTagName -Value $wrapped -AllowFullRef)
            }
            else {
                [void](ConvertTo-StatsProReleaseTagName -Value $wrapped -AllowBareVersion)
            }
            $accepted = $true
        }
        catch {
        }
        if ($accepted) {
            throw "StatsPro release tag adapter accepted invalid value '$wrapped'."
        }
    }

    foreach ($projectVersion in @(
            'v1.2.3',
            'v1.2.3-0-gabcdef0',
            'v1.2.3-12-g0123456789abcdef',
            ('v1.2.3-1-g' + ('a' * 40)))) {
        $parsed = ConvertTo-StatsProPackagerProjectVersionParts -Value $projectVersion
        if (-not [System.StringComparer]::Ordinal.Equals($parsed.ProjectVersion, $projectVersion)) {
            throw "StatsPro Packager project version contract did not round-trip '$projectVersion'."
        }
    }
    foreach ($projectVersion in @(
            'v01.2.3',
            'v1.02.3-1-gabcdef0',
            'V1.2.3-1-gabcdef0',
            'v1.2.3-01-gabcdef0',
            'v1.2.3--1-gabcdef0',
            'v1.2.3-1-gabcdef',
            ('v1.2.3-1-g' + ('a' * 41)),
            'v1.2.3-1-gabcdeg0',
            'v1.2.3-alpha',
            'v2147483648.0.0-1-gabcdef0',
            'v1.2.3-2147483648-gabcdef0')) {
        if (Test-StatsProPackagerProjectVersion -Value $projectVersion) {
            throw "StatsPro Packager project version contract accepted invalid value '$projectVersion'."
        }
    }
}
