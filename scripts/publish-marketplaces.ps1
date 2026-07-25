param(
    [ValidateSet('Prepare', 'Publish')]
    [string]$Mode,
    [string]$ArchivePath,
    [string]$ExpectedTag,
    [string]$ExpectedSha256,
    [string]$PlanPath,
    [string]$ExpectedPlanSha256,
    [string]$OutputPath,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "release-tag-contract.ps1")

$ExpectedProjectIds = [ordered]@{
    CurseForge = "1525100"
    Wago = "EGPemEN1"
    WowInterface = "27130"
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

    $completed = $false
    try {
        & $Script
        $completed = $true
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Name failed with wrong error: $($_.Exception.Message)"
        }
    }
    if ($completed) {
        throw "$Name should have failed."
    }
}

function Assert-ExactPropertySet {
    param([object]$Value, [string[]]$Expected, [string]$Description)

    if ($null -eq $Value) { throw "$Description is missing." }
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expectedSorted = @($Expected | Sort-Object)
    if ($actual.Count -ne $expectedSorted.Count -or
        (Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actual)) {
        throw "$Description fields are '$($actual -join ', ')'; expected '$($expectedSorted -join ', ')'."
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)

    $parent = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($Path), $Text, [System.Text.UTF8Encoding]::new($false))
}

function Add-OutputValue {
    param([string]$Path, [string]$Name, [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if ($Value -match '[\r\n]') { throw "Output '$Name' contains a newline." }
    [System.IO.File]::AppendAllText(
        [System.IO.Path]::GetFullPath($Path),
        "$Name=$Value`n",
        [System.Text.UTF8Encoding]::new($false))
}

function Resolve-RequiredFile {
    param([string]$Path, [string]$Description)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing $Description file '$Path'."
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-Sha256 {
    param([string]$Value, [string]$Description = 'Expected archive SHA-256')

    if ($Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Description must be 64 lowercase hexadecimal characters."
    }
}

function Get-LowercaseFileSha256 {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-ArchiveIdentity {
    param([string]$Path, [string]$Tag, [string]$Sha256)

    Assert-StatsProReleaseTag -Value $Tag
    Assert-Sha256 $Sha256
    $resolved = Resolve-RequiredFile -Path $Path -Description "marketplace archive"
    $expectedName = "StatsPro-$Tag.zip"
    if (-not [System.StringComparer]::Ordinal.Equals([System.IO.Path]::GetFileName($resolved), $expectedName)) {
        throw "Marketplace archive filename must be '$expectedName'."
    }
    $actualSha = Get-LowercaseFileSha256 -Path $resolved
    if (-not [System.StringComparer]::Ordinal.Equals($actualSha, $Sha256)) {
        throw "Marketplace archive SHA-256 is '$actualSha', expected '$Sha256'."
    }
    return $resolved
}

function Get-ArchiveTextContracts {
    param([string]$Path)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $result = [ordered]@{}
        foreach ($contract in @(
            [pscustomobject]@{ Key = 'Toc'; Name = 'StatsPro/StatsPro.toc' },
            [pscustomobject]@{ Key = 'Changelog'; Name = 'StatsPro/CHANGELOG.md' }
        )) {
            $entries = @($zip.Entries | Where-Object {
                [System.StringComparer]::Ordinal.Equals($_.FullName.Replace('\', '/'), $contract.Name)
            })
            if ($entries.Count -ne 1 -or $entries[0].Length -le 0) {
                throw "Marketplace archive must contain exactly one non-empty '$($contract.Name)' entry."
            }
            $reader = [System.IO.StreamReader]::new($entries[0].Open(), [System.Text.UTF8Encoding]::new($false, $true), $true)
            try { $result[$contract.Key] = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        return $result
    }
    finally {
        $zip.Dispose()
    }
}

function Get-RequiredCredentials {
    param([hashtable]$Values)

    $credentials = [ordered]@{}
    foreach ($name in @('CF_API_KEY', 'WAGO_API_TOKEN', 'WOWI_API_TOKEN')) {
        $value = [string]$Values[$name]
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "$name is required for marketplace publication."
        }
        if (-not [System.StringComparer]::Ordinal.Equals($value, $value.Trim()) -or $value -match '[\x00-\x1F\x7F]') {
            throw "$name has invalid whitespace or control characters."
        }
        $credentials[$name] = $value
    }
    return $credentials
}

function Get-SingleTocValue {
    param([string]$Text, [string]$Key, [string]$Pattern)

    $lineMatches = [regex]::Matches($Text, '^##\s+' + [regex]::Escape($Key) + ':\s*(\S+)\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($lineMatches.Count -ne 1 -or $lineMatches[0].Groups[1].Value -notmatch $Pattern) {
        throw "TOC must contain exactly one valid $Key value."
    }
    return $lineMatches[0].Groups[1].Value
}

function Get-TocUploadContract {
    param([string]$Text, [string]$Tag)

    $version = Get-SingleTocValue -Text $text -Key 'Version' -Pattern '^\d+\.\d+\.\d+$'
    if (-not [System.StringComparer]::Ordinal.Equals("v$version", $Tag)) {
        throw "Packaged TOC version '$version' does not match release tag '$Tag'."
    }
    $ids = [ordered]@{
        CurseForge = Get-SingleTocValue -Text $text -Key 'X-Curse-Project-ID' -Pattern '^\d+$'
        Wago = Get-SingleTocValue -Text $text -Key 'X-Wago-ID' -Pattern '^[A-Za-z0-9]{8}$'
        WowInterface = Get-SingleTocValue -Text $text -Key 'X-WoWI-ID' -Pattern '^\d+$'
    }
    foreach ($name in $ids.Keys) {
        if (-not [System.StringComparer]::Ordinal.Equals($ids[$name], $ExpectedProjectIds[$name])) {
            throw "Packaged TOC $name project ID '$($ids[$name])' is not the configured StatsPro project."
        }
    }
    $interfaceMatches = [regex]::Matches($text, '^##\s+Interface:\s*(.+?)\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($interfaceMatches.Count -ne 1) {
        throw "Packaged TOC must contain exactly one Interface line."
    }
    $interfaces = @($interfaceMatches[0].Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $versions = @()
    foreach ($interface in $interfaces) {
        if ($interface -notmatch '^\d{6}$') {
            throw "Packaged TOC Interface '$interface' is not a six-digit Retail interface."
        }
        $versions += "{0}.{1}.{2}" -f [int]$interface.Substring(0, 2), [int]$interface.Substring(2, 2), [int]$interface.Substring(4, 2)
    }
    return [pscustomobject]@{
        Version = $version
        ProjectIds = $ids
        RetailVersions = @($versions | Sort-Object { [version]$_ } -Unique)
    }
}

function Get-AcceptedCompatibilityVersions {
    param([string]$Version)

    $parsed = [version]$Version
    $accepted = @($Version)
    $minor = "$($parsed.Major).$($parsed.Minor).0"
    if ($accepted -notcontains $minor) { $accepted += $minor }
    if ($parsed.Minor -gt 0 -and $parsed.Build -eq 0) {
        $expansion = "$($parsed.Major).0.0"
        if ($accepted -notcontains $expansion) { $accepted += $expansion }
    }
    return $accepted
}

function Select-OrdinalFallback {
    param([string[]]$Available, [string]$Requested)

    $comparer = [System.StringComparer]::Ordinal
    $exact = @($Available | Where-Object { $comparer.Equals($_, $Requested) })
    if ($exact.Count -eq 1) { return $Requested }
    if ($exact.Count -gt 1) { throw "Marketplace version '$Requested' is duplicated." }
    $bestLower = $null
    $bestAny = $null
    foreach ($candidate in $Available) {
        if ($null -eq $candidate) { continue }
        if ($null -eq $bestAny -or $comparer.Compare($candidate, $bestAny) -gt 0) {
            $bestAny = $candidate
        }
        if ($comparer.Compare($candidate, $Requested) -lt 0 -and
            ($null -eq $bestLower -or $comparer.Compare($candidate, $bestLower) -gt 0)) {
            $bestLower = $candidate
        }
    }
    if ($null -ne $bestLower) { return $bestLower }
    return $bestAny
}

function Get-CurseForgeVersionIds {
    param([string]$Json, [string[]]$RequiredVersions)

    $items = @(ConvertFrom-JsonCompat $Json)
    $ids = @()
    foreach ($version in $RequiredVersions) {
        $matches = @($items | Where-Object { [string]$_.name -eq $version -and [int]$_.gameVersionTypeID -eq 517 })
        if ($matches.Count -ne 1) {
            throw "CurseForge must expose exactly one Retail game version '$version'."
        }
        $id = 0
        if (-not [int]::TryParse([string]$matches[0].id, [ref]$id) -or $id -le 0) {
            throw "CurseForge game version '$version' has an invalid ID."
        }
        $ids += $id
    }
    return $ids
}

function Get-WowInterfaceVersions {
    param([string]$Json, [string[]]$RequiredVersions)

    $items = @(ConvertFrom-JsonCompat $Json)
    $available = @($items | Where-Object { [string]$_.game -eq 'Retail' } | ForEach-Object { [string]$_.id })
    $selected = @()
    foreach ($version in $RequiredVersions) {
        $chosen = Select-OrdinalFallback -Available $available -Requested $version
        $allowed = @(Get-AcceptedCompatibilityVersions -Version $version)
        if ([string]::IsNullOrWhiteSpace($chosen) -or $allowed -notcontains $chosen) {
            throw "WoWInterface would select unsupported fallback '$chosen' for '$version'; allowed: $($allowed -join ', ')."
        }
        if ($selected -notcontains $chosen) { $selected += $chosen }
    }
    return @($selected | Sort-Object { [version]$_ } -Descending)
}

function Get-WagoVersions {
    param([string]$Json, [string[]]$RequiredVersions)

    $data = ConvertFrom-JsonCompat $Json
    $property = if ($null -ne $data -and $null -ne $data.patches) { $data.patches.PSObject.Properties['retail'] } else { $null }
    if ($null -eq $property) {
        throw "Wago game data is missing patches.retail."
    }
    $available = @($property.Value | ForEach-Object { [string]$_ })
    $selected = @()
    foreach ($version in $RequiredVersions) {
        $chosen = Select-OrdinalFallback -Available $available -Requested $version
        $allowed = @(Get-AcceptedCompatibilityVersions -Version $version)
        $requestedParsed = [version]$version
        foreach ($required in $RequiredVersions) {
            $parsed = [version]$required
            if ($parsed.Major -eq $requestedParsed.Major -and $parsed -le $requestedParsed -and $allowed -notcontains $required) {
                $allowed += $required
            }
        }
        if ([string]::IsNullOrWhiteSpace($chosen) -or $allowed -notcontains $chosen) {
            throw "Wago would select unsupported fallback '$chosen' for '$version'; allowed: $($allowed -join ', ')."
        }
        if ($selected -notcontains $chosen) { $selected += $chosen }
    }
    return @($selected | Sort-Object { [version]$_ } -Descending)
}

function Invoke-JsonRead {
    param([string]$Uri, [hashtable]$Headers, [scriptblock]$Request)

    if ($null -ne $Request) {
        return [string](& $Request $Uri $Headers)
    }
    try {
        $response = Invoke-WebRequest -Uri $Uri -Headers $Headers -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 0
        return [string]$response.Content
    }
    catch {
        throw "Marketplace compatibility read failed for $Uri`: $($_.Exception.GetType().Name)."
    }
}

# SYNC: These non-mutating ownership/existence checks mirror the canonical
# preflight in check-marketplace-versions.ps1 and must run before any upload.
function Assert-WowInterfaceProjectList {
    param([string]$Json, [string]$ExpectedProjectId)

    try { $items = @(ConvertFrom-JsonCompat $Json) }
    catch { throw "WoWInterface project-access response contained invalid JSON." }
    $matches = @($items | Where-Object {
        $null -ne $_.id -and
        [System.StringComparer]::Ordinal.Equals([string]$_.id, $ExpectedProjectId)
    })
    if ($matches.Count -ne 1) {
        throw "WoWInterface credential must expose exactly one StatsPro project '$ExpectedProjectId'; found $($matches.Count)."
    }
}

function Assert-WagoProjectPage {
    param([string]$Html, [string]$ExpectedProjectId)

    $expectedCanonical = 'content="https://addons.wago.io/addons/' + [regex]::Escape($ExpectedProjectId) + '"'
    if ([string]::IsNullOrWhiteSpace($Html) -or $Html -notmatch $expectedCanonical) {
        throw "Wago public project page does not identify StatsPro project '$ExpectedProjectId'."
    }
}

function Invoke-ExactUpload {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [hashtable]$Form,
        [int[]]$ExpectedStatus,
        [string]$Description,
        [scriptblock]$Request
    )

    try {
        $response = if ($null -ne $Request) {
            & $Request $Uri $Headers $Form
        }
        else {
            if ($PSVersionTable.PSVersion.Major -lt 7) {
                throw "Marketplace publication requires PowerShell 7 or newer."
            }
            Invoke-WebRequest -Uri $Uri -Method Post -Headers $Headers -Form $Form -TimeoutSec 120 -MaximumRedirection 0 -SkipHttpErrorCheck
        }
    }
    catch {
        throw "$Description outcome is ambiguous; do not retry this tag: $($_.Exception.GetType().Name)."
    }
    $status = [int]$response.StatusCode
    if ($ExpectedStatus -notcontains $status) {
        throw "$Description failed with HTTP $status; do not retry this tag."
    }
}

function Get-MarketplaceArchiveContext {
    param([string]$Archive, [string]$Tag, [string]$Sha256, [hashtable]$CredentialValues)

    $resolvedArchive = Assert-ArchiveIdentity -Path $Archive -Tag $Tag -Sha256 $Sha256
    $archiveText = Get-ArchiveTextContracts -Path $resolvedArchive
    $contract = Get-TocUploadContract -Text $archiveText.Toc -Tag $Tag
    $markdown = [string]$archiveText.Changelog
    if ([string]::IsNullOrWhiteSpace($markdown)) {
        throw "Packaged changelog must be non-empty."
    }
    return [pscustomobject]@{
        Archive = $resolvedArchive
        Contract = $contract
        Credentials = Get-RequiredCredentials -Values $CredentialValues
        Markdown = $markdown
    }
}

function New-MarketplacePlan {
    param(
        [string]$Archive,
        [string]$Tag,
        [string]$Sha256,
        [hashtable]$CredentialValues,
        [scriptblock]$ReadRequest
    )

    $context = Get-MarketplaceArchiveContext -Archive $Archive -Tag $Tag -Sha256 $Sha256 -CredentialValues $CredentialValues
    $cfJson = Invoke-JsonRead -Uri 'https://wow.curseforge.com/api/game/wow/versions' -Headers @{ 'x-api-token' = $context.Credentials.CF_API_KEY } -Request $ReadRequest
    $wowiProjectsJson = Invoke-JsonRead -Uri 'https://api.wowinterface.com/addons/list.json' -Headers @{ 'x-api-token' = $context.Credentials.WOWI_API_TOKEN } -Request $ReadRequest
    Assert-WowInterfaceProjectList -Json $wowiProjectsJson -ExpectedProjectId $context.Contract.ProjectIds.WowInterface
    $wagoProjectHtml = Invoke-JsonRead -Uri "https://addons.wago.io/addons/$($context.Contract.ProjectIds.Wago)" -Headers @{} -Request $ReadRequest
    Assert-WagoProjectPage -Html $wagoProjectHtml -ExpectedProjectId $context.Contract.ProjectIds.Wago
    $wowiJson = Invoke-JsonRead -Uri 'https://api.wowinterface.com/addons/compatible.json' -Headers @{} -Request $ReadRequest
    $wagoJson = Invoke-JsonRead -Uri 'https://addons.wago.io/api/data/game' -Headers @{} -Request $ReadRequest
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        kind = 'statspro-marketplace-plan'
        tag = $Tag
        archiveSha256 = $Sha256
        retailVersions = @($context.Contract.RetailVersions)
        curseForgeGameVersionIds = @(Get-CurseForgeVersionIds -Json $cfJson -RequiredVersions $context.Contract.RetailVersions)
        wowInterfaceVersions = @(Get-WowInterfaceVersions -Json $wowiJson -RequiredVersions $context.Contract.RetailVersions)
        wagoVersions = @(Get-WagoVersions -Json $wagoJson -RequiredVersions $context.Contract.RetailVersions)
    }
}

function Save-MarketplacePlan {
    param([object]$Plan, [string]$Path, [string]$GithubOutputPath)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [System.StringComparer]::Ordinal.Equals([System.IO.Path]::GetFileName($Path), 'statspro-marketplace-plan.json')) {
        throw "Marketplace plan filename must be 'statspro-marketplace-plan.json'."
    }
    Write-Utf8NoBom -Path $Path -Text (($Plan | ConvertTo-Json -Depth 5 -Compress) + "`n")
    $resolved = Resolve-RequiredFile -Path $Path -Description 'marketplace plan'
    $sha = Get-LowercaseFileSha256 -Path $resolved
    Add-OutputValue -Path $GithubOutputPath -Name 'plan_path' -Value $resolved
    Add-OutputValue -Path $GithubOutputPath -Name 'plan_sha256' -Value $sha
    return $sha
}

function Assert-PlanStringArray {
    param([object]$Values, [string]$Description, [string]$Pattern)

    if ($Values -isnot [System.Array] -or $Values.Count -eq 0) {
        throw "$Description must be a non-empty JSON array."
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($value in $Values) {
        if ($value -isnot [string]) {
            throw "$Description contains a non-string value."
        }
        $text = $value
        if ($text -cnotmatch $Pattern -or -not $seen.Add($text)) {
            throw "$Description contains an invalid or duplicate value '$text'."
        }
    }
}

function Read-MarketplacePlan {
    param([string]$Path, [string]$ExpectedSha256, [string]$Tag, [string]$ArchiveSha256)

    Assert-Sha256 -Value $ExpectedSha256 -Description 'Expected marketplace plan SHA-256'
    $resolved = Resolve-RequiredFile -Path $Path -Description 'marketplace plan'
    if (-not [System.StringComparer]::Ordinal.Equals([System.IO.Path]::GetFileName($resolved), 'statspro-marketplace-plan.json')) {
        throw "Marketplace plan filename must be 'statspro-marketplace-plan.json'."
    }
    $actualSha = Get-LowercaseFileSha256 -Path $resolved
    if (-not [System.StringComparer]::Ordinal.Equals($actualSha, $ExpectedSha256)) {
        throw "Marketplace plan SHA-256 is '$actualSha', expected '$ExpectedSha256'."
    }
    try { $plan = ConvertFrom-JsonCompat ([System.IO.File]::ReadAllText($resolved)) }
    catch { throw "Marketplace plan contains invalid JSON: $($_.Exception.Message)" }
    Assert-ExactPropertySet -Value $plan -Expected @(
        'schemaVersion', 'kind', 'tag', 'archiveSha256', 'retailVersions',
        'curseForgeGameVersionIds', 'wowInterfaceVersions', 'wagoVersions'
    ) -Description 'Marketplace plan'
    $schemaIsInteger = $plan.schemaVersion -is [int] -or $plan.schemaVersion -is [long]
    if (-not $schemaIsInteger -or [long]$plan.schemaVersion -ne 1 -or
        $plan.kind -isnot [string] -or $plan.kind -cne 'statspro-marketplace-plan' -or
        $plan.tag -isnot [string] -or $plan.tag -cne $Tag -or
        $plan.archiveSha256 -isnot [string] -or $plan.archiveSha256 -cne $ArchiveSha256) {
        throw "Marketplace plan identity does not match the exact archive."
    }
    Assert-PlanStringArray -Values $plan.retailVersions -Description 'Marketplace plan retail versions' -Pattern '^\d+\.\d+\.\d+$'
    Assert-PlanStringArray -Values $plan.wowInterfaceVersions -Description 'Marketplace plan WoWInterface versions' -Pattern '^\d+\.\d+\.\d+$'
    Assert-PlanStringArray -Values $plan.wagoVersions -Description 'Marketplace plan Wago versions' -Pattern '^\d+\.\d+\.\d+$'
    $cfIds = $plan.curseForgeGameVersionIds
    $seenIds = [System.Collections.Generic.HashSet[int]]::new()
    if ($cfIds -isnot [System.Array] -or $cfIds.Count -eq 0) {
        throw "Marketplace plan CurseForge game version IDs are invalid or duplicated."
    }
    foreach ($id in $cfIds) {
        $isInteger = $id -is [int] -or $id -is [long]
        if (-not $isInteger -or [long]$id -le 0 -or [long]$id -gt [int]::MaxValue -or
            -not $seenIds.Add([int]$id)) {
            throw "Marketplace plan CurseForge game version IDs are invalid or duplicated."
        }
    }
    return $plan
}

function Assert-MarketplacePlanMatchesArchive {
    param([object]$Plan, [object]$ArchiveContext)

    if ((@($Plan.retailVersions) -join "`n") -cne (@($ArchiveContext.Contract.RetailVersions) -join "`n")) {
        throw "Marketplace plan Retail versions do not match the packaged TOC."
    }
}

function Prepare-MarketplacePlanHandoff {
    param(
        [string]$Archive,
        [string]$Tag,
        [string]$Sha256,
        [hashtable]$CredentialValues,
        [string]$Path,
        [string]$GithubOutputPath,
        [scriptblock]$ReadRequest
    )

    $plan = New-MarketplacePlan `
        -Archive $Archive `
        -Tag $Tag `
        -Sha256 $Sha256 `
        -CredentialValues $CredentialValues `
        -ReadRequest $ReadRequest
    $planSha = Save-MarketplacePlan -Plan $plan -Path $Path
    $validatedPlan = Read-MarketplacePlan `
        -Path $Path `
        -ExpectedSha256 $planSha `
        -Tag $Tag `
        -ArchiveSha256 $Sha256
    $context = Get-MarketplaceArchiveContext `
        -Archive $Archive `
        -Tag $Tag `
        -Sha256 $Sha256 `
        -CredentialValues $CredentialValues
    Assert-MarketplacePlanMatchesArchive -Plan $validatedPlan -ArchiveContext $context
    [void](Assert-ArchiveIdentity -Path $context.Archive -Tag $Tag -Sha256 $Sha256)
    Add-OutputValue `
        -Path $GithubOutputPath `
        -Name 'plan_path' `
        -Value (Resolve-RequiredFile -Path $Path -Description 'marketplace plan')
    Add-OutputValue -Path $GithubOutputPath -Name 'plan_sha256' -Value $planSha
    return [pscustomobject]@{ Plan = $validatedPlan; Sha256 = $planSha }
}

function Publish-ExactMarketplacePlan {
    param(
        [string]$Archive,
        [string]$Tag,
        [string]$Sha256,
        [hashtable]$CredentialValues,
        [object]$Plan,
        [scriptblock]$UploadRequest
    )

    $context = Get-MarketplaceArchiveContext -Archive $Archive -Tag $Tag -Sha256 $Sha256 -CredentialValues $CredentialValues
    Assert-MarketplacePlanMatchesArchive -Plan $Plan -ArchiveContext $context
    $cfVersionIds = @($Plan.curseForgeGameVersionIds | ForEach-Object { [int]$_ })
    $wowiVersions = @($Plan.wowInterfaceVersions | ForEach-Object { [string]$_ })
    $wagoVersions = @($Plan.wagoVersions | ForEach-Object { [string]$_ })
    $cfMetadata = [ordered]@{
        displayName = $Tag
        gameVersions = $cfVersionIds
        releaseType = 'release'
        changelog = $context.Markdown
        changelogType = 'markdown'
    } | ConvertTo-Json -Depth 4 -Compress
    $wagoMetadata = [ordered]@{
        label = $Tag
        supported_retail_patches = $wagoVersions
        stability = 'stable'
        changelog = $context.Markdown
    } | ConvertTo-Json -Depth 4 -Compress

    # Wago has no safe read-only token ownership probe, so attempt it before
    # platforms whose credentials/project access were checked during Prepare.
    [void](Assert-ArchiveIdentity -Path $context.Archive -Tag $Tag -Sha256 $Sha256)
    Invoke-ExactUpload `
        -Uri "https://addons.wago.io/api/projects/$($context.Contract.ProjectIds.Wago)/version" `
        -Headers @{ authorization = "Bearer $($context.Credentials.WAGO_API_TOKEN)"; accept = 'application/json' } `
        -Form @{ metadata = $wagoMetadata; file = Get-Item -LiteralPath $context.Archive } `
        -ExpectedStatus @(200, 201) `
        -Description 'Wago upload' `
        -Request $UploadRequest

    [void](Assert-ArchiveIdentity -Path $context.Archive -Tag $Tag -Sha256 $Sha256)
    Invoke-ExactUpload `
        -Uri "https://wow.curseforge.com/api/projects/$($context.Contract.ProjectIds.CurseForge)/upload-file" `
        -Headers @{ 'x-api-token' = $context.Credentials.CF_API_KEY } `
        -Form @{ metadata = $cfMetadata; file = Get-Item -LiteralPath $context.Archive } `
        -ExpectedStatus @(200) `
        -Description 'CurseForge upload' `
        -Request $UploadRequest

    [void](Assert-ArchiveIdentity -Path $context.Archive -Tag $Tag -Sha256 $Sha256)
    Invoke-ExactUpload `
        -Uri 'https://api.wowinterface.com/addons/update' `
        -Headers @{ 'x-api-token' = $context.Credentials.WOWI_API_TOKEN } `
        -Form @{
            id = $context.Contract.ProjectIds.WowInterface
            version = $Tag
            compatible = ($wowiVersions -join ',')
            # Pinned Packager sends the manual Markdown unchanged when its
            # no-secret build has no pandoc-generated WoWI sidecar.
            changelog = $context.Markdown
            updatefile = Get-Item -LiteralPath $context.Archive
        } `
        -ExpectedStatus @(202) `
        -Description 'WoWInterface upload' `
        -Request $UploadRequest

    Write-Host "Marketplace uploads accepted the exact attested archive for $Tag."
}

function Publish-ExactMarketplaceArchive {
    param(
        [string]$Archive,
        [string]$Tag,
        [string]$Sha256,
        [hashtable]$CredentialValues,
        [scriptblock]$ReadRequest,
        [scriptblock]$UploadRequest
    )

    $plan = New-MarketplacePlan -Archive $Archive -Tag $Tag -Sha256 $Sha256 -CredentialValues $CredentialValues -ReadRequest $ReadRequest
    Publish-ExactMarketplacePlan -Archive $Archive -Tag $Tag -Sha256 $Sha256 -CredentialValues $CredentialValues -Plan $plan -UploadRequest $UploadRequest
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-marketplace-upload-" + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $root)
    try {
        $tag = 'v1.2.3'
        $archive = Join-Path $root "StatsPro-$tag.zip"
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archiveStream = [System.IO.File]::Create($archive)
        try {
            $testZip = [System.IO.Compression.ZipArchive]::new($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                foreach ($entryData in @(
                    [pscustomobject]@{ Name = 'StatsPro/StatsPro.toc'; Text = @"
## Interface: 120007, 120100
## Version: 1.2.3
## X-Curse-Project-ID: 1525100
## X-Wago-ID: EGPemEN1
## X-WoWI-ID: 27130
"@ },
                    [pscustomobject]@{ Name = 'StatsPro/CHANGELOG.md'; Text = "## 1.2.3`n`n- Fixed.`n" }
                )) {
                    $entry = $testZip.CreateEntry($entryData.Name)
                    $writer = [System.IO.StreamWriter]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false))
                    try { $writer.Write($entryData.Text) } finally { $writer.Dispose() }
                }
            }
            finally { $testZip.Dispose() }
        }
        finally { $archiveStream.Dispose() }
        $originalArchive = [System.IO.File]::ReadAllBytes($archive)
        $sha = Get-LowercaseFileSha256 -Path $archive
        $credentials = @{ CF_API_KEY = 'cf-secret'; WAGO_API_TOKEN = 'wago-secret'; WOWI_API_TOKEN = 'wowi-secret' }
        $readCalls = [System.Collections.Generic.List[object]]::new()
        $read = {
            param([string]$Uri, [hashtable]$Headers)
            $readCalls.Add([pscustomobject]@{ Uri = $Uri; Headers = $Headers })
            switch ($Uri) {
                'https://wow.curseforge.com/api/game/wow/versions' { return '[{"id":120007,"name":"12.0.7","gameVersionTypeID":517},{"id":120100,"name":"12.1.0","gameVersionTypeID":517}]' }
                'https://api.wowinterface.com/addons/list.json' { return '[{"id":27130,"title":"StatsPro"}]' }
                'https://addons.wago.io/addons/EGPemEN1' { return '<meta property="og:url" content="https://addons.wago.io/addons/EGPemEN1" />' }
                'https://api.wowinterface.com/addons/compatible.json' { return '[{"id":"12.0.7","game":"Retail"},{"id":"12.1.0","game":"Retail"}]' }
                'https://addons.wago.io/api/data/game' { return '{"patches":{"retail":["12.0.7","12.1.0"]}}' }
                default { throw "unexpected read URI" }
            }
        }
        $calls = [System.Collections.Generic.List[object]]::new()
        $upload = {
            param([string]$Uri, [hashtable]$Headers, [hashtable]$Form)
            $calls.Add([pscustomobject]@{ Uri = $Uri; Headers = $Headers; Form = $Form })
            $status = if ($Uri -match 'wowinterface') { 202 } elseif ($Uri -match 'wago') { 201 } else { 200 }
            return [pscustomobject]@{ StatusCode = $status }
        }
        Publish-ExactMarketplaceArchive -Archive $archive -Tag $tag -Sha256 $sha -CredentialValues $credentials -ReadRequest $read -UploadRequest $upload
        $expectedReadUris = @(
            'https://wow.curseforge.com/api/game/wow/versions',
            'https://api.wowinterface.com/addons/list.json',
            'https://addons.wago.io/addons/EGPemEN1',
            'https://api.wowinterface.com/addons/compatible.json',
            'https://addons.wago.io/api/data/game'
        )
        if ($readCalls.Count -ne 5) { throw "Marketplace pre-upload read count self-test failed." }
        for ($index = 0; $index -lt $expectedReadUris.Count; $index++) {
            if (-not [System.StringComparer]::Ordinal.Equals($readCalls[$index].Uri, $expectedReadUris[$index])) {
                throw "Marketplace compatibility URI self-test failed."
            }
        }
        if ($readCalls[0].Headers.Count -ne 1 -or $readCalls[0].Headers['x-api-token'] -ne $credentials.CF_API_KEY -or
            $readCalls[1].Headers.Count -ne 1 -or $readCalls[1].Headers['x-api-token'] -ne $credentials.WOWI_API_TOKEN -or
            $readCalls[2].Headers.Count -ne 0 -or $readCalls[3].Headers.Count -ne 0 -or
            $readCalls[4].Headers.Count -ne 0) {
            throw "Marketplace pre-upload header self-test failed."
        }
        $expectedUploadUris = @(
            'https://addons.wago.io/api/projects/EGPemEN1/version',
            'https://wow.curseforge.com/api/projects/1525100/upload-file',
            'https://api.wowinterface.com/addons/update'
        )
        if ($calls.Count -ne 3) {
            throw "Marketplace upload ordering self-test failed."
        }
        for ($index = 0; $index -lt $expectedUploadUris.Count; $index++) {
            if (-not [System.StringComparer]::Ordinal.Equals($calls[$index].Uri, $expectedUploadUris[$index])) {
                throw "Marketplace upload URI self-test failed."
            }
        }
        foreach ($call in $calls) {
            $file = if ($call.Form.ContainsKey('file')) { $call.Form.file } else { $call.Form.updatefile }
            if ($null -eq $file -or -not [System.StringComparer]::Ordinal.Equals($file.FullName, (Resolve-Path $archive).Path)) {
                throw "Marketplace upload did not bind the exact archive file."
            }
        }
        $cfPayload = ConvertFrom-JsonCompat ([string]$calls[1].Form.metadata)
        if ($calls[1].Headers.Count -ne 1 -or $calls[1].Headers['x-api-token'] -ne $credentials.CF_API_KEY -or
            $calls[1].Form.Count -ne 2 -or $cfPayload.displayName -ne $tag -or $cfPayload.releaseType -ne 'release' -or
            $cfPayload.changelogType -ne 'markdown' -or $cfPayload.changelog -ne "## 1.2.3`n`n- Fixed.`n" -or
            (@($cfPayload.gameVersions) -join ',') -ne '120007,120100') {
            throw "CurseForge payload self-test failed."
        }
        if ($calls[2].Headers.Count -ne 1 -or $calls[2].Headers['x-api-token'] -ne $credentials.WOWI_API_TOKEN -or
            $calls[2].Form.Count -ne 5 -or $calls[2].Form.id -ne '27130' -or $calls[2].Form.version -ne $tag -or
            $calls[2].Form.compatible -ne '12.1.0,12.0.7' -or $calls[2].Form.changelog -ne "## 1.2.3`n`n- Fixed.`n") {
            throw "WoWInterface payload self-test failed."
        }
        $wagoPayload = ConvertFrom-JsonCompat ([string]$calls[0].Form.metadata)
        if ($calls[0].Headers.Count -ne 2 -or $calls[0].Headers.authorization -ne "Bearer $($credentials.WAGO_API_TOKEN)" -or
            $calls[0].Headers.accept -ne 'application/json' -or $calls[0].Form.Count -ne 2 -or
            $wagoPayload.label -ne $tag -or $wagoPayload.stability -ne 'stable' -or
            $wagoPayload.changelog -ne "## 1.2.3`n`n- Fixed.`n" -or
            (@($wagoPayload.supported_retail_patches) -join ',') -ne '12.1.0,12.0.7') {
            throw "Wago payload self-test failed."
        }

        $planPath = Join-Path $root 'statspro-marketplace-plan.json'
        $planOutput = Join-Path $root 'plan-output.txt'
        $prepared = Prepare-MarketplacePlanHandoff `
            -Archive $archive `
            -Tag $tag `
            -Sha256 $sha `
            -CredentialValues $credentials `
            -Path $planPath `
            -GithubOutputPath $planOutput `
            -ReadRequest $read
        $planSha = $prepared.Sha256
        $loadedPlan = $prepared.Plan
        $planOutputText = Get-Content -LiteralPath $planOutput -Raw
        if ($planOutputText -notmatch '(?m)^plan_path=.+statspro-marketplace-plan\.json$' -or
            $planOutputText -notmatch "(?m)^plan_sha256=$([regex]::Escape($planSha))$") {
            throw "Validated marketplace handoff did not emit exact plan outputs."
        }
        $planCalls = [System.Collections.Generic.List[object]]::new()
        Publish-ExactMarketplacePlan -Archive $archive -Tag $tag -Sha256 $sha -CredentialValues $credentials -Plan $loadedPlan -UploadRequest {
            param($uri, $headers, $form)
            $planCalls.Add([pscustomobject]@{ Uri = $uri; Headers = $headers; Form = $form })
            [pscustomobject]@{ StatusCode = if ($uri -match 'wowinterface') { 202 } else { 200 } }
        }
        if ($planCalls.Count -ne 3) { throw "Prepared marketplace plan did not drive exactly three uploads." }
        $validPlanText = [System.IO.File]::ReadAllText($planPath)
        [System.IO.File]::AppendAllText($planPath, 'tampered')
        Assert-ThrowsMatch "tampered marketplace plan rejected" {
            [void](Read-MarketplacePlan -Path $planPath -ExpectedSha256 $planSha -Tag $tag -ArchiveSha256 $sha)
        } "plan SHA-256"

        $writeInvalidPlan = {
            param([string]$Text)
            Write-Utf8NoBom -Path $planPath -Text $Text
            return Get-LowercaseFileSha256 -Path $planPath
        }
        $invalidSha = & $writeInvalidPlan ($validPlanText.Replace('"schemaVersion":1', '"schemaVersion":true'))
        Assert-ThrowsMatch "boolean marketplace schema rejected" {
            [void](Read-MarketplacePlan -Path $planPath -ExpectedSha256 $invalidSha -Tag $tag -ArchiveSha256 $sha)
        } "identity"
        $invalidSha = & $writeInvalidPlan ($validPlanText.Replace('120007', '2147483648'))
        Assert-ThrowsMatch "oversized CurseForge plan ID rejected" {
            [void](Read-MarketplacePlan -Path $planPath -ExpectedSha256 $invalidSha -Tag $tag -ArchiveSha256 $sha)
        } "IDs are invalid"
        $invalidSha = & $writeInvalidPlan ($validPlanText.Replace('120100', '120007'))
        Assert-ThrowsMatch "duplicate CurseForge plan ID rejected" {
            [void](Read-MarketplacePlan -Path $planPath -ExpectedSha256 $invalidSha -Tag $tag -ArchiveSha256 $sha)
        } "IDs are invalid"
        $invalidSha = & $writeInvalidPlan ($validPlanText -replace ',"wagoVersions":\[[^\]]+\]', '')
        Assert-ThrowsMatch "missing marketplace plan field rejected" {
            [void](Read-MarketplacePlan -Path $planPath -ExpectedSha256 $invalidSha -Tag $tag -ArchiveSha256 $sha)
        } "fields"
        $invalidSha = & $writeInvalidPlan ($validPlanText.TrimEnd("`r", "`n", '}' ) + ',"extra":true}' + "`n")
        Assert-ThrowsMatch "extra marketplace plan field rejected" {
            [void](Read-MarketplacePlan -Path $planPath -ExpectedSha256 $invalidSha -Tag $tag -ArchiveSha256 $sha)
        } "fields"
        Write-Utf8NoBom -Path $planPath -Text $validPlanText

        Assert-ThrowsMatch "duplicate external CurseForge mapping rejected before plan" {
            [void](New-MarketplacePlan -Archive $archive -Tag $tag -Sha256 $sha -CredentialValues $credentials -ReadRequest {
                param($uri, $headers)
                if ($uri -eq 'https://wow.curseforge.com/api/game/wow/versions') {
                    return '[{"id":120007,"name":"12.0.7","gameVersionTypeID":517},{"id":120008,"name":"12.0.7","gameVersionTypeID":517},{"id":120100,"name":"12.1.0","gameVersionTypeID":517}]'
                }
                return & $read $uri $headers
            })
        } "exactly one Retail game version"

        Assert-ThrowsMatch "wrong WoWInterface project access rejected before plan" {
            [void](New-MarketplacePlan -Archive $archive -Tag $tag -Sha256 $sha -CredentialValues $credentials -ReadRequest {
                param($uri, $headers)
                if ($uri -eq 'https://api.wowinterface.com/addons/list.json') { return '[]' }
                return & $read $uri $headers
            })
        } "must expose exactly one"

        Assert-ThrowsMatch "wrong Wago project page rejected before plan" {
            [void](New-MarketplacePlan -Archive $archive -Tag $tag -Sha256 $sha -CredentialValues $credentials -ReadRequest {
                param($uri, $headers)
                if ($uri -eq 'https://addons.wago.io/addons/EGPemEN1') {
                    return '<meta property="og:url" content="https://addons.wago.io/addons/OTHER" />'
                }
                return & $read $uri $headers
            })
        } "does not identify StatsPro project"

        $mutationOutput = Join-Path $root 'mutation-output.txt'
        Assert-ThrowsMatch "archive mutation during marketplace reads rejected before outputs" {
            [void](Prepare-MarketplacePlanHandoff `
                -Archive $archive `
                -Tag $tag `
                -Sha256 $sha `
                -CredentialValues $credentials `
                -Path $planPath `
                -GithubOutputPath $mutationOutput `
                -ReadRequest {
                    param($uri, $headers)
                    $result = & $read $uri $headers
                    if ($uri -eq 'https://addons.wago.io/api/data/game') {
                        [System.IO.File]::AppendAllText($archive, 'changed')
                    }
                    return $result
                })
        } "archive SHA-256"
        if (Test-Path -LiteralPath $mutationOutput) {
            throw "Failed marketplace Prepare emitted plan outputs."
        }
        [System.IO.File]::WriteAllBytes($archive, $originalArchive)

        $zeroCalls = [System.Collections.Generic.List[object]]::new()
        Assert-ThrowsMatch "wrong archive hash blocks every upload" {
            Publish-ExactMarketplaceArchive -Archive $archive -Tag $tag -Sha256 ('f' * 64) -CredentialValues $credentials -ReadRequest $read -UploadRequest { param($u, $h, $f) $zeroCalls.Add($u); [pscustomobject]@{ StatusCode = 200 } }
        } "archive SHA-256"
        if ($zeroCalls.Count -ne 0) { throw "Wrong hash reached an upload request." }

        Assert-ThrowsMatch "missing credential blocks every upload" {
            Publish-ExactMarketplaceArchive -Archive $archive -Tag $tag -Sha256 $sha -CredentialValues @{ CF_API_KEY = ''; WAGO_API_TOKEN = 'x'; WOWI_API_TOKEN = 'y' } -ReadRequest $read -UploadRequest { throw 'should not upload' }
        } "CF_API_KEY"

        $mutatingCalls = [System.Collections.Generic.List[string]]::new()
        Assert-ThrowsMatch "archive mutation between platforms is rejected" {
            Publish-ExactMarketplaceArchive -Archive $archive -Tag $tag -Sha256 $sha -CredentialValues $credentials -ReadRequest $read -UploadRequest {
                param($uri, $headers, $form)
                $mutatingCalls.Add($uri)
                [System.IO.File]::AppendAllText($archive, 'changed')
                [pscustomobject]@{ StatusCode = 200 }
            }
        } "archive SHA-256"
        if ($mutatingCalls.Count -ne 1) { throw "Archive mutation should stop before the second upload." }
        [System.IO.File]::WriteAllBytes($archive, $originalArchive)

        $failureCalls = [System.Collections.Generic.List[string]]::new()
        Assert-ThrowsMatch "failed upload is not retried" {
            Publish-ExactMarketplaceArchive -Archive $archive -Tag $tag -Sha256 $sha -CredentialValues $credentials -ReadRequest $read -UploadRequest {
                param($uri, $headers, $form)
                $failureCalls.Add($uri)
                [pscustomobject]@{ StatusCode = 503 }
            }
        } "HTTP 503.*do not retry"
        if ($failureCalls.Count -ne 1) { throw "Failed upload must be attempted exactly once." }

        $ambiguousCalls = [System.Collections.Generic.List[string]]::new()
        Assert-ThrowsMatch "ambiguous upload is not retried or leaked" {
            Publish-ExactMarketplaceArchive -Archive $archive -Tag $tag -Sha256 $sha -CredentialValues $credentials -ReadRequest $read -UploadRequest {
                param($uri, $headers, $form)
                $ambiguousCalls.Add($uri)
                throw "transport failed with $($credentials.CF_API_KEY)"
            }
        } "outcome is ambiguous.*RuntimeException"
        if ($ambiguousCalls.Count -ne 1) { throw "Ambiguous upload must be attempted exactly once." }

        Assert-ThrowsMatch "unsupported WoWInterface fallback blocks upload" {
            Publish-ExactMarketplaceArchive -Archive $archive -Tag $tag -Sha256 $sha -CredentialValues $credentials -ReadRequest {
                param($uri, $headers)
                if ($uri -match 'curseforge') { return '[{"id":120007,"name":"12.0.7","gameVersionTypeID":517},{"id":120100,"name":"12.1.0","gameVersionTypeID":517}]' }
                if ($uri -eq 'https://api.wowinterface.com/addons/list.json') { return '[{"id":27130,"title":"StatsPro"}]' }
                if ($uri -eq 'https://api.wowinterface.com/addons/compatible.json') { return '[{"id":"12.0.9","game":"Retail"},{"id":"12.0.0","game":"Retail"}]' }
                if ($uri -eq 'https://addons.wago.io/addons/EGPemEN1') { return '<meta property="og:url" content="https://addons.wago.io/addons/EGPemEN1" />' }
                return '{"patches":{"retail":["12.0.7","12.1.0"]}}'
            } -UploadRequest { throw 'should not upload' }
        } "WoWInterface would select unsupported fallback"

        if ((Select-OrdinalFallback -Available @('12.0.7', '12.0.9') -Requested '12.1.0') -cne '12.0.9') {
            throw "Marketplace fallback selection must use the greatest ordinal predecessor."
        }

        Write-Host "Marketplace publisher self-test passed."
    }
    finally {
        $resolvedRoot = [System.IO.Path]::GetFullPath($root)
        $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if ($resolvedRoot.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "Marketplace publication requires PowerShell 7 or newer before any credential or network access."
}

$environmentValues = @{
    CF_API_KEY = [Environment]::GetEnvironmentVariable('CF_API_KEY')
    WAGO_API_TOKEN = [Environment]::GetEnvironmentVariable('WAGO_API_TOKEN')
    WOWI_API_TOKEN = [Environment]::GetEnvironmentVariable('WOWI_API_TOKEN')
}
if ([string]::IsNullOrWhiteSpace($Mode)) {
    throw "Missing marketplace publication -Mode."
}
switch ($Mode) {
    'Prepare' {
        [void](Prepare-MarketplacePlanHandoff `
            -Archive $ArchivePath `
            -Tag $ExpectedTag `
            -Sha256 $ExpectedSha256 `
            -CredentialValues $environmentValues `
            -Path $PlanPath `
            -GithubOutputPath $OutputPath)
    }
    'Publish' {
        $plan = Read-MarketplacePlan `
            -Path $PlanPath `
            -ExpectedSha256 $ExpectedPlanSha256 `
            -Tag $ExpectedTag `
            -ArchiveSha256 $ExpectedSha256
        Publish-ExactMarketplacePlan `
            -Archive $ArchivePath `
            -Tag $ExpectedTag `
            -Sha256 $ExpectedSha256 `
            -CredentialValues $environmentValues `
            -Plan $plan
    }
}
