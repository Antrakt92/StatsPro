param()

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot
$AddonFile = Join-Path $RepoRoot "StatsPro.lua"
$ArchonTargetsFile = Join-Path $RepoRoot "StatsPro_ArchonTargets.lua"
$SmokeFile = Join-Path $RepoRoot "scripts\smoke.lua"
$MetadataCheck = Join-Path $RepoRoot "scripts\check-metadata.ps1"

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
$LuaVersion = (& $Lua -v 2>&1) -join "`n"
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

& $MetadataCheck
if ($LASTEXITCODE -ne 0) {
    throw "metadata check exited with code $LASTEXITCODE"
}

Write-Host "== Lua syntax =="
$SyntaxFiles = @()
if (Test-Path $ArchonTargetsFile) { $SyntaxFiles += "StatsPro_ArchonTargets.lua" }
$SyntaxFiles += "StatsPro.lua"
$SyntaxFiles += $SmokeFile
& $Luac -p @SyntaxFiles
if ($LASTEXITCODE -ne 0) {
    throw "luac exited with code $LASTEXITCODE"
}

Write-Host "== Lua smoke =="
& $Lua $SmokeFile
if ($LASTEXITCODE -ne 0) {
    throw "Lua smoke exited with code $LASTEXITCODE"
}

Write-Host "== Luacheck =="
& $Luacheck StatsPro.lua
if ($LASTEXITCODE -ne 0) {
    throw "luacheck exited with code $LASTEXITCODE"
}

Write-Host "== Lua diagnostics =="
$LogPath = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-lls-" + [System.Guid]::NewGuid().ToString("N"))
try {
    $Output = & $LuaLanguageServer `
        --check="$AddonFile" `
        --check_format=pretty `
        --checklevel=Warning `
        --configpath="$RepoRoot\.luarc.json" `
        --logpath="$LogPath" 2>&1
    $Output | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "lua-language-server exited with code $LASTEXITCODE"
    }
    $JoinedOutput = $Output -join "`n"
    if (
        $JoinedOutput -match "Diagnosis complete(?:d)?,\s+([1-9]\d*) problems? found" -or
        $JoinedOutput -match "Found\s+([1-9]\d*) problems?"
    ) {
        throw "lua-language-server reported $($Matches[1]) diagnostic problem(s)"
    }
}
finally {
    Remove-Item -Recurse -Force $LogPath -ErrorAction SilentlyContinue
}

Write-Host "All Lua checks passed."
