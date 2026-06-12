param(
    [string]$Version = $env:STATSPRO_VERSION,
    [string]$ProjectId = $(if ($env:STATSPRO_CF_PROJECT_ID) { $env:STATSPRO_CF_PROJECT_ID } else { "1525100" }),
    [string]$ApiKey = $env:CF_API_KEY,
    [int]$TimeoutSec = 30,
    [int]$MaxAttempts = 3,
    [int]$RetryDelaySeconds = 5,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

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

function ConvertFrom-JsonCompat {
    param([string]$Json)

    $command = Get-Command ConvertFrom-Json
    if ($command.Parameters.ContainsKey("Depth")) {
        return ($Json | ConvertFrom-Json -Depth 100)
    }
    return ($Json | ConvertFrom-Json)
}

function ConvertTo-JsonCompat {
    param($InputObject)

    $command = Get-Command ConvertTo-Json
    if ($command.Parameters.ContainsKey("Depth")) {
        return (ConvertTo-Json -InputObject $InputObject -Depth 20)
    }
    return (ConvertTo-Json -InputObject $InputObject)
}

function Get-CurseForgeHttpStatusCode {
    param($Exception)

    if ($null -eq $Exception) { return $null }
    try {
        if ($Exception.Data -and $Exception.Data.Contains("CurseForgeStatusCode")) {
            return [int]$Exception.Data["CurseForgeStatusCode"]
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

function Get-CurseForgeFailureBody {
    param($Exception)

    if ($null -eq $Exception) { return "" }
    try {
        if ($Exception.Data -and $Exception.Data.Contains("CurseForgeBody")) {
            return [string]$Exception.Data["CurseForgeBody"]
        }
    }
    catch {
    }
    return ""
}

function Format-CurseForgeRequestFailure {
    param($Exception)

    $message = if ($Exception -and $Exception.Message) { $Exception.Message } else { "unknown error" }
    $statusCode = Get-CurseForgeHttpStatusCode $Exception
    $prefix = if ($null -ne $statusCode) { "HTTP $statusCode ($message)" } else { $message }
    $body = Get-CurseForgeFailureBody $Exception
    if (-not [string]::IsNullOrWhiteSpace($body)) {
        $snippet = if ($body.Length -gt 2000) { $body.Substring(0, 2000) } else { $body }
        return "$prefix Body: $snippet"
    }
    return $prefix
}

function Test-CurseForgeAuthFailure {
    param($Exception)

    try {
        if ($Exception.Data -and $Exception.Data.Contains("CurseForgeAuthFailure")) {
            return [bool]$Exception.Data["CurseForgeAuthFailure"]
        }
    }
    catch {
    }
    $statusCode = Get-CurseForgeHttpStatusCode $Exception
    return $null -ne $statusCode -and @(401, 403) -contains [int]$statusCode
}

function Test-CurseForgeRetryableFailure {
    param($Exception)

    $statusCode = Get-CurseForgeHttpStatusCode $Exception
    if ($null -eq $statusCode) { return $true }
    return @(408, 429, 500, 502, 503, 504) -contains [int]$statusCode
}

function Get-CurseForgeDiagnosticEndpoints {
    param([string]$ProjectId)

    $apiBase = "https://wow.curseforge.com/api/projects/$ProjectId"
    return @(
        "$apiBase/files",
        "$apiBase/files?sort=-id",
        "$apiBase/files?page=1&pageSize=20"
    )
}

function Get-CurseForgeFileItems {
    param([string]$JsonText)

    try {
        $parsed = ConvertFrom-JsonCompat $JsonText
    }
    catch {
        throw "CurseForge response contained invalid JSON: $($_.Exception.Message)"
    }

    if ($parsed -is [System.Array]) {
        return @($parsed)
    }

    $propertyNames = @($parsed.PSObject.Properties | ForEach-Object { $_.Name })
    if ($propertyNames -contains "data" -and $parsed.data -is [System.Array]) {
        return @($parsed.data)
    }
    if ($propertyNames -contains "files" -and $parsed.files -is [System.Array]) {
        return @($parsed.files)
    }
    foreach ($fileNameProperty in @("displayName", "fileName", "name")) {
        if ($propertyNames -contains $fileNameProperty) {
            return @($parsed)
        }
    }
    return @()
}

function Test-CurseForgeFileVersionMatch {
    param(
        [object]$File,
        [string]$Version
    )

    foreach ($property in @("displayName", "fileName", "name")) {
        $value = $File.$property
        if ($null -ne $value -and ([string]$value).IndexOf($Version, [System.StringComparison]::Ordinal) -ge 0) {
            return $true
        }
    }
    return $false
}

function Get-CurseForgeFileSummary {
    param(
        [object[]]$Files,
        [int]$Limit = 25
    )

    return @($Files | Select-Object -First $Limit | ForEach-Object {
        [pscustomobject]@{
            id = $_.id
            displayName = $_.displayName
            fileName = $_.fileName
            name = $_.name
            releaseType = $_.releaseType
            status = $_.status
            fileStatus = $_.fileStatus
            gameVersions = $_.gameVersions
            dateCreated = $_.dateCreated
            dateModified = $_.dateModified
            downloadUrl = $_.downloadUrl
        }
    })
}

function Write-CurseForgeFileSummary {
    param([object[]]$Files)

    $summary = @(Get-CurseForgeFileSummary -Files $Files)
    Write-Host (ConvertTo-JsonCompat -InputObject $summary)
}

function Invoke-CurseForgeEndpointRequest {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [int]$TimeoutSec,
        [int]$MaxAttempts,
        [int]$RetryDelaySeconds,
        [scriptblock]$Request,
        [scriptblock]$Sleep
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return (& $Request $Uri $Headers $TimeoutSec)
        }
        catch {
            $failure = Format-CurseForgeRequestFailure $_.Exception
            if (Test-CurseForgeAuthFailure $_.Exception) {
                $authException = [System.Exception]::new("CurseForge auth/permission failed for $Uri`: $failure")
                $authException.Data["CurseForgeAuthFailure"] = $true
                throw $authException
            }
            if (-not (Test-CurseForgeRetryableFailure $_.Exception)) {
                throw ("CurseForge endpoint request failed for {0}: {1}" -f $Uri, $failure)
            }
            if ($attempt -ge $MaxAttempts) {
                throw ("CurseForge endpoint request failed for {0} after {1} attempt(s): {2}" -f $Uri, $MaxAttempts, $failure)
            }

            Write-Warning ("CurseForge request attempt {0}/{1} failed: {2}. Retrying in {3} second(s). URL: {4}" -f $attempt, $MaxAttempts, $failure, $RetryDelaySeconds, $Uri)
            if ($RetryDelaySeconds -gt 0) {
                & $Sleep $RetryDelaySeconds
            }
        }
    }
}

function Invoke-CurseForgeDiagnostics {
    param(
        [string]$Version,
        [string]$ProjectId,
        [string]$ApiKey,
        [int]$TimeoutSec = 30,
        [int]$MaxAttempts = 3,
        [int]$RetryDelaySeconds = 5,
        [scriptblock]$Request = $null,
        [scriptblock]$Sleep = $null
    )

    if ([string]::IsNullOrWhiteSpace($Version)) { throw "Missing version label. Pass -Version vX.Y.Z or set STATSPRO_VERSION." }
    if ([string]::IsNullOrWhiteSpace($ProjectId)) { throw "Missing CurseForge project id." }
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw "CF_API_KEY secret is not set." }
    if ($TimeoutSec -le 0) { throw "TimeoutSec must be positive." }
    if ($MaxAttempts -lt 1) { throw "MaxAttempts must be at least 1." }
    if ($RetryDelaySeconds -lt 0) { throw "RetryDelaySeconds must be non-negative." }

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

    $headers = @{ "x-api-token" = $ApiKey }
    $successfulListings = 0
    $endpointFailures = @()

    foreach ($endpoint in Get-CurseForgeDiagnosticEndpoints -ProjectId $ProjectId) {
        Write-Host "== GET $endpoint =="
        try {
            $response = Invoke-CurseForgeEndpointRequest `
                -Uri $endpoint `
                -Headers $headers `
                -TimeoutSec $TimeoutSec `
                -MaxAttempts $MaxAttempts `
                -RetryDelaySeconds $RetryDelaySeconds `
                -Request $Request `
                -Sleep $Sleep
        }
        catch {
            if (Test-CurseForgeAuthFailure $_.Exception) {
                throw
            }
            $endpointFailures += $_.Exception.Message
            Write-Host $_.Exception.Message
            continue
        }

        $statusCode = if ($response.PSObject.Properties.Name -contains "StatusCode") { [int]$response.StatusCode } else { 200 }
        Write-Host "HTTP $statusCode"
        if ($statusCode -lt 200 -or $statusCode -gt 299) {
            if (@(401, 403) -contains $statusCode) {
                throw "CurseForge auth/permission failed for $endpoint`: HTTP $statusCode"
            }
            $message = "CurseForge endpoint returned HTTP $statusCode for $endpoint"
            $endpointFailures += $message
            Write-Host $message
            continue
        }

        $files = @(Get-CurseForgeFileItems -JsonText ([string]$response.Content))
        $successfulListings += 1
        Write-Host "Parsed $($files.Count) file listing item(s)."
        Write-CurseForgeFileSummary -Files $files
        foreach ($file in $files) {
            if (Test-CurseForgeFileVersionMatch -File $file -Version $Version) {
                Write-Host "$Version found in CurseForge file listings."
                return
            }
        }
    }

    if ($successfulListings -gt 0) {
        throw "$Version was not found in CurseForge project $ProjectId file listings."
    }
    $details = if ($endpointFailures.Count -gt 0) { " Details: $($endpointFailures -join ' | ')" } else { "" }
    throw "Could not read CurseForge project $ProjectId file listings.$details"
}

function Invoke-SelfTest {
    $blankTokenState = @{ Attempts = 0 }
    Assert-ThrowsMatch "blank token rejected before request" {
        Invoke-CurseForgeDiagnostics `
            -Version "v1.2.3" `
            -ProjectId "1525100" `
            -ApiKey " " `
            -Request {
                $blankTokenState.Attempts = [int]$blankTokenState.Attempts + 1
                return [pscustomobject]@{ StatusCode = 200; Content = "[]" }
            }
    } "CF_API_KEY"
    if ($blankTokenState.Attempts -ne 0) {
        throw "Blank CF_API_KEY should fail before any request."
    }

    $literalState = @{ Attempts = 0; SawTokenHeader = $false }
    Invoke-CurseForgeDiagnostics `
        -Version "v1.2.3[hotfix]" `
        -ProjectId "1525100" `
        -ApiKey "secret-value" `
        -RetryDelaySeconds 0 `
        -Request {
            param([string]$Uri, [hashtable]$Headers, [int]$RequestTimeoutSec)
            $literalState.Attempts = [int]$literalState.Attempts + 1
            if ($Headers["x-api-token"] -eq "secret-value") {
                $literalState.SawTokenHeader = $true
            }
            return [pscustomobject]@{
                StatusCode = 200
                Content = '[{"displayName":"StatsPro-v1.2.3[hotfix].zip"}]'
            }
        }
    if ($literalState.Attempts -ne 1) {
        throw "Literal match should stop after the first successful endpoint."
    }
    if (-not $literalState.SawTokenHeader) {
        throw "Diagnostics request should pass the API token header to transport."
    }

    $dataState = @{ Attempts = 0 }
    Invoke-CurseForgeDiagnostics `
        -Version "v2.0.0" `
        -ProjectId "1525100" `
        -ApiKey "secret-value" `
        -RetryDelaySeconds 0 `
        -Request {
            $dataState.Attempts = [int]$dataState.Attempts + 1
            return [pscustomobject]@{
                StatusCode = 200
                Content = '{"data":[{"fileName":"StatsPro-v2.0.0.zip"}]}'
            }
        }
    if ($dataState.Attempts -ne 1) {
        throw "Data-array match should stop after the first successful endpoint."
    }

    $filesState = @{ Attempts = 0 }
    Invoke-CurseForgeDiagnostics `
        -Version "v3.0.0" `
        -ProjectId "1525100" `
        -ApiKey "secret-value" `
        -RetryDelaySeconds 0 `
        -Request {
            $filesState.Attempts = [int]$filesState.Attempts + 1
            return [pscustomobject]@{
                StatusCode = 200
                Content = '{"files":[{"name":"StatsPro v3.0.0"}]}'
            }
        }
    if ($filesState.Attempts -ne 1) {
        throw "Files-array match should stop after the first successful endpoint."
    }

    $authState = @{ Attempts = 0 }
    Assert-ThrowsMatch "auth failure rejected distinctly" {
        Invoke-CurseForgeDiagnostics `
            -Version "v1.2.3" `
            -ProjectId "1525100" `
            -ApiKey "secret-value" `
            -RetryDelaySeconds 0 `
            -Request {
                $authState.Attempts = [int]$authState.Attempts + 1
                $ex = [System.Exception]::new("forbidden diagnostics self-test")
                $ex.Data["CurseForgeStatusCode"] = 403
                $ex.Data["CurseForgeBody"] = "token forbidden"
                throw $ex
            }
    } "auth/permission.*HTTP 403"
    if ($authState.Attempts -ne 1) {
        throw "Auth failure should not retry, got $($authState.Attempts) attempt(s)."
    }

    $retryState = @{ Attempts = 0 }
    Invoke-CurseForgeDiagnostics `
        -Version "v4.0.0" `
        -ProjectId "1525100" `
        -ApiKey "secret-value" `
        -RetryDelaySeconds 0 `
        -Request {
            $retryState.Attempts = [int]$retryState.Attempts + 1
            if ($retryState.Attempts -eq 1) {
                $ex = [System.Exception]::new("temporary diagnostics self-test")
                $ex.Data["CurseForgeStatusCode"] = 503
                throw $ex
            }
            return [pscustomobject]@{
                StatusCode = 200
                Content = '[{"displayName":"StatsPro-v4.0.0.zip"}]'
            }
        }
    if ($retryState.Attempts -ne 2) {
        throw "Transient failure should retry once before success, got $($retryState.Attempts) attempt(s)."
    }

    $summaryInput = @(1..30 | ForEach-Object {
        [pscustomobject]@{
            id = $_
            displayName = "StatsPro-v$_.zip"
            fileName = "StatsPro-v$_.zip"
            ignoredProperty = "must not leak into diagnostics summary"
        }
    })
    $summary = @(Get-CurseForgeFileSummary -Files $summaryInput -Limit 25)
    if ($summary.Count -ne 25) {
        throw "CurseForge file summary should be bounded to 25 items."
    }
    if ($summary[-1].displayName -ne "StatsPro-v25.zip") {
        throw "CurseForge file summary should preserve file listing order."
    }
    if ($summary[0].PSObject.Properties.Name -contains "ignoredProperty") {
        throw "CurseForge file summary should expose only diagnostic-safe fields."
    }

    $longBodyException = [System.Exception]::new("long body diagnostics self-test")
    $longBodyException.Data["CurseForgeStatusCode"] = 404
    $longBodyException.Data["CurseForgeBody"] = ("x" * 3000)
    $longBodyFailure = Format-CurseForgeRequestFailure $longBodyException
    if ($longBodyFailure -notmatch "HTTP 404" -or $longBodyFailure.Length -gt 2100) {
        throw "Long CurseForge failure bodies should be bounded in diagnostics output."
    }

    $nextEndpointState = @{ Attempts = 0; Uris = @() }
    Invoke-CurseForgeDiagnostics `
        -Version "v5.0.0" `
        -ProjectId "1525100" `
        -ApiKey "secret-value" `
        -RetryDelaySeconds 0 `
        -Request {
            param([string]$Uri, [hashtable]$Headers, [int]$RequestTimeoutSec)
            $nextEndpointState.Attempts = [int]$nextEndpointState.Attempts + 1
            $nextEndpointState.Uris += $Uri
            if ($nextEndpointState.Attempts -eq 1) {
                $ex = [System.Exception]::new("not found diagnostics self-test")
                $ex.Data["CurseForgeStatusCode"] = 404
                $ex.Data["CurseForgeBody"] = "not found"
                throw $ex
            }
            return [pscustomobject]@{
                StatusCode = 200
                Content = '[{"displayName":"StatsPro-v5.0.0.zip"}]'
            }
        }
    if ($nextEndpointState.Attempts -ne 2) {
        throw "Non-auth nonretryable endpoint failure should continue to the next endpoint."
    }
    if (($nextEndpointState.Uris | Select-Object -Unique).Count -ne 2) {
        throw "Endpoint fallback should call two distinct endpoints."
    }

    Assert-ThrowsMatch "successful listing without version rejected as not found" {
        Invoke-CurseForgeDiagnostics `
            -Version "v9.9.9" `
            -ProjectId "1525100" `
            -ApiKey "secret-value" `
            -RetryDelaySeconds 0 `
            -Request {
                return [pscustomobject]@{ StatusCode = 200; Content = '[{"displayName":"StatsPro-v1.0.0.zip"}]' }
            }
    } "was not found"

    Assert-ThrowsMatch "object without file arrays is treated as empty listing" {
        Invoke-CurseForgeDiagnostics `
            -Version "v9.9.9" `
            -ProjectId "1525100" `
            -ApiKey "secret-value" `
            -RetryDelaySeconds 0 `
            -Request {
                return [pscustomobject]@{ StatusCode = 200; Content = '{"pagination":{"totalCount":0}}' }
            }
    } "was not found"

    Assert-ThrowsMatch "malformed JSON rejected" {
        Invoke-CurseForgeDiagnostics `
            -Version "v9.9.9" `
            -ProjectId "1525100" `
            -ApiKey "secret-value" `
            -RetryDelaySeconds 0 `
            -Request {
                return [pscustomobject]@{ StatusCode = 200; Content = '{"data":' }
            }
    } "invalid JSON"

    Write-Host "CurseForge diagnostics self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

Invoke-CurseForgeDiagnostics `
    -Version $Version `
    -ProjectId $ProjectId `
    -ApiKey $ApiKey `
    -TimeoutSec $TimeoutSec `
    -MaxAttempts $MaxAttempts `
    -RetryDelaySeconds $RetryDelaySeconds
