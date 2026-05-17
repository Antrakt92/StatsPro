# StatsPro Archon M+ Targets Design

> Status: current design reference, refreshed after the initial implementation.
> Generated data now uses schema v2 with Mythic+ and Raid snapshots. The
> private scheduled data-only release flow is documented in
> `WOW/stats-pro-meta/docs/runbooks/statspro-archon-target-refresh.md`.

## Goal

StatsPro will show a small, high-value target comparison for secondary stats:
the player's current rating, the selected Archon target rating, and the missing
or surplus rating. The shipped data sources are Archon M+ High Keys
`high-keys/all-dungeons/this-week` and Archon Raid Mythic `all-bosses`.

The addon must not fetch network data in game. A private local build/update
script in the `WOW` coordination repository will collect Archon snapshots before
release, generate a Lua data file, and copy that generated file into the public
StatsPro addon repository for packaging.

## Scope

Included in the first version:

- Retail Midnight StatsPro only.
- Mythic+ and Raid target profiles.
- Archon M+ URL shape:
  `https://www.archon.gg/wow/builds/{spec}/{class}/mythic-plus/overview/high-keys/all-dungeons/this-week`
- Archon Raid URL shape:
  `https://www.archon.gg/wow/builds/{spec}/{class}/raid/overview/mythic/all-bosses`
- All supported player specializations.
- Secondary stat targets only: critical strike, haste, mastery, versatility.
- Tooltip-only display on StatsPro secondary stat rows, selected by a settings
  dropdown.
- Snapshot metadata in generated data: source, activity, bracket, dungeon,
  window, capture date, and source URL per spec.
- Safe runtime behavior when data is missing or stale.

Excluded from the first version:

- Per-dungeon targets.
- Per-boss raid targets.
- Talent builds, hero talent builds, gear, consumables, rotations, or guide text.
- In-game networking.
- General feature-release tag publishing. A guarded private automation may
  publish data-only Archon refreshes under the workspace release-safety rules.

## Architecture

The feature has three separate layers.

1. `WOW/stats-pro-meta/tools/update-archon-targets.ps1`

   The private collector runs on the developer machine. It requests each Archon
   M+ High Keys and Raid Mythic All Bosses page, extracts the embedded Next.js
   JSON payload, locates the stat priority section, normalizes the four
   secondary stat ratings, and writes deterministic Lua snapshots into the
   StatsPro addon repository.

2. `StatsPro_ArchonTargets.lua`

   The generated snapshot is loaded by `StatsPro.toc` before `StatsPro.lua`.
   It exposes one global table, `StatsProArchonTargets`, with profile metadata
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
  schemaVersion = 2,
  source = "archon",
  snapshots = {
    ["mythicPlus"] = {
      label = "M+ High Keys",
      title = "M+ Target",
      activity = "mythic-plus",
      bracket = "high-keys",
      dungeon = "all-dungeons",
      window = "this-week",
      capturedAt = "2026-05-15",
      specs = {
        ["DEATHKNIGHT"] = {
          ["frost"] = {
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
    },
    ["raid"] = {
      label = "Raid Mythic All Bosses",
      title = "Raid Target",
      activity = "raid",
      difficulty = "mythic",
      boss = "all-bosses",
      window = "last-14-days",
      capturedAt = "2026-05-15",
      specs = {},
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
- Snapshot: selected profile label and capture date.

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

## Data-Only Refresh Flow

The private scheduled automation may refresh and publish only generated Archon
target data when all release-safety gates pass. The current runbook in the
private `WOW` repository is authoritative; this public spec records the addon
contract only.

1. Run the collector.
2. Write or update `StatsPro_ArchonTargets.lua` in the public StatsPro repo.
3. Validate both Mythic+ and Raid snapshots across all supported specs.
4. Run existing StatsPro verification.
5. Commit generated target changes only when the semantic target data changed.
6. For the private automation path only, publish a PATCH tag after the guarded
   release checks pass and the release workflow/package assets are confirmed.

Normal feature, fix, UI, behavior, infrastructure, manual, and non-Archon
releases still require the workspace in-game verification or explicit waiver
gate before any `vX.Y.Z` tag push.

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
- GitHub Actions scheduling and data-only release publishing now exist outside
  this public repo. Keep collector/runbook details private in `WOW`; the public
  addon continues to ship only transformed generated data and runtime readers.
