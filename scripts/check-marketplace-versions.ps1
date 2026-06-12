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
        $response = Invoke-WebRequest -Uri $Uri -Headers $Headers -UseBasicParsing
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
