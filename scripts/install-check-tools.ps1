param(
    [switch]$Install,
    [string]$ToolLockPath = (Join-Path $PSScriptRoot "tool-version-locks.json"),
    [string]$OwnedToolRoot,
    [switch]$EphemeralOwnedToolRoot,
    [switch]$EnforceToolLocks,
    [switch]$SelfTest,
    [switch]$PinnedLuaIntegrationTest
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "tool-version-locks.ps1")

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
        [string]$Description = $null,
        [hashtable]$Environment = @{}
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
    Set-StatsProIsolatedLuaProcessEnvironment -StartInfo $startInfo -Environment $Environment

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

function Add-ToolPath {
    param([string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $parts = @($env:PATH -split [System.IO.Path]::PathSeparator)
    if (-not ($parts | Where-Object { [System.StringComparer]::OrdinalIgnoreCase.Equals($_, $resolved) })) {
        $env:PATH = $resolved + [System.IO.Path]::PathSeparator + $env:PATH
    }
    if ($env:GITHUB_PATH) {
        Add-Content -LiteralPath $env:GITHUB_PATH -Value $resolved -Encoding utf8
    }
}

function Publish-StatsProOwnedToolRoot {
    param($Layout)

    [Environment]::SetEnvironmentVariable("STATSPRO_OWNED_TOOL_ROOT", $Layout.ToolRoot, "Process")
    if ($env:GITHUB_ENV) {
        Add-Content -LiteralPath $env:GITHUB_ENV -Value "STATSPRO_OWNED_TOOL_ROOT=$($Layout.ToolRoot)" -Encoding utf8
    }
    Add-ToolPath -Path $Layout.LuaRoot
}

function Assert-Lua51Pair {
    param([string]$Root, $Locks)
    $lua = Join-Path $Root "lua5.1.exe"
    $luac = Join-Path $Root "luac5.1.exe"
    foreach ($tool in @(
        @{ Label = "lua5.1"; Path = $lua },
        @{ Label = "luac5.1"; Path = $luac }
    )) {
        if (-not (Test-Path -LiteralPath $tool.Path -PathType Leaf)) {
            throw "Pinned Lua archive is missing $($tool.Label)."
        }
        $result = Invoke-NativeCapture -FilePath $tool.Path -Arguments @("-v") -TimeoutSeconds 30 -Description "$($tool.Label) version"
        if ($result.ExitCode -ne 0) {
            throw "$($tool.Label) version command exited with code $($result.ExitCode)."
        }
        Assert-StatsProCommandVersionText `
            -Label $tool.Label `
            -Text ($result.Output -join "`n") `
            -Pattern (Get-StatsProLockedCommandPattern -Locks $Locks -CommandName $tool.Label)
    }
    return $Root
}

function Save-PinnedArtifact {
    param(
        $Lock,
        [string]$DestinationPath
    )

    $safeUri = Assert-StatsProHttpsDownloadUri -Uri $Lock.Url
    if ($Lock.Sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Pinned artifact SHA-256 is missing or malformed."
    }
    if ([string]::IsNullOrWhiteSpace($Lock.FileName)) {
        throw "Pinned artifact file name is missing."
    }
    $uriFileName = [System.Uri]::UnescapeDataString(
        [System.IO.Path]::GetFileName(([uri]$safeUri).AbsolutePath))
    if (-not [System.StringComparer]::Ordinal.Equals($uriFileName, [string]$Lock.FileName)) {
        throw "Pinned artifact URL file '$uriFileName' does not match lock file '$($Lock.FileName)'."
    }
    $windowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    if ([string]::IsNullOrWhiteSpace($windowsRoot)) {
        throw "Cannot resolve the Windows directory for the pinned artifact downloader."
    }
    $systemCurl = [System.IO.Path]::GetFullPath((Join-Path $windowsRoot "System32\curl.exe"))
    if (-not (Test-Path -LiteralPath $systemCurl -PathType Leaf)) {
        throw "Missing the Windows system curl executable: $systemCurl"
    }

    $arguments = Get-StatsProPinnedCurlArguments -Uri $safeUri -OutputPath $DestinationPath
    if ([System.IO.File]::Exists($DestinationPath)) {
        [System.IO.File]::Delete($DestinationPath)
    }
    & $systemCurl @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Pinned artifact download failed with curl exit code $LASTEXITCODE."
    }
    return Assert-StatsProPinnedArchive `
        -Path $DestinationPath `
        -ExpectedSha256 $Lock.Sha256
}

function Install-PinnedLua51 {
    param(
        $Lock,
        $Locks,
        [string]$DestinationRoot,
        [string]$AllowedToolRoot,
        [string]$ArchivePathOverride,
        [switch]$SkipPathMutation
    )
    [void](Assert-StatsProHttpsDownloadUri -Uri $Lock.Url)
    if ($Lock.Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Pinned Lua version must be a three-part numeric version."
    }
    if ($Lock.Sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Pinned Lua SHA-256 is missing or malformed."
    }

    $allowedFull = [System.IO.Path]::GetFullPath($AllowedToolRoot).TrimEnd('\', '/')
    $destinationFull = [System.IO.Path]::GetFullPath($DestinationRoot)
    $allowedPrefix = $allowedFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $destinationFull.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Pinned Lua destination escaped its tool root."
    }
    if (Test-Path -LiteralPath $allowedFull) {
        $allowedItem = Get-Item -LiteralPath $allowedFull -Force
        if (($allowedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Pinned Lua tool root cannot be a reparse point."
        }
    }

    $nonce = [System.Guid]::NewGuid().ToString("N")
    $archive = if ($ArchivePathOverride) {
        [System.IO.Path]::GetFullPath($ArchivePathOverride)
    }
    else {
        Join-Path ([System.IO.Path]::GetTempPath()) "statspro-lua-$nonce.zip"
    }
    $ownsArchive = -not $ArchivePathOverride
    $staging = Join-Path $allowedFull "lua-$nonce"
    try {
        if (-not $ArchivePathOverride) {
            [void](Save-PinnedArtifact -Lock $Lock -DestinationPath $archive)
        }
        [void](Assert-StatsProPinnedArchive -Path $archive -ExpectedSha256 $Lock.Sha256)

        New-Item -ItemType Directory -Path $allowedFull -Force | Out-Null
        $allowedItem = Get-Item -LiteralPath $allowedFull -Force
        if (($allowedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Pinned Lua tool root became a reparse point."
        }
        Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
        [void](Assert-Lua51Pair -Root $staging -Locks $Locks)

        if (Test-Path -LiteralPath $DestinationRoot) {
            $destinationItem = Get-Item -LiteralPath $DestinationRoot -Force
            if (($destinationItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Pinned Lua destination cannot be replaced through a reparse point."
            }
            [System.IO.Directory]::Delete($destinationFull, $true)
        }
        Move-Item -LiteralPath $staging -Destination $DestinationRoot
        [void](Assert-Lua51Pair -Root $DestinationRoot -Locks $Locks)
        if (-not $SkipPathMutation) {
            Add-ToolPath -Path $DestinationRoot
        }
        return $DestinationRoot
    }
    finally {
        if ($ownsArchive -and (Test-Path -LiteralPath $archive -PathType Leaf)) {
            [System.IO.File]::Delete($archive)
        }
        if (Test-Path -LiteralPath $staging -PathType Container) {
            [System.IO.Directory]::Delete($staging, $true)
        }
    }
}

function Require-Tool {
    param(
        [string]$Label,
        [string[]]$Names
    )

    $Path = Resolve-Tool -Names $Names
    if (-not $Path) {
        throw "Missing $Label. Re-run with -Install."
    }
    Write-Host "${Label}: $Path"
    return $Path
}

function Assert-OwnedDestinationRoot {
    param([string]$DestinationRoot, [string]$AllowedToolRoot, [string]$Label)

    $allowedFull = [System.IO.Path]::GetFullPath($AllowedToolRoot).TrimEnd('\', '/')
    $destinationFull = [System.IO.Path]::GetFullPath($DestinationRoot)
    $allowedPrefix = $allowedFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $destinationFull.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label destination escaped its tool root."
    }
    if (Test-Path -LiteralPath $allowedFull) {
        $allowedItem = Get-Item -LiteralPath $allowedFull -Force
        if (($allowedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "StatsPro tool root cannot be a reparse point."
        }
    }
    if (Test-Path -LiteralPath $destinationFull) {
        $destinationItem = Get-Item -LiteralPath $destinationFull -Force
        if (($destinationItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label destination cannot be a reparse point."
        }
    }
    return $destinationFull
}

function Remove-OwnedToolDirectory {
    param([string]$DestinationRoot, [string]$AllowedToolRoot, [string]$Label)

    $destinationFull = Assert-OwnedDestinationRoot `
        -DestinationRoot $DestinationRoot `
        -AllowedToolRoot $AllowedToolRoot `
        -Label $Label
    if ([System.IO.Directory]::Exists($destinationFull)) {
        [System.IO.Directory]::Delete($destinationFull, $true)
    }
}

function Assert-LuaLanguageServerRoot {
    param([string]$Root, $Locks)

    $server = Join-Path $Root "bin\lua-language-server.exe"
    if (-not (Test-Path -LiteralPath $server -PathType Leaf)) {
        throw "Pinned LuaLS archive is missing bin\lua-language-server.exe."
    }
    Assert-ToolCommandVersion `
        -Label "lua-language-server" `
        -Path $server `
        -Arguments @("--version") `
        -Pattern (Get-StatsProLockedCommandPattern -Locks $Locks -CommandName "lua-language-server")
    return (Resolve-Path -LiteralPath $server).Path
}

function Install-PinnedLuaLanguageServer {
    param(
        $Lock,
        $Locks,
        [string]$DestinationRoot,
        [string]$AllowedToolRoot,
        [string]$ArchivePathOverride
    )

    [void](Assert-OwnedDestinationRoot `
            -DestinationRoot $DestinationRoot `
            -AllowedToolRoot $AllowedToolRoot `
            -Label "Pinned LuaLS")
    $nonce = [System.Guid]::NewGuid().ToString("N")
    $archive = if ($ArchivePathOverride) {
        [System.IO.Path]::GetFullPath($ArchivePathOverride)
    }
    else {
        Join-Path ([System.IO.Path]::GetTempPath()) "statspro-luals-$nonce.zip"
    }
    $ownsArchive = -not $ArchivePathOverride
    $staging = Join-Path ([System.IO.Path]::GetFullPath($AllowedToolRoot)) "luals-$nonce"
    try {
        if ($ArchivePathOverride) {
            [void](Assert-StatsProPinnedArchive -Path $archive -ExpectedSha256 $Lock.Sha256)
        }
        else {
            [void](Save-PinnedArtifact -Lock $Lock -DestinationPath $archive)
        }

        New-Item -ItemType Directory -Path $AllowedToolRoot -Force | Out-Null
        [void](Assert-OwnedDestinationRoot `
                -DestinationRoot $DestinationRoot `
                -AllowedToolRoot $AllowedToolRoot `
                -Label "Pinned LuaLS")
        Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
        [void](Assert-LuaLanguageServerRoot -Root $staging -Locks $Locks)
        Remove-OwnedToolDirectory `
            -DestinationRoot $DestinationRoot `
            -AllowedToolRoot $AllowedToolRoot `
            -Label "Pinned LuaLS"
        Move-Item -LiteralPath $staging -Destination $DestinationRoot
        return Assert-LuaLanguageServerRoot -Root $DestinationRoot -Locks $Locks
    }
    finally {
        if ($ownsArchive -and [System.IO.File]::Exists($archive)) {
            [System.IO.File]::Delete($archive)
        }
        if ([System.IO.Directory]::Exists($staging)) {
            [System.IO.Directory]::Delete($staging, $true)
        }
    }
}

function Get-LuacheckInstallPlan {
    param($Locks)

    return @(
        [pscustomobject]@{ Name = "argparse"; Lock = Get-StatsProLockedRock -Locks $Locks -PackageName "argparse" },
        [pscustomobject]@{ Name = "luafilesystem"; Lock = Get-StatsProLockedRock -Locks $Locks -PackageName "luafilesystem" },
        [pscustomobject]@{ Name = "luacheck"; Lock = Get-StatsProLockedRock -Locks $Locks -PackageName "luacheck" }
    )
}

function Assert-LuaRocksBundle {
    param(
        $Layout,
        $Locks
    )

    foreach ($tool in @($Layout.LuaRocksPath, $Layout.LuacheckScriptPath)) {
        if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
            throw "Pinned LuaRocks bundle is missing $tool."
        }
    }
    Assert-ToolCommandVersion `
        -Label "luarocks" `
        -Path $Layout.LuaRocksPath `
        -Arguments @("--version") `
        -Pattern (Get-StatsProLockedCommandPattern -Locks $Locks -CommandName "luarocks")
    $luacheckEnvironment = Get-StatsProOwnedLuacheckEnvironment -Layout $Layout
    Assert-ToolCommandVersion `
        -Label "luacheck" `
        -Path $Layout.LuaRocksLuaPath `
        -Arguments @($Layout.LuacheckScriptPath, "--version") `
        -Pattern (Get-StatsProLockedCommandPattern -Locks $Locks -CommandName "luacheck") `
        -Environment $luacheckEnvironment
    foreach ($package in @(Get-LuacheckInstallPlan -Locks $Locks)) {
        Assert-LuarocksPackageVersion `
            -LuarocksPath $Layout.LuaRocksPath `
            -PackageName $package.Name `
            -ExpectedVersion $package.Lock.Version
    }
    return [pscustomobject]@{
        LuaRocksPath = (Resolve-Path -LiteralPath $Layout.LuaRocksPath).Path
        LuacheckScriptPath = (Resolve-Path -LiteralPath $Layout.LuacheckScriptPath).Path
    }
}

function Install-PinnedLuaRocksBundle {
    param(
        $Locks,
        $Layout
    )

    $DestinationRoot = $Layout.LuaRocksRoot
    $AllowedToolRoot = $Layout.ToolRoot
    $luaRocksLock = Get-StatsProLockedPortableTool -Locks $Locks -ToolName "luaRocks"
    [void](Assert-OwnedDestinationRoot `
            -DestinationRoot $DestinationRoot `
            -AllowedToolRoot $AllowedToolRoot `
            -Label "Pinned LuaRocks")
    $nonce = [System.Guid]::NewGuid().ToString("N")
    $downloadRoot = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) "statspro-luarocks-$nonce"))
    $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') +
        [System.IO.Path]::DirectorySeparatorChar + "statspro-luarocks-"
    if (-not $downloadRoot.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Pinned LuaRocks staging escaped the temporary directory."
    }
    [System.IO.Directory]::CreateDirectory($downloadRoot) | Out-Null
    try {
        $archive = Join-Path $downloadRoot $luaRocksLock.FileName
        [void](Save-PinnedArtifact -Lock $luaRocksLock -DestinationPath $archive)
        $rockPaths = @{}
        foreach ($package in @(Get-LuacheckInstallPlan -Locks $Locks)) {
            $rockPath = Join-Path $downloadRoot $package.Lock.FileName
            [void](Save-PinnedArtifact -Lock $package.Lock -DestinationPath $rockPath)
            $rockPaths[$package.Name] = $rockPath
        }

        $sourceRoot = Join-Path $downloadRoot "source"
        Expand-Archive -LiteralPath $archive -DestinationPath $sourceRoot -Force
        $installerRoot = Join-Path $sourceRoot "luarocks-$($luaRocksLock.Version)-win32"
        $installer = Join-Path $installerRoot "install.bat"
        if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
            throw "Pinned LuaRocks archive is missing its exact installer path."
        }

        New-Item -ItemType Directory -Path $AllowedToolRoot -Force | Out-Null
        Remove-OwnedToolDirectory `
            -DestinationRoot $DestinationRoot `
            -AllowedToolRoot $AllowedToolRoot `
            -Label "Pinned LuaRocks"
        Push-Location $installerRoot
        try {
            $installResult = Invoke-NativeCapture `
                -FilePath $installer `
                -Arguments @("/NOADMIN", "/SELFCONTAINED", "/L", "/Q", "/P", $DestinationRoot) `
                -TimeoutSeconds 120 `
                -Description "pinned LuaRocks installer"
        }
        finally {
            Pop-Location
        }
        if ($installResult.ExitCode -ne 0) {
            throw "Pinned LuaRocks installer exited with code $($installResult.ExitCode): $(Format-VersionOutput $installResult.Output)"
        }

        $luaRocks = Join-Path $DestinationRoot "luarocks.bat"
        $tree = Join-Path $DestinationRoot "systree"
        foreach ($package in @(Get-LuacheckInstallPlan -Locks $Locks)) {
            Write-Host "Installing pinned $($package.Name) $($package.Lock.Version) into the owned rock tree..."
            $installArgs = @("install", $rockPaths[$package.Name], "--tree", $tree, "--deps-mode=none")
            $result = Invoke-NativeCapture `
                -FilePath $luaRocks `
                -Arguments $installArgs `
                -TimeoutSeconds 120 `
                -Description "pinned $($package.Name) install"
            if ($result.ExitCode -ne 0) {
                throw "Pinned $($package.Name) install exited with code $($result.ExitCode): $(Format-VersionOutput $result.Output)"
            }
        }
        return Assert-LuaRocksBundle -Layout $Layout -Locks $Locks
    }
    catch {
        if (Test-Path -LiteralPath $DestinationRoot) {
            Remove-OwnedToolDirectory `
                -DestinationRoot $DestinationRoot `
                -AllowedToolRoot $AllowedToolRoot `
                -Label "Pinned LuaRocks"
        }
        throw
    }
    finally {
        if ([System.IO.Directory]::Exists($downloadRoot)) {
            [System.IO.Directory]::Delete($downloadRoot, $true)
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
        [string[]]$Arguments,
        [hashtable]$Environment = @{}
    )

    $result = Invoke-NativeCapture -FilePath $Path -Arguments $Arguments -TimeoutSeconds 30 -Description "$Label version" -Environment $Environment
    if ($result.ExitCode -eq 0) {
        Write-Host "${Label} version: $(Format-VersionOutput $result.Output)"
    }
    else {
        Write-Warning "${Label} version command exited with code $($result.ExitCode): $(Format-VersionOutput $result.Output)"
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

function Assert-LuarocksPackageVersion {
    param([string]$LuarocksPath, [string]$PackageName, [string]$ExpectedVersion)
    $result = Invoke-NativeCapture -FilePath $LuarocksPath -Arguments @("list", "--porcelain", $PackageName) -TimeoutSeconds 30 -Description "luarocks list $PackageName"
    if ($result.ExitCode -ne 0) {
        throw "luarocks list $PackageName exited with code $($result.ExitCode): $(Format-VersionOutput $result.Output)"
    }
    Assert-StatsProPackageVersionLine -Label $PackageName -Output $result.Output -ExpectedVersion $ExpectedVersion
}

function Assert-ToolCommandVersion {
    param(
        [string]$Label,
        [string]$Path,
        [string[]]$Arguments,
        [string]$Pattern,
        [hashtable]$Environment = @{}
    )
    $result = Invoke-NativeCapture -FilePath $Path -Arguments $Arguments -TimeoutSeconds 30 -Description "$Label version" -Environment $Environment
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
    $luaLock = Get-StatsProLockedPortableTool -Locks $locks -ToolName "lua51"
    Assert-Equal "locked Lua version" $luaLock.Version "5.1.5"
    Assert-Equal "locked Lua URL scheme" ([uri]$luaLock.Url).Scheme "https"
    Assert-Equal "locked Lua file name" $luaLock.FileName "lua-5.1.5_Win64_bin.zip"
    Assert-Equal "locked Lua SHA-256" $luaLock.Sha256 "5f34cf7d40a20a587ea351482a4207d93b92ef6f1983e910a13338253819fe93"
    $curlArguments = Get-StatsProPinnedCurlArguments `
        -Uri $luaLock.Url `
        -OutputPath "C:\pinned\lua.zip"
    Assert-Equal "pinned downloader requires HTTPS source" $curlArguments[-1] $luaLock.Url
    Assert-Equal "pinned downloader fixes output path" $curlArguments[-2] "C:\pinned\lua.zip"
    Assert-Equal "pinned downloader restricts redirect protocol" `
        (($curlArguments -join " ") -match "--proto-redir =https") $true
    $malformedVersionFailed = $false
    try {
        [void](Get-StatsProContentAddressedToolRoot `
                -ToolRoot "C:\owned-tools" `
                -Prefix "lua" `
                -Lock ([pscustomobject]@{
                    Version = '..\..\victim'
                    Sha256 = $luaLock.Sha256
                }))
    }
    catch { $malformedVersionFailed = $true }
    Assert-Equal "malformed Lua version cannot shape tool path" $malformedVersionFailed $true
    $luaLsLock = Get-StatsProLockedPortableTool -Locks $locks -ToolName "luaLanguageServer"
    Assert-Equal "locked LuaLS version" $luaLsLock.Version "3.18.1"
    Assert-Equal "locked LuaLS URL scheme" ([uri]$luaLsLock.Url).Scheme "https"
    Assert-Equal "locked LuaLS file name" $luaLsLock.FileName "lua-language-server-3.18.1-win32-x64.zip"
    Assert-Equal "locked LuaLS SHA-256" $luaLsLock.Sha256 "0b0c4ac671629269b847e13239b70ac7271a562e0253c789f590c8a8985addea"
    $luaRocksLock = Get-StatsProLockedPortableTool -Locks $locks -ToolName "luaRocks"
    Assert-Equal "locked LuaRocks version" $luaRocksLock.Version "2.4.4"
    Assert-Equal "locked LuaRocks URL scheme" ([uri]$luaRocksLock.Url).Scheme "https"
    Assert-Equal "locked LuaRocks file name" $luaRocksLock.FileName "luarocks-2.4.4-win32.zip"
    Assert-Equal "locked LuaRocks SHA-256" $luaRocksLock.Sha256 "763d2fbe301b5f941dd5ea4aea485fb35e75cbbdceca8cc2f18726b75f9895c1"
    Assert-Equal "locked luacheck rock version" (Get-StatsProLockedLuarocksVersion -Locks $locks -PackageName "luacheck") "1.2.0-1"
    $luacheckPlan = @(Get-LuacheckInstallPlan -Locks $locks)
    Assert-Equal "locked luacheck install plan count" $luacheckPlan.Count 3
    Assert-Equal "locked luacheck install plan order" (($luacheckPlan | ForEach-Object { $_.Name }) -join " ") "argparse luafilesystem luacheck"
    Assert-Equal "locked rock file names are unique" (($luacheckPlan | ForEach-Object { $_.Lock.FileName } | Sort-Object -Unique).Count) 3
    foreach ($package in $luacheckPlan) {
        Assert-Equal "locked $($package.Name) URL scheme" ([uri]$package.Lock.Url).Scheme "https"
        Assert-Equal "locked $($package.Name) SHA-256 length" $package.Lock.Sha256.Length 64
    }
    $bundleRoot = Get-StatsProPortableLuaRocksRoot -Locks $locks -ToolRoot "C:\owned-tools"
    if ($bundleRoot -notmatch 'luarocks-2\.4\.4-[0-9a-f]{12}$') {
        throw "Owned LuaRocks root must include the version and complete bundle fingerprint."
    }
    $ownedLayout = Get-StatsProOwnedToolLayout -Locks $locks -ToolRoot "C:\owned-tools"
    Assert-Equal "owned layout Lua path" $ownedLayout.LuaPath `
        (Join-Path $ownedLayout.LuaRoot "lua5.1.exe")
    Assert-Equal "owned layout LuaLS path" $ownedLayout.LuaLanguageServerPath `
        (Join-Path $ownedLayout.LuaLanguageServerRoot "bin\lua-language-server.exe")
    Assert-Equal "owned layout luacheck script path" $ownedLayout.LuacheckScriptPath `
        (Join-Path $ownedLayout.LuaRocksRoot "systree\lib\luarocks\rocks\luacheck\1.2.0-1\bin\luacheck")
    $invocationRootOne = New-StatsProOwnedToolInvocationRoot
    $invocationRootTwo = New-StatsProOwnedToolInvocationRoot
    Assert-Equal "concurrent invocations receive distinct owned roots" `
        ([System.StringComparer]::OrdinalIgnoreCase.Equals($invocationRootOne, $invocationRootTwo)) $false
    $selfTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-tool-selftest-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $selfTestRoot | Out-Null
    try {
        $good = Join-Path $selfTestRoot "good.bin"
        $bad = Join-Path $selfTestRoot "bad.bin"
        [System.IO.File]::WriteAllText($good, "trusted")
        [System.IO.File]::WriteAllText($bad, "tampered")
        $goodHash = (Get-FileHash -LiteralPath $good -Algorithm SHA256).Hash
        [void](Assert-StatsProPinnedArchive -Path $good -ExpectedSha256 $goodHash)
        $pathBefore = $env:PATH
        $tamperedFailed = $false
        try { [void](Assert-StatsProPinnedArchive -Path $bad -ExpectedSha256 $goodHash) }
        catch { $tamperedFailed = $true }
        Assert-Equal "tampered archive rejected" $tamperedFailed $true
        Assert-Equal "tampered archive leaves PATH unchanged" $env:PATH $pathBefore

        $manifestLayout = Get-StatsProOwnedToolLayout `
            -Locks $locks `
            -ToolRoot (Join-Path $selfTestRoot "manifest-owned")
        $manifestInputs = @(
            $manifestLayout.LuaPath,
            $manifestLayout.LuacPath,
            $manifestLayout.LuaLanguageServerPath,
            $manifestLayout.LuaRocksPath,
            $manifestLayout.LuaRocksLuaPath,
            $manifestLayout.LuacheckScriptPath,
            (Join-Path $manifestLayout.LuacheckShareRoot "luacheck\main.lua"),
            (Join-Path $manifestLayout.LuacheckShareRoot "argparse.lua"),
            (Join-Path $manifestLayout.LuacheckCPathRoot "lfs.dll")
        )
        foreach ($path in $manifestInputs) {
            New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($path)) -Force | Out-Null
            [System.IO.File]::WriteAllText($path, "owned")
        }
        Copy-Item -LiteralPath $env:ComSpec -Destination $manifestLayout.LuaLanguageServerPath -Force
        [System.IO.File]::WriteAllText(
            $manifestLayout.LuaRocksPath, "@echo off`r`necho owned-luarocks`r`n")
        [void](Write-StatsProOwnedToolManifest -Locks $locks -Layout $manifestLayout)

        $wrongMarker = Join-Path $selfTestRoot "wrong-version.marker"
        $sameMarker = Join-Path $selfTestRoot "same-version.marker"
        $wrongRoot = Join-Path $selfTestRoot "wrong-version-shadow"
        $sameRoot = Join-Path $selfTestRoot "same-version-shadow"
        New-Item -ItemType Directory -Path $wrongRoot, $sameRoot -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $wrongRoot "lua-language-server.cmd"),
            "@echo off`r`n> `"$wrongMarker`" echo wrong`r`necho 3.18.2-dev`r`n")
        [System.IO.File]::WriteAllText(
            (Join-Path $wrongRoot "luarocks.cmd"),
            "@echo off`r`n> `"$wrongMarker`" echo wrong`r`necho 3.0.0`r`n")
        [System.IO.File]::WriteAllText(
            (Join-Path $sameRoot "lua-language-server.cmd"),
            "@echo off`r`n> `"$sameMarker`" echo same`r`necho 3.18.1`r`n")
        [System.IO.File]::WriteAllText(
            (Join-Path $sameRoot "luarocks.cmd"),
            "@echo off`r`n> `"$sameMarker`" echo same`r`necho 2.4.4`r`n")
        foreach ($shadowRoot in @($wrongRoot, $sameRoot)) {
            try {
                $env:PATH = $shadowRoot + [System.IO.Path]::PathSeparator + $pathBefore
                $resolvedManifest = Read-StatsProOwnedToolManifest -Locks $locks -Layout $manifestLayout
                $result = Invoke-NativeCapture `
                    -FilePath $resolvedManifest.LuaLanguageServerPath `
                    -Arguments @("/d", "/c", "echo owned") `
                    -TimeoutSeconds 10 `
                    -Description "owned manifest execution"
                Assert-Equal "owned manifest command exit" $result.ExitCode 0
                Assert-Equal "owned manifest command executed" (($result.Output -join "`n") -match '^owned$') $true
                $luaRocksResult = Invoke-NativeCapture `
                    -FilePath $resolvedManifest.LuaRocksPath `
                    -Arguments @("--version") `
                    -TimeoutSeconds 10 `
                    -Description "owned LuaRocks manifest execution"
                Assert-Equal "owned LuaRocks manifest command exit" $luaRocksResult.ExitCode 0
                Assert-Equal "owned LuaRocks manifest command executed" (($luaRocksResult.Output -join "`n") -match '^owned-luarocks$') $true
                Assert-Equal "wrong-version PATH shadow not executed" (Test-Path -LiteralPath $wrongMarker) $false
                Assert-Equal "same-version PATH shadow not executed" (Test-Path -LiteralPath $sameMarker) $false
            }
            finally {
                $env:PATH = $pathBefore
            }
        }

        $oldLuaEnvironment = @{}
        foreach ($name in @("LUA_INIT", "LUA_INIT_5_1", "LUA_PATH", "LUA_PATH_5_1", "LUA_CPATH", "LUA_CPATH_5_1")) {
            $oldLuaEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, "self-test-canary", "Process")
        }
        $luaEnvironmentMarker = Join-Path $selfTestRoot "lua-environment.marker"
        try {
            $environmentResult = Invoke-NativeCapture `
                -FilePath $env:ComSpec `
                -Arguments @("/d", "/c", "if defined LUA_INIT (> `"$luaEnvironmentMarker`" echo leak) else if defined LUA_INIT_5_1 (> `"$luaEnvironmentMarker`" echo leak) else if defined LUA_PATH (> `"$luaEnvironmentMarker`" echo leak) else if defined LUA_PATH_5_1 (> `"$luaEnvironmentMarker`" echo leak) else if defined LUA_CPATH (> `"$luaEnvironmentMarker`" echo leak) else if defined LUA_CPATH_5_1 (> `"$luaEnvironmentMarker`" echo leak)") `
                -TimeoutSeconds 10 `
                -Description "isolated Lua environment"
            Assert-Equal "isolated Lua environment command exit" $environmentResult.ExitCode 0
            Assert-Equal "ambient Lua environment removed" (Test-Path -LiteralPath $luaEnvironmentMarker) $false
        }
        finally {
            foreach ($name in $oldLuaEnvironment.Keys) {
                [Environment]::SetEnvironmentVariable($name, $oldLuaEnvironment[$name], "Process")
            }
        }

        [System.IO.File]::WriteAllText(
            (Join-Path $manifestLayout.LuacheckShareRoot "argparse.lua"), "tampered")
        $manifestTamperFailed = $false
        try { [void](Read-StatsProOwnedToolManifest -Locks $locks -Layout $manifestLayout) }
        catch { $manifestTamperFailed = $true }
        Assert-Equal "owned manifest rejects replaced runtime module" $manifestTamperFailed $true

        $installRoot = Join-Path $selfTestRoot "tool-root"
        $installDestination = Join-Path $installRoot "lua-5.1.5-test"
        $installerFailed = $false
        try {
            Install-PinnedLua51 `
                -Lock $luaLock `
                -Locks $locks `
                -DestinationRoot $installDestination `
                -AllowedToolRoot $installRoot `
                -ArchivePathOverride $bad | Out-Null
        }
        catch { $installerFailed = $true }
        Assert-Equal "tampered installer rejected" $installerFailed $true
        Assert-Equal "tampered installer leaves destination absent" (Test-Path -LiteralPath $installDestination) $false
        Assert-Equal "tampered installer leaves tool root absent" (Test-Path -LiteralPath $installRoot) $false
        Assert-Equal "tampered installer leaves PATH unchanged" $env:PATH $pathBefore
    }
    finally {
        [System.IO.Directory]::Delete($selfTestRoot, $true)
    }
    Assert-StatsProPackageVersionLine -Label "luacheck" -Output @("luacheck`t1.2.0-1`tinstalled`tC:/rocks") -ExpectedVersion "1.2.0-1"

    Write-Host "Install check tools self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if ($PinnedLuaIntegrationTest) {
    $integrationLocks = Read-StatsProToolLocks -Path $ToolLockPath
    $integrationToolRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
        "statspro-pinned-toolchain-root-" + [System.Guid]::NewGuid().ToString("N"))
    $integrationLuaLock = Get-StatsProLockedPortableTool -Locks $integrationLocks -ToolName "lua51"
    $integrationLuaLsLock = Get-StatsProLockedPortableTool -Locks $integrationLocks -ToolName "luaLanguageServer"
    $integrationLayout = Get-StatsProOwnedToolLayout -Locks $integrationLocks -ToolRoot $integrationToolRoot
    try {
        [void](Install-PinnedLua51 `
                -Lock $integrationLuaLock `
                -Locks $integrationLocks `
                -DestinationRoot $integrationLayout.LuaRoot `
                -AllowedToolRoot $integrationToolRoot `
                -SkipPathMutation)
        [void](Install-PinnedLuaLanguageServer `
                -Lock $integrationLuaLsLock `
                -Locks $integrationLocks `
                -DestinationRoot $integrationLayout.LuaLanguageServerRoot `
                -AllowedToolRoot $integrationToolRoot)
        [void](Install-PinnedLuaRocksBundle `
                -Locks $integrationLocks `
                -Layout $integrationLayout)
        [void](Assert-Lua51Pair -Root $integrationLayout.LuaRoot -Locks $integrationLocks)
        [void](Assert-LuaLanguageServerRoot -Root $integrationLayout.LuaLanguageServerRoot -Locks $integrationLocks)
        [void](Assert-LuaRocksBundle -Layout $integrationLayout -Locks $integrationLocks)
        [void](Write-StatsProOwnedToolManifest -Locks $integrationLocks -Layout $integrationLayout)
        [void](Read-StatsProOwnedToolManifest -Locks $integrationLocks -Layout $integrationLayout)
        Write-Host "Pinned toolchain integration test passed."
    }
    finally {
        if (Test-Path -LiteralPath $integrationToolRoot -PathType Container) {
            [System.IO.Directory]::Delete($integrationToolRoot, $true)
        }
    }
    return
}

$ToolLocks = Read-StatsProToolLocks -Path $ToolLockPath
if ($EnforceToolLocks -and -not $Install) {
    throw "Enforcing tool locks requires -Install so every owned artifact is freshly verified."
}
if ($EphemeralOwnedToolRoot -and ([string]::IsNullOrWhiteSpace($OwnedToolRoot) -or -not $Install)) {
    throw "Ephemeral owned tool roots require both -OwnedToolRoot and -Install."
}

if ([string]::IsNullOrWhiteSpace($OwnedToolRoot)) {
    $OwnedToolRoot = if ($Install) {
        New-StatsProOwnedToolInvocationRoot
    }
    else {
        Get-StatsProPortableToolRoot
    }
}
$OwnedToolRoot = [System.IO.Path]::GetFullPath($OwnedToolRoot)

$PortableLuaLock = Get-StatsProLockedPortableTool -Locks $ToolLocks -ToolName "lua51"
$PortableLuaLsLock = Get-StatsProLockedPortableTool -Locks $ToolLocks -ToolName "luaLanguageServer"
$OwnedLayout = Get-StatsProOwnedToolLayout -Locks $ToolLocks -ToolRoot $OwnedToolRoot
$PortableToolRoot = $OwnedLayout.ToolRoot
$PortableLuaRoot = $OwnedLayout.LuaRoot
$PortableLuaLsRoot = $OwnedLayout.LuaLanguageServerRoot
$PortableLuaRocksRoot = $OwnedLayout.LuaRocksRoot
$PortableLuaLsPath = $OwnedLayout.LuaLanguageServerPath
$PortableLuaRocksPath = $OwnedLayout.LuaRocksPath
$PortableLuacheckPath = $OwnedLayout.GeneratedLuacheckPath
$PortableLuaPath = $OwnedLayout.LuaPath
$PortableLuacPath = $OwnedLayout.LuacPath
$luaCandidates = @((Join-Path $PortableLuaRoot "lua5.1.exe"), "lua5.1", "C:\ProgramData\chocolatey\lib\lua51\tools\lua5.1.exe")
$luacCandidates = @((Join-Path $PortableLuaRoot "luac5.1.exe"), "luac5.1", "C:\ProgramData\chocolatey\lib\lua51\tools\luac5.1.exe")
if ($Install) {
    [void](Install-PinnedLua51 `
            -Lock $PortableLuaLock `
            -Locks $ToolLocks `
            -DestinationRoot $PortableLuaRoot `
            -AllowedToolRoot $PortableToolRoot `
            -SkipPathMutation)
    $PortableLuaLsPath = Install-PinnedLuaLanguageServer `
        -Lock $PortableLuaLsLock `
        -Locks $ToolLocks `
        -DestinationRoot $PortableLuaLsRoot `
        -AllowedToolRoot $PortableToolRoot
    $bundle = Install-PinnedLuaRocksBundle `
        -Locks $ToolLocks `
        -Layout $OwnedLayout
    $PortableLuaRocksPath = $bundle.LuaRocksPath
    [void](Write-StatsProOwnedToolManifest -Locks $ToolLocks -Layout $OwnedLayout)
    if (-not $EphemeralOwnedToolRoot) {
        Publish-StatsProOwnedToolRoot -Layout $OwnedLayout
    }
}

if ($EnforceToolLocks) {
    $OwnedTools = Read-StatsProOwnedToolManifest -Locks $ToolLocks -Layout $OwnedLayout
    $Lua = $OwnedTools.LuaPath
    $Luac = $OwnedTools.LuacPath
    $LuaLanguageServer = $OwnedTools.LuaLanguageServerPath
    $Luarocks = $OwnedTools.LuaRocksPath
    $Luacheck = $OwnedTools.LuacheckScriptPath
    $LuacheckCommand = $OwnedTools.LuaRocksLuaPath
    $LuacheckArgumentsPrefix = @($Luacheck)
    $LuacheckEnvironment = $OwnedTools.LuacheckEnvironment
}
else {
    $Lua = Require-Tool `
        -Label "lua5.1" `
        -Names $luaCandidates
    $Luac = Require-Tool `
        -Label "luac5.1" `
        -Names $luacCandidates
    $LuaLanguageServer = Require-Tool `
        -Label "lua-language-server" `
        -Names @($PortableLuaLsPath, "lua-language-server")
    $Luarocks = Require-Tool `
        -Label "luarocks" `
        -Names @($PortableLuaRocksPath, "luarocks")
    $Luacheck = Require-Tool `
        -Label "luacheck" `
        -Names @($PortableLuacheckPath, "luacheck")
    $LuacheckCommand = $Luacheck
    $LuacheckArgumentsPrefix = @()
    $LuacheckEnvironment = @{}
}

$LuaVersionResult = Invoke-NativeCapture -FilePath $Lua -Arguments @("-v")
$LuaVersion = $LuaVersionResult.Output -join "`n"
if ($LuaVersionResult.ExitCode -ne 0) {
    throw "lua -v exited with code $($LuaVersionResult.ExitCode): $LuaVersion"
}
if ($LuaVersion -notmatch "Lua\s+5\.1") {
    throw "StatsPro smoke requires Lua 5.1 because it uses setfenv; found: $LuaVersion"
}

Write-Host "luacheck script: $Luacheck"

Write-Host "== Tool versions =="
Write-ToolVersionReport -Label "lua5.1" -Path $Lua -Arguments @("-v")
Write-ToolVersionReport -Label "luac5.1" -Path $Luac -Arguments @("-v")
Write-ToolVersionReport -Label "lua-language-server" -Path $LuaLanguageServer -Arguments @("--version")
Write-ToolVersionReport -Label "luarocks" -Path $Luarocks -Arguments @("--version")
Write-ToolVersionReport -Label "luacheck" -Path $LuacheckCommand -Arguments ($LuacheckArgumentsPrefix + @("--version")) -Environment $LuacheckEnvironment

Write-LuarocksPackageReport -LuarocksPath $Luarocks -PackageName "luacheck"
Write-LuarocksPackageReport -LuarocksPath $Luarocks -PackageName "argparse"
Write-LuarocksPackageReport -LuarocksPath $Luarocks -PackageName "luafilesystem"

if ($EnforceToolLocks) {
    Assert-ToolCommandVersion -Label "lua5.1" -Path $Lua -Arguments @("-v") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "lua5.1")
    Assert-ToolCommandVersion -Label "luac5.1" -Path $Luac -Arguments @("-v") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "luac5.1")
    Assert-ToolCommandVersion -Label "lua-language-server" -Path $LuaLanguageServer -Arguments @("--version") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "lua-language-server")
    Assert-ToolCommandVersion -Label "luarocks" -Path $Luarocks -Arguments @("--version") -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "luarocks")
    Assert-ToolCommandVersion -Label "luacheck" -Path $LuacheckCommand -Arguments ($LuacheckArgumentsPrefix + @("--version")) -Pattern (Get-StatsProLockedCommandPattern -Locks $ToolLocks -CommandName "luacheck") -Environment $LuacheckEnvironment

    Assert-LuarocksPackageVersion -LuarocksPath $Luarocks -PackageName "luacheck" -ExpectedVersion (Get-StatsProLockedLuarocksVersion -Locks $ToolLocks -PackageName "luacheck")
    Assert-LuarocksPackageVersion -LuarocksPath $Luarocks -PackageName "argparse" -ExpectedVersion (Get-StatsProLockedLuarocksVersion -Locks $ToolLocks -PackageName "argparse")
    Assert-LuarocksPackageVersion -LuarocksPath $Luarocks -PackageName "luafilesystem" -ExpectedVersion (Get-StatsProLockedLuarocksVersion -Locks $ToolLocks -PackageName "luafilesystem")
    Write-Host "Tool version locks enforced."
}

Write-Host "StatsPro check tools are available."
