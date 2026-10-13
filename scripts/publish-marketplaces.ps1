param(
    [ValidateSet('Prepare', 'Publish')]
    [string]$Mode,
    [string]$ArchivePath,
    [string]$ExpectedTag,
    [string]$ExpectedSha256,
    [string]$PlanPath,
    [string]$ExpectedPlanSha256,
    [string]$OutputPath,
    [ValidateSet('Retail', 'Forever')]
    [string]$Flavor = 'Retail',
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "release-check-contract.ps1")
. (Join-Path $PSScriptRoot "release-tag-contract.ps1")
. (Join-Path $PSScriptRoot "marketplace-version-contract.ps1")
$Flavor = ConvertTo-StatsProMarketplaceFlavor -Value $Flavor

$ExpectedProjectIds = Get-StatsProExpectedMarketplaceProjectIdMap

function Assert-ArchiveIdentity {
    param([string]$Path, [string]$Tag, [string]$Sha256, [ValidateSet('Retail', 'Forever')][string]$Flavor = 'Retail')

    Assert-StatsProReleaseTag -Value $Tag
    Assert-Sha256 -Value $Sha256 -Description 'Expected archive SHA-256'
    $resolved = Resolve-RequiredFile -Path $Path -Description "marketplace archive"
    $expectedName = if ($Flavor -ieq 'Forever') { "StatsPro-$Tag-Forever-beta.zip" } else { "StatsPro-$Tag.zip" }
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
    foreach ($name in @('CF_API_KEY', 'WAGO_API_TOKEN')) {
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
    param([string]$Text, [string]$Tag, [ValidateSet('Retail', 'Forever')][string]$Flavor = 'Retail')

    $Flavor = ConvertTo-StatsProMarketplaceFlavor -Value $Flavor

    $version = Get-SingleTocValue -Text $text -Key 'Version' -Pattern '^\d+\.\d+\.\d+$'
    if (-not [System.StringComparer]::Ordinal.Equals("v$version", $Tag)) {
        throw "Packaged TOC version '$version' does not match release tag '$Tag'."
    }
    $ids = [ordered]@{
        CurseForge = Get-SingleTocValue -Text $text -Key 'X-Curse-Project-ID' -Pattern '^\d+$'
        Wago = Get-SingleTocValue -Text $text -Key 'X-Wago-ID' -Pattern '^[A-Za-z0-9]{8}$'
    }
    if ($Flavor -ieq 'Retail') { $ids.WowInterface = Get-SingleTocValue -Text $text -Key 'X-WoWI-ID' -Pattern '^\d+$' }
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
        if ($Flavor -ieq 'Forever') {
            if ($interfaces.Count -ne 1 -or $interface -cne '16001') {
                throw 'Forever TOC must declare exact Interface 16001 without other flavors.'
            }
            $versions += '1.60.1'
            continue
        }
        if ($interface -notmatch '^\d{6}$') {
            throw "Packaged TOC Interface '$interface' is not a six-digit Retail interface."
        }
        $versions += "{0}.{1}.{2}" -f [int]$interface.Substring(0, 2), [int]$interface.Substring(2, 2), [int]$interface.Substring(4, 2)
    }
    return [pscustomobject]@{
        Version = $version
        ProjectIds = $ids
        Flavor = $Flavor
        GameVersions = @($versions | Sort-Object { [version]$_ } -Unique)
        RetailVersions = @($versions | Sort-Object { [version]$_ } -Unique)
    }
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
    param([string]$Archive, [string]$Tag, [string]$Sha256, [hashtable]$CredentialValues,
        [ValidateSet('Retail', 'Forever')][string]$Flavor = 'Retail')

    $resolvedArchive = Assert-ArchiveIdentity -Path $Archive -Tag $Tag -Sha256 $Sha256 -Flavor $Flavor
    $archiveText = Get-ArchiveTextContracts -Path $resolvedArchive
    $contract = Get-TocUploadContract -Text $archiveText.Toc -Tag $Tag -Flavor $Flavor
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
        [scriptblock]$ReadRequest,
        [ValidateSet('Retail', 'Forever')][string]$Flavor = 'Retail'
    )

    $context = Get-MarketplaceArchiveContext -Archive $Archive -Tag $Tag -Sha256 $Sha256 -CredentialValues $CredentialValues -Flavor $Flavor
    $cfJson = Invoke-JsonRead -Uri 'https://wow.curseforge.com/api/game/wow/versions' -Headers @{ 'x-api-token' = $context.Credentials.CF_API_KEY } -Request $ReadRequest
    $wagoProjectHtml = Invoke-JsonRead -Uri "https://addons.wago.io/addons/$($context.Contract.ProjectIds.Wago)" -Headers @{} -Request $ReadRequest
    Assert-StatsProWagoProjectPage -Html $wagoProjectHtml -ExpectedProjectId $context.Contract.ProjectIds.Wago
    $wagoJson = Invoke-JsonRead -Uri 'https://addons.wago.io/api/data/game' -Headers @{} -Request $ReadRequest
    $plan = [ordered]@{
        schemaVersion = 1
        kind = 'statspro-marketplace-plan'
        tag = $Tag
        archiveSha256 = $Sha256
        retailVersions = @($context.Contract.RetailVersions)
        curseForgeGameVersionIds = @(Resolve-StatsProCurseForgeVersionIdMap -Json $cfJson -RequiredVersions $context.Contract.GameVersions -Flavor $Flavor)
        wowInterfaceVersions = @() # Retired; reject old plans that still request uploads.
        wagoVersions = @(Resolve-StatsProWagoVersionSelection -Json $wagoJson -RequiredVersions $context.Contract.GameVersions -Flavor $Flavor)
    }
    if ($Flavor -ieq 'Forever') {
        $plan.schemaVersion = 2
        $plan.Remove('retailVersions')
        $plan.flavor = 'Forever'
        $plan.gameVersions = @($context.Contract.GameVersions)
        $plan.curseForgeGameVersionTypeId = 88568
    }
    return [pscustomobject]$plan
}

function Save-MarketplacePlan {
    param([object]$Plan, [string]$Path, [string]$GithubOutputPath)

    $filename = if ($Plan.PSObject.Properties['flavor'] -and $Plan.flavor -ceq 'Forever') { 'statspro-forever-marketplace-plan.json' } else { 'statspro-marketplace-plan.json' }
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [System.StringComparer]::Ordinal.Equals([System.IO.Path]::GetFileName($Path), $filename)) {
        throw "Marketplace plan filename must be '$filename'."
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
    param([string]$Path, [string]$ExpectedSha256, [string]$Tag, [string]$ArchiveSha256,
        [ValidateSet('Retail', 'Forever')][string]$Flavor = 'Retail')

    Assert-Sha256 -Value $ExpectedSha256 -Description 'Expected marketplace plan SHA-256'
    $resolved = Resolve-RequiredFile -Path $Path -Description 'marketplace plan'
    $filename = if ($Flavor -ieq 'Forever') { 'statspro-forever-marketplace-plan.json' } else { 'statspro-marketplace-plan.json' }
    if (-not [System.StringComparer]::Ordinal.Equals([System.IO.Path]::GetFileName($resolved), $filename)) {
        throw "Marketplace plan filename must be '$filename'."
    }
    $actualSha = Get-LowercaseFileSha256 -Path $resolved
    if (-not [System.StringComparer]::Ordinal.Equals($actualSha, $ExpectedSha256)) {
        throw "Marketplace plan SHA-256 is '$actualSha', expected '$ExpectedSha256'."
    }
    try { $plan = ConvertFrom-JsonCompat ([System.IO.File]::ReadAllText($resolved)) }
    catch { throw "Marketplace plan contains invalid JSON: $($_.Exception.Message)" }
    $expectedProperties = @(
        'schemaVersion', 'kind', 'tag', 'archiveSha256', 'retailVersions',
        'curseForgeGameVersionIds', 'wowInterfaceVersions', 'wagoVersions'
    )
    $schema = 1
    if ($Flavor -ieq 'Forever') {
        $schema = 2
        $expectedProperties = @($expectedProperties | Where-Object { $_ -cne 'retailVersions' }) + @('flavor', 'gameVersions', 'curseForgeGameVersionTypeId')
    }
    Assert-ExactPropertySet -Value $plan -Expected $expectedProperties -Description 'Marketplace plan'
    $schemaIsInteger = $plan.schemaVersion -is [int] -or $plan.schemaVersion -is [long]
    if (-not $schemaIsInteger -or [long]$plan.schemaVersion -ne $schema -or
        $plan.kind -isnot [string] -or $plan.kind -cne 'statspro-marketplace-plan' -or
        $plan.tag -isnot [string] -or $plan.tag -cne $Tag -or
        $plan.archiveSha256 -isnot [string] -or $plan.archiveSha256 -cne $ArchiveSha256) {
        throw "Marketplace plan identity does not match the exact archive."
    }
    if ($Flavor -ieq 'Forever') {
        if ($plan.flavor -isnot [string] -or $plan.flavor -cne 'Forever' -or
            ($plan.curseForgeGameVersionTypeId -isnot [int] -and $plan.curseForgeGameVersionTypeId -isnot [long]) -or
            $plan.curseForgeGameVersionTypeId -ne 88568) { throw 'Forever marketplace plan flavor identity is invalid.' }
        Assert-PlanStringArray -Values $plan.gameVersions -Description 'Marketplace plan Forever versions' -Pattern '^1\.60\.1$'
    } else {
        Assert-PlanStringArray -Values $plan.retailVersions -Description 'Marketplace plan retail versions' -Pattern '^\d+\.\d+\.\d+$'
    }
    if ($plan.wowInterfaceVersions -isnot [System.Array] -or $plan.wowInterfaceVersions.Count -ne 0) {
        throw 'WoWInterface publication is retired; prepare a new marketplace plan.'
    }
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
    if ($Flavor -ieq 'Forever' -and ($cfIds.Count -ne 1 -or @($plan.wagoVersions).Count -ne 1 -or $plan.wagoVersions[0] -cne '1.60.1')) {
        throw 'Forever marketplace plan must select one exact CurseForge ID and Wago patch 1.60.1.'
    }
    return $plan
}

function Assert-MarketplacePlanMatchesArchive {
    param([object]$Plan, [object]$ArchiveContext)

    if ($ArchiveContext.Contract.Flavor -ceq 'Forever') {
        if ($Plan.flavor -cne 'Forever' -or $Plan.curseForgeGameVersionTypeId -ne 88568 -or
            (@($Plan.gameVersions) -join ',') -cne '1.60.1' -or (@($Plan.wagoVersions) -join ',') -cne '1.60.1') {
            throw 'Marketplace plan Forever flavor does not match the packaged TOC.'
        }
        return
    }
    if ($Plan.PSObject.Properties['flavor']) { throw 'Marketplace plan flavor does not match the Retail archive.' }
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
        [scriptblock]$ReadRequest,
        [ValidateSet('Retail', 'Forever')][string]$Flavor = 'Retail'
    )

    $plan = New-MarketplacePlan `
        -Archive $Archive `
        -Tag $Tag `
        -Sha256 $Sha256 `
        -CredentialValues $CredentialValues `
        -ReadRequest $ReadRequest -Flavor $Flavor
    $planSha = Save-MarketplacePlan -Plan $plan -Path $Path
    $validatedPlan = Read-MarketplacePlan `
        -Path $Path `
        -ExpectedSha256 $planSha `
        -Tag $Tag `
        -ArchiveSha256 $Sha256 -Flavor $Flavor
    $context = Get-MarketplaceArchiveContext `
        -Archive $Archive `
        -Tag $Tag `
        -Sha256 $Sha256 `
        -CredentialValues $CredentialValues -Flavor $Flavor
    Assert-MarketplacePlanMatchesArchive -Plan $validatedPlan -ArchiveContext $context
    [void](Assert-ArchiveIdentity -Path $context.Archive -Tag $Tag -Sha256 $Sha256 -Flavor $Flavor)
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
        [scriptblock]$UploadRequest,
        [ValidateSet('Retail', 'Forever')][string]$Flavor = 'Retail'
    )

    $context = Get-MarketplaceArchiveContext -Archive $Archive -Tag $Tag -Sha256 $Sha256 -CredentialValues $CredentialValues -Flavor $Flavor
    Assert-MarketplacePlanMatchesArchive -Plan $Plan -ArchiveContext $context
    $cfVersionIds = @($Plan.curseForgeGameVersionIds | ForEach-Object { [int]$_ })
    $wagoVersions = @($Plan.wagoVersions | ForEach-Object { [string]$_ })
    $cfMetadata = [ordered]@{
        displayName = if ($Flavor -ieq 'Forever') { "$Tag-Forever-beta" } else { $Tag }
        gameVersions = $cfVersionIds
        releaseType = if ($Flavor -ieq 'Forever') { 'beta' } else { 'release' }
        changelog = $context.Markdown
        changelogType = 'markdown'
    } | ConvertTo-Json -Depth 4 -Compress
    $wagoValues = [ordered]@{
        label = if ($Flavor -ieq 'Forever') { "$Tag-Forever-beta" } else { $Tag }
        stability = if ($Flavor -ieq 'Forever') { 'beta' } else { 'stable' }
        changelog = $context.Markdown
    }
    $supportProperty = if ($Flavor -ieq 'Forever') { 'supported_forever_patches' } else { 'supported_retail_patches' }
    $wagoValues[$supportProperty] = $wagoVersions
    $wagoMetadata = $wagoValues | ConvertTo-Json -Depth 4 -Compress

    # Wago has no safe read-only token ownership probe, so attempt it before
    # platforms whose credentials/project access were checked during Prepare.
    [void](Assert-ArchiveIdentity -Path $context.Archive -Tag $Tag -Sha256 $Sha256 -Flavor $Flavor)
    Invoke-ExactUpload `
        -Uri "https://addons.wago.io/api/projects/$($context.Contract.ProjectIds.Wago)/version" `
        -Headers @{ authorization = "Bearer $($context.Credentials.WAGO_API_TOKEN)"; accept = 'application/json' } `
        -Form @{ metadata = $wagoMetadata; file = Get-Item -LiteralPath $context.Archive } `
        -ExpectedStatus @(200, 201) `
        -Description 'Wago upload' `
        -Request $UploadRequest

    [void](Assert-ArchiveIdentity -Path $context.Archive -Tag $Tag -Sha256 $Sha256 -Flavor $Flavor)
    Invoke-ExactUpload `
        -Uri "https://wow.curseforge.com/api/projects/$($context.Contract.ProjectIds.CurseForge)/upload-file" `
        -Headers @{ 'x-api-token' = $context.Credentials.CF_API_KEY } `
        -Form @{ metadata = $cfMetadata; file = Get-Item -LiteralPath $context.Archive } `
        -ExpectedStatus @(200) `
        -Description 'CurseForge upload' `
        -Request $UploadRequest

    if ($Flavor -ieq 'Forever') {
        Write-Host "Forever marketplace uploads accepted the exact attested archive for ${Tag}: $([System.IO.Path]::GetFileName($context.Archive)) sha256=$Sha256."
    } else {
        Write-Host "Marketplace uploads accepted the exact attested archive for $Tag."
    }
}

function Publish-ExactMarketplaceArchive {
    param(
        [string]$Archive,
        [string]$Tag,
        [string]$Sha256,
        [hashtable]$CredentialValues,
        [scriptblock]$ReadRequest,
        [scriptblock]$UploadRequest,
        [ValidateSet('Retail', 'Forever')][string]$Flavor = 'Retail'
    )

    $plan = New-MarketplacePlan -Archive $Archive -Tag $Tag -Sha256 $Sha256 -CredentialValues $CredentialValues -ReadRequest $ReadRequest -Flavor $Flavor
    Publish-ExactMarketplacePlan -Archive $Archive -Tag $Tag -Sha256 $Sha256 -CredentialValues $CredentialValues -Plan $plan -UploadRequest $UploadRequest -Flavor $Flavor
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-marketplace-upload-" + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $root)
    try {
        $tag = 'v1.2.3'
        $fullChangelog = "# Changelog`n`n## 1.2.3`n`n- Fixed.`n`n## 1.2.2`n`n- Previous update.`n`n## 1.0.0`n`n- Initial release.`n"
        $archive = Join-Path $root "StatsPro-$tag.zip"
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archiveStream = [System.IO.File]::Create($archive)
        try {
            $testZip = [System.IO.Compression.ZipArchive]::new($archiveStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                foreach ($entryData in @(
                    [pscustomobject]@{ Name = 'StatsPro/StatsPro.toc'; Text = @"
## Interface: 120100
## Version: 1.2.3
## X-Curse-Project-ID: 1525100
## X-Wago-ID: EGPemEN1
## X-WoWI-ID: 27130
"@ },
                    [pscustomobject]@{ Name = 'StatsPro/CHANGELOG.md'; Text = $fullChangelog }
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
        $credentials = @{ CF_API_KEY = 'cf-secret'; WAGO_API_TOKEN = 'wago-secret' }
        $readCalls = [System.Collections.Generic.List[object]]::new()
        $read = {
            param([string]$Uri, [hashtable]$Headers)
            $readCalls.Add([pscustomobject]@{ Uri = $Uri; Headers = $Headers })
            switch ($Uri) {
                'https://wow.curseforge.com/api/game/wow/versions' { return '[{"id":120100,"name":"12.1.0","gameVersionTypeID":517}]' }
                'https://api.wowinterface.com/addons/list.json' { return '[{"id":27130,"title":"StatsPro"}]' }
                'https://addons.wago.io/addons/EGPemEN1' { return '<meta property="og:url" content="https://addons.wago.io/addons/EGPemEN1" />' }
                'https://api.wowinterface.com/addons/compatible.json' { return '[{"id":"12.1.0","game":"Retail"}]' }
                'https://addons.wago.io/api/data/game' { return '{"patches":{"retail":["12.1.0"]}}' }
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
            'https://addons.wago.io/addons/EGPemEN1',
            'https://addons.wago.io/api/data/game'
        )
        if ($readCalls.Count -ne 3) { throw "Marketplace pre-upload read count self-test failed." }
        for ($index = 0; $index -lt $expectedReadUris.Count; $index++) {
            if (-not [System.StringComparer]::Ordinal.Equals($readCalls[$index].Uri, $expectedReadUris[$index])) {
                throw "Marketplace compatibility URI self-test failed."
            }
        }
        if ($readCalls[0].Headers.Count -ne 1 -or $readCalls[0].Headers['x-api-token'] -ne $credentials.CF_API_KEY -or
            $readCalls[1].Headers.Count -ne 0 -or $readCalls[2].Headers.Count -ne 0) {
            throw "Marketplace pre-upload header self-test failed."
        }
        $expectedUploadUris = @(
            'https://addons.wago.io/api/projects/EGPemEN1/version',
            'https://wow.curseforge.com/api/projects/1525100/upload-file'
        )
        if ($calls.Count -ne 2) {
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
            $cfPayload.changelogType -ne 'markdown' -or $cfPayload.changelog -ne $fullChangelog -or
            (@($cfPayload.gameVersions) -join ',') -ne '120100') {
            throw "CurseForge payload self-test failed."
        }
        $wagoPayload = ConvertFrom-JsonCompat ([string]$calls[0].Form.metadata)
        if ($calls[0].Headers.Count -ne 2 -or $calls[0].Headers.authorization -ne "Bearer $($credentials.WAGO_API_TOKEN)" -or
            $calls[0].Headers.accept -ne 'application/json' -or $calls[0].Form.Count -ne 2 -or
            $wagoPayload.label -ne $tag -or $wagoPayload.stability -ne 'stable' -or
            $wagoPayload.changelog -ne $fullChangelog -or
            (@($wagoPayload.supported_retail_patches) -join ',') -ne '12.1.0') {
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
        if ($planCalls.Count -ne 2) { throw "Prepared marketplace plan did not drive exactly two uploads." }
        $validPlanText = [System.IO.File]::ReadAllText($planPath)
        $retiredPlan = [System.IO.File]::ReadAllText($planPath).Replace('"wowInterfaceVersions":[]', '"wowInterfaceVersions":["12.1.0"]')
        Write-Utf8NoBom -Path $planPath -Text $retiredPlan
        Assert-ThrowsMatch "retired WoWInterface plan rejected" {
            [void](Read-MarketplacePlan -Path $planPath -ExpectedSha256 (Get-LowercaseFileSha256 -Path $planPath) -Tag $tag -ArchiveSha256 $sha)
        } "WoWInterface publication is retired"
        Write-Utf8NoBom -Path $planPath -Text $validPlanText

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
        $invalidSha = & $writeInvalidPlan ($validPlanText.Replace('120100', '2147483648'))
        Assert-ThrowsMatch "oversized CurseForge plan ID rejected" {
            [void](Read-MarketplacePlan -Path $planPath -ExpectedSha256 $invalidSha -Tag $tag -ArchiveSha256 $sha)
        } "IDs are invalid"
        $invalidSha = & $writeInvalidPlan ($validPlanText.Replace('120100', '120100,120100'))
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
                    return '[{"id":120100,"name":"12.1.0","gameVersionTypeID":517},{"id":120101,"name":"12.1.0","gameVersionTypeID":517}]'
                }
                return & $read $uri $headers
            })
        } "exactly one Retail game version"


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



        if ((Select-StatsProOrdinalMarketplaceVersion -AvailableVersions @('12.0.9', '12.0.10') -RequestedVersion '12.1.0') -cne '12.0.9') {
            throw "Marketplace fallback selection must use the greatest ordinal predecessor."
        }
        $earlierWago = @(Resolve-StatsProWagoVersionSelection -Json '{"patches":{"retail":["12.0.7"]}}' -RequiredVersions @('12.0.7', '12.1.0'))
        if (($earlierWago -join ',') -ne '12.0.7') {
            throw "Marketplace publisher must preserve the allowed earlier required Wago fallback."
        }

        $foreverArchive = Join-Path $root "StatsPro-$tag-Forever-beta.zip"
        $stream = [System.IO.File]::Create($foreverArchive)
        try {
            $zip = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                foreach ($data in @(
                    @{ Name = 'StatsPro/StatsPro.toc'; Text = "## Interface: 16001`n## Version: 1.2.3`n## X-Curse-Project-ID: 1525100`n## X-Wago-ID: EGPemEN1`n" },
                    @{ Name = 'StatsPro/CHANGELOG.md'; Text = $fullChangelog }
                )) {
                    $writer = [System.IO.StreamWriter]::new($zip.CreateEntry($data.Name).Open(), [System.Text.UTF8Encoding]::new($false))
                    try { $writer.Write($data.Text) } finally { $writer.Dispose() }
                }
            } finally { $zip.Dispose() }
        } finally { $stream.Dispose() }
        $foreverSha = Get-LowercaseFileSha256 -Path $foreverArchive
        $foreverRead = {
            param($uri, $headers)
            if ($uri -eq 'https://wow.curseforge.com/api/game/wow/versions') {
                # Synthetic ID: production resolves its exact ID from authenticated API data.
                return '[{"id":1600100,"name":"1.60.1","gameVersionTypeID":88568},{"id":120100,"name":"1.60.1","gameVersionTypeID":517}]'
            }
            if ($uri -eq 'https://addons.wago.io/api/data/game') { return '{"patches":{"retail":["12.1.0"],"forever":["1.60.1"]}}' }
            return & $read $uri $headers
        }
        $foreverPath = Join-Path $root 'statspro-forever-marketplace-plan.json'
        $foreverPrepared = Prepare-MarketplacePlanHandoff -Archive $foreverArchive -Tag $tag -Sha256 $foreverSha `
            -CredentialValues $credentials -Path $foreverPath -ReadRequest $foreverRead -Flavor Forever
        $lowercaseForever = New-MarketplacePlan -Archive $foreverArchive -Tag $tag -Sha256 $foreverSha -CredentialValues $credentials -ReadRequest $foreverRead -Flavor forever
        $lowercaseForeverContext = Get-MarketplaceArchiveContext -Archive $foreverArchive -Tag $tag -Sha256 $foreverSha -CredentialValues $credentials -Flavor forever
        Assert-MarketplacePlanMatchesArchive -Plan $lowercaseForever -ArchiveContext $lowercaseForeverContext
        if ($lowercaseForeverContext.Contract.Flavor -cne 'Forever') { throw 'Lowercase Forever flavor was not canonicalized.' }
        $lowercaseRetailContext = Get-MarketplaceArchiveContext -Archive $archive -Tag $tag -Sha256 $sha -CredentialValues $credentials -Flavor retail
        if ($lowercaseRetailContext.Contract.Flavor -cne 'Retail') { throw 'Lowercase Retail flavor was not canonicalized.' }
        Assert-MarketplacePlanMatchesArchive -Plan $loadedPlan -ArchiveContext $lowercaseRetailContext
        $foreverCalls = [System.Collections.Generic.List[object]]::new()
        Publish-ExactMarketplacePlan -Archive $foreverArchive -Tag $tag -Sha256 $foreverSha -CredentialValues $credentials `
            -Plan $foreverPrepared.Plan -Flavor Forever -UploadRequest {
                param($uri, $headers, $form)
                $foreverCalls.Add([pscustomobject]@{ Uri = $uri; Metadata = ConvertFrom-JsonCompat $form.metadata })
                [pscustomobject]@{ StatusCode = 200 }
            }
        if ($foreverCalls.Count -ne 2 -or $foreverCalls[0].Metadata.label -cne "$tag-Forever-beta" -or
            $foreverCalls[0].Metadata.stability -cne 'beta' -or
            (@($foreverCalls[0].Metadata.supported_forever_patches) -join ',') -cne '1.60.1' -or
            $foreverCalls[0].Metadata.PSObject.Properties['supported_retail_patches'] -or
            $foreverCalls[1].Metadata.displayName -cne "$tag-Forever-beta" -or
            $foreverCalls[1].Metadata.releaseType -cne 'beta' -or
            (@($foreverCalls[1].Metadata.gameVersions) -join ',') -cne '1600100') { throw 'Forever exact beta upload metadata is invalid.' }
        Assert-ThrowsMatch 'Forever archive requires explicit flavor' {
            [void](New-MarketplacePlan -Archive $foreverArchive -Tag $tag -Sha256 $foreverSha -CredentialValues $credentials -ReadRequest $foreverRead)
        } 'filename'
        Assert-ThrowsMatch 'Retail plan cannot authorize Forever' {
            Publish-ExactMarketplacePlan -Archive $foreverArchive -Tag $tag -Sha256 $foreverSha -CredentialValues $credentials -Plan $loadedPlan -Flavor Forever -UploadRequest { throw 'must not upload' }
        } 'Forever flavor'
        Assert-ThrowsMatch 'Forever must reject wrong CF flavor' {
            Resolve-StatsProCurseForgeVersionIdMap -Json '[{"id":120100,"name":"1.60.1","gameVersionTypeID":517}]' -RequiredVersions @('1.60.1') -Flavor Forever
        } 'exactly one Forever'
        Assert-ThrowsMatch 'Forever must reject Wago fallback' {
            Resolve-StatsProWagoVersionSelection -Json '{"patches":{"retail":["1.60.1"],"forever":["1.60.0"]}}' -RequiredVersions @('1.60.1') -Flavor Forever
        } 'fallback is forbidden'
        Assert-ThrowsMatch 'Forever rejects duplicate CF versions' {
            Resolve-StatsProCurseForgeVersionIdMap -Json '[{"id":1,"name":"1.60.1","gameVersionTypeID":88568},{"id":2,"name":"1.60.1","gameVersionTypeID":88568}]' -RequiredVersions @('1.60.1') -Flavor Forever
        } 'exactly one Forever'
        $foreverPlanText = [System.IO.File]::ReadAllText($foreverPath)
        Write-Utf8NoBom -Path $foreverPath -Text ($foreverPlanText.Replace('"curseForgeGameVersionTypeId":88568', '"curseForgeGameVersionTypeId":517'))
        Assert-ThrowsMatch 'Forever rejects flavor plan mutation even with replaced hash' {
            Read-MarketplacePlan -Path $foreverPath -ExpectedSha256 (Get-LowercaseFileSha256 -Path $foreverPath) -Tag $tag -ArchiveSha256 $foreverSha -Flavor Forever
        } 'flavor identity'
        Assert-ThrowsMatch 'Forever rejects plan hash tampering' {
            Read-MarketplacePlan -Path $foreverPath -ExpectedSha256 $foreverPrepared.Sha256 -Tag $tag -ArchiveSha256 $foreverSha -Flavor Forever
        } 'plan SHA-256'
        Write-Utf8NoBom -Path $foreverPath -Text $foreverPlanText
        $foreverFailures = [System.Collections.Generic.List[string]]::new()
        Assert-ThrowsMatch 'Forever never retries failed upload' {
            Publish-ExactMarketplacePlan -Archive $foreverArchive -Tag $tag -Sha256 $foreverSha -CredentialValues $credentials -Plan $foreverPrepared.Plan -Flavor Forever -UploadRequest {
                param($uri, $headers, $form)
                $foreverFailures.Add($uri)
                [pscustomobject]@{ StatusCode = 503 }
            }
        } 'HTTP 503.*do not retry'
        if ($foreverFailures.Count -ne 1) { throw 'Forever retried an uncertain upload.' }

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
            -GithubOutputPath $OutputPath -Flavor $Flavor)
    }
    'Publish' {
        $plan = Read-MarketplacePlan `
            -Path $PlanPath `
            -ExpectedSha256 $ExpectedPlanSha256 `
            -Tag $ExpectedTag `
            -ArchiveSha256 $ExpectedSha256 -Flavor $Flavor
        Publish-ExactMarketplacePlan `
            -Archive $ArchivePath `
            -Tag $ExpectedTag `
            -Sha256 $ExpectedSha256 `
            -CredentialValues $environmentValues `
            -Plan $plan -Flavor $Flavor
    }
}
