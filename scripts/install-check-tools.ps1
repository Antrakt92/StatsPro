param(
    [switch]$Install
)

$ErrorActionPreference = "Stop"

$LuacheckFallback = "C:\ProgramData\chocolatey\lib\luarocks\luarocks-2.4.4-win32\systree\bin\luacheck.bat"

function Resolve-Tool {
    param(
        [string[]]$Names
    )

    foreach ($Name in $Names) {
        if (Test-Path $Name) {
            return (Resolve-Path $Name).Path
        }
        $Command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($Command) {
            return $Command.Source
        }
    }
    return $null
}

function Install-ChocoPackage {
    param(
        [string]$PackageName
    )

    $Choco = Resolve-Tool -Names @("choco")
    if (-not $Choco) {
        throw "Missing Chocolatey; cannot install $PackageName automatically."
    }
    Write-Host "Installing $PackageName with Chocolatey..."
    & $Choco install $PackageName -y --no-progress
    if ($LASTEXITCODE -ne 0) {
        throw "choco install $PackageName exited with code $LASTEXITCODE"
    }
}

function Require-Tool {
    param(
        [string]$Label,
        [string[]]$Names,
        [string]$ChocoPackage
    )

    $Path = Resolve-Tool -Names $Names
    if (-not $Path -and $Install) {
        Install-ChocoPackage -PackageName $ChocoPackage
        $Path = Resolve-Tool -Names $Names
    }
    if (-not $Path) {
        throw "Missing $Label. Re-run with -Install, or install $ChocoPackage with Chocolatey."
    }
    Write-Host "${Label}: $Path"
    return $Path
}

function Install-Luacheck {
    param(
        [string]$LuarocksPath
    )

    Write-Host "Installing luacheck with LuaRocks..."
    & $LuarocksPath install luacheck
    if ($LASTEXITCODE -eq 0) {
        return
    }

    Write-Host "Direct luacheck install failed; trying Windows-friendly dependency bootstrap..."
    & $LuarocksPath install argparse
    if ($LASTEXITCODE -ne 0) {
        throw "luarocks install argparse exited with code $LASTEXITCODE"
    }
    & $LuarocksPath install luafilesystem 1.6.0-1
    if ($LASTEXITCODE -ne 0) {
        throw "luarocks install luafilesystem 1.6.0-1 exited with code $LASTEXITCODE"
    }
    & $LuarocksPath install luacheck --deps-mode=none
    if ($LASTEXITCODE -ne 0) {
        throw "luarocks install luacheck --deps-mode=none exited with code $LASTEXITCODE"
    }
}

$Lua = Require-Tool `
    -Label "lua5.1" `
    -Names @("lua5.1", "C:\ProgramData\chocolatey\lib\lua51\tools\lua5.1.exe") `
    -ChocoPackage "lua51"

$Luac = Require-Tool `
    -Label "luac5.1" `
    -Names @("luac5.1", "C:\ProgramData\chocolatey\lib\lua51\tools\luac5.1.exe") `
    -ChocoPackage "lua51"

$LuaLanguageServer = Require-Tool `
    -Label "lua-language-server" `
    -Names @("lua-language-server") `
    -ChocoPackage "lua-language-server"

$Luarocks = Require-Tool `
    -Label "luarocks" `
    -Names @("luarocks") `
    -ChocoPackage "luarocks"

$LuaVersion = (& $Lua -v 2>&1) -join "`n"
if ($LuaVersion -notmatch "Lua\s+5\.1") {
    throw "StatsPro smoke requires Lua 5.1 because it uses setfenv; found: $LuaVersion"
}

$Luacheck = Resolve-Tool -Names @("luacheck", $LuacheckFallback)
if (-not $Luacheck -and $Install) {
    Install-Luacheck -LuarocksPath $Luarocks
    $Luacheck = Resolve-Tool -Names @("luacheck", $LuacheckFallback)
}
if (-not $Luacheck) {
    throw "Missing luacheck. Re-run with -Install, or install it with LuaRocks. On Windows, the wrapper also checks $LuacheckFallback."
}
Write-Host "luacheck: $Luacheck"

Write-Host "StatsPro check tools are available."
