param(
    [switch]$Install,
    [string]$ToolLockPath = (Join-Path $PSScriptRoot "tool-version-locks.json"),
    [switch]$EnforceToolLocks,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "tool-version-locks.ps1")

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
        [string]$PackageName,
        [string]$Version
    )

    $Choco = Resolve-Tool -Names @("choco")
    if (-not $Choco) {
        throw "Missing Chocolatey; cannot install $PackageName automatically."
    }
    Write-Host "Installing $PackageName $Version with Chocolatey..."
    & $Choco @(Get-StatsProChocoInstallArguments -PackageName $PackageName -Version $Version) | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "choco install $PackageName $Version exited with code $LASTEXITCODE"
    }
}

function Require-Tool {
    param(
        [string]$Label,
        [string[]]$Names,
        [string]$ChocoPackage,
        [string]$ChocoVersion
    )

    $Path = Resolve-Tool -Names $Names
    if (-not $Path -and $Install) {
        Install-ChocoPackage -PackageName $ChocoPackage -Version $ChocoVersion
        $Path = Resolve-Tool -Names $Names
    }
    if (-not $Path) {
        throw "Missing $Label. Re-run with -Install, or install $ChocoPackage with Chocolatey."
    }
    Write-Host "${Label}: $Path"
    return $Path
}

function Get-LuacheckInstallPlan {
    param($Locks)
    $luacheckVersion = Get-StatsProLockedLuarocksVersion -Locks $Locks -PackageName "luacheck"
    $argparseVersion = Get-StatsProLockedLuarocksVersion -Locks $Locks -PackageName "argparse"
    $luafilesystemVersion = Get-StatsProLockedLuarocksVersion -Locks $Locks -PackageName "luafilesystem"

    return @(
        [pscustomobject]@{ Name = "argparse"; Version = $argparseVersion; DepsModeNone = $false },
        [pscustomobject]@{ Name = "luafilesystem"; Version = $luafilesystemVersion; DepsModeNone = $false },
        [pscustomobject]@{ Name = "luacheck"; Version = $luacheckVersion; DepsModeNone = $true }
    )
}

function Install-Luacheck {
    param(
        [string]$LuarocksPath,
        $Locks
    )

    foreach ($package in @(Get-LuacheckInstallPlan -Locks $Locks)) {
        Write-Host "Installing $($package.Name) $($package.Version) with LuaRocks..."
        $installArgs = Get-StatsProLuarocksInstallArguments -PackageName $package.Name -Version $package.Version -DepsModeNone:([bool]$package.DepsModeNone)
        & $LuarocksPath @installArgs | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            $depsMessage = if ($package.DepsModeNone) { " --deps-mode=none" } else { "" }
            throw "luarocks install $($package.Name) $($package.Version)$depsMessage exited with code $LASTEXITCODE"
        }
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

function Assert-ChocoPackageVersion {
    param([string]$ChocoPath, [string]$PackageName, [string]$ExpectedVersion)
    $result = Invoke-NativeCapture -FilePath $ChocoPath -Arguments @("list", "--exact", $PackageName, "--limit-output") -TimeoutSeconds 30 -Description "choco list $PackageName"
    if ($result.ExitCode -ne 0) {
        throw "choco list $PackageName exited with code $($result.ExitCode): $(Format-VersionOutput $result.Output)"
    }
    Assert-StatsProPackageVersionLine -Label $PackageName -Output $result.Output -ExpectedVersion $ExpectedVersion -Format "choco"
}

function Assert-LuarocksPackageVersion {
    param([string]$LuarocksPath, [string]$PackageName, [string]$ExpectedVersion)
    $result = Invoke-NativeCapture -FilePath $LuarocksPath -Arguments @("list", "--porcelain", $PackageName) -TimeoutSeconds 30 -Description "luarocks list $PackageName"
    if ($result.ExitCode -ne 0) {
        throw "luarocks list $PackageName exited with code $($result.ExitCode): $(Format-VersionOutput $result.Output)"
    }
    Assert-StatsProPackageVersionLine -Label $PackageName -Output $result.Output -ExpectedVersion $ExpectedVersion -Format "luarocks"
}

function Assert-ToolCommandVersion {
    param([string]$Label, [string]$Path, [string[]]$Arguments, [string]$Pattern)
    $result = Invoke-NativeCapture -FilePath $Path -Arguments $Arguments -TimeoutSeconds 30 -Description "$Label version"
    if ($result.ExitCode -ne 0) {
        throw "$Label version command exited with code $($result.ExitCode): $(Format-VersionOutput $result.Output)"
    }
    Assert-StatsProCommandVersionText -Label $Label -Text ($result.Output -join "`n") -Pattern $Pattern
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

    $locks = Read-StatsProToolLocks -Path (Join-Path $PSScriptRoot "tool-version-locks.json")
    Assert-Equal "locked lua51 choco version" (Get-StatsProLockedChocolateyVersion -Locks $locks -PackageName "lua51") "5.1.5"
    Assert-Equal "locked LuaLS choco version" (Get-StatsProLockedChocolateyVersion -Locks $locks -PackageName "lua-language-server") "3.18.1"
    Assert-Equal "locked luacheck rock version" (Get-StatsProLockedLuarocksVersion -Locks $locks -PackageName "luacheck") "1.2.0-1"
    Assert-Equal "locked choco install args" ((Get-StatsProChocoInstallArguments -PackageName "lua51" -Version "5.1.5") -join " ") "install lua51 --version 5.1.5 -y --no-progress --allow-empty-checksums"
    Assert-Equal "locked luarocks install args" ((Get-StatsProLuarocksInstallArguments -PackageName "luacheck" -Version "1.2.0-1") -join " ") "install luacheck 1.2.0-1"
    Assert-Equal "locked luarocks no-deps install args" ((Get-StatsProLuarocksInstallArguments -PackageName "luacheck" -Version "1.2.0-1" -DepsModeNone) -join " ") "install luacheck 1.2.0-1 --deps-mode=none"
    $luacheckPlan = @(Get-LuacheckInstallPlan -Locks $locks)
    Assert-Equal "locked luacheck install plan count" $luacheckPlan.Count 3
    Assert-Equal "locked luacheck install plan order" (($luacheckPlan | ForEach-Object { $_.Name }) -join " ") "argparse luafilesystem luacheck"
    Assert-Equal "locked luacheck installs without auto deps" $luacheckPlan[2].DepsModeNone $true
    Assert-StatsProPackageVersionLine -Label "lua51" -Output @("lua51|5.1.5") -ExpectedVersion "5.1.5" -Format "choco"
    Assert-StatsProPackageVersionLine -Label "luacheck" -Output @("luacheck`t1.2.0-1`tinstalled`tC:/rocks") -ExpectedVersion "1.2.0-1" -Format "luarocks"

    Write-Host "Install check tools self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

$ToolLocks = Read-StatsProToolLocks -Path $ToolLockPath

$Lua = Require-Tool `
    -Label "lua5.1" `
    -Names @("lua5.1", "C:\ProgramData\chocolatey\lib\lua51\tools\lua5.1.exe") `
    -ChocoPackage "lua51" `
    -ChocoVersion (Get-StatsProLockedChocolateyVersion -Locks $ToolLocks -PackageName "lua51")

$Luac = Require-Tool `
    -Label "luac5.1" `
    -Names @("luac5.1", "C:\ProgramData\chocolatey\lib\lua51\tools\luac5.1.exe") `
    -ChocoPackage "lua51" `
    -ChocoVersion (Get-StatsProLockedChocolateyVersion -Locks $ToolLocks -PackageName "lua51")

$LuaLanguageServer = Require-Tool `
    -Label "lua-language-server" `
    -Names @("lua-language-server") `
    -ChocoPackage "lua-language-server" `
    -ChocoVersion (Get-StatsProLockedChocolateyVersion -Locks $ToolLocks -PackageName "lua-language-server")

$Luarocks = Require-Tool `
    -Label "luarocks" `
    -Names @("luarocks") `
    -ChocoPackage "luarocks" `
    -ChocoVersion (Get-StatsProLockedChocolateyVersion -Locks $ToolLocks -PackageName "luarocks")

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
    Install-Luacheck -LuarocksPath $Luarocks -Locks $ToolLocks
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

if ($EnforceToolLocks) {
    Assert-ToolCommandVersion -Label "lua5.1" -Path $Lua -Arguments @("-v") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "lua5.1")
    Assert-ToolCommandVersion -Label "luac5.1" -Path $Luac -Arguments @("-v") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "luac5.1")
    Assert-ToolCommandVersion -Label "lua-language-server" -Path $LuaLanguageServer -Arguments @("--version") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "lua-language-server")
    Assert-ToolCommandVersion -Label "luarocks" -Path $Luarocks -Arguments @("--version") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "luarocks")
    Assert-ToolCommandVersion -Label "luacheck" -Path $Luacheck -Arguments @("--version") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "luacheck")

    $ChocoForAssert = Resolve-Tool -Names @("choco")
    if (-not $ChocoForAssert) {
        throw "Chocolatey is required to enforce Chocolatey package locks."
    }
    Assert-ChocoPackageVersion -ChocoPath $ChocoForAssert -PackageName "lua51" -ExpectedVersion (Get-StatsProLockedChocolateyVersion -Locks $ToolLocks -PackageName "lua51")
    Assert-ChocoPackageVersion -ChocoPath $ChocoForAssert -PackageName "lua-language-server" -ExpectedVersion (Get-StatsProLockedChocolateyVersion -Locks $ToolLocks -PackageName "lua-language-server")
    Assert-ChocoPackageVersion -ChocoPath $ChocoForAssert -PackageName "luarocks" -ExpectedVersion (Get-StatsProLockedChocolateyVersion -Locks $ToolLocks -PackageName "luarocks")
    Assert-LuarocksPackageVersion -LuarocksPath $Luarocks -PackageName "luacheck" -ExpectedVersion (Get-StatsProLockedLuarocksVersion -Locks $ToolLocks -PackageName "luacheck")
    Assert-LuarocksPackageVersion -LuarocksPath $Luarocks -PackageName "argparse" -ExpectedVersion (Get-StatsProLockedLuarocksVersion -Locks $ToolLocks -PackageName "argparse")
    Assert-LuarocksPackageVersion -LuarocksPath $Luarocks -PackageName "luafilesystem" -ExpectedVersion (Get-StatsProLockedLuarocksVersion -Locks $ToolLocks -PackageName "luafilesystem")
    Write-Host "Tool version locks enforced."
}

Write-Host "StatsPro check tools are available."
