function Assert-ThrowsMatch {
    param([string]$Name, [scriptblock]$Script, [string]$Pattern)

    $completed = $false
    try {
        & $Script
        $completed = $true
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Name failed with wrong error: $($_.Exception.Message)"
        }
    }
    if ($completed) {
        throw "$Name should have failed."
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

function Resolve-RequiredFile {
    param([string]$Path, [string]$Description)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing $Description file '$Path'."
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-LowercaseFileSha256 {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Sha256 {
    param(
        [string]$Value,
        [string]$Description = "Expected SHA-256"
    )

    if ($Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Description must be 64 lowercase hexadecimal characters."
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)

    $parent = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::GetFullPath($Path),
        $Text,
        [System.Text.UTF8Encoding]::new($false))
}

function Add-OutputValue {
    param([string]$Path, [string]$Name, [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    if ($Value -match '[\r\n]') {
        throw "Output '$Name' contains a newline."
    }
    [System.IO.File]::AppendAllText(
        [System.IO.Path]::GetFullPath($Path),
        "$Name=$Value`n",
        [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Git {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& git @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') failed with code ${exitCode}: $($output -join ' ')"
    }
    return @{
        ExitCode = $exitCode
        Output = $output
    }
}

function Get-SingleRegexMatch {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Description
    )

    $Text = Get-Content -Path $Path -Raw -Encoding UTF8
    $Matches = [regex]::Matches($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($Matches.Count -eq 0) {
        throw "Missing $Description in $Path"
    }
    if ($Matches.Count -gt 1) {
        throw "Found multiple $Description values in $Path"
    }
    return $Matches[0].Groups[1].Value
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

function Assert-ExactPropertySet {
    param([object]$Value, [string[]]$Expected, [string]$Description)

    if ($null -eq $Value) {
        throw "$Description is missing."
    }
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $expectedSorted = @($Expected | Sort-Object)
    if ($actual.Count -ne $expectedSorted.Count -or
        (Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actual)) {
        throw "$Description fields are '$($actual -join ', ')'; expected '$($expectedSorted -join ', ')'."
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
