param(
    [ValidateSet("RefuseExisting", "ValidateStart", "CreateDraft", "MarkMarketplaceStarted", "AttachAssets", "Publish", "RetirePrepared")]
    [string]$Mode,
    [string]$Repository,
    [string]$ExpectedTag,
    [string]$ExpectedCommitSha,
    [string]$ExpectedRunId,
    [string]$ExpectedRunAttempt,
    [string]$ExpectedArchiveSha256,
    [string]$ExpectedCandidateSha256,
    [string]$ArchivePath,
    [string]$ReleaseJsonPath,
    [string]$NotesPath,
    [string]$ManifestPath,
    [int]$AttestationAttempts = 6,
    [int]$TimeoutMinutes = 10,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "release-check-contract.ps1")
. (Join-Path $PSScriptRoot "release-tag-contract.ps1")

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

function Get-DeadlineRemainingMilliseconds {
    param(
        [datetime]$Deadline,
        [scriptblock]$Now = $null
    )

    if ($null -eq $Now) {
        $Now = { Get-Date }
    }
    $remaining = ($Deadline - (& $Now)).TotalMilliseconds
    if ($remaining -le 0) {
        return 0
    }
    return [int][Math]::Min([int]::MaxValue, [Math]::Ceiling($remaining))
}

function Get-BoundedNativeDiagnostic {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxCharacters = 4096
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }
    $normalized = ($Text -replace "\r?\n", " | ").Trim()
    if ($normalized.Length -le $MaxCharacters) {
        return $normalized
    }
    return "<truncated> " + $normalized.Substring($normalized.Length - $MaxCharacters)
}

function Get-CompletedTaskText {
    param([AllowNull()][object]$Task)

    if ($null -eq $Task -or $Task.Status -ne [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
        return ""
    }
    return [string]$Task.Result
}

function Initialize-WindowsNativeJobType {
    if ($null -ne ("StatsPro.ReleaseProcessJob" -as [type])) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace StatsPro
{
    public static class ReleaseProcessJob
    {
        private const uint JobObjectExtendedLimitInformation = 9;
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimitInformation
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimitInformation
        {
            public BasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            uint informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static IntPtr CreateKillOnClose()
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed");
            }

            int size = Marshal.SizeOf(typeof(ExtendedLimitInformation));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                ExtendedLimitInformation information = new ExtendedLimitInformation();
                information.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
                Marshal.StructureToPtr(information, buffer, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size))
                {
                    int error = Marshal.GetLastWin32Error();
                    CloseHandle(job);
                    throw new Win32Exception(error, "SetInformationJobObject failed");
                }
                return job;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public static void Assign(IntPtr job, IntPtr process)
        {
            if (!AssignProcessToJobObject(job, process))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "AssignProcessToJobObject failed");
            }
        }

        public static void Terminate(IntPtr job)
        {
            if (!TerminateJobObject(job, 1))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "TerminateJobObject failed");
            }
        }

        public static void Close(IntPtr job)
        {
            if (job != IntPtr.Zero && !CloseHandle(job))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CloseHandle failed");
            }
        }
    }
}
'@ -Language CSharp -ErrorAction Stop
}

function New-NativeProcessContainment {
    param([string]$Description)

    if ($env:OS -eq "Windows_NT") {
        try {
            Initialize-WindowsNativeJobType
            $jobHandle = [StatsPro.ReleaseProcessJob]::CreateKillOnClose()
            $gateName = "Local\StatsPro.ReleaseProcessGate.$([System.Guid]::NewGuid().ToString('N'))"
            $gate = [System.Threading.EventWaitHandle]::new(
                $false,
                [System.Threading.EventResetMode]::ManualReset,
                $gateName)
        }
        catch {
            if ($jobHandle) {
                try { [StatsPro.ReleaseProcessJob]::Close($jobHandle) } catch {}
            }
            throw "$Description cannot start because Windows Job Object containment is unavailable: $($_.Exception.Message)"
        }
        return [pscustomobject]@{
            Kind           = "WindowsJob"
            JobHandle      = $jobHandle
            Gate           = $gate
            GateName       = $gateName
            ProcessGroupId = 0
            KillPath       = $null
            Terminated     = $false
            Released       = $false
        }
    }

    $setSid = Get-Command setsid -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $kill = Get-Command kill -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $setSid -or -not $kill) {
        throw "$Description cannot start because Unix process-group containment requires setsid and kill."
    }
    return [pscustomobject]@{
        Kind           = "UnixProcessGroup"
        SetSidPath     = $setSid.Source
        KillPath       = $kill.Source
        ProcessGroupId = 0
        Terminated     = $false
        Released       = $false
    }
}

function Get-WindowsNativeGateEncodedCommand {
    $wrapper = @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class StatsProNativeGateLauncher
{
    private const uint StartfUseStdHandles = 0x00000100;
    private const uint CreateNoWindow = 0x08000000;
    private const uint DuplicateSameAccess = 0x00000002;
    private const uint Infinite = 0xFFFFFFFF;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public uint cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int standardHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DuplicateHandle(
        IntPtr sourceProcess,
        IntPtr sourceHandle,
        IntPtr targetProcess,
        out IntPtr targetHandle,
        uint desiredAccess,
        bool inheritHandle,
        uint options);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref StartupInfo startupInfo,
        out ProcessInformation processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private static IntPtr DuplicateStandardHandle(int standardHandle)
    {
        IntPtr source = GetStdHandle(standardHandle);
        if (source == IntPtr.Zero || source == new IntPtr(-1))
        {
            return IntPtr.Zero;
        }
        IntPtr duplicate;
        IntPtr current = GetCurrentProcess();
        if (!DuplicateHandle(current, source, current, out duplicate, 0, true, DuplicateSameAccess))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "DuplicateHandle failed");
        }
        return duplicate;
    }

    public static int Run(string commandLine, string workingDirectory)
    {
        IntPtr standardInput = IntPtr.Zero;
        IntPtr standardOutput = IntPtr.Zero;
        IntPtr standardError = IntPtr.Zero;
        ProcessInformation process = new ProcessInformation();
        try
        {
            standardInput = DuplicateStandardHandle(-10);
            standardOutput = DuplicateStandardHandle(-11);
            standardError = DuplicateStandardHandle(-12);
            if (standardOutput == IntPtr.Zero || standardError == IntPtr.Zero)
            {
                throw new InvalidOperationException("The native gate has no inheritable stdout/stderr handles.");
            }

            StartupInfo startup = new StartupInfo();
            startup.cb = (uint)Marshal.SizeOf(typeof(StartupInfo));
            startup.dwFlags = StartfUseStdHandles;
            startup.hStdInput = standardInput;
            startup.hStdOutput = standardOutput;
            startup.hStdError = standardError;
            StringBuilder mutableCommandLine = new StringBuilder(commandLine);
            if (!CreateProcess(
                null,
                mutableCommandLine,
                IntPtr.Zero,
                IntPtr.Zero,
                true,
                CreateNoWindow,
                IntPtr.Zero,
                workingDirectory,
                ref startup,
                out process))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcess failed");
            }

            uint waitResult = WaitForSingleObject(process.hProcess, Infinite);
            if (waitResult != 0)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "WaitForSingleObject failed");
            }
            uint exitCode;
            if (!GetExitCodeProcess(process.hProcess, out exitCode))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetExitCodeProcess failed");
            }
            return unchecked((int)exitCode);
        }
        finally
        {
            if (process.hThread != IntPtr.Zero) { CloseHandle(process.hThread); }
            if (process.hProcess != IntPtr.Zero) { CloseHandle(process.hProcess); }
            if (standardInput != IntPtr.Zero) { CloseHandle(standardInput); }
            if (standardOutput != IntPtr.Zero) { CloseHandle(standardOutput); }
            if (standardError != IntPtr.Zero) { CloseHandle(standardError); }
        }
    }
}
"@ -Language CSharp -ErrorAction Stop

function Format-TargetArgument {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument -or $Argument -eq "") { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $slash = [string][char]92
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $pendingSlashes = 0
    foreach ($char in $Argument.ToCharArray()) {
        if ($char -eq [char]92) { $pendingSlashes++; continue }
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
    if ($pendingSlashes -gt 0) { [void]$builder.Append($slash * ($pendingSlashes * 2)) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

$gate = $null
try {
    $gateName = [Environment]::GetEnvironmentVariable("STATSPRO_NATIVE_GATE_NAME")
    $payloadBase64 = [Environment]::GetEnvironmentVariable("STATSPRO_NATIVE_GATE_PAYLOAD")
    if ([string]::IsNullOrWhiteSpace($gateName) -or [string]::IsNullOrWhiteSpace($payloadBase64)) {
        throw "Native gate environment is incomplete."
    }
    $gate = [System.Threading.EventWaitHandle]::OpenExisting($gateName)
    if (-not $gate.WaitOne()) { throw "Native gate wait failed." }

    $payloadJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payloadBase64))
    $payload = $payloadJson | ConvertFrom-Json
    [Environment]::SetEnvironmentVariable("STATSPRO_NATIVE_GATE_NAME", $null)
    [Environment]::SetEnvironmentVariable("STATSPRO_NATIVE_GATE_PAYLOAD", $null)
    $commandLine = @(
        (Format-TargetArgument ([string]$payload.FilePath))
        @($payload.Arguments | ForEach-Object { Format-TargetArgument ([string]$_) })
    ) -join " "
    exit [StatsProNativeGateLauncher]::Run($commandLine, [string]$payload.WorkingDirectory)
}
catch {
    [Console]::Error.WriteLine("StatsPro native launch gate failed: " + $_.Exception.Message)
    exit 125
}
finally {
    if ($gate) { $gate.Dispose() }
}
'@
    return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapper))
}

function Set-WindowsNativeGatePayload {
    param(
        [System.Diagnostics.ProcessStartInfo]$StartInfo,
        [object]$Containment,
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $payload = [ordered]@{
        FilePath         = $FilePath
        Arguments        = @($Arguments)
        WorkingDirectory = $WorkingDirectory
    }
    $payloadJson = $payload | ConvertTo-Json -Depth 4 -Compress
    $payloadBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payloadJson))
    $StartInfo.EnvironmentVariables["STATSPRO_NATIVE_GATE_NAME"] = $Containment.GateName
    $StartInfo.EnvironmentVariables["STATSPRO_NATIVE_GATE_PAYLOAD"] = $payloadBase64
}

function Set-NativeProcessContainment {
    param(
        [object]$Containment,
        [System.Diagnostics.Process]$Process,
        [string]$Description,
        [datetime]$Deadline,
        [scriptblock]$AssignWindowsJob = $null
    )

    if ($Containment.Kind -eq "WindowsJob") {
        if ($null -eq $AssignWindowsJob) {
            $AssignWindowsJob = {
                param([object]$JobContainment, [System.Diagnostics.Process]$JobProcess)
                [StatsPro.ReleaseProcessJob]::Assign($JobContainment.JobHandle, $JobProcess.Handle)
            }
        }
        try {
            & $AssignWindowsJob $Containment $Process
        }
        catch {
            try { if (-not $Process.HasExited) { $Process.Kill() } } catch {}
            throw "$Description started but could not be assigned to its Windows Job Object: $($_.Exception.Message)"
        }
        try {
            if ((Get-DeadlineRemainingMilliseconds -Deadline $Deadline) -lt 1) {
                throw [System.TimeoutException]::new("Deadline expired before signalling the contained Windows target launch gate.")
            }
            if (-not $Containment.Gate.Set()) {
                throw "The native launch gate could not be signalled."
            }
        }
        catch {
            try { [StatsPro.ReleaseProcessJob]::Terminate($Containment.JobHandle) } catch {}
            $Containment.Terminated = $true
            throw "$Description was contained but its launch gate failed before target start: $($_.Exception.Message)"
        }
        return
    }
    $Containment.ProcessGroupId = $Process.Id
}

function Invoke-UnixProcessGroupSignal {
    param(
        [object]$Containment,
        [ValidateSet("0", "TERM", "KILL")][string]$Signal,
        [datetime]$Deadline
    )

    $remainingMilliseconds = Get-DeadlineRemainingMilliseconds -Deadline $Deadline
    if ($remainingMilliseconds -lt 1) {
        throw "kill -$Signal could not run before the process-group cleanup deadline."
    }
    $signalInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $signalInfo.FileName = $Containment.KillPath
    $signalInfo.Arguments = "-$Signal -- -$($Containment.ProcessGroupId)"
    $signalInfo.UseShellExecute = $false
    $signalInfo.CreateNoWindow = $true
    $signalInfo.RedirectStandardOutput = $true
    $signalInfo.RedirectStandardError = $true
    $signalProcess = [System.Diagnostics.Process]::new()
    $signalProcess.StartInfo = $signalInfo
    try {
        [void]$signalProcess.Start()
        $stdoutTask = $signalProcess.StandardOutput.ReadToEndAsync()
        $stderrTask = $signalProcess.StandardError.ReadToEndAsync()
        if (-not $signalProcess.WaitForExit($remainingMilliseconds)) {
            try { $signalProcess.Kill() } catch {}
            throw "kill -$Signal exceeded its cleanup bound."
        }
        $remainingMilliseconds = Get-DeadlineRemainingMilliseconds -Deadline $Deadline
        if ($remainingMilliseconds -lt 1 -or
            -not $stdoutTask.Wait($remainingMilliseconds) -or
            -not $stderrTask.Wait((Get-DeadlineRemainingMilliseconds -Deadline $Deadline))) {
            throw "kill -$Signal output did not drain before the process-group cleanup deadline."
        }
        return [pscustomobject]@{
            ExitCode = $signalProcess.ExitCode
            StdOut   = [string]$stdoutTask.Result
            StdErr   = [string]$stderrTask.Result
        }
    }
    finally {
        $signalProcess.Dispose()
    }
}

function Test-UnixProcessGroupMissingResult {
    param([object]$Result)

    return $Result.ExitCode -ne 0 -and [string]$Result.StdErr -match '(?i)no such process'
}

function Assert-UnixProcessGroupAbsent {
    param(
        [object]$Containment,
        [datetime]$Deadline,
        [string]$Description
    )

    while ((Get-DeadlineRemainingMilliseconds -Deadline $Deadline) -gt 0) {
        $probe = Invoke-UnixProcessGroupSignal -Containment $Containment -Signal "0" -Deadline $Deadline
        if (Test-UnixProcessGroupMissingResult -Result $probe) {
            return
        }
        if ($probe.ExitCode -ne 0) {
            throw "$Description process-group absence probe failed: $($probe.StdErr.Trim())"
        }
        Start-Sleep -Milliseconds ([Math]::Min(50, (Get-DeadlineRemainingMilliseconds -Deadline $Deadline)))
    }
    throw "$Description Unix process group $($Containment.ProcessGroupId) still existed after bounded cleanup."
}

function Close-NativeProcessContainment {
    param(
        [AllowNull()][object]$Containment
    )

    if ($null -eq $Containment -or $Containment.Released) {
        return
    }
    try {
        if ($Containment.Kind -eq "WindowsJob") {
            try { $Containment.Gate.Dispose() } finally {
                [StatsPro.ReleaseProcessJob]::Close($Containment.JobHandle)
            }
        }
    }
    finally {
        $Containment.Released = $true
    }
}

function Stop-NativeProcessTree {
    param(
        [System.Diagnostics.Process]$Process,
        [object]$Containment,
        [string]$Description,
        [int]$CleanupMilliseconds = 5000,
        [scriptblock]$RunUnixProcessGroupSignal = $null,
        [scriptblock]$VerifyUnixProcessGroupAbsent = $null,
        [scriptblock]$KillUnixRoot = $null
    )

    if ($Containment.Kind -eq "WindowsJob") {
        try {
            [StatsPro.ReleaseProcessJob]::Terminate($Containment.JobHandle)
        }
        catch {
            throw "$Description Windows Job Object termination failed: $($_.Exception.Message)"
        }
        $Containment.Terminated = $true
        if (-not $Process.HasExited -and -not $Process.WaitForExit($CleanupMilliseconds)) {
            throw "$Description root did not exit after Windows Job Object termination."
        }
        return "Windows Job Object"
    }

    if ($null -eq $KillUnixRoot) {
        $KillUnixRoot = {
            param([System.Diagnostics.Process]$RootProcess)
            $RootProcess.Kill()
        }
    }

    $cleanupDeadline = (Get-Date).AddMilliseconds($CleanupMilliseconds)
    $termError = $null
    try {
        $termResult = if ($null -eq $RunUnixProcessGroupSignal) {
            Invoke-UnixProcessGroupSignal `
                -Containment $Containment `
                -Signal "TERM" `
                -Deadline $cleanupDeadline
        }
        else {
            & $RunUnixProcessGroupSignal $Containment "TERM" $cleanupDeadline
        }
        if ($termResult.ExitCode -ne 0 -and -not (Test-UnixProcessGroupMissingResult -Result $termResult)) {
            $termError = "TERM failed: $($termResult.StdErr.Trim())"
        }
    }
    catch {
        $termError = "TERM failed: $($_.Exception.Message)"
    }
    if (-not $Process.HasExited) {
        $waitMilliseconds = [Math]::Min(250, (Get-DeadlineRemainingMilliseconds -Deadline $cleanupDeadline))
        if ($waitMilliseconds -gt 0) {
            [void]$Process.WaitForExit($waitMilliseconds)
        }
    }
    $rootKillError = $null
    if (-not $Process.HasExited) {
        try {
            & $KillUnixRoot $Process
        }
        catch {
            $rootExitedAfterKillRace = $false
            try { $rootExitedAfterKillRace = $Process.HasExited } catch {}
            if (-not $rootExitedAfterKillRace) {
                $rootKillError = $_.Exception.Message
            }
        }
        if (-not $Process.HasExited) {
            $remainingMilliseconds = Get-DeadlineRemainingMilliseconds -Deadline $cleanupDeadline
            if ($remainingMilliseconds -gt 0) {
                [void]$Process.WaitForExit([Math]::Min(250, $remainingMilliseconds))
            }
        }
    }

    $groupKillError = $null
    try {
        $killResult = if ($null -eq $RunUnixProcessGroupSignal) {
            Invoke-UnixProcessGroupSignal `
                -Containment $Containment `
                -Signal "KILL" `
                -Deadline $cleanupDeadline
        }
        else {
            & $RunUnixProcessGroupSignal $Containment "KILL" $cleanupDeadline
        }
        if ($killResult.ExitCode -ne 0 -and -not (Test-UnixProcessGroupMissingResult -Result $killResult)) {
            $groupKillError = "KILL failed: $($killResult.StdErr.Trim())"
        }
    }
    catch {
        $groupKillError = "KILL failed: $($_.Exception.Message)"
    }
    $absenceError = $null
    try {
        if ($null -eq $VerifyUnixProcessGroupAbsent) {
            Assert-UnixProcessGroupAbsent `
                -Containment $Containment `
                -Deadline $cleanupDeadline `
                -Description $Description
        }
        else {
            & $VerifyUnixProcessGroupAbsent $Containment $cleanupDeadline $Description
        }
    }
    catch {
        $absenceError = $_.Exception.Message
    }

    if (-not $Process.HasExited) {
        $remainingMilliseconds = Get-DeadlineRemainingMilliseconds -Deadline $cleanupDeadline
        if ($remainingMilliseconds -gt 0) {
            [void]$Process.WaitForExit($remainingMilliseconds)
        }
    }
    $rootStillRunning = $false
    try { $rootStillRunning = -not $Process.HasExited } catch {}
    $blockingErrors = @()
    foreach ($cleanupError in @($groupKillError, $absenceError)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$cleanupError)) {
            $blockingErrors += $cleanupError
        }
    }
    if ($rootStillRunning) {
        $rootDetail = if ($rootKillError) { $rootKillError } else { "root remained alive after final group KILL" }
        $blockingErrors += "root cleanup failed: $rootDetail"
    }
    if ($blockingErrors.Count -gt 0) {
        $context = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$termError)) {
            $context += $termError
        }
        throw "$Description Unix process-tree cleanup failed: $(@($context + $blockingErrors) -join '; ')"
    }
    $Containment.Terminated = $true
    return "Unix process group $($Containment.ProcessGroupId)"
}

function Throw-NativeDrainTimeout {
    param(
        [System.Diagnostics.Process]$Process,
        [object]$Containment,
        [string]$Description,
        [ValidateSet("stdout", "stderr")][string]$StreamName,
        [object]$StdOutTask,
        [object]$StdErrTask
    )

    $treeResult = "not attempted"
    $treeError = $null
    try {
        $treeResult = Stop-NativeProcessTree -Process $Process -Containment $Containment -Description $Description
    }
    catch {
        $treeError = $_.Exception.Message
        try { if (-not $Process.HasExited) { $Process.Kill() } } catch {}
    }
    [void]$StdOutTask.Wait(250)
    [void]$StdErrTask.Wait(250)
    $details = @()
    $stdout = Get-BoundedNativeDiagnostic -Text (Get-CompletedTaskText -Task $StdOutTask)
    $stderr = Get-BoundedNativeDiagnostic -Text (Get-CompletedTaskText -Task $StdErrTask)
    if ($stdout) { $details += "stdout: $stdout" }
    if ($stderr) { $details += "stderr: $stderr" }
    if ($treeError) { $details += "tree cleanup: $treeError" } else { $details += "tree cleanup: $treeResult" }
    throw [System.TimeoutException]::new(
        "$Description exited but $StreamName did not drain before its absolute deadline (PID $($Process.Id)). $($details -join '; ')")
}

function Invoke-NativeCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [datetime]$Deadline,
        [string]$Description = $null,
        [string]$WorkingDirectory = (Get-Location).Path,
        [scriptblock]$AssignWindowsJob = $null
    )

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        throw "Native process path is required."
    }
    $displayName = if ([string]::IsNullOrWhiteSpace($Description)) { "native process '$FilePath'" } else { $Description }
    if ((Get-DeadlineRemainingMilliseconds -Deadline $Deadline) -lt 1) {
        throw [System.TimeoutException]::new("Deadline expired before starting $displayName.")
    }

    $effectiveFilePath = $FilePath
    $effectiveArguments = @($Arguments)
    if ([System.IO.Path]::GetExtension($FilePath) -in @(".bat", ".cmd")) {
        if ([string]::IsNullOrWhiteSpace($env:ComSpec)) {
            throw "Cannot run $displayName because ComSpec is not set."
        }
        $effectiveFilePath = $env:ComSpec
        $effectiveArguments = @("/d", "/c", "call", $FilePath) + @($Arguments)
    }

    $containment = $null
    $process = $null
    try {
        $containment = New-NativeProcessContainment -Description $displayName
        if ($containment.Kind -eq "UnixProcessGroup") {
            $effectiveArguments = @("--", $effectiveFilePath) + @($effectiveArguments)
            $effectiveFilePath = $containment.SetSidPath
        }
        else {
            $targetFilePath = $effectiveFilePath
            $targetArguments = @($effectiveArguments)
            $hostExecutable = (Get-Process -Id $PID).MainModule.FileName
            if ([string]::IsNullOrWhiteSpace($hostExecutable) -or
                -not (Test-Path -LiteralPath $hostExecutable -PathType Leaf)) {
                Close-NativeProcessContainment -Containment $containment
                throw "$displayName cannot start because the Windows PowerShell gate host is unavailable."
            }
            $effectiveFilePath = $hostExecutable
            $effectiveArguments = @(
                "-NoLogo", "-NoProfile", "-NonInteractive",
                "-EncodedCommand", (Get-WindowsNativeGateEncodedCommand)
            )
        }

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $effectiveFilePath
        $startInfo.WorkingDirectory = $WorkingDirectory
        $startInfo.Arguments = (@($effectiveArguments) | ForEach-Object { Format-NativeArgument $_ }) -join " "
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        if ($containment.Kind -eq "WindowsJob") {
            Set-WindowsNativeGatePayload `
                -StartInfo $startInfo `
                -Containment $containment `
                -FilePath $targetFilePath `
                -Arguments $targetArguments `
                -WorkingDirectory $WorkingDirectory
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $stdoutTask = $null
        $stderrTask = $null
        if ((Get-DeadlineRemainingMilliseconds -Deadline $Deadline) -lt 1) {
            throw [System.TimeoutException]::new("Deadline expired before starting $displayName after containment preparation.")
        }
        [void]$process.Start()
        Set-NativeProcessContainment `
            -Containment $containment `
            -Process $process `
            -Description $displayName `
            -Deadline $Deadline `
            -AssignWindowsJob $AssignWindowsJob
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $remainingMilliseconds = Get-DeadlineRemainingMilliseconds -Deadline $Deadline
        $completed = $remainingMilliseconds -gt 0 -and $process.WaitForExit($remainingMilliseconds)
        if ($completed -and $process.ExitTime -gt $Deadline) {
            $completed = $false
        }
        if (-not $completed) {
            $treeTermination = "not attempted"
            $treeError = $null
            try {
                $treeTermination = Stop-NativeProcessTree -Process $process -Containment $containment -Description $displayName
            }
            catch {
                $treeError = $_.Exception.Message
                try { if (-not $process.HasExited) { $process.Kill() } } catch {}
                [void]$process.WaitForExit(1000)
            }
            [void]$stdoutTask.Wait(1000)
            [void]$stderrTask.Wait(1000)
            $stdout = Get-BoundedNativeDiagnostic -Text (Get-CompletedTaskText -Task $stdoutTask)
            $stderr = Get-BoundedNativeDiagnostic -Text (Get-CompletedTaskText -Task $stderrTask)
            $details = @()
            if ($stdout) { $details += "stdout: $stdout" }
            if ($stderr) { $details += "stderr: $stderr" }
            if ($treeError) { $details += "tree cleanup: $treeError" } else { $details += "tree cleanup: $treeTermination" }
            $suffix = if ($details.Count -gt 0) { " " + ($details -join "; ") } else { "" }
            throw [System.TimeoutException]::new("$displayName exceeded its absolute deadline (PID $($process.Id)).$suffix")
        }

        $remainingMilliseconds = Get-DeadlineRemainingMilliseconds -Deadline $Deadline
        if ($remainingMilliseconds -lt 1 -or -not $stdoutTask.Wait($remainingMilliseconds)) {
            Throw-NativeDrainTimeout `
                -Process $process `
                -Containment $containment `
                -Description $displayName `
                -StreamName "stdout" `
                -StdOutTask $stdoutTask `
                -StdErrTask $stderrTask
        }
        $remainingMilliseconds = Get-DeadlineRemainingMilliseconds -Deadline $Deadline
        if ($remainingMilliseconds -lt 1 -or -not $stderrTask.Wait($remainingMilliseconds)) {
            Throw-NativeDrainTimeout `
                -Process $process `
                -Containment $containment `
                -Description $displayName `
                -StreamName "stderr" `
                -StdOutTask $stdoutTask `
                -StdErrTask $stderrTask
        }

        $stdout = Split-NativeOutput $stdoutTask.Result
        $stderr = Split-NativeOutput $stderrTask.Result
        return @{
            ExitCode = $process.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
            Output   = @($stdout) + @($stderr)
        }
    }
    finally {
        try {
            Close-NativeProcessContainment -Containment $containment
        }
        finally {
            if ($process) {
                $process.Dispose()
            }
        }
    }
}

function Invoke-NativeCaptureSelfTest {
    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-native-capture-test-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $treePids = [System.Collections.Generic.List[int]]::new()
    try {
        $unixSignalHelperText = ${function:Invoke-UnixProcessGroupSignal}.ToString()
        if ($unixSignalHelperText -match '(?im)^\s*\$signal\s*=') {
            throw "Unix signal helper must not shadow its case-insensitive Signal parameter with a local variable."
        }

        $powerShellPath = (Get-Process -Id $PID).MainModule.FileName
        if ([string]::IsNullOrWhiteSpace($powerShellPath) -or -not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
            throw "Native capture self-test could not resolve the current PowerShell executable."
        }

        $floodScript = Join-Path $fixtureRoot "flood.ps1"
        [System.IO.File]::WriteAllText($floodScript, @'
param([string]$Value)
for ($index = 0; $index -lt 6000; $index++) {
    [Console]::Out.WriteLine("stdout-{0:D4}-xxxxxxxxxxxxxxxx" -f $index)
    [Console]::Error.WriteLine("stderr-{0:D4}-yyyyyyyyyyyyyyyy" -f $index)
}
[Console]::Out.WriteLine("cwd:" + [Environment]::CurrentDirectory)
[Console]::Out.WriteLine("argument:$Value")
exit 7
'@, [System.Text.UTF8Encoding]::new($false))
        $argumentValue = 'space "quote" trailing\'
        $floodResult = Invoke-NativeCapture `
            -FilePath $powerShellPath `
            -Arguments @("-NoLogo", "-NoProfile", "-File", $floodScript, "-Value", $argumentValue) `
            -Deadline (Get-Date).AddSeconds(30) `
            -Description "native dual-stream capture self-test" `
            -WorkingDirectory $fixtureRoot
        if ($floodResult.ExitCode -ne 7 -or
            $floodResult.StdOut.Count -ne 6002 -or
            $floodResult.StdErr.Count -ne 6000 -or
            $floodResult.StdOut[-1] -ne "argument:$argumentValue" -or
            -not [System.StringComparer]::OrdinalIgnoreCase.Equals($floodResult.StdOut[-2], "cwd:$fixtureRoot") -or
            $floodResult.StdOut[0] -notmatch '^stdout-' -or
            $floodResult.StdErr[0] -notmatch '^stderr-') {
            throw "Native capture must drain both full streams, preserve arguments, and return the exact exit code. Exit=$($floodResult.ExitCode), stdout=$($floodResult.StdOut.Count), stderr=$($floodResult.StdErr.Count), firstErr='$($floodResult.StdErr[0])', lastErr='$($floodResult.StdErr[-1])', last='$($floodResult.StdOut[-1])'."
        }

        $expiredSentinel = Join-Path $fixtureRoot "expired-started.txt"
        $sentinelScript = Join-Path $fixtureRoot "sentinel.ps1"
        [System.IO.File]::WriteAllText($sentinelScript, @'
param([string]$SentinelPath)
[System.IO.File]::WriteAllText($SentinelPath, "started")
'@, [System.Text.UTF8Encoding]::new($false))
        Assert-ThrowsMatch "expired native deadline prevents process start" {
            [void](Invoke-NativeCapture `
                -FilePath $powerShellPath `
                -Arguments @("-NoLogo", "-NoProfile", "-File", $sentinelScript, "-SentinelPath", $expiredSentinel) `
                -Deadline (Get-Date).AddMilliseconds(-1) `
                -Description "expired native process self-test")
        } "Deadline expired before starting expired native process self-test"
        if (Test-Path -LiteralPath $expiredSentinel) {
            throw "An already-expired native deadline must not start the child process."
        }

        if ($env:OS -eq "Windows_NT") {
            $assignmentFailureSentinel = Join-Path $fixtureRoot "assignment-failure-started.txt"
            Assert-ThrowsMatch "Windows assignment failure prevents target start" {
                [void](Invoke-NativeCapture `
                    -FilePath $powerShellPath `
                    -Arguments @("-NoLogo", "-NoProfile", "-File", $sentinelScript, "-SentinelPath", $assignmentFailureSentinel) `
                    -Deadline (Get-Date).AddSeconds(10) `
                    -Description "assignment failure native process self-test" `
                    -AssignWindowsJob {
                        param([object]$Containment, [System.Diagnostics.Process]$Process)
                        $null = @($Containment, $Process)
                        throw "injected assignment failure"
                    })
            } "could not be assigned to its Windows Job Object.*injected assignment failure"
            Start-Sleep -Milliseconds 500
            if (Test-Path -LiteralPath $assignmentFailureSentinel) {
                throw "Windows Job Object assignment failure allowed the gated target to start."
            }

            $assignmentDeadlineSentinel = Join-Path $fixtureRoot "assignment-deadline-started.txt"
            Assert-ThrowsMatch "Windows assignment cannot signal target after deadline" {
                [void](Invoke-NativeCapture `
                    -FilePath $powerShellPath `
                    -Arguments @("-NoLogo", "-NoProfile", "-File", $sentinelScript, "-SentinelPath", $assignmentDeadlineSentinel) `
                    -Deadline (Get-Date).AddSeconds(2) `
                    -Description "assignment deadline native process self-test" `
                    -AssignWindowsJob {
                        param([object]$Containment, [System.Diagnostics.Process]$Process)
                        [StatsPro.ReleaseProcessJob]::Assign($Containment.JobHandle, $Process.Handle)
                        Start-Sleep -Milliseconds 2500
                    })
            } "launch gate failed before target start.*Deadline expired before signalling"
            Start-Sleep -Milliseconds 500
            if (Test-Path -LiteralPath $assignmentDeadlineSentinel) {
                throw "An expired Windows assignment path signalled the gated target."
            }
        }

        $rootRaceInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $rootRaceInfo.FileName = $powerShellPath
        $rootRaceInfo.Arguments = (@(
            "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 300"
        ) | ForEach-Object { Format-NativeArgument $_ }) -join " "
        $rootRaceInfo.UseShellExecute = $false
        $rootRaceInfo.CreateNoWindow = $true
        $rootRaceProcess = [System.Diagnostics.Process]::new()
        $rootRaceProcess.StartInfo = $rootRaceInfo
        $unixRaceSignals = [System.Collections.Generic.List[string]]::new()
        $unixRaceState = [pscustomobject]@{ AbsenceChecks = 0 }
        try {
            [void]$rootRaceProcess.Start()
            $treePids.Add($rootRaceProcess.Id)
            $fakeUnixContainment = [pscustomobject]@{
                Kind           = "UnixProcessGroup"
                ProcessGroupId = 4242
                Terminated     = $false
            }
            $raceCleanup = Stop-NativeProcessTree `
                -Process $rootRaceProcess `
                -Containment $fakeUnixContainment `
                -Description "Unix root-exit race self-test" `
                -CleanupMilliseconds 5000 `
                -RunUnixProcessGroupSignal {
                    param([object]$Containment, [string]$Signal, [datetime]$Deadline)
                    $null = @($Containment, $Deadline)
                    $unixRaceSignals.Add($Signal) | Out-Null
                    return [pscustomobject]@{ ExitCode = 0; StdOut = ""; StdErr = "" }
                } `
                -KillUnixRoot {
                    param([System.Diagnostics.Process]$RootProcess)
                    $RootProcess.Kill()
                    [void]$RootProcess.WaitForExit(5000)
                    throw "injected root exited before Kill completed"
                } `
                -VerifyUnixProcessGroupAbsent {
                    param([object]$Containment, [datetime]$Deadline, [string]$Description)
                    $null = @($Containment, $Deadline, $Description)
                    $unixRaceState.AbsenceChecks++
                }
            if ($raceCleanup -ne "Unix process group 4242" -or
                ($unixRaceSignals -join ",") -ne "TERM,KILL" -or
                $unixRaceState.AbsenceChecks -ne 1 -or
                -not $fakeUnixContainment.Terminated -or
                -not $rootRaceProcess.HasExited) {
                throw "Unix root-exit race did not preserve final group KILL and absence verification."
            }
        }
        finally {
            try { if (-not $rootRaceProcess.HasExited) { $rootRaceProcess.Kill() } } catch {}
            $rootRaceProcess.Dispose()
        }

        $grandchildScript = Join-Path $fixtureRoot "grandchild.ps1"
        $parentScript = Join-Path $fixtureRoot "parent.ps1"
        $parentPidPath = Join-Path $fixtureRoot "parent.pid"
        $grandchildPidPath = Join-Path $fixtureRoot "grandchild.pid"
        $treeReadyPath = Join-Path $fixtureRoot "tree-ready.txt"
        $lateSentinel = Join-Path $fixtureRoot "grandchild-survived.txt"
        [System.IO.File]::WriteAllText($grandchildScript, @'
param([string]$PidPath, [string]$SentinelPath, [int]$SentinelDelaySeconds)
[System.IO.File]::WriteAllText($PidPath, [string]$PID)
[Console]::Out.WriteLine("grandchild-stdout-marker")
[Console]::Error.WriteLine("grandchild-stderr-marker")
Start-Sleep -Seconds $SentinelDelaySeconds
[System.IO.File]::WriteAllText($SentinelPath, "survived")
while ($true) { Start-Sleep -Seconds 1 }
'@, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($parentScript, @'
param(
    [string]$PowerShellPath,
    [string]$GrandchildPath,
    [string]$ParentPidPath,
    [string]$GrandchildPidPath,
    [string]$TreeReadyPath,
    [string]$SentinelPath,
    [string]$Secret
)
[System.IO.File]::WriteAllText($ParentPidPath, [string]$PID)
$arguments = @(
    "-NoLogo", "-NoProfile", "-File", $GrandchildPath,
    "-PidPath", $GrandchildPidPath,
    "-SentinelPath", $SentinelPath,
    "-SentinelDelaySeconds", "30"
)
[void](Start-Process -FilePath $PowerShellPath -ArgumentList $arguments -PassThru)
$readinessDeadline = [DateTime]::UtcNow.AddSeconds(10)
while (-not (Test-Path -LiteralPath $GrandchildPidPath -PathType Leaf) -and
    [DateTime]::UtcNow -lt $readinessDeadline) {
    Start-Sleep -Milliseconds 100
}
if (-not (Test-Path -LiteralPath $GrandchildPidPath -PathType Leaf)) {
    throw "Grandchild did not become ready within the bounded fixture window."
}
[System.IO.File]::WriteAllText($TreeReadyPath, "ready")
[Console]::Out.WriteLine("parent-stdout-marker")
[Console]::Error.WriteLine("parent-stderr-marker")
while ($true) { Start-Sleep -Seconds 1 }
'@, [System.Text.UTF8Encoding]::new($false))

        $secret = "must-not-appear-$([System.Guid]::NewGuid().ToString('N'))"
        $treeTimeoutSeconds = if ($env:OS -eq "Windows_NT") { 15 } else { 8 }
        $timeoutMessage = ""
        try {
            [void](Invoke-NativeCapture `
                -FilePath $powerShellPath `
                -Arguments @(
                    "-NoLogo", "-NoProfile", "-File", $parentScript,
                    "-PowerShellPath", $powerShellPath,
                    "-GrandchildPath", $grandchildScript,
                    "-ParentPidPath", $parentPidPath,
                    "-GrandchildPidPath", $grandchildPidPath,
                    "-TreeReadyPath", $treeReadyPath,
                    "-SentinelPath", $lateSentinel,
                    "-Secret", $secret
                ) `
                -Deadline (Get-Date).AddSeconds($treeTimeoutSeconds) `
                -Description "hung process-tree self-test")
            throw "Hung native process tree should have timed out."
        }
        catch {
            $timeoutMessage = $_.Exception.Message
        }
        if ($timeoutMessage -notmatch 'exceeded its absolute deadline' -or
            $timeoutMessage -notmatch 'parent-stdout-marker' -or
            $timeoutMessage -notmatch 'parent-stderr-marker' -or
            $timeoutMessage.Contains($secret)) {
            throw "Native timeout diagnostics must preserve stdout/stderr without exposing raw arguments. Got: $timeoutMessage"
        }

        if (-not (Test-Path -LiteralPath $treeReadyPath -PathType Leaf)) {
            throw "Hung process-tree self-test timed out before its bounded readiness gate completed."
        }
        foreach ($pidPath in @($parentPidPath, $grandchildPidPath)) {
            if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
                throw "Hung process-tree self-test did not record '$pidPath'."
            }
            $childPid = 0
            if (-not [int]::TryParse(([System.IO.File]::ReadAllText($pidPath)).Trim(), [ref]$childPid)) {
                throw "Hung process-tree self-test recorded an invalid PID."
            }
            $treePids.Add($childPid)
            if (Get-Process -Id $childPid -ErrorAction SilentlyContinue) {
                throw "Native timeout left process $childPid running."
            }
        }
        Start-Sleep -Seconds 3
        if (Test-Path -LiteralPath $lateSentinel) {
            throw "Native timeout left a grandchild alive long enough to write its delayed sentinel."
        }

        if ($env:OS -ne "Windows_NT") {
            $shell = Get-Command sh -CommandType Application -ErrorAction Stop | Select-Object -First 1
            $unixTreeScript = Join-Path $fixtureRoot "unix-process-group.sh"
            $unixRootPidPath = Join-Path $fixtureRoot "unix-root.pid"
            $unixChildPidPath = Join-Path $fixtureRoot "unix-child.pid"
            $unixProcessGroupPath = Join-Path $fixtureRoot "unix-pgid.txt"
            [System.IO.File]::WriteAllText($unixTreeScript, @'
root_pid=$$
root_pid_path=$1
process_group_path=$2
child_pid_path=$3
set -- $(ps -o pgid= -p $$)
process_group=$1
printf '%s' "$root_pid" > "$root_pid_path"
printf '%s' "$process_group" > "$process_group_path"
sleep 300 &
child_pid=$!
printf '%s' "$child_pid" > "$child_pid_path"
printf '%s\n' 'unix-pgid-ready'
wait
'@, [System.Text.UTF8Encoding]::new($false))
            $unixTimeoutMessage = ""
            try {
                [void](Invoke-NativeCapture `
                    -FilePath $shell.Source `
                    -Arguments @(
                        $unixTreeScript,
                        $unixRootPidPath,
                        $unixProcessGroupPath,
                        $unixChildPidPath
                    ) `
                    -Deadline (Get-Date).AddSeconds(3) `
                    -Description "Unix process-group self-test")
                throw "Unix process-group fixture should have timed out."
            }
            catch {
                $unixTimeoutMessage = $_.Exception.Message
            }
            if ($unixTimeoutMessage -notmatch 'exceeded its absolute deadline' -or
                $unixTimeoutMessage -notmatch 'unix-pgid-ready' -or
                $unixTimeoutMessage -notmatch 'tree cleanup: Unix process group') {
                throw "Unix PGID timeout did not preserve output and verified cleanup: $unixTimeoutMessage"
            }
            foreach ($path in @($unixRootPidPath, $unixChildPidPath, $unixProcessGroupPath)) {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    throw "Unix PGID fixture did not write '$path'."
                }
            }
            $unixRootPid = [int]([System.IO.File]::ReadAllText($unixRootPidPath).Trim())
            $unixChildPid = [int]([System.IO.File]::ReadAllText($unixChildPidPath).Trim())
            $unixProcessGroup = [int]([System.IO.File]::ReadAllText($unixProcessGroupPath).Trim())
            $treePids.Add($unixRootPid)
            $treePids.Add($unixChildPid)
            if ($unixProcessGroup -ne $unixRootPid) {
                throw "setsid did not establish the target PID $unixRootPid as PGID; got $unixProcessGroup."
            }
            foreach ($unixPid in @($unixRootPid, $unixChildPid)) {
                if (Get-Process -Id $unixPid -ErrorAction SilentlyContinue) {
                    throw "Unix process-group cleanup left process $unixPid running."
                }
            }
        }

        $orphanParentScript = Join-Path $fixtureRoot "orphan-parent.ps1"
        $orphanPidPath = Join-Path $fixtureRoot "orphan.pid"
        $orphanSentinel = Join-Path $fixtureRoot "orphan-survived.txt"
        [System.IO.File]::WriteAllText($orphanParentScript, @'
param(
    [string]$PowerShellPath,
    [string]$GrandchildPath,
    [string]$GrandchildPidPath,
    [string]$SentinelPath
)
$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $PowerShellPath
$startInfo.Arguments = "-NoLogo -NoProfile -File `"$GrandchildPath`" -PidPath `"$GrandchildPidPath`" -SentinelPath `"$SentinelPath`" -SentinelDelaySeconds 30"
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$child = [System.Diagnostics.Process]::new()
$child.StartInfo = $startInfo
[void]$child.Start()
$child.Dispose()
[Console]::Out.WriteLine("orphan-parent-exited")
'@, [System.Text.UTF8Encoding]::new($false))
        $orphanMessage = ""
        $orphanTimeoutSeconds = if ($env:OS -eq "Windows_NT") { 10 } else { 5 }
        try {
            [void](Invoke-NativeCapture `
                -FilePath $powerShellPath `
                -Arguments @(
                    "-NoLogo", "-NoProfile", "-File", $orphanParentScript,
                    "-PowerShellPath", $powerShellPath,
                    "-GrandchildPath", $grandchildScript,
                    "-GrandchildPidPath", $orphanPidPath,
                    "-SentinelPath", $orphanSentinel
                ) `
                -Deadline (Get-Date).AddSeconds($orphanTimeoutSeconds) `
                -Description "inherited output handle self-test")
            throw "A descendant-held output handle should not produce silent success."
        }
        catch {
            $orphanMessage = $_.Exception.Message
        }
        if ($orphanMessage -notmatch 'did not drain before its absolute deadline' -or
            $orphanMessage -notmatch 'tree cleanup: (Windows Job Object|Unix process group)') {
            throw "Inherited output handle failure must be bounded and report successful containment cleanup. Got: $orphanMessage"
        }
        if (-not (Test-Path -LiteralPath $orphanPidPath -PathType Leaf)) {
            throw "Inherited output handle self-test did not record its descendant PID."
        }
        $orphanPid = 0
        if (-not [int]::TryParse(([System.IO.File]::ReadAllText($orphanPidPath)).Trim(), [ref]$orphanPid)) {
            throw "Inherited output handle self-test recorded an invalid PID."
        }
        $treePids.Add($orphanPid)
        $orphanStopped = $false
        for ($attempt = 0; $attempt -lt 50; $attempt++) {
            $orphanProcess = Get-Process -Id $orphanPid -ErrorAction SilentlyContinue
            if (-not $orphanProcess) {
                $orphanStopped = $true
                break
            }
            $orphanProcess.Dispose()
            Start-Sleep -Milliseconds 100
        }
        if (-not $orphanStopped) {
            throw "Inherited output handle timeout left descendant process $orphanPid running."
        }
        Start-Sleep -Seconds 3
        if (Test-Path -LiteralPath $orphanSentinel) {
            throw "Inherited output handle timeout left its descendant alive long enough to write its delayed sentinel."
        }
    }
    finally {
        foreach ($treePid in $treePids) {
            $leftover = Get-Process -Id $treePid -ErrorAction SilentlyContinue
            if ($leftover) {
                try { $leftover.Kill() } catch {}
                $leftover.Dispose()
            }
        }
        if (Test-Path -LiteralPath $fixtureRoot) {
            Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
        }
    }
}

function Assert-CommitSha {
    param([string]$Value)

    if ($Value -cnotmatch "^[0-9a-f]{40}$") {
        throw "Malformed expected commit SHA '$Value'. Expected 40 lowercase hex characters."
    }
}

function Assert-RepositoryName {
    param([string]$Value)

    if ($Value -notmatch "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") {
        throw "Malformed GitHub repository '$Value'. Expected owner/name."
    }
}

function Assert-RunId {
    param([string]$Value)

    if ($Value -notmatch "^[1-9][0-9]*$") {
        throw "Malformed GitHub Actions run ID '$Value'. Expected a positive decimal integer."
    }
}

function Assert-RunAttempt {
    param([string]$Value)

    if ($Value -notmatch "^[1-9][0-9]*$") {
        throw "Malformed GitHub Actions run attempt '$Value'. Expected a positive decimal integer."
    }
}

function Assert-LowercaseSha256 {
    param([string]$Value, [string]$Description)

    if ($Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Description must be 64 lowercase hex characters."
    }
}

function Get-CanonicalFileText {
    param(
        [string]$Path,
        [string]$Description
    )

    $resolved = Resolve-ReleaseManagerRequiredFile -Path $Path -Description $Description
    $text = [System.IO.File]::ReadAllText($resolved)
    $normalized = ($text -replace "`r`n", "`n") -replace "`r", "`n"
    return $normalized.TrimEnd([char[]]"`n")
}

function Get-LowercaseTextSha256 {
    param([string]$Text)

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($hash.ComputeHash($bytes)) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $hash.Dispose()
    }
}

function ConvertTo-Base64Url {
    param([string]$Text)

    return [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-Base64Url {
    param([string]$Value)

    if ($Value -notmatch '^[A-Za-z0-9_-]+$') {
        throw "Release state marker payload is not canonical base64url."
    }
    $padded = $Value.Replace('-', '+').Replace('_', '/')
    switch ($padded.Length % 4) {
        0 { }
        2 { $padded += '==' }
        3 { $padded += '=' }
        default { throw "Release state marker payload has invalid base64url length." }
    }
    try {
        return [System.Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String($padded))
    }
    catch {
        throw "Release state marker payload is not valid UTF-8 base64url: $($_.Exception.Message)"
    }
}

function Get-ReleaseTransactionId {
    param(
        [ValidateSet(1, 2)]
        [int]$SchemaVersion,
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [string]$ExpectedRunId,
        [AllowEmptyString()][string]$ExpectedRunAttempt,
        [string]$NotesSha256,
        [string]$ManifestSha256,
        [AllowEmptyString()][string]$ArchiveSha256,
        [AllowEmptyString()][string]$CandidateSha256
    )

    if ($SchemaVersion -eq 1) {
        return Get-LowercaseTextSha256 -Text ("statspro-release-transaction-v1`n$Repository`n$ExpectedTag`n$ExpectedCommitSha`n$NotesSha256`n$ManifestSha256")
    }
    return Get-LowercaseTextSha256 -Text ("statspro-release-transaction-v2`n$Repository`n$ExpectedTag`n$ExpectedCommitSha`n$ExpectedRunId`n$ExpectedRunAttempt`n$NotesSha256`n$ManifestSha256`n$ArchiveSha256`n$CandidateSha256")
}

function Get-ReleaseStateData {
    param(
        [ValidateSet(1, 2)]
        [int]$SchemaVersion = 1,
        [ValidateSet('prepared', 'marketplace-started')]
        [string]$Phase,
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [string]$ExpectedRunId,
        [AllowEmptyString()][string]$ExpectedRunAttempt,
        [string]$NotesSha256,
        [string]$ManifestSha256,
        [AllowEmptyString()][string]$ArchiveSha256,
        [AllowEmptyString()][string]$CandidateSha256
    )

    Assert-RepositoryName $Repository
    Assert-StatsProReleaseTag -Value $ExpectedTag
    Assert-CommitSha $ExpectedCommitSha
    Assert-RunId $ExpectedRunId
    Assert-LowercaseSha256 -Value $NotesSha256 -Description 'Release notes digest'
    Assert-LowercaseSha256 -Value $ManifestSha256 -Description 'Release manifest digest'
    if ($SchemaVersion -eq 1) {
        return [pscustomobject][ordered]@{
            schemaVersion  = 1
            kind           = 'statspro-release-transaction'
            phase          = $Phase
            repository     = $Repository
            tag            = $ExpectedTag
            commitSha      = $ExpectedCommitSha
            runId          = $ExpectedRunId
            notesSha256    = $NotesSha256
            manifestSha256 = $ManifestSha256
            transactionId  = Get-ReleaseTransactionId `
                -SchemaVersion 1 `
                -Repository $Repository `
                -ExpectedTag $ExpectedTag `
                -ExpectedCommitSha $ExpectedCommitSha `
                -ExpectedRunId $ExpectedRunId `
                -ExpectedRunAttempt '' `
                -NotesSha256 $NotesSha256 `
                -ManifestSha256 $ManifestSha256 `
                -ArchiveSha256 '' `
                -CandidateSha256 ''
        }
    }
    Assert-RunAttempt $ExpectedRunAttempt
    Assert-LowercaseSha256 -Value $ArchiveSha256 -Description 'Release archive digest'
    Assert-LowercaseSha256 -Value $CandidateSha256 -Description 'Release candidate digest'
    return [pscustomobject][ordered]@{
        schemaVersion  = 2
        kind           = 'statspro-release-transaction'
        phase          = $Phase
        repository     = $Repository
        tag            = $ExpectedTag
        commitSha      = $ExpectedCommitSha
        runId          = $ExpectedRunId
        runAttempt     = $ExpectedRunAttempt
        notesSha256    = $NotesSha256
        manifestSha256 = $ManifestSha256
        archiveSha256  = $ArchiveSha256
        candidateSha256 = $CandidateSha256
        transactionId  = Get-ReleaseTransactionId `
            -SchemaVersion 2 `
            -Repository $Repository `
            -ExpectedTag $ExpectedTag `
            -ExpectedCommitSha $ExpectedCommitSha `
            -ExpectedRunId $ExpectedRunId `
            -ExpectedRunAttempt $ExpectedRunAttempt `
            -NotesSha256 $NotesSha256 `
            -ManifestSha256 $ManifestSha256 `
            -ArchiveSha256 $ArchiveSha256 `
            -CandidateSha256 $CandidateSha256
    }
}

function Get-ReleaseStateMarkerLine {
    param([object]$State)

    $json = $State | ConvertTo-Json -Compress
    return "<!-- statspro-release-state:$(ConvertTo-Base64Url -Text $json) -->"
}

function Get-ReleaseBody {
    param(
        [object]$State,
        [string]$CanonicalNotes
    )

    return "$(Get-ReleaseStateMarkerLine -State $State)`n`n$CanonicalNotes"
}

function Read-ReleaseStateMarker {
    param([string]$Body)

    $normalizedBody = (($Body -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd([char[]]"`n")
    $markerPrefix = '<!-- statspro-release-state:'
    if ([regex]::Matches($normalizedBody, [regex]::Escape($markerPrefix)).Count -ne 1) {
        throw "Release body must contain exactly one StatsPro release state marker."
    }
    $match = [regex]::Match($normalizedBody, '\A<!-- statspro-release-state:([A-Za-z0-9_-]+) -->\n\n')
    if (-not $match.Success) {
        throw "Release state marker must be the canonical first line followed by one blank line."
    }
    $encoded = $match.Groups[1].Value
    $json = ConvertFrom-Base64Url -Value $encoded
    try {
        $state = ConvertFrom-JsonCompat $json
    }
    catch {
        throw "Release state marker is not valid JSON: $($_.Exception.Message)"
    }
    $schemaVersion = [int]$state.schemaVersion
    $expectedKeys = if ($schemaVersion -eq 1) {
        @('schemaVersion', 'kind', 'phase', 'repository', 'tag', 'commitSha', 'runId', 'notesSha256', 'manifestSha256', 'transactionId') | Sort-Object
    }
    elseif ($schemaVersion -eq 2) {
        @('schemaVersion', 'kind', 'phase', 'repository', 'tag', 'commitSha', 'runId', 'runAttempt', 'notesSha256', 'manifestSha256', 'archiveSha256', 'candidateSha256', 'transactionId') | Sort-Object
    }
    else {
        throw "Release state marker has an unsupported schema or kind."
    }
    $actualKeys = @($state.PSObject.Properties.Name | Sort-Object)
    if ($actualKeys.Count -ne $expectedKeys.Count -or (Compare-Object -ReferenceObject $expectedKeys -DifferenceObject $actualKeys)) {
        throw "Release state marker fields are not the exact schema."
    }
    if (-not [System.StringComparer]::Ordinal.Equals([string]$state.kind, 'statspro-release-transaction')) {
        throw "Release state marker has an unsupported schema or kind."
    }
    if (-not (Test-ContainsOrdinal -Values @('prepared', 'marketplace-started') -Expected ([string]$state.phase))) {
        throw "Release state marker has unsupported phase '$($state.phase)'."
    }
    Assert-RepositoryName ([string]$state.repository)
    Assert-StatsProReleaseTag -Value ([string]$state.tag)
    Assert-CommitSha ([string]$state.commitSha)
    Assert-RunId ([string]$state.runId)
    if ($schemaVersion -eq 2) {
        Assert-RunAttempt ([string]$state.runAttempt)
    }
    $digestNames = @('notesSha256', 'manifestSha256', 'transactionId')
    if ($schemaVersion -eq 2) {
        $digestNames += @('archiveSha256', 'candidateSha256')
    }
    foreach ($name in $digestNames) {
        if ([string]$state.$name -cnotmatch '^[0-9a-f]{64}$') {
            throw "Release state marker field '$name' is not a lowercase SHA-256 digest."
        }
    }
    $expectedTransaction = Get-ReleaseTransactionId `
        -SchemaVersion $schemaVersion `
        -Repository ([string]$state.repository) `
        -ExpectedTag ([string]$state.tag) `
        -ExpectedCommitSha ([string]$state.commitSha) `
        -ExpectedRunId ([string]$state.runId) `
        -ExpectedRunAttempt $(if ($schemaVersion -eq 2) { [string]$state.runAttempt } else { '' }) `
        -NotesSha256 ([string]$state.notesSha256) `
        -ManifestSha256 ([string]$state.manifestSha256) `
        -ArchiveSha256 $(if ($schemaVersion -eq 2) { [string]$state.archiveSha256 } else { '' }) `
        -CandidateSha256 $(if ($schemaVersion -eq 2) { [string]$state.candidateSha256 } else { '' })
    if (-not [System.StringComparer]::Ordinal.Equals([string]$state.transactionId, $expectedTransaction)) {
        throw "Release state marker transaction ID does not match its identity fields."
    }
    $canonicalMarker = Get-ReleaseStateMarkerLine -State (Get-ReleaseStateData `
        -SchemaVersion $schemaVersion `
        -Phase ([string]$state.phase) `
        -Repository ([string]$state.repository) `
        -ExpectedTag ([string]$state.tag) `
        -ExpectedCommitSha ([string]$state.commitSha) `
        -ExpectedRunId ([string]$state.runId) `
        -ExpectedRunAttempt $(if ($schemaVersion -eq 2) { [string]$state.runAttempt } else { '' }) `
        -NotesSha256 ([string]$state.notesSha256) `
        -ManifestSha256 ([string]$state.manifestSha256) `
        -ArchiveSha256 $(if ($schemaVersion -eq 2) { [string]$state.archiveSha256 } else { '' }) `
        -CandidateSha256 $(if ($schemaVersion -eq 2) { [string]$state.candidateSha256 } else { '' }))
    if (-not [System.StringComparer]::Ordinal.Equals($match.Value.Substring(0, $match.Value.Length - 2), $canonicalMarker)) {
        throw "Release state marker encoding is not canonical."
    }
    $notes = $normalizedBody.Substring($match.Length)
    if (-not [System.StringComparer]::Ordinal.Equals((Get-LowercaseTextSha256 -Text $notes), [string]$state.notesSha256)) {
        throw "Release notes do not match the release state marker digest."
    }
    return [pscustomobject]@{
        State = $state
        Notes = $notes
        Body  = $normalizedBody
    }
}

function Get-NativeStandardOutput {
    param([object]$Result)

    if ($null -ne $Result -and $Result.PSObject.Properties["StdOut"]) {
        return @($Result.StdOut)
    }
    return @($Result.Output)
}

function Invoke-Gh {
    param(
        [string[]]$Arguments,
        [datetime]$Deadline,
        [string]$Description = "GitHub CLI request"
    )

    $result = Invoke-NativeCapture -FilePath "gh" -Arguments $Arguments -Deadline $Deadline -Description $Description
    if ($result.ExitCode -ne 0) {
        throw "$Description failed with code $($result.ExitCode): $($result.Output -join ' ')"
    }
    return @(Get-NativeStandardOutput -Result $result)
}

function Select-GitHubReleaseByTag {
    param(
        [object[]]$Releases,
        [string]$ExpectedTag
    )

    $matches = @($Releases | Where-Object { [System.StringComparer]::Ordinal.Equals([string]$_.tag_name, $ExpectedTag) })
    if ($matches.Count -gt 1) {
        throw "Found multiple GitHub release markers for $ExpectedTag."
    }
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[0]
}

function Get-GitHubReleaseByTag {
    param(
        [string]$Repository,
        [string]$ExpectedTag,
        [datetime]$Deadline,
        [scriptblock]$RunGh = $null
    )

    if ($null -eq $RunGh) {
        $RunGh = {
            param([string[]]$Arguments, [datetime]$RequestDeadline)
            Invoke-NativeCapture `
                -FilePath "gh" `
                -Arguments $Arguments `
                -Deadline $RequestDeadline `
                -Description "GitHub release listing"
        }
    }
    $arguments = @(
        "api",
        "--paginate",
        "--slurp",
        "-H", "Accept: application/vnd.github+json",
        "-H", "X-GitHub-Api-Version: 2026-03-10",
        "repos/$Repository/releases?per_page=100"
    )
    $result = & $RunGh $arguments $Deadline
    if ($result.ExitCode -ne 0) {
        throw "Could not list release markers for $ExpectedTag`: $($result.Output -join ' ')"
    }
    $paginated = ConvertFrom-JsonCompat ((Get-NativeStandardOutput -Result $result) -join "`n")
    $releases = @()
    foreach ($page in @($paginated)) {
        if ($page -is [System.Array]) {
            $releases += @($page)
        }
        elseif ($null -ne $page) {
            $releases += $page
        }
    }
    return Select-GitHubReleaseByTag -Releases $releases -ExpectedTag $ExpectedTag
}

function Wait-GitHubReleaseState {
    param(
        [string]$Repository,
        [string]$ExpectedTag,
        [int]$Attempts,
        [datetime]$Deadline,
        [scriptblock]$AssertState,
        [scriptblock]$GetRelease = $null,
        [scriptblock]$Wait = $null,
        [scriptblock]$Now = $null
    )

    if ($Attempts -lt 1) {
        throw "Release state attempts must be at least 1."
    }
    if ($null -eq $GetRelease) {
        $GetRelease = {
            param([string]$RepoName, [string]$TagName, [datetime]$RequestDeadline)
            Get-GitHubReleaseByTag -Repository $RepoName -ExpectedTag $TagName -Deadline $RequestDeadline
        }
    }
    if ($null -eq $Wait) {
        $Wait = {
            param([int]$Seconds)
            Start-Sleep -Seconds $Seconds
        }
    }
    if ($null -eq $Now) {
        $Now = { Get-Date }
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if ((Get-DeadlineRemainingMilliseconds -Deadline $Deadline -Now $Now) -lt 1) {
            throw "GitHub release state for $ExpectedTag exceeded its absolute deadline before attempt $attempt."
        }
        try {
            $release = & $GetRelease $Repository $ExpectedTag $Deadline
            & $AssertState $release
            if ((Get-DeadlineRemainingMilliseconds -Deadline $Deadline -Now $Now) -lt 1) {
                throw "GitHub release state for $ExpectedTag converged after its absolute deadline."
            }
            return $release
        }
        catch {
            $lastError = $_
            if ($attempt -lt $Attempts) {
                $remainingMilliseconds = Get-DeadlineRemainingMilliseconds -Deadline $Deadline -Now $Now
                if ($remainingMilliseconds -lt 1) {
                    break
                }
                $waitSeconds = [Math]::Min([Math]::Min(30, 5 * $attempt), [int][Math]::Floor($remainingMilliseconds / 1000))
                if ($waitSeconds -lt 1) {
                    break
                }
                & $Wait $waitSeconds
            }
        }
    }
    throw "GitHub release state for $ExpectedTag did not converge after $Attempts attempt(s): $($lastError.Exception.Message)"
}

function Get-GitHubRemoteTagCommitSha {
    param(
        [string]$Repository,
        [string]$ExpectedTag,
        [datetime]$Deadline
    )

    $reference = ConvertFrom-JsonCompat ((Invoke-Gh -Deadline $Deadline -Description "GitHub tag reference lookup" -Arguments @(
        "api",
        "-H", "Accept: application/vnd.github+json",
        "-H", "X-GitHub-Api-Version: 2026-03-10",
        "repos/$Repository/git/ref/tags/$ExpectedTag"
    )) -join "`n")
    $objectType = [string]$reference.object.type
    $objectSha = [string]$reference.object.sha
    for ($depth = 0; $depth -lt 5 -and $objectType -eq "tag"; $depth++) {
        $tagObject = ConvertFrom-JsonCompat ((Invoke-Gh -Deadline $Deadline -Description "GitHub annotated tag lookup" -Arguments @(
            "api",
            "-H", "Accept: application/vnd.github+json",
            "-H", "X-GitHub-Api-Version: 2026-03-10",
            "repos/$Repository/git/tags/$objectSha"
        )) -join "`n")
        $objectType = [string]$tagObject.object.type
        $objectSha = [string]$tagObject.object.sha
    }
    if ($objectType -ne "commit") {
        throw "Remote tag $ExpectedTag did not peel to a commit; final object type is '$objectType'."
    }
    Assert-CommitSha $objectSha
    return $objectSha
}

function Assert-RemoteTagCommit {
    param(
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [datetime]$Deadline,
        [scriptblock]$ResolveTagCommit = $null
    )

    Assert-CommitSha $ExpectedCommitSha
    if ($null -eq $ResolveTagCommit) {
        $ResolveTagCommit = {
            param([string]$RepoName, [string]$TagName, [datetime]$RequestDeadline)
            Get-GitHubRemoteTagCommitSha -Repository $RepoName -ExpectedTag $TagName -Deadline $RequestDeadline
        }
    }
    $actual = [string](& $ResolveTagCommit $Repository $ExpectedTag $Deadline)
    if ((Get-DeadlineRemainingMilliseconds -Deadline $Deadline) -lt 1) {
        throw "Remote tag verification for $ExpectedTag completed after its absolute deadline."
    }
    if (-not [System.StringComparer]::Ordinal.Equals($actual, $ExpectedCommitSha)) {
        throw "Remote tag $ExpectedTag points to $actual, expected event commit $ExpectedCommitSha."
    }
}

function Get-ReleaseAssetNames {
    param([object]$Release)
    return @($Release.assets | ForEach-Object { [string]$_.name })
}

function Get-ExpectedReleaseAssetNames {
    param([string]$ExpectedTag)
    return @("StatsPro-$ExpectedTag.zip", "release.json")
}

function Test-ContainsOrdinal {
    param([string[]]$Values, [string]$Expected)

    foreach ($value in $Values) {
        if ([System.StringComparer]::Ordinal.Equals($value, $Expected)) {
            return $true
        }
    }
    return $false
}

function Get-OrdinalStringSet {
    param([string[]]$Values)

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($value in $Values) {
        if (-not $set.Add($value)) {
            throw "Release contains duplicate asset name '$value'."
        }
    }
    return ,$set
}

function Assert-ExactAssetSet {
    param(
        [object]$Release,
        [string[]]$ExpectedNames
    )

    $actual = @(Get-ReleaseAssetNames -Release $Release)
    $actualSet = Get-OrdinalStringSet -Values $actual
    $expectedSet = Get-OrdinalStringSet -Values $ExpectedNames
    if (-not $actualSet.SetEquals($expectedSet)) {
        throw "Release assets are '$($actual -join ', ')'; expected '$($ExpectedNames -join ', ')'."
    }
}

function Assert-ReleaseCoreState {
    param(
        [object]$Release,
        [string]$ExpectedTag
    )

    if ($null -eq $Release) {
        throw "Release marker $ExpectedTag does not exist."
    }
    if (-not [System.StringComparer]::Ordinal.Equals([string]$Release.tag_name, $ExpectedTag)) {
        throw "Release marker tag is '$($Release.tag_name)', expected '$ExpectedTag'."
    }
    if ([bool]$Release.prerelease) {
        throw "Release $ExpectedTag must not be a prerelease."
    }
}

function Assert-NoExistingRelease {
    param(
        [AllowNull()][object]$Release,
        [string]$ExpectedTag
    )

    if ($null -ne $Release) {
        $state = if ([bool]$Release.draft) { "draft marker" } else { "published release" }
        throw "Release $ExpectedTag already has a $state; refusing marketplace republish."
    }
}

function Assert-DraftRelease {
    param(
        [object]$Release,
        [string]$ExpectedTag,
        [string[]]$ExpectedAssets
    )

    Assert-ReleaseCoreState -Release $Release -ExpectedTag $ExpectedTag
    if (-not [bool]$Release.draft) {
        throw "Release $ExpectedTag is already published."
    }
    if ([bool]$Release.immutable) {
        throw "Draft release $ExpectedTag unexpectedly reports immutable state."
    }
    Assert-ExactAssetSet -Release $Release -ExpectedNames $ExpectedAssets
}

function Assert-ReleaseMarkerIdentity {
    param(
        [object]$Release,
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [string]$ExpectedPhase,
        [AllowEmptyString()][string]$ExpectedRunId,
        [AllowEmptyString()][string]$ExpectedRunAttempt,
        [AllowEmptyString()][string]$ExpectedNotes,
        [AllowEmptyString()][string]$ExpectedManifestSha256,
        [AllowEmptyString()][string]$ExpectedArchiveSha256,
        [AllowEmptyString()][string]$ExpectedCandidateSha256
    )

    Assert-ReleaseCoreState -Release $Release -ExpectedTag $ExpectedTag
    if (-not [System.StringComparer]::Ordinal.Equals([string]$Release.name, $ExpectedTag)) {
        throw "Release title is '$($Release.name)', expected '$ExpectedTag'."
    }
    # WHY: GitHub reports target_commitish as the default branch for releases
    # created from existing tags. The peeled remote tag check is authoritative.
    $parsed = Read-ReleaseStateMarker -Body ([string]$Release.body)
    $state = $parsed.State
    if (-not [System.StringComparer]::Ordinal.Equals([string]$state.repository, $Repository) -or
        -not [System.StringComparer]::Ordinal.Equals([string]$state.tag, $ExpectedTag) -or
        -not [System.StringComparer]::Ordinal.Equals([string]$state.commitSha, $ExpectedCommitSha)) {
        throw "Release state marker identity does not match repository, tag, and commit."
    }
    if (-not [string]::IsNullOrEmpty($ExpectedPhase) -and -not [System.StringComparer]::Ordinal.Equals([string]$state.phase, $ExpectedPhase)) {
        throw "Release state phase is '$($state.phase)', expected '$ExpectedPhase'."
    }
    if (-not [string]::IsNullOrEmpty($ExpectedRunId) -and -not [System.StringComparer]::Ordinal.Equals([string]$state.runId, $ExpectedRunId)) {
        throw "Release state belongs to run '$($state.runId)', expected '$ExpectedRunId'."
    }
    if (-not [string]::IsNullOrEmpty($ExpectedRunAttempt) -and
        -not [System.StringComparer]::Ordinal.Equals([string]$state.runAttempt, $ExpectedRunAttempt)) {
        throw "Release state belongs to run attempt '$($state.runAttempt)', expected '$ExpectedRunAttempt'."
    }
    if ($PSBoundParameters.ContainsKey('ExpectedNotes') -and
        -not [System.StringComparer]::Ordinal.Equals((Get-LowercaseTextSha256 -Text $ExpectedNotes), [string]$state.notesSha256)) {
        throw "Release state notes digest does not match the current release notes."
    }
    if (-not [string]::IsNullOrEmpty($ExpectedManifestSha256) -and
        -not [System.StringComparer]::Ordinal.Equals([string]$state.manifestSha256, $ExpectedManifestSha256)) {
        throw "Release state manifest digest does not match the validated package tree."
    }
    if (-not [string]::IsNullOrEmpty($ExpectedArchiveSha256) -and
        -not [System.StringComparer]::Ordinal.Equals([string]$state.archiveSha256, $ExpectedArchiveSha256)) {
        throw "Release state archive digest does not match the attested archive."
    }
    if (-not [string]::IsNullOrEmpty($ExpectedCandidateSha256) -and
        -not [System.StringComparer]::Ordinal.Equals([string]$state.candidateSha256, $ExpectedCandidateSha256)) {
        throw "Release state candidate digest does not match the attested handoff."
    }
    return $parsed
}

function Assert-ReleaseProtocolIdentity {
    param(
        [object]$Release,
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [string]$ExpectedPhase,
        [AllowEmptyString()][string]$ExpectedRunId,
        [AllowEmptyString()][string]$ExpectedRunAttempt,
        [AllowEmptyString()][string]$ExpectedNotes,
        [AllowEmptyString()][string]$ExpectedManifestSha256,
        [AllowEmptyString()][string]$ExpectedArchiveSha256,
        [AllowEmptyString()][string]$ExpectedCandidateSha256
    )

    if ($null -eq $Release) {
        throw "Release marker $ExpectedTag does not exist."
    }
    if (-not [bool]$Release.draft) {
        throw "Release $ExpectedTag is already published; marketplace replay is forbidden."
    }
    if ([bool]$Release.immutable) {
        throw "Draft release $ExpectedTag unexpectedly reports immutable state."
    }
    return Assert-ReleaseMarkerIdentity @PSBoundParameters
}

function Assert-ReleaseStartState {
    param(
        [AllowNull()][object]$Release,
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [string]$ExpectedNotes
    )

    if ($null -eq $Release) {
        return 'fresh'
    }
    $parsed = Assert-ReleaseProtocolIdentity `
        -Release $Release `
        -Repository $Repository `
        -ExpectedTag $ExpectedTag `
        -ExpectedCommitSha $ExpectedCommitSha `
        -ExpectedPhase 'prepared' `
        -ExpectedNotes $ExpectedNotes
    Assert-ExactAssetSet -Release $Release -ExpectedNames @()
    return "prepared:$($parsed.State.runId)"
}

function Get-PreparedDraftClaimDisposition {
    param(
        [object]$Release,
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [string]$ExpectedNotes,
        [string]$ExpectedManifestSha256,
        [string]$DesiredBody
    )

    [void](Assert-ReleaseProtocolIdentity `
        -Release $Release `
        -Repository $Repository `
        -ExpectedTag $ExpectedTag `
        -ExpectedCommitSha $ExpectedCommitSha `
        -ExpectedPhase 'prepared' `
        -ExpectedNotes $ExpectedNotes `
        -ExpectedManifestSha256 $ExpectedManifestSha256)
    Assert-ExactAssetSet -Release $Release -ExpectedNames @()
    $existingBody = (([string]$Release.body -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd([char[]]"`n")
    if ([System.StringComparer]::Ordinal.Equals($existingBody, $DesiredBody)) {
        return 'already-current'
    }
    return 'rebind'
}

function Assert-PublishedProtocolIdentity {
    param(
        [object]$Release,
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [AllowEmptyString()][string]$ExpectedRunId,
        [AllowEmptyString()][string]$ExpectedRunAttempt,
        [string]$ExpectedNotes,
        [string]$ExpectedManifestSha256,
        [AllowEmptyString()][string]$ExpectedArchiveSha256,
        [AllowEmptyString()][string]$ExpectedCandidateSha256
    )

    Assert-PublishedImmutableRelease -Release $Release -ExpectedTag $ExpectedTag
    if (-not [System.StringComparer]::Ordinal.Equals([string]$Release.name, $ExpectedTag)) {
        throw "Published release title does not match the release transaction."
    }
    $parsed = Assert-ReleaseMarkerIdentity `
        -Release $Release `
        -Repository $Repository `
        -ExpectedTag $ExpectedTag `
        -ExpectedCommitSha $ExpectedCommitSha `
        -ExpectedPhase 'marketplace-started' `
        -ExpectedRunId $ExpectedRunId `
        -ExpectedRunAttempt $ExpectedRunAttempt `
        -ExpectedNotes $ExpectedNotes `
        -ExpectedManifestSha256 $ExpectedManifestSha256 `
        -ExpectedArchiveSha256 $ExpectedArchiveSha256 `
        -ExpectedCandidateSha256 $ExpectedCandidateSha256
    $state = $parsed.State
    if (-not [System.StringComparer]::Ordinal.Equals([string]$state.phase, 'marketplace-started')) {
        throw "Published release state marker does not match the expected transaction."
    }
    return $parsed
}

function Assert-ReleaseAssetSubsetMatchesLocalFiles {
    param(
        [object]$Release,
        [hashtable]$LocalFiles
    )

    $expectedNames = @($LocalFiles.Keys)
    $actualNames = @(Get-ReleaseAssetNames -Release $Release)
    [void](Get-OrdinalStringSet -Values $actualNames)
    foreach ($name in $actualNames) {
        if (-not (Test-ContainsOrdinal -Values $expectedNames -Expected $name)) {
            throw "Release contains unexpected asset '$name'."
        }
        $asset = @($Release.assets | Where-Object { [System.StringComparer]::Ordinal.Equals([string]$_.name, $name) })[0]
        $path = $LocalFiles[$name]
        if (-not [System.StringComparer]::Ordinal.Equals([string]$asset.state, 'uploaded')) {
            throw "Draft asset $name is in state '$($asset.state)', expected 'uploaded'."
        }
        $expectedSize = (Get-Item -LiteralPath $path).Length
        if ([long]$asset.size -ne $expectedSize) {
            throw "Draft asset $name size is $($asset.size), expected $expectedSize."
        }
        $expectedDigest = "sha256:$(Get-LowercaseFileSha256 -Path $path)"
        if (-not [System.StringComparer]::Ordinal.Equals([string]$asset.digest, $expectedDigest)) {
            throw "Draft asset $name digest is '$($asset.digest)', expected '$expectedDigest'."
        }
    }
}

function Assert-PublishedImmutableRelease {
    param(
        [object]$Release,
        [string]$ExpectedTag
    )

    Assert-ReleaseCoreState -Release $Release -ExpectedTag $ExpectedTag
    if ([bool]$Release.draft) {
        throw "Release $ExpectedTag is still a draft."
    }
    if (-not [bool]$Release.immutable) {
        throw "Published release $ExpectedTag is not immutable."
    }
    Assert-ExactAssetSet -Release $Release -ExpectedNames (Get-ExpectedReleaseAssetNames -ExpectedTag $ExpectedTag)
}

function Assert-LocalArchiveSha256 {
    param([string]$Path, [string]$ExpectedSha256)

    Assert-LowercaseSha256 -Value $ExpectedSha256 -Description 'Expected release archive digest'
    $resolved = Resolve-ReleaseManagerRequiredFile -Path $Path -Description 'release archive'
    $actual = Get-LowercaseFileSha256 -Path $resolved
    if (-not [System.StringComparer]::Ordinal.Equals($actual, $ExpectedSha256)) {
        throw "Release archive digest is '$actual', expected '$ExpectedSha256'."
    }
    return $resolved
}

function Assert-DraftAssetsMatchLocalFiles {
    param(
        [object]$Release,
        [string]$ExpectedTag,
        [string]$ArchivePath,
        [string]$ReleaseJsonPath
    )

    Assert-DraftRelease -Release $Release -ExpectedTag $ExpectedTag -ExpectedAssets (Get-ExpectedReleaseAssetNames -ExpectedTag $ExpectedTag)
    $localFiles = @{
        "StatsPro-$ExpectedTag.zip" = $ArchivePath
        "release.json"              = $ReleaseJsonPath
    }
    foreach ($asset in @($Release.assets)) {
        $name = [string]$asset.name
        $path = $localFiles[$name]
        if (-not [System.StringComparer]::Ordinal.Equals([string]$asset.state, "uploaded")) {
            throw "Draft asset $name is in state '$($asset.state)', expected 'uploaded'."
        }
        $expectedSize = (Get-Item -LiteralPath $path).Length
        if ([long]$asset.size -ne $expectedSize) {
            throw "Draft asset $name size is $($asset.size), expected $expectedSize."
        }
        $expectedDigest = "sha256:$(Get-LowercaseFileSha256 -Path $path)"
        if (-not [System.StringComparer]::Ordinal.Equals([string]$asset.digest, $expectedDigest)) {
            throw "Draft asset $name digest is '$($asset.digest)', expected '$expectedDigest'."
        }
    }
}

function Invoke-GitHubMutationAndAttest {
    param(
        [string]$Description,
        [string[]]$Arguments,
        [string]$Repository,
        [string]$ExpectedTag,
        [int]$Attempts,
        [datetime]$Deadline,
        [scriptblock]$AssertState,
        [scriptblock]$Mutate = $null,
        [scriptblock]$GetRelease = $null,
        [scriptblock]$Wait = $null,
        [scriptblock]$Now = $null
    )

    if ($null -eq $Mutate) {
        $Mutate = {
            param([string[]]$GhArguments, [datetime]$RequestDeadline)
            [void](Invoke-Gh -Arguments $GhArguments -Deadline $RequestDeadline -Description $Description)
        }
    }
    if ($null -eq $Now) {
        $Now = { Get-Date }
    }
    $attestationReserveSeconds = 30
    $mutationMaximumSeconds = 60
    $nowValue = & $Now
    $reservedDeadline = $Deadline.AddSeconds(-$attestationReserveSeconds)
    if ($nowValue -ge $reservedDeadline) {
        throw "$Description cannot start because fewer than $attestationReserveSeconds second(s) remain for read-only attestation."
    }
    $mutationDeadline = $nowValue.AddSeconds($mutationMaximumSeconds)
    if ($mutationDeadline -gt $reservedDeadline) {
        $mutationDeadline = $reservedDeadline
    }
    $mutationError = $null
    try {
        & $Mutate $Arguments $mutationDeadline
        if ((& $Now) -ge $mutationDeadline) {
            throw [System.TimeoutException]::new("$Description completed after its mutation deadline.")
        }
    }
    catch {
        $mutationError = $_
    }
    try {
        $release = Wait-GitHubReleaseState `
            -Repository $Repository `
            -ExpectedTag $ExpectedTag `
            -Attempts $Attempts `
            -Deadline $Deadline `
            -AssertState $AssertState `
            -GetRelease $GetRelease `
            -Wait $Wait `
            -Now $Now
    }
    catch {
        if ($null -ne $mutationError) {
            throw "$Description returned an error and the desired state was not observed: $($mutationError.Exception.Message); attestation: $($_.Exception.Message)"
        }
        throw
    }
    if ($null -ne $mutationError) {
        Write-Warning "$Description returned an ambiguous error, but read-only attestation confirmed the desired state: $($mutationError.Exception.Message)"
    }
    return $release
}

function Invoke-BoundedReadOnlyCheck {
    param(
        [string]$Description,
        [int]$Attempts,
        [datetime]$Deadline,
        [scriptblock]$Check,
        [scriptblock]$Wait = $null,
        [scriptblock]$Now = $null
    )

    if ($Attempts -lt 1) {
        throw "$Description attempts must be at least 1."
    }
    if ($null -eq $Wait) {
        $Wait = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
    }
    if ($null -eq $Now) {
        $Now = { Get-Date }
    }
    $lastError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if ((Get-DeadlineRemainingMilliseconds -Deadline $Deadline -Now $Now) -lt 1) {
            throw "$Description exceeded its absolute deadline before attempt $attempt."
        }
        try {
            & $Check $Deadline
            if ((Get-DeadlineRemainingMilliseconds -Deadline $Deadline -Now $Now) -lt 1) {
                throw "$Description completed after its absolute deadline."
            }
            return
        }
        catch {
            $lastError = $_
            if ($attempt -lt $Attempts) {
                $remainingMilliseconds = Get-DeadlineRemainingMilliseconds -Deadline $Deadline -Now $Now
                if ($remainingMilliseconds -lt 1) {
                    break
                }
                $waitSeconds = [Math]::Min([Math]::Min(30, 5 * $attempt), [int][Math]::Floor($remainingMilliseconds / 1000))
                if ($waitSeconds -lt 1) {
                    break
                }
                & $Wait $waitSeconds
            }
        }
    }
    throw "$Description did not pass after $Attempts attempt(s): $($lastError.Exception.Message)"
}

function Resolve-ReleaseManagerRequiredFile {
    param(
        [string]$Path,
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing $Description file: '$Path'."
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-ReleaseAssetPaths {
    param(
        [string]$ArchivePath,
        [string]$ReleaseJsonPath,
        [string]$ExpectedTag
    )

    $archive = Resolve-ReleaseManagerRequiredFile -Path $ArchivePath -Description "StatsPro archive"
    $releaseJson = Resolve-ReleaseManagerRequiredFile -Path $ReleaseJsonPath -Description "release.json"
    if (-not [System.StringComparer]::Ordinal.Equals([System.IO.Path]::GetFileName($archive), "StatsPro-$ExpectedTag.zip")) {
        throw "Archive filename must be StatsPro-$ExpectedTag.zip."
    }
    if (-not [System.StringComparer]::Ordinal.Equals([System.IO.Path]::GetFileName($releaseJson), "release.json")) {
        throw "Release metadata filename must be release.json."
    }
    return [pscustomobject]@{
        Archive     = $archive
        ReleaseJson = $releaseJson
    }
}

function Assert-ReleaseAttestationCommit {
    param(
        [object]$Attestation,
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha
    )

    Assert-CommitSha $ExpectedCommitSha
    $expectedUri = "pkg:github/$Repository@$ExpectedTag"
    $subjects = @(
        @($Attestation) |
            ForEach-Object { @($_.verificationResult.statement.subject) } |
            Where-Object { [string]$_.uri -eq $expectedUri }
    )
    if ($subjects.Count -ne 1) {
        throw "Release attestation must contain exactly one subject URI $expectedUri; found $($subjects.Count)."
    }
    $attestedCommit = [string]$subjects[0].digest.sha1
    if ($attestedCommit -ne $ExpectedCommitSha) {
        throw "Release attestation commit is '$attestedCommit', expected '$ExpectedCommitSha'."
    }
}

function Invoke-ImmutableReleaseAttestationChecks {
    param(
        [string]$Repository,
        [string]$ExpectedTag,
        [string]$ExpectedCommitSha,
        [string]$ArchivePath,
        [string]$ReleaseJsonPath,
        [datetime]$Deadline
    )

    $attestationJson = (Invoke-Gh -Deadline $Deadline -Description "GitHub release attestation" -Arguments @("release", "verify", $ExpectedTag, "--repo", $Repository, "--format", "json")) -join "`n"
    Assert-ReleaseAttestationCommit `
        -Attestation (ConvertFrom-JsonCompat $attestationJson) `
        -Repository $Repository `
        -ExpectedTag $ExpectedTag `
        -ExpectedCommitSha $ExpectedCommitSha
    [void](Invoke-Gh -Deadline $Deadline -Description "GitHub archive asset attestation" -Arguments @("release", "verify-asset", $ExpectedTag, $ArchivePath, "--repo", $Repository))
    [void](Invoke-Gh -Deadline $Deadline -Description "GitHub metadata asset attestation" -Arguments @("release", "verify-asset", $ExpectedTag, $ReleaseJsonPath, "--repo", $Repository))
}

function Get-WorkflowJobBlock {
    param([string]$WorkflowText, [string]$JobName)

    $escapedName = [regex]::Escape($JobName)
    $jobBlock = [regex]::Match(
        $WorkflowText,
        "(?ms)^  ${escapedName}:\s*$.*?(?=^  [A-Za-z0-9_-]+:\s*$|\z)"
    )
    if (-not $jobBlock.Success) {
        throw "Workflow is missing job '$JobName'."
    }
    return $jobBlock
}

function Get-WorkflowStepName {
    param([System.Text.RegularExpressions.Match]$StepBlock)

    $name = [regex]::Match($StepBlock.Value, '(?m)^\s{6}- name:\s*(.+?)\s*$')
    if (-not $name.Success) {
        throw "Could not resolve a workflow step name."
    }
    return $name.Groups[1].Value
}

function Assert-ExactWorkflowKeySet {
    param(
        [string]$Text,
        [int]$Indent,
        [string[]]$ExpectedKeys,
        [string]$Description
    )

    $prefix = " " * $Indent
    $actualKeys = @(
        [regex]::Matches($Text, "(?m)^$([regex]::Escape($prefix))([A-Za-z][A-Za-z0-9_-]*):") |
            ForEach-Object { $_.Groups[1].Value }
    )
    $actualUnique = @($actualKeys | Sort-Object -Unique)
    $expectedUnique = @($ExpectedKeys | Sort-Object -Unique)
    if ($actualKeys.Count -ne $actualUnique.Count -or
        $ExpectedKeys.Count -ne $expectedUnique.Count -or
        $actualUnique.Count -ne $expectedUnique.Count -or
        (Compare-Object -ReferenceObject $expectedUnique -DifferenceObject $actualUnique)) {
        throw "$Description keys are '$($actualKeys -join ', ')'; expected '$($ExpectedKeys -join ', ')'."
    }
}

function Assert-ExactWorkflowBlock {
    param(
        [string]$Actual,
        [string]$Expected,
        [string]$Description
    )

    $normalizedActual = (($Actual -replace "`r", '')).Trim()
    $normalizedExpected = (($Expected -replace "`r", '')).Trim()
    if (-not [System.StringComparer]::Ordinal.Equals($normalizedActual, $normalizedExpected)) {
        throw "$Description must match its exact canonical YAML block."
    }
}

function Test-ContainsSecretReference {
    param([string]$Text, [string]$SecretName)

    $escapedSecretName = [regex]::Escape($SecretName)
    $pattern = @'
(?ix)
\bsecrets\s*(?:\.\s*__SECRET__\b|\[\s*['"]\s*__SECRET__\s*['"]\s*\])
'@
    return $Text -match $pattern.Replace('__SECRET__', $escapedSecretName)
}

function Test-ContainsAnySecretReference {
    param([string]$Text)

    return $Text -match '(?i)\bsecrets\b'
}

function Test-ContainsGitHubTokenReference {
    param([string]$Text)

    return (Test-ContainsSecretReference -Text $Text -SecretName 'GITHUB_TOKEN') -or
        $Text -match @'
(?ix)
\bgithub\s*(?:\.\s*token\b|\[\s*['"]\s*token\s*['"]\s*\])
'@
}

function Test-ContainsPrivilegedReleaseTokenReference {
    param([string]$Text)

    return (Test-ContainsGitHubTokenReference -Text $Text) -or
        (Test-ContainsSecretReference -Text $Text -SecretName 'IMMUTABLE_RELEASES_READ_TOKEN')
}

function Assert-WorkflowCheckoutCredentialBoundary {
    param(
        [string]$WorkflowText,
        [string[]]$JobNames
    )

    foreach ($jobName in $JobNames) {
        $jobBlock = Get-WorkflowJobBlock -WorkflowText $WorkflowText -JobName $jobName
        $stepBlocks = @([regex]::Matches($jobBlock.Value, '(?ms)^\s{6}- name: .+?\s*$.*?(?=^\s{6}- name:|\z)'))
        $checkoutSteps = @($stepBlocks | Where-Object {
            $_.Value -match '(?m)^\s{8}uses:\s*actions/checkout@[0-9a-f]{40}\s*$'
        })
        if ($checkoutSteps.Count -ne 1) {
            throw "Workflow job '$jobName' must contain exactly one SHA-pinned checkout step."
        }

        $checkoutStep = $checkoutSteps[0]
        $fetchDepth = @([regex]::Matches($checkoutStep.Value, '(?m)^\s{10}fetch-depth:\s*(.*?)\s*$'))
        if ($fetchDepth.Count -ne 1 -or $fetchDepth[0].Groups[1].Value -ne '0') {
            throw "Workflow job '$jobName' checkout must preserve full history with fetch-depth: 0."
        }
        $persistCredentials = @([regex]::Matches($checkoutStep.Value, '(?m)^\s{10}persist-credentials:\s*(.*?)\s*$'))
        if ($persistCredentials.Count -ne 1 -or $persistCredentials[0].Groups[1].Value -ne 'false') {
            throw "Workflow job '$jobName' checkout must contain exactly one literal persist-credentials: false."
        }
        if ($checkoutStep.Value -match '(?m)^\s{10}(?:token|ssh-key):' -or
            (Test-ContainsPrivilegedReleaseTokenReference -Text $checkoutStep.Value)) {
            throw "Workflow job '$jobName' checkout must not receive explicit credentials."
        }

        $checkoutOrdinal = -1
        for ($index = 0; $index -lt $stepBlocks.Count; $index++) {
            if ($stepBlocks[$index].Index -eq $checkoutStep.Index) {
                $checkoutOrdinal = $index
                break
            }
        }
        if ($checkoutOrdinal -lt 0 -or $checkoutOrdinal + 1 -ge $stepBlocks.Count) {
            throw "Workflow job '$jobName' must verify checkout credentials immediately after checkout."
        }
        $verificationStep = $stepBlocks[$checkoutOrdinal + 1]
        if ((Get-WorkflowStepName -StepBlock $verificationStep) -ne 'Verify anonymous checkout boundary' -or
            $verificationStep.Value -notmatch '(?m)^\s{8}shell:\s*pwsh\s*$' -or
            $verificationStep.Value -notmatch '(?m)^\s{8}run:\s*[.\\/]+scripts[\\/]check-anonymous-checkout\.ps1\s*$') {
            throw "Workflow job '$jobName' must verify checkout credentials immediately after checkout."
        }
    }
}

function Assert-ChecksWorkflowBoundary {
    param([string]$WorkflowText)

    $triggerBlock = [regex]::Match($WorkflowText, '(?ms)^on:\s*$.*?(?=^[A-Za-z][A-Za-z0-9_-]*:\s*|\z)')
    if ($triggerBlock.Success -and $triggerBlock.Value -match '(?m)^  pull_request_target:\s*$') {
        throw "Checks workflow must not use pull_request_target."
    }
    if (-not $triggerBlock.Success -or $triggerBlock.Value -notmatch '(?m)^  pull_request:\s*$') {
        throw "Checks workflow must include the pull_request trigger."
    }

    $permissionsBlock = [regex]::Match($WorkflowText, '(?ms)^permissions:\s*$.*?(?=^[A-Za-z][A-Za-z0-9_-]*:\s*|\z)')
    if (-not $permissionsBlock.Success -or
        $permissionsBlock.Value -notmatch '(?m)^  contents:\s*read\s*$' -or
        $permissionsBlock.Value -match '(?im)^  [A-Za-z][A-Za-z0-9_-]*:\s*write\s*$') {
        throw "Checks workflow must grant contents: read without workflow-level write permissions."
    }

    $packageJob = Get-WorkflowJobBlock -WorkflowText $WorkflowText -JobName 'package-contract'
    if ($packageJob.Value -match '(?m)^    if:\s*') {
        throw "Checks package-contract job must not define a job-level pull request filter."
    }
    if ($packageJob.Value -match '(?im)^    permissions:\s*(?:write-all|\{[^}]*write)' -or
        $packageJob.Value -match '(?im)^      [A-Za-z][A-Za-z0-9_-]*:\s*write\s*$') {
        throw "Checks package-contract job must not escalate workflow permissions."
    }
    if ((Test-ContainsAnySecretReference -Text $packageJob.Value) -or
        (Test-ContainsGitHubTokenReference -Text $packageJob.Value)) {
        throw "Checks package-contract job must not reference secrets or a GitHub token."
    }
    Assert-WorkflowCheckoutCredentialBoundary -WorkflowText $WorkflowText -JobNames @('package-contract')

    $stepBlocks = @([regex]::Matches($packageJob.Value, '(?ms)^\s{6}- name: .+?\s*$.*?(?=^\s{6}- name:|\z)'))
    $packagerSteps = @($stepBlocks | Where-Object { $_.Value -match '(?im)^\s{8}uses:\s*BigWigsMods/packager@' })
    if ($packagerSteps.Count -ne 1 -or
        $packagerSteps[0].Value -notmatch '(?m)^\s{8}uses:\s*BigWigsMods/packager@6d50adb6e8517eefef63f4afb16a6518166a6b28\s*$') {
        throw "Checks package-contract job must use the exact pinned BigWigs Packager action once."
    }
    $packagerArgs = @([regex]::Matches($packagerSteps[0].Value, '(?m)^\s{10}args:\s*(.*?)\s*$'))
    if ($packagerArgs.Count -ne 1 -or $packagerArgs[0].Groups[1].Value -ne '-d') {
        throw "Checks package-contract Packager step must use literal args: -d without publication flags."
    }

    $resolverSteps = @($stepBlocks | Where-Object { $_.Value -match '(?i)resolve-packager-output\.ps1' })
    $validatorSteps = @($stepBlocks | Where-Object { $_.Value -match '(?i)check-package-dry-run\.ps1' })
    if ($resolverSteps.Count -ne 1 -or $validatorSteps.Count -ne 1) {
        throw "Checks package-contract job must contain one package resolver and one package validator step."
    }
    if ($packagerSteps[0].Index -ge $resolverSteps[0].Index -or
        $resolverSteps[0].Index -ge $validatorSteps[0].Index) {
        throw "Checks package-contract must run Packager, resolver, and validator in that order."
    }

    $resolver = $resolverSteps[0].Value
    $validator = $validatorSteps[0].Value
    if ($resolver -notmatch '(?m)^\s{8}id:\s*package-output\s*$' -or
        $resolver -notmatch '(?m)^\s{8}shell:\s*pwsh\s*$' -or
        $resolver -notmatch '(?m)^\s{8}run:\s*\./scripts/resolve-packager-output\.ps1\s+-OutputPath\s+\$env:GITHUB_OUTPUT\s*$' -or
        $validator -notmatch '(?m)^\s{8}shell:\s*pwsh\s*$' -or
        $validator -notmatch '(?m)^\s{10}STATSPRO_ARCHIVE_PATH:\s*\$\{\{\s*steps\.package-output\.outputs\.archive_path\s*\}\}\s*$' -or
        $validator -notmatch '(?m)^\s{10}STATSPRO_PROJECT_VERSION:\s*\$\{\{\s*steps\.package-output\.outputs\.project_version\s*\}\}\s*$' -or
        $validator -notmatch '(?m)-ArchivePath\s+\$env:STATSPRO_ARCHIVE_PATH' -or
        $validator -notmatch '(?m)-PackagerProjectVersion\s+\$env:STATSPRO_PROJECT_VERSION') {
        throw "Checks package-contract must preserve the resolver-to-validator output handoff."
    }
}

function Assert-CanonicalMarketplaceEnvironment {
    param(
        [System.Text.RegularExpressions.Match]$StepBlock,
        [string]$StepName
    )

    $expectedNames = @('CF_API_KEY', 'WAGO_API_TOKEN', 'WOWI_API_TOKEN')
    $actualNames = @(
        [regex]::Matches($StepBlock.Value, '(?m)^\s{10}([A-Z][A-Z0-9_]+):') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object
    )
    if ($actualNames.Count -ne $expectedNames.Count -or
        (Compare-Object -ReferenceObject ($expectedNames | Sort-Object) -DifferenceObject $actualNames)) {
        throw "Marketplace step '$StepName' must expose exactly the three marketplace token environment keys."
    }

    $withoutCanonicalReferences = $StepBlock.Value
    foreach ($name in $expectedNames) {
        $linePattern = "(?m)^\s{10}${name}:\s*\`$\{\{\s*secrets\.${name}\s*\}\}\s*`$"
        $lines = @([regex]::Matches($withoutCanonicalReferences, $linePattern))
        if ($lines.Count -ne 1) {
            throw "Marketplace step '$StepName' must bind $name exactly once to secrets.$name."
        }
        $withoutCanonicalReferences = $withoutCanonicalReferences.Remove($lines[0].Index, $lines[0].Length)
    }
    if (Test-ContainsAnySecretReference -Text $withoutCanonicalReferences) {
        throw "Marketplace step '$StepName' contains a non-canonical secret reference."
    }
}

function Assert-TrustedManualWorkflowBoundary {
    param(
        [string]$WorkflowText,
        [string]$JobName,
        [string]$ExpectedTrigger,
        [string]$ExpectedWorkflowName
    )

    Assert-WorkflowCheckoutCredentialBoundary -WorkflowText $WorkflowText -JobNames @($JobName)

    if ($WorkflowText -match '(?m)^\s*(?:"[^"\r\n]+"|''[^''\r\n]+''|<<|\?[^:\r\n]*):') {
        throw "Trusted manual workflow must not use quoted, merged, or explicit mapping keys."
    }
    if ($WorkflowText -match '(?m)^\s*[A-Za-z][A-Za-z0-9_-]*[ \t]+:') {
        throw "Trusted manual workflow mapping keys must not contain whitespace before the colon."
    }
    if ($WorkflowText -match '(?m)^\s*(?:\?\s+|:\s+)') {
        throw "Trusted manual workflow must not use multi-line explicit mapping keys."
    }
    Assert-ExactWorkflowKeySet `
        -Text $WorkflowText `
        -Indent 0 `
        -ExpectedKeys @('name', 'on', 'permissions', 'jobs') `
        -Description "Trusted manual workflow"
    $nameLines = @([regex]::Matches($WorkflowText, '(?m)^name:\s*(.*?)\s*$'))
    if ($nameLines.Count -ne 1 -or $nameLines[0].Groups[1].Value -ne $ExpectedWorkflowName) {
        throw "Trusted manual workflow name must remain '$ExpectedWorkflowName'."
    }

    $triggerBlock = [regex]::Match($WorkflowText, '(?ms)^on:\s*$.*?(?=^permissions:\s*$)')
    $normalizedTrigger = if ($triggerBlock.Success) {
        ($triggerBlock.Value -replace "`r", '').Trim()
    }
    else {
        ''
    }
    if ($normalizedTrigger -ne (($ExpectedTrigger -replace "`r", '').Trim())) {
        throw "Trusted manual workflow must keep its exact workflow_dispatch trigger and inputs."
    }
    $permissionsBlock = [regex]::Match($WorkflowText, '(?ms)^permissions:\s*$.*?(?=^jobs:\s*$)')
    $normalizedPermissions = if ($permissionsBlock.Success) {
        ($permissionsBlock.Value -replace "`r", '').Trim()
    }
    else {
        ''
    }
    if ($normalizedPermissions -ne "permissions:`n  contents: read") {
        throw "Trusted manual workflow must have contents: read as its only workflow permission."
    }

    $jobBlock = Get-WorkflowJobBlock -WorkflowText $WorkflowText -JobName $JobName
    Assert-ExactWorkflowKeySet `
        -Text $jobBlock.Value `
        -Indent 4 `
        -ExpectedKeys @('if', 'environment', 'runs-on', 'steps') `
        -Description "Trusted manual job '$JobName'"
    $runsOnLines = @([regex]::Matches($jobBlock.Value, '(?m)^    runs-on:\s*(.*?)\s*$'))
    if ($runsOnLines.Count -ne 1 -or $runsOnLines[0].Groups[1].Value -ne 'ubuntu-latest') {
        throw "Trusted manual job '$JobName' must run only on ubuntu-latest."
    }
    $expectedIf = '${{ github.ref == ''refs/heads/main'' }}'
    $ifLines = @([regex]::Matches(
        $jobBlock.Value,
        "(?m)^    if:\s*$([regex]::Escape($expectedIf))\s*`$"
    ))
    if ($ifLines.Count -ne 1) {
        throw "Trusted manual job '$JobName' must require the exact main ref as defense in depth."
    }
    $environmentLines = @([regex]::Matches($jobBlock.Value, '(?m)^    environment:\s*(.*?)\s*$'))
    if ($environmentLines.Count -ne 1 -or $environmentLines[0].Groups[1].Value -ne 'marketplace-manual') {
        throw "Trusted manual job '$JobName' must bind exactly environment marketplace-manual."
    }
    $stepBlocks = @([regex]::Matches($jobBlock.Value, '(?ms)^\s{6}- name: .+?\s*$.*?(?=^\s{6}- name:|\z)'))
    $rawStepStarts = @([regex]::Matches($jobBlock.Value, '(?m)^\s{6}-\s+'))
    if ($rawStepStarts.Count -ne $stepBlocks.Count) {
        throw "Trusted manual job '$JobName' must use named steps only."
    }
    $checkoutSteps = @($stepBlocks | Where-Object {
        $_.Value -match '(?m)^\s{8}uses:\s*actions/checkout@[0-9a-f]{40}\s*$'
    })
    if ($checkoutSteps.Count -ne 1) {
        throw "Trusted manual job '$JobName' must contain exactly one SHA-pinned checkout step."
    }
    $checkoutStep = $checkoutSteps[0]
    Assert-ExactWorkflowKeySet `
        -Text $checkoutStep.Value `
        -Indent 8 `
        -ExpectedKeys @('uses', 'with') `
        -Description "Trusted manual job '$JobName' checkout step"
    Assert-ExactWorkflowKeySet `
        -Text $checkoutStep.Value `
        -Indent 10 `
        -ExpectedKeys @('ref', 'fetch-depth', 'persist-credentials') `
        -Description "Trusted manual job '$JobName' checkout inputs"
    $expectedCheckoutStep = @'
      - name: Checkout
        uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10
        with:
          ref: ${{ github.sha }}
          fetch-depth: 0
          persist-credentials: false
'@
    $expectedCheckoutRef = '${{ github.sha }}'
    $checkoutRefs = @([regex]::Matches($checkoutStep.Value, '(?m)^\s{10}ref:\s*(.*?)\s*$'))
    if ($checkoutRefs.Count -ne 1 -or $checkoutRefs[0].Groups[1].Value -ne $expectedCheckoutRef) {
        throw "Trusted manual job '$JobName' checkout must bind the exact dispatched commit with ref: `${{ github.sha }}."
    }
    if ($checkoutStep.Value -match '(?m)^\s{10}(?:repository|path|submodules):') {
        throw "Trusted manual job '$JobName' checkout must not redirect repository content."
    }
    Assert-ExactWorkflowBlock `
        -Actual $checkoutStep.Value `
        -Expected $expectedCheckoutStep `
        -Description "Trusted manual job '$JobName' checkout step"

    $checkoutOrdinal = [array]::IndexOf($stepBlocks, $checkoutStep)
    if ($checkoutOrdinal -lt 0 -or $checkoutOrdinal + 1 -ge $stepBlocks.Count) {
        throw "Trusted manual job '$JobName' must verify checkout credentials immediately after checkout."
    }
    $anonymousStep = $stepBlocks[$checkoutOrdinal + 1]
    Assert-ExactWorkflowKeySet `
        -Text $anonymousStep.Value `
        -Indent 8 `
        -ExpectedKeys @('shell', 'run') `
        -Description "Trusted manual job '$JobName' anonymous checkout step"
    $expectedAnonymousStep = @'
      - name: Verify anonymous checkout boundary
        shell: pwsh
        run: ./scripts/check-anonymous-checkout.ps1
'@
    Assert-ExactWorkflowBlock `
        -Actual $anonymousStep.Value `
        -Expected $expectedAnonymousStep `
        -Description "Trusted manual job '$JobName' anonymous checkout step"
}

function Assert-MarketplaceCredentialWorkflowBoundary {
    param([string]$WorkflowText)

    Assert-TrustedManualWorkflowBoundary `
        -WorkflowText $WorkflowText `
        -JobName 'preflight' `
        -ExpectedTrigger "on:`n  workflow_dispatch:" `
        -ExpectedWorkflowName 'Marketplace credential preflight'

    if ($WorkflowText -match 'BigWigsMods/packager@' -or
        $WorkflowText -match '(?i)manage-github-release\.ps1.+CreateDraft' -or
        $WorkflowText -match '(?m)^\s+args:\s*.*(?:^|\s)-o(?:\s|$)') {
        throw "Marketplace credential workflow must not execute Packager, draft creation, or upload commands."
    }

    $stepBlocks = @([regex]::Matches($WorkflowText, '(?ms)^\s{6}- name: .+?\s*$.*?(?=^\s{6}- name:|\z)'))
    $stepNames = @($stepBlocks | ForEach-Object { Get-WorkflowStepName -StepBlock $_ })
    if ($stepNames.Count -ne 3 -or
        $stepNames[0] -ne 'Checkout' -or
        $stepNames[1] -ne 'Verify anonymous checkout boundary' -or
        $stepNames[2] -ne 'Verify marketplace release credentials and versions') {
        throw "Marketplace credential workflow must contain only checkout, anonymous verification, and the credential checker in that order."
    }
    $credentialSteps = @($stepBlocks | Where-Object {
        (Get-WorkflowStepName -StepBlock $_) -eq 'Verify marketplace release credentials and versions'
    })
    if ($credentialSteps.Count -ne 1) {
        throw "Marketplace credential workflow must contain exactly one credential preflight step."
    }
    $credentialStep = $credentialSteps[0]
    Assert-ExactWorkflowKeySet `
        -Text $credentialStep.Value `
        -Indent 8 `
        -ExpectedKeys @('shell', 'env', 'run') `
        -Description "Marketplace credential checker step"
    Assert-ExactWorkflowKeySet `
        -Text $credentialStep.Value `
        -Indent 10 `
        -ExpectedKeys @('CF_API_KEY', 'WAGO_API_TOKEN', 'WOWI_API_TOKEN') `
        -Description "Marketplace credential checker environment"
    $expectedCredentialStep = @'
      - name: Verify marketplace release credentials and versions
        shell: pwsh
        env:
          CF_API_KEY: ${{ secrets.CF_API_KEY }}
          WAGO_API_TOKEN: ${{ secrets.WAGO_API_TOKEN }}
          WOWI_API_TOKEN: ${{ secrets.WOWI_API_TOKEN }}
        run: ./scripts/check-marketplace-versions.ps1
'@
    Assert-CanonicalMarketplaceEnvironment `
        -StepBlock $credentialStep `
        -StepName 'Verify marketplace release credentials and versions'
    if ($credentialStep.Value -notmatch '(?m)^\s{8}shell:\s*pwsh\s*$' -or
        $credentialStep.Value -notmatch '(?m)^\s{8}run:\s*\./scripts/check-marketplace-versions\.ps1\s*$' -or
        $credentialStep.Value -match '(?m)^\s{8}(?:if|continue-on-error|uses):') {
        throw "Marketplace credential workflow must execute the exact mandatory pwsh checker."
    }
    Assert-ExactWorkflowBlock `
        -Actual $credentialStep.Value `
        -Expected $expectedCredentialStep `
        -Description "Marketplace credential checker step"

    $outsideCredentialStep = $WorkflowText.Remove($credentialStep.Index, $credentialStep.Length)
    if ((Test-ContainsAnySecretReference -Text $outsideCredentialStep) -or
        $outsideCredentialStep -match '(?m)^\s*(?:CF_API_KEY|WAGO_API_TOKEN|WOWI_API_TOKEN):') {
        throw "Marketplace credential workflow secrets must be scoped to its checker step."
    }
    $expectedWorkflow = @'
name: Marketplace credential preflight

on:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  preflight:
    if: ${{ github.ref == 'refs/heads/main' }}
    environment: marketplace-manual
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10
        with:
          ref: ${{ github.sha }}
          fetch-depth: 0
          persist-credentials: false

      - name: Verify anonymous checkout boundary
        shell: pwsh
        run: ./scripts/check-anonymous-checkout.ps1

      - name: Verify marketplace release credentials and versions
        shell: pwsh
        env:
          CF_API_KEY: ${{ secrets.CF_API_KEY }}
          WAGO_API_TOKEN: ${{ secrets.WAGO_API_TOKEN }}
          WOWI_API_TOKEN: ${{ secrets.WOWI_API_TOKEN }}
        run: ./scripts/check-marketplace-versions.ps1
'@
    Assert-ExactWorkflowBlock `
        -Actual $WorkflowText `
        -Expected $expectedWorkflow `
        -Description "Marketplace credential workflow"
}

function Assert-CurseForgeDiagnosticsWorkflowBoundary {
    param([string]$WorkflowText)

    $expectedTrigger = @'
on:
  workflow_dispatch:
    inputs:
      version:
        description: Version label to search for, such as vX.Y.Z
        required: true
'@
    Assert-TrustedManualWorkflowBoundary `
        -WorkflowText $WorkflowText `
        -JobName 'files' `
        -ExpectedTrigger $expectedTrigger `
        -ExpectedWorkflowName 'CurseForge diagnostics'

    $stepBlocks = @([regex]::Matches($WorkflowText, '(?ms)^\s{6}- name: .+?\s*$.*?(?=^\s{6}- name:|\z)'))
    $stepNames = @($stepBlocks | ForEach-Object { Get-WorkflowStepName -StepBlock $_ })
    if ($stepNames.Count -ne 3 -or
        $stepNames[0] -ne 'Checkout' -or
        $stepNames[1] -ne 'Verify anonymous checkout boundary' -or
        $stepNames[2] -ne 'Query CurseForge legacy API') {
        throw "CurseForge diagnostics workflow must contain only checkout, anonymous verification, and the query in that order."
    }
    $querySteps = @($stepBlocks | Where-Object {
        (Get-WorkflowStepName -StepBlock $_) -eq 'Query CurseForge legacy API'
    })
    if ($querySteps.Count -ne 1) {
        throw "CurseForge diagnostics workflow must contain exactly one query step."
    }
    $queryStep = $querySteps[0]
    Assert-ExactWorkflowKeySet `
        -Text $queryStep.Value `
        -Indent 8 `
        -ExpectedKeys @('shell', 'env', 'run') `
        -Description "CurseForge diagnostics query step"
    Assert-ExactWorkflowKeySet `
        -Text $queryStep.Value `
        -Indent 10 `
        -ExpectedKeys @('CF_API_KEY', 'STATSPRO_CF_PROJECT_ID', 'STATSPRO_VERSION') `
        -Description "CurseForge diagnostics query environment"
    $expectedQueryStep = @'
      - name: Query CurseForge legacy API
        shell: pwsh
        env:
          CF_API_KEY: ${{ secrets.CF_API_KEY }}
          STATSPRO_CF_PROJECT_ID: "1525100"
          STATSPRO_VERSION: ${{ inputs.version }}
        run: ./scripts/check-curseforge-diagnostics.ps1
'@
    $actualNames = @(
        [regex]::Matches($queryStep.Value, '(?m)^\s{10}([A-Z][A-Z0-9_]+):') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object
    )
    $expectedNames = @('CF_API_KEY', 'STATSPRO_CF_PROJECT_ID', 'STATSPRO_VERSION')
    if ($actualNames.Count -ne $expectedNames.Count -or
        (Compare-Object -ReferenceObject ($expectedNames | Sort-Object) -DifferenceObject $actualNames)) {
        throw "CurseForge diagnostics query must expose only its exact three environment keys."
    }
    $canonicalPatterns = @(
        '(?m)^\s{10}CF_API_KEY:\s*\$\{\{\s*secrets\.CF_API_KEY\s*\}\}\s*$',
        '(?m)^\s{10}STATSPRO_CF_PROJECT_ID:\s*"1525100"\s*$',
        '(?m)^\s{10}STATSPRO_VERSION:\s*\$\{\{\s*inputs\.version\s*\}\}\s*$'
    )
    $withoutCanonicalBindings = $queryStep.Value
    foreach ($pattern in $canonicalPatterns) {
        $matches = @([regex]::Matches($withoutCanonicalBindings, $pattern))
        if ($matches.Count -ne 1) {
            throw "CurseForge diagnostics query must keep its exact secret, project, and version bindings."
        }
        $withoutCanonicalBindings = $withoutCanonicalBindings.Remove($matches[0].Index, $matches[0].Length)
    }
    if ((Test-ContainsAnySecretReference -Text $withoutCanonicalBindings) -or
        $queryStep.Value -notmatch '(?m)^\s{8}shell:\s*pwsh\s*$' -or
        $queryStep.Value -notmatch '(?m)^\s{8}run:\s*\./scripts/check-curseforge-diagnostics\.ps1\s*$' -or
        $queryStep.Value -match '(?m)^\s{8}(?:if|continue-on-error|uses):') {
        throw "CurseForge diagnostics must execute the exact mandatory pwsh checker with no extra secret source."
    }
    Assert-ExactWorkflowBlock `
        -Actual $queryStep.Value `
        -Expected $expectedQueryStep `
        -Description "CurseForge diagnostics query step"

    $outsideQueryStep = $WorkflowText.Remove($queryStep.Index, $queryStep.Length)
    if ((Test-ContainsAnySecretReference -Text $outsideQueryStep) -or
        $outsideQueryStep -match '(?m)^\s*CF_API_KEY:') {
        throw "CurseForge diagnostics secret must be scoped to its query step."
    }
    $expectedWorkflow = @'
name: CurseForge diagnostics

on:
  workflow_dispatch:
    inputs:
      version:
        description: Version label to search for, such as vX.Y.Z
        required: true

permissions:
  contents: read

jobs:
  files:
    if: ${{ github.ref == 'refs/heads/main' }}
    environment: marketplace-manual
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10
        with:
          ref: ${{ github.sha }}
          fetch-depth: 0
          persist-credentials: false

      - name: Verify anonymous checkout boundary
        shell: pwsh
        run: ./scripts/check-anonymous-checkout.ps1

      - name: Query CurseForge legacy API
        shell: pwsh
        env:
          CF_API_KEY: ${{ secrets.CF_API_KEY }}
          STATSPRO_CF_PROJECT_ID: "1525100"
          STATSPRO_VERSION: ${{ inputs.version }}
        run: ./scripts/check-curseforge-diagnostics.ps1
'@
    Assert-ExactWorkflowBlock `
        -Actual $WorkflowText `
        -Expected $expectedWorkflow `
        -Description "CurseForge diagnostics workflow"
}

function Assert-ReleaseEventBoundary {
    param([string]$WorkflowText)

    if ($WorkflowText -match '(?m)^(?:"[^"\r\n]+"|''[^''\r\n]+''|<<|\?[^:\r\n]*):' -or
        $WorkflowText -match '(?m)^[A-Za-z][A-Za-z0-9_-]*[ \t]+:' -or
        $WorkflowText -match '(?m)^(?:\?\s+|:\s+)') {
        throw "Release workflow must use plain canonical top-level mapping keys."
    }
    Assert-ExactWorkflowKeySet `
        -Text $WorkflowText `
        -Indent 0 `
        -ExpectedKeys @('name', 'on', 'concurrency', 'jobs') `
        -Description "Release workflow"

    $triggerBlock = [regex]::Match($WorkflowText, '(?ms)^on:\s*$.*?(?=^concurrency:\s*$)')
    $normalizedTrigger = if ($triggerBlock.Success) {
        $withoutComments = $triggerBlock.Value -replace '(?m)^\s*#.*(?:\r?\n|$)', ''
        (($withoutComments -replace '(?m)^\s*$\r?\n', '') -replace "`r", '').Trim()
    }
    else {
        ''
    }
    $expectedTrigger = "on:`n  push:`n    tags:`n      - 'v*'"
    if (-not [System.StringComparer]::Ordinal.Equals($normalizedTrigger, $expectedTrigger)) {
        throw "Release workflow must keep the exact tag-only push trigger."
    }

    $expectedGuard = '${{ github.event.created == true && github.event.forced == false && github.event.deleted == false }}'
    foreach ($jobName in @('preflight', 'package', 'github-prepare', 'marketplace-upload', 'github-finalize', 'verify')) {
        $jobBlock = Get-WorkflowJobBlock -WorkflowText $WorkflowText -JobName $jobName
        $guardLines = @([regex]::Matches($jobBlock.Value, '(?m)^    if:\s*(.*?)\s*$'))
        if ($guardLines.Count -ne 1 -or
            -not [System.StringComparer]::Ordinal.Equals($guardLines[0].Groups[1].Value, $expectedGuard)) {
            throw "Release job '$jobName' must keep the exact first-created, non-forced, non-deleted event guard."
        }
    }
}

function Assert-ReleaseWorkflowBoundary {
    param([string]$WorkflowText)

    Assert-ReleaseEventBoundary -WorkflowText $WorkflowText

    if ($WorkflowText -match '(?m)^\s*(?:"(?:uses|permissions|environment|needs)"|''(?:uses|permissions|environment|needs)''|(?:uses|permissions|environment|needs)\s+):' -or
        $WorkflowText -match '(?m)^\s*(?:<<|\?\s+|:\s+)') {
        throw "Release workflow must use canonical plain mapping keys without aliases."
    }
    if ($WorkflowText -match '(?m)^        (?:if|continue-on-error):') {
        throw "Every release step must be named, mandatory, and fail closed."
    }

    $concurrencyBlock = [regex]::Match($WorkflowText, '(?ms)^concurrency:\s*$.*?(?=^jobs:\s*$)')
    if (-not $concurrencyBlock.Success -or
        $concurrencyBlock.Value -notmatch '(?m)^  group: statspro-release-publication\s*$' -or
        $concurrencyBlock.Value -notmatch '(?m)^  queue: max\s*$' -or
        $concurrencyBlock.Value -match '(?m)^\s+cancel-in-progress:') {
        throw "Release workflow must use the shared non-cancelling queue with queue: max."
    }

    $jobsBlock = [regex]::Match($WorkflowText, '(?ms)^jobs:\s*$.*\z')
    $jobNames = @(
        [regex]::Matches($jobsBlock.Value, '(?m)^  ([a-z][a-z0-9-]*):\s*$') |
            ForEach-Object { $_.Groups[1].Value }
    )
    $expectedJobNames = @('preflight', 'package', 'github-prepare', 'marketplace-upload', 'github-finalize', 'verify')
    if ($jobNames.Count -ne $expectedJobNames.Count -or
        (Compare-Object -ReferenceObject ($expectedJobNames | Sort-Object) -DifferenceObject ($jobNames | Sort-Object))) {
        throw "Release workflow job inventory must be exactly '$($expectedJobNames -join ', ')'."
    }

    Assert-WorkflowCheckoutCredentialBoundary -WorkflowText $WorkflowText -JobNames $expectedJobNames

    $jobs = @{}
    foreach ($jobName in $expectedJobNames) {
        $jobs[$jobName] = Get-WorkflowJobBlock -WorkflowText $WorkflowText -JobName $jobName
        if ($jobs[$jobName].Value -match '(?m)^      - (?!name:)') {
            throw "Every release step must be named, mandatory, and fail closed."
        }
    }

    $expectedJobKeys = @{
        preflight = @('if', 'runs-on', 'timeout-minutes', 'permissions', 'steps')
        package = @('needs', 'if', 'runs-on', 'timeout-minutes', 'permissions', 'outputs', 'steps')
        'github-prepare' = @('needs', 'if', 'runs-on', 'timeout-minutes', 'permissions', 'steps')
        'marketplace-upload' = @('needs', 'environment', 'if', 'runs-on', 'timeout-minutes', 'permissions', 'steps')
        'github-finalize' = @('needs', 'if', 'runs-on', 'timeout-minutes', 'permissions', 'steps')
        verify = @('needs', 'if', 'runs-on', 'timeout-minutes', 'permissions', 'steps')
    }
    foreach ($jobName in $expectedJobNames) {
        Assert-ExactWorkflowKeySet -Text $jobs[$jobName].Value -Indent 4 -ExpectedKeys $expectedJobKeys[$jobName] -Description "Release job '$jobName'"
    }

    $timeoutContract = @{
        preflight = 30
        package = 30
        'github-prepare' = 30
        'marketplace-upload' = 45
        'github-finalize' = 30
        verify = 30
    }
    foreach ($jobName in $expectedJobNames) {
        $timeoutLines = @([regex]::Matches($jobs[$jobName].Value, '(?m)^    timeout-minutes:\s*([1-9][0-9]*)\s*$'))
        if ($timeoutLines.Count -ne 1 -or [int]$timeoutLines[0].Groups[1].Value -ne $timeoutContract[$jobName]) {
            throw "Release job '$jobName' must keep timeout-minutes: $($timeoutContract[$jobName])."
        }
    }

    $permissionContract = @{
        preflight = 'read'
        package = 'read'
        'github-prepare' = 'write'
        'marketplace-upload' = 'write'
        'github-finalize' = 'write'
        verify = 'read'
    }
    foreach ($jobName in $expectedJobNames) {
        $permissionBlocks = @([regex]::Matches($jobs[$jobName].Value, '(?m)^    permissions:\s*\r?\n      contents:\s*(read|write)\s*$'))
        if ($permissionBlocks.Count -ne 1 -or
            -not [System.StringComparer]::Ordinal.Equals($permissionBlocks[0].Groups[1].Value, $permissionContract[$jobName])) {
            throw "Release job '$jobName' must have exactly contents: $($permissionContract[$jobName])."
        }
    }

    $needsContract = @{
        package = 'preflight'
        'github-prepare' = 'package'
        'marketplace-upload' = '[package, github-prepare]'
        'github-finalize' = '[package, marketplace-upload]'
        verify = 'github-finalize'
    }
    foreach ($jobName in $needsContract.Keys) {
        $needsLines = @([regex]::Matches($jobs[$jobName].Value, '(?m)^    needs:\s*(.*?)\s*$'))
        if ($needsLines.Count -ne 1 -or
            -not [System.StringComparer]::Ordinal.Equals($needsLines[0].Groups[1].Value, $needsContract[$jobName])) {
            throw "Release job '$jobName' has the wrong dependency boundary."
        }
    }

    foreach ($jobName in $expectedJobNames) {
        $environmentLines = @([regex]::Matches($jobs[$jobName].Value, '(?m)^    environment:\s*(.*?)\s*$'))
        $expectsEnvironment = $jobName -eq 'marketplace-upload'
        if ($expectsEnvironment) {
            if ($environmentLines.Count -ne 1 -or $environmentLines[0].Groups[1].Value -ne 'marketplace-release') {
                throw "Release job '$jobName' must bind exactly environment marketplace-release."
            }
        }
        elseif ($environmentLines.Count -ne 0) {
            throw "Release job '$jobName' must not bind a credential environment."
        }
    }

    $actionContract = @{
        preflight = @('actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10')
        package = @(
            'actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10',
            'BigWigsMods/packager@6d50adb6e8517eefef63f4afb16a6518166a6b28',
            'BigWigsMods/packager@6d50adb6e8517eefef63f4afb16a6518166a6b28',
            'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
        )
        'github-prepare' = @(
            'actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10',
            'actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c'
        )
        'marketplace-upload' = @(
            'actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10',
            'actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c'
        )
        'github-finalize' = @(
            'actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10',
            'actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c'
        )
        verify = @('actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10')
    }
    foreach ($jobName in $expectedJobNames) {
        $actualActions = @([regex]::Matches($jobs[$jobName].Value, '(?m)^\s{8}uses:\s*(\S+)\s*$') | ForEach-Object { $_.Groups[1].Value })
        $expectedActions = $actionContract[$jobName]
        if ($actualActions.Count -ne $expectedActions.Count) {
            throw "Release job '$jobName' has the wrong action count."
        }
        for ($index = 0; $index -lt $expectedActions.Count; $index++) {
            if (-not [System.StringComparer]::Ordinal.Equals($actualActions[$index], $expectedActions[$index])) {
                throw "Release job '$jobName' action '$($actualActions[$index])' is outside its exact allowlist."
            }
        }
    }

    $allSteps = @()
    foreach ($jobName in $expectedJobNames) {
        foreach ($step in @([regex]::Matches($jobs[$jobName].Value, '(?ms)^\s{6}- name: .+?\s*$.*?(?=^\s{6}- name:|\z)'))) {
            $allSteps += [pscustomobject]@{ Job = $jobName; Name = Get-WorkflowStepName -StepBlock $step; Block = $step }
        }
    }
    $getStep = {
        param([string]$Job, [string]$Name)
        $matches = @($allSteps | Where-Object { $_.Job -eq $Job -and $_.Name -eq $Name })
        if ($matches.Count -ne 1) {
            throw "Release workflow must contain exactly one '$Name' step in '$Job'."
        }
        return $matches[0]
    }

    $stepInventory = [ordered]@{
        preflight = @(
            'Checkout',
            'Verify anonymous checkout boundary',
            'Check CI action refs',
            'Check release ancestry',
            'Check release version',
            'Lua checks',
            'Trim release changelog',
            'Validate interrupted release state'
        )
        package = @(
            'Checkout',
            'Verify anonymous checkout boundary',
            'Trim release changelog',
            'Install release validation tools',
            'Build package without publishing',
            'Resolve initial package output',
            'Validate initial package artifact',
            'Recheck release ancestry before final package build',
            'Rebuild package without publishing',
            'Resolve final package output',
            'Compare and validate final package artifact',
            'Create and validate release metadata',
            'Create exact release candidate',
            'Upload exact release candidate'
        )
        'github-prepare' = @(
            'Checkout',
            'Verify anonymous checkout boundary',
            'Download exact release candidate',
            'Verify exact release candidate',
            'Prepare resumable draft release'
        )
        'marketplace-upload' = @(
            'Checkout',
            'Verify anonymous checkout boundary',
            'Download exact release candidate',
            'Verify exact release candidate',
            'Require fresh package attempt before marketplace publication',
            'Verify immutable release policy',
            'Prepare exact marketplace publication plan',
            'Mark marketplace publication started',
            'Publish exact archive to marketplaces'
        )
        'github-finalize' = @(
            'Checkout',
            'Verify anonymous checkout boundary',
            'Download exact release candidate',
            'Verify exact release candidate',
            'Attach validated assets to draft',
            'Publish immutable GitHub release'
        )
        verify = @(
            'Checkout',
            'Verify anonymous checkout boundary',
            'Install release validation tools',
            'Validate published immutable release assets'
        )
    }
    foreach ($jobName in $stepInventory.Keys) {
        $actualNames = @($allSteps | Where-Object { $_.Job -eq $jobName } | ForEach-Object Name)
        $expectedNames = @($stepInventory[$jobName])
        if ($actualNames.Count -ne $expectedNames.Count -or
            -not [System.StringComparer]::Ordinal.Equals(($actualNames -join "`n"), ($expectedNames -join "`n"))) {
            throw "Release job '$jobName' step inventory must remain exact and ordered."
        }
    }

    $expectedCheckoutStep = @'
      - name: Checkout
        uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10
        with:
          fetch-depth: 0
          persist-credentials: false
'@
    $expectedAnonymousStep = @'
      - name: Verify anonymous checkout boundary
        shell: pwsh
        run: ./scripts/check-anonymous-checkout.ps1
'@
    foreach ($jobName in $expectedJobNames) {
        Assert-ExactWorkflowBlock `
            -Actual (& $getStep $jobName 'Checkout').Block.Value `
            -Expected $expectedCheckoutStep `
            -Description "Release job '$jobName' checkout step"
        Assert-ExactWorkflowBlock `
            -Actual (& $getStep $jobName 'Verify anonymous checkout boundary').Block.Value `
            -Expected $expectedAnonymousStep `
            -Description "Release job '$jobName' anonymous checkout step"
    }
    $expectedConsumerVerifySteps = [ordered]@{
        'github-prepare' = @'
      - name: Verify exact release candidate
        id: verify-candidate
        shell: pwsh
        run: |
          ./scripts/release-candidate.ps1 `
            -Mode Verify `
            -Repository $env:GITHUB_REPOSITORY `
            -ExpectedTag $env:GITHUB_REF_NAME `
            -ExpectedCommitSha $env:GITHUB_SHA `
            -ExpectedRunId $env:GITHUB_RUN_ID `
            -ExpectedRunAttempt '${{ needs.package.outputs.run_attempt }}' `
            -ExpectedProjectVersion '${{ needs.package.outputs.project_version }}' `
            -CandidatePath (Join-Path ".release" "handoff" "statspro-release-candidate.json") `
            -ExpectedCandidateSha256 '${{ needs.package.outputs.candidate_sha256 }}' `
            -OutputPath $env:GITHUB_OUTPUT
'@
        'marketplace-upload' = @'
      - name: Verify exact release candidate
        id: verify-candidate
        shell: pwsh
        run: |
          ./scripts/release-candidate.ps1 `
            -Mode Verify `
            -Repository $env:GITHUB_REPOSITORY `
            -ExpectedTag $env:GITHUB_REF_NAME `
            -ExpectedCommitSha $env:GITHUB_SHA `
            -ExpectedRunId $env:GITHUB_RUN_ID `
            -ExpectedRunAttempt '${{ needs.package.outputs.run_attempt }}' `
            -ExpectedProjectVersion '${{ needs.package.outputs.project_version }}' `
            -CandidatePath (Join-Path ".release" "handoff" "statspro-release-candidate.json") `
            -ExpectedCandidateSha256 '${{ needs.package.outputs.candidate_sha256 }}' `
            -ArchonMaxAgeDays 3 `
            -OutputPath $env:GITHUB_OUTPUT
'@
        'github-finalize' = @'
      - name: Verify exact release candidate
        id: verify-candidate
        shell: pwsh
        run: |
          ./scripts/release-candidate.ps1 `
            -Mode Verify `
            -Repository $env:GITHUB_REPOSITORY `
            -ExpectedTag $env:GITHUB_REF_NAME `
            -ExpectedCommitSha $env:GITHUB_SHA `
            -ExpectedRunId $env:GITHUB_RUN_ID `
            -ExpectedRunAttempt '${{ needs.package.outputs.run_attempt }}' `
            -ExpectedProjectVersion '${{ needs.package.outputs.project_version }}' `
            -CandidatePath (Join-Path ".release" "handoff" "statspro-release-candidate.json") `
            -ExpectedCandidateSha256 '${{ needs.package.outputs.candidate_sha256 }}' `
            -OutputPath $env:GITHUB_OUTPUT
'@
    }
    foreach ($jobName in $expectedConsumerVerifySteps.Keys) {
        Assert-ExactWorkflowBlock `
            -Actual (& $getStep $jobName 'Verify exact release candidate').Block.Value `
            -Expected $expectedConsumerVerifySteps[$jobName] `
            -Description "Release candidate verification step '$jobName'"
    }
    $expectedFreshAttemptStep = @'
      - name: Require fresh package attempt before marketplace publication
        shell: pwsh
        env:
          STATSPRO_PACKAGE_RUN_ATTEMPT: ${{ needs.package.outputs.run_attempt }}
        run: |
          if ($env:GITHUB_RUN_ATTEMPT -cne $env:STATSPRO_PACKAGE_RUN_ATTEMPT) {
            throw "Marketplace publication cannot reuse a package from an earlier run attempt. Re-run all jobs to create a fresh candidate."
          }
'@
    Assert-ExactWorkflowBlock `
        -Actual (& $getStep 'marketplace-upload' 'Require fresh package attempt before marketplace publication').Block.Value `
        -Expected $expectedFreshAttemptStep `
        -Description 'Marketplace fresh-attempt guard step'

    $approvedSecrets = @{
        GITHUB_TOKEN = @(
            'preflight/Check release version',
            'preflight/Validate interrupted release state',
            'github-prepare/Prepare resumable draft release',
            'marketplace-upload/Mark marketplace publication started',
            'github-finalize/Attach validated assets to draft',
            'github-finalize/Publish immutable GitHub release',
            'verify/Validate published immutable release assets'
        )
        IMMUTABLE_RELEASES_READ_TOKEN = @('marketplace-upload/Verify immutable release policy')
        CF_API_KEY = @('marketplace-upload/Prepare exact marketplace publication plan', 'marketplace-upload/Publish exact archive to marketplaces')
        WAGO_API_TOKEN = @('marketplace-upload/Prepare exact marketplace publication plan', 'marketplace-upload/Publish exact archive to marketplaces')
        WOWI_API_TOKEN = @('marketplace-upload/Prepare exact marketplace publication plan', 'marketplace-upload/Publish exact archive to marketplaces')
    }
    $withoutApprovedSecrets = $WorkflowText
    foreach ($secretName in $approvedSecrets.Keys) {
        $pattern = '\$\{\{\s*secrets\.' + [regex]::Escape($secretName) + '\s*\}\}'
        $matches = @([regex]::Matches($WorkflowText, $pattern))
        if ($matches.Count -ne $approvedSecrets[$secretName].Count) {
            throw "Release secret '$secretName' must appear only in its exact approved steps."
        }
        foreach ($approvedLocation in $approvedSecrets[$secretName]) {
            $parts = $approvedLocation.Split('/', 2)
            $step = & $getStep $parts[0] $parts[1]
            if (@([regex]::Matches($step.Block.Value, $pattern)).Count -ne 1) {
                throw "Release secret '$secretName' is missing from '$approvedLocation'."
            }
        }
        $withoutApprovedSecrets = [regex]::Replace($withoutApprovedSecrets, $pattern, '')
    }
    if ((Test-ContainsAnySecretReference -Text $withoutApprovedSecrets) -or
        (Test-ContainsGitHubTokenReference -Text $withoutApprovedSecrets)) {
        throw "Release workflow contains an unapproved or non-canonical secret or github.token reference."
    }

    $sensitiveStepContracts = @(
        [pscustomobject]@{ Job = 'preflight'; Name = 'Check release version'; Block = @'
      - name: Check release version
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        shell: pwsh
        run: .\scripts\check-release-version.ps1 -Tag $env:GITHUB_REF_NAME -EnforceSemVer -VerifyPublishedChangelog -Repository $env:GITHUB_REPOSITORY
'@ },
        [pscustomobject]@{ Job = 'preflight'; Name = 'Validate interrupted release state'; Block = @'
      - name: Validate interrupted release state
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        shell: pwsh
        run: |
          .\scripts\manage-github-release.ps1 `
            -Mode ValidateStart `
            -Repository $env:GITHUB_REPOSITORY `
            -ExpectedTag $env:GITHUB_REF_NAME `
            -ExpectedCommitSha $env:GITHUB_SHA `
            -NotesPath CHANGELOG.md
'@ },
        [pscustomobject]@{ Job = 'github-prepare'; Name = 'Prepare resumable draft release'; Block = @'
      - name: Prepare resumable draft release
        shell: pwsh
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          ./scripts/manage-github-release.ps1 `
            -Mode CreateDraft `
            -Repository $env:GITHUB_REPOSITORY `
            -ExpectedTag $env:GITHUB_REF_NAME `
            -ExpectedCommitSha $env:GITHUB_SHA `
            -ExpectedRunId $env:GITHUB_RUN_ID `
            -ExpectedRunAttempt '${{ needs.package.outputs.run_attempt }}' `
            -ExpectedArchiveSha256 '${{ needs.package.outputs.archive_sha256 }}' `
            -ExpectedCandidateSha256 '${{ needs.package.outputs.candidate_sha256 }}' `
            -NotesPath '${{ steps.verify-candidate.outputs.notes_path }}' `
            -ManifestPath '${{ steps.verify-candidate.outputs.manifest_path }}'
'@ },
        [pscustomobject]@{ Job = 'marketplace-upload'; Name = 'Verify immutable release policy'; Block = @'
      - name: Verify immutable release policy
        env:
          GH_TOKEN: ${{ secrets.IMMUTABLE_RELEASES_READ_TOKEN }}
        shell: pwsh
        run: ./scripts/check-repository-settings.ps1 -Repository $env:GITHUB_REPOSITORY -ImmutableReleasePolicyOnly -RequireExplicitToken
'@ },
        [pscustomobject]@{ Job = 'marketplace-upload'; Name = 'Prepare exact marketplace publication plan'; Block = @'
      - name: Prepare exact marketplace publication plan
        id: prepare-marketplace
        shell: pwsh
        env:
          CF_API_KEY: ${{ secrets.CF_API_KEY }}
          WAGO_API_TOKEN: ${{ secrets.WAGO_API_TOKEN }}
          WOWI_API_TOKEN: ${{ secrets.WOWI_API_TOKEN }}
        run: |
          ./scripts/publish-marketplaces.ps1 `
            -Mode Prepare `
            -ArchivePath '${{ steps.verify-candidate.outputs.archive_path }}' `
            -ExpectedTag $env:GITHUB_REF_NAME `
            -ExpectedSha256 '${{ needs.package.outputs.archive_sha256 }}' `
            -PlanPath (Join-Path ".release" "handoff" "statspro-marketplace-plan.json") `
            -OutputPath $env:GITHUB_OUTPUT
'@ },
        [pscustomobject]@{ Job = 'marketplace-upload'; Name = 'Mark marketplace publication started'; Block = @'
      - name: Mark marketplace publication started
        shell: pwsh
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          ./scripts/manage-github-release.ps1 `
            -Mode MarkMarketplaceStarted `
            -Repository $env:GITHUB_REPOSITORY `
            -ExpectedTag $env:GITHUB_REF_NAME `
            -ExpectedCommitSha $env:GITHUB_SHA `
            -ExpectedRunId $env:GITHUB_RUN_ID `
            -ExpectedRunAttempt '${{ needs.package.outputs.run_attempt }}' `
            -ExpectedArchiveSha256 '${{ needs.package.outputs.archive_sha256 }}' `
            -ExpectedCandidateSha256 '${{ needs.package.outputs.candidate_sha256 }}' `
            -NotesPath '${{ steps.verify-candidate.outputs.notes_path }}' `
            -ManifestPath '${{ steps.verify-candidate.outputs.manifest_path }}'
'@ },
        [pscustomobject]@{ Job = 'marketplace-upload'; Name = 'Publish exact archive to marketplaces'; Block = @'
      - name: Publish exact archive to marketplaces
        shell: pwsh
        env:
          CF_API_KEY: ${{ secrets.CF_API_KEY }}
          WAGO_API_TOKEN: ${{ secrets.WAGO_API_TOKEN }}
          WOWI_API_TOKEN: ${{ secrets.WOWI_API_TOKEN }}
        run: |
          ./scripts/publish-marketplaces.ps1 `
            -Mode Publish `
            -ArchivePath '${{ steps.verify-candidate.outputs.archive_path }}' `
            -ExpectedTag $env:GITHUB_REF_NAME `
            -ExpectedSha256 '${{ needs.package.outputs.archive_sha256 }}' `
            -PlanPath '${{ steps.prepare-marketplace.outputs.plan_path }}' `
            -ExpectedPlanSha256 '${{ steps.prepare-marketplace.outputs.plan_sha256 }}'
'@ },
        [pscustomobject]@{ Job = 'github-finalize'; Name = 'Attach validated assets to draft'; Block = @'
      - name: Attach validated assets to draft
        shell: pwsh
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          ./scripts/manage-github-release.ps1 `
            -Mode AttachAssets `
            -Repository $env:GITHUB_REPOSITORY `
            -ExpectedTag $env:GITHUB_REF_NAME `
            -ExpectedCommitSha $env:GITHUB_SHA `
            -ExpectedRunId $env:GITHUB_RUN_ID `
            -ExpectedRunAttempt '${{ needs.package.outputs.run_attempt }}' `
            -ExpectedArchiveSha256 '${{ needs.package.outputs.archive_sha256 }}' `
            -ExpectedCandidateSha256 '${{ needs.package.outputs.candidate_sha256 }}' `
            -ArchivePath '${{ steps.verify-candidate.outputs.archive_path }}' `
            -ReleaseJsonPath '${{ steps.verify-candidate.outputs.release_json_path }}' `
            -NotesPath '${{ steps.verify-candidate.outputs.notes_path }}' `
            -ManifestPath '${{ steps.verify-candidate.outputs.manifest_path }}'
'@ },
        [pscustomobject]@{ Job = 'github-finalize'; Name = 'Publish immutable GitHub release'; Block = @'
      - name: Publish immutable GitHub release
        shell: pwsh
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          ./scripts/manage-github-release.ps1 `
            -Mode Publish `
            -Repository $env:GITHUB_REPOSITORY `
            -ExpectedTag $env:GITHUB_REF_NAME `
            -ExpectedCommitSha $env:GITHUB_SHA `
            -ExpectedRunId $env:GITHUB_RUN_ID `
            -ExpectedRunAttempt '${{ needs.package.outputs.run_attempt }}' `
            -ExpectedArchiveSha256 '${{ needs.package.outputs.archive_sha256 }}' `
            -ExpectedCandidateSha256 '${{ needs.package.outputs.candidate_sha256 }}' `
            -ArchivePath '${{ steps.verify-candidate.outputs.archive_path }}' `
            -ReleaseJsonPath '${{ steps.verify-candidate.outputs.release_json_path }}' `
            -NotesPath '${{ steps.verify-candidate.outputs.notes_path }}' `
            -ManifestPath '${{ steps.verify-candidate.outputs.manifest_path }}'
'@ },
        [pscustomobject]@{ Job = 'verify'; Name = 'Validate published immutable release assets'; Block = @'
      - name: Validate published immutable release assets
        shell: pwsh
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          $tag = $env:GITHUB_REF_NAME
          $assetDir = Join-Path $env:RUNNER_TEMP "statspro-release-assets"
          New-Item -ItemType Directory -Path $assetDir -Force | Out-Null

          function Save-ReleaseAsset {
            param([string]$Name)

            $path = Join-Path $assetDir $Name
            for ($attempt = 1; $attempt -le 6; $attempt++) {
              $output = @(gh release download $tag --repo $env:GITHUB_REPOSITORY --pattern $Name --dir $assetDir --clobber 2>&1)
              if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                return $path
              }
              Write-Host "Release asset $Name not ready on attempt $attempt`: $($output -join ' ')"
              if ($attempt -lt 6) {
                Start-Sleep -Seconds ([Math]::Min(60, 5 * [Math]::Pow(2, $attempt - 1)))
              }
            }
            throw "Release asset $Name was not downloadable after retries."
          }

          $zipPath = Save-ReleaseAsset -Name "StatsPro-$tag.zip"
          $releaseJsonPath = Save-ReleaseAsset -Name "release.json"
          ./scripts/check-release-artifact.ps1 `
            -ZipPath $zipPath `
            -ReleaseJsonPath $releaseJsonPath `
            -ExpectedTag $tag `
            -PackagerProjectVersion $tag `
            -RequireExactPackagerProjectVersion `
            -WithReleaseJson `
            -ArchonMaxAgeDays 3 `
            -EnforceToolLocks
'@ }
    )
    foreach ($contract in $sensitiveStepContracts) {
        Assert-ExactWorkflowBlock `
            -Actual (& $getStep $contract.Job $contract.Name).Block.Value `
            -Expected $contract.Block `
            -Description "Release sensitive step '$($contract.Job)/$($contract.Name)'"
    }

    $packageJob = $jobs['package'].Value
    if ($packageJob -match '(?i)secrets|github\.token|GITHUB_TOKEN' -or
        @([regex]::Matches($packageJob, '(?m)^\s{10}args:\s*-d\s*$')).Count -ne 1 -or
        @([regex]::Matches($packageJob, '(?m)^\s{10}args:\s*-e -d\s*$')).Count -ne 1 -or
        $packageJob -match '(?m)^\s{10}args:.*(?:^|\s)-(?:c|o)(?:\s|$)') {
        throw "The package job must be secret-free and use exactly two non-publishing Packager runs."
    }

    $candidateCreate = & $getStep 'package' 'Create exact release candidate'
    $artifactUpload = & $getStep 'package' 'Upload exact release candidate'
    if ($candidateCreate.Block.Value -notmatch '(?m)^\s+id:\s*create-candidate\s*$' -or
        $candidateCreate.Block.Value -notmatch '(?m)^\s+-Mode Create\s*' -or
        $candidateCreate.Block.Value -notmatch '-ExpectedRunAttempt \$env:GITHUB_RUN_ATTEMPT' -or
        $candidateCreate.Block.Value -notmatch '-ExpectedProjectVersion \$env:STATSPRO_PROJECT_VERSION' -or
        $candidateCreate.Block.Index -ge $artifactUpload.Block.Index) {
        throw "Release candidate creation must validate and bind the final package before artifact upload."
    }
    foreach ($requiredUploadPattern in @(
        '(?m)^\s{8}id:\s*upload-candidate\s*$',
        '(?m)^\s{10}name:\s*statspro-release-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}\s*$',
        '(?m)^\s{10}if-no-files-found:\s*error\s*$',
        '(?m)^\s{10}compression-level:\s*0\s*$',
        '(?m)^\s{10}overwrite:\s*false\s*$',
        '(?m)^\s{10}include-hidden-files:\s*true\s*$',
        '(?m)^\s{10}retention-days:\s*35\s*$'
    )) {
        if ($artifactUpload.Block.Value -notmatch $requiredUploadPattern) {
            throw "Release artifact upload is missing an exact immutable handoff setting."
        }
    }
    foreach ($outputName in @('archive_path', 'release_json_path', 'manifest_path', 'candidate_path')) {
        if (@([regex]::Matches($artifactUpload.Block.Value, [regex]::Escape("steps.create-candidate.outputs.$outputName"))).Count -ne 1) {
            throw "Release artifact upload must include exact candidate output '$outputName'."
        }
    }
    $packageOutputs = [regex]::Match($packageJob, '(?ms)^    outputs:\s*$.*?(?=^    steps:\s*$)')
    foreach ($outputPattern in @(
        'artifact_id:\s*\$\{\{ steps\.upload-candidate\.outputs\.artifact-id \}\}',
        'archive_sha256:\s*\$\{\{ steps\.create-candidate\.outputs\.archive_sha256 \}\}',
        'candidate_sha256:\s*\$\{\{ steps\.create-candidate\.outputs\.candidate_sha256 \}\}',
        'project_version:\s*\$\{\{ steps\.rebuild-package-output\.outputs\.project_version \}\}',
        'run_attempt:\s*\$\{\{ github\.run_attempt \}\}'
    )) {
        if (-not $packageOutputs.Success -or $packageOutputs.Value -notmatch $outputPattern) {
            throw "Release package outputs must bind artifact identity and inner candidate hashes."
        }
    }

    foreach ($consumerJob in @('github-prepare', 'marketplace-upload', 'github-finalize')) {
        $download = & $getStep $consumerJob 'Download exact release candidate'
        if ($download.Block.Value -notmatch '(?m)^\s{10}artifact-ids:\s*\$\{\{ needs\.package\.outputs\.artifact_id \}\}\s*$' -or
            $download.Block.Value -notmatch '(?m)^\s{10}path:\s*\.release/handoff\s*$' -or
            $download.Block.Value -notmatch '(?m)^\s{10}digest-mismatch:\s*error\s*$' -or
            $download.Block.Value -match '(?m)^\s{10}(?:name|pattern|merge-multiple|github-token|repository|run-id):') {
            throw "Release consumer '$consumerJob' must download the exact current-run artifact ID and fail on digest mismatch."
        }
        $verifyCandidate = & $getStep $consumerJob 'Verify exact release candidate'
        if ($verifyCandidate.Block.Value -notmatch '(?m)^\s+-Mode Verify\s*' -or
            $verifyCandidate.Block.Value -notmatch '-ExpectedCandidateSha256 ''\$\{\{ needs\.package\.outputs\.candidate_sha256 \}\}''' -or
            $verifyCandidate.Block.Value -notmatch '-ExpectedProjectVersion ''\$\{\{ needs\.package\.outputs\.project_version \}\}''' -or
            $verifyCandidate.Block.Value -notmatch '-ExpectedRunAttempt ''\$\{\{ needs\.package\.outputs\.run_attempt \}\}''' -or
            $download.Block.Index -ge $verifyCandidate.Block.Index) {
            throw "Release consumer '$consumerJob' must verify the exact candidate before using it."
        }
    }

    $prepareCandidate = & $getStep 'github-prepare' 'Verify exact release candidate'
    $prepareDraft = & $getStep 'github-prepare' 'Prepare resumable draft release'
    if ($prepareCandidate.Block.Index -ge $prepareDraft.Block.Index -or
        $prepareDraft.Block.Value -notmatch '-Mode CreateDraft') {
        throw "GitHub preparation must verify and prepare the exact candidate in order."
    }

    $marketplaceVerify = & $getStep 'marketplace-upload' 'Verify exact release candidate'
    $freshAttempt = & $getStep 'marketplace-upload' 'Require fresh package attempt before marketplace publication'
    $immutablePolicy = & $getStep 'marketplace-upload' 'Verify immutable release policy'
    $credentialCheck = & $getStep 'marketplace-upload' 'Prepare exact marketplace publication plan'
    $markStarted = & $getStep 'marketplace-upload' 'Mark marketplace publication started'
    $marketplacePublish = & $getStep 'marketplace-upload' 'Publish exact archive to marketplaces'
    if (-not ($marketplaceVerify.Block.Index -lt $freshAttempt.Block.Index -and
        $freshAttempt.Block.Index -lt $immutablePolicy.Block.Index -and
        $immutablePolicy.Block.Index -lt $credentialCheck.Block.Index -and
        $credentialCheck.Block.Index -lt $markStarted.Block.Index -and
        $markStarted.Block.Index -lt $marketplacePublish.Block.Index) -or
        $markStarted.Block.Value -notmatch '-Mode MarkMarketplaceStarted' -or
        $credentialCheck.Block.Value -notmatch '-Mode Prepare' -or
        $marketplacePublish.Block.Value -notmatch '(?m)^\s+\./scripts/publish-marketplaces\.ps1\s+\x60\s*$' -or
        $marketplacePublish.Block.Value -notmatch '-Mode Publish' -or
        $marketplacePublish.Block.Value -notmatch '-ArchivePath ''\$\{\{ steps\.verify-candidate\.outputs\.archive_path \}\}''' -or
        $marketplacePublish.Block.Value -notmatch '-ExpectedSha256 ''\$\{\{ needs\.package\.outputs\.archive_sha256 \}\}''' -or
        $marketplacePublish.Block.Value -notmatch '-PlanPath ''\$\{\{ steps\.prepare-marketplace\.outputs\.plan_path \}\}''' -or
        $marketplacePublish.Block.Value -notmatch '-ExpectedPlanSha256 ''\$\{\{ steps\.prepare-marketplace\.outputs\.plan_sha256 \}\}''') {
        throw "Marketplace publication must upload only the already verified exact archive."
    }

    $finalizeVerify = & $getStep 'github-finalize' 'Verify exact release candidate'
    $attach = & $getStep 'github-finalize' 'Attach validated assets to draft'
    $publish = & $getStep 'github-finalize' 'Publish immutable GitHub release'
    if (-not ($finalizeVerify.Block.Index -lt $attach.Block.Index -and $attach.Block.Index -lt $publish.Block.Index) -or
        $attach.Block.Value -notmatch '-Mode AttachAssets' -or $publish.Block.Value -notmatch '-Mode Publish') {
        throw "GitHub finalization must verify, attach, and publish the exact candidate in order."
    }

    foreach ($managementStep in @($prepareDraft, $markStarted, $attach, $publish)) {
        foreach ($binding in @(
            '-ExpectedRunId \$env:GITHUB_RUN_ID',
            '-ExpectedRunAttempt ''\$\{\{ needs\.package\.outputs\.run_attempt \}\}''',
            '-ExpectedArchiveSha256 ''\$\{\{ needs\.package\.outputs\.archive_sha256 \}\}''',
            '-ExpectedCandidateSha256 ''\$\{\{ needs\.package\.outputs\.candidate_sha256 \}\}'''
        )) {
            if ($managementStep.Block.Value -notmatch $binding) {
                throw "GitHub release mutation '$($managementStep.Name)' is missing exact candidate identity '$binding'."
            }
        }
    }

    if ($immutablePolicy.Block.Value -notmatch '(?m)^\s{8}run:\s*\./scripts/check-repository-settings\.ps1 -Repository \$env:GITHUB_REPOSITORY -ImmutableReleasePolicyOnly -RequireExplicitToken\s*$') {
        throw "Marketplace publication must run the exact immutable-policy checker before planning or upload."
    }
}
function Get-CreateDraftGhArguments {
    param([string]$Repository, [string]$ExpectedTag, [string]$NotesPath)
    return @(
        "release", "create", $ExpectedTag,
        "--repo", $Repository,
        "--draft",
        "--verify-tag",
        "--title", $ExpectedTag,
        "--notes-file", $NotesPath
    )
}

function Get-EditDraftBodyGhArguments {
    param([string]$Repository, [string]$ExpectedTag, [string]$NotesPath)
    return @("release", "edit", $ExpectedTag, "--repo", $Repository, "--notes-file", $NotesPath)
}

function Get-AttachAssetsGhArguments {
    param([string]$Repository, [string]$ExpectedTag, [string]$AssetPath)
    return @(
        "release", "upload", $ExpectedTag,
        $AssetPath,
        "--repo", $Repository
    )
}

function Get-PublishGhArguments {
    param([string]$Repository, [string]$ExpectedTag)
    return @("release", "edit", $ExpectedTag, "--repo", $Repository, "--draft=false", "--latest")
}

function Get-RetirePreparedGhArguments {
    param([string]$Repository, [string]$ExpectedTag)
    return @("release", "delete", $ExpectedTag, "--repo", $Repository, "--yes")
}

function Invoke-WithTemporaryReleaseBody {
    param(
        [string]$Body,
        [scriptblock]$Action
    )

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-release-body-" + [System.Guid]::NewGuid().ToString('N') + '.md')
    try {
        [System.IO.File]::WriteAllText($path, $Body + "`n", [System.Text.UTF8Encoding]::new($false))
        return & $Action $path
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SelfTest {
    Assert-StatsProReleaseTagContractSelfTest
    Invoke-NativeCaptureSelfTest
    $selfTestDeadline = (Get-Date).AddMinutes(5)
    foreach ($invalidTag in @("v01.2.3", "V1.2.3", ("v1.2.3" + [char]10))) {
        Assert-ThrowsMatch "release manager rejects noncanonical tag '$invalidTag'" {
            Assert-StatsProReleaseTag -Value $invalidTag
        } "Malformed StatsPro release tag"
    }

    $tag = "v1.2.3"
    $commit = "0123456789abcdef0123456789abcdef01234567"
    $draftEmpty = [pscustomobject]@{
        tag_name = $tag
        draft = $true
        prerelease = $false
        immutable = $false
        assets = @()
    }
    $draftReady = [pscustomobject]@{
        tag_name = $tag
        draft = $true
        prerelease = $false
        immutable = $false
        assets = @(
            [pscustomobject]@{ name = "StatsPro-$tag.zip" },
            [pscustomobject]@{ name = "release.json" }
        )
    }
    $published = [pscustomobject]@{
        tag_name = $tag
        draft = $false
        prerelease = $false
        immutable = $true
        assets = $draftReady.assets
    }

    Assert-NoExistingRelease -Release $null -ExpectedTag $tag
    Assert-DraftRelease -Release $draftEmpty -ExpectedTag $tag -ExpectedAssets @()
    Assert-DraftRelease -Release $draftReady -ExpectedTag $tag -ExpectedAssets (Get-ExpectedReleaseAssetNames -ExpectedTag $tag)
    Assert-PublishedImmutableRelease -Release $published -ExpectedTag $tag

    Assert-ThrowsMatch "existing draft marker rejected" {
        Assert-NoExistingRelease -Release $draftEmpty -ExpectedTag $tag
    } "draft marker"
    Assert-ThrowsMatch "existing published release rejected" {
        Assert-NoExistingRelease -Release $published -ExpectedTag $tag
    } "published release"
    Assert-ThrowsMatch "partial draft assets rejected" {
        $partial = [pscustomobject]@{
            tag_name = $tag
            draft = $true
            prerelease = $false
            immutable = $false
            assets = @([pscustomobject]@{ name = "StatsPro-$tag.zip" })
        }
        Assert-DraftRelease -Release $partial -ExpectedTag $tag -ExpectedAssets (Get-ExpectedReleaseAssetNames -ExpectedTag $tag)
    } "expected"
    Assert-ThrowsMatch "mutable published release rejected" {
        $mutable = $published.PSObject.Copy()
        $mutable.immutable = $false
        Assert-PublishedImmutableRelease -Release $mutable -ExpectedTag $tag
    } "not immutable"
    Assert-ThrowsMatch "prerelease rejected" {
        $prerelease = $published.PSObject.Copy()
        $prerelease.prerelease = $true
        Assert-PublishedImmutableRelease -Release $prerelease -ExpectedTag $tag
    } "must not be a prerelease"

    $eventualLookup = [pscustomobject]@{ Count = 0 }
    $eventualWaits = [System.Collections.Generic.List[int]]::new()
    $eventualDraft = Wait-GitHubReleaseState `
        -Repository "owner/repo" `
        -ExpectedTag $tag `
        -Attempts 3 `
        -Deadline $selfTestDeadline `
        -AssertState {
            param([object]$Release)
            Assert-DraftRelease -Release $Release -ExpectedTag $tag -ExpectedAssets @()
        } `
        -GetRelease {
            param([string]$Repository, [string]$ExpectedTag)
            $eventualLookup.Count++
            if ($eventualLookup.Count -eq 1) {
                return $null
            }
            return $draftEmpty
        } `
        -Wait {
            param([int]$Seconds)
            $eventualWaits.Add($Seconds)
        }
    if ($eventualDraft -ne $draftEmpty -or $eventualLookup.Count -ne 2 -or
        $eventualWaits.Count -ne 1 -or $eventualWaits[0] -ne 5) {
        throw "Eventual release visibility retry did not preserve the expected state."
    }
    Assert-ThrowsMatch "release visibility exhaustion rejected" {
        [void](Wait-GitHubReleaseState `
            -Repository "owner/repo" `
            -ExpectedTag $tag `
            -Attempts 2 `
            -Deadline $selfTestDeadline `
            -AssertState {
                param([object]$Release)
                Assert-DraftRelease -Release $Release -ExpectedTag $tag -ExpectedAssets @()
            } `
            -GetRelease { param([string]$Repository, [string]$ExpectedTag) return $null } `
            -Wait { param([int]$Seconds) })
    } "did not converge after 2 attempt"
    $lateStateClock = [pscustomobject]@{ Value = [datetime]"2026-01-01T00:00:00Z" }
    Assert-ThrowsMatch "release state observed after deadline rejected" {
        [void](Wait-GitHubReleaseState `
            -Repository "owner/repo" `
            -ExpectedTag $tag `
            -Attempts 1 `
            -Deadline $lateStateClock.Value.AddSeconds(1) `
            -AssertState { param([object]$Release) Assert-DraftRelease -Release $Release -ExpectedTag $tag -ExpectedAssets @() } `
            -GetRelease {
                param([string]$Repository, [string]$ExpectedTag, [datetime]$Deadline)
                $lateStateClock.Value = $lateStateClock.Value.AddSeconds(2)
                return $draftEmpty
            } `
            -Now { $lateStateClock.Value })
    } "converged after its absolute deadline"
    $boundedWaitClock = [pscustomobject]@{ Value = [datetime]"2026-01-01T00:00:00Z" }
    $boundedWaits = [System.Collections.Generic.List[int]]::new()
    Assert-ThrowsMatch "release retry wait respects remaining deadline" {
        [void](Wait-GitHubReleaseState `
            -Repository "owner/repo" `
            -ExpectedTag $tag `
            -Attempts 2 `
            -Deadline $boundedWaitClock.Value.AddSeconds(3) `
            -AssertState { param([object]$Release) Assert-DraftRelease -Release $Release -ExpectedTag $tag -ExpectedAssets @() } `
            -GetRelease { param([string]$Repository, [string]$ExpectedTag, [datetime]$Deadline) return $null } `
            -Wait {
                param([int]$Seconds)
                $boundedWaits.Add($Seconds)
                $boundedWaitClock.Value = $boundedWaitClock.Value.AddSeconds($Seconds)
            } `
            -Now { $boundedWaitClock.Value })
    } "exceeded its absolute deadline before attempt 2"
    if ($boundedWaits.Count -ne 1 -or $boundedWaits[0] -ne 3) {
        throw "Release retry wait must clamp to the remaining absolute deadline."
    }
    Assert-ThrowsMatch "malformed repository rejected" {
        Assert-RepositoryName "missing-owner"
    } "owner/name"

    $listCalls = [System.Collections.Generic.List[string]]::new()
    $listedDraft = Get-GitHubReleaseByTag -Repository "owner/repo" -ExpectedTag $tag -Deadline $selfTestDeadline -RunGh {
        param([string[]]$Arguments)
        $listCalls.Add(($Arguments -join " ")) | Out-Null
        return @{
            ExitCode = 0
            Output = @('[[{"tag_name":"v1.2.3","draft":true,"prerelease":false,"immutable":false,"assets":[]}],[]]')
        }
    }
    if ($null -eq $listedDraft -or -not $listedDraft.draft) {
        throw "Paginated release lookup must return draft markers."
    }
    if ($listCalls.Count -ne 1 -or $listCalls[0] -notmatch "api --paginate --slurp .*releases\?per_page=100") {
        throw "Release lookup must use the paginated list endpoint so drafts are visible."
    }
    Assert-ThrowsMatch "duplicate release markers rejected" {
        [void](Get-GitHubReleaseByTag -Repository "owner/repo" -ExpectedTag $tag -Deadline $selfTestDeadline -RunGh {
            param([string[]]$Arguments)
            return @{
                ExitCode = 0
                Output = @('[[{"tag_name":"v1.2.3"},{"tag_name":"v1.2.3"}]]')
            }
        })
    } "multiple"

    Assert-RemoteTagCommit -Repository "owner/repo" -ExpectedTag $tag -ExpectedCommitSha $commit -Deadline $selfTestDeadline -ResolveTagCommit {
        param([string]$Repository, [string]$ExpectedTag)
        return $commit
    }
    Assert-ThrowsMatch "moved remote tag rejected" {
        Assert-RemoteTagCommit -Repository "owner/repo" -ExpectedTag $tag -ExpectedCommitSha $commit -Deadline $selfTestDeadline -ResolveTagCommit {
            param([string]$Repository, [string]$ExpectedTag)
            return "fedcba9876543210fedcba9876543210fedcba98"
        }
    } "expected event commit"

    $createArguments = Get-CreateDraftGhArguments -Repository "owner/repo" -ExpectedTag $tag -NotesPath "notes.md"
    if ($createArguments -notcontains "--draft" -or $createArguments -notcontains "--verify-tag" -or $createArguments -contains "--target") {
        throw "CreateDraft gh arguments must create a draft for an existing tag."
    }
    $attachArguments = Get-AttachAssetsGhArguments -Repository "owner/repo" -ExpectedTag $tag -AssetPath "StatsPro-$tag.zip"
    if ($attachArguments -contains "--clobber") {
        throw "AttachAssets gh arguments must never clobber a draft asset."
    }
    $publishArguments = Get-PublishGhArguments -Repository "owner/repo" -ExpectedTag $tag
    if ($publishArguments -notcontains "--draft=false") {
        throw "Publish gh arguments must publish the prepared draft."
    }
    $retireArguments = Get-RetirePreparedGhArguments -Repository "owner/repo" -ExpectedTag $tag
    if ($retireArguments -notcontains "--yes" -or $retireArguments -contains "--cleanup-tag") {
        throw "RetirePrepared must delete only the proven-safe draft and preserve its tag."
    }

    $protocolNotes = "## StatsPro $tag`n`nSafe release notes."
    $protocolManifest = "0123456789abcdef  StatsPro/StatsPro.lua"
    $protocolManifestSha = Get-LowercaseTextSha256 -Text $protocolManifest
    $protocolRunId = '12345'
    $protocolRunAttempt = '2'
    $protocolArchiveSha = 'a' * 64
    $protocolCandidateSha = 'b' * 64
    $preparedState = Get-ReleaseStateData `
        -Phase 'prepared' `
        -Repository 'owner/repo' `
        -ExpectedTag $tag `
        -ExpectedCommitSha $commit `
        -ExpectedRunId $protocolRunId `
        -NotesSha256 (Get-LowercaseTextSha256 -Text $protocolNotes) `
        -ManifestSha256 $protocolManifestSha
    $preparedBody = Get-ReleaseBody -State $preparedState -CanonicalNotes $protocolNotes
    $preparedV2State = Get-ReleaseStateData `
        -SchemaVersion 2 `
        -Phase 'prepared' `
        -Repository 'owner/repo' `
        -ExpectedTag $tag `
        -ExpectedCommitSha $commit `
        -ExpectedRunId $protocolRunId `
        -ExpectedRunAttempt $protocolRunAttempt `
        -NotesSha256 (Get-LowercaseTextSha256 -Text $protocolNotes) `
        -ManifestSha256 $protocolManifestSha `
        -ArchiveSha256 $protocolArchiveSha `
        -CandidateSha256 $protocolCandidateSha
    $preparedV2Body = Get-ReleaseBody -State $preparedV2State -CanonicalNotes $protocolNotes
    $newProtocolRelease = {
        param([string]$Phase, [string]$RunId, [object[]]$Assets, [bool]$Draft = $true, [bool]$Immutable = $false)
        $state = Get-ReleaseStateData -SchemaVersion 2 -Phase $Phase -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedRunId $RunId -ExpectedRunAttempt $protocolRunAttempt -NotesSha256 (Get-LowercaseTextSha256 -Text $protocolNotes) -ManifestSha256 $protocolManifestSha -ArchiveSha256 $protocolArchiveSha -CandidateSha256 $protocolCandidateSha
        return [pscustomobject]@{
            tag_name = $tag
            name = $tag
            target_commitish = $commit
            draft = $Draft
            prerelease = $false
            immutable = $Immutable
            body = Get-ReleaseBody -State $state -CanonicalNotes $protocolNotes
            assets = @($Assets)
        }
    }
    $preparedProtocolRelease = & $newProtocolRelease 'prepared' $protocolRunId @()
    $preparedLegacyRelease = [pscustomobject]@{
        tag_name = $tag
        name = $tag
        target_commitish = $commit
        draft = $true
        prerelease = $false
        immutable = $false
        body = $preparedBody
        assets = @()
    }
    $parsedPrepared = Read-ReleaseStateMarker -Body $preparedBody
    if ([string]$parsedPrepared.State.transactionId -ne [string]$preparedState.transactionId -or $parsedPrepared.Notes -ne $protocolNotes) {
        throw "Canonical release marker round trip failed."
    }
    $parsedPreparedV2 = Read-ReleaseStateMarker -Body $preparedV2Body
    if ([int]$parsedPreparedV2.State.schemaVersion -ne 2 -or
        $parsedPreparedV2.State.runAttempt -ne $protocolRunAttempt -or
        $parsedPreparedV2.State.archiveSha256 -ne $protocolArchiveSha -or
        $parsedPreparedV2.State.candidateSha256 -ne $protocolCandidateSha) {
        throw "Canonical v2 release marker round trip failed."
    }
    $preparedV2Release = [pscustomobject]@{
        tag_name = $tag
        name = $tag
        target_commitish = $commit
        draft = $true
        prerelease = $false
        immutable = $false
        body = $preparedV2Body
        assets = @()
    }
    [void](Assert-ReleaseProtocolIdentity -Release $preparedV2Release -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedPhase 'prepared' -ExpectedRunId $protocolRunId -ExpectedRunAttempt $protocolRunAttempt -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha -ExpectedArchiveSha256 $protocolArchiveSha -ExpectedCandidateSha256 $protocolCandidateSha)
    if ((Get-PreparedDraftClaimDisposition -Release $preparedV2Release -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha -DesiredBody $preparedV2Body) -ne 'already-current') {
        throw "Exact v2 prepared draft must not be rewritten."
    }
    if ((Get-PreparedDraftClaimDisposition -Release $preparedLegacyRelease -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha -DesiredBody $preparedV2Body) -ne 'rebind') {
        throw "Safe empty v1 prepared draft must be claimable as v2."
    }
    $stalePreparedV2State = Get-ReleaseStateData `
        -SchemaVersion 2 `
        -Phase 'prepared' `
        -Repository 'owner/repo' `
        -ExpectedTag $tag `
        -ExpectedCommitSha $commit `
        -ExpectedRunId '98765' `
        -ExpectedRunAttempt '3' `
        -NotesSha256 (Get-LowercaseTextSha256 -Text $protocolNotes) `
        -ManifestSha256 $protocolManifestSha `
        -ArchiveSha256 ('c' * 64) `
        -CandidateSha256 ('d' * 64)
    $stalePreparedV2Release = [pscustomobject]@{
        tag_name = $tag
        name = $tag
        target_commitish = $commit
        draft = $true
        prerelease = $false
        immutable = $false
        body = Get-ReleaseBody -State $stalePreparedV2State -CanonicalNotes $protocolNotes
        assets = @()
    }
    if ((Get-PreparedDraftClaimDisposition -Release $stalePreparedV2Release -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha -DesiredBody $preparedV2Body) -ne 'rebind') {
        throw "Safe stale v2 prepared draft must be claimable by the current candidate."
    }
    Assert-ThrowsMatch "v1 marker rejected at v2 transition" {
        [void](Assert-ReleaseProtocolIdentity -Release $preparedLegacyRelease -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedPhase 'prepared' -ExpectedRunId $protocolRunId -ExpectedRunAttempt $protocolRunAttempt -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha -ExpectedArchiveSha256 $protocolArchiveSha -ExpectedCandidateSha256 $protocolCandidateSha)
    } "run attempt"
    Assert-ThrowsMatch "wrong v2 archive digest rejected" {
        [void](Assert-ReleaseProtocolIdentity -Release $preparedV2Release -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedPhase 'prepared' -ExpectedRunId $protocolRunId -ExpectedRunAttempt $protocolRunAttempt -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha -ExpectedArchiveSha256 ('c' * 64) -ExpectedCandidateSha256 $protocolCandidateSha)
    } "archive digest"
    $staleV2Transaction = $preparedV2State.PSObject.Copy()
    $staleV2Transaction.runAttempt = '3'
    Assert-ThrowsMatch "stale v2 transaction rejected" {
        [void](Read-ReleaseStateMarker -Body (Get-ReleaseBody -State $staleV2Transaction -CanonicalNotes $protocolNotes))
    } "transaction ID"
    Assert-ThrowsMatch "uppercase release tag rejected" {
        Assert-StatsProReleaseTag -Value 'V1.2.3'
    } "Malformed StatsPro release tag"
    if ($null -ne (Select-GitHubReleaseByTag -Releases @([pscustomobject]@{ tag_name = 'V1.2.3' }) -ExpectedTag $tag)) {
        throw "Release lookup must use ordinal tag identity."
    }
    if ((Assert-ReleaseStartState -Release $null -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes) -ne 'fresh') {
        throw "Absent release must classify as fresh."
    }
    if ((Assert-ReleaseStartState -Release $preparedProtocolRelease -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes) -ne "prepared:$protocolRunId") {
        throw "Exact empty prepared release must be resumable."
    }
    $recoverableProtocolRelease = & $newProtocolRelease 'prepared' '98765' @()
    if ((Assert-ReleaseStartState -Release $recoverableProtocolRelease -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes) -ne 'prepared:98765') {
        throw "A protocol-owned empty prepared release from another run must be safely claimable."
    }
    Assert-ThrowsMatch "marketplace-started interruption rejected" {
        [void](Assert-ReleaseStartState -Release (& $newProtocolRelease 'marketplace-started' $protocolRunId @()) -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes)
    } "phase"
    Assert-ThrowsMatch "prepared release with assets rejected" {
        [void](Assert-ReleaseStartState -Release (& $newProtocolRelease 'prepared' $protocolRunId @([pscustomobject]@{ name = "StatsPro-$tag.zip" })) -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes)
    } "expected"
    Assert-ThrowsMatch "published interruption rejected" {
        [void](Assert-ReleaseStartState -Release (& $newProtocolRelease 'marketplace-started' $protocolRunId @() $false $true) -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes)
    } "already published"
    Assert-ThrowsMatch "duplicate protocol marker rejected" {
        [void](Read-ReleaseStateMarker -Body ($preparedBody + "`n" + (Get-ReleaseStateMarkerLine -State $preparedState)))
    } "exactly one"
    Assert-ThrowsMatch "release notes spoof rejected" {
        [void](Read-ReleaseStateMarker -Body ($preparedBody + 'changed'))
    } "notes"
    $extraJson = ($preparedState | ConvertTo-Json -Compress).TrimEnd('}') + ',"extra":true}'
    Assert-ThrowsMatch "unknown protocol field rejected" {
        [void](Read-ReleaseStateMarker -Body ("<!-- statspro-release-state:$(ConvertTo-Base64Url -Text $extraJson) -->`n`n$protocolNotes"))
    } "exact schema"
    $wrongPhaseJson = ($preparedState | ConvertTo-Json -Compress).Replace('"phase":"prepared"', '"phase":"Prepared"')
    Assert-ThrowsMatch "wrong-case protocol phase rejected" {
        [void](Read-ReleaseStateMarker -Body ("<!-- statspro-release-state:$(ConvertTo-Base64Url -Text $wrongPhaseJson) -->`n`n$protocolNotes"))
    } "unsupported phase"
    $leadingZeroTagState = $preparedState.PSObject.Copy()
    $leadingZeroTagState.tag = 'v01.2.3'
    Assert-ThrowsMatch "leading-zero protocol marker tag rejected" {
        [void](Read-ReleaseStateMarker -Body (Get-ReleaseBody -State $leadingZeroTagState -CanonicalNotes $protocolNotes))
    } "Malformed StatsPro release tag"
    $wrongTransaction = $preparedState.PSObject.Copy()
    $wrongTransaction.transactionId = '0' * 64
    Assert-ThrowsMatch "wrong transaction digest rejected" {
        [void](Read-ReleaseStateMarker -Body (Get-ReleaseBody -State $wrongTransaction -CanonicalNotes $protocolNotes))
    } "transaction ID"
    Assert-ThrowsMatch "wrong protocol owner rejected" {
        [void](Assert-ReleaseProtocolIdentity -Release $preparedProtocolRelease -Repository 'other/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedPhase 'prepared' -ExpectedRunId $protocolRunId -ExpectedRunAttempt $protocolRunAttempt -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha -ExpectedArchiveSha256 $protocolArchiveSha -ExpectedCandidateSha256 $protocolCandidateSha)
    } "identity"
    Assert-ThrowsMatch "wrong run owner rejected after claim" {
        [void](Assert-ReleaseProtocolIdentity -Release $preparedProtocolRelease -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedPhase 'prepared' -ExpectedRunId '99999' -ExpectedRunAttempt $protocolRunAttempt -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha -ExpectedArchiveSha256 $protocolArchiveSha -ExpectedCandidateSha256 $protocolCandidateSha)
    } "belongs to run"
    Assert-ThrowsMatch "wrong package manifest rejected" {
        [void](Assert-ReleaseProtocolIdentity -Release $preparedProtocolRelease -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedPhase 'prepared' -ExpectedRunId $protocolRunId -ExpectedRunAttempt $protocolRunAttempt -ExpectedNotes $protocolNotes -ExpectedManifestSha256 ('f' * 64) -ExpectedArchiveSha256 $protocolArchiveSha -ExpectedCandidateSha256 $protocolCandidateSha)
    } "manifest digest"

    $ambiguousCounters = [pscustomobject]@{ Mutations = 0; Reads = 0 }
    [void](Invoke-GitHubMutationAndAttest `
        -Description 'self-test ambiguous mutation' `
        -Arguments @('release', 'edit') `
        -Repository 'owner/repo' `
        -ExpectedTag $tag `
        -Attempts 2 `
        -Deadline $selfTestDeadline `
        -AssertState { param([object]$Observed) if ($Observed -ne $preparedProtocolRelease) { throw 'not visible' } } `
        -Mutate { param([string[]]$Arguments) $ambiguousCounters.Mutations++; throw 'lost response' } `
        -GetRelease { param([string]$Repository, [string]$ExpectedTag) $ambiguousCounters.Reads++; return $preparedProtocolRelease } `
        -Wait { param([int]$Seconds) })
    if ($ambiguousCounters.Mutations -ne 1 -or $ambiguousCounters.Reads -ne 1) {
        throw "Ambiguous mutation recovery must mutate once and then use read-only attestation."
    }
    $timedMutationClock = [pscustomobject]@{ Value = [datetime]"2026-01-01T00:00:00Z" }
    $timedMutationState = [pscustomobject]@{ Mutations = 0; Reads = 0; Deadline = [datetime]::MinValue }
    [void](Invoke-GitHubMutationAndAttest `
        -Description 'self-test timed-out mutation' `
        -Arguments @('release', 'edit') `
        -Repository 'owner/repo' `
        -ExpectedTag $tag `
        -Attempts 2 `
        -Deadline $timedMutationClock.Value.AddMinutes(5) `
        -AssertState { param([object]$Observed) if ($Observed -ne $preparedProtocolRelease) { throw 'not visible' } } `
        -Mutate {
            param([string[]]$Arguments, [datetime]$MutationDeadline)
            $timedMutationState.Mutations++
            $timedMutationState.Deadline = $MutationDeadline
            throw [System.TimeoutException]::new('fixture mutation timed out')
        } `
        -GetRelease {
            param([string]$Repository, [string]$ExpectedTag, [datetime]$Deadline)
            $timedMutationState.Reads++
            return $preparedProtocolRelease
        } `
        -Wait { param([int]$Seconds) } `
        -Now { $timedMutationClock.Value })
    if ($timedMutationState.Mutations -ne 1 -or
        $timedMutationState.Reads -ne 1 -or
        $timedMutationState.Deadline -ne $timedMutationClock.Value.AddSeconds(60)) {
        throw "Timed-out mutation recovery must cap the mutation deadline and retain global attestation budget."
    }
    $nearExpiryMutations = [pscustomobject]@{ Count = 0 }
    Assert-ThrowsMatch "mutation refuses to consume attestation reserve" {
        [void](Invoke-GitHubMutationAndAttest `
            -Description 'self-test near-expiry mutation' `
            -Arguments @('release', 'edit') `
            -Repository 'owner/repo' `
            -ExpectedTag $tag `
            -Attempts 2 `
            -Deadline $timedMutationClock.Value.AddSeconds(20) `
            -AssertState { param([object]$Observed) } `
            -Mutate { param([string[]]$Arguments, [datetime]$MutationDeadline) $nearExpiryMutations.Count++ } `
            -GetRelease { param([string]$Repository, [string]$ExpectedTag, [datetime]$Deadline) return $preparedProtocolRelease } `
            -Wait { param([int]$Seconds) } `
            -Now { $timedMutationClock.Value })
    } "fewer than 30 second.*remain for read-only attestation"
    if ($nearExpiryMutations.Count -ne 0) {
        throw "Near-expiry mutation must fail before changing external state."
    }
    $failedMutationCounter = [pscustomobject]@{ Mutations = 0 }
    Assert-ThrowsMatch "unconfirmed ambiguous mutation rejected" {
        [void](Invoke-GitHubMutationAndAttest `
            -Description 'self-test failed mutation' `
            -Arguments @('release', 'edit') `
            -Repository 'owner/repo' `
            -ExpectedTag $tag `
            -Attempts 2 `
            -Deadline $selfTestDeadline `
            -AssertState { param([AllowNull()][object]$Observed) throw 'not visible' } `
            -Mutate { param([string[]]$Arguments) $failedMutationCounter.Mutations++; throw 'lost response' } `
            -GetRelease { param([string]$Repository, [string]$ExpectedTag) return $null } `
            -Wait { param([int]$Seconds) })
    } "returned an error and the desired state was not observed"
    if ($failedMutationCounter.Mutations -ne 1) {
        throw "Failed ambiguous mutation must not be retried."
    }
    $startedProtocolRelease = & $newProtocolRelease 'marketplace-started' $protocolRunId @()
    foreach ($boundary in @(
        [pscustomobject]@{
            Name = 'draft creation'
            Observed = $preparedProtocolRelease
            Assert = {
                param([object]$Observed)
                [void](Assert-ReleaseProtocolIdentity -Release $Observed -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedPhase 'prepared' -ExpectedRunId $protocolRunId -ExpectedRunAttempt $protocolRunAttempt -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha -ExpectedArchiveSha256 $protocolArchiveSha -ExpectedCandidateSha256 $protocolCandidateSha)
                Assert-ExactAssetSet -Release $Observed -ExpectedNames @()
            }
        },
        [pscustomobject]@{
            Name = 'marketplace-started transition'
            Observed = $startedProtocolRelease
            Assert = {
                param([object]$Observed)
                [void](Assert-ReleaseProtocolIdentity -Release $Observed -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedPhase 'marketplace-started' -ExpectedRunId $protocolRunId -ExpectedRunAttempt $protocolRunAttempt -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha -ExpectedArchiveSha256 $protocolArchiveSha -ExpectedCandidateSha256 $protocolCandidateSha)
                Assert-ExactAssetSet -Release $Observed -ExpectedNames @()
            }
        },
        [pscustomobject]@{
            Name = 'prepared draft retirement'
            Observed = $null
            Assert = {
                param([AllowNull()][object]$Observed)
                if ($null -ne $Observed) { throw 'draft still visible' }
            }
        }
    )) {
        $boundaryCounters = [pscustomobject]@{ Mutations = 0; Reads = 0 }
        [void](Invoke-GitHubMutationAndAttest `
            -Description "self-test $($boundary.Name)" `
            -Arguments @('release', 'mutation') `
            -Repository 'owner/repo' `
            -ExpectedTag $tag `
            -Attempts 2 `
            -Deadline $selfTestDeadline `
            -AssertState $boundary.Assert `
            -Mutate { param([string[]]$Arguments) $boundaryCounters.Mutations++; throw 'lost response' } `
            -GetRelease { param([string]$Repository, [string]$ExpectedTag) $boundaryCounters.Reads++; return $boundary.Observed } `
            -Wait { param([int]$Seconds) })
        if ($boundaryCounters.Mutations -ne 1 -or $boundaryCounters.Reads -ne 1) {
            throw "Boundary '$($boundary.Name)' must mutate once and then converge read-only."
        }
    }
    $readOnlyRetry = [pscustomobject]@{ Checks = 0; Waits = 0 }
    Invoke-BoundedReadOnlyCheck `
        -Description 'self-test post-publish attestation' `
        -Attempts 3 `
        -Deadline $selfTestDeadline `
        -Check {
            $readOnlyRetry.Checks++
            if ($readOnlyRetry.Checks -lt 3) {
                throw 'not visible yet'
            }
        } `
        -Wait { param([int]$Seconds) $readOnlyRetry.Waits++ }
    if ($readOnlyRetry.Checks -ne 3 -or $readOnlyRetry.Waits -ne 2) {
        throw "Post-publish attestation retry must remain bounded and read-only."
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-release-manager-test-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
        $archivePath = Join-Path $tempDir "StatsPro-$tag.zip"
        $releaseJsonPath = Join-Path $tempDir "release.json"
        [System.IO.File]::WriteAllBytes($archivePath, [byte[]](1, 2, 3, 4))
        [System.IO.File]::WriteAllText($releaseJsonPath, '{"releases":[]}', [System.Text.UTF8Encoding]::new($false))
        $draftWithDigests = [pscustomobject]@{
            tag_name = $tag
            draft = $true
            prerelease = $false
            immutable = $false
            assets = @(
                [pscustomobject]@{
                    name = "StatsPro-$tag.zip"
                    state = "uploaded"
                    size = (Get-Item -LiteralPath $archivePath).Length
                    digest = "sha256:$(Get-LowercaseFileSha256 -Path $archivePath)"
                },
                [pscustomobject]@{
                    name = "release.json"
                    state = "uploaded"
                    size = (Get-Item -LiteralPath $releaseJsonPath).Length
                    digest = "sha256:$(Get-LowercaseFileSha256 -Path $releaseJsonPath)"
                }
            )
        }
        Assert-DraftAssetsMatchLocalFiles -Release $draftWithDigests -ExpectedTag $tag -ArchivePath $archivePath -ReleaseJsonPath $releaseJsonPath
        $publishedProtocolRelease = & $newProtocolRelease 'marketplace-started' $protocolRunId @($draftWithDigests.assets) $false $true
        [void](Assert-PublishedProtocolIdentity -Release $publishedProtocolRelease -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedRunId $protocolRunId -ExpectedRunAttempt $protocolRunAttempt -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha -ExpectedArchiveSha256 $protocolArchiveSha -ExpectedCandidateSha256 $protocolCandidateSha)
        $localFiles = @{
            "StatsPro-$tag.zip" = $archivePath
            'release.json' = $releaseJsonPath
        }
        $partialProtocol = & $newProtocolRelease 'marketplace-started' $protocolRunId @($draftWithDigests.assets[0])
        Assert-ReleaseAssetSubsetMatchesLocalFiles -Release $partialProtocol -LocalFiles $localFiles
        Assert-ThrowsMatch "partial post-marketplace rerun rejected" {
            [void](Assert-ReleaseStartState -Release $partialProtocol -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedNotes $protocolNotes)
        } "phase"
        foreach ($boundary in @(
            [pscustomobject]@{
                Name = 'single asset upload'
                Observed = $partialProtocol
                Assert = {
                    param([object]$Observed)
                    [void](Assert-ReleaseProtocolIdentity -Release $Observed -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedPhase 'marketplace-started' -ExpectedRunId $protocolRunId -ExpectedRunAttempt $protocolRunAttempt -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha -ExpectedArchiveSha256 $protocolArchiveSha -ExpectedCandidateSha256 $protocolCandidateSha)
                    Assert-ReleaseAssetSubsetMatchesLocalFiles -Release $Observed -LocalFiles $localFiles
                    if (-not (Test-ContainsOrdinal -Values @(Get-ReleaseAssetNames -Release $Observed) -Expected "StatsPro-$tag.zip")) { throw 'asset missing' }
                }
            },
            [pscustomobject]@{
                Name = 'immutable publish'
                Observed = $publishedProtocolRelease
                Assert = {
                    param([object]$Observed)
                    [void](Assert-PublishedProtocolIdentity -Release $Observed -Repository 'owner/repo' -ExpectedTag $tag -ExpectedCommitSha $commit -ExpectedRunId $protocolRunId -ExpectedRunAttempt $protocolRunAttempt -ExpectedNotes $protocolNotes -ExpectedManifestSha256 $protocolManifestSha -ExpectedArchiveSha256 $protocolArchiveSha -ExpectedCandidateSha256 $protocolCandidateSha)
                }
            }
        )) {
            $boundaryCounters = [pscustomobject]@{ Mutations = 0; Reads = 0 }
            [void](Invoke-GitHubMutationAndAttest `
                -Description "self-test $($boundary.Name)" `
                -Arguments @('release', 'mutation') `
                -Repository 'owner/repo' `
                -ExpectedTag $tag `
                -Attempts 2 `
                -Deadline $selfTestDeadline `
                -AssertState $boundary.Assert `
                -Mutate { param([string[]]$Arguments) $boundaryCounters.Mutations++; throw 'lost response' } `
                -GetRelease { param([string]$Repository, [string]$ExpectedTag) $boundaryCounters.Reads++; return $boundary.Observed } `
                -Wait { param([int]$Seconds) })
            if ($boundaryCounters.Mutations -ne 1 -or $boundaryCounters.Reads -ne 1) {
                throw "Boundary '$($boundary.Name)' must mutate once and then converge read-only."
            }
        }
        foreach ($subset in @(
            @(),
            @($draftWithDigests.assets[1]),
            @($draftWithDigests.assets)
        )) {
            Assert-ReleaseAssetSubsetMatchesLocalFiles -Release (& $newProtocolRelease 'marketplace-started' $protocolRunId $subset) -LocalFiles $localFiles
        }
        Assert-ThrowsMatch "duplicate partial asset rejected" {
            Assert-ReleaseAssetSubsetMatchesLocalFiles -Release (& $newProtocolRelease 'marketplace-started' $protocolRunId @($draftWithDigests.assets[0], $draftWithDigests.assets[0])) -LocalFiles $localFiles
        } "duplicate asset"
        foreach ($mutation in @(
            [pscustomobject]@{ Field = 'state'; Value = 'new'; Pattern = 'state' },
            [pscustomobject]@{ Field = 'size'; Value = 999; Pattern = 'size' },
            [pscustomobject]@{ Field = 'digest'; Value = "sha256:$('0' * 64)"; Pattern = 'digest' }
        )) {
            $badAsset = $draftWithDigests.assets[1].PSObject.Copy()
            $badAsset.($mutation.Field) = $mutation.Value
            Assert-ThrowsMatch "partial asset $($mutation.Field) rejected" {
                Assert-ReleaseAssetSubsetMatchesLocalFiles -Release (& $newProtocolRelease 'marketplace-started' $protocolRunId @($badAsset)) -LocalFiles $localFiles
            } $mutation.Pattern
        }
        $unexpectedProtocol = & $newProtocolRelease 'marketplace-started' $protocolRunId @([pscustomobject]@{ name = 'unexpected.txt'; state = 'uploaded'; size = 1; digest = 'sha256:' + ('0' * 64) })
        Assert-ThrowsMatch "unexpected partial asset rejected" {
            Assert-ReleaseAssetSubsetMatchesLocalFiles -Release $unexpectedProtocol -LocalFiles $localFiles
        } "unexpected asset"
        $wrongCaseProtocol = & $newProtocolRelease 'marketplace-started' $protocolRunId @([pscustomobject]@{
            name = "statspro-$tag.zip"
            state = 'uploaded'
            size = (Get-Item -LiteralPath $archivePath).Length
            digest = "sha256:$(Get-LowercaseFileSha256 -Path $archivePath)"
        })
        Assert-ThrowsMatch "wrong-case partial asset rejected" {
            Assert-ReleaseAssetSubsetMatchesLocalFiles -Release $wrongCaseProtocol -LocalFiles $localFiles
        } "unexpected asset"
        $wrongCaseFull = $draftWithDigests.PSObject.Copy()
        $wrongCaseFull.assets = @($draftWithDigests.assets | ForEach-Object { $_.PSObject.Copy() })
        $wrongCaseFull.assets[0].name = "statspro-$tag.zip"
        Assert-ThrowsMatch "wrong-case exact asset rejected" {
            Assert-DraftAssetsMatchLocalFiles -Release $wrongCaseFull -ExpectedTag $tag -ArchivePath $archivePath -ReleaseJsonPath $releaseJsonPath
        } "expected"
        $wrongCaseArchivePath = Join-Path $tempDir "statspro-$tag.zip"
        [System.IO.File]::WriteAllBytes($wrongCaseArchivePath, [byte[]](1, 2, 3, 4))
        Assert-ThrowsMatch "wrong-case local archive rejected" {
            [void](Assert-ReleaseAssetPaths -ArchivePath $wrongCaseArchivePath -ReleaseJsonPath $releaseJsonPath -ExpectedTag $tag)
        } "Archive filename"
        $swapped = $draftWithDigests.PSObject.Copy()
        $swapped.assets = @($draftWithDigests.assets | ForEach-Object { $_.PSObject.Copy() })
        $swapped.assets[0].digest = "sha256:$('0' * 64)"
        Assert-ThrowsMatch "draft asset swap rejected" {
            Assert-DraftAssetsMatchLocalFiles -Release $swapped -ExpectedTag $tag -ArchivePath $archivePath -ReleaseJsonPath $releaseJsonPath
        } "digest"
        $pending = $draftWithDigests.PSObject.Copy()
        $pending.assets = @($draftWithDigests.assets | ForEach-Object { $_.PSObject.Copy() })
        $pending.assets[1].state = "new"
        Assert-ThrowsMatch "incomplete draft asset rejected" {
            Assert-DraftAssetsMatchLocalFiles -Release $pending -ExpectedTag $tag -ArchivePath $archivePath -ReleaseJsonPath $releaseJsonPath
        } "state"
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $attestation = [pscustomobject]@{
        verificationResult = [pscustomobject]@{
            statement = [pscustomobject]@{
                subject = @([pscustomobject]@{
                    uri = "pkg:github/owner/repo@$tag"
                    digest = [pscustomobject]@{ sha1 = $commit }
                })
            }
        }
    }
    Assert-ReleaseAttestationCommit -Attestation $attestation -Repository "owner/repo" -ExpectedTag $tag -ExpectedCommitSha $commit
    $wrongCommitAttestation = $attestation.PSObject.Copy()
    $wrongCommitAttestation.verificationResult = $attestation.verificationResult.PSObject.Copy()
    $wrongCommitAttestation.verificationResult.statement = $attestation.verificationResult.statement.PSObject.Copy()
    $wrongCommitAttestation.verificationResult.statement.subject = @([pscustomobject]@{
        uri = "pkg:github/owner/repo@$tag"
        digest = [pscustomobject]@{ sha1 = "fedcba9876543210fedcba9876543210fedcba98" }
    })
    Assert-ThrowsMatch "wrong attestation commit rejected" {
        Assert-ReleaseAttestationCommit -Attestation $wrongCommitAttestation -Repository "owner/repo" -ExpectedTag $tag -ExpectedCommitSha $commit
    } "attestation commit"

    $workflowPath = Join-Path (Join-Path $PSScriptRoot "..") ".github\workflows\release.yml"
    $workflowText = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
    Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText
    Assert-ThrowsMatch "workflow_dispatch release trigger rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '(?m)^  push:\s*$', "  workflow_dispatch:`n  push:")
    } "exact tag-only push trigger"
    Assert-ThrowsMatch "broadened release tag trigger rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace("      - 'v*'", "      - '*'")
    } "exact tag-only push trigger"
    Assert-ThrowsMatch "missing preflight event guard rejected" {
        $preflight = Get-WorkflowJobBlock -WorkflowText $workflowText -JobName 'preflight'
        $replacement = $preflight.Value -replace '(?m)^    if:.*\r?\n', ''
        $mutated = $workflowText.Remove($preflight.Index, $preflight.Length).Insert($preflight.Index, $replacement)
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "preflight.*first-created, non-forced, non-deleted"
    Assert-ThrowsMatch "weakened package event guard rejected" {
        $packageReleaseJob = Get-WorkflowJobBlock -WorkflowText $workflowText -JobName 'package'
        $replacement = $packageReleaseJob.Value.Replace(
            'github.event.created == true && github.event.forced == false && github.event.deleted == false',
            'github.event.created == true && github.event.deleted == false')
        $mutated = $workflowText.Remove($packageReleaseJob.Index, $packageReleaseJob.Length).Insert($packageReleaseJob.Index, $replacement)
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "package.*first-created, non-forced, non-deleted"
    Assert-ThrowsMatch "both release event guards weakened together rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            'github.event.created == true && github.event.forced == false && github.event.deleted == false',
            'github.event.created == true')
    } "preflight.*first-created, non-forced, non-deleted"
    Assert-ThrowsMatch "combined release trigger and guard drift rejected at admission" {
        $mutated = $workflowText.Replace("      - 'v*'", "      - '*'")
        $mutated = $mutated.Replace(
            'github.event.created == true && github.event.forced == false && github.event.deleted == false',
            'github.event.deleted == false')
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "exact tag-only push trigger"
    $checksWorkflowPath = Join-Path (Join-Path $PSScriptRoot "..") ".github\workflows\checks.yml"
    $checksWorkflowText = Get-Content -LiteralPath $checksWorkflowPath -Raw -Encoding UTF8
    Assert-ChecksWorkflowBoundary -WorkflowText $checksWorkflowText
    Assert-ThrowsMatch "missing pull_request checks trigger rejected" {
        Assert-ChecksWorkflowBoundary -WorkflowText $checksWorkflowText.Replace(
            '  pull_request:',
            '  schedule:')
    } "must include the pull_request trigger"
    Assert-ThrowsMatch "fork PR package-contract filter rejected" {
        Assert-ChecksWorkflowBoundary -WorkflowText $checksWorkflowText.Replace(
            '  package-contract:',
            "  package-contract:`n    if: `${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository }}")
    } "must not define a job-level pull request filter"
    Assert-ThrowsMatch "pull_request_target checks trigger rejected" {
        Assert-ChecksWorkflowBoundary -WorkflowText $checksWorkflowText.Replace(
            '  pull_request:',
            '  pull_request_target:')
    } "must not use pull_request_target"
    Assert-ThrowsMatch "write checks workflow permission rejected" {
        Assert-ChecksWorkflowBoundary -WorkflowText $checksWorkflowText.Replace(
            '  contents: read',
            '  contents: write')
    } "contents: read without workflow-level write permissions"
    Assert-ThrowsMatch "package-contract publication flags rejected" {
        Assert-ChecksWorkflowBoundary -WorkflowText $checksWorkflowText.Replace(
            '          args: -d',
            '          args: -d --publish')
    } "literal args: -d without publication flags"
    Assert-ThrowsMatch "reordered package-contract steps rejected" {
        $packageJob = Get-WorkflowJobBlock -WorkflowText $checksWorkflowText -JobName 'package-contract'
        $stepBlocks = @([regex]::Matches($packageJob.Value, '(?ms)^\s{6}- name: .+?\s*$.*?(?=^\s{6}- name:|\z)'))
        $packager = @($stepBlocks | Where-Object { $_.Value -match '(?i)BigWigsMods/packager@' })[0]
        $resolver = @($stepBlocks | Where-Object { $_.Value -match '(?i)resolve-packager-output\.ps1' })[0]
        $validator = @($stepBlocks | Where-Object { $_.Value -match '(?i)check-package-dry-run\.ps1' })[0]
        $mutated = $checksWorkflowText.Replace(
            ($packager.Value + $resolver.Value + $validator.Value),
            ($resolver.Value + $packager.Value + $validator.Value))
        Assert-ChecksWorkflowBoundary -WorkflowText $mutated
    } "must run Packager, resolver, and validator in that order"
    Assert-ThrowsMatch "package-contract GitHub token exposure rejected" {
        Assert-ChecksWorkflowBoundary -WorkflowText $checksWorkflowText.Replace(
            '        uses: BigWigsMods/packager@6d50adb6e8517eefef63f4afb16a6518166a6b28',
            "        uses: BigWigsMods/packager@6d50adb6e8517eefef63f4afb16a6518166a6b28`n        env:`n          GH_TOKEN: `${{ github.token }}")
    } "must not reference secrets or a GitHub token"
    Assert-ThrowsMatch "package-contract secret exposure rejected" {
        Assert-ChecksWorkflowBoundary -WorkflowText $checksWorkflowText.Replace(
            '        uses: BigWigsMods/packager@6d50adb6e8517eefef63f4afb16a6518166a6b28',
            "        uses: BigWigsMods/packager@6d50adb6e8517eefef63f4afb16a6518166a6b28`n        env:`n          CF_API_KEY: `${{ secrets.CF_API_KEY }}")
    } "must not reference secrets or a GitHub token"
    Assert-ThrowsMatch "package-contract output handoff drift rejected" {
        Assert-ChecksWorkflowBoundary -WorkflowText $checksWorkflowText.Replace(
            '${{ steps.package-output.outputs.archive_path }}',
            '${{ steps.package.outputs.archive_path }}')
    } "preserve the resolver-to-validator output handoff"
    $marketplaceWorkflowPath = Join-Path (Join-Path $PSScriptRoot "..") ".github\workflows\marketplace-credential-preflight.yml"
    $marketplaceWorkflowText = Get-Content -LiteralPath $marketplaceWorkflowPath -Raw -Encoding UTF8
    Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText
    Assert-ThrowsMatch "non-manual marketplace credential workflow rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            '  workflow_dispatch:',
            '  push:')
    } "exact workflow_dispatch trigger"
    Assert-ThrowsMatch "marketplace credential working-directory redirect rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            'name: Marketplace credential preflight',
            "name: Marketplace credential preflight`n`ndefaults:`n  run:`n    working-directory: attacker-controlled")
    } "Trusted manual workflow keys"
    Assert-ThrowsMatch "spaced marketplace credential working-directory redirect rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            'name: Marketplace credential preflight',
            "name: Marketplace credential preflight`n`ndefaults :`n  run:`n    working-directory: attacker-controlled")
    } "whitespace before the colon"
    Assert-ThrowsMatch "non-main marketplace credential dispatch rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            "github.ref == 'refs/heads/main'",
            "github.ref == 'refs/heads/feature'")
    } "exact main ref"
    Assert-ThrowsMatch "wrong marketplace credential environment rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            'environment: marketplace-manual',
            'environment: marketplace-release')
    } "environment marketplace-manual"
    Assert-ThrowsMatch "dynamic marketplace credential checkout rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            'ref: ${{ github.sha }}',
            'ref: ${{ github.ref }}')
    } "exact dispatched commit"
    Assert-ThrowsMatch "self-hosted marketplace credential runner rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            'runs-on: ubuntu-latest',
            'runs-on: self-hosted')
    } "run only on ubuntu-latest"
    Assert-ThrowsMatch "job permission override in marketplace credential workflow rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            '  preflight:',
            "  preflight:`n    permissions:`n      contents: write")
    } "Trusted manual job 'preflight' keys"
    Assert-ThrowsMatch "marketplace credential container interception rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            '    runs-on: ubuntu-latest',
            "    runs-on: ubuntu-latest`n    container: attacker/image")
    } "Trusted manual job 'preflight' keys"
    Assert-ThrowsMatch "quoted marketplace credential container interception rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            '    runs-on: ubuntu-latest',
            "    runs-on: ubuntu-latest`n    `"container`": attacker/image")
    } "quoted, merged, or explicit mapping keys"
    Assert-ThrowsMatch "spaced marketplace credential container interception rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            '    runs-on: ubuntu-latest',
            "    runs-on: ubuntu-latest`n    container : attacker/image")
    } "whitespace before the colon"
    Assert-ThrowsMatch "explicit marketplace credential container interception rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            '    runs-on: ubuntu-latest',
            "    runs-on: ubuntu-latest`n    ? container`n    : attacker/image")
    } "multi-line explicit mapping keys"
    Assert-ThrowsMatch "tagged marketplace credential container interception rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            '    runs-on: ubuntu-latest',
            "    runs-on: ubuntu-latest`n    !!str container: attacker/image")
    } "Marketplace credential workflow.*canonical YAML block"
    Assert-ThrowsMatch "intervening marketplace credential step rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            '      - name: Verify marketplace release credentials and versions',
            "      - name: Mutate checker`n        run: echo changed`n`n      - name: Verify marketplace release credentials and versions")
    } "must contain only checkout"
    Assert-ThrowsMatch "swapped manual marketplace secret bindings rejected" {
        $mutated = $marketplaceWorkflowText.Replace(
            'secrets.CF_API_KEY',
            'secrets.TEMP_MARKETPLACE_TOKEN').Replace(
                'secrets.WAGO_API_TOKEN',
                'secrets.CF_API_KEY').Replace(
                    'secrets.TEMP_MARKETPLACE_TOKEN',
                    'secrets.WAGO_API_TOKEN')
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $mutated
    } "bind CF_API_KEY|bind WAGO_API_TOKEN|non-canonical"
    Assert-ThrowsMatch "job-level manual marketplace secret rejected" {
        $mutated = $marketplaceWorkflowText.Replace(
            '  preflight:',
            "  preflight:`n    env:`n      WAGO_API_TOKEN: `${{ secrets.WAGO_API_TOKEN }}")
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $mutated
    } "Trusted manual job 'preflight' keys|scoped to its checker step"
    Assert-ThrowsMatch "fallible manual marketplace checker rejected" {
        $mutated = $marketplaceWorkflowText.Replace(
            '      - name: Verify marketplace release credentials and versions',
            "      - name: Verify marketplace release credentials and versions`n        continue-on-error: true")
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $mutated
    } "checker step keys|exact mandatory pwsh checker"
    Assert-ThrowsMatch "Packager in manual marketplace workflow rejected" {
        $mutated = $marketplaceWorkflowText.Replace(
            '      - name: Verify marketplace release credentials and versions',
            "      - name: Unexpected Packager`n        uses: BigWigsMods/packager@6d50adb6e8517eefef63f4afb16a6518166a6b28`n        with:`n          args: -d`n`n      - name: Verify marketplace release credentials and versions")
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $mutated
    } "must not execute Packager"
    Assert-ThrowsMatch "manual marketplace self-test substitution rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText ($marketplaceWorkflowText -replace '\./scripts/check-marketplace-versions\.ps1', './scripts/check-marketplace-versions.ps1 -SelfTest')
    } "exact mandatory pwsh checker"
    Assert-ThrowsMatch "bare marketplace secrets context rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            '          WAGO_API_TOKEN: ${{ secrets.WAGO_API_TOKEN }}',
            "          WAGO_API_TOKEN: `${{ secrets.WAGO_API_TOKEN }}`n          payload: `${{ toJSON(secrets) }}")
    } "checker environment keys|non-canonical secret"
    Assert-ThrowsMatch "continued marketplace checker command rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            '        run: ./scripts/check-marketplace-versions.ps1',
            "        run: ./scripts/check-marketplace-versions.ps1`n          ; Write-Host `$env:CF_API_KEY")
    } "canonical YAML block"
    Assert-ThrowsMatch "continued marketplace anonymous-check command rejected" {
        Assert-MarketplaceCredentialWorkflowBoundary -WorkflowText $marketplaceWorkflowText.Replace(
            '        run: ./scripts/check-anonymous-checkout.ps1',
            "        run: ./scripts/check-anonymous-checkout.ps1`n          ; Write-Host changed")
    } "canonical YAML block"

    $diagnosticsWorkflowPath = Join-Path (Join-Path $PSScriptRoot "..") ".github\workflows\curseforge-diagnostics.yml"
    $diagnosticsWorkflowText = Get-Content -LiteralPath $diagnosticsWorkflowPath -Raw -Encoding UTF8
    Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText
    Assert-ThrowsMatch "non-manual CurseForge diagnostics workflow rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            '  workflow_dispatch:',
            '  pull_request_target:')
    } "exact workflow_dispatch trigger"
    Assert-ThrowsMatch "CurseForge diagnostics working-directory redirect rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            'name: CurseForge diagnostics',
            "name: CurseForge diagnostics`n`ndefaults:`n  run:`n    working-directory: attacker-controlled")
    } "Trusted manual workflow keys"
    Assert-ThrowsMatch "spaced CurseForge diagnostics container interception rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            '    runs-on: ubuntu-latest',
            "    runs-on: ubuntu-latest`n    container : attacker/image")
    } "whitespace before the colon"
    Assert-ThrowsMatch "non-main CurseForge diagnostics dispatch rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            "github.ref == 'refs/heads/main'",
            "github.ref == 'refs/tags/main'")
    } "exact main ref"
    Assert-ThrowsMatch "wrong CurseForge diagnostics environment rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            'environment: marketplace-manual',
            'environment: marketplace-release')
    } "environment marketplace-manual"
    Assert-ThrowsMatch "dynamic CurseForge diagnostics checkout rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            'ref: ${{ github.sha }}',
            'ref: ${{ github.ref }}')
    } "exact dispatched commit"
    Assert-ThrowsMatch "self-hosted CurseForge diagnostics runner rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            'runs-on: ubuntu-latest',
            'runs-on: self-hosted')
    } "run only on ubuntu-latest"
    Assert-ThrowsMatch "persisted CurseForge diagnostics checkout credentials rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            'persist-credentials: false',
            'persist-credentials: true')
    } "literal persist-credentials: false"
    Assert-ThrowsMatch "missing CurseForge diagnostics anonymous check rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            '      - name: Verify anonymous checkout boundary',
            '      - name: Credential boundary removed')
    } "verify checkout credentials immediately"
    Assert-ThrowsMatch "CurseForge diagnostics checker drift rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            './scripts/check-curseforge-diagnostics.ps1',
            './scripts/check-curseforge-diagnostics.ps1 -SelfTest')
    } "exact mandatory pwsh checker"
    Assert-ThrowsMatch "CurseForge diagnostics version input drift rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            '${{ inputs.version }}',
            '${{ github.ref_name }}')
    } "exact secret, project, and version bindings"
    Assert-ThrowsMatch "job-level CurseForge diagnostics secret rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            '  files:',
            "  files:`n    env:`n      CF_API_KEY: `${{ secrets.CF_API_KEY }}")
    } "Trusted manual job 'files' keys|scoped to its query step"
    Assert-ThrowsMatch "extra CurseForge diagnostics secret rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            '          STATSPRO_VERSION: ${{ inputs.version }}',
            "          STATSPRO_VERSION: `${{ inputs.version }}`n          EXTRA_TOKEN: `${{ secrets.IMMUTABLE_RELEASES_READ_TOKEN }}")
    } "query environment keys|exact three environment keys|extra secret source"
    Assert-ThrowsMatch "bare CurseForge diagnostics secrets context rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            '          STATSPRO_VERSION: ${{ inputs.version }}',
            "          STATSPRO_VERSION: `${{ inputs.version }}`n          payload: `${{ toJSON(secrets) }}")
    } "query environment keys|extra secret source"
    Assert-ThrowsMatch "intervening CurseForge diagnostics step rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            '      - name: Query CurseForge legacy API',
            "      - name: Mutate checker`n        run: echo changed`n`n      - name: Query CurseForge legacy API")
    } "must contain only checkout"
    Assert-ThrowsMatch "duplicate CurseForge diagnostics run key rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            '        run: ./scripts/check-curseforge-diagnostics.ps1',
            "        run: ./scripts/check-curseforge-diagnostics.ps1`n        run: echo leaked")
    } "query step keys"
    Assert-ThrowsMatch "continued CurseForge diagnostics command rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            '        run: ./scripts/check-curseforge-diagnostics.ps1',
            "        run: ./scripts/check-curseforge-diagnostics.ps1`n          ; Write-Host `$env:CF_API_KEY")
    } "canonical YAML block"
    Assert-ThrowsMatch "continued diagnostics anonymous-check command rejected" {
        Assert-CurseForgeDiagnosticsWorkflowBoundary -WorkflowText $diagnosticsWorkflowText.Replace(
            '        run: ./scripts/check-anonymous-checkout.ps1',
            "        run: ./scripts/check-anonymous-checkout.ps1`n          ; Write-Host changed")
    } "canonical YAML block"

    foreach ($reference in @(
        '${{ secrets.GITHUB_TOKEN }}',
        '${{ secrets [ ''GITHUB_TOKEN'' ] }}',
        '${{ secrets["GITHUB_TOKEN"] }}',
        '${{ github.token }}',
        '${{ github [ ''token'' ] }}',
        '${{ github["token"] }}',
        '${{ secrets . GITHUB_TOKEN }}'
    )) {
        if (-not (Test-ContainsGitHubTokenReference -Text $reference)) {
            throw "GitHub token reference detector missed a supported expression form."
        }
    }
    foreach ($reference in @(
        '${{ secrets.CF_API_KEY }}',
        '${{ github.repository }}',
        'GITHUB_TOKEN is named only in documentation text'
    )) {
        if (Test-ContainsGitHubTokenReference -Text $reference) {
            throw "GitHub token reference detector rejected a non-token expression."
        }
    }
    foreach ($reference in @(
        '${{ secrets.IMMUTABLE_RELEASES_READ_TOKEN }}',
        '${{ secrets [ ''IMMUTABLE_RELEASES_READ_TOKEN'' ] }}',
        '${{ secrets["IMMUTABLE_RELEASES_READ_TOKEN"] }}',
        '${{ secrets . IMMUTABLE_RELEASES_READ_TOKEN }}'
    )) {
        if (-not (Test-ContainsSecretReference -Text $reference -SecretName 'IMMUTABLE_RELEASES_READ_TOKEN')) {
            throw "Immutable policy token detector missed a supported expression form."
        }
    }
    if (Test-ContainsSecretReference -Text '${{ secrets.IMMUTABLE_RELEASES_READ_TOKEN_BACKUP }}' -SecretName 'IMMUTABLE_RELEASES_READ_TOKEN') {
        throw "Immutable policy token detector matched a longer secret name."
    }

    $replaceJob = {
        param([string]$JobName, [scriptblock]$Mutation)
        $job = Get-WorkflowJobBlock -WorkflowText $workflowText -JobName $JobName
        $replacement = & $Mutation $job.Value
        return $workflowText.Remove($job.Index, $job.Length).Insert($job.Index, $replacement)
    }

    Assert-ThrowsMatch "missing release job rejected" {
        $job = Get-WorkflowJobBlock -WorkflowText $workflowText -JobName 'marketplace-upload'
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Remove($job.Index, $job.Length)
    } "job inventory|missing job"

    Assert-ThrowsMatch "package write permission rejected" {
        $mutated = & $replaceJob 'package' { param($value) $value.Replace('      contents: read', '      contents: write') }
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "package.*contents: read"

    Assert-ThrowsMatch "verify write permission rejected" {
        $mutated = & $replaceJob 'verify' { param($value) $value.Replace('      contents: read', '      contents: write') }
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "verify.*contents: read"

    Assert-ThrowsMatch "marketplace read permission rejected" {
        $mutated = & $replaceJob 'marketplace-upload' { param($value) $value.Replace('      contents: write', '      contents: read') }
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "marketplace-upload.*contents: write"

    Assert-ThrowsMatch "third-party action in write job rejected" {
        $mutated = & $replaceJob 'github-prepare' {
            param($value)
            $value.Replace(
                'actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c',
                'BigWigsMods/packager@6d50adb6e8517eefef63f4afb16a6518166a6b28')
        }
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "allowlist"

    Assert-ThrowsMatch "credential environment on write job rejected" {
        $mutated = & $replaceJob 'github-finalize' { param($value) $value.Replace('    runs-on:', "    environment: marketplace-release`n    runs-on:") }
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "keys|must not bind a credential environment"

    Assert-ThrowsMatch "wrong job dependency rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            '    needs: [package, marketplace-upload]',
            '    needs: marketplace-upload')
    } "wrong dependency boundary"

    Assert-ThrowsMatch "missing credential environment rejected" {
        $mutated = & $replaceJob 'marketplace-upload' { param($value) $value -replace '(?m)^    environment: marketplace-release\s*\r?\n', '' }
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "keys|environment marketplace-release"

    Assert-ThrowsMatch "marketplace secret in package job rejected" {
        $mutated = $workflowText.Replace(
            '      - name: Build package without publishing',
            "      - name: Build package without publishing`n        env:`n          CF_API_KEY: `${{ secrets.CF_API_KEY }}")
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "secret.*approved|secret-free"

    Assert-ThrowsMatch "publishing Packager flags rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace('          args: -e -d', '          args: -c -e -o')
    } "non-publishing Packager"

    Assert-ThrowsMatch "artifact overwrite rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace('          overwrite: false', '          overwrite: true')
    } "immutable handoff setting"

    Assert-ThrowsMatch "hidden candidate exclusion rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace('          include-hidden-files: true', '          include-hidden-files: false')
    } "immutable handoff setting"

    Assert-ThrowsMatch "artifact download by name rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace 'artifact-ids: \$\{\{ needs\.package\.outputs\.artifact_id \}\}', 'name: release-candidate')
    } "exact current-run artifact ID"

    Assert-ThrowsMatch "foreign artifact run rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            '          digest-mismatch: error',
            "          digest-mismatch: error`n          run-id: 123")
    } "exact current-run artifact ID"

    Assert-ThrowsMatch "artifact digest mismatch warning rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace('          digest-mismatch: error', '          digest-mismatch: warn')
    } "fail on digest mismatch"

    Assert-ThrowsMatch "wrong candidate hash source rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            "needs.package.outputs.candidate_sha256",
            "needs.package.outputs.archive_sha256")
    } "exact candidate|candidate identity|canonical YAML block"

    Assert-ThrowsMatch "wrong run-attempt binding rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            '-ExpectedRunAttempt ''${{ needs.package.outputs.run_attempt }}''',
            '-ExpectedRunAttempt $env:GITHUB_RUN_ATTEMPT')
    } "candidate identity|canonical YAML block"

    Assert-ThrowsMatch "missing inner archive hash output rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '(?m)^\s{6}archive_sha256:.*\r?\n', '')
    } "artifact identity and inner candidate hashes"

    Assert-ThrowsMatch "missing package attempt output rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '(?m)^\s{6}run_attempt:.*\r?\n', '')
    } "artifact identity and inner candidate hashes"

    Assert-ThrowsMatch "preliminary project version output rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            'steps.rebuild-package-output.outputs.project_version',
            'steps.build-package-output.outputs.project_version')
    } "artifact identity and inner candidate hashes"

    $packageJob = Get-WorkflowJobBlock -WorkflowText $workflowText -JobName 'package'
    $createBlock = [regex]::Match($packageJob.Value, '(?ms)^\s{6}- name: Create exact release candidate\s*$.*?(?=^\s{6}- name:|\z)')
    $uploadBlock = [regex]::Match($packageJob.Value, '(?ms)^\s{6}- name: Upload exact release candidate\s*$.*?(?=^\s{6}- name:|\z)')
    $swappedPackage = $packageJob.Value.Substring(0, $createBlock.Index) +
        $uploadBlock.Value + $createBlock.Value +
        $packageJob.Value.Substring($uploadBlock.Index + $uploadBlock.Length)
    Assert-ThrowsMatch "candidate attestation after artifact upload rejected" {
        $mutated = $workflowText.Remove($packageJob.Index, $packageJob.Length).Insert($packageJob.Index, $swappedPackage)
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "before artifact upload|step inventory"

    Assert-ThrowsMatch "wrong marketplace archive hash rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            '-ExpectedSha256 ''${{ needs.package.outputs.archive_sha256 }}''',
            '-ExpectedSha256 ''${{ needs.package.outputs.candidate_sha256 }}''')
    } "already verified exact archive|canonical YAML block"

    Assert-ThrowsMatch "marketplace plan hash bypass rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            '-ExpectedPlanSha256 ''${{ steps.prepare-marketplace.outputs.plan_sha256 }}''',
            '-ExpectedPlanSha256 ''${{ needs.package.outputs.candidate_sha256 }}''')
    } "canonical YAML block|already verified exact archive"

    Assert-ThrowsMatch "missing marketplace credential binding rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '(?m)^\s{10}WOWI_API_TOKEN:\s*\$\{\{ secrets\.WOWI_API_TOKEN \}\}\s*\r?\n', '')
    } "secret 'WOWI_API_TOKEN'"

    Assert-ThrowsMatch "unknown secret reference rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            'secrets.WOWI_API_TOKEN',
            'secrets.WOWI_API_TOKEN_BACKUP')
    } "secret 'WOWI_API_TOKEN'|unapproved"

    Assert-ThrowsMatch "github token context injection rejected" {
        $replacement = '$1' + "`n        env:`n          GH_TOKEN: `${{ github.token }}"
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '(?m)^(\s{8}id: verify-candidate\s*)$', $replacement)
    } "github.token reference|candidate verification step.*canonical YAML block"

    Assert-ThrowsMatch "checkout repository redirect rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            '          fetch-depth: 0',
            "          repository: attacker/controlled`n          fetch-depth: 0")
    } "checkout step"

    Assert-ThrowsMatch "privileged command injection rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            '            -Mode CreateDraft `',
            "          Write-Host `$env:GH_TOKEN`n            -Mode CreateDraft ``")
    } "sensitive step|step inventory"

    Assert-ThrowsMatch "upstream publisher script rewrite rejected" {
        $mutated = & $replaceJob 'github-prepare' {
            param($value)
            $value.Replace(
                '            -OutputPath $env:GITHUB_OUTPUT',
                "            -OutputPath `$env:GITHUB_OUTPUT`n          Set-Content ./scripts/manage-github-release.ps1 'Write-Host replaced'")
        }
        Assert-ReleaseWorkflowBoundary -WorkflowText $mutated
    } "candidate verification step.*canonical YAML block"

    Assert-ThrowsMatch "missing fresh marketplace attempt guard rejected" {
        $step = [regex]::Match(
            (Get-WorkflowJobBlock -WorkflowText $workflowText -JobName 'marketplace-upload').Value,
            '(?ms)^\s{6}- name: Require fresh package attempt before marketplace publication\s*$.*?(?=^\s{6}- name:|\z)')
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Remove($step.Index + (Get-WorkflowJobBlock -WorkflowText $workflowText -JobName 'marketplace-upload').Index, $step.Length)
    } "step inventory"

    Assert-ThrowsMatch "unpinned official action rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            'actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c',
            'actions/download-artifact@v8')
    } "allowlist"

    Assert-ThrowsMatch "alternate uses key rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            '        uses: actions/upload-artifact@',
            '        uses : actions/upload-artifact@')
    } "canonical plain mapping keys"

    Assert-ThrowsMatch "unnamed action step rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace(
            '      - name: Upload exact release candidate',
            '      - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a')
    } "Every release step must be named"

    Assert-ThrowsMatch "fallible candidate verification rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText ($workflowText -replace '(?m)^(\s{6}- name: Verify exact release candidate\s*)$', "`$1`n        continue-on-error: true")
    } "mandatory.*fail closed"

    Assert-ThrowsMatch "ordinary release job timeout drift rejected" {
        $preflightJob = Get-WorkflowJobBlock -WorkflowText $workflowText -JobName 'preflight'
        $mutatedJob = $preflightJob.Value.Replace('    timeout-minutes: 30', '    timeout-minutes: 29')
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Remove($preflightJob.Index, $preflightJob.Length).Insert($preflightJob.Index, $mutatedJob)
    } "preflight.*timeout-minutes: 30"

    Assert-ThrowsMatch "marketplace release job timeout drift rejected" {
        $marketplaceJob = Get-WorkflowJobBlock -WorkflowText $workflowText -JobName 'marketplace-upload'
        $mutatedJob = $marketplaceJob.Value.Replace('    timeout-minutes: 45', '    timeout-minutes: 30')
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Remove($marketplaceJob.Index, $marketplaceJob.Length).Insert($marketplaceJob.Index, $mutatedJob)
    } "marketplace-upload.*timeout-minutes: 45"

    Assert-ThrowsMatch "single-pending release queue rejected" {
        Assert-ReleaseWorkflowBoundary -WorkflowText $workflowText.Replace('queue: max', 'queue: single')
    } "queue: max"
    Write-Host "GitHub release management self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if ([string]::IsNullOrWhiteSpace($Mode)) {
    throw "Missing release-management -Mode."
}
Assert-RepositoryName $Repository
Assert-StatsProReleaseTag -Value $ExpectedTag
if ($Mode -ne "RefuseExisting") {
    Assert-CommitSha $ExpectedCommitSha
}
if ($Mode -in @("CreateDraft", "MarkMarketplaceStarted", "AttachAssets", "Publish")) {
    Assert-RunId $ExpectedRunId
    Assert-RunAttempt $ExpectedRunAttempt
    Assert-LowercaseSha256 -Value $ExpectedArchiveSha256 -Description 'Expected release archive digest'
    Assert-LowercaseSha256 -Value $ExpectedCandidateSha256 -Description 'Expected release candidate digest'
}
if ($AttestationAttempts -lt 1) {
    throw "-AttestationAttempts must be at least 1."
}
if ($TimeoutMinutes -lt 1) {
    throw "-TimeoutMinutes must be at least 1."
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required."
}
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)

switch ($Mode) {
    "RefuseExisting" {
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag -Deadline $deadline
        Assert-NoExistingRelease -Release $release -ExpectedTag $ExpectedTag
        Write-Host "No existing GitHub release marker found for $ExpectedTag."
    }
    "ValidateStart" {
        $notesText = Get-CanonicalFileText -Path $NotesPath -Description "release notes"
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag -Deadline $deadline
        $state = Assert-ReleaseStartState `
            -Release $release `
            -Repository $Repository `
            -ExpectedTag $ExpectedTag `
            -ExpectedCommitSha $ExpectedCommitSha `
            -ExpectedNotes $notesText
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -Deadline $deadline
        Write-Host "Release start state for $ExpectedTag is $state."
    }
    "CreateDraft" {
        $notesText = Get-CanonicalFileText -Path $NotesPath -Description "release notes"
        $manifestText = Get-CanonicalFileText -Path $ManifestPath -Description "validated package manifest"
        $manifestSha256 = Get-LowercaseTextSha256 -Text $manifestText
        $desiredState = Get-ReleaseStateData `
            -SchemaVersion 2 `
            -Phase 'prepared' `
            -Repository $Repository `
            -ExpectedTag $ExpectedTag `
            -ExpectedCommitSha $ExpectedCommitSha `
            -ExpectedRunId $ExpectedRunId `
            -ExpectedRunAttempt $ExpectedRunAttempt `
            -NotesSha256 (Get-LowercaseTextSha256 -Text $notesText) `
            -ManifestSha256 $manifestSha256 `
            -ArchiveSha256 $ExpectedArchiveSha256 `
            -CandidateSha256 $ExpectedCandidateSha256
        $desiredBody = Get-ReleaseBody -State $desiredState -CanonicalNotes $notesText
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag -Deadline $deadline
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -Deadline $deadline
        if ($null -eq $release) {
            Invoke-WithTemporaryReleaseBody -Body $desiredBody -Action {
                param([string]$BodyPath)
                [void](Invoke-GitHubMutationAndAttest `
                    -Description "Draft creation for $ExpectedTag" `
                    -Arguments (Get-CreateDraftGhArguments -Repository $Repository -ExpectedTag $ExpectedTag -NotesPath $BodyPath) `
                    -Repository $Repository `
                    -ExpectedTag $ExpectedTag `
                    -Attempts $AttestationAttempts `
                    -Deadline $deadline `
                    -AssertState {
                        param([object]$Observed)
                        [void](Assert-ReleaseProtocolIdentity -Release $Observed -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'prepared' -ExpectedRunId $ExpectedRunId -ExpectedRunAttempt $ExpectedRunAttempt -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256 -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedCandidateSha256 $ExpectedCandidateSha256)
                        Assert-ExactAssetSet -Release $Observed -ExpectedNames @()
                    })
            }
            Write-Host "Prepared draft release marker created for $ExpectedTag."
        }
        else {
            $claimDisposition = Get-PreparedDraftClaimDisposition `
                -Release $release `
                -Repository $Repository `
                -ExpectedTag $ExpectedTag `
                -ExpectedCommitSha $ExpectedCommitSha `
                -ExpectedNotes $notesText `
                -ExpectedManifestSha256 $manifestSha256 `
                -DesiredBody $desiredBody
            if ($claimDisposition -eq 'already-current') {
                Write-Host "Prepared draft release marker already matches run $ExpectedRunId attempt $ExpectedRunAttempt; no mutation needed."
            }
            else {
                Invoke-WithTemporaryReleaseBody -Body $desiredBody -Action {
                    param([string]$BodyPath)
                    [void](Invoke-GitHubMutationAndAttest `
                        -Description "Prepared draft claim for $ExpectedTag" `
                        -Arguments (Get-EditDraftBodyGhArguments -Repository $Repository -ExpectedTag $ExpectedTag -NotesPath $BodyPath) `
                        -Repository $Repository `
                        -ExpectedTag $ExpectedTag `
                        -Attempts $AttestationAttempts `
                        -Deadline $deadline `
                        -AssertState {
                            param([object]$Observed)
                            [void](Assert-ReleaseProtocolIdentity -Release $Observed -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'prepared' -ExpectedRunId $ExpectedRunId -ExpectedRunAttempt $ExpectedRunAttempt -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256 -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedCandidateSha256 $ExpectedCandidateSha256)
                            Assert-ExactAssetSet -Release $Observed -ExpectedNames @()
                        })
                }
                Write-Host "Prepared draft release marker safely rebound to run $ExpectedRunId attempt $ExpectedRunAttempt."
            }
        }
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -Deadline $deadline
    }
    "MarkMarketplaceStarted" {
        $notesText = Get-CanonicalFileText -Path $NotesPath -Description "release notes"
        $manifestSha256 = Get-LowercaseTextSha256 -Text (Get-CanonicalFileText -Path $ManifestPath -Description "validated package manifest")
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag -Deadline $deadline
        [void](Assert-ReleaseProtocolIdentity -Release $release -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'prepared' -ExpectedRunId $ExpectedRunId -ExpectedRunAttempt $ExpectedRunAttempt -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256 -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedCandidateSha256 $ExpectedCandidateSha256)
        Assert-ExactAssetSet -Release $release -ExpectedNames @()
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -Deadline $deadline
        $startedState = Get-ReleaseStateData -SchemaVersion 2 -Phase 'marketplace-started' -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedRunId $ExpectedRunId -ExpectedRunAttempt $ExpectedRunAttempt -NotesSha256 (Get-LowercaseTextSha256 -Text $notesText) -ManifestSha256 $manifestSha256 -ArchiveSha256 $ExpectedArchiveSha256 -CandidateSha256 $ExpectedCandidateSha256
        $startedBody = Get-ReleaseBody -State $startedState -CanonicalNotes $notesText
        Invoke-WithTemporaryReleaseBody -Body $startedBody -Action {
            param([string]$BodyPath)
            [void](Invoke-GitHubMutationAndAttest `
                -Description "Marketplace-started marker for $ExpectedTag" `
                -Arguments (Get-EditDraftBodyGhArguments -Repository $Repository -ExpectedTag $ExpectedTag -NotesPath $BodyPath) `
                -Repository $Repository `
                -ExpectedTag $ExpectedTag `
                -Attempts $AttestationAttempts `
                -Deadline $deadline `
                -AssertState {
                    param([object]$Observed)
                    [void](Assert-ReleaseProtocolIdentity -Release $Observed -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'marketplace-started' -ExpectedRunId $ExpectedRunId -ExpectedRunAttempt $ExpectedRunAttempt -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256 -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedCandidateSha256 $ExpectedCandidateSha256)
                    Assert-ExactAssetSet -Release $Observed -ExpectedNames @()
                })
        }
        Write-Host "Marketplace publication boundary durably marked for $ExpectedTag."
    }
    "AttachAssets" {
        $paths = Assert-ReleaseAssetPaths -ArchivePath $ArchivePath -ReleaseJsonPath $ReleaseJsonPath -ExpectedTag $ExpectedTag
        [void](Assert-LocalArchiveSha256 -Path $paths.Archive -ExpectedSha256 $ExpectedArchiveSha256)
        $notesText = Get-CanonicalFileText -Path $NotesPath -Description "release notes"
        $manifestSha256 = Get-LowercaseTextSha256 -Text (Get-CanonicalFileText -Path $ManifestPath -Description "validated package manifest")
        $localFiles = @{
            "StatsPro-$ExpectedTag.zip" = $paths.Archive
            "release.json"              = $paths.ReleaseJson
        }
        foreach ($assetName in @("StatsPro-$ExpectedTag.zip", "release.json")) {
            [void](Assert-LocalArchiveSha256 -Path $paths.Archive -ExpectedSha256 $ExpectedArchiveSha256)
            $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag -Deadline $deadline
            [void](Assert-ReleaseProtocolIdentity -Release $release -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'marketplace-started' -ExpectedRunId $ExpectedRunId -ExpectedRunAttempt $ExpectedRunAttempt -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256 -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedCandidateSha256 $ExpectedCandidateSha256)
            Assert-ReleaseAssetSubsetMatchesLocalFiles -Release $release -LocalFiles $localFiles
            if (-not (Test-ContainsOrdinal -Values @(Get-ReleaseAssetNames -Release $release) -Expected $assetName)) {
                [void](Invoke-GitHubMutationAndAttest `
                    -Description "Asset upload '$assetName' for $ExpectedTag" `
                    -Arguments (Get-AttachAssetsGhArguments -Repository $Repository -ExpectedTag $ExpectedTag -AssetPath $localFiles[$assetName]) `
                    -Repository $Repository `
                    -ExpectedTag $ExpectedTag `
                    -Attempts $AttestationAttempts `
                    -Deadline $deadline `
                    -AssertState {
                        param([object]$Observed)
                        [void](Assert-ReleaseProtocolIdentity -Release $Observed -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'marketplace-started' -ExpectedRunId $ExpectedRunId -ExpectedRunAttempt $ExpectedRunAttempt -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256 -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedCandidateSha256 $ExpectedCandidateSha256)
                        Assert-ReleaseAssetSubsetMatchesLocalFiles -Release $Observed -LocalFiles $localFiles
                        if (-not (Test-ContainsOrdinal -Values @(Get-ReleaseAssetNames -Release $Observed) -Expected $assetName)) {
                            throw "Uploaded asset '$assetName' is not visible."
                        }
                    })
            }
        }
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag -Deadline $deadline
        [void](Assert-ReleaseProtocolIdentity -Release $release -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'marketplace-started' -ExpectedRunId $ExpectedRunId -ExpectedRunAttempt $ExpectedRunAttempt -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256 -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedCandidateSha256 $ExpectedCandidateSha256)
        Assert-DraftAssetsMatchLocalFiles -Release $release -ExpectedTag $ExpectedTag -ArchivePath $paths.Archive -ReleaseJsonPath $paths.ReleaseJson
        Write-Host "Validated release assets attached to draft $ExpectedTag."
    }
    "Publish" {
        $paths = Assert-ReleaseAssetPaths -ArchivePath $ArchivePath -ReleaseJsonPath $ReleaseJsonPath -ExpectedTag $ExpectedTag
        [void](Assert-LocalArchiveSha256 -Path $paths.Archive -ExpectedSha256 $ExpectedArchiveSha256)
        $notesText = Get-CanonicalFileText -Path $NotesPath -Description "release notes"
        $manifestSha256 = Get-LowercaseTextSha256 -Text (Get-CanonicalFileText -Path $ManifestPath -Description "validated package manifest")
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag -Deadline $deadline
        [void](Assert-ReleaseProtocolIdentity -Release $release -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'marketplace-started' -ExpectedRunId $ExpectedRunId -ExpectedRunAttempt $ExpectedRunAttempt -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256 -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedCandidateSha256 $ExpectedCandidateSha256)
        Assert-DraftAssetsMatchLocalFiles -Release $release -ExpectedTag $ExpectedTag -ArchivePath $paths.Archive -ReleaseJsonPath $paths.ReleaseJson
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -Deadline $deadline
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag -Deadline $deadline
        [void](Assert-LocalArchiveSha256 -Path $paths.Archive -ExpectedSha256 $ExpectedArchiveSha256)
        [void](Assert-ReleaseProtocolIdentity -Release $release -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'marketplace-started' -ExpectedRunId $ExpectedRunId -ExpectedRunAttempt $ExpectedRunAttempt -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256 -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedCandidateSha256 $ExpectedCandidateSha256)
        Assert-DraftAssetsMatchLocalFiles -Release $release -ExpectedTag $ExpectedTag -ArchivePath $paths.Archive -ReleaseJsonPath $paths.ReleaseJson
        [void](Invoke-GitHubMutationAndAttest `
            -Description "Immutable publication for $ExpectedTag" `
            -Arguments (Get-PublishGhArguments -Repository $Repository -ExpectedTag $ExpectedTag) `
            -Repository $Repository `
            -ExpectedTag $ExpectedTag `
            -Attempts $AttestationAttempts `
            -Deadline $deadline `
            -AssertState {
                param([object]$Observed)
                [void](Assert-PublishedProtocolIdentity -Release $Observed -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedRunId $ExpectedRunId -ExpectedRunAttempt $ExpectedRunAttempt -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256 -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedCandidateSha256 $ExpectedCandidateSha256)
            })
        Invoke-BoundedReadOnlyCheck `
            -Description "Published immutable release attestation for $ExpectedTag" `
            -Attempts $AttestationAttempts `
            -Deadline $deadline `
            -Check {
                param([datetime]$CheckDeadline)
                $published = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag -Deadline $CheckDeadline
                [void](Assert-PublishedProtocolIdentity -Release $published -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedRunId $ExpectedRunId -ExpectedRunAttempt $ExpectedRunAttempt -ExpectedNotes $notesText -ExpectedManifestSha256 $manifestSha256 -ExpectedArchiveSha256 $ExpectedArchiveSha256 -ExpectedCandidateSha256 $ExpectedCandidateSha256)
                Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -Deadline $CheckDeadline
                Invoke-ImmutableReleaseAttestationChecks -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ArchivePath $paths.Archive -ReleaseJsonPath $paths.ReleaseJson -Deadline $CheckDeadline
            }
        Write-Host "Immutable GitHub release published and attested for $ExpectedTag."
    }
    "RetirePrepared" {
        $notesText = Get-CanonicalFileText -Path $NotesPath -Description "release notes"
        $release = Get-GitHubReleaseByTag -Repository $Repository -ExpectedTag $ExpectedTag -Deadline $deadline
        [void](Assert-ReleaseProtocolIdentity -Release $release -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -ExpectedPhase 'prepared' -ExpectedNotes $notesText)
        Assert-ExactAssetSet -Release $release -ExpectedNames @()
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -Deadline $deadline
        [void](Invoke-GitHubMutationAndAttest `
            -Description "Prepared draft retirement for $ExpectedTag" `
            -Arguments (Get-RetirePreparedGhArguments -Repository $Repository -ExpectedTag $ExpectedTag) `
            -Repository $Repository `
            -ExpectedTag $ExpectedTag `
            -Attempts $AttestationAttempts `
            -Deadline $deadline `
            -AssertState {
                param([AllowNull()][object]$Observed)
                if ($null -ne $Observed) {
                    throw "Prepared draft $ExpectedTag still exists after retirement."
                }
            })
        Assert-RemoteTagCommit -Repository $Repository -ExpectedTag $ExpectedTag -ExpectedCommitSha $ExpectedCommitSha -Deadline $deadline
        Write-Host "Safely retired empty prepared draft $ExpectedTag; tag was preserved."
    }
}
