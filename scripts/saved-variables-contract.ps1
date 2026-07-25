function Assert-StatsProSavedVariablesContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TocText,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $directives = [regex]::Matches(
        $TocText,
        '^##[ \t]+SavedVariables[ \t]*:[ \t]*([^\r\n]*?)[ \t]*\r?$',
        [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($directives.Count -ne 1) {
        throw "$Description must contain exactly one SavedVariables directive; found $($directives.Count)."
    }

    $roots = @($directives[0].Groups[1].Value -split ',' | ForEach-Object { $_.Trim() })
    if ($roots.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace($roots[0]) -or
        -not [System.StringComparer]::Ordinal.Equals($roots[0], 'StatsProDB')) {
        throw "$Description SavedVariables directive must name only StatsProDB; got '$($roots -join ', ')'."
    }

    $perCharacterDirectives = [regex]::Matches(
        $TocText,
        '^##[ \t]+SavedVariablesPerCharacter[ \t]*:[^\r\n]*\r?$',
        [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($perCharacterDirectives.Count -gt 0) {
        throw "$Description must not contain a SavedVariablesPerCharacter directive; found $($perCharacterDirectives.Count)."
    }
}
