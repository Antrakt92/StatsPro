param(
    [string]$ArchivePath,
    [string]$ExpectedTag,
    [string]$PackagerProjectVersion,
    [string]$SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")),
    [string]$PackageRoot = (Join-Path (Join-Path (Join-Path $PSScriptRoot "..") ".release") "StatsPro"),
    [string]$ReleaseRoot = (Join-Path (Join-Path $PSScriptRoot "..") ".release"),
    [string]$ManifestPath,
    [string]$CompareManifestPath,
    [int]$ArchonMaxAgeDays = 3,
    [switch]$EnforceToolLocks,
    [switch]$RequireExactPackagerProjectVersion,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "release-tag-contract.ps1")

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

function Assert-PowerShell7OrNewer {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "check-package-dry-run.ps1 requires PowerShell 7+ (pwsh). Windows PowerShell 5.1 lacks APIs used by the package repeatability checks."
    }
}

function Assert-ReleaseTag {
    param([string]$Value)

    Assert-StatsProReleaseTag -Value $Value
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

function Get-StatsProSourceVersionTag {
    param([string]$Root)

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $tocPath = Join-Path $resolvedRoot "StatsPro.toc"
    if (-not (Test-Path -LiteralPath $tocPath -PathType Leaf)) {
        throw "Missing StatsPro.toc in source root $resolvedRoot."
    }
    $tocText = Get-Content -LiteralPath $tocPath -Raw -Encoding UTF8
    $version = Get-SingleRegexMatchFromText -Text $tocText -Pattern "^##\s+Version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$" -Description "TOC Version"
    Assert-StatsProReleaseVersion -Value $version
    return "v$version"
}

function Resolve-StatsProExpectedTag {
    param([string]$Value, [string]$Root)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = Get-StatsProSourceVersionTag -Root $Root
    }
    Assert-ReleaseTag $Value
    return $Value
}

function Resolve-StatsProPackagerProjectVersion {
    param([string]$Value, [string]$Root)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $output = @(& git -C $Root describe --tags --abbrev=7 '--exclude=*[Aa][Ll][Pp][Hh][Aa]*' 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Could not derive the pinned Packager project version from git: $($output -join ' ')"
        }
        $Value = ($output -join "`n").Trim()
    }
    Assert-StatsProPackagerProjectVersion $Value
    return $Value
}

function Assert-StatsProPackagerProjectVersionPolicy {
    param(
        [string]$ProjectVersion,
        [string]$ExpectedTag,
        [bool]$RequireExact
    )

    if ($RequireExact -and -not [System.StringComparer]::Ordinal.Equals($ProjectVersion, $ExpectedTag)) {
        throw "Packager project version '$ProjectVersion' must exactly match release tag '$ExpectedTag' in exact-tag mode."
    }
}

function Assert-StatsProExactVersionInputs {
    param(
        [string]$ExpectedTag,
        [string]$PackagerProjectVersion,
        [bool]$RequireExact
    )

    if (-not $RequireExact) {
        return
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedTag)) {
        throw "Exact-tag mode requires an explicit -ExpectedTag."
    }
    if ([string]::IsNullOrWhiteSpace($PackagerProjectVersion)) {
        throw "Exact-tag mode requires an explicit -PackagerProjectVersion."
    }
}

function Get-StatsProWorkflowRunScripts {
    param([string]$Text)

    $scripts = @()
    $lines = @($Text -split "\r?\n")
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ($line -notmatch '^(\s*)(?:-\s+)?run:\s*(.*?)\s*$') {
            continue
        }

        $headerIndent = $Matches[1].Length
        $value = $Matches[2]
        if (-not [string]::IsNullOrWhiteSpace($value) -and $value -notmatch '^[|>]') {
            $scripts += $value
            continue
        }

        $blockLines = @()
        $contentIndent = $null
        for ($blockIndex = $index + 1; $blockIndex -lt $lines.Count; $blockIndex++) {
            $blockLine = [string]$lines[$blockIndex]
            if ([string]::IsNullOrWhiteSpace($blockLine)) {
                if ($null -ne $contentIndent) {
                    $blockLines += ""
                }
                continue
            }
            $indent = ([regex]::Match($blockLine, '^\s*')).Value.Length
            if ($indent -le $headerIndent) {
                break
            }
            if ($null -eq $contentIndent) {
                $contentIndent = $indent
            }
            if ($indent -lt $contentIndent) {
                throw "Workflow run block has inconsistent indentation."
            }
            $blockLines += $blockLine.Substring($contentIndent)
        }
        if ($null -eq $contentIndent) {
            throw "Workflow run block is empty."
        }
        $scripts += ($blockLines -join "`n")
        $index = $blockIndex - 1
    }
    return $scripts
}

function Get-StatsProWorkflowCommands {
    param([string]$Text, [string]$ScriptName)

    $commands = @()
    foreach ($script in (Get-StatsProWorkflowRunScripts -Text $Text)) {
        if ($script -notmatch [regex]::Escape($ScriptName)) {
            continue
        }
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) {
            throw "Workflow run script could not be parsed: $($errors[0].Message)"
        }
        $commandAsts = @($ast.FindAll({
            param($node)
            if ($node -isnot [System.Management.Automation.Language.CommandAst]) {
                return $false
            }
            $commandName = $node.GetCommandName()
            if ([string]::IsNullOrWhiteSpace($commandName)) {
                return $false
            }
            $leaf = ($commandName -split '[\\/]')[-1]
            return [System.StringComparer]::OrdinalIgnoreCase.Equals($leaf, $ScriptName)
        }, $true))
        $commands += @($commandAsts | ForEach-Object { $_.Extent.Text })
    }
    return $commands
}

function Get-StatsProCommandParameterInfo {
    param([string]$Command, [string]$Name)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "Workflow command could not be parsed: $($errors[0].Message)"
    }
    $commandAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)
    if ($null -eq $commandAst) {
        throw "Workflow block contains no executable command."
    }

    $elements = @($commandAst.CommandElements)
    $matches = @()
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
            [System.StringComparer]::OrdinalIgnoreCase.Equals($element.ParameterName, $Name)) {
            $following = $null
            if ($index + 1 -lt $elements.Count -and
                $elements[$index + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                $following = $elements[$index + 1]
            }
            $matches += [pscustomobject]@{
                Parameter = $element
                Following = $following
            }
        }
    }
    if ($matches.Count -gt 1) {
        throw "Workflow command repeats -$Name."
    }
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[0]
}

function Assert-StatsProBareWorkflowSwitch {
    param([string]$Command, [string]$Name)

    $info = Get-StatsProCommandParameterInfo -Command $Command -Name $Name
    if ($null -eq $info -or $null -ne $info.Parameter.Argument) {
        throw "Workflow command must pass bare -$Name."
    }
}

function Assert-StatsProWorkflowVariableParameter {
    param([string]$Command, [string]$Name, [string]$VariablePath)

    $info = Get-StatsProCommandParameterInfo -Command $Command -Name $Name
    if ($null -eq $info -or $null -ne $info.Parameter.Argument -or
        $info.Following -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
        (-not [string]::IsNullOrWhiteSpace($VariablePath) -and
            -not [System.StringComparer]::OrdinalIgnoreCase.Equals($info.Following.VariablePath.UserPath, $VariablePath))) {
        $expected = if ([string]::IsNullOrWhiteSpace($VariablePath)) { "an explicit variable" } else { "`$$VariablePath" }
        throw "Workflow command must pass -$Name as $expected."
    }
}

function Assert-StatsProWorkflowPackageVersionPolicy {
    param([string]$Root)

    $releasePath = Join-Path (Join-Path $Root ".github\workflows") "release.yml"
    $checksPath = Join-Path (Join-Path $Root ".github\workflows") "checks.yml"
    $releaseText = Get-Content -LiteralPath $releasePath -Raw -Encoding UTF8
    $checksText = Get-Content -LiteralPath $checksPath -Raw -Encoding UTF8
    if ($releaseText -match 'steps\.(?:build-package|rebuild-package|publish-package)\.outputs\.' -or
        $checksText -match 'steps\.package\.outputs\.') {
        throw "Workflows must not read undeclared outputs directly from the BigWigs Packager action."
    }
    if ($checksText -notmatch '(?m)^\s{8}run: \./scripts/resolve-packager-output\.ps1 -OutputPath \$env:GITHUB_OUTPUT\s*$' -or
        $checksText.IndexOf('STATSPRO_ARCHIVE_PATH: ${{ steps.package-output.outputs.archive_path }}', [System.StringComparison]::Ordinal) -lt 0 -or
        $checksText.IndexOf('STATSPRO_PROJECT_VERSION: ${{ steps.package-output.outputs.project_version }}', [System.StringComparison]::Ordinal) -lt 0) {
        throw "checks.yml must resolve the generated Packager artifact before validating it."
    }
    $releaseCommands = @(Get-StatsProWorkflowCommands -Text $releaseText -ScriptName "check-package-dry-run.ps1")
    $checksCommands = @(Get-StatsProWorkflowCommands -Text $checksText -ScriptName "check-package-dry-run.ps1")

    if ($releaseCommands.Count -lt 1) {
        throw "release.yml must contain package dry-run validations."
    }
    foreach ($command in $releaseCommands) {
        Assert-StatsProBareWorkflowSwitch -Command $command -Name "RequireExactPackagerProjectVersion"
        Assert-StatsProWorkflowVariableParameter -Command $command -Name "ExpectedTag" -VariablePath "env:GITHUB_REF_NAME"
        Assert-StatsProWorkflowVariableParameter -Command $command -Name "PackagerProjectVersion" -VariablePath "env:STATSPRO_PROJECT_VERSION"
    }

    if ($checksCommands.Count -lt 1) {
        throw "checks.yml must contain a branch package dry-run validation."
    }
    foreach ($command in $checksCommands) {
        if ($null -ne (Get-StatsProCommandParameterInfo -Command $command -Name "RequireExactPackagerProjectVersion") -or
            $null -ne (Get-StatsProCommandParameterInfo -Command $command -Name "ExpectedTag")) {
            throw "checks.yml branch package validation must allow Packager commit suffixes."
        }
    }

    $releaseArtifactCommands = @(Get-StatsProWorkflowCommands -Text $releaseText -ScriptName "check-release-artifact.ps1")
    foreach ($command in $releaseArtifactCommands) {
        if ($null -ne (Get-StatsProCommandParameterInfo -Command $command -Name "SelfTest")) {
            continue
        }
        Assert-StatsProBareWorkflowSwitch -Command $command -Name "RequireExactPackagerProjectVersion"
        Assert-StatsProWorkflowVariableParameter -Command $command -Name "PackagerProjectVersion" -VariablePath ""
    }
}

function Resolve-StatsProArchivePath {
    param([string]$Value, [string]$Root)

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return (Resolve-Path -LiteralPath $Value).Path
    }

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Missing -ArchivePath and release root not found: $Root"
    }
    $candidates = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "StatsPro-*.zip" | Sort-Object FullName)
    if ($candidates.Count -ne 1) {
        throw "Missing -ArchivePath and expected exactly one StatsPro-*.zip in $Root; found $($candidates.Count)."
    }
    return $candidates[0].FullName
}

function Get-StatsProPackageManifestLines {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Package root not found: $Root"
    }
    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $filesByRelativePath = @{}
    foreach ($file in (Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File)) {
        $relative = [System.IO.Path]::GetRelativePath($resolvedRoot, $file.FullName) -replace "\\", "/"
        if ($filesByRelativePath.ContainsKey($relative)) {
            throw "Package root contains duplicate canonical path $relative."
        }
        $filesByRelativePath[$relative] = $file.FullName
    }
    $paths = [string[]]@($filesByRelativePath.Keys)
    [System.Array]::Sort($paths, [System.StringComparer]::Ordinal)
    $lines = @($paths | ForEach-Object {
        $hash = (Get-FileHash -LiteralPath $filesByRelativePath[$_] -Algorithm SHA256).Hash
        "$_`t$hash"
    })
    if ($lines.Count -eq 0) {
        throw "Package root contains no files: $resolvedRoot"
    }
    return $lines
}

function Assert-StatsProPackageManifestMatches {
    param([string]$Root, [string]$ExpectedManifestPath)

    if (-not (Test-Path -LiteralPath $ExpectedManifestPath -PathType Leaf)) {
        throw "Expected package manifest not found: $ExpectedManifestPath"
    }
    $expected = @(Get-Content -LiteralPath $ExpectedManifestPath)
    $actual = @(Get-StatsProPackageManifestLines -Root $Root)
    if ($expected.Count -ne $actual.Count) {
        throw "Package tree is not repeatable between dry-run builds: manifest line count is $($actual.Count), expected $($expected.Count)."
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if (-not [System.StringComparer]::Ordinal.Equals([string]$expected[$index], [string]$actual[$index])) {
            throw "Package tree is not repeatable between dry-run builds at manifest line $($index + 1): '$($actual[$index])', expected '$($expected[$index])'."
        }
    }
}

function Save-StatsProPackageManifest {
    param([string]$Root, [string]$Path)

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Get-StatsProPackageManifestLines -Root $Root |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

function Assert-StatsProNoInGameSolicitation {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Package root not found: $Root"
    }
    $rules = [ordered]@{
        "Sponsors" = "github\.com/sponsors|\bsponsors?\b"
        "Donate" = "\bdonat(?:e|ion|ions)\b"
        "Support-development" = "support\s+(?:development|the\s+developer)"
    }
    $runtimeFiles = @(Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object { $_.Extension -in ".lua", ".toc" })
    foreach ($file in $runtimeFiles) {
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        foreach ($rule in $rules.GetEnumerator()) {
            if ($text -match $rule.Value) {
                $relative = [System.IO.Path]::GetRelativePath($Root, $file.FullName) -replace "\\", "/"
                throw "Packaged in-game surface contains forbidden solicitation token '$($rule.Key)' in '$relative'."
            }
        }
    }
}

function Invoke-StatsProPackageArtifactCheck {
    param(
        [string]$ZipPath,
        [string]$ExpectedTag,
        [string]$ProjectVersion,
        [string]$Root,
        [int]$MaxAgeDays,
        [bool]$CheckToolLocks,
        [bool]$RequireExactPackagerProjectVersion
    )

    $checker = Join-Path (Join-Path $Root "scripts") "check-release-artifact.ps1"
    if (-not (Test-Path -LiteralPath $checker -PathType Leaf)) {
        throw "Missing release artifact checker: $checker"
    }

    if ($CheckToolLocks) {
        & $checker `
            -ZipPath $ZipPath `
            -ExpectedTag $ExpectedTag `
            -PackagerProjectVersion $ProjectVersion `
            -SourceRoot $Root `
            -ArchonMaxAgeDays $MaxAgeDays `
            -RequireExactPackagerProjectVersion:$RequireExactPackagerProjectVersion `
            -PackageOnly `
            -EnforceToolLocks
    }
    else {
        & $checker `
            -ZipPath $ZipPath `
            -ExpectedTag $ExpectedTag `
            -PackagerProjectVersion $ProjectVersion `
            -SourceRoot $Root `
            -ArchonMaxAgeDays $MaxAgeDays `
            -RequireExactPackagerProjectVersion:$RequireExactPackagerProjectVersion `
            -PackageOnly
    }
}

function Invoke-SelfTest {
    Assert-StatsProReleaseTagContractSelfTest
    $sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $tag = Get-StatsProSourceVersionTag -Root $sourceRoot
    Assert-ReleaseTag $tag
    Assert-ThrowsMatch "leading-zero expected tag rejected" {
        [void](Resolve-StatsProExpectedTag -Value "v01.2.3" -Root $sourceRoot)
    } "Malformed StatsPro release tag"
    if ((Resolve-StatsProPackagerProjectVersion -Value "v1.2.3-4-gabcdef0" -Root $sourceRoot) -ne "v1.2.3-4-gabcdef0") {
        throw "Explicit Packager project version was not preserved."
    }
    Assert-ThrowsMatch "leading-zero Packager base rejected" {
        [void](Resolve-StatsProPackagerProjectVersion -Value "v1.02.3-4-gabcdef0" -Root $sourceRoot)
    } "Malformed StatsPro Packager project version"
    Assert-ThrowsMatch "malformed Packager project version rejected" {
        [void](Resolve-StatsProPackagerProjectVersion -Value "1.2.3" -Root $sourceRoot)
    } "Malformed"
    Assert-StatsProPackagerProjectVersionPolicy `
        -ProjectVersion "v1.2.3-4-gabcdef0" `
        -ExpectedTag "v1.2.3" `
        -RequireExact:$false
    Assert-StatsProPackagerProjectVersionPolicy `
        -ProjectVersion "v1.2.3" `
        -ExpectedTag "v1.2.3" `
        -RequireExact:$true
    Assert-ThrowsMatch "branch Packager version rejected in exact-tag mode" {
        Assert-StatsProPackagerProjectVersionPolicy `
            -ProjectVersion "v1.2.3-4-gabcdef0" `
            -ExpectedTag "v1.2.3" `
            -RequireExact:$true
    } "must exactly match release tag"
    Assert-ThrowsMatch "missing explicit tag rejected in exact-tag mode" {
        Assert-StatsProExactVersionInputs -ExpectedTag "" -PackagerProjectVersion "v1.2.3" -RequireExact:$true
    } "explicit -ExpectedTag"
    Assert-ThrowsMatch "missing explicit Packager version rejected in exact-tag mode" {
        Assert-StatsProExactVersionInputs -ExpectedTag "v1.2.3" -PackagerProjectVersion " " -RequireExact:$true
    } "explicit -PackagerProjectVersion"

    $validWorkflowCommand = @'
./scripts/check-package-dry-run.ps1 `
    -PackagerProjectVersion $env:STATSPRO_PROJECT_VERSION `
    -RequireExactPackagerProjectVersion `
    -ExpectedTag $env:GITHUB_REF_NAME
'@
    Assert-StatsProBareWorkflowSwitch -Command $validWorkflowCommand -Name "RequireExactPackagerProjectVersion"
    Assert-StatsProWorkflowVariableParameter -Command $validWorkflowCommand -Name "ExpectedTag" -VariablePath "env:GITHUB_REF_NAME"
    Assert-StatsProWorkflowVariableParameter -Command $validWorkflowCommand -Name "PackagerProjectVersion" -VariablePath "env:STATSPRO_PROJECT_VERSION"
    Assert-ThrowsMatch "explicitly disabled workflow switch rejected" {
        Assert-StatsProBareWorkflowSwitch `
            -Command ($validWorkflowCommand -replace "-RequireExactPackagerProjectVersion", '-RequireExactPackagerProjectVersion:$false') `
            -Name "RequireExactPackagerProjectVersion"
    } "must pass bare"
    Assert-ThrowsMatch "wrong workflow tag variable rejected" {
        Assert-StatsProWorkflowVariableParameter `
            -Command ($validWorkflowCommand -replace 'env:GITHUB_REF_NAME', 'env:STATSPRO_PROJECT_VERSION') `
            -Name "ExpectedTag" `
            -VariablePath "env:GITHUB_REF_NAME"
    } "must pass -ExpectedTag"
    Assert-ThrowsMatch "missing workflow switch rejected" {
        Assert-StatsProBareWorkflowSwitch `
            -Command ($validWorkflowCommand -replace '(?m)^\s*-RequireExactPackagerProjectVersion\s+`\s*$', '') `
            -Name "RequireExactPackagerProjectVersion"
    } "must pass bare"
    Assert-ThrowsMatch "missing workflow tag parameter rejected" {
        Assert-StatsProWorkflowVariableParameter `
            -Command ($validWorkflowCommand -replace '(?m)^\s*-ExpectedTag .+$', '') `
            -Name "ExpectedTag" `
            -VariablePath "env:GITHUB_REF_NAME"
    } "must pass -ExpectedTag"
    Assert-ThrowsMatch "wrong workflow Packager variable rejected" {
        Assert-StatsProWorkflowVariableParameter `
            -Command ($validWorkflowCommand -replace 'env:STATSPRO_PROJECT_VERSION', 'env:GITHUB_REF_NAME') `
            -Name "PackagerProjectVersion" `
            -VariablePath "env:STATSPRO_PROJECT_VERSION"
    } "must pass -PackagerProjectVersion"

    $syntheticWorkflow = @'
steps:
  - run: ./scripts/check-package-dry-run.ps1 -ExpectedTag $env:GITHUB_REF_NAME -PackagerProjectVersion $env:STATSPRO_PROJECT_VERSION -RequireExactPackagerProjectVersion
  - run: |
      & .\scripts\check-package-dry-run.ps1 `
          -RequireExactPackagerProjectVersion `
          -ExpectedTag $env:GITHUB_REF_NAME `
          -PackagerProjectVersion $env:STATSPRO_PROJECT_VERSION
  - notes: |
      ./scripts/check-package-dry-run.ps1 -RequireExactPackagerProjectVersion:$false
'@
    $syntheticCommands = @(Get-StatsProWorkflowCommands -Text $syntheticWorkflow -ScriptName "check-package-dry-run.ps1")
    if ($syntheticCommands.Count -ne 2) {
        throw "Workflow run-script extraction found $($syntheticCommands.Count) package commands, expected 2."
    }
    foreach ($command in $syntheticCommands) {
        Assert-StatsProBareWorkflowSwitch -Command $command -Name "RequireExactPackagerProjectVersion"
    }
    Assert-StatsProWorkflowPackageVersionPolicy -Root $sourceRoot

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("statspro-package-dry-run-test-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
        $invalidSource = Join-Path $tempDir "invalid-source"
        New-Item -ItemType Directory -Path $invalidSource | Out-Null
        Set-Content -LiteralPath (Join-Path $invalidSource "StatsPro.toc") -Value "## Version: 01.2.3" -Encoding UTF8
        Assert-ThrowsMatch "leading-zero TOC fallback rejected" {
            [void](Get-StatsProSourceVersionTag -Root $invalidSource)
        } "Malformed StatsPro release version"

        $packageRoot = Join-Path $tempDir "StatsPro"
        New-Item -ItemType Directory -Path (Join-Path $packageRoot "nested") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $packageRoot "a.txt") -Value "one" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $packageRoot "nested\b.txt") -Value "two" -Encoding UTF8

        $manifest = Join-Path $tempDir "manifest.tsv"
        Get-StatsProPackageManifestLines -Root $packageRoot |
            Set-Content -LiteralPath $manifest -Encoding UTF8
        Assert-StatsProPackageManifestMatches -Root $packageRoot -ExpectedManifestPath $manifest

        Set-Content -LiteralPath (Join-Path $packageRoot "nested\b.txt") -Value "changed" -Encoding UTF8
        Assert-ThrowsMatch "manifest mismatch rejected" {
            Assert-StatsProPackageManifestMatches -Root $packageRoot -ExpectedManifestPath $manifest
        } "not repeatable"

        $runtimePath = Join-Path $packageRoot "StatsPro.lua"
        Set-Content -LiteralPath $runtimePath -Value 'local contact = "https://github.com/example/issues"' -Encoding UTF8
        Assert-StatsProNoInGameSolicitation -Root $packageRoot
        Set-Content -LiteralPath $runtimePath -Value 'local approvedLink = "https://ko-fi.com/example"' -Encoding UTF8
        Assert-StatsProNoInGameSolicitation -Root $packageRoot
        Set-Content -LiteralPath $runtimePath -Value 'local solicitation = "Donate to the developer"' -Encoding UTF8
        Assert-ThrowsMatch "coercive in-game solicitation rejected" {
            Assert-StatsProNoInGameSolicitation -Root $packageRoot
        } "forbidden solicitation token 'Donate'"
        Remove-Item -LiteralPath $runtimePath

        $releaseRoot = Join-Path $tempDir "release"
        New-Item -ItemType Directory -Path $releaseRoot | Out-Null
        $singleZip = Join-Path $releaseRoot "StatsPro-v1.2.3-4-gabcdef0.zip"
        Set-Content -LiteralPath $singleZip -Value "zip" -Encoding UTF8
        if ((Resolve-StatsProArchivePath -Value "" -Root $releaseRoot) -ne $singleZip) {
            throw "Archive fallback must return the only StatsPro zip."
        }
        Assert-ThrowsMatch "missing archive fallback rejected" {
            Resolve-StatsProArchivePath -Value "" -Root (Join-Path $tempDir "missing-release")
        } "release root not found"
        Set-Content -LiteralPath (Join-Path $releaseRoot "StatsPro-v1.2.3-5-gabcdef1.zip") -Value "zip" -Encoding UTF8
        Assert-ThrowsMatch "ambiguous archive fallback rejected" {
            Resolve-StatsProArchivePath -Value "" -Root $releaseRoot
        } "exactly one"
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "Package dry-run self-test passed."
}

if ($SelfTest) {
    Assert-PowerShell7OrNewer
    Invoke-SelfTest
    return
}

Assert-PowerShell7OrNewer

$resolvedSourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
Assert-StatsProExactVersionInputs `
    -ExpectedTag $ExpectedTag `
    -PackagerProjectVersion $PackagerProjectVersion `
    -RequireExact:$RequireExactPackagerProjectVersion.IsPresent
$resolvedArchivePath = Resolve-StatsProArchivePath -Value $ArchivePath -Root $ReleaseRoot
$resolvedTag = Resolve-StatsProExpectedTag -Value $ExpectedTag -Root $resolvedSourceRoot
$resolvedPackagerProjectVersion = Resolve-StatsProPackagerProjectVersion -Value $PackagerProjectVersion -Root $resolvedSourceRoot
Assert-StatsProPackagerProjectVersionPolicy `
    -ProjectVersion $resolvedPackagerProjectVersion `
    -ExpectedTag $resolvedTag `
    -RequireExact:$RequireExactPackagerProjectVersion.IsPresent

Invoke-StatsProPackageArtifactCheck `
    -ZipPath $resolvedArchivePath `
    -ExpectedTag $resolvedTag `
    -ProjectVersion $resolvedPackagerProjectVersion `
    -Root $resolvedSourceRoot `
    -MaxAgeDays $ArchonMaxAgeDays `
    -CheckToolLocks:$EnforceToolLocks.IsPresent `
    -RequireExactPackagerProjectVersion:$RequireExactPackagerProjectVersion.IsPresent

$resolvedPackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
Assert-StatsProNoInGameSolicitation -Root $resolvedPackageRoot

if (-not [string]::IsNullOrWhiteSpace($ManifestPath) -or -not [string]::IsNullOrWhiteSpace($CompareManifestPath)) {
    if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
        Save-StatsProPackageManifest -Root $resolvedPackageRoot -Path $ManifestPath
        Write-Host "StatsPro package manifest saved to $ManifestPath."
    }
    if (-not [string]::IsNullOrWhiteSpace($CompareManifestPath)) {
        Assert-StatsProPackageManifestMatches -Root $resolvedPackageRoot -ExpectedManifestPath $CompareManifestPath
        Write-Host "StatsPro package manifest matches $CompareManifestPath."
    }
}
