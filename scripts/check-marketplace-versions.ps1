param(
    [string]$TocPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")) "StatsPro.toc"),
    [string]$CurseForgeVersionsJsonPath,
    [string]$WowInterfaceVersionsJsonPath,
    [string]$WagoVersionsJsonPath,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

$ExpectedMarketplaceProjectIds = [ordered]@{
    "X-Curse-Project-ID" = "1525100"
    "X-Wago-ID" = "EGPemEN1"
    "X-WoWI-ID" = "27130"
}

function Get-RequiredTocMetadataValue {
    param(
        [string]$TocText,
        [string]$Key,
        [string]$ExpectedValue,
        [string]$ValuePattern
    )

    $matches = [regex]::Matches(
        $TocText,
        "^##\s+" + [regex]::Escape($Key) + ":\s*(\S+)\s*$",
        [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($matches.Count -ne 1) {
        throw "TOC must contain exactly one $Key value; found $($matches.Count)."
    }
    $value = $matches[0].Groups[1].Value
    if ($value -notmatch $ValuePattern) {
        throw "TOC $Key value has an invalid format."
    }
    if (-not [System.StringComparer]::Ordinal.Equals($value, $ExpectedValue)) {
        throw "TOC $Key must identify the configured StatsPro project '$ExpectedValue'."
    }
    return $value
}

function Get-MarketplaceProjectIds {
    param([string]$Path)

    $tocText = Get-Content -LiteralPath (Resolve-Path $Path).Path -Raw -Encoding UTF8
    return [ordered]@{
        CurseForge = Get-RequiredTocMetadataValue -TocText $tocText -Key "X-Curse-Project-ID" -ExpectedValue $ExpectedMarketplaceProjectIds["X-Curse-Project-ID"] -ValuePattern '^\d+$'
        Wago = Get-RequiredTocMetadataValue -TocText $tocText -Key "X-Wago-ID" -ExpectedValue $ExpectedMarketplaceProjectIds["X-Wago-ID"] -ValuePattern '^[A-Za-z0-9]{8}$'
        WowInterface = Get-RequiredTocMetadataValue -TocText $tocText -Key "X-WoWI-ID" -ExpectedValue $ExpectedMarketplaceProjectIds["X-WoWI-ID"] -ValuePattern '^\d+$'
    }
}

function Get-RequiredMarketplaceCredentials {
    param([hashtable]$EnvironmentValues = $null)

    if ($null -eq $EnvironmentValues) {
        $EnvironmentValues = @{
            CF_API_KEY = [Environment]::GetEnvironmentVariable("CF_API_KEY")
            WAGO_API_TOKEN = [Environment]::GetEnvironmentVariable("WAGO_API_TOKEN")
            WOWI_API_TOKEN = [Environment]::GetEnvironmentVariable("WOWI_API_TOKEN")
        }
    }

    $credentials = [ordered]@{}
    foreach ($name in @("CF_API_KEY", "WAGO_API_TOKEN", "WOWI_API_TOKEN")) {
        $value = [string]$EnvironmentValues[$name]
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "$name is required for the marketplace release preflight."
        }
        if (-not [System.StringComparer]::Ordinal.Equals($value, $value.Trim())) {
            throw "$name must not contain leading or trailing whitespace."
        }
        if ($value -match '[\x00-\x1F\x7F]') {
            throw "$name contains an invalid control character."
        }
        $credentials[$name] = $value
    }
    return $credentials
}

function ConvertFrom-JsonCompat {
    param([string]$Json)

    $command = Get-Command ConvertFrom-Json
    if ($command.Parameters.ContainsKey("Depth")) {
        return ($Json | ConvertFrom-Json -Depth 100)
    }
    return ($Json | ConvertFrom-Json)
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

function Get-TocInterfaceValues {
    param([string]$Path)

    $tocText = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $matches = [regex]::Matches($tocText, "^##\s+Interface:\s*(.+?)\s*$", [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($matches.Count -eq 0) {
        throw "Missing TOC Interface in $Path."
    }
    if ($matches.Count -gt 1) {
        throw "Found multiple TOC Interface lines in $Path."
    }
    $interfaces = @($matches[0].Groups[1].Value -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    if ($interfaces.Count -eq 0) {
        throw "TOC Interface contains no values."
    }
    foreach ($interface in $interfaces) {
        if ($interface -notmatch "^\d{6}$") {
            throw "TOC Interface value '$interface' must be a six-digit Retail interface number."
        }
    }
    return @($interfaces)
}

function Get-RequiredRetailVersionsFromInterfaces {
    param([string[]]$Interfaces)

    $versions = @()
    foreach ($interface in $Interfaces) {
        if ($interface -notmatch "^\d{6}$") {
            throw "Cannot convert interface '$interface' to a Retail version."
        }
        $major = [int]$interface.Substring(0, 2)
        $minor = [int]$interface.Substring(2, 2)
        $patch = [int]$interface.Substring(4, 2)
        $versions += "$major.$minor.$patch"
    }
    return @($versions | Sort-Object { [version]$_ } -Unique)
}

function Get-MarketplaceHttpStatusCode {
    param($Exception)

    if ($null -eq $Exception) { return $null }
    try {
        if ($Exception.Data -and $Exception.Data.Contains("MarketplaceStatusCode")) {
            return [int]$Exception.Data["MarketplaceStatusCode"]
        }
    }
    catch {
    }
    try {
        if ($Exception.Response -and $Exception.Response.StatusCode) {
            return [int]$Exception.Response.StatusCode
        }
    }
    catch {
    }
    return $null
}

function Format-MarketplaceRequestFailure {
    param($Exception)

    $statusCode = Get-MarketplaceHttpStatusCode $Exception
    if ($null -ne $statusCode) {
        return "HTTP $statusCode"
    }
    if ($Exception) {
        return $Exception.GetType().Name
    }
    return "unknown error"
}

function Test-MarketplaceAuthFailure {
    param($Exception)

    $statusCode = Get-MarketplaceHttpStatusCode $Exception
    return $null -ne $statusCode -and @(401, 403) -contains [int]$statusCode
}

function Test-MarketplaceRequestRetryable {
    param($Exception)

    $statusCode = Get-MarketplaceHttpStatusCode $Exception
    if ($null -eq $statusCode) { return $true }
    return @(408, 429, 500, 502, 503, 504) -contains [int]$statusCode
}

function Invoke-MarketplaceWebRequest {
    param(
        [string]$Uri,
        [hashtable]$Headers = @{},
        [string]$Description,
        [int]$TimeoutSec = 30,
        [int]$MaxAttempts = 3,
        [int]$InitialDelaySeconds = 2,
        [int]$MaxDelaySeconds = 10,
        [scriptblock]$Request = $null,
        [scriptblock]$Sleep = $null
    )

    if ([string]::IsNullOrWhiteSpace($Uri)) { throw "Marketplace request URI is required." }
    if ([string]::IsNullOrWhiteSpace($Description)) { throw "Marketplace request description is required." }
    if ($TimeoutSec -le 0) { throw "TimeoutSec must be positive." }
    if ($MaxAttempts -lt 1) { throw "MaxAttempts must be at least 1." }
    if ($InitialDelaySeconds -lt 0) { throw "InitialDelaySeconds must be non-negative." }
    if ($MaxDelaySeconds -lt 0) { throw "MaxDelaySeconds must be non-negative." }

    if ($null -eq $Request) {
        $Request = {
            param([string]$RequestUri, [hashtable]$RequestHeaders, [int]$RequestTimeoutSec)
            Invoke-WebRequest -Uri $RequestUri -Headers $RequestHeaders -UseBasicParsing -TimeoutSec $RequestTimeoutSec -MaximumRedirection 0
        }
    }
    if ($null -eq $Sleep) {
        $Sleep = {
            param([int]$Seconds)
            Start-Sleep -Seconds $Seconds
        }
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return (& $Request $Uri $Headers $TimeoutSec)
        }
        catch {
            $failure = Format-MarketplaceRequestFailure $_.Exception
            if (Test-MarketplaceAuthFailure $_.Exception) {
                throw ("Failed to fetch {0} from {1}: auth/permission failure: {2}" -f $Description, $Uri, $failure)
            }
            if (-not (Test-MarketplaceRequestRetryable $_.Exception)) {
                throw ("Failed to fetch {0} from {1}: {2}" -f $Description, $Uri, $failure)
            }
            if ($attempt -ge $MaxAttempts) {
                throw ("Failed to fetch {0} from {1} after {2} attempt(s): {3}" -f $Description, $Uri, $MaxAttempts, $failure)
            }

            $delaySeconds = [int][Math]::Min($MaxDelaySeconds, $InitialDelaySeconds * [Math]::Pow(2, $attempt - 1))
            Write-Warning ("Marketplace request attempt {0}/{1} failed for {2}: {3}. Retrying in {4} second(s)." -f $attempt, $MaxAttempts, $Description, $failure, $delaySeconds)
            if ($delaySeconds -gt 0) {
                & $Sleep $delaySeconds
            }
        }
    }
}

function Invoke-CurseForgeCredentialProbe {
    param(
        [string]$ApiKey,
        [scriptblock]$Request = $null
    )

    return Invoke-MarketplaceWebRequest `
        -Uri "https://wow.curseforge.com/api/game/wow/versions" `
        -Headers @{ "x-api-token" = $ApiKey } `
        -Description "CurseForge credential probe" `
        -Request $Request
}

function Assert-CurseForgeProjectResponse {
    param([string]$JsonText)

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        throw "CurseForge project-access response had an unexpected schema."
    }
    $trimmed = $JsonText.Trim()
    try {
        $parsed = ConvertFrom-JsonCompat $JsonText
    }
    catch {
        throw "CurseForge project-access response contained invalid JSON."
    }
    if ($trimmed.StartsWith('[')) {
        return
    }
    if ($null -eq $parsed) {
        throw "CurseForge project-access response had an unexpected schema."
    }
    foreach ($propertyName in @("data", "files", "items")) {
        $property = $parsed.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $property.Value -is [System.Array]) {
            return
        }
    }
    throw "CurseForge project-access response had an unexpected schema."
}

function Invoke-CurseForgeProjectProbe {
    param(
        [string]$ApiKey,
        [string]$ProjectId,
        [scriptblock]$Request = $null
    )

    $response = Invoke-MarketplaceWebRequest `
        -Uri "https://wow.curseforge.com/api/projects/$ProjectId/files?page=1&pageSize=1" `
        -Headers @{ "x-api-token" = $ApiKey } `
        -Description "CurseForge StatsPro project-access probe" `
        -Request $Request
    Assert-CurseForgeProjectResponse -JsonText ([string]$response.Content)
    return $response
}

function Assert-WowInterfaceProjectList {
    param(
        [string]$JsonText,
        [string]$ExpectedProjectId
    )

    try {
        $items = @(ConvertFrom-JsonCompat $JsonText)
    }
    catch {
        throw "WoWInterface project-access response contained invalid JSON."
    }
    $matches = @($items | Where-Object {
        $null -ne $_.id -and [System.StringComparer]::Ordinal.Equals([string]$_.id, $ExpectedProjectId)
    })
    if ($matches.Count -ne 1) {
        throw "WoWInterface credential must expose exactly one StatsPro project '$ExpectedProjectId'; found $($matches.Count)."
    }
}

function Invoke-WowInterfaceCredentialProbe {
    param(
        [string]$ApiToken,
        [string]$ProjectId,
        [scriptblock]$Request = $null
    )

    $response = Invoke-MarketplaceWebRequest `
        -Uri "https://api.wowinterface.com/addons/list.json" `
        -Headers @{ "x-api-token" = $ApiToken } `
        -Description "WoWInterface credential and project-access probe" `
        -Request $Request
    Assert-WowInterfaceProjectList -JsonText ([string]$response.Content) -ExpectedProjectId $ProjectId
    return $response
}

function Assert-WagoProjectPage {
    param(
        [string]$Html,
        [string]$ExpectedProjectId
    )

    $expectedCanonical = 'content="https://addons.wago.io/addons/' + [regex]::Escape($ExpectedProjectId) + '"'
    if ([string]::IsNullOrWhiteSpace($Html) -or $Html -notmatch $expectedCanonical) {
        throw "Wago public project page does not identify StatsPro project '$ExpectedProjectId'."
    }
}

function Invoke-WagoProjectExistenceProbe {
    param(
        [string]$ProjectId,
        [scriptblock]$Request = $null
    )

    $response = Invoke-MarketplaceWebRequest `
        -Uri "https://addons.wago.io/addons/$ProjectId" `
        -Description "Wago public project existence probe" `
        -Request $Request
    Assert-WagoProjectPage -Html ([string]$response.Content) -ExpectedProjectId $ProjectId
    return $response
}

function Read-JsonTextOrFetch {
    param(
        [string]$Path,
        [string]$Uri,
        [hashtable]$Headers = @{},
        [string]$Description
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return Get-Content -LiteralPath (Resolve-Path $Path).Path -Raw -Encoding UTF8
    }

    try {
        $response = Invoke-MarketplaceWebRequest -Uri $Uri -Headers $Headers -Description $Description
        return [string]$response.Content
    }
    catch {
        throw "Failed to fetch $Description from $Uri`: $($_.Exception.Message)"
    }
}

function Assert-CurseForgeVersions {
    param(
        [string]$JsonText,
        [string[]]$RequiredVersions
    )

    $items = @(ConvertFrom-JsonCompat $JsonText)
    foreach ($version in $RequiredVersions) {
        $matches = @($items | Where-Object {
            [string]$_.name -eq $version -and [int]$_.gameVersionTypeID -eq 517
        })
        if ($matches.Count -ne 1) {
            throw "CurseForge must expose exactly one Retail game version '$version' with gameVersionTypeID 517; found $($matches.Count)."
        }
        try {
            $id = [int]$matches[0].id
        }
        catch {
            throw "CurseForge version '$version' has a non-numeric id '$($matches[0].id)'."
        }
        if ($id -le 0) {
            throw "CurseForge version '$version' has invalid id '$($matches[0].id)'."
        }
    }
}

function Get-AcceptedRetailCompatibilityVersions {
    param([string]$Version)

    $parts = [version]$Version
    $accepted = @($Version)

    $minorAggregate = "$($parts.Major).$($parts.Minor).0"
    if ($accepted -notcontains $minorAggregate) {
        $accepted += $minorAggregate
    }

    if ($parts.Minor -gt 0 -and $parts.Build -eq 0) {
        $expansionAggregate = "$($parts.Major).0.0"
        if ($accepted -notcontains $expansionAggregate) {
            $accepted += $expansionAggregate
        }
    }

    return @($accepted)
}

function Assert-WowInterfaceVersions {
    param(
        [string]$JsonText,
        [string[]]$RequiredVersions
    )

    $items = @(ConvertFrom-JsonCompat $JsonText)
    foreach ($version in $RequiredVersions) {
        $acceptedVersions = @(Get-AcceptedRetailCompatibilityVersions -Version $version)
        $matched = $false
        foreach ($acceptedVersion in $acceptedVersions) {
            $matches = @($items | Where-Object {
                [string]$_.game -eq "Retail" -and [string]$_.id -eq $acceptedVersion
            })
            if ($matches.Count -eq 1) {
                $matched = $true
                break
            }
            if ($matches.Count -gt 1) {
                throw "WoWInterface must expose at most one Retail compatibility version '$acceptedVersion' for requested '$version'; found $($matches.Count)."
            }
        }
        if (-not $matched) {
            throw "WoWInterface must expose Retail compatibility version '$version' or accepted aggregate '$($acceptedVersions -join ', ')'; found none."
        }
    }
}

function Get-WagoPackagerFallbackVersion {
    param(
        [string[]]$AvailableVersions,
        [string]$RequestedVersion
    )

    $comparer = [System.StringComparer]::Ordinal
    $bestLower = $null
    $bestOverall = $null
    foreach ($version in $AvailableVersions) {
        if ($null -eq $bestOverall -or $comparer.Compare($version, $bestOverall) -gt 0) {
            $bestOverall = $version
        }
        if ($comparer.Compare($version, $RequestedVersion) -lt 0 -and
            ($null -eq $bestLower -or $comparer.Compare($version, $bestLower) -gt 0)) {
            $bestLower = $version
        }
    }
    if ($null -ne $bestLower) {
        return $bestLower
    }
    return $bestOverall
}

function Assert-WagoVersions {
    param(
        [string]$JsonText,
        [string[]]$RequiredVersions
    )

    # SYNC: BigWigs Packager release.sh::upload_wago reads patches.retail from this endpoint.
    $data = ConvertFrom-JsonCompat $JsonText
    if ($null -eq $data -or $null -eq $data.patches) {
        throw "Wago game data must contain a patches object."
    }
    $retailProperty = $data.patches.PSObject.Properties["retail"]
    if ($null -eq $retailProperty) {
        throw "Wago game data is missing patches.retail; Packager would ignore Retail versions."
    }

    $retailVersions = @($retailProperty.Value)
    if ($retailVersions.Count -eq 0) {
        throw "Wago patches.retail is empty; Packager would ignore Retail versions."
    }
    $seen = @{}
    foreach ($item in $retailVersions) {
        $versionText = [string]$item
        if ($versionText -notmatch "^\d+\.\d+\.\d+$") {
            throw "Wago patches.retail contains malformed version '$versionText'."
        }
        if ($seen.ContainsKey($versionText)) {
            throw "Wago patches.retail contains duplicate version '$versionText'."
        }
        $seen[$versionText] = $true
    }

    foreach ($version in $RequiredVersions) {
        $acceptedVersions = @(Get-AcceptedRetailCompatibilityVersions -Version $version)
        $matches = @($acceptedVersions | Where-Object { $seen.ContainsKey($_) })
        if ($matches.Count -eq 0) {
            throw "Wago must expose Retail patch '$version' or accepted aggregate '$($acceptedVersions -join ', ')'; found none."
        }
        if ($seen.ContainsKey($version)) {
            continue
        }

        $packagerFallback = Get-WagoPackagerFallbackVersion -AvailableVersions $retailVersions -RequestedVersion $version
        $allowedFallbacks = @($acceptedVersions)
        $requestedParsed = [version]$version
        foreach ($requiredVersion in $RequiredVersions) {
            $requiredParsed = [version]$requiredVersion
            if ($requiredParsed.Major -eq $requestedParsed.Major -and
                $requiredParsed -le $requestedParsed -and
                $allowedFallbacks -notcontains $requiredVersion) {
                $allowedFallbacks += $requiredVersion
            }
        }
        if ($allowedFallbacks -notcontains $packagerFallback) {
            throw "Wago Packager would replace Retail patch '$version' with unexpected fallback '$packagerFallback'; allowed: $($allowedFallbacks -join ', ')."
        }
    }
}

function Assert-MarketplaceVersions {
    param(
        [string]$TocPath,
        [string]$CurseForgeVersionsJsonPath,
        [string]$WowInterfaceVersionsJsonPath,
        [string]$WagoVersionsJsonPath
    )

    $projectIds = Get-MarketplaceProjectIds -Path $TocPath
    $credentials = Get-RequiredMarketplaceCredentials
    $interfaces = @(Get-TocInterfaceValues -Path $TocPath)
    $requiredVersions = @(Get-RequiredRetailVersionsFromInterfaces -Interfaces $interfaces)

    $cfApiKey = $credentials.CF_API_KEY

    $curseForgeProbe = Invoke-CurseForgeCredentialProbe -ApiKey $cfApiKey
    if ([string]::IsNullOrWhiteSpace([string]$curseForgeProbe.Content)) {
        throw "CurseForge credential probe returned an empty response."
    }
    $curseForgeJson = if ([string]::IsNullOrWhiteSpace($CurseForgeVersionsJsonPath)) {
        [string]$curseForgeProbe.Content
    }
    else {
        Read-JsonTextOrFetch `
            -Path $CurseForgeVersionsJsonPath `
            -Uri "https://wow.curseforge.com/api/game/wow/versions" `
            -Description "CurseForge game versions"
    }
    Assert-CurseForgeVersions -JsonText $curseForgeJson -RequiredVersions $requiredVersions
    [void](Invoke-CurseForgeProjectProbe -ApiKey $cfApiKey -ProjectId $projectIds.CurseForge)

    [void](Invoke-WowInterfaceCredentialProbe `
        -ApiToken $credentials.WOWI_API_TOKEN `
        -ProjectId $projectIds.WowInterface)
    [void](Invoke-WagoProjectExistenceProbe -ProjectId $projectIds.Wago)

    $wowInterfaceJson = Read-JsonTextOrFetch `
        -Path $WowInterfaceVersionsJsonPath `
        -Uri "https://api.wowinterface.com/addons/compatible.json" `
        -Description "WoWInterface compatibility versions"
    Assert-WowInterfaceVersions -JsonText $wowInterfaceJson -RequiredVersions $requiredVersions

    $wagoJson = Read-JsonTextOrFetch `
        -Path $WagoVersionsJsonPath `
        -Uri "https://addons.wago.io/api/data/game" `
        -Description "Wago game versions"
    Assert-WagoVersions -JsonText $wagoJson -RequiredVersions $requiredVersions

    Write-Host "Marketplace preflight passed for Retail $($requiredVersions -join ', '): required keys are present, CurseForge token/project reachability and WoWInterface project access are valid, and Wago project existence is valid."
    Write-Warning "CurseForge does not publish a read-only upload-permission probe, and Wago does not publish a read-only API-key validation endpoint. This gate does not make mutation-shaped requests to either service."
}

function Invoke-SelfTest {
    $versions = Get-RequiredRetailVersionsFromInterfaces -Interfaces @("120007", "120100")
    if (($versions -join ",") -ne "12.0.7,12.1.0") {
        throw "Expected TOC interface conversion to 12.0.7,12.1.0; got $($versions -join ',')"
    }

    $validCredentials = @{
        CF_API_KEY = "cf-self-test-secret"
        WAGO_API_TOKEN = "wago-self-test-secret"
        WOWI_API_TOKEN = "wowi-self-test-secret"
    }
    $resolvedCredentials = Get-RequiredMarketplaceCredentials -EnvironmentValues $validCredentials
    if ($resolvedCredentials.Count -ne 3) {
        throw "Marketplace credential set should contain exactly three values."
    }
    foreach ($missingName in @("CF_API_KEY", "WAGO_API_TOKEN", "WOWI_API_TOKEN")) {
        foreach ($missingValue in @($null, "", "   ")) {
            $case = $validCredentials.Clone()
            $case[$missingName] = $missingValue
            Assert-ThrowsMatch "$missingName missing value rejected" {
                [void](Get-RequiredMarketplaceCredentials -EnvironmentValues $case)
            } $missingName
        }
    }
    Assert-ThrowsMatch "multiple missing credentials fail closed" {
        [void](Get-RequiredMarketplaceCredentials -EnvironmentValues @{
            CF_API_KEY = " "
            WAGO_API_TOKEN = ""
            WOWI_API_TOKEN = "wowi-self-test-secret"
        })
    } "CF_API_KEY"
    Assert-ThrowsMatch "credential control character rejected" {
        [void](Get-RequiredMarketplaceCredentials -EnvironmentValues @{
            CF_API_KEY = "cf`nsecret"
            WAGO_API_TOKEN = "wago-self-test-secret"
            WOWI_API_TOKEN = "wowi-self-test-secret"
        })
    } "CF_API_KEY.*control"
    Assert-ThrowsMatch "credential surrounding whitespace rejected" {
        [void](Get-RequiredMarketplaceCredentials -EnvironmentValues @{
            CF_API_KEY = "cf-self-test-secret"
            WAGO_API_TOKEN = " wago-self-test-secret "
            WOWI_API_TOKEN = "wowi-self-test-secret"
        })
    } "WAGO_API_TOKEN.*whitespace"

    $tocFixture = @'
## Interface: 120007, 120100
## X-Curse-Project-ID: 1525100
## X-Wago-ID: EGPemEN1
## X-WoWI-ID: 27130
'@
    $tempToc = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $tempToc -Value $tocFixture -Encoding UTF8
        $projectIds = Get-MarketplaceProjectIds -Path $tempToc
        if ($projectIds.CurseForge -ne "1525100" -or $projectIds.Wago -ne "EGPemEN1" -or $projectIds.WowInterface -ne "27130") {
            throw "Marketplace project ID mapping mismatch."
        }
    }
    finally {
        Remove-Item -LiteralPath $tempToc -Force -ErrorAction SilentlyContinue
    }
    Assert-ThrowsMatch "duplicate marketplace ID rejected" {
        [void](Get-RequiredTocMetadataValue `
            -TocText ($tocFixture + "`n## X-Wago-ID: EGPemEN1") `
            -Key "X-Wago-ID" `
            -ExpectedValue "EGPemEN1" `
            -ValuePattern '^[A-Za-z0-9]{8}$')
    } "exactly one X-Wago-ID"
    Assert-ThrowsMatch "wrong marketplace ID rejected" {
        [void](Get-RequiredTocMetadataValue `
            -TocText "## X-WoWI-ID: 99999" `
            -Key "X-WoWI-ID" `
            -ExpectedValue "27130" `
            -ValuePattern '^\d+$')
    } "configured StatsPro project '27130'"
    Assert-ThrowsMatch "malformed marketplace ID rejected" {
        [void](Get-RequiredTocMetadataValue `
            -TocText "## X-Curse-Project-ID: not-a-number" `
            -Key "X-Curse-Project-ID" `
            -ExpectedValue "1525100" `
            -ValuePattern '^\d+$')
    } "invalid format"

    $cfValid = @'
[
  {"id": 1007, "gameVersionTypeID": 517, "name": "12.0.7"},
  {"id": 120100, "gameVersionTypeID": 517, "name": "12.1.0"},
  {"id": 1, "gameVersionTypeID": 732, "name": "12.0.7"}
]
'@
    $wowiExactValid = @'
[
  {"game": "Retail", "id": "12.0.7"},
  {"game": "Retail", "id": "12.1.0"},
  {"game": "Classic", "id": "1.15.7"}
]
'@
    $wowiAggregateValid = @'
[
  {"game": "Retail", "id": "12.0.0"},
  {"game": "Classic", "id": "1.15.7"}
]
'@
    $wagoExactValid = @'
{"patches":{"retail":["12.1.0","12.0.7"],"classic":["1.15.8"]}}
'@
    $wagoAggregateValid = @'
{"patches":{"retail":["12.0.0"],"classic":["1.15.8"]}}
'@
    $wagoRequestedVersionFallbackValid = @'
{"patches":{"retail":["12.0.7","12.0.0"],"classic":["1.15.8"]}}
'@

    $cfProbeState = @{ Attempts = 0; Header = $null; Uri = $null }
    $cfProbe = Invoke-CurseForgeCredentialProbe `
        -ApiKey $validCredentials.CF_API_KEY `
        -Request {
            param([string]$RequestUri, [hashtable]$RequestHeaders, [int]$RequestTimeoutSec)
            $cfProbeState.Attempts++
            $cfProbeState.Header = $RequestHeaders["x-api-token"]
            $cfProbeState.Uri = $RequestUri
            return [pscustomobject]@{ Content = $cfValid }
        }
    if ($cfProbeState.Attempts -ne 1 -or $cfProbeState.Header -ne $validCredentials.CF_API_KEY -or
        $cfProbeState.Uri -ne "https://wow.curseforge.com/api/game/wow/versions" -or
        $cfProbeState.Uri.Contains($validCredentials.CF_API_KEY) -or [string]::IsNullOrWhiteSpace([string]$cfProbe.Content)) {
        throw "CurseForge credential probe request binding failed."
    }

    $cfProjectProbeState = @{ Attempts = 0; Header = $null; Uri = $null }
    [void](Invoke-CurseForgeProjectProbe `
        -ApiKey $validCredentials.CF_API_KEY `
        -ProjectId "1525100" `
        -Request {
            param([string]$RequestUri, [hashtable]$RequestHeaders, [int]$RequestTimeoutSec)
            $cfProjectProbeState.Attempts++
            $cfProjectProbeState.Header = $RequestHeaders["x-api-token"]
            $cfProjectProbeState.Uri = $RequestUri
            return [pscustomobject]@{ Content = '[]' }
        })
    if ($cfProjectProbeState.Attempts -ne 1 -or $cfProjectProbeState.Header -ne $validCredentials.CF_API_KEY -or
        $cfProjectProbeState.Uri -ne "https://wow.curseforge.com/api/projects/1525100/files?page=1&pageSize=1" -or
        $cfProjectProbeState.Uri.Contains($validCredentials.CF_API_KEY)) {
        throw "CurseForge project-access probe request binding failed."
    }
    Assert-CurseForgeProjectResponse -JsonText '{"data":[]}'
    Assert-ThrowsMatch "malformed CurseForge project response rejected" {
        Assert-CurseForgeProjectResponse -JsonText '{bad json'
    } "invalid JSON"
    Assert-ThrowsMatch "unexpected CurseForge project schema rejected" {
        Assert-CurseForgeProjectResponse -JsonText '{"project":"1525100"}'
    } "unexpected schema"

    $wowiProbeState = @{ Attempts = 0; Header = $null; Uri = $null }
    [void](Invoke-WowInterfaceCredentialProbe `
        -ApiToken $validCredentials.WOWI_API_TOKEN `
        -ProjectId "27130" `
        -Request {
            param([string]$RequestUri, [hashtable]$RequestHeaders, [int]$RequestTimeoutSec)
            $wowiProbeState.Attempts++
            $wowiProbeState.Header = $RequestHeaders["x-api-token"]
            $wowiProbeState.Uri = $RequestUri
            return [pscustomobject]@{ Content = '[{"id":"27130","title":"StatsPro"}]' }
        })
    if ($wowiProbeState.Attempts -ne 1 -or $wowiProbeState.Header -ne $validCredentials.WOWI_API_TOKEN -or
        $wowiProbeState.Uri -ne "https://api.wowinterface.com/addons/list.json" -or
        $wowiProbeState.Uri.Contains($validCredentials.WOWI_API_TOKEN)) {
        throw "WoWInterface credential probe request binding failed."
    }
    Assert-WowInterfaceProjectList -JsonText '[{"id":27130}]' -ExpectedProjectId "27130"
    Assert-ThrowsMatch "missing WoWInterface project access rejected" {
        Assert-WowInterfaceProjectList -JsonText '[{"id":"12345"}]' -ExpectedProjectId "27130"
    } "found 0"
    Assert-ThrowsMatch "duplicate WoWInterface project access rejected" {
        Assert-WowInterfaceProjectList -JsonText '[{"id":"27130"},{"id":27130}]' -ExpectedProjectId "27130"
    } "found 2"
    Assert-ThrowsMatch "malformed WoWInterface access response rejected" {
        Assert-WowInterfaceProjectList -JsonText '{bad json' -ExpectedProjectId "27130"
    } "invalid JSON"

    $wagoProbeState = @{ Attempts = 0; HeaderCount = -1; Uri = $null }
    [void](Invoke-WagoProjectExistenceProbe `
        -ProjectId "EGPemEN1" `
        -Request {
            param([string]$RequestUri, [hashtable]$RequestHeaders, [int]$RequestTimeoutSec)
            $wagoProbeState.Attempts++
            $wagoProbeState.HeaderCount = $RequestHeaders.Count
            $wagoProbeState.Uri = $RequestUri
            return [pscustomobject]@{ Content = '<meta property="og:url" content="https://addons.wago.io/addons/EGPemEN1" />' }
        })
    if ($wagoProbeState.Attempts -ne 1 -or $wagoProbeState.HeaderCount -ne 0 -or
        $wagoProbeState.Uri -ne "https://addons.wago.io/addons/EGPemEN1" -or
        $wagoProbeState.Uri.Contains($validCredentials.WAGO_API_TOKEN)) {
        throw "Wago non-mutating project-existence probe request binding failed."
    }
    Assert-ThrowsMatch "wrong Wago project page rejected" {
        Assert-WagoProjectPage `
            -Html '<meta property="og:url" content="https://addons.wago.io/addons/notstats" />' `
            -ExpectedProjectId "EGPemEN1"
    } "does not identify"
    Assert-CurseForgeVersions -JsonText $cfValid -RequiredVersions $versions
    Assert-WowInterfaceVersions -JsonText $wowiExactValid -RequiredVersions $versions
    Assert-WowInterfaceVersions -JsonText $wowiAggregateValid -RequiredVersions $versions
    Assert-WagoVersions -JsonText $wagoExactValid -RequiredVersions $versions
    Assert-WagoVersions -JsonText $wagoAggregateValid -RequiredVersions $versions
    Assert-WagoVersions -JsonText $wagoRequestedVersionFallbackValid -RequiredVersions $versions

    Assert-ThrowsMatch "missing CurseForge version rejected" {
        Assert-CurseForgeVersions -JsonText '[{"id":1,"gameVersionTypeID":517,"name":"12.0.7"}]' -RequiredVersions $versions
    } "12\.1\.0"
    Assert-ThrowsMatch "duplicate CurseForge version rejected" {
        Assert-CurseForgeVersions -JsonText '[{"id":1,"gameVersionTypeID":517,"name":"12.0.7"},{"id":2,"gameVersionTypeID":517,"name":"12.0.7"},{"id":3,"gameVersionTypeID":517,"name":"12.1.0"}]' -RequiredVersions $versions
    } "12\.0\.7"
    Assert-ThrowsMatch "WoWInterface missing exact and aggregate rejected" {
        Assert-WowInterfaceVersions -JsonText '[{"game":"Retail","id":"11.0.0"}]' -RequiredVersions $versions
    } "12\.0\.7"
    Assert-ThrowsMatch "duplicate WoWInterface aggregate rejected" {
        Assert-WowInterfaceVersions -JsonText '[{"game":"Retail","id":"12.0.0"},{"game":"Retail","id":"12.0.0"}]' -RequiredVersions $versions
    } "12\.0\.0"
    Assert-ThrowsMatch "missing Wago version and aggregate rejected" {
        Assert-WagoVersions -JsonText '{"patches":{"retail":["12.0.7"]}}' -RequiredVersions $versions
    } "12\.1\.0"
    Assert-ThrowsMatch "ignored Wago Retail versions rejected" {
        Assert-WagoVersions -JsonText '{"patches":{"retail":[]}}' -RequiredVersions $versions
    } "ignore Retail"
    Assert-ThrowsMatch "duplicate Wago version rejected" {
        Assert-WagoVersions -JsonText '{"patches":{"retail":["12.0.7","12.0.7","12.1.0"]}}' -RequiredVersions $versions
    } "duplicate version '12\.0\.7'"
    Assert-ThrowsMatch "unexpected Wago Packager fallback rejected" {
        Assert-WagoVersions -JsonText '{"patches":{"retail":["12.0.9","12.0.7","12.0.0"]}}' -RequiredVersions $versions
    } "unexpected fallback '12\.0\.9'"
    Assert-ThrowsMatch "bad interface rejected" {
        [void](Get-RequiredRetailVersionsFromInterfaces -Interfaces @("12005"))
    } "12005"

    $retryState = @{ Attempts = 0; Delays = @(); Timeouts = @(); SawTokenHeader = $false }
    $retryResponse = Invoke-MarketplaceWebRequest `
        -Uri "https://example.invalid/retry" `
        -Headers @{ "x-api-token" = "secret-value" } `
        -Description "retry self-test" `
        -TimeoutSec 17 `
        -MaxAttempts 3 `
        -InitialDelaySeconds 1 `
        -MaxDelaySeconds 5 `
        -Request {
            param([string]$RequestUri, [hashtable]$RequestHeaders, [int]$RequestTimeoutSec)
            $retryState.Attempts = [int]$retryState.Attempts + 1
            $retryState.Timeouts += $RequestTimeoutSec
            if ($RequestHeaders["x-api-token"] -eq "secret-value") {
                $retryState.SawTokenHeader = $true
            }
            if ($RequestUri -ne "https://example.invalid/retry") {
                throw "retry request URI binding failed"
            }
            if ($retryState.Attempts -lt 3) {
                $ex = [System.Exception]::new("transient marketplace self-test")
                $ex.Data["MarketplaceStatusCode"] = 503
                throw $ex
            }
            return [pscustomobject]@{ Content = "ok" }
        } `
        -Sleep {
            param([int]$Seconds)
            $retryState.Delays += $Seconds
        }
    if ($retryResponse.Content -ne "ok") {
        throw "Marketplace retry response content mismatch."
    }
    if ($retryState.Attempts -ne 3) {
        throw "Marketplace retry should use 3 attempts, got $($retryState.Attempts)."
    }
    if (($retryState.Delays -join ",") -ne "1,2") {
        throw "Marketplace retry delays should be 1,2; got $($retryState.Delays -join ',')."
    }
    if (($retryState.Timeouts | Sort-Object -Unique) -join "," -ne "17") {
        throw "Marketplace retry should pass the configured timeout to every request."
    }
    if (-not $retryState.SawTokenHeader) {
        throw "Marketplace retry should pass request headers to the transport."
    }

    $authState = @{ Attempts = 0; Delays = @() }
    Assert-ThrowsMatch "auth failure is not retried" {
        [void](Invoke-MarketplaceWebRequest `
            -Uri "https://example.invalid/auth" `
            -Headers @{ "x-api-token" = "secret-value" } `
            -Description "auth self-test" `
            -MaxAttempts 3 `
            -InitialDelaySeconds 1 `
            -Request {
                param([string]$RequestUri, [hashtable]$RequestHeaders, [int]$RequestTimeoutSec)
                $authState.Attempts = [int]$authState.Attempts + 1
                $ex = [System.Exception]::new("forbidden marketplace self-test")
                $ex.Data["MarketplaceStatusCode"] = 403
                throw $ex
            } `
            -Sleep {
                param([int]$Seconds)
                $authState.Delays += $Seconds
            })
    } "auth/permission.*HTTP 403"
    if ($authState.Attempts -ne 1) {
        throw "Marketplace auth failure should not retry, got $($authState.Attempts) attempt(s)."
    }
    if ($authState.Delays.Count -ne 0) {
        throw "Marketplace auth failure should not sleep before failing."
    }

    $exhaustionState = @{ Attempts = 0; Delays = @() }
    Assert-ThrowsMatch "retry exhaustion reports attempts" {
        [void](Invoke-MarketplaceWebRequest `
            -Uri "https://example.invalid/exhaustion" `
            -Description "exhaustion self-test" `
            -MaxAttempts 3 `
            -InitialDelaySeconds 1 `
            -MaxDelaySeconds 5 `
            -Request {
                param([string]$RequestUri, [hashtable]$RequestHeaders, [int]$RequestTimeoutSec)
                $exhaustionState.Attempts = [int]$exhaustionState.Attempts + 1
                $ex = [System.Exception]::new("still unavailable marketplace self-test")
                $ex.Data["MarketplaceStatusCode"] = 503
                throw $ex
            } `
            -Sleep {
                param([int]$Seconds)
                $exhaustionState.Delays += $Seconds
            })
    } "after 3 attempt\(s\).*HTTP 503"
    if ($exhaustionState.Attempts -ne 3) {
        throw "Marketplace retry exhaustion should use 3 attempts, got $($exhaustionState.Attempts)."
    }
    if (($exhaustionState.Delays -join ",") -ne "1,2") {
        throw "Marketplace retry exhaustion delays should be 1,2; got $($exhaustionState.Delays -join ',')."
    }

    $terminalState = @{ Attempts = 0 }
    $terminalSecret = "T2-76-TERMINAL-SECRET-CANARY"
    $terminalMessage = $null
    try {
        [void](Invoke-MarketplaceWebRequest `
            -Uri "https://example.invalid/terminal" `
            -Headers @{ "x-api-token" = $terminalSecret } `
            -Description "terminal self-test" `
            -MaxAttempts 3 `
            -Request {
                param([string]$RequestUri, [hashtable]$RequestHeaders, [int]$RequestTimeoutSec)
                $terminalState.Attempts++
                $ex = [System.Exception]::new("API token is malformed. Token provided: $terminalSecret")
                $ex.Data["MarketplaceStatusCode"] = 400
                throw $ex
            })
    }
    catch {
        $terminalMessage = $_.Exception.Message
    }
    if ($terminalState.Attempts -ne 1 -or [string]::IsNullOrWhiteSpace($terminalMessage) -or
        $terminalMessage -notmatch "HTTP 400" -or $terminalMessage.Contains($terminalSecret)) {
        throw "Terminal marketplace failures must fail once with a redacted status-only diagnostic."
    }

    $retrySecret = "T2-76-RETRY-SECRET-CANARY"
    $redactionOutput = & {
        try {
            [void](Invoke-MarketplaceWebRequest `
                -Uri "https://example.invalid/redaction" `
                -Headers @{ "Authorization" = "Bearer $retrySecret" } `
                -Description "redaction self-test" `
                -MaxAttempts 2 `
                -InitialDelaySeconds 0 `
                -Request {
                    param([string]$RequestUri, [hashtable]$RequestHeaders, [int]$RequestTimeoutSec)
                    $ex = [System.Exception]::new("reflected credential $retrySecret")
                    $ex.Data["MarketplaceStatusCode"] = 503
                    throw $ex
                } `
                -Sleep { param([int]$Seconds) })
        }
        catch {
            $_.Exception.Message
        }
    } 3>&1 | Out-String
    if ($redactionOutput.Contains($retrySecret) -or $redactionOutput -notmatch "HTTP 503") {
        throw "Marketplace retry diagnostics must redact reflected credential values."
    }
    Write-Host "Marketplace version self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

Assert-MarketplaceVersions `
    -TocPath $TocPath `
    -CurseForgeVersionsJsonPath $CurseForgeVersionsJsonPath `
    -WowInterfaceVersionsJsonPath $WowInterfaceVersionsJsonPath `
    -WagoVersionsJsonPath $WagoVersionsJsonPath
