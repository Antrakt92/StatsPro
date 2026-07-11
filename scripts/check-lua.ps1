param(
    [switch]$Release,
    [int]$ArchonMaxAgeDays = 14,
    [switch]$AllowStaleArchonTargets,
    [string]$ToolLockPath = (Join-Path $PSScriptRoot "tool-version-locks.json"),
    [switch]$EnforceToolLocks,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "tool-version-locks.ps1")

if ($ArchonMaxAgeDays -lt 0) {
    throw "-ArchonMaxAgeDays must be a non-negative integer."
}

function Format-NativeArgument {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument -or $Argument -eq "") {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $slash = [string][char]92
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $pendingSlashes = 0
    foreach ($char in $Argument.ToCharArray()) {
        if ($char -eq [char]92) {
            $pendingSlashes++
            continue
        }
        if ($char -eq '"') {
            if ($pendingSlashes -gt 0) {
                [void]$builder.Append($slash * ($pendingSlashes * 2))
                $pendingSlashes = 0
            }
            [void]$builder.Append($slash)
            [void]$builder.Append('"')
            continue
        }
        if ($pendingSlashes -gt 0) {
            [void]$builder.Append($slash * $pendingSlashes)
            $pendingSlashes = 0
        }
        [void]$builder.Append($char)
    }
    if ($pendingSlashes -gt 0) {
        [void]$builder.Append($slash * ($pendingSlashes * 2))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Split-NativeOutput {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return @()
    }
    return @($Text -split "\r?\n" | Where-Object { $_ -ne "" })
}

function Format-VersionOutput {
    param([object[]]$Output)

    $lines = @($Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne "" })
    if ($lines.Count -eq 0) {
        return "<no version output>"
    }
    return ($lines -join " | ")
}

function Invoke-NativeCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 0,
        [string]$Description = $null
    )

    if (-not $FilePath) {
        throw "Native process path is required."
    }
    if ($TimeoutSeconds -lt 0) {
        throw "TimeoutSeconds must be non-negative."
    }

    $effectiveFilePath = $FilePath
    $effectiveArguments = @($Arguments)
    $extension = [System.IO.Path]::GetExtension($FilePath)
    if ($extension -in @(".bat", ".cmd")) {
        if (-not $env:ComSpec) {
            throw "Cannot run ${FilePath}: ComSpec is not set."
        }
        $effectiveFilePath = $env:ComSpec
        $effectiveArguments = @("/d", "/c", "call", $FilePath) + @($Arguments)
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $effectiveFilePath
    $startInfo.WorkingDirectory = (Get-Location).Path
    $startInfo.Arguments = (@($effectiveArguments) | ForEach-Object { Format-NativeArgument $_ }) -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $displayName = if ($Description) { $Description } else { "$FilePath $($Arguments -join ' ')" }
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($TimeoutSeconds -gt 0) {
            $completed = $process.WaitForExit($TimeoutSeconds * 1000)
        }
        else {
            $process.WaitForExit()
            $completed = $true
        }
        if (-not $completed) {
            try {
                $process.Kill()
            }
            catch {
                # Preserve the timeout failure below; the process may have exited between WaitForExit and Kill.
            }
            [void]$process.WaitForExit(5000)
            $timeoutOutput = @()
            if ($stdoutTask.Wait(1000)) { $timeoutOutput += Split-NativeOutput $stdoutTask.Result }
            if ($stderrTask.Wait(1000)) { $timeoutOutput += Split-NativeOutput $stderrTask.Result }
            $details = if ($timeoutOutput.Count -gt 0) { " Output: $($timeoutOutput -join ' ')" } else { "" }
            throw "Timed out after $TimeoutSeconds second(s): $displayName.$details"
        }
        if (-not $stdoutTask.Wait(5000)) {
            throw "Timed out reading stdout from $displayName."
        }
        if (-not $stderrTask.Wait(5000)) {
            throw "Timed out reading stderr from $displayName."
        }
        $output = @()
        $output += Split-NativeOutput $stdoutTask.Result
        $output += Split-NativeOutput $stderrTask.Result
        return @{
            ExitCode = $process.ExitCode
            Output = $output
        }
    }
    finally {
        $process.Dispose()
    }
}

function Write-ToolVersionReport {
    param(
        [string]$Label,
        [string]$Path,
        [string[]]$Arguments
    )

    Write-Host "${Label}: $Path"
    $result = Invoke-NativeCapture -FilePath $Path -Arguments $Arguments -TimeoutSeconds 30 -Description "$Label version"
    if ($result.ExitCode -eq 0) {
        Write-Host "${Label} version: $(Format-VersionOutput $result.Output)"
    }
    else {
        Write-Warning "${Label} version command exited with code $($result.ExitCode): $(Format-VersionOutput $result.Output)"
    }
}

function Assert-ToolCommandVersion {
    param([string]$Label, [string]$Path, [string[]]$Arguments, [string]$Pattern)
    $result = Invoke-NativeCapture -FilePath $Path -Arguments $Arguments -TimeoutSeconds 30 -Description "$Label version"
    if ($result.ExitCode -ne 0) {
        throw "$Label version command exited with code $($result.ExitCode): $(Format-VersionOutput $result.Output)"
    }
    Assert-StatsProCommandVersionText -Label $Label -Text ($result.Output -join "`n") -Pattern $Pattern
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
        [string]$Description = "lua-language-server diagnostics"
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
        ) -TimeoutSeconds $TimeoutSeconds -Description $Description
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

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ArchonTargetsFile = Join-Path $RepoRoot "StatsPro_ArchonTargets.lua"
$SmokeFile = Join-Path $RepoRoot "scripts\smoke.lua"
$MetadataCheck = Join-Path $RepoRoot "scripts\check-metadata.ps1"
$ArchonTargetsCheck = Join-Path $RepoRoot "scripts\check-archon-targets.lua"
$LuaGlobalStub = Join-Path $RepoRoot "scripts\types\wow-globals.d.lua"

function Invoke-SelfTest {
    & $MetadataCheck -SelfTest

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-lua-check-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root | Out-Null
    try {
        $cmd = Get-Command cmd.exe -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
        $nativeCapture = Invoke-NativeCapture -FilePath $cmd -Arguments @("/d", "/c", "echo stdout-line && echo stderr-line 1>&2 && exit /b 7") -TimeoutSeconds 10 -Description "native capture self-test"
        if ($nativeCapture.ExitCode -ne 7) {
            throw "native capture should preserve nonzero exit code 7, got $($nativeCapture.ExitCode)"
        }
        $nativeOutput = $nativeCapture.Output -join "`n"
        if ($nativeOutput -notmatch "stdout-line" -or $nativeOutput -notmatch "stderr-line") {
            throw "native capture should include stdout and stderr, got: $nativeOutput"
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
        $luaLanguageServer = Get-Command lua-language-server -ErrorAction Stop |
            Select-Object -First 1 -ExpandProperty Source
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
local suffix = "Text"
local dynamic = _G["StatsProVisibleCheck" .. suffix]
return state.retrySchedueld or globalTypo or maxSchoolsTypo or dynamic
'@ -Encoding UTF8
        $fieldCheck = Invoke-LuaLanguageServerCheck `
            -ServerPath $luaLanguageServer `
            -Root $fieldFixtureRoot `
            -ConfigPath (Join-Path $fieldFixtureRoot ".luarc.json") `
            -TimeoutSeconds 60 `
            -Description "undefined-field regression fixture"
        $undefinedFieldDiagnostics = @($fieldCheck.Diagnostics | Where-Object { $_.Code -eq "undefined-field" })
        $fieldMessages = $undefinedFieldDiagnostics.Message -join "`n"
        if ($fieldCheck.ExitCode -eq 0 -or $fieldCheck.Diagnostics.Count -ne 5 -or
            $undefinedFieldDiagnostics.Count -ne 5 -or
            $fieldMessages -notmatch "retrySchedueld" -or
            $fieldMessages -notmatch "StatsProFontPickre" -or
            $fieldMessages -notmatch "MAX_SPELL_SCHOOL" -or
            $fieldMessages -notmatch "IsShwon" -or
            $fieldMessages -notmatch "buton1") {
            $summary = @($fieldCheck.Diagnostics | ForEach-Object { "$($_.Code): $($_.Message)" }) -join " | "
            throw "LuaLS field-typo fixture must report only the five intentional field typos; exit=$($fieldCheck.ExitCode), diagnostics=$summary"
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

Set-Location $RepoRoot

$LuacCandidates = @(
    (Get-Command luac5.1 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    (Get-Command luac -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    "C:\ProgramData\chocolatey\lib\lua51\tools\luac5.1.exe"
) | Where-Object { $_ -and (Test-Path $_) }

$Luac = $LuacCandidates | Select-Object -First 1
if (-not $Luac) {
    throw "Missing luac 5.1. Install with: choco install lua51 -y"
}

$LuaCandidates = @(
    (Get-Command lua5.1 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    (Get-Command lua -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    "C:\ProgramData\chocolatey\lib\lua51\tools\lua5.1.exe"
) | Where-Object { $_ -and (Test-Path $_) }

$Lua = $LuaCandidates | Select-Object -First 1
if (-not $Lua) {
    throw "Missing lua 5.1 runtime. Install with: choco install lua51 -y"
}
$LuaVersionResult = Invoke-NativeCapture -FilePath $Lua -Arguments @("-v") -TimeoutSeconds 10 -Description "lua -v"
$LuaVersion = $LuaVersionResult.Output -join "`n"
if ($LuaVersionResult.ExitCode -ne 0) {
    throw "lua -v exited with code $($LuaVersionResult.ExitCode): $LuaVersion"
}
if ($LuaVersion -notmatch "Lua\s+5\.1") {
    throw "StatsPro smoke requires Lua 5.1 because it uses setfenv; found: $LuaVersion"
}

$LuaLanguageServer = Get-Command lua-language-server -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source
if (-not $LuaLanguageServer) {
    throw "Missing lua-language-server. Install with: choco install lua-language-server -y"
}

$LuacheckCandidates = @(
    (Get-Command luacheck -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    "C:\ProgramData\chocolatey\lib\luarocks\luarocks-2.4.4-win32\systree\bin\luacheck.bat"
) | Where-Object { $_ -and (Test-Path $_) }

$Luacheck = $LuacheckCandidates | Select-Object -First 1
if (-not $Luacheck) {
    throw "Missing luacheck. Run: .\scripts\install-check-tools.ps1 -Install"
}

Write-Host "== Tool versions =="
Write-ToolVersionReport -Label "lua" -Path $Lua -Arguments @("-v")
Write-ToolVersionReport -Label "luac" -Path $Luac -Arguments @("-v")
Write-ToolVersionReport -Label "lua-language-server" -Path $LuaLanguageServer -Arguments @("--version")
Write-ToolVersionReport -Label "luacheck" -Path $Luacheck -Arguments @("--version")

if ($EnforceToolLocks) {
    $ToolLocks = Read-StatsProToolLocks -Path $ToolLockPath
    Assert-ToolCommandVersion -Label "lua" -Path $Lua -Arguments @("-v") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "lua5.1")
    Assert-ToolCommandVersion -Label "luac" -Path $Luac -Arguments @("-v") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "luac5.1")
    Assert-ToolCommandVersion -Label "lua-language-server" -Path $LuaLanguageServer -Arguments @("--version") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "lua-language-server")
    Assert-ToolCommandVersion -Label "luacheck" -Path $Luacheck -Arguments @("--version") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "luacheck")
    Write-Host "Tool command version locks enforced."
}

& $MetadataCheck

$RuntimeLuaRefs = @(Get-RuntimeLuaRefs -MetadataCheckPath $MetadataCheck)

Write-Host "== Lua syntax =="
$SyntaxFiles = @($RuntimeLuaRefs | ForEach-Object { $_.FullPath })
if (Test-Path $ArchonTargetsCheck) { $SyntaxFiles += $ArchonTargetsCheck }
$SyntaxFiles += $SmokeFile
& $Luac -p @SyntaxFiles
if ($LASTEXITCODE -ne 0) {
    throw "luac exited with code $LASTEXITCODE"
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
    $ArchonResult = Invoke-NativeCapture -FilePath $Lua -Arguments $ArchonArgs -TimeoutSeconds 30 -Description "Archon target snapshot check"
    $ArchonResult.Output | ForEach-Object { Write-Host $_ }
    if ($ArchonResult.ExitCode -ne 0) {
        throw "Archon target snapshot check exited with code $($ArchonResult.ExitCode)"
    }
}

Write-Host "== Lua smoke =="
& $Lua $SmokeFile
if ($LASTEXITCODE -ne 0) {
    throw "Lua smoke exited with code $LASTEXITCODE"
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
& $Luacheck @StaticAnalysisFiles
if ($LASTEXITCODE -ne 0) {
    throw "luacheck exited with code $LASTEXITCODE"
}

Write-Host "== Lua diagnostics =="
Write-Host "-- $RepoRoot"
Assert-UndefinedFieldDiagnosticsEnabled -ConfigPath (Join-Path $RepoRoot ".luarc.json")
$LuaLanguageServerResult = Invoke-LuaLanguageServerCheck `
    -ServerPath $LuaLanguageServer `
    -Root $RepoRoot `
    -ConfigPath (Join-Path $RepoRoot ".luarc.json") `
    -TimeoutSeconds 180 `
    -Description "lua-language-server diagnostics for $RepoRoot"
Assert-NoLuaDiagnostics `
    -Diagnostics @($LuaLanguageServerResult.Diagnostics) `
    -ExitCode $LuaLanguageServerResult.ExitCode

Write-Host "All Lua checks passed."
