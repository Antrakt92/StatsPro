function Format-StatsProNativeArgument {
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

function Split-StatsProNativeOutput {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return @()
    }
    return @($Text -split "\r?\n" | Where-Object { $_ -ne "" })
}

function Format-StatsProVersionOutput {
    param([object[]]$Output)

    $lines = @($Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne "" })
    if ($lines.Count -eq 0) {
        return "<no version output>"
    }
    return ($lines -join " | ")
}

function Stop-StatsProNativeProcessTree {
    param([System.Diagnostics.Process]$Process)

    # Never send a PID-based command after the owned root has exited: that PID
    # could now identify another process. The caller still reports its timeout.
    if ($Process.HasExited) { return }
    if ($env:OS -eq "Windows_NT") {
        $start = [System.Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Join-Path ([Environment]::GetFolderPath("System")) "taskkill.exe"
        $start.Arguments = "/PID $($Process.Id) /T /F"
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $terminator = [System.Diagnostics.Process]::new()
        $terminator.StartInfo = $start
        try {
            [void]$terminator.Start()
            $stdout = $terminator.StandardOutput.ReadToEndAsync()
            $stderr = $terminator.StandardError.ReadToEndAsync()
            if (-not $terminator.WaitForExit(10000)) {
                if (-not $terminator.HasExited) { $terminator.Kill() }
                throw "Owned process-tree termination exceeded 10 seconds."
            }
            if ($terminator.ExitCode -ne 0) {
                throw "Owned process-tree termination exited with code $($terminator.ExitCode)."
            }
            [void]$stdout.Wait(1000)
            [void]$stderr.Wait(1000)
        }
        finally { $terminator.Dispose() }
    }
    elseif ($Process.GetType().GetMethod("Kill", [type[]]@([bool]))) {
        $Process.Kill($true)
    }
    else {
        $Process.Kill()
    }
    if (-not $Process.WaitForExit(5000)) {
        throw "Owned process did not exit after process-tree termination."
    }
}

function Invoke-StatsProNativeCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 0,
        [string]$Description = $null,
        [switch]$IsolateLuaEnvironment,
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
    $startInfo.Arguments = (@($effectiveArguments) | ForEach-Object { Format-StatsProNativeArgument $_ }) -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    if ($IsolateLuaEnvironment) {
        Set-StatsProIsolatedLuaProcessEnvironment -StartInfo $startInfo -Environment $Environment
    }

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
            $cleanupFailure = $null
            try {
                Stop-StatsProNativeProcessTree -Process $process
            }
            catch {
                $cleanupFailure = $_.Exception.Message
            }
            $timeoutOutput = @()
            foreach ($streamTask in @($stdoutTask, $stderrTask)) {
                try {
                    if ($streamTask.Wait(1000)) { $timeoutOutput += Split-StatsProNativeOutput $streamTask.Result }
                }
                catch {
                    # Reading diagnostics must never replace the original timeout.
                    $timeoutOutput += "Output capture failed: $($_.Exception.Message)"
                }
            }
            $details = if ($timeoutOutput.Count -gt 0) { " Output: $($timeoutOutput -join ' ')" } else { "" }
            if ($cleanupFailure) { $details += " Tree cleanup failed: $cleanupFailure" }
            throw "Timed out after $TimeoutSeconds second(s): $displayName.$details"
        }
        if (-not $stdoutTask.Wait(5000)) {
            throw "Timed out reading stdout from $displayName."
        }
        if (-not $stderrTask.Wait(5000)) {
            throw "Timed out reading stderr from $displayName."
        }
        $output = @()
        $output += Split-StatsProNativeOutput $stdoutTask.Result
        $output += Split-StatsProNativeOutput $stderrTask.Result
        return @{
            ExitCode = $process.ExitCode
            Output = $output
        }
    }
    finally {
        $process.Dispose()
    }
}
