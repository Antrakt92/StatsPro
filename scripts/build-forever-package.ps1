[CmdletBinding()]
param([string]$SourceRoot = (Join-Path $PSScriptRoot '..'), [string]$OutputRoot)
$ErrorActionPreference = 'Stop'
$buildSourceRoot = $SourceRoot
$buildOutputRoot = $OutputRoot
. (Join-Path $PSScriptRoot 'test-forever-package.ps1') -LibraryOnly
$SourceRoot = [System.IO.Path]::GetFullPath($buildSourceRoot)
$OutputRoot = $buildOutputRoot
if (-not $OutputRoot) { $OutputRoot = Join-Path $SourceRoot '.release/forever-beta' }
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$version = Get-ForeverSourceVersion $SourceRoot
$map = Get-ForeverPackageMap
Assert-ForeverToc ([System.IO.File]::ReadAllText((Join-Path $SourceRoot 'StatsPro_Forever.toc'))) $version
$snapshots = @{}
foreach ($name in $map.Values) { $snapshots[$name] = [System.IO.File]::ReadAllBytes((Join-Path $SourceRoot $name)) }
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$archivePath = Join-Path $OutputRoot "StatsPro-v$version-Forever-beta.zip"
if (Test-Path -LiteralPath $archivePath) { throw "Refusing overwrite of existing build: $archivePath" }
$zip = [System.IO.Compression.ZipFile]::Open($archivePath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in @($map.Keys | Sort-Object)) {
        $bytes = $snapshots[$map[$name]]
        if ($name -ceq 'StatsPro.lua') {
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            if ([regex]::Matches($text, '@project-version@').Count -ne 1) { throw 'Expected one version substitution token' }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($text.Replace('@project-version@', "v$version"))
        }
        $entry = $zip.CreateEntry("StatsPro/$name", [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::new(2000,1,1,0,0,0,[TimeSpan]::Zero)
        $stream = $entry.Open()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
}
finally { $zip.Dispose() }
foreach ($name in $map.Values) {
    if ([Convert]::ToBase64String($snapshots[$name]) -cne [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $SourceRoot $name)))) {
        throw "Source changed during packaging: $name; archive is unverified"
    }
}
Assert-ForeverArchive $archivePath $SourceRoot
$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "Local Forever beta archive: $archivePath"
Write-Host "SHA256: $hash"
Write-Host 'No release, marketplace upload or installation performed.'
