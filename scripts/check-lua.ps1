param(
    [switch]$Release,
    [int]$ArchonMaxAgeDays = 14,
    [switch]$AllowStaleArchonTargets,
    [string]$ToolLockPath = (Join-Path $PSScriptRoot "tool-version-locks.json"),
    [switch]$EnforceToolLocks,
    [switch]$UpdateSmokeContract,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "release-check-contract.ps1")
. (Join-Path $PSScriptRoot "tool-version-locks.ps1")
. (Join-Path $PSScriptRoot "native-process.ps1")

if ($ArchonMaxAgeDays -lt 0) {
    throw "-ArchonMaxAgeDays must be a non-negative integer."
}
if ($UpdateSmokeContract -and ($SelfTest -or $Release)) {
    throw "-UpdateSmokeContract cannot be combined with -SelfTest or -Release."
}
if ($UpdateSmokeContract -and -not $EnforceToolLocks) {
    throw "-UpdateSmokeContract requires -EnforceToolLocks so the baseline comes from the locked toolchain."
}

function Invoke-NativeCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 0,
        [string]$Description = $null,
        [switch]$IsolateLuaEnvironment,
        [hashtable]$Environment = @{}
    )

    return Invoke-StatsProNativeCapture `
        -FilePath $FilePath `
        -Arguments $Arguments `
        -TimeoutSeconds $TimeoutSeconds `
        -Description $Description `
        -IsolateLuaEnvironment:$IsolateLuaEnvironment.IsPresent `
        -Environment $Environment
}

function Write-ToolVersionReport {
    param(
        [string]$Label,
        [string]$Path,
        [string[]]$Arguments,
        [switch]$IsolateLuaEnvironment,
        [hashtable]$Environment = @{}
    )

    Write-Host "${Label}: $Path"
    $result = Invoke-NativeCapture -FilePath $Path -Arguments $Arguments -TimeoutSeconds 30 -Description "$Label version" -IsolateLuaEnvironment:$IsolateLuaEnvironment.IsPresent -Environment $Environment
    if ($result.ExitCode -eq 0) {
        Write-Host "${Label} version: $(Format-StatsProVersionOutput $result.Output)"
    }
    else {
        Write-Warning "${Label} version command exited with code $($result.ExitCode): $(Format-StatsProVersionOutput $result.Output)"
    }
}

function Assert-ToolCommandVersion {
    param(
        [string]$Label,
        [string]$Path,
        [string[]]$Arguments,
        [string]$Pattern,
        [switch]$IsolateLuaEnvironment,
        [hashtable]$Environment = @{}
    )
    $result = Invoke-NativeCapture -FilePath $Path -Arguments $Arguments -TimeoutSeconds 30 -Description "$Label version" -IsolateLuaEnvironment:$IsolateLuaEnvironment.IsPresent -Environment $Environment
    if ($result.ExitCode -ne 0) {
        throw "$Label version command exited with code $($result.ExitCode): $(Format-StatsProVersionOutput $result.Output)"
    }
    Assert-StatsProCommandVersionText -Label $Label -Text ($result.Output -join "`n") -Pattern $Pattern
}

function Assert-Lua51VersionResult {
    param(
        [string]$Label,
        [object]$Result,
        [string]$Purpose
    )

    $version = $Result.Output -join "`n"
    if ($Result.ExitCode -ne 0) {
        throw "$Label -v exited with code $($Result.ExitCode): $version"
    }
    if ($version -notmatch "Lua\s+5\.1\b") {
        throw "$Purpose requires Lua 5.1; found: $version"
    }
}

function Get-RuntimeLuaRefs {
    param([string]$MetadataCheckPath)

    $json = @(& $MetadataCheckPath -ListRuntimeLuaRefs) -join "`n"
    $refs = $json | ConvertFrom-Json
    return @($refs)
}

function Read-LuaLanguageServerDiagnostics {
    param([string]$JsonPath)

    if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) {
        throw "lua-language-server did not write JSON diagnostics to $JsonPath"
    }
    $raw = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8
    try {
        $parsed = $raw | ConvertFrom-Json
    }
    catch {
        throw "lua-language-server wrote invalid JSON diagnostics to ${JsonPath}: $($_.Exception.Message)"
    }

    $diagnostics = @()
    if ($null -eq $parsed) {
        return $diagnostics
    }
    if ($parsed -is [System.Array]) {
        foreach ($item in $parsed) {
            if ($null -ne $item) {
                $diagnostics += $item
            }
        }
        return $diagnostics
    }
    foreach ($property in $parsed.PSObject.Properties) {
        foreach ($diagnostic in @($property.Value)) {
            if ($null -eq $diagnostic) {
                continue
            }
            $diagnostics += [pscustomobject]@{
                FileUri  = $property.Name
                Code     = $diagnostic.code
                Message  = $diagnostic.message
                Severity = $diagnostic.severity
                Source   = $diagnostic.source
                Range    = $diagnostic.range
            }
        }
    }
    return $diagnostics
}

function Invoke-LuaLanguageServerCheck {
    param(
        [string]$ServerPath,
        [string]$Root,
        [string]$ConfigPath,
        [int]$TimeoutSeconds = 180,
        [string]$Description = "lua-language-server diagnostics",
        [switch]$IsolateLuaEnvironment
    )

    $logPath = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-lls-" + [System.Guid]::NewGuid().ToString("N"))
    $jsonPath = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-lls-" + [System.Guid]::NewGuid().ToString("N") + ".json")
    try {
        $result = Invoke-NativeCapture -FilePath $ServerPath -Arguments @(
            "--check=$Root",
            "--check_format=json",
            "--check_out_path=$jsonPath",
            "--checklevel=Warning",
            "--configpath=$ConfigPath",
            "--logpath=$logPath"
        ) -TimeoutSeconds $TimeoutSeconds -Description $Description -IsolateLuaEnvironment:$IsolateLuaEnvironment.IsPresent
        return [pscustomobject]@{
            ExitCode    = $result.ExitCode
            Diagnostics = @(Read-LuaLanguageServerDiagnostics -JsonPath $jsonPath)
        }
    }
    finally {
        Remove-Item -Recurse -Force $logPath -ErrorAction SilentlyContinue
        Remove-Item -Force $jsonPath -ErrorAction SilentlyContinue
    }
}

function Assert-NoLuaDiagnostics {
    param(
        [object[]]$Diagnostics,
        [int]$ExitCode,
        [switch]$Quiet
    )

    if ($Diagnostics.Count -gt 0) {
        if (-not $Quiet) {
            foreach ($diagnostic in $Diagnostics) {
                $location = $diagnostic.FileUri
                if ($diagnostic.Range -and $diagnostic.Range.start) {
                    $line = [int]$diagnostic.Range.start.line + 1
                    $character = [int]$diagnostic.Range.start.character + 1
                    $location = "$location`:$line`:$character"
                }
                Write-Host "$location $($diagnostic.Code): $($diagnostic.Message)"
            }
        }
        throw "lua-language-server reported $($Diagnostics.Count) diagnostic problem(s)"
    }
    if ($ExitCode -ne 0) {
        throw "lua-language-server exited with code $ExitCode without JSON diagnostics"
    }
}

function Assert-UndefinedFieldDiagnosticsEnabled {
    param([string]$ConfigPath)

    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Could not parse LuaLS config ${ConfigPath}: $($_.Exception.Message)"
    }
    $disabled = @($config.'diagnostics.disable')
    if ($disabled -contains "undefined-field") {
        throw "LuaLS config must keep undefined-field diagnostics enabled."
    }
}

function ConvertTo-SmokeContractPositiveInteger {
    param([object]$Value, [string]$Label)

    if ($null -eq $Value) {
        throw "$Label must be a positive integer."
    }
    $integerTypes = @(
        [System.TypeCode]::Byte,
        [System.TypeCode]::SByte,
        [System.TypeCode]::Int16,
        [System.TypeCode]::UInt16,
        [System.TypeCode]::Int32,
        [System.TypeCode]::UInt32,
        [System.TypeCode]::Int64,
        [System.TypeCode]::UInt64
    )
    if ([System.Type]::GetTypeCode($Value.GetType()) -notin $integerTypes) {
        throw "$Label must be a positive integer."
    }
    $number = [int64]$Value
    if ($number -le 0 -or $number -gt [int]::MaxValue) {
        throw "$Label must be between 1 and $([int]::MaxValue)."
    }
    return [int]$number
}

function ConvertFrom-SmokeProtocolInteger {
    param([string]$Value, [string]$Label)

    $number = 0L
    if (-not [int64]::TryParse($Value, [ref]$number) -or
        $number -le 0 -or $number -gt [int]::MaxValue) {
        throw "$Label must be a positive 32-bit integer."
    }
    return [int]$number
}

function Read-SmokeContract {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing smoke reachability contract: $Path"
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json
    }
    catch {
        throw "Could not parse smoke reachability contract ${Path}: $($_.Exception.Message)"
    }
    if ($null -eq $parsed) {
        throw "Smoke reachability contract is empty: $Path"
    }

    $rootNames = @($parsed.PSObject.Properties.Name)
    foreach ($required in @("schemaVersion", "totalAssertions", "suites")) {
        if ($rootNames -cnotcontains $required) {
            throw "Smoke reachability contract is missing '$required'."
        }
    }
    foreach ($property in $rootNames) {
        if ($property -cnotin @("schemaVersion", "totalAssertions", "suites")) {
            throw "Smoke reachability contract has unsupported root property '$property'."
        }
    }
    $schemaVersion = ConvertTo-SmokeContractPositiveInteger $parsed.schemaVersion "Smoke contract schemaVersion"
    if ($schemaVersion -ne 2) {
        throw "Unsupported smoke reachability contract schemaVersion $schemaVersion; expected 2."
    }
    $totalAssertions = ConvertTo-SmokeContractPositiveInteger `
        $parsed.totalAssertions `
        "Smoke contract totalAssertions"
    $suiteRows = @($parsed.suites)
    if ($suiteRows.Count -eq 0) {
        throw "Smoke reachability contract must define at least one suite."
    }

    $seen = @{}
    $suites = @()
    $floorSum = 0L
    foreach ($suite in $suiteRows) {
        if ($null -eq $suite) {
            throw "Smoke reachability contract contains an empty suite entry."
        }
        $suiteNames = @($suite.PSObject.Properties.Name)
        foreach ($required in @("name", "assertions", "fingerprint")) {
            if ($suiteNames -cnotcontains $required) {
                throw "Smoke reachability contract suite is missing '$required'."
            }
        }
        foreach ($property in $suiteNames) {
            if ($property -cnotin @("name", "assertions", "fingerprint")) {
                throw "Smoke reachability contract suite has unsupported property '$property'."
            }
        }
        if ($suite.name -isnot [string] -or $suite.name -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
            throw "Smoke reachability suite names must match ^[a-z0-9][a-z0-9-]*$; got '$($suite.name)'."
        }
        if ($seen.ContainsKey($suite.name)) {
            throw "Smoke reachability contract repeats suite '$($suite.name)'."
        }
        $seen[$suite.name] = $true
        $assertions = ConvertTo-SmokeContractPositiveInteger `
            $suite.assertions `
            "Smoke suite '$($suite.name)' assertions"
        if ($suite.fingerprint -isnot [string] -or
            $suite.fingerprint -cnotmatch '^[0-9a-f]{8}$') {
            throw "Smoke suite '$($suite.name)' fingerprint must be eight lowercase hexadecimal digits."
        }
        $floorSum += $assertions
        if ($floorSum -gt [int]::MaxValue) {
            throw "Smoke reachability contract assertion floors exceed the supported range."
        }
        $suites += [pscustomobject]@{
            Name = $suite.name
            Assertions = $assertions
            Fingerprint = $suite.fingerprint
        }
    }
    if ($floorSum -ne $totalAssertions) {
        throw "Smoke reachability contract totalAssertions $totalAssertions does not equal suite assertion sum $floorSum."
    }

    return [pscustomobject]@{
        SchemaVersion = $schemaVersion
        TotalAssertions = $totalAssertions
        Suites = $suites
    }
}

function Read-SmokeOutputSummary {
    param([object[]]$Output)

    $suitePrefix = "STATSPRO_SMOKE_SUITE"
    $summaryPrefix = "STATSPRO_SMOKE_SUMMARY"
    $suitePattern = '^STATSPRO_SMOKE_SUITE protocol=2 index=([0-9]+) name=([a-z0-9][a-z0-9-]*) assertions=([0-9]+) fingerprint=([0-9a-f]{8})$'
    $summaryPattern = '^STATSPRO_SMOKE_SUMMARY protocol=2 status=PASS suites=([0-9]+) assertions=([0-9]+)$'
    $suites = @()
    $seen = @{}
    $summary = $null

    foreach ($item in @($Output)) {
        $line = "$item"
        if ($line.StartsWith($suitePrefix, [System.StringComparison]::Ordinal)) {
            if ($null -ne $summary) {
                throw "Smoke suite sentinel appeared after the terminal summary."
            }
            if ($line -cnotmatch $suitePattern) {
                throw "Malformed smoke suite sentinel: $line"
            }
            $index = ConvertFrom-SmokeProtocolInteger $Matches[1] "Smoke suite index"
            $name = $Matches[2]
            $assertions = ConvertFrom-SmokeProtocolInteger $Matches[3] "Smoke suite '$name' assertion count"
            $fingerprint = $Matches[4]
            $expectedIndex = $suites.Count + 1
            if ($index -ne $expectedIndex) {
                throw "Smoke suite '$name' has index $index; expected $expectedIndex."
            }
            if ($seen.ContainsKey($name)) {
                throw "Smoke output repeats suite '$name'."
            }
            $seen[$name] = $true
            $suites += [pscustomobject]@{
                Index = $index
                Name = $name
                Assertions = $assertions
                Fingerprint = $fingerprint
            }
        }
        elseif ($line.StartsWith($summaryPrefix, [System.StringComparison]::Ordinal)) {
            if ($line -cnotmatch $summaryPattern) {
                throw "Malformed smoke terminal summary: $line"
            }
            if ($null -ne $summary) {
                throw "Smoke output contains more than one terminal summary."
            }
            $summary = [pscustomobject]@{
                SuiteCount = ConvertFrom-SmokeProtocolInteger $Matches[1] "Smoke terminal suite count"
                TotalAssertions = ConvertFrom-SmokeProtocolInteger $Matches[2] "Smoke terminal assertion count"
            }
        }
    }

    if ($null -eq $summary) {
        throw "Smoke output is missing the terminal STATSPRO_SMOKE_SUMMARY line."
    }
    if ($suites.Count -eq 0) {
        throw "Smoke output is missing STATSPRO_SMOKE_SUITE sentinels."
    }
    if ($summary.SuiteCount -ne $suites.Count) {
        throw "Smoke terminal summary reports $($summary.SuiteCount) suites, but $($suites.Count) completed suite sentinels were emitted."
    }
    $sum = 0L
    foreach ($suite in $suites) {
        $sum += $suite.Assertions
    }
    if ($sum -ne $summary.TotalAssertions) {
        throw "Smoke suite assertions sum to $sum, but the terminal summary reports $($summary.TotalAssertions)."
    }

    return [pscustomobject]@{
        Suites = $suites
        SuiteCount = $summary.SuiteCount
        TotalAssertions = $summary.TotalAssertions
    }
}

function Assert-SmokeContract {
    param(
        [object]$Summary,
        [object]$Contract
    )

    if ($Summary.SuiteCount -ne $Contract.Suites.Count) {
        throw "Smoke completed $($Summary.SuiteCount) suites; the contract requires $($Contract.Suites.Count)."
    }
    for ($index = 0; $index -lt $Contract.Suites.Count; $index++) {
        $observed = $Summary.Suites[$index]
        $expected = $Contract.Suites[$index]
        if ($observed.Name -cne $expected.Name) {
            throw "Smoke suite $($index + 1) is '$($observed.Name)'; the contract requires '$($expected.Name)'."
        }
        if ($observed.Assertions -ne $expected.Assertions) {
            throw "Smoke suite '$($expected.Name)' completed $($observed.Assertions) assertions; the contract requires exactly $($expected.Assertions)."
        }
        if ($observed.Fingerprint -cne $expected.Fingerprint) {
            throw "Smoke suite '$($expected.Name)' assertion fingerprint '$($observed.Fingerprint)' does not match contract '$($expected.Fingerprint)'."
        }
    }
    if ($Summary.TotalAssertions -ne $Contract.TotalAssertions) {
        throw "Smoke completed $($Summary.TotalAssertions) assertions; the contract requires exactly $($Contract.TotalAssertions)."
    }
}

function ConvertTo-SmokeContractJson {
    param([object]$Summary)

    $suiteRows = @($Summary.Suites | ForEach-Object {
        [ordered]@{
            name = $_.Name
            assertions = [int]$_.Assertions
            fingerprint = $_.Fingerprint
        }
    })
    $document = [ordered]@{
        schemaVersion = 2
        totalAssertions = [int]$Summary.TotalAssertions
        suites = $suiteRows
    }
    return ($document | ConvertTo-Json -Depth 4)
}

function Write-SmokeContract {
    param(
        [string]$Path,
        [object]$Summary
    )

    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory ("smoke-contract." + [System.Guid]::NewGuid().ToString("N") + ".tmp")
    $backup = Join-Path $directory ("smoke-contract." + [System.Guid]::NewGuid().ToString("N") + ".bak")
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($temporary, (ConvertTo-SmokeContractJson $Summary) + "`n", $utf8NoBom)
        $roundTrip = Read-SmokeContract -Path $temporary
        Assert-SmokeContract -Summary $Summary -Contract $roundTrip
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $Path, $backup)
        }
        else {
            [System.IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Force
        }
    }
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ArchonTargetsFile = Join-Path $RepoRoot "StatsPro_ArchonTargets.lua"
$SmokeFile = Join-Path $RepoRoot "scripts\smoke.lua"
$SmokeContractFile = Join-Path $RepoRoot "scripts\smoke-contract.json"
$MetadataCheck = Join-Path $RepoRoot "scripts\check-metadata.ps1"
$ArchonTargetsCheck = Join-Path $RepoRoot "scripts\check-archon-targets.lua"
$LuaGlobalStub = Join-Path $RepoRoot "scripts\types\wow-globals.d.lua"

function Invoke-SelfTest {
    & $MetadataCheck -SelfTest

    $lua51Version = [pscustomobject]@{ ExitCode = 0; Output = @("Lua 5.1.5") }
    Assert-Lua51VersionResult -Label "lua" -Result $lua51Version -Purpose "StatsPro smoke"
    Assert-Lua51VersionResult -Label "luac" -Result $lua51Version -Purpose "StatsPro syntax check"
    Assert-ThrowsMatch "non-5.1 luac rejected" {
        Assert-Lua51VersionResult `
            -Label "luac" `
            -Result ([pscustomobject]@{ ExitCode = 0; Output = @("Lua 5.10.0") }) `
            -Purpose "StatsPro syntax check"
    } "requires Lua 5.1"

    $smokeFixtureContract = [pscustomobject]@{
        SchemaVersion = 2
        TotalAssertions = 5
        Suites = @(
            [pscustomobject]@{ Name = "alpha"; Assertions = 2; Fingerprint = "aaaaaaaa" },
            [pscustomobject]@{ Name = "beta"; Assertions = 3; Fingerprint = "bbbbbbbb" }
        )
    }
    $validSmokeOutput = @(
        "unrelated diagnostic output",
        "STATSPRO_SMOKE_SUITE protocol=2 index=1 name=alpha assertions=2 fingerprint=aaaaaaaa",
        "STATSPRO_SMOKE_SUITE protocol=2 index=2 name=beta assertions=3 fingerprint=bbbbbbbb",
        "STATSPRO_SMOKE_SUMMARY protocol=2 status=PASS suites=2 assertions=5",
        "StatsPro smoke: PASS (5 assertions)"
    )
    $validSmokeSummary = Read-SmokeOutputSummary -Output $validSmokeOutput
    Assert-SmokeContract -Summary $validSmokeSummary -Contract $smokeFixtureContract

    $growthSmokeSummary = Read-SmokeOutputSummary -Output @(
        "STATSPRO_SMOKE_SUITE protocol=2 index=1 name=alpha assertions=4 fingerprint=cccccccc",
        "STATSPRO_SMOKE_SUITE protocol=2 index=2 name=beta assertions=6 fingerprint=dddddddd",
        "STATSPRO_SMOKE_SUMMARY protocol=2 status=PASS suites=2 assertions=10"
    )
    Assert-ThrowsMatch "smoke assertion growth requires contract update" {
        Assert-SmokeContract -Summary $growthSmokeSummary -Contract $smokeFixtureContract
    } "requires exactly 2"

    Assert-ThrowsMatch "missing smoke suite rejected" {
        $summary = Read-SmokeOutputSummary -Output @(
            "STATSPRO_SMOKE_SUITE protocol=2 index=1 name=alpha assertions=5 fingerprint=aaaaaaaa",
            "STATSPRO_SMOKE_SUMMARY protocol=2 status=PASS suites=1 assertions=5"
        )
        Assert-SmokeContract -Summary $summary -Contract $smokeFixtureContract
    } "contract requires 2"
    Assert-ThrowsMatch "truncated smoke output rejected" {
        [void](Read-SmokeOutputSummary -Output @(
            "STATSPRO_SMOKE_SUITE protocol=2 index=1 name=alpha assertions=2 fingerprint=aaaaaaaa",
            "STATSPRO_SMOKE_SUITE protocol=2 index=2 name=beta assertions=3 fingerprint=bbbbbbbb"
        ))
    } "missing the terminal"
    Assert-ThrowsMatch "smoke suite count mismatch rejected" {
        $summary = Read-SmokeOutputSummary -Output @(
            "STATSPRO_SMOKE_SUITE protocol=2 index=1 name=alpha assertions=1 fingerprint=aaaaaaaa",
            "STATSPRO_SMOKE_SUITE protocol=2 index=2 name=beta assertions=3 fingerprint=bbbbbbbb",
            "STATSPRO_SMOKE_SUMMARY protocol=2 status=PASS suites=2 assertions=4"
        )
        Assert-SmokeContract -Summary $summary -Contract $smokeFixtureContract
    } "requires exactly 2"
    Assert-ThrowsMatch "smoke fingerprint mismatch rejected" {
        $summary = Read-SmokeOutputSummary -Output @(
            "STATSPRO_SMOKE_SUITE protocol=2 index=1 name=alpha assertions=2 fingerprint=cccccccc",
            "STATSPRO_SMOKE_SUITE protocol=2 index=2 name=beta assertions=3 fingerprint=bbbbbbbb",
            "STATSPRO_SMOKE_SUMMARY protocol=2 status=PASS suites=2 assertions=5"
        )
        Assert-SmokeContract -Summary $summary -Contract $smokeFixtureContract
    } "fingerprint 'cccccccc' does not match"
    Assert-ThrowsMatch "duplicate smoke suite rejected" {
        [void](Read-SmokeOutputSummary -Output @(
            "STATSPRO_SMOKE_SUITE protocol=2 index=1 name=alpha assertions=2 fingerprint=aaaaaaaa",
            "STATSPRO_SMOKE_SUITE protocol=2 index=2 name=alpha assertions=3 fingerprint=bbbbbbbb",
            "STATSPRO_SMOKE_SUMMARY protocol=2 status=PASS suites=2 assertions=5"
        ))
    } "repeats suite"
    Assert-ThrowsMatch "reordered smoke suite rejected" {
        $summary = Read-SmokeOutputSummary -Output @(
            "STATSPRO_SMOKE_SUITE protocol=2 index=1 name=beta assertions=3 fingerprint=bbbbbbbb",
            "STATSPRO_SMOKE_SUITE protocol=2 index=2 name=alpha assertions=2 fingerprint=aaaaaaaa",
            "STATSPRO_SMOKE_SUMMARY protocol=2 status=PASS suites=2 assertions=5"
        )
        Assert-SmokeContract -Summary $summary -Contract $smokeFixtureContract
    } "contract requires 'alpha'"
    Assert-ThrowsMatch "smoke suite sum mismatch rejected" {
        [void](Read-SmokeOutputSummary -Output @(
            "STATSPRO_SMOKE_SUITE protocol=2 index=1 name=alpha assertions=2 fingerprint=aaaaaaaa",
            "STATSPRO_SMOKE_SUITE protocol=2 index=2 name=beta assertions=3 fingerprint=bbbbbbbb",
            "STATSPRO_SMOKE_SUMMARY protocol=2 status=PASS suites=2 assertions=6"
        ))
    } "sum to 5"
    Assert-ThrowsMatch "legacy smoke summary alone rejected" {
        [void](Read-SmokeOutputSummary -Output @("StatsPro smoke: PASS (5 assertions)"))
    } "missing the terminal"
    Assert-ThrowsMatch "uppercase smoke suite name rejected" {
        [void](Read-SmokeOutputSummary -Output @(
            "STATSPRO_SMOKE_SUITE protocol=2 index=1 name=Alpha assertions=2 fingerprint=aaaaaaaa",
            "STATSPRO_SMOKE_SUMMARY protocol=2 status=PASS suites=1 assertions=2"
        ))
    } "Malformed smoke suite sentinel"
    Assert-ThrowsMatch "lowercase smoke status rejected" {
        [void](Read-SmokeOutputSummary -Output @(
            "STATSPRO_SMOKE_SUITE protocol=2 index=1 name=alpha assertions=2 fingerprint=aaaaaaaa",
            "STATSPRO_SMOKE_SUMMARY protocol=2 status=pass suites=1 assertions=2"
        ))
    } "Malformed smoke terminal summary"

    $realSmokeContract = Read-SmokeContract -Path $SmokeContractFile
    if ($realSmokeContract.Suites.Count -lt 2) {
        throw "Tracked smoke reachability contract must contain multiple named suites."
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-lua-check-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    try {
        $smokeContractFixturePath = Join-Path $root "smoke-contract.json"
        Write-SmokeContract -Path $smokeContractFixturePath -Summary $validSmokeSummary
        Write-SmokeContract -Path $smokeContractFixturePath -Summary $growthSmokeSummary
        $writtenSmokeContract = Read-SmokeContract -Path $smokeContractFixturePath
        Assert-SmokeContract -Summary $growthSmokeSummary -Contract $writtenSmokeContract
        if ($writtenSmokeContract.TotalAssertions -ne 10) {
            throw "atomic smoke contract replacement did not publish the updated summary"
        }

        $cmd = Get-Command cmd.exe -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
        $nativeCapture = Invoke-NativeCapture -FilePath $cmd -Arguments @("/d", "/c", "echo stdout-line&&echo stderr-line>&2&&exit /b 7") -TimeoutSeconds 10 -Description "native capture self-test"
        if ($nativeCapture.ExitCode -ne 7) {
            throw "native capture should preserve nonzero exit code 7, got $($nativeCapture.ExitCode)"
        }
        if (($nativeCapture.Output -join "|") -ne "stdout-line|stderr-line") {
            throw "native capture should return stdout before stderr, got: $($nativeCapture.Output -join '|')"
        }

        $argumentFixture = Join-Path $root "native argument fixture.ps1"
        [System.IO.File]::WriteAllText($argumentFixture, @'
param([string]$Value, [AllowEmptyString()][string]$EmptyValue)
[Console]::Out.WriteLine("value:" + $Value)
[Console]::Out.WriteLine("")
[Console]::Out.WriteLine("empty:" + $EmptyValue.Length)
'@)
        $hostExecutable = (Get-Process -Id $PID).MainModule.FileName
        $argumentValue = 'space "quote" trailing\'
        $argumentCapture = Invoke-NativeCapture `
            -FilePath $hostExecutable `
            -Arguments @(
                "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $argumentFixture,
                "-Value", $argumentValue, "-EmptyValue", ""
            ) `
            -TimeoutSeconds 10 `
            -Description "native argument self-test"
        if (($argumentCapture.Output -join "|") -ne "value:$argumentValue|empty:0") {
            throw "native capture did not preserve quoted, trailing-backslash, or empty arguments, or did not remove empty output lines: $($argumentCapture.Output -join '|')"
        }

        $oldNativeLuaInit = [Environment]::GetEnvironmentVariable("LUA_INIT", "Process")
        try {
            [Environment]::SetEnvironmentVariable("LUA_INIT", "ambient-native-canary", "Process")
            $inheritedEnvironment = Invoke-NativeCapture `
                -FilePath $cmd `
                -Arguments @("/d", "/c", "echo %LUA_INIT%") `
                -TimeoutSeconds 10 `
                -Description "inherited Lua environment self-test"
            if (($inheritedEnvironment.Output -join "|") -ne "ambient-native-canary") {
                throw "native capture without isolation did not preserve the ambient Lua environment"
            }
            $overrideEnvironment = Invoke-NativeCapture `
                -FilePath $cmd `
                -Arguments @("/d", "/c", "echo %LUA_INIT%") `
                -TimeoutSeconds 10 `
                -Description "isolated Lua environment override self-test" `
                -IsolateLuaEnvironment `
                -Environment @{ LUA_INIT = "explicit-native-override" }
            if (($overrideEnvironment.Output -join "|") -ne "explicit-native-override") {
                throw "native capture isolation did not apply the explicit Lua environment override"
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable("LUA_INIT", $oldNativeLuaInit, "Process")
        }

        $selfTestLocks = Read-StatsProToolLocks -Path $ToolLockPath
        $selfTestOwnedTools = Read-StatsProOwnedToolManifest -Locks $selfTestLocks
        $wrongShadowRoot = Join-Path $root "wrong-version-shadow"
        $sameShadowRoot = Join-Path $root "same-version-shadow"
        $wrongShadowMarker = Join-Path $root "wrong-version.marker"
        $sameShadowMarker = Join-Path $root "same-version.marker"
        New-Item -ItemType Directory -Path $wrongShadowRoot, $sameShadowRoot -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $wrongShadowRoot "lua-language-server.cmd"),
            "@echo off`r`n> `"$wrongShadowMarker`" echo wrong`r`necho 3.18.2-dev`r`n")
        [System.IO.File]::WriteAllText(
            (Join-Path $sameShadowRoot "lua-language-server.cmd"),
            "@echo off`r`n> `"$sameShadowMarker`" echo same`r`necho 3.18.1`r`n")
        $oldPath = $env:PATH
        try {
            foreach ($shadowRoot in @($wrongShadowRoot, $sameShadowRoot)) {
                $env:PATH = $shadowRoot + [System.IO.Path]::PathSeparator + $oldPath
                $resolvedOwned = Read-StatsProOwnedToolManifest -Locks $selfTestLocks
                $versionResult = Invoke-NativeCapture `
                    -FilePath $resolvedOwned.LuaLanguageServerPath `
                    -Arguments @("--version") `
                    -TimeoutSeconds 30 `
                    -Description "owned LuaLS shadow regression" `
                    -IsolateLuaEnvironment
                if ($versionResult.ExitCode -ne 0 -or
                    ($versionResult.Output -join "`n") -notmatch '^3\.18\.1(?:\s|$)' -or
                    (Test-Path -LiteralPath $wrongShadowMarker) -or
                    (Test-Path -LiteralPath $sameShadowMarker)) {
                    throw "canonical enforced resolution executed an ambient LuaLS shadow"
                }
            }
        }
        finally {
            $env:PATH = $oldPath
        }

        $ambientInitMarker = Join-Path $root "ambient-init.marker"
        $ambientModuleMarker = Join-Path $root "ambient-module.marker"
        $ambientInit = Join-Path $root "ambient-init.lua"
        $ambientModules = Join-Path $root "ambient-modules"
        $ambientLuacheck = Join-Path $ambientModules "luacheck"
        New-Item -ItemType Directory -Path $ambientLuacheck -Force | Out-Null
        [System.IO.File]::WriteAllText(
            $ambientInit,
            "local f=assert(io.open([[$ambientInitMarker]], [[w]])); f:write([[leak]]); f:close()")
        [System.IO.File]::WriteAllText(
            (Join-Path $ambientLuacheck "main.lua"),
            "local f=assert(io.open([[$ambientModuleMarker]], [[w]])); f:write([[leak]]); f:close(); os.exit(0)")
        $oldLuaInit = $env:LUA_INIT
        $oldLuaPath = $env:LUA_PATH
        $oldLuaCPath = $env:LUA_CPATH
        try {
            $env:LUA_INIT = "@$ambientInit"
            $env:LUA_PATH = (Join-Path $ambientModules "?.lua")
            $env:LUA_CPATH = (Join-Path $ambientModules "?.dll")
            $luaCanaryResult = Invoke-NativeCapture `
                -FilePath $selfTestOwnedTools.LuaPath `
                -Arguments @("-v") `
                -TimeoutSeconds 30 `
                -Description "owned Lua environment regression" `
                -IsolateLuaEnvironment
            if ($luaCanaryResult.ExitCode -ne 0 -or (Test-Path -LiteralPath $ambientInitMarker)) {
                throw "owned Lua executed ambient LUA_INIT"
            }
            $luacheckCanaryResult = Invoke-NativeCapture `
                -FilePath $selfTestOwnedTools.LuaRocksLuaPath `
                -Arguments @($selfTestOwnedTools.LuacheckScriptPath, "--version") `
                -TimeoutSeconds 30 `
                -Description "owned luacheck environment regression" `
                -IsolateLuaEnvironment `
                -Environment $selfTestOwnedTools.LuacheckEnvironment
            if ($luacheckCanaryResult.ExitCode -ne 0 -or
                ($luacheckCanaryResult.Output -join "`n") -notmatch '^Luacheck:\s+1\.2\.0' -or
                (Test-Path -LiteralPath $ambientInitMarker) -or
                (Test-Path -LiteralPath $ambientModuleMarker)) {
                throw "owned luacheck executed an ambient Lua init or module"
            }
        }
        finally {
            $env:LUA_INIT = $oldLuaInit
            $env:LUA_PATH = $oldLuaPath
            $env:LUA_CPATH = $oldLuaCPath
        }

        Push-Location -Path $root
        try {
            $cwdCapture = Invoke-NativeCapture -FilePath $cmd -Arguments @("/d", "/c", "cd") -TimeoutSeconds 10 -Description "native working-directory self-test"
        }
        finally {
            Pop-Location
        }
        $childCwd = ($cwdCapture.Output | Select-Object -First 1)
        if ([System.IO.Path]::GetFullPath($childCwd) -ne [System.IO.Path]::GetFullPath($root)) {
            throw "native capture should run from the current PowerShell location; got <$childCwd>, expected <$root>"
        }

        $ping = Get-Command ping.exe -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
        Assert-ThrowsMatch "native timeout rejected" {
            [void](Invoke-NativeCapture -FilePath $ping -Arguments @("-n", "6", "127.0.0.1") -TimeoutSeconds 1 -Description "native timeout self-test")
        } "Timed out"

        $emptyPath = Join-Path $root "empty.json"
        Set-Content -Path $emptyPath -Value "[]" -Encoding UTF8
        $emptyDiagnostics = @(Read-LuaLanguageServerDiagnostics -JsonPath $emptyPath)
        if ($emptyDiagnostics.Count -ne 0) {
            throw "empty JSON diagnostics should produce zero diagnostics"
        }
        Assert-NoLuaDiagnostics -Diagnostics $emptyDiagnostics -ExitCode 0

        $objectPath = Join-Path $root "object.json"
        Set-Content -Path $objectPath -Value @"
{
  "file:///c%3A/StatsPro/StatsPro.lua": [
    {
      "code": "undefined-global",
      "message": "Undefined global `GameTooltip`.",
      "severity": 2,
      "source": "Lua Diagnostics.",
      "range": {
        "start": { "line": 4, "character": 2 },
        "end": { "line": 4, "character": 13 }
      }
    }
  ]
}
"@ -Encoding UTF8
        $objectDiagnostics = @(Read-LuaLanguageServerDiagnostics -JsonPath $objectPath)
        if ($objectDiagnostics.Count -ne 1) {
            throw "URI-keyed JSON diagnostics should produce one diagnostic"
        }
        Assert-ThrowsMatch "diagnostics are rejected" {
            Assert-NoLuaDiagnostics -Diagnostics $objectDiagnostics -ExitCode 1 -Quiet
        } "1 diagnostic"

        Assert-ThrowsMatch "missing JSON rejected" {
            [void](Read-LuaLanguageServerDiagnostics -JsonPath (Join-Path $root "missing.json"))
        } "did not write JSON"

        $invalidPath = Join-Path $root "invalid.json"
        Set-Content -Path $invalidPath -Value "not-json" -Encoding UTF8
        Assert-ThrowsMatch "invalid JSON rejected" {
            [void](Read-LuaLanguageServerDiagnostics -JsonPath $invalidPath)
        } "invalid JSON"

        Assert-ThrowsMatch "nonzero exit without diagnostics rejected" {
            Assert-NoLuaDiagnostics -Diagnostics @() -ExitCode 1
        } "without JSON diagnostics"

        if (-not (Test-Path -LiteralPath $LuaGlobalStub -PathType Leaf)) {
            throw "Missing LuaLS WoW/global definition file: $LuaGlobalStub"
        }
        Assert-UndefinedFieldDiagnosticsEnabled -ConfigPath (Join-Path $RepoRoot ".luarc.json")
        $luaLanguageServer = $selfTestOwnedTools.LuaLanguageServerPath
        $fieldFixtureRoot = Join-Path $root "undefined-field"
        $fieldFixtureTypes = Join-Path $fieldFixtureRoot "scripts\types"
        New-Item -ItemType Directory -Path $fieldFixtureTypes -Force | Out-Null
        Copy-Item -LiteralPath $LuaGlobalStub -Destination (Join-Path $fieldFixtureTypes "wow-globals.d.lua")
        Copy-Item -LiteralPath (Join-Path $RepoRoot ".luarc.json") -Destination (Join-Path $fieldFixtureRoot ".luarc.json")
        Set-Content -LiteralPath (Join-Path $fieldFixtureRoot "field-typo.lua") -Value @'
---@class FieldContract
---@field retryScheduled boolean
---@type FieldContract
local state = { retryScheduled = true }
local picker = _G.StatsProFontPicker
if picker then
    picker:IsShown()
    picker:Hide()
    picker:IsShwon()
end
local definition = _G.StaticPopupDialogs["STATSPRO_FIXTURE"]
definition.button1 = definition.buton1
local globalTypo = _G.StatsProFontPickre
local maxSchoolsTypo = _G.MAX_SPELL_SCHOOL
local specInfoByID = _G.GetSpecializationInfoByID
local specInfoByIDTypo = _G.GetSpecializationInfoById
local suffix = "Text"
local dynamic = _G["StatsProVisibleCheck" .. suffix]
return state.retrySchedueld or globalTypo or maxSchoolsTypo
    or specInfoByID or specInfoByIDTypo or dynamic
'@ -Encoding UTF8
        $fieldCheck = Invoke-LuaLanguageServerCheck `
            -ServerPath $luaLanguageServer `
            -Root $fieldFixtureRoot `
            -ConfigPath (Join-Path $fieldFixtureRoot ".luarc.json") `
            -TimeoutSeconds 60 `
            -Description "undefined-field regression fixture" `
            -IsolateLuaEnvironment
        $undefinedFieldDiagnostics = @($fieldCheck.Diagnostics | Where-Object { $_.Code -eq "undefined-field" })
        $fieldMessages = $undefinedFieldDiagnostics.Message -join "`n"
        if ($fieldCheck.ExitCode -eq 0 -or $fieldCheck.Diagnostics.Count -ne 6 -or
            $undefinedFieldDiagnostics.Count -ne 6 -or
            $fieldMessages -notmatch "retrySchedueld" -or
            $fieldMessages -notmatch "StatsProFontPickre" -or
            $fieldMessages -notmatch "MAX_SPELL_SCHOOL" -or
            $fieldMessages -notmatch "IsShwon" -or
            $fieldMessages -notmatch "buton1" -or
            $fieldMessages -notmatch "GetSpecializationInfoById") {
            $summary = @($fieldCheck.Diagnostics | ForEach-Object { "$($_.Code): $($_.Message)" }) -join " | "
            throw "LuaLS field-typo fixture must report only the six intentional field typos; exit=$($fieldCheck.ExitCode), diagnostics=$summary"
        }
    }
    finally {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
    Write-Host "Lua check self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

$GateOwnedToolRoot = if ($EnforceToolLocks) { New-StatsProOwnedToolInvocationRoot } else { $null }
$LocationPushed = $false
try {
Push-Location -Path $RepoRoot
$LocationPushed = $true

$ToolLocks = $null
$OwnedLayout = $null
if ($EnforceToolLocks) {
    & (Join-Path $PSScriptRoot "install-check-tools.ps1") `
        -Install `
        -EnforceToolLocks `
        -ToolLockPath $ToolLockPath `
        -OwnedToolRoot $GateOwnedToolRoot `
        -EphemeralOwnedToolRoot
    $ToolLocks = Read-StatsProToolLocks -Path $ToolLockPath
    $OwnedLayout = Get-StatsProOwnedToolLayout -Locks $ToolLocks -ToolRoot $GateOwnedToolRoot
    $OwnedTools = Read-StatsProOwnedToolManifest -Locks $ToolLocks -Layout $OwnedLayout
    $Lua = $OwnedTools.LuaPath
    $Luac = $OwnedTools.LuacPath
    $LuaLanguageServer = $OwnedTools.LuaLanguageServerPath
    $Luacheck = $OwnedTools.LuacheckScriptPath
    $LuacheckCommand = $OwnedTools.LuaRocksLuaPath
    $LuacheckArgumentsPrefix = @($Luacheck)
    $LuacheckEnvironment = $OwnedTools.LuacheckEnvironment
}
else {
    $LuacCandidates = @(
        if ($env:STATSPRO_PINNED_LUA_ROOT) { Join-Path $env:STATSPRO_PINNED_LUA_ROOT "luac5.1.exe" }
        (Get-Command luac5.1 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
        (Get-Command luac -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
        "C:\ProgramData\chocolatey\lib\lua51\tools\luac5.1.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }
    $Luac = $LuacCandidates | Select-Object -First 1
    if (-not $Luac) {
        throw "Missing luac 5.1. Install the pinned toolchain with: .\scripts\install-check-tools.ps1 -Install"
    }

    $LuaCandidates = @(
        if ($env:STATSPRO_PINNED_LUA_ROOT) { Join-Path $env:STATSPRO_PINNED_LUA_ROOT "lua5.1.exe" }
        (Get-Command lua5.1 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
        (Get-Command lua -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
        "C:\ProgramData\chocolatey\lib\lua51\tools\lua5.1.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }
    $Lua = $LuaCandidates | Select-Object -First 1
    if (-not $Lua) {
        throw "Missing lua 5.1 runtime. Install the pinned toolchain with: .\scripts\install-check-tools.ps1 -Install"
    }

    $LuaLanguageServer = Get-Command lua-language-server -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source
    if (-not $LuaLanguageServer) {
        throw "Missing lua-language-server. Run: .\scripts\install-check-tools.ps1 -Install"
    }

    $LuacheckCandidates = @(
        (Get-Command luacheck -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
        "C:\ProgramData\chocolatey\lib\luarocks\luarocks-2.4.4-win32\systree\bin\luacheck.bat"
    ) | Where-Object { $_ -and (Test-Path $_) }
    $Luacheck = $LuacheckCandidates | Select-Object -First 1
    if (-not $Luacheck) {
        throw "Missing luacheck. Run: .\scripts\install-check-tools.ps1 -Install"
    }
    $LuacheckCommand = $Luacheck
    $LuacheckArgumentsPrefix = @()
    $LuacheckEnvironment = @{}
}

$LuaVersionResult = Invoke-NativeCapture -FilePath $Lua -Arguments @("-v") -TimeoutSeconds 10 -Description "lua -v" -IsolateLuaEnvironment:$EnforceToolLocks.IsPresent
Assert-Lua51VersionResult -Label "lua" -Result $LuaVersionResult -Purpose "StatsPro smoke"
$LuacVersionResult = Invoke-NativeCapture -FilePath $Luac -Arguments @("-v") -TimeoutSeconds 10 -Description "luac -v" -IsolateLuaEnvironment:$EnforceToolLocks.IsPresent
Assert-Lua51VersionResult -Label "luac" -Result $LuacVersionResult -Purpose "StatsPro syntax check"

Write-Host "== Tool versions =="
Write-ToolVersionReport -Label "lua" -Path $Lua -Arguments @("-v") -IsolateLuaEnvironment:$EnforceToolLocks.IsPresent
Write-ToolVersionReport -Label "luac" -Path $Luac -Arguments @("-v") -IsolateLuaEnvironment:$EnforceToolLocks.IsPresent
Write-ToolVersionReport -Label "lua-language-server" -Path $LuaLanguageServer -Arguments @("--version") -IsolateLuaEnvironment:$EnforceToolLocks.IsPresent
Write-ToolVersionReport -Label "luacheck" -Path $LuacheckCommand -Arguments ($LuacheckArgumentsPrefix + @("--version")) -IsolateLuaEnvironment:$EnforceToolLocks.IsPresent -Environment $LuacheckEnvironment

if ($EnforceToolLocks) {
    Assert-ToolCommandVersion -Label "lua" -Path $Lua -Arguments @("-v") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "lua5.1") -IsolateLuaEnvironment
    Assert-ToolCommandVersion -Label "luac" -Path $Luac -Arguments @("-v") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "luac5.1") -IsolateLuaEnvironment
    Assert-ToolCommandVersion -Label "lua-language-server" -Path $LuaLanguageServer -Arguments @("--version") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "lua-language-server") -IsolateLuaEnvironment
    Assert-ToolCommandVersion -Label "luacheck" -Path $LuacheckCommand -Arguments ($LuacheckArgumentsPrefix + @("--version")) -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "luacheck") -IsolateLuaEnvironment -Environment $LuacheckEnvironment
    Write-Host "Tool command version locks enforced."
}

& $MetadataCheck

$RuntimeLuaRefs = @(Get-RuntimeLuaRefs -MetadataCheckPath $MetadataCheck)

Write-Host "== Lua syntax =="
$SyntaxFiles = @($RuntimeLuaRefs | ForEach-Object { $_.FullPath })
if (Test-Path $ArchonTargetsCheck) { $SyntaxFiles += $ArchonTargetsCheck }
$SyntaxFiles += $SmokeFile
$SyntaxResult = Invoke-NativeCapture `
    -FilePath $Luac `
    -Arguments (@("-p") + $SyntaxFiles) `
    -TimeoutSeconds 60 `
    -Description "Lua syntax" `
    -IsolateLuaEnvironment:$EnforceToolLocks.IsPresent
$SyntaxResult.Output | ForEach-Object { Write-Host $_ }
if ($SyntaxResult.ExitCode -ne 0) {
    throw "luac exited with code $($SyntaxResult.ExitCode)"
}

if (Test-Path $ArchonTargetsFile) {
    Write-Host "== Archon target snapshot =="
    if (-not (Test-Path $ArchonTargetsCheck)) {
        throw "Missing Archon target validator: $ArchonTargetsCheck"
    }
    $ArchonArgs = @($ArchonTargetsCheck, "--path", $ArchonTargetsFile)
    if ($Release) {
        if ($AllowStaleArchonTargets -or $env:STATSPRO_ALLOW_STALE_ARCHON_TARGETS -eq "1") {
            Write-Warning "Allowing stale Archon targets because an explicit stale-data override is set."
            $ArchonArgs += "--allow-stale"
        }
        else {
            $ArchonArgs += @("--max-age-days", $ArchonMaxAgeDays)
        }
    }
    $ArchonResult = Invoke-NativeCapture -FilePath $Lua -Arguments $ArchonArgs -TimeoutSeconds 30 -Description "Archon target snapshot check" -IsolateLuaEnvironment:$EnforceToolLocks.IsPresent
    $ArchonResult.Output | ForEach-Object { Write-Host $_ }
    if ($ArchonResult.ExitCode -ne 0) {
        throw "Archon target snapshot check exited with code $($ArchonResult.ExitCode)"
    }
}

Write-Host "== Lua smoke =="
$SmokeResult = Invoke-NativeCapture `
    -FilePath $Lua `
    -Arguments @($SmokeFile) `
    -TimeoutSeconds 180 `
    -Description "Lua smoke" `
    -IsolateLuaEnvironment:$EnforceToolLocks.IsPresent
$SmokeResult.Output | ForEach-Object { Write-Host $_ }
if ($SmokeResult.ExitCode -ne 0) {
    throw "Lua smoke exited with code $($SmokeResult.ExitCode)"
}
$SmokeSummary = Read-SmokeOutputSummary -Output $SmokeResult.Output
if (-not $UpdateSmokeContract) {
    $SmokeContract = Read-SmokeContract -Path $SmokeContractFile
    Assert-SmokeContract -Summary $SmokeSummary -Contract $SmokeContract
    Write-Host "Smoke reachability contract passed: $($SmokeSummary.SuiteCount) suites, $($SmokeSummary.TotalAssertions) assertions."
}

$StaticAnalysisFiles = @(
    $RuntimeLuaRefs |
        Where-Object { -not $_.IsVendored -and -not $_.IsGenerated } |
        ForEach-Object { $_.FullPath }
)
if ($StaticAnalysisFiles.Count -eq 0) {
    throw "No first-party runtime Lua files available for static analysis."
}

Write-Host "== Luacheck =="
$LuacheckResult = Invoke-NativeCapture `
    -FilePath $LuacheckCommand `
    -Arguments ($LuacheckArgumentsPrefix + $StaticAnalysisFiles) `
    -TimeoutSeconds 180 `
    -Description "luacheck" `
    -IsolateLuaEnvironment:$EnforceToolLocks.IsPresent `
    -Environment $LuacheckEnvironment
$LuacheckResult.Output | ForEach-Object { Write-Host $_ }
if ($LuacheckResult.ExitCode -ne 0) {
    throw "luacheck exited with code $($LuacheckResult.ExitCode)"
}

Write-Host "== Lua diagnostics =="
Write-Host "-- $RepoRoot"
Assert-UndefinedFieldDiagnosticsEnabled -ConfigPath (Join-Path $RepoRoot ".luarc.json")
$LuaLanguageServerResult = Invoke-LuaLanguageServerCheck `
    -ServerPath $LuaLanguageServer `
    -Root $RepoRoot `
    -ConfigPath (Join-Path $RepoRoot ".luarc.json") `
    -TimeoutSeconds 180 `
    -Description "lua-language-server diagnostics for $RepoRoot" `
    -IsolateLuaEnvironment:$EnforceToolLocks.IsPresent
Assert-NoLuaDiagnostics `
    -Diagnostics @($LuaLanguageServerResult.Diagnostics) `
    -ExitCode $LuaLanguageServerResult.ExitCode

if ($UpdateSmokeContract) {
    Write-SmokeContract -Path $SmokeContractFile -Summary $SmokeSummary
    Write-Host "Updated smoke reachability contract after the full gate passed: $SmokeContractFile"
}

Write-Host "All Lua checks passed."
}
finally {
    try {
        if ($LocationPushed) {
            Pop-Location
        }
    }
    finally {
        if ($GateOwnedToolRoot) {
            Remove-StatsProOwnedToolInvocationRoot -Path $GateOwnedToolRoot
        }
    }
}
