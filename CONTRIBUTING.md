# Contributing to StatsPro

[Overview](README.md) · [Checks](#local-verification) · [Release history](CHANGELOG.md)

Bug reports, translation corrections, and focused pull requests are welcome.
Please keep shared changes compatible with World of Warcraft Retail, the supported
WoW Forever beta and Lua 5.1. Both builds use the shared HUD. Forever's stat
sources, class-aware presets and labels live in `StatsPro_Forever.lua`; its load
order is defined in `StatsPro_Forever.toc`. Classic Era and other Classic branches
are outside the supported clients.

## Before opening a pull request

For a bug report, include your client flavor (Retail or Forever), WoW build,
StatsPro version, class and specialization where applicable, and steps to reproduce the problem. For a translation correction,
include the client language and the label you want to change.

Use Git to clone the repository so the checks can inspect tracked files and
release history:

```powershell
git clone https://github.com/Antrakt92/StatsPro.git
cd StatsPro
```

The locked local toolchain runs on Windows. Use PowerShell and allow downloads
from the sources listed in [`scripts/tool-version-locks.json`](scripts/tool-version-locks.json).
You do not need to install Lua tools globally.

## Local verification

From the repository root, run:

```powershell
.\scripts\check-lua.ps1 -EnforceToolLocks
```

The wrapper runs Lua 5.1 syntax checks, the pure-Lua smoke harness, luacheck,
and Lua Language Server diagnostics. In enforced mode it first installs the
exact locked artifacts into an isolated temporary tool root, verifies their
checksums, and executes those owned paths without selecting an ambient `PATH`
match.

The smoke harness has a tracked reachability contract in
[`scripts/smoke-contract.json`](scripts/smoke-contract.json). It records exact
suite counts and fingerprints of unique assertion IDs, so deleting, renaming,
moving, or adding a check requires an intentional contract update. Regenerate it
only after reviewing the test change with:

```powershell
.\scripts\check-lua.ps1 -UpdateSmokeContract -EnforceToolLocks
```

The update is written only after the complete verification gate passes. Review
both the test and contract diffs, then rerun the normal `-EnforceToolLocks`
command before committing.

For shared user-visible changes, also test both supported clients after `/reload`.
Include screenshots for layout, Settings, font, color or localization changes.
For a flavor-specific change, test the affected client and preserve the other
flavor's local regressions.

The local gate also checks Forever stat sources and focused HUD regressions.
It exercises every preset and the complete optional catalogue across all nine
Forever classes, including profile transfers and forced-language row alignment.
Build a Forever beta archive with `scripts/build-forever-package.ps1`; validate it with
`scripts/test-forever-package.ps1 -ArchivePath <path>`. This builder does not publish.
Changes to Forever need login, combat, character stats, Settings, profile and reload
checks in that client. Retail's automatic Archon releases remain separate.

## Architecture guide

Most runtime code lives in [`StatsPro.lua`](StatsPro.lua). Important boundaries:

- `Panel:SetTextSafe` renders aligned label, rating, and percentage columns,
  with dedicated repair-row strings and clean measurement caches.
- `FmtRatingPct`, `FmtPctOnly`, and `RouteValueOnly` route display values without
  leaving empty columns when a user changes value-display options.
- `UpdateStats` builds logical Character, Offensive, Tertiary (Utility in
  Forever), Defensive, Item Level, Durability and Repair blocks before routing
  them to panels.
- `LABELS_BY_LOCALE`, `L`, and the label-formatting helpers provide live
  localization and UTF-8-safe label styles.
- `MigrateDB` owns SavedVariables schema upgrades. Changes to defaults need a
  migration that preserves explicit user choices.
- Profile settings and account settings are intentionally separate. Language
  and refresh rate are account-wide; HUD content and presentation are profile-scoped.

Retail and Forever can return restricted values from stat, unit, tooltip and
measurement APIs. Do not assume that a Classic-style stat catalog makes combat
values unrestricted. Only clean finite values may drive comparisons, visibility,
layout arithmetic, or persistent caches. Display-only paths may have narrower
rules. Follow the guarded patterns already used by adjacent code.

## Change scope

- Keep one behavior change and its regression coverage together.
- Update every affected locale when adding or changing user-visible strings.
- Keep marketplace descriptions and screenshots synchronized with the public UI.
- Do not commit local workspace notes, private plans, credentials, or generated
  release archives.

See [`CHANGELOG.md`](CHANGELOG.md) for shipped behavior and
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) for bundled dependency provenance.

## Releases

Retail and Forever use separate installable archives with the same `StatsPro/`
root folder. The Forever archive uses its flavor-specific TOC and stat module;
it excludes the Retail Archon dataset. Each package retains the full changelog
and required license notices. Keep client flavor and release channel clear in
file names and marketplace metadata, and do not mark Classic Era compatibility.

Retail-only updates do not publish a new Forever package. When the Forever TOC
version changes, update its download link in the README and marketplace
descriptions to that release tag. Do not point Forever downloads at
`releases/latest`: a newer Retail-only release can have no Forever asset.

Maintainers publish releases through the tag-triggered workflow. A normal pull
request does not need a release tag. Release tags must be lightweight so their
Git ref and release attestation name the same commit. Use
`git -c tag.gpgSign=false tag vX.Y.Z`; do not use annotated or signed tags.
Run `scripts/check-release-ancestry.ps1 -Tag vX.Y.Z` before pushing a release
tag. Published tags and assets must never be rewritten. Failed release tags that
never published receive no CHANGELOG heading.

Forever-only maintenance uses lightweight `forever-vX.Y.Z` tags and the separate
Forever beta release workflow. Its version comes from `StatsPro_Forever.toc`,
and its cumulative notes live in [`CHANGELOG-FOREVER.md`](CHANGELOG-FOREVER.md).
These GitHub prereleases contain only the Forever archive and leave Retail's
latest release unchanged. Failed or uncertain uploads recover under a new beta
version; never rerun an upload or move its tag.
