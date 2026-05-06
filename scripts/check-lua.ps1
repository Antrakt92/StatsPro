param()

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot
$AddonFile = Join-Path $RepoRoot "StatsPro.lua"

$LuacCandidates = @(
    (Get-Command luac5.1 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    (Get-Command luac -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    "C:\ProgramData\chocolatey\lib\lua51\tools\luac5.1.exe"
) | Where-Object { $_ -and (Test-Path $_) }

$Luac = $LuacCandidates | Select-Object -First 1
if (-not $Luac) {
    throw "Missing luac 5.1. Install with: choco install lua51 -y"
}

$LuaLanguageServer = Get-Command lua-language-server -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source
if (-not $LuaLanguageServer) {
    throw "Missing lua-language-server. Install with: choco install lua-language-server -y"
}

Write-Host "== Lua syntax =="
& $Luac -p StatsPro.lua

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
