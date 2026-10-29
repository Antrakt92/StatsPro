# StatsPro development reference

[Contributor setup](../CONTRIBUTING.md) · [Player guide](../README.md)

## Repository layout

| Location | Contents |
|---|---|
| Root Lua files and TOCs | Shared HUD, fonts, client adapter, Archon snapshot and loading order |
| `scripts/` | Local checks, Lua regressions, locked tool definitions and packaging helpers |
| `fonts/`, `textures/`, `libs/`, `LICENSES/` | Runtime assets, bundled libraries and licenses |
| `screenshots/` | Images used in the player guide |
| `.github/` | Issue templates and workflows |

TOCs, versioned changelogs and the generated Archon file are inputs to the
packaging and update scripts. Check their consumers before moving them.
Run the commands below from the repository root.

## Updating the smoke contract

The smoke harness has a tracked reachability contract in
[`scripts/smoke-contract.json`](../scripts/smoke-contract.json). It records exact
suite counts and fingerprints of unique assertion IDs, so deleting, renaming,
moving, or adding a check requires an intentional contract update. Regenerate it
only after reviewing the test change with:

```powershell
.\scripts\check-lua.ps1 -UpdateSmokeContract -EnforceToolLocks
```

The update is written only after the complete verification gate passes. Review
both the test and contract diffs, then rerun the normal `-EnforceToolLocks`
command before committing.

## Architecture

Most runtime code lives in [`StatsPro.lua`](../StatsPro.lua). Important boundaries:

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

## Releases

Run commands from the repository root. Build a local Forever archive with
`scripts/build-forever-package.ps1` and validate it with
`scripts/test-forever-package.ps1 -ArchivePath <path>`. These commands do not publish.
Forever changes also need login, combat, stat, Settings, profile and reload checks
in that client; Retail checks do not establish Forever behavior.

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
and its cumulative notes live in [`CHANGELOG-FOREVER.md`](../CHANGELOG-FOREVER.md).
These GitHub prereleases contain only the Forever archive and leave Retail's
latest release unchanged. Failed or uncertain uploads recover under a new beta
version; never rerun an upload or move its tag.
