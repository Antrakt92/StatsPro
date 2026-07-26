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
. (Join-Path $PSScriptRoot "release-tag-contract.ps1")

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

    # SYNC: CurseForge's web frontend uses this read-only file-list surface.
    # The legacy author API documents upload/update, not GET file listings.
    $apiBase = "https://www.curseforge.com/api/v1/mods/$ProjectId/files"
    return @(
        "${apiBase}?pageIndex=0&pageSize=50",
        "${apiBase}?pageIndex=0&pageSize=20",
        $apiBase
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

    Assert-StatsProReleaseTag -Value $Version
    $escapedVersion = [regex]::Escape($Version)
    $versionTokenPattern = "(?<![\p{L}\p{M}\p{N}\p{Cs}])$escapedVersion(?![\p{L}\p{M}\p{N}\p{Cs}]|\.[\p{N}\p{Cs}])"
    foreach ($property in @("displayName", "fileName", "name")) {
        $value = $File.$property
        if ($null -ne $value -and [regex]::IsMatch(
                [string]$value,
                $versionTokenPattern,
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
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

function Invoke-CurseForgeWebRequest {
    param(
        [string]$RequestUri,
        [hashtable]$RequestHeaders,
        [int]$RequestTimeoutSec
    )

    Invoke-WebRequest `
        -Uri $RequestUri `
        -Headers $RequestHeaders `
        -UseBasicParsing `
        -TimeoutSec $RequestTimeoutSec `
        -MaximumRedirection 0
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
        [scriptblock]$Sleep = $null,
        [scriptblock]$GetEndpoints = $null
    )

    if ([string]::IsNullOrWhiteSpace($Version)) { throw "Missing version label. Pass -Version vX.Y.Z or set STATSPRO_VERSION." }
    Assert-StatsProReleaseTag -Value $Version
    if ([string]::IsNullOrWhiteSpace($ProjectId)) { throw "Missing CurseForge project id." }
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw "CF_API_KEY secret is not set." }
    if ($TimeoutSec -le 0) { throw "TimeoutSec must be positive." }
    if ($MaxAttempts -lt 1) { throw "MaxAttempts must be at least 1." }
    if ($RetryDelaySeconds -lt 0) { throw "RetryDelaySeconds must be non-negative." }

    if ($null -eq $Request) {
        $Request = ${function:Invoke-CurseForgeWebRequest}
    }
    if ($null -eq $Sleep) {
        $Sleep = {
            param([int]$Seconds)
            Start-Sleep -Seconds $Seconds
        }
    }
    if ($null -eq $GetEndpoints) {
        $GetEndpoints = ${function:Get-CurseForgeDiagnosticEndpoints}
    }

    $headers = @{ "x-api-token" = $ApiKey }
    $successfulListings = 0
    $endpointFailures = @()

    foreach ($endpoint in & $GetEndpoints $ProjectId) {
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

function Invoke-CurseForgeRedirectTransportSelfTest {
    $secretCanary = "T2-105-REDIRECT-SECRET-CANARY"
    $serverJob = Start-Job -ScriptBlock {
        function Read-RequestHeaders {
            param([System.Net.Sockets.TcpClient]$Client)

            $stream = $Client.GetStream()
            $stream.ReadTimeout = 5000
            $reader = [System.IO.StreamReader]::new(
                $stream,
                [System.Text.Encoding]::ASCII,
                $false,
                1024,
                $true)
            $headers = @()
            while (($line = $reader.ReadLine()) -ne "") {
                if ($null -eq $line) { break }
                $headers += $line
            }
            return @($headers)
        }

        function Write-HttpResponse {
            param(
                [System.Net.Sockets.TcpClient]$Client,
                [string]$Status,
                [string[]]$Headers = @(),
                [string]$Body = ""
            )

            $stream = $Client.GetStream()
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $headerLines = @("HTTP/1.1 $Status") + @($Headers) + @(
                "Content-Length: $($bodyBytes.Length)",
                "Connection: close",
                "",
                "")
            $headerBytes = [System.Text.Encoding]::ASCII.GetBytes(($headerLines -join "`r`n"))
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            if ($bodyBytes.Length -gt 0) {
                $stream.Write($bodyBytes, 0, $bodyBytes.Length)
            }
            $stream.Flush()
            $Client.Close()
        }

        $redirectListener = [System.Net.Sockets.TcpListener]::new(
            [System.Net.IPAddress]::Loopback,
            0)
        $targetListener = [System.Net.Sockets.TcpListener]::new(
            [System.Net.IPAddress]::Loopback,
            0)
        try {
            $redirectListener.Start()
            $targetListener.Start()
            $redirectPort = ([System.Net.IPEndPoint]$redirectListener.LocalEndpoint).Port
            $targetPort = ([System.Net.IPEndPoint]$targetListener.LocalEndpoint).Port
            "READY:$redirectPort`:$targetPort"

            $initialClient = $redirectListener.AcceptTcpClient()
            $initialHeaders = @(Read-RequestHeaders -Client $initialClient)
            Write-HttpResponse `
                -Client $initialClient `
                -Status "302 Found" `
                -Headers @("Location: http://127.0.0.1:$targetPort/capture")

            $targetReached = $false
            $targetHeaders = @()
            $deadline = [DateTime]::UtcNow.AddSeconds(2)
            while ([DateTime]::UtcNow -lt $deadline) {
                if ($targetListener.Pending()) {
                    $targetReached = $true
                    $targetClient = $targetListener.AcceptTcpClient()
                    $targetHeaders = @(Read-RequestHeaders -Client $targetClient)
                    Write-HttpResponse -Client $targetClient -Status "200 OK" -Body "OK"
                    break
                }
                Start-Sleep -Milliseconds 20
            }

            [pscustomobject]@{
                Kind = "Result"
                InitialHeaders = @($initialHeaders)
                TargetReached = $targetReached
                TargetHeaders = @($targetHeaders)
            }
        }
        finally {
            $redirectListener.Stop()
            $targetListener.Stop()
        }
    }

    try {
        $readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            $events = @(Receive-Job -Job $serverJob -Keep)
            $readyEvents = @($events | Where-Object { $_ -is [string] -and $_ -match '^READY:\d+:\d+$' })
            if ($readyEvents.Count -eq 1) {
                break
            }
            if ($serverJob.State -eq "Failed") {
                throw "Redirect transport self-test server failed: $($serverJob.ChildJobs[0].JobStateInfo.Reason)"
            }
            Start-Sleep -Milliseconds 25
        } while ([DateTime]::UtcNow -lt $readyDeadline)
        if ($readyEvents.Count -ne 1) {
            throw "Redirect transport self-test server did not become ready."
        }
        $readyMatch = [regex]::Match($readyEvents[0], '^READY:(\d+):(\d+)$')
        $redirectPort = [int]$readyMatch.Groups[1].Value

        $endpointProvider = {
            param([string]$ProjectId)
            return @("http://127.0.0.1:$redirectPort/start")
        }.GetNewClosure()
        $redirectRejected = $false
        try {
            Invoke-CurseForgeDiagnostics `
                -Version "v1.2.3" `
                -ProjectId "1525100" `
                -ApiKey $secretCanary `
                -TimeoutSec 5 `
                -MaxAttempts 1 `
                -RetryDelaySeconds 0 `
                -GetEndpoints $endpointProvider
        }
        catch {
            $redirectRejected = $true
            if ($_.Exception.Message -notmatch 'Could not read CurseForge project' -or
                $_.Exception.Message -notmatch '(HTTP 302|maximum redirection|current state of the object)') {
                throw "Redirect transport self-test failed unexpectedly: $($_.Exception.Message)"
            }
        }
        if (-not $redirectRejected) {
            throw "CurseForge diagnostics accepted a redirect response."
        }

        [void](Wait-Job -Job $serverJob -Timeout 10)
        if ($serverJob.State -ne "Completed") {
            throw "Redirect transport self-test server did not complete."
        }
        $events = @(Receive-Job -Job $serverJob -Keep)
        $results = @($events | Where-Object { $_.Kind -eq "Result" })
        if ($results.Count -ne 1) {
            throw "Redirect transport self-test produced $($results.Count) result(s)."
        }

        $initialTokenHeaders = @($results[0].InitialHeaders | Where-Object {
                $_ -ceq "x-api-token: $secretCanary"
            })
        if ($initialTokenHeaders.Count -ne 1) {
            throw "Redirect transport self-test did not observe the token on the allowlisted initial request."
        }
        if ($results[0].TargetReached -or
            @($results[0].TargetHeaders | Where-Object { $_ -match [regex]::Escape($secretCanary) }).Count -gt 0) {
            throw "CurseForge diagnostics forwarded CF_API_KEY to a redirect target."
        }
    }
    finally {
        if ($serverJob.State -notin @("Completed", "Failed", "Stopped")) {
            Stop-Job -Job $serverJob
        }
        Remove-Job -Job $serverJob -Force
    }
}

function Invoke-SelfTest {
    Assert-StatsProReleaseTagContractSelfTest
    Invoke-CurseForgeRedirectTransportSelfTest
    $diagnosticEndpoints = @(Get-CurseForgeDiagnosticEndpoints -ProjectId "1525100")
    if ($diagnosticEndpoints.Count -ne 3 -or @($diagnosticEndpoints | Where-Object {
                $_ -notmatch '^https://www\.curseforge\.com/api/v1/mods/1525100/files(?:\?|$)'
            }).Count -ne 0) {
        throw "CurseForge diagnostics must use only the bounded official web file-list surface."
    }
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

    $malformedVersionState = @{ Attempts = 0 }
    Assert-ThrowsMatch "noncanonical version rejected before request" {
        Invoke-CurseForgeDiagnostics `
            -Version "v01.2.3" `
            -ProjectId "1525100" `
            -ApiKey "secret-value" `
            -Request {
                $malformedVersionState.Attempts = [int]$malformedVersionState.Attempts + 1
                return [pscustomobject]@{ StatusCode = 200; Content = "[]" }
            }
    } "Malformed StatsPro release tag"
    if ($malformedVersionState.Attempts -ne 0) {
        throw "Noncanonical version must fail before any CurseForge request."
    }

    foreach ($positive in @(
            @{ Property = "displayName"; Value = "StatsPro-v1.2.3.zip" },
            @{ Property = "fileName"; Value = "StatsPro_v1.2.3-release.zip" },
            @{ Property = "name"; Value = "StatsPro v1.2.3 [hotfix]" })) {
        $file = [pscustomobject]@{ displayName = $null; fileName = $null; name = $null }
        $file.($positive.Property) = $positive.Value
        if (-not (Test-CurseForgeFileVersionMatch -File $file -Version "v1.2.3")) {
            throw "Canonical version token was not matched in $($positive.Property): $($positive.Value)"
        }
    }
    foreach ($negative in @(
            "StatsPro-v1.2.30.zip",
            "StatsPro-v1.2.3.1.zip",
            "StatsPro-v1.2.3beta.zip",
            "StatsProv1.2.3.zip",
            ("StatsPro-v1.2.3" + [char]0x0664 + ".zip"),
            ("StatsPro-v1.2.3" + [char]0x00B2 + ".zip"),
            ("StatsPro-" + [char]0x2163 + "v1.2.3.zip"),
            ("StatsPro-v1.2.3" + [char]::ConvertFromUtf32(0x11F50) + ".zip"),
            ("StatsPro-" + [char]::ConvertFromUtf32(0x11F50) + "v1.2.3.zip"),
            ("StatsPro-v1.2.3." + [char]::ConvertFromUtf32(0x11F50) + ".zip"),
            "StatsPro-V1.2.3.zip")) {
        foreach ($property in @("displayName", "fileName", "name")) {
            $file = [pscustomobject]@{ displayName = $null; fileName = $null; name = $null }
            $file.$property = $negative
            if (Test-CurseForgeFileVersionMatch -File $file -Version "v1.2.3") {
                throw "Non-token version match was accepted in ${property}: $negative"
            }
        }
    }

    $literalState = @{ Attempts = 0; SawTokenHeader = $false }
    Invoke-CurseForgeDiagnostics `
        -Version "v1.2.3" `
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

    $numericPrefixState = @{ Attempts = 0 }
    Assert-ThrowsMatch "longer numeric-prefix versions rejected as not found" {
        Invoke-CurseForgeDiagnostics `
            -Version "v1.2.3" `
            -ProjectId "1525100" `
            -ApiKey "secret-value" `
            -RetryDelaySeconds 0 `
            -Request {
                $numericPrefixState.Attempts = [int]$numericPrefixState.Attempts + 1
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '[{"displayName":"StatsPro-v1.2.30.zip","fileName":"StatsPro-v1.2.3.1.zip","name":"StatsPro-v1.2.3beta"}]'
                }
            }
    } "was not found"
    if ($numericPrefixState.Attempts -ne 3) {
        throw "Numeric-prefix mismatch should inspect all three listing endpoints, got $($numericPrefixState.Attempts)."
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
