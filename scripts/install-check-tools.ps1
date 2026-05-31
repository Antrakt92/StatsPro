param(
    [switch]$Install,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

$LuacheckFallback = "C:\ProgramData\chocolatey\lib\luarocks\luarocks-2.4.4-win32\systree\bin\luacheck.bat"

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
    & $Choco install $PackageName -y --no-progress | ForEach-Object { Write-Host $_ }
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
    & $LuarocksPath install luacheck | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -eq 0) {
        return
    }

    Write-Host "Direct luacheck install failed; trying Windows-friendly dependency bootstrap..."
    & $LuarocksPath install argparse | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "luarocks install argparse exited with code $LASTEXITCODE"
    }
    & $LuarocksPath install luafilesystem 1.6.0-1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "luarocks install luafilesystem 1.6.0-1 exited with code $LASTEXITCODE"
    }
    & $LuarocksPath install luacheck --deps-mode=none | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "luarocks install luacheck --deps-mode=none exited with code $LASTEXITCODE"
    }
}

function Format-VersionOutput {
    param([object[]]$Output)

    $lines = @($Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne "" })
    if ($lines.Count -eq 0) {
        return "<no version output>"
    }
    return ($lines -join " | ")
}

function Write-ToolVersionReport {
    param(
        [string]$Label,
        [string]$Path,
        [string[]]$Arguments
    )

    $result = Invoke-NativeCapture -FilePath $Path -Arguments $Arguments -TimeoutSeconds 30 -Description "$Label version"
    if ($result.ExitCode -eq 0) {
        Write-Host "${Label} version: $(Format-VersionOutput $result.Output)"
    }
    else {
        Write-Warning "${Label} version command exited with code $($result.ExitCode): $(Format-VersionOutput $result.Output)"
    }
}

function Write-ChocoPackageReport {
    param(
        [string]$ChocoPath,
        [string]$PackageName
    )

    $result = Invoke-NativeCapture -FilePath $ChocoPath -Arguments @("list", "--exact", $PackageName, "--limit-output") -TimeoutSeconds 30 -Description "choco list $PackageName"
    if ($result.ExitCode -eq 0 -and $result.Output.Count -gt 0) {
        Write-Host "choco package ${PackageName}: $(Format-VersionOutput $result.Output)"
    }
    else {
        Write-Warning "choco package ${PackageName} version not listed: $(Format-VersionOutput $result.Output)"
    }
}

function Write-LuarocksPackageReport {
    param(
        [string]$LuarocksPath,
        [string]$PackageName
    )

    $result = Invoke-NativeCapture -FilePath $LuarocksPath -Arguments @("list", "--porcelain", $PackageName) -TimeoutSeconds 30 -Description "luarocks list $PackageName"
    if ($result.ExitCode -eq 0 -and $result.Output.Count -gt 0) {
        Write-Host "luarocks package ${PackageName}: $(Format-VersionOutput $result.Output)"
    }
    else {
        Write-Warning "luarocks package ${PackageName} version not listed: $(Format-VersionOutput $result.Output)"
    }
}

function Assert-Equal {
    param(
        [string]$Name,
        [object]$Actual,
        [object]$Expected
    )

    if ($Actual -ne $Expected) {
        throw "$Name expected <$Expected>, got <$Actual>."
    }
}

function Invoke-SelfTest {
    Assert-Equal "version output collapses lines" (Format-VersionOutput @(" Tool 1.2.3 ", "", "Lua 5.1 ")) "Tool 1.2.3 | Lua 5.1"
    Assert-Equal "version output empty fallback" (Format-VersionOutput @("", "   ")) "<no version output>"

    Write-Host "Install check tools self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
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

$LuaVersionResult = Invoke-NativeCapture -FilePath $Lua -Arguments @("-v")
$LuaVersion = $LuaVersionResult.Output -join "`n"
if ($LuaVersionResult.ExitCode -ne 0) {
    throw "lua -v exited with code $($LuaVersionResult.ExitCode): $LuaVersion"
}
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

Write-Host "== Tool versions =="
Write-ToolVersionReport -Label "lua5.1" -Path $Lua -Arguments @("-v")
Write-ToolVersionReport -Label "luac5.1" -Path $Luac -Arguments @("-v")
Write-ToolVersionReport -Label "lua-language-server" -Path $LuaLanguageServer -Arguments @("--version")
Write-ToolVersionReport -Label "luarocks" -Path $Luarocks -Arguments @("--version")
Write-ToolVersionReport -Label "luacheck" -Path $Luacheck -Arguments @("--version")

$Choco = Resolve-Tool -Names @("choco")
if ($Choco) {
    Write-ToolVersionReport -Label "choco" -Path $Choco -Arguments @("--version")
    Write-ChocoPackageReport -ChocoPath $Choco -PackageName "lua51"
    Write-ChocoPackageReport -ChocoPath $Choco -PackageName "lua-language-server"
    Write-ChocoPackageReport -ChocoPath $Choco -PackageName "luarocks"
}
else {
    Write-Warning "Chocolatey is not available for package version reporting."
}

Write-LuarocksPackageReport -LuarocksPath $Luarocks -PackageName "luacheck"
Write-LuarocksPackageReport -LuarocksPath $Luarocks -PackageName "argparse"
Write-LuarocksPackageReport -LuarocksPath $Luarocks -PackageName "luafilesystem"

Write-Host "StatsPro check tools are available."
