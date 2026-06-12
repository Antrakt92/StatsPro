param(
    [string]$TocPath = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")) "StatsPro.toc"),
    [string]$CurseForgeVersionsJsonPath,
    [string]$WowInterfaceVersionsJsonPath,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

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

    $message = if ($Exception -and $Exception.Message) { $Exception.Message } else { "unknown error" }
    $statusCode = Get-MarketplaceHttpStatusCode $Exception
    if ($null -ne $statusCode) {
        return "HTTP $statusCode ($message)"
    }
    return $message
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
            Invoke-WebRequest -Uri $RequestUri -Headers $RequestHeaders -UseBasicParsing -TimeoutSec $RequestTimeoutSec
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

function Assert-WowInterfaceVersions {
    param(
        [string]$JsonText,
        [string[]]$RequiredVersions
    )

    $items = @(ConvertFrom-JsonCompat $JsonText)
    foreach ($version in $RequiredVersions) {
        $matches = @($items | Where-Object {
            [string]$_.game -eq "Retail" -and [string]$_.id -eq $version
        })
        if ($matches.Count -ne 1) {
            throw "WoWInterface must expose exactly one Retail compatibility version '$version'; found $($matches.Count)."
        }
    }
}

function Assert-MarketplaceVersions {
    param(
        [string]$TocPath,
        [string]$CurseForgeVersionsJsonPath,
        [string]$WowInterfaceVersionsJsonPath
    )

    $interfaces = @(Get-TocInterfaceValues -Path $TocPath)
    $requiredVersions = @(Get-RequiredRetailVersionsFromInterfaces -Interfaces $interfaces)

    $cfApiKey = $env:CF_API_KEY
    $cfHeaders = @{}
    if ([string]::IsNullOrWhiteSpace($CurseForgeVersionsJsonPath)) {
        if ([string]::IsNullOrWhiteSpace($cfApiKey)) {
            throw "CF_API_KEY is required when -CurseForgeVersionsJsonPath is not provided."
        }
        $cfHeaders["x-api-token"] = $cfApiKey
    }

    $curseForgeJson = Read-JsonTextOrFetch `
        -Path $CurseForgeVersionsJsonPath `
        -Uri "https://wow.curseforge.com/api/game/wow/versions" `
        -Headers $cfHeaders `
        -Description "CurseForge game versions"
    Assert-CurseForgeVersions -JsonText $curseForgeJson -RequiredVersions $requiredVersions

    $wowInterfaceJson = Read-JsonTextOrFetch `
        -Path $WowInterfaceVersionsJsonPath `
        -Uri "https://api.wowinterface.com/addons/compatible.json" `
        -Description "WoWInterface compatibility versions"
    Assert-WowInterfaceVersions -JsonText $wowInterfaceJson -RequiredVersions $requiredVersions

    Write-Host "Marketplace version gate passed for Retail $($requiredVersions -join ', ')."
}

function Invoke-SelfTest {
    $versions = Get-RequiredRetailVersionsFromInterfaces -Interfaces @("120005", "120007")
    if (($versions -join ",") -ne "12.0.5,12.0.7") {
        throw "Expected TOC interface conversion to 12.0.5,12.0.7; got $($versions -join ',')"
    }

    $cfValid = @'
[
  {"id": 1005, "gameVersionTypeID": 517, "name": "12.0.5"},
  {"id": 1007, "gameVersionTypeID": 517, "name": "12.0.7"},
  {"id": 1, "gameVersionTypeID": 732, "name": "12.0.7"}
]
'@
    $wowiValid = @'
[
  {"game": "Retail", "id": "12.0.5"},
  {"game": "Retail", "id": "12.0.7"},
  {"game": "Classic", "id": "1.15.7"}
]
'@
    Assert-CurseForgeVersions -JsonText $cfValid -RequiredVersions $versions
    Assert-WowInterfaceVersions -JsonText $wowiValid -RequiredVersions $versions

    Assert-ThrowsMatch "missing CurseForge version rejected" {
        Assert-CurseForgeVersions -JsonText '[{"id":1,"gameVersionTypeID":517,"name":"12.0.5"}]' -RequiredVersions $versions
    } "12\.0\.7"
    Assert-ThrowsMatch "duplicate CurseForge version rejected" {
        Assert-CurseForgeVersions -JsonText '[{"id":1,"gameVersionTypeID":517,"name":"12.0.5"},{"id":2,"gameVersionTypeID":517,"name":"12.0.5"},{"id":3,"gameVersionTypeID":517,"name":"12.0.7"}]' -RequiredVersions $versions
    } "12\.0\.5"
    Assert-ThrowsMatch "WoWInterface fallback rejected" {
        Assert-WowInterfaceVersions -JsonText '[{"game":"Retail","id":"12.0.0"}]' -RequiredVersions $versions
    } "12\.0\.5"
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
    Write-Host "Marketplace version self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

Assert-MarketplaceVersions `
    -TocPath $TocPath `
    -CurseForgeVersionsJsonPath $CurseForgeVersionsJsonPath `
    -WowInterfaceVersionsJsonPath $WowInterfaceVersionsJsonPath
