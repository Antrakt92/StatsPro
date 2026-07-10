param(
    [string]$ZipPath,
    [string]$ReleaseJsonPath,
    [string]$ExpectedTag,
    [string]$PackagerProjectVersion,
    [string]$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")),
    [int]$ArchonMaxAgeDays = 3,
    [string]$ToolLockPath = (Join-Path $PSScriptRoot "tool-version-locks.json"),
    [switch]$EnforceToolLocks,
    [switch]$PackageOnly,
    [switch]$WithReleaseJson,
    [switch]$WriteReleaseJson,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "tool-version-locks.ps1")
. (Join-Path $PSScriptRoot "third-party-contract.ps1")

function Invoke-NativeCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @()
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return @{
        ExitCode = $exitCode
        Output   = $output
    }
}

function ConvertFrom-JsonCompat {
    param([string]$Json)

    $command = Get-Command ConvertFrom-Json
    if ($command.Parameters.ContainsKey("Depth")) {
        return ($Json | ConvertFrom-Json -Depth 100)
    }
    return ($Json | ConvertFrom-Json)
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

function Assert-ReleaseTag {
    param([string]$Value)

    if ($Value -notmatch "^v\d+\.\d+\.\d+$") {
        throw "Malformed release tag '$Value'. Expected vX.Y.Z."
    }
}

function Normalize-StatsProZipEntryPath {
    param([string]$Entry)

    if ([string]::IsNullOrWhiteSpace($Entry)) {
        throw "Package contains an empty entry path."
    }
    $path = $Entry -replace "\\", "/"
    if ($path -cne $path.Trim()) {
        throw "Package contains an entry path with leading or trailing whitespace: '$Entry'."
    }
    if ($path.StartsWith("/") -or $path -match "^[A-Za-z]:/" -or $path -match "(^|/)\.\.(/|$)") {
        throw "Package contains unsafe entry path '$Entry'."
    }
    $pathWithoutTrailingSlash = if ($path.EndsWith("/")) { $path.Substring(0, $path.Length - 1) } else { $path }
    if ([string]::IsNullOrWhiteSpace($pathWithoutTrailingSlash)) {
        throw "Package contains an empty entry path."
    }
    foreach ($segment in $pathWithoutTrailingSlash.Split([char[]]@('/'), [System.StringSplitOptions]::None)) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq "." -or $segment -eq "..") {
            throw "Package contains unsafe entry path '$Entry'."
        }
    }
    return $path
}

function Get-ZipEntries {
    param([string]$Path)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        return @($archive.Entries | ForEach-Object { $_.FullName })
    }
    finally {
        $archive.Dispose()
    }
}

function Get-StatsProPackageFileContract {
    $licenseFiles = @(
        Get-StatsProThirdPartyContract |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.LicenseFile) } |
            ForEach-Object { "StatsPro/$($_.LicenseFile)" }
    )
    $requiredFiles = @(
        "StatsPro/CHANGELOG.md",
        "StatsPro/LICENSE",
        "StatsPro/THIRD-PARTY-NOTICES.md"
    ) + $licenseFiles + @(
        "StatsPro/StatsPro.toc",
        "StatsPro/StatsPro.lua",
        "StatsPro/StatsPro_ArchonTargets.lua",
        "StatsPro/textures/logo.png",
        "StatsPro/libs/LibStub/LibStub.lua",
        "StatsPro/libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
        "StatsPro/libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua"
    )
    $textFiles = @($requiredFiles | Where-Object { $_ -ne "StatsPro/textures/logo.png" })
    return [pscustomobject]@{
        RequiredFiles = $requiredFiles
        AllowedFiles  = $requiredFiles
        TextFiles     = $textFiles
        SourceSubstitutions = @(
            # SYNC: This is the executable build discriminator consumed by StatsPro.lua.
            [pscustomobject]@{
                Path          = "StatsPro/StatsPro.lua"
                Token         = "@project-version@"
                ExpectedCount = 1
            }
        )
    }
}

function Assert-StatsProPackageEntries {
    param([string[]]$Entries)

    $normalized = @($Entries | ForEach-Object { Normalize-StatsProZipEntryPath $_ })
    if ($normalized.Count -eq 0) {
        throw "Package contains no entries."
    }

    $roots = @($normalized | ForEach-Object { ($_ -split "/", 2)[0] } | Sort-Object -Unique)
    if ($roots.Count -ne 1 -or $roots[0] -ne "StatsPro") {
        throw "Package must contain exactly one root directory named StatsPro. Found: $($roots -join ', ')"
    }

    $fileEntries = @($normalized | Where-Object { -not $_.EndsWith("/") })
    $fileSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in $fileEntries) {
        if (-not $fileSet.Add($entry)) {
            throw "Package contains duplicate file entry $entry."
        }
    }

    $contract = Get-StatsProPackageFileContract
    foreach ($required in $contract.RequiredFiles) {
        if (-not $fileSet.Contains($required)) {
            throw "Package is missing required file $required."
        }
    }

    $allowedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($allowed in $contract.AllowedFiles) {
        [void]$allowedFiles.Add($allowed)
    }
    foreach ($entry in $fileEntries) {
        if (-not $allowedFiles.Contains($entry)) {
            if ($entry.StartsWith("StatsPro/libs/", [System.StringComparison]::Ordinal)) {
                throw "Package contains unexpected packaged lib file $entry."
            }
            throw "Package contains unexpected packaged file $entry."
        }
    }
}

function Expand-StatsProPackageToTemp {
    param([string]$Path)

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-package-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
        Expand-Archive -LiteralPath $Path -DestinationPath $tempDir -Force
        $packageRoot = Join-Path $tempDir "StatsPro"
        if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
            throw "Expanded package is missing StatsPro root directory."
        }
        return [pscustomobject]@{
            TempDir     = $tempDir
            PackageRoot = $packageRoot
        }
    }
    catch {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Get-SingleRegexMatchFromText {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Description
    )

    $matches = [regex]::Matches($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($matches.Count -eq 0) {
        throw "Missing $Description."
    }
    if ($matches.Count -gt 1) {
        throw "Found multiple $Description values."
    }
    return $matches[0].Groups[1].Value
}

function Get-TocInterfaceValues {
    param([string]$TocPath)

    $tocText = Get-Content -LiteralPath $TocPath -Raw -Encoding UTF8
    $interfaceText = Get-SingleRegexMatchFromText -Text $tocText -Pattern "^##\s+Interface:\s*(.+?)\s*$" -Description "TOC Interface"
    $interfaces = @($interfaceText -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    if ($interfaces.Count -eq 0) {
        throw "TOC Interface contains no values."
    }
    foreach ($interface in $interfaces) {
        if ($interface -notmatch "^\d+$") {
            throw "TOC Interface value '$interface' is not numeric."
        }
    }
    return @($interfaces | ForEach-Object { [int]$_ })
}

function Assert-PackagedStatsProVersionMetadata {
    param(
        [string]$PackageRoot,
        [string]$ExpectedTag,
        [string]$PackagerProjectVersion
    )

    Assert-ReleaseTag $ExpectedTag
    Assert-PackagerProjectVersion $PackagerProjectVersion
    $expectedVersion = $ExpectedTag.Substring(1)
    $tocPath = Join-Path $PackageRoot "StatsPro.toc"
    $luaPath = Join-Path $PackageRoot "StatsPro.lua"
    $tocText = Get-Content -LiteralPath $tocPath -Raw -Encoding UTF8
    $luaText = Get-Content -LiteralPath $luaPath -Raw -Encoding UTF8

    $tocVersion = Get-SingleRegexMatchFromText -Text $tocText -Pattern "^##\s+Version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$" -Description "TOC Version"
    if ($tocVersion -ne $expectedVersion) {
        throw "Packaged TOC Version is $tocVersion, expected $expectedVersion."
    }

    $currentRelease = Get-SingleRegexMatchFromText -Text $luaText -Pattern 'CURRENT_RELEASE\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"' -Description "StatsPro.lua CURRENT_RELEASE"
    if ($currentRelease -ne $expectedVersion) {
        throw "Packaged CURRENT_RELEASE is $currentRelease, expected $expectedVersion."
    }

    $packagedBuildVersion = Get-SingleRegexMatchFromText -Text $luaText `
        -Pattern '^local\s+ADDON_VERSION\s*=\s*addon\.ResolveAddonVersion\("([^"]+)",' `
        -Description "StatsPro.lua executable Packager project version"
    if ($packagedBuildVersion -ne $PackagerProjectVersion) {
        throw "Packaged executable Packager project version is $packagedBuildVersion, expected $PackagerProjectVersion."
    }
    if ($luaText.Contains("@project-version@")) {
        throw "Packaged StatsPro.lua still contains an unresolved project-version token."
    }

    return [pscustomobject]@{
        Version    = $expectedVersion
        Interfaces = @(Get-TocInterfaceValues -TocPath $tocPath)
    }
}

function Assert-PackagerProjectVersion {
    param([string]$Value)

    if ($Value -notmatch '^v\d+\.\d+\.\d+(?:-\d+-g[0-9a-fA-F]{7,40})?$') {
        throw "Malformed Packager project version '$Value'. Expected vX.Y.Z or vX.Y.Z-N-gHASH."
    }
}

function ConvertTo-StatsProNormalizedText {
    param(
        [string]$Path,
        [string]$ContractPath
    )

    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    try {
        $text = $utf8.GetString([System.IO.File]::ReadAllBytes($Path))
    }
    catch {
        throw "Package source-fidelity text file $ContractPath is not valid UTF-8: $($_.Exception.Message)"
    }
    if ($ContractPath -eq "StatsPro/StatsPro.toc" -and $text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }
    return (($text -replace "`r`n", "`n") -replace "`r", "`n")
}

function ConvertTo-StatsProExpectedPackagedText {
    param(
        [string]$SourceText,
        [string]$ContractPath,
        [string]$ProjectVersion,
        [object]$Contract = (Get-StatsProPackageFileContract)
    )

    $expectedText = $SourceText
    foreach ($substitution in @($Contract.SourceSubstitutions | Where-Object { $_.Path -eq $ContractPath })) {
        $parts = $expectedText.Split([string[]]@($substitution.Token), [System.StringSplitOptions]::None)
        $count = $parts.Length - 1
        if ($count -ne $substitution.ExpectedCount) {
            throw "Package source-fidelity contract expected $($substitution.ExpectedCount) '$($substitution.Token)' token(s) in $ContractPath, found $count."
        }
        $expectedText = $expectedText.Replace($substitution.Token, $ProjectVersion)
    }
    return $expectedText
}

function Get-StatsProTopChangelogEntryFromText {
    param([string]$Text)

    # SYNC: check-release-version.ps1::Get-TopChangelogEntry prepares the release-only manual changelog.
    $headingDash = [regex]::Escape([string][char]0x2014)
    $headingPattern = "^##\s+([0-9]+\.[0-9]+\.[0-9]+)\s+-\s+([0-9]{2}-(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)-[0-9]{4})\s+$headingDash\s+\S.*$"
    $headingMatches = [regex]::Matches($Text, $headingPattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($headingMatches.Count -eq 0) {
        throw "Package source-fidelity changelog has no release heading."
    }
    $firstHeading = $headingMatches[0]
    $endIndex = if ($headingMatches.Count -gt 1) { $headingMatches[1].Index } else { $Text.Length }
    $prefix = $Text.Substring(0, $firstHeading.Index).TrimEnd()
    $entry = $Text.Substring($firstHeading.Index, $endIndex - $firstHeading.Index).TrimEnd()
    if (-not [string]::IsNullOrWhiteSpace($prefix)) {
        return "$prefix`n`n$entry`n"
    }
    return "$entry`n"
}

function Get-StatsProBytesSha256 {
    param([byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString("X2") }) -join "")
    }
    finally {
        $sha.Dispose()
    }
}

function Get-StatsProTextSha256 {
    param([string]$Text)

    return Get-StatsProBytesSha256 -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Sort-StatsProOrdinalStrings {
    param([string[]]$Values)

    $copy = [string[]]@($Values)
    [System.Array]::Sort($copy, [System.StringComparer]::Ordinal)
    return $copy
}

function Assert-StatsProOrdinalPathSet {
    param(
        [string[]]$Expected,
        [string[]]$Actual,
        [string]$Description
    )

    $expectedSorted = @(Sort-StatsProOrdinalStrings -Values $Expected)
    $actualSorted = @(Sort-StatsProOrdinalStrings -Values $Actual)
    if ($expectedSorted.Count -ne $actualSorted.Count) {
        throw "$Description path count is $($actualSorted.Count), expected $($expectedSorted.Count). Actual: $($actualSorted -join ', ')"
    }
    for ($index = 0; $index -lt $expectedSorted.Count; $index++) {
        if (-not [System.StringComparer]::Ordinal.Equals($expectedSorted[$index], $actualSorted[$index])) {
            throw "$Description path mismatch at entry $($index + 1): '$($actualSorted[$index])', expected '$($expectedSorted[$index])'."
        }
    }
}

function Get-StatsProExpandedPackageFilePaths {
    param([string]$PackageRoot)

    $resolvedRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
    return @(
        Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File |
            ForEach-Object {
                $relative = [System.IO.Path]::GetRelativePath($resolvedRoot, $_.FullName) -replace "\\", "/"
                $contractPath = Normalize-StatsProZipEntryPath "StatsPro/$relative"
                [pscustomobject]@{
                    ContractPath = $contractPath
                    FullName     = $_.FullName
                }
            }
    )
}

function Resolve-StatsProSourceContractFile {
    param(
        [string]$SourceRoot,
        [string]$RelativePath
    )

    $current = Get-Item -LiteralPath (Resolve-Path -LiteralPath $SourceRoot).Path
    foreach ($segment in ($RelativePath -split "/")) {
        $matches = @(Get-ChildItem -LiteralPath $current.FullName -Force | Where-Object {
            [System.StringComparer]::OrdinalIgnoreCase.Equals($_.Name, $segment)
        })
        if ($matches.Count -eq 0) {
            throw "Package source-fidelity source file is missing: StatsPro/$RelativePath."
        }
        if ($matches.Count -gt 1) {
            throw "Package source-fidelity source path is ambiguous at '$segment' in StatsPro/$RelativePath."
        }
        if (-not [System.StringComparer]::Ordinal.Equals($matches[0].Name, $segment)) {
            throw "Package source-fidelity source path case mismatch: '$($matches[0].Name)', expected '$segment' in StatsPro/$RelativePath."
        }
        $current = $matches[0]
    }
    if (-not $current.PSIsContainer -and (Test-Path -LiteralPath $current.FullName -PathType Leaf)) {
        return $current
    }
    throw "Package source-fidelity source file is missing: StatsPro/$RelativePath."
}

function Assert-StatsProPackageSourceFidelity {
    param(
        [string]$PackageRoot,
        [string]$SourceRoot,
        [string]$ProjectVersion
    )

    Assert-PackagerProjectVersion $ProjectVersion
    $contract = Get-StatsProPackageFileContract
    $expectedPaths = @($contract.RequiredFiles)
    $packageFiles = @(Get-StatsProExpandedPackageFilePaths -PackageRoot $PackageRoot)
    $actualPaths = @($packageFiles | ForEach-Object { $_.ContractPath })
    Assert-StatsProOrdinalPathSet -Expected $expectedPaths -Actual $actualPaths -Description "Expanded package source-fidelity"

    $packageByPath = @{}
    foreach ($packageFile in $packageFiles) {
        if ($packageByPath.ContainsKey($packageFile.ContractPath)) {
            throw "Expanded package contains duplicate canonical path $($packageFile.ContractPath)."
        }
        $packageByPath[$packageFile.ContractPath] = $packageFile.FullName
    }
    $textFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in $contract.TextFiles) {
        [void]$textFiles.Add($path)
    }

    foreach ($contractPath in $expectedPaths) {
        $relative = $contractPath.Substring("StatsPro/".Length)
        $sourceItem = Resolve-StatsProSourceContractFile -SourceRoot $SourceRoot -RelativePath $relative

        $packagePath = $packageByPath[$contractPath]
        if ($textFiles.Contains($contractPath)) {
            $sourceText = ConvertTo-StatsProNormalizedText -Path $sourceItem.FullName -ContractPath $contractPath
            $expectedText = ConvertTo-StatsProExpectedPackagedText -SourceText $sourceText -ContractPath $contractPath -ProjectVersion $ProjectVersion -Contract $contract
            $actualText = ConvertTo-StatsProNormalizedText -Path $packagePath -ContractPath $contractPath
            $expectedAlternatives = @($expectedText)
            if ($contractPath -eq "StatsPro/CHANGELOG.md") {
                $topChangelogEntry = Get-StatsProTopChangelogEntryFromText -Text $expectedText
                if (-not [System.StringComparer]::Ordinal.Equals($topChangelogEntry, $expectedText)) {
                    $expectedAlternatives += $topChangelogEntry
                }
            }
            $matched = $false
            foreach ($expectedAlternative in $expectedAlternatives) {
                if ([System.StringComparer]::Ordinal.Equals($expectedAlternative, $actualText)) {
                    $matched = $true
                    break
                }
            }
            if (-not $matched) {
                $expectedHashes = @($expectedAlternatives | ForEach-Object { Get-StatsProTextSha256 $_ })
                throw "Package source-fidelity mismatch for ${contractPath}: normalized SHA256 $(Get-StatsProTextSha256 $actualText), expected one of $($expectedHashes -join ', ')."
            }
        }
        else {
            $expectedBytes = [System.IO.File]::ReadAllBytes($sourceItem.FullName)
            $actualBytes = [System.IO.File]::ReadAllBytes($packagePath)
            $expectedHash = Get-StatsProBytesSha256 -Bytes $expectedBytes
            $actualHash = Get-StatsProBytesSha256 -Bytes $actualBytes
            if (-not [System.StringComparer]::Ordinal.Equals($expectedHash, $actualHash)) {
                throw "Package source-fidelity mismatch for ${contractPath}: SHA256 $actualHash, expected $expectedHash."
            }
        }
    }
}

function Get-PackagedRuntimeLuaPathsFromToc {
    param([string]$PackageRoot)

    $tocPath = Join-Path $PackageRoot "StatsPro.toc"
    $tocText = ConvertTo-StatsProNormalizedText -Path $tocPath -ContractPath "StatsPro/StatsPro.toc"
    $refs = @()
    foreach ($line in ($tocText -split "`n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }
        if ($trimmed -match '(?i)\.lua$') {
            $contractPath = Normalize-StatsProZipEntryPath ("StatsPro/" + ($trimmed -replace "\\", "/"))
            $refs += $contractPath.Substring("StatsPro/".Length)
        }
    }
    if ($refs.Count -eq 0) {
        throw "Packaged StatsPro.toc contains no runtime Lua files."
    }
    return @($refs)
}

function Resolve-Luac51 {
    $candidates = @(
        (Get-Command "luac5.1" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
        (Get-Command "luac" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
        "C:\ProgramData\chocolatey\lib\lua51\tools\luac5.1.exe"
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not $seen.Add($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $result = Invoke-NativeCapture -FilePath $candidate -Arguments @("-v")
        if ($result.ExitCode -eq 0 -and ($result.Output -join "`n") -match 'Lua 5\.1(?:\.|\s|$)') {
            return $candidate
        }
    }
    throw "luac5.1 is required to syntax-check packaged runtime Lua."
}

function Assert-Luac51VersionLock {
    param([string]$LuacPath, [string]$LockPath)

    $locks = Read-StatsProToolLocks -Path $LockPath
    $result = Invoke-NativeCapture -FilePath $LuacPath -Arguments @("-v")
    if ($result.ExitCode -ne 0) {
        throw "luac5.1 -v exited with code $($result.ExitCode): $($result.Output -join ' ')"
    }
    Assert-StatsProCommandVersionText -Label "luac5.1" -Text ($result.Output -join "`n") -Pattern (Get-StatsProLockedCommandPattern -Locks $locks -CommandName "luac5.1")
}

function Assert-PackagedRuntimeLuaSyntax {
    param(
        [string]$PackageRoot,
        [string]$LuacPath,
        [bool]$CheckToolLocks
    )

    if ($CheckToolLocks) {
        Assert-Luac51VersionLock -LuacPath $LuacPath -LockPath $ToolLockPath
    }
    $refs = @(Get-PackagedRuntimeLuaPathsFromToc -PackageRoot $PackageRoot)
    $packagedLua = @(
        Get-ChildItem -LiteralPath $PackageRoot -Recurse -File -Filter "*.lua" |
            ForEach-Object { [System.IO.Path]::GetRelativePath($PackageRoot, $_.FullName) -replace "\\", "/" }
    )
    Assert-StatsProOrdinalPathSet -Expected $refs -Actual $packagedLua -Description "Packaged runtime Lua"

    foreach ($relative in (Sort-StatsProOrdinalStrings -Values $refs)) {
        $path = Join-Path $PackageRoot ($relative -replace "/", [System.IO.Path]::DirectorySeparatorChar)
        $result = Invoke-NativeCapture -FilePath $LuacPath -Arguments @("-p", $path)
        if ($result.ExitCode -ne 0) {
            throw "Packaged runtime Lua syntax failed for ${relative}: $($result.Output -join ' ')"
        }
    }
}

function Assert-StatsProReleaseJson {
    param(
        [string]$JsonText,
        [string]$ExpectedTag,
        [int[]]$ExpectedInterfaces = @(120007, 120100)
    )

    Assert-ReleaseTag $ExpectedTag
    $json = ConvertFrom-JsonCompat $JsonText
    $releases = @($json.releases)
    if ($releases.Count -eq 0) {
        throw "release.json contains no releases."
    }
    $statsProReleases = @($releases | Where-Object { $_.name -eq "StatsPro" })
    if ($statsProReleases.Count -ne 1) {
        throw "release.json must contain exactly one StatsPro release, found $($statsProReleases.Count)."
    }

    $release = $statsProReleases[0]
    if ($release.version -ne $ExpectedTag) {
        throw "release.json StatsPro version is '$($release.version)', expected '$ExpectedTag'."
    }
    $expectedZip = "StatsPro-$ExpectedTag.zip"
    if ($release.filename -ne $expectedZip) {
        throw "release.json StatsPro filename is '$($release.filename)', expected '$expectedZip'."
    }
    if ($null -eq $release.nolib) {
        throw "release.json StatsPro release is missing nolib state."
    }
    if ([bool]$release.nolib) {
        throw "release.json StatsPro release must be a lib-inclusive package, got nolib=true."
    }

    $metadata = @($release.metadata)
    $expectedSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($interface in $ExpectedInterfaces) {
        [void]$expectedSet.Add([int]$interface)
    }
    if ($metadata.Count -ne $expectedSet.Count) {
        throw "release.json metadata entry count is $($metadata.Count), expected $($expectedSet.Count)."
    }
    $actualSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($entry in $metadata) {
        if ($entry.flavor -ne "mainline") {
            throw "release.json metadata flavor is '$($entry.flavor)', expected 'mainline'."
        }
        if ($null -eq $entry.interface) {
            throw "release.json metadata entry is missing interface."
        }
        [void]$actualSet.Add([int]$entry.interface)
    }
    if ($actualSet.Count -ne $expectedSet.Count) {
        throw "release.json interface count is $($actualSet.Count), expected $($expectedSet.Count)."
    }
    foreach ($interface in $expectedSet) {
        if (-not $actualSet.Contains($interface)) {
            throw "release.json is missing interface $interface."
        }
    }
}

function New-StatsProReleaseJsonText {
    param(
        [string]$ExpectedTag,
        [int[]]$Interfaces
    )

    Assert-ReleaseTag $ExpectedTag
    if ($Interfaces.Count -eq 0) {
        throw "Cannot create release.json without TOC Interface values."
    }
    $metadata = @($Interfaces | ForEach-Object {
        [ordered]@{
            flavor    = "mainline"
            interface = [int]$_
        }
    })
    $document = [ordered]@{
        releases = @(
            [ordered]@{
                name     = "StatsPro"
                version  = $ExpectedTag
                filename = "StatsPro-$ExpectedTag.zip"
                nolib    = $false
                metadata = $metadata
            }
        )
    }
    return ($document | ConvertTo-Json -Depth 8 -Compress)
}

function Write-StatsProReleaseJson {
    param(
        [string]$Path,
        [string]$ExpectedTag,
        [int[]]$Interfaces
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Missing release.json output path."
    }
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = New-StatsProReleaseJsonText -ExpectedTag $ExpectedTag -Interfaces $Interfaces
    [System.IO.File]::WriteAllText($Path, "$json`n", [System.Text.UTF8Encoding]::new($false))
}

function Resolve-Lua51 {
    $command = Get-Command "lua5.1" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    throw "lua5.1 is required for Archon target validation."
}

function Assert-Lua51VersionLock {
    param([string]$LuaPath, [string]$LockPath)
    $locks = Read-StatsProToolLocks -Path $LockPath
    $result = Invoke-NativeCapture -FilePath $LuaPath -Arguments @("-v")
    if ($result.ExitCode -ne 0) {
        throw "lua5.1 -v exited with code $($result.ExitCode): $($result.Output -join ' ')"
    }
    Assert-StatsProCommandVersionText -Label "lua5.1" -Text ($result.Output -join "`n") -Pattern (Get-StatsProLockedCommandPattern -Locks $locks -CommandName "lua5.1")
}

function Invoke-ArchonTargetValidator {
    param(
        [string]$LuaPath,
        [string]$ValidatorPath,
        [string[]]$Arguments
    )

    $result = Invoke-NativeCapture -FilePath $LuaPath -Arguments (@($ValidatorPath) + $Arguments)
    if ($result.ExitCode -ne 0) {
        throw "Archon target validator failed with code $($result.ExitCode): $($result.Output -join ' ')"
    }
    return @($result.Output)
}

function Get-ArchonSemanticLines {
    param(
        [string]$LuaPath,
        [string]$ValidatorPath,
        [string]$TargetPath,
        [string]$StatsProLuaPath
    )

    $output = Invoke-ArchonTargetValidator -LuaPath $LuaPath -ValidatorPath $ValidatorPath -Arguments @(
        "--path", $TargetPath,
        "--statspro-lua", $StatsProLuaPath,
        "--semantic-lines",
        "--allow-stale"
    )
    return @($output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

function Assert-PackagedArchonTargets {
    param(
        [string]$PackageRoot,
        [string]$SourceRoot,
        [int]$MaxAgeDays
    )

    $lua = Resolve-Lua51
    if ($EnforceToolLocks) {
        Assert-Lua51VersionLock -LuaPath $lua -LockPath $ToolLockPath
    }
    $validator = Join-Path $SourceRoot "scripts\check-archon-targets.lua"
    if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
        throw "Missing Archon target validator: $validator"
    }

    $packageTarget = Join-Path $PackageRoot "StatsPro_ArchonTargets.lua"
    $packageLua = Join-Path $PackageRoot "StatsPro.lua"
    Invoke-ArchonTargetValidator -LuaPath $lua -ValidatorPath $validator -Arguments @(
        "--path", $packageTarget,
        "--statspro-lua", $packageLua,
        "--max-age-days", [string]$MaxAgeDays
    ) | Out-Null

    $sourceTarget = Join-Path $SourceRoot "StatsPro_ArchonTargets.lua"
    $sourceLua = Join-Path $SourceRoot "StatsPro.lua"
    $packageLines = @(Get-ArchonSemanticLines -LuaPath $lua -ValidatorPath $validator -TargetPath $packageTarget -StatsProLuaPath $packageLua)
    $sourceLines = @(Get-ArchonSemanticLines -LuaPath $lua -ValidatorPath $validator -TargetPath $sourceTarget -StatsProLuaPath $sourceLua)
    if ($packageLines.Count -ne $sourceLines.Count) {
        throw "Packaged Archon target semantic line count $($packageLines.Count) does not match source count $($sourceLines.Count)."
    }
    for ($index = 0; $index -lt $sourceLines.Count; $index++) {
        if ($packageLines[$index] -ne $sourceLines[$index]) {
            throw "Packaged Archon target semantic mismatch at entry $($index + 1)."
        }
    }
}

function Assert-StatsProReleaseArtifact {
    param(
        [string]$ZipPath,
        [string]$ReleaseJsonPath,
        [string]$ExpectedTag,
        [string]$PackagerProjectVersion,
        [string]$SourceRoot,
        [int]$ArchonMaxAgeDays,
        [bool]$PackageOnly,
        [bool]$WithReleaseJson,
        [bool]$WriteReleaseJson
    )

    if ($PackageOnly -and $WithReleaseJson) {
        throw "Choose only one of -PackageOnly or -WithReleaseJson."
    }
    if (-not $PackageOnly -and -not $WithReleaseJson) {
        $WithReleaseJson = -not [string]::IsNullOrWhiteSpace($ReleaseJsonPath)
        $PackageOnly = -not $WithReleaseJson
    }

    if ([string]::IsNullOrWhiteSpace($ZipPath)) {
        throw "Missing -ZipPath."
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedTag)) {
        throw "Missing -ExpectedTag."
    }
    Assert-ReleaseTag $ExpectedTag
    if ([string]::IsNullOrWhiteSpace($PackagerProjectVersion)) {
        $PackagerProjectVersion = $ExpectedTag
    }
    Assert-PackagerProjectVersion $PackagerProjectVersion
    $zipFullPath = (Resolve-Path $ZipPath).Path
    $sourceFullPath = (Resolve-Path $SourceRoot).Path

    $entries = Get-ZipEntries -Path $zipFullPath
    Assert-StatsProPackageEntries -Entries $entries

    $expanded = $null
    try {
        $expanded = Expand-StatsProPackageToTemp -Path $zipFullPath
        $luac = Resolve-Luac51
        Assert-PackagedRuntimeLuaSyntax -PackageRoot $expanded.PackageRoot -LuacPath $luac -CheckToolLocks:$EnforceToolLocks.IsPresent
        Assert-StatsProPackageSourceFidelity -PackageRoot $expanded.PackageRoot -SourceRoot $sourceFullPath -ProjectVersion $PackagerProjectVersion
        $versionMetadata = Assert-PackagedStatsProVersionMetadata `
            -PackageRoot $expanded.PackageRoot `
            -ExpectedTag $ExpectedTag `
            -PackagerProjectVersion $PackagerProjectVersion
        Assert-StatsProThirdPartyMaterials -Root $expanded.PackageRoot
        Assert-PackagedArchonTargets -PackageRoot $expanded.PackageRoot -SourceRoot $sourceFullPath -MaxAgeDays $ArchonMaxAgeDays
        if ($WithReleaseJson) {
            if ([string]::IsNullOrWhiteSpace($ReleaseJsonPath)) {
                throw "-WithReleaseJson requires -ReleaseJsonPath."
            }
            if ($WriteReleaseJson) {
                Write-StatsProReleaseJson -Path $ReleaseJsonPath -ExpectedTag $ExpectedTag -Interfaces $versionMetadata.Interfaces
            }
            $releaseJsonText = Get-Content -LiteralPath (Resolve-Path $ReleaseJsonPath).Path -Raw -Encoding UTF8
            Assert-StatsProReleaseJson -JsonText $releaseJsonText -ExpectedTag $ExpectedTag -ExpectedInterfaces $versionMetadata.Interfaces
        }
    }
    finally {
        if ($expanded -and (Test-Path -LiteralPath $expanded.TempDir)) {
            Remove-Item -LiteralPath $expanded.TempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "StatsPro release artifact checks passed for $ExpectedTag."
}

function New-TestPackageZip {
    param(
        [string]$SourceRoot,
        [string]$ZipPath,
        [string]$PackagerProjectVersion
    )

    Assert-PackagerProjectVersion $PackagerProjectVersion
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }
    $archive = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $contract = Get-StatsProPackageFileContract
        $textFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($textFile in $contract.TextFiles) {
            [void]$textFiles.Add($textFile)
        }
        foreach ($file in $contract.RequiredFiles) {
            $relative = $file.Substring("StatsPro/".Length)
            $sourceFile = Join-Path $SourceRoot ($relative -replace "/", [System.IO.Path]::DirectorySeparatorChar)
            if ($textFiles.Contains($file)) {
                $sourceText = ConvertTo-StatsProNormalizedText -Path $sourceFile -ContractPath $file
                $packagedText = ConvertTo-StatsProExpectedPackagedText -SourceText $sourceText -ContractPath $file -ProjectVersion $PackagerProjectVersion -Contract $contract
                $packagedText = $packagedText -replace "`n", "`r`n"
                $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($packagedText)
                $entry = $archive.CreateEntry($file)
                $stream = $entry.Open()
                try {
                    $stream.Write($bytes, 0, $bytes.Length)
                }
                finally {
                    $stream.Dispose()
                }
            }
            else {
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $sourceFile, $file) | Out-Null
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-SourceVersionTag {
    param([string]$Root)

    $tocText = Get-Content -LiteralPath (Join-Path $Root "StatsPro.toc") -Raw -Encoding UTF8
    $version = Get-SingleRegexMatchFromText -Text $tocText -Pattern "^##\s+Version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$" -Description "TOC Version"
    return "v$version"
}

function Invoke-SelfTest {
    $sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $tag = Get-SourceVersionTag -Root $sourceRoot
    $interfaces = @(Get-TocInterfaceValues -TocPath (Join-Path $sourceRoot "StatsPro.toc"))
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-artifact-test-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
        [void](Normalize-StatsProZipEntryPath "StatsPro/StatsPro.lua")
        Assert-ThrowsMatch "unsafe zip path rejected" {
            [void](Normalize-StatsProZipEntryPath "StatsPro/../evil.lua")
        } "unsafe"

        $zip = Join-Path $tempDir "StatsPro-$tag.zip"
        New-TestPackageZip -SourceRoot $sourceRoot -ZipPath $zip -PackagerProjectVersion $tag
        $jsonPath = Join-Path $tempDir "release.json"
        Assert-StatsProReleaseArtifact -ZipPath $zip -ReleaseJsonPath $jsonPath -ExpectedTag $tag -SourceRoot $sourceRoot -ArchonMaxAgeDays 99999 -PackageOnly:$false -WithReleaseJson:$true -WriteReleaseJson:$true
        $expectedJson = New-StatsProReleaseJsonText -ExpectedTag $tag -Interfaces $interfaces
        if ((Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8).Trim() -ne $expectedJson) {
            throw "Generated release.json is not deterministic."
        }
        Assert-StatsProReleaseArtifact -ZipPath $zip -ExpectedTag $tag -SourceRoot $sourceRoot -ArchonMaxAgeDays 99999 -PackageOnly:$true -WithReleaseJson:$false -WriteReleaseJson:$false
        $branchProjectVersion = "$tag-12-gabcdef0"
        $branchZip = Join-Path $tempDir "StatsPro-$branchProjectVersion.zip"
        New-TestPackageZip -SourceRoot $sourceRoot -ZipPath $branchZip -PackagerProjectVersion $branchProjectVersion
        Assert-StatsProReleaseArtifact -ZipPath $branchZip -ExpectedTag $tag -PackagerProjectVersion $branchProjectVersion -SourceRoot $sourceRoot -ArchonMaxAgeDays 99999 -PackageOnly:$true -WithReleaseJson:$false

        if ((Normalize-StatsProZipEntryPath "StatsPro\StatsPro.lua") -ne "StatsPro/StatsPro.lua") {
            throw "Backslash package path normalization failed."
        }
        Assert-ThrowsMatch "unsafe dot-segment zip path rejected" {
            [void](Normalize-StatsProZipEntryPath "StatsPro/./StatsPro.lua")
        } "unsafe"
        Assert-ThrowsMatch "unsafe duplicate-separator zip path rejected" {
            [void](Normalize-StatsProZipEntryPath "StatsPro//StatsPro.lua")
        } "unsafe"
        Assert-ThrowsMatch "rooted zip path rejected" {
            [void](Normalize-StatsProZipEntryPath "/StatsPro/StatsPro.lua")
        } "unsafe"
        Assert-ThrowsMatch "drive zip path rejected" {
            [void](Normalize-StatsProZipEntryPath "C:/StatsPro/StatsPro.lua")
        } "unsafe"
        Assert-ThrowsMatch "whitespace zip path rejected" {
            [void](Normalize-StatsProZipEntryPath " StatsPro/StatsPro.lua")
        } "whitespace"
        Assert-ThrowsMatch "duplicate zip file entry rejected" {
            Assert-StatsProPackageEntries -Entries ((Get-StatsProPackageFileContract).RequiredFiles + "StatsPro/StatsPro.lua")
        } "duplicate"
        Assert-ThrowsMatch "malformed Packager project version rejected" {
            Assert-PackagerProjectVersion "v1.2.3-dirty"
        } "Malformed"
        Assert-ThrowsMatch "source substitution token count drift rejected" {
            [void](ConvertTo-StatsProExpectedPackagedText -SourceText "@project-version@ @project-version@" -ContractPath "StatsPro/StatsPro.lua" -ProjectVersion "v1.2.3")
        } "expected 1"

        $mutationPackage = Expand-StatsProPackageToTemp -Path $zip
        try {
            $mutationRoot = $mutationPackage.PackageRoot
            $luac = Resolve-Luac51
            Assert-PackagedRuntimeLuaSyntax -PackageRoot $mutationRoot -LuacPath $luac -CheckToolLocks:$false
            Assert-StatsProPackageSourceFidelity -PackageRoot $mutationRoot -SourceRoot $sourceRoot -ProjectVersion $tag

            $corePath = Join-Path $mutationRoot "StatsPro.lua"
            $coreBytes = [System.IO.File]::ReadAllBytes($corePath)
            [System.IO.File]::AppendAllText($corePath, "`r`n-- syntactically valid mutation", [System.Text.UTF8Encoding]::new($false))
            Assert-ThrowsMatch "core source-fidelity mutation rejected" {
                Assert-StatsProPackageSourceFidelity -PackageRoot $mutationRoot -SourceRoot $sourceRoot -ProjectVersion $tag
            } "source-fidelity mismatch.*StatsPro/StatsPro\.lua"
            [System.IO.File]::WriteAllBytes($corePath, $coreBytes)

            $coreText = [System.IO.File]::ReadAllText($corePath)
            $inconsistentVersionText = ([regex]::new([regex]::Escape($tag))).Replace($coreText, "v9.9.9", 1)
            [System.IO.File]::WriteAllText($corePath, $inconsistentVersionText, [System.Text.UTF8Encoding]::new($false))
            Assert-ThrowsMatch "inconsistent executable Packager version rejected" {
                [void](Assert-PackagedStatsProVersionMetadata `
                    -PackageRoot $mutationRoot `
                    -ExpectedTag $tag `
                    -PackagerProjectVersion $tag)
            } "Packaged executable Packager project version is v9\.9\.9"
            Assert-ThrowsMatch "inconsistent project-version substitution rejected" {
                Assert-StatsProPackageSourceFidelity -PackageRoot $mutationRoot -SourceRoot $sourceRoot -ProjectVersion $tag
            } "source-fidelity mismatch.*StatsPro/StatsPro\.lua"
            [System.IO.File]::WriteAllBytes($corePath, $coreBytes)

            [System.IO.File]::WriteAllText($corePath, "local =`n", [System.Text.UTF8Encoding]::new($false))
            Assert-ThrowsMatch "invalid packaged core Lua rejected" {
                Assert-PackagedRuntimeLuaSyntax -PackageRoot $mutationRoot -LuacPath $luac -CheckToolLocks:$false
            } "syntax failed.*StatsPro\.lua"
            [System.IO.File]::WriteAllBytes($corePath, $coreBytes)

            $nestedLuaPath = Join-Path (Join-Path $mutationRoot "libs") "CallbackHandler-1.0"
            $nestedLuaPath = Join-Path $nestedLuaPath "CallbackHandler-1.0.lua"
            $nestedLuaBytes = [System.IO.File]::ReadAllBytes($nestedLuaPath)
            [System.IO.File]::WriteAllText($nestedLuaPath, "local =`n", [System.Text.UTF8Encoding]::new($false))
            Assert-ThrowsMatch "invalid packaged nested Lua rejected" {
                Assert-PackagedRuntimeLuaSyntax -PackageRoot $mutationRoot -LuacPath $luac -CheckToolLocks:$false
            } "syntax failed.*CallbackHandler-1\.0/CallbackHandler-1\.0\.lua"
            [System.IO.File]::WriteAllBytes($nestedLuaPath, $nestedLuaBytes)

            $changelogPath = Join-Path $mutationRoot "CHANGELOG.md"
            $fullChangelogBytes = [System.IO.File]::ReadAllBytes($changelogPath)
            $sourceChangelogPath = Join-Path $sourceRoot "CHANGELOG.md"
            $sourceChangelogText = ConvertTo-StatsProNormalizedText -Path $sourceChangelogPath -ContractPath "StatsPro/CHANGELOG.md"
            $topChangelogText = (Get-StatsProTopChangelogEntryFromText -Text $sourceChangelogText) -replace "`n", "`r`n"
            [System.IO.File]::WriteAllText($changelogPath, $topChangelogText, [System.Text.UTF8Encoding]::new($false))
            Assert-StatsProPackageSourceFidelity -PackageRoot $mutationRoot -SourceRoot $sourceRoot -ProjectVersion $tag
            [System.IO.File]::AppendAllText($changelogPath, "mutation`r`n", [System.Text.UTF8Encoding]::new($false))
            Assert-ThrowsMatch "trimmed changelog drift rejected" {
                Assert-StatsProPackageSourceFidelity -PackageRoot $mutationRoot -SourceRoot $sourceRoot -ProjectVersion $tag
            } "StatsPro/CHANGELOG\.md"
            [System.IO.File]::WriteAllBytes($changelogPath, $fullChangelogBytes)

            foreach ($relativeMutationPath in @(
                "StatsPro.toc",
                "CHANGELOG.md",
                "LICENSE",
                "LICENSES/CallbackHandler-1.0-BSD-2-Clause.txt",
                "LICENSES/LibSharedMedia-3.0-LGPL-2.1.txt"
            )) {
                $mutationPath = Join-Path $mutationRoot ($relativeMutationPath -replace "/", [System.IO.Path]::DirectorySeparatorChar)
                $originalBytes = [System.IO.File]::ReadAllBytes($mutationPath)
                [System.IO.File]::AppendAllText($mutationPath, "`nmutation", [System.Text.UTF8Encoding]::new($false))
                Assert-ThrowsMatch "$relativeMutationPath source-fidelity mutation rejected" {
                    Assert-StatsProPackageSourceFidelity -PackageRoot $mutationRoot -SourceRoot $sourceRoot -ProjectVersion $tag
                } ([regex]::Escape("StatsPro/$relativeMutationPath"))
                [System.IO.File]::WriteAllBytes($mutationPath, $originalBytes)
            }

            $logoPath = Join-Path (Join-Path $mutationRoot "textures") "logo.png"
            $logoBytes = [System.IO.File]::ReadAllBytes($logoPath)
            if ($logoBytes.Length -eq 0) {
                throw "Self-test logo fixture is empty."
            }
            $mutatedLogoBytes = [byte[]]$logoBytes.Clone()
            $mutatedLogoBytes[0] = $mutatedLogoBytes[0] -bxor 0x01
            [System.IO.File]::WriteAllBytes($logoPath, $mutatedLogoBytes)
            Assert-ThrowsMatch "binary logo source-fidelity mutation rejected" {
                Assert-StatsProPackageSourceFidelity -PackageRoot $mutationRoot -SourceRoot $sourceRoot -ProjectVersion $tag
            } "StatsPro/textures/logo\.png"
            [System.IO.File]::WriteAllBytes($logoPath, $logoBytes)

            $extraPath = Join-Path $mutationRoot "debug.lua"
            [System.IO.File]::WriteAllText($extraPath, "return true`n", [System.Text.UTF8Encoding]::new($false))
            Assert-ThrowsMatch "extra package source-fidelity file rejected" {
                Assert-StatsProPackageSourceFidelity -PackageRoot $mutationRoot -SourceRoot $sourceRoot -ProjectVersion $tag
            } "path count"
            Remove-Item -LiteralPath $extraPath -Force

            Remove-Item -LiteralPath $corePath -Force
            Assert-ThrowsMatch "missing package source-fidelity file rejected" {
                Assert-StatsProPackageSourceFidelity -PackageRoot $mutationRoot -SourceRoot $sourceRoot -ProjectVersion $tag
            } "path count"
            [System.IO.File]::WriteAllBytes($corePath, $coreBytes)
        }
        finally {
            if ($mutationPackage -and (Test-Path -LiteralPath $mutationPackage.TempDir)) {
                Remove-Item -LiteralPath $mutationPackage.TempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        Assert-ThrowsMatch "release json mismatch rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"Other"}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "StatsPro"
        Assert-ThrowsMatch "release json wrong version rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"StatsPro","version":"v1.2.2","filename":"StatsPro-v1.2.3.zip","nolib":false,"metadata":[{"flavor":"mainline","interface":120007}]}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "version"
        Assert-ThrowsMatch "release json wrong filename rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"StatsPro","version":"v1.2.3","filename":"StatsPro-v1.2.3-1-gabc.zip","nolib":false,"metadata":[{"flavor":"mainline","interface":120007}]}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "filename"
        Assert-ThrowsMatch "release json missing nolib rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"StatsPro","version":"v1.2.3","filename":"StatsPro-v1.2.3.zip","metadata":[{"flavor":"mainline","interface":120007}]}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "nolib"
        Assert-ThrowsMatch "release json nolib true rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"StatsPro","version":"v1.2.3","filename":"StatsPro-v1.2.3.zip","nolib":true,"metadata":[{"flavor":"mainline","interface":120007}]}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "nolib=true"
        Assert-ThrowsMatch "release json wrong flavor rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"StatsPro","version":"v1.2.3","filename":"StatsPro-v1.2.3.zip","nolib":false,"metadata":[{"flavor":"classic","interface":120007}]}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "flavor"
        Assert-ThrowsMatch "release json missing interface rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"StatsPro","version":"v1.2.3","filename":"StatsPro-v1.2.3.zip","nolib":false,"metadata":[{"flavor":"mainline"}]}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "interface"
        Assert-ThrowsMatch "release json duplicate metadata rejected" {
            Assert-StatsProReleaseJson -JsonText '{"releases":[{"name":"StatsPro","version":"v1.2.3","filename":"StatsPro-v1.2.3.zip","nolib":false,"metadata":[{"flavor":"mainline","interface":120007},{"flavor":"mainline","interface":120007}]}]}' -ExpectedTag "v1.2.3" -ExpectedInterfaces @(120007)
        } "entry count"

        $noticeRoot = Join-Path $tempDir "notice-root"
        $noticeRequirements = @(Get-StatsProThirdPartyContract)
        foreach ($requirement in $noticeRequirements) {
            $runtimeSource = Join-Path $sourceRoot ($requirement.Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
            $runtimeTarget = Join-Path $noticeRoot ($requirement.Path -replace "/", [System.IO.Path]::DirectorySeparatorChar)
            New-Item -ItemType Directory -Path (Split-Path -Parent $runtimeTarget) -Force | Out-Null
            Copy-Item -LiteralPath $runtimeSource -Destination $runtimeTarget
            if (-not [string]::IsNullOrWhiteSpace($requirement.LicenseFile)) {
                $licenseSource = Join-Path $sourceRoot ($requirement.LicenseFile -replace "/", [System.IO.Path]::DirectorySeparatorChar)
                $licenseTarget = Join-Path $noticeRoot ($requirement.LicenseFile -replace "/", [System.IO.Path]::DirectorySeparatorChar)
                New-Item -ItemType Directory -Path (Split-Path -Parent $licenseTarget) -Force | Out-Null
                Copy-Item -LiteralPath $licenseSource -Destination $licenseTarget
            }
        }
        $noticePath = Join-Path $noticeRoot "THIRD-PARTY-NOTICES.md"
        Copy-Item -LiteralPath (Join-Path $sourceRoot "THIRD-PARTY-NOTICES.md") -Destination $noticePath
        $validNotice = Get-Content -LiteralPath $noticePath -Raw -Encoding UTF8
        Assert-StatsProThirdPartyMaterials -Root $noticeRoot

        Set-Content -LiteralPath $noticePath -Value ($validNotice -replace "(?ms)^## libs/LibStub/LibStub\.lua.*?(?=^## |\z)", "") -Encoding UTF8
        Assert-ThrowsMatch "notice missing library section rejected" {
            Assert-StatsProThirdPartyMaterials -Root $noticeRoot
        } "missing section"

        Set-Content -LiteralPath $noticePath -Value ($validNotice -replace "License: BSD-2-Clause", "License: MIT") -Encoding UTF8
        Assert-ThrowsMatch "notice wrong license rejected" {
            Assert-StatsProThirdPartyMaterials -Root $noticeRoot
        } "License: BSD-2-Clause"

        Set-Content -LiteralPath $noticePath -Value ($validNotice -replace $noticeRequirements[2].RuntimeSha256, ("0" * 64)) -Encoding UTF8
        Assert-ThrowsMatch "notice stale hash rejected" {
            Assert-StatsProThirdPartyMaterials -Root $noticeRoot
        } "SHA256"

        Set-Content -LiteralPath $noticePath -Value ($validNotice -replace $noticeRequirements[1].LicenseDeclarationSha256, ("0" * 64)) -Encoding UTF8
        Assert-ThrowsMatch "notice stale provenance hash rejected" {
            Assert-StatsProThirdPartyMaterials -Root $noticeRoot
        } "License declaration SHA256"

        Set-Content -LiteralPath $noticePath -Value $validNotice -Encoding UTF8
        Remove-Item -LiteralPath (Join-Path $noticeRoot $noticeRequirements[1].LicenseFile)
        Assert-ThrowsMatch "missing packaged license rejected" {
            Assert-StatsProThirdPartyMaterials -Root $noticeRoot
        } "Missing license text"

        Copy-Item -LiteralPath (Join-Path $sourceRoot $noticeRequirements[1].LicenseFile) -Destination (Join-Path $noticeRoot $noticeRequirements[1].LicenseFile)
        Set-Content -LiteralPath (Join-Path $noticeRoot $noticeRequirements[2].LicenseFile) -Value "modified" -Encoding UTF8
        Assert-ThrowsMatch "modified packaged license rejected" {
            Assert-StatsProThirdPartyMaterials -Root $noticeRoot
        } "License text.*SHA256"

        Copy-Item -LiteralPath (Join-Path $sourceRoot $noticeRequirements[2].LicenseFile) -Destination (Join-Path $noticeRoot $noticeRequirements[2].LicenseFile) -Force
        Set-Content -LiteralPath (Join-Path $noticeRoot $noticeRequirements[1].Path) -Value "modified" -Encoding UTF8
        Assert-ThrowsMatch "modified packaged runtime rejected" {
            Assert-StatsProThirdPartyMaterials -Root $noticeRoot
        } "runtime library.*SHA256"

        Assert-ThrowsMatch "missing package file rejected" {
            Assert-StatsProPackageEntries -Entries @(
                "StatsPro/CHANGELOG.md",
                "StatsPro/LICENSE",
                "StatsPro/StatsPro.toc",
                "StatsPro/StatsPro.lua",
                "StatsPro/StatsPro_ArchonTargets.lua",
                "StatsPro/textures/logo.png",
                "StatsPro/libs/LibStub/LibStub.lua",
                "StatsPro/libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
                "StatsPro/libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua"
            )
        } "THIRD-PARTY-NOTICES"
        foreach ($licenseFile in @($noticeRequirements | Where-Object { -not [string]::IsNullOrWhiteSpace($_.LicenseFile) } | ForEach-Object { "StatsPro/$($_.LicenseFile)" })) {
            Assert-ThrowsMatch "missing packaged license entry rejected" {
                Assert-StatsProPackageEntries -Entries @((Get-StatsProPackageFileContract).RequiredFiles | Where-Object { $_ -ne $licenseFile })
            } ([regex]::Escape($licenseFile))
        }
        Assert-ThrowsMatch "unexpected lib file rejected" {
            Assert-StatsProPackageEntries -Entries ((Get-StatsProPackageFileContract).RequiredFiles + "StatsPro/libs/LibStub/tests/test.lua")
        } "unexpected packaged lib file"
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "Release artifact self-test passed."
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if ($WriteReleaseJson) {
    $WithReleaseJson = $true
}

Assert-StatsProReleaseArtifact `
    -ZipPath $ZipPath `
    -ReleaseJsonPath $ReleaseJsonPath `
    -ExpectedTag $ExpectedTag `
    -PackagerProjectVersion $PackagerProjectVersion `
    -SourceRoot $SourceRoot `
    -ArchonMaxAgeDays $ArchonMaxAgeDays `
    -PackageOnly:$PackageOnly.IsPresent `
    -WithReleaseJson:$WithReleaseJson.IsPresent `
    -WriteReleaseJson:$WriteReleaseJson.IsPresent
