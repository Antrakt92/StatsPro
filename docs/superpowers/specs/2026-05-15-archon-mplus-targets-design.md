# StatsPro Archon M+ Targets Design

## Goal

StatsPro will show a small, high-value target comparison for secondary stats:
the player's current rating, the current M+ High Keys target rating, and the
missing or surplus rating. The first data source is Archon M+ pages for
`high-keys/all-dungeons/this-week`.

The addon must not fetch network data in game. A private local build/update
script in the `WOW` coordination repository will collect Archon snapshots before
release, generate a Lua data file, and copy that generated file into the public
StatsPro addon repository for packaging.

## Scope

Included in the first version:

- Retail Midnight StatsPro only.
- Mythic+ only.
- Archon URL shape:
  `https://www.archon.gg/wow/builds/{spec}/{class}/mythic-plus/overview/high-keys/all-dungeons/this-week`
- All supported player specializations.
- Secondary stat targets only: critical strike, haste, mastery, versatility.
- Tooltip-only display on StatsPro secondary stat rows.
- Snapshot metadata in generated data: source, activity, bracket, dungeon,
  window, capture date, and source URL per spec.
- Safe runtime behavior when data is missing or stale.

Excluded from the first version:

- Raid targets.
- Per-dungeon targets.
- Talent builds, hero talent builds, gear, consumables, rotations, or guide text.
- In-game networking.
- Automatic release tag publishing.

## Architecture

The feature has three separate layers.

1. `WOW/stats-pro-meta/tools/update-archon-targets.ps1`

   The private collector runs on the developer machine. It requests each Archon
   M+ High Keys page, extracts the embedded Next.js JSON payload, locates the
   stat priority section, normalizes the four secondary stat ratings, and writes
   a deterministic Lua snapshot into the StatsPro addon repository.

2. `StatsPro_ArchonTargets.lua`

   The generated snapshot is loaded by `StatsPro.toc` before `StatsPro.lua`.
   It exposes one global table, `StatsProArchonTargets`, with source metadata
   and spec-keyed target ratings. The file is treated as generated output and
   should not contain runtime logic.

3. `StatsPro.lua`

   Runtime code reads the generated table and appends tooltip lines for the
   currently visible secondary stat rows. The addon remains fully usable when
   the table is absent, incomplete, or contains no matching current spec.

## Data Shape

The generated Lua table should use stable internal keys:

```lua
StatsProArchonTargets = {
  schemaVersion = 1,
  source = "archon",
  activity = "mythic-plus",
  bracket = "high-keys",
  dungeon = "all-dungeons",
  window = "this-week",
  capturedAt = "2026-05-15",
  specs = {
    DEATHKNIGHT = {
      frost = {
        sourceUrl = "https://www.archon.gg/wow/builds/frost/death-knight/mythic-plus/overview/high-keys/all-dungeons/this-week",
        targets = {
          mastery = 1043,
          crit = 921,
          haste = 419,
          versatility = 92,
        },
        order = { "mastery", "crit", "haste", "versatility" },
      },
    },
  },
}
```

The collector may preserve Archon order, but runtime comparisons use numeric
targets by stat key. The generated file should be sorted by class token and spec
key so diffs are easy to review.

## Runtime UX

StatsPro will add mouseover tooltips to secondary stat rows. The tooltip should
keep StatsPro's compact HUD style and add only the target-specific lines:

- Target: rating from snapshot.
- Current: current player rating.
- Missing: positive rating deficit when current is below target.
- Over: positive surplus when current is above target.
- Snapshot: M+ High Keys, All Dungeons, this week, capture date.

The tooltip must avoid copying Archon guide text, page copy, charts, talent
strings, or other guide content. It only uses transformed numeric targets.

## Runtime Integration

StatsPro currently renders rows with separate FontStrings for labels, ratings,
and values. Tooltip support should add row hit areas without disrupting
three-column alignment, repair-row sizing, or existing right-click settings.

Implementation constraints:

- Keep `frame:EnableMouse(true)` behavior intact.
- Do not read `StatsProDB` directly in hot render paths.
- Use existing dirty-flag and cached-value patterns.
- Do not merge durability or repair rows into target logic.
- Guard stat API values with the existing 12.x secret-value rules before doing
  arithmetic or formatting.
- If target data is missing, skip only the Archon tooltip block.

## Collector Behavior

The collector should:

- Build the full spec URL list from explicit class/spec slug mappings.
- Fetch pages with clear User-Agent text identifying StatsPro.
- Extract `script#__NEXT_DATA__` and parse JSON with PowerShell JSON APIs.
- Locate the stat priority payload by structure rather than brittle line text.
- Normalize stat labels to `crit`, `haste`, `mastery`, and `versatility`.
- Fail the run if a supported spec page returns no parseable target ratings.
- Emit a concise summary: specs parsed, specs failed, output path, capture date.
- Write deterministic Lua output without secrets.

The collector should not store API credentials, cookies, personal data, or raw
HTML pages in either repository. The collector itself remains private in the
`WOW` repository; the public StatsPro repository receives only transformed
generated targets.

## Daily Update Flow

The first automation should stop at a prepared commit or pull request:

1. Run the collector.
2. Write or update `StatsPro_ArchonTargets.lua` in the public StatsPro repo.
3. Run Lua syntax checks and existing StatsPro verification.
4. Commit generated target changes when the snapshot changed.
5. Leave release tagging/manual publishing for a separate, gated step.

StatsPro release safety still applies: no automatic `vX.Y.Z` tag push until the
user has verified the addon in game or explicitly waived the check.

## Error Handling

Collector failures should be loud before release and quiet in game:

- Network, HTTP, or JSON parse failures fail the collector run.
- Missing targets for any supported spec fail the collector run.
- Generated output is not updated on partial failure.
- Runtime missing-data paths simply omit the target tooltip block.
- Runtime invalid numeric data is ignored for that stat.

## Testing

Collector tests should cover:

- Parsing a saved representative Archon `__NEXT_DATA__` payload.
- Stat label normalization.
- Lua output determinism.
- Failure when a spec has fewer than four secondary stat targets.

Runtime checks should cover:

- `luac5.1 -p StatsPro_ArchonTargets.lua StatsPro.lua`
- Existing `scripts/check-lua.ps1`.
- Smoke coverage for generated table shape when practical.
- In-game `/reload` confirmation before any release tag is pushed.

## Implementation Decisions

- The generated data file is `StatsPro_ArchonTargets.lua`.
- The first update path is a private local script under
  `WOW/stats-pro-meta/tools/` that creates or updates generated data in the
  StatsPro repo and lets the user or Codex prepare a normal StatsPro commit.
- GitHub Actions scheduling and automatic release publishing are out of scope
  for the first implementation pass. They can be added after the parser and
  runtime tooltip have been verified in game.
