# Changelog

## 1.0.4 — Combat-safe lock toggle

### Fixed

- **Lock Frames toggle stuck after combat** — switching the toggle off mid-combat
  updated saved settings but `Panel:Unlock` no-op'd via its `InCombatLockdown`
  guard, leaving panels mouse-disabled until `/reload`. A `PLAYER_REGEN_ENABLED`
  handler now re-applies the saved lock state on combat exit.
- **SwiftStatsLocal migration aliased sub-tables** — first-load migration shallow-
  copied the legacy DB, so `StatsProDB.colors` shared a Lua table reference with
  `SwiftStatsLocalDB.colors` for as long as both addons were enabled. Color-picker
  edits in either silently mutated the other. Sub-tables now go through `CopyTable`.
- **Default-fill skipped on coincidental version match** — `MigrateDB` early-
  returned when `db.dbVersion == CURRENT_DB_VERSION`, so SwiftStatsLocal migrants
  whose legacy DB happened to carry `dbVersion=3` never picked up StatsPro's
  default scalars or color entries. The init loops now run before the version
  early-return (idempotent — only fills missing keys).

### Improved

- **Repair cost no longer widens the panel** — coin string is rendered on a
  dedicated single-line FontString anchored to the same row as the `Repair:`
  label, RIGHT-aligned to the panel edge and free to extend leftward past the
  rating/value column for wide values. The `Repair:` label still sits in the
  main label column, aligned with the other labels. Previously the wide
  `60g 63s 9c` coin string inflated the value column and stretched the whole
  panel just for that one row; now panel width is determined purely by stat
  content.
- **Tertiary sub-toggles grey out when master is off** — `Show Leech` /
  `Show Avoidance` / `Show Speed` now follow the same dependency-disable pattern
  the Defensive tab already uses for `Show Repair Cost` (gated on `Show Durability`)
  and the durability swatch (gated on `Auto Color by Threshold`).
- **Font dropdown refreshes on each open** — fonts registered via LibSharedMedia
  by addons that load after StatsPro now appear in the dropdown without requiring
  `/reload`. Previously the list was built once at config-menu open time.

### Internal

- Stripped stale `v2.2` version-tag noise from `defaults`, `cached`, and
  `CACHED_BOOL_KEYS` block comments.
- Extracted shared `SetCheckboxEnabled` helper for dependent-toggle greying;
  `ApplyRepairCostEnabled` now calls it instead of duplicating the
  Enable/Disable + text-color logic.
- Dev-only build label now reads e.g. `1.0.4-dev` instead of `vdev` when running
  from local source (token-substituted release builds are unaffected).

## 1.0.3 — Refresh-rate slider

### Added

- **Refresh Rate slider** on the Display tab (range `0.1s – 1.0s`, default `0.5s`).
  Controls how often stat values recompute on screen. Lower = smoother updates,
  higher = lighter on CPU. Previously the only way to change this was the hidden
  `/run StatsProDB.updateInterval = X` workaround.

### Internal

- Extracted `IsDualColMode()` helper — single source of truth for the column-routing
  decision now used uniformly by `FmtRatingPct`, `FmtPctOnly`, `RouteValueOnly`, and
  the `UpdateStats` value-col join.
- Wired automated CurseForge upload from the GitHub Actions release workflow
  (`X-Curse-Project-ID` populated in TOC, `CF_API_KEY` secret set on the repo).
  Future release tags now auto-publish the file + per-version changelog from
  `CHANGELOG.md` to CurseForge with no manual paste step.

## 1.0.2 — Dynamic version display

### Fixed

- **Settings window and Blizzard interface options panel showed stale "v1.0"** —
  the version string was hardcoded in the title and launcher labels, so installing
  v1.0.1 still displayed "StatsPro v1.0 Settings". Both labels now read the version
  from the TOC at runtime via `C_AddOns.GetAddOnMetadata`, so future releases keep
  the in-game UI in sync without a code edit.

## 1.0.1 — Single-column display polish

### Changed

- **Single-column layout when only one display dimension is on** — toggling either
  `Show Rating` or `Show Percentage` off now stacks every visible number in a single
  RIGHT-justified column (the rating column). Previously, non-rating rows (Primary
  stats, Defensives, Durability, Repair) still rendered in the value column, which
  collapsed to a degenerate empty layout when most rows were empty there — leaving
  visible gaps and, in the rating-only case, truncating Durability's percentage.

### Fixed

- **Wide gap / truncated percentage in single-display modes** — `FontString:GetString-
  Width()` on a mostly-empty multi-line string (e.g. `"\n\n\n92.3%"`) is unreliable
  in 12.x retail, leaving cached column widths stale and the panel layout broken.
  `FmtRatingPct`, `FmtPctOnly`, and the inline Primary/Armor/Durability/Repair pushes
  now route their value into the rating column whenever the dual-column mode is off,
  and `UpdateStats` passes a literal `""` to the value FontString in that case —
  bypassing the unreliable measurement entirely.
- **In-combat taint crash spam** — an over-eager all-empty short-circuit in
  `JoinLinesSecretSafe` compared list elements against `""`, which raises a taint
  error when in-combat stat reads put a secret-tainted string in the list. The
  comparison was removed; all-empty detection now lives at call sites (`UpdateStats`)
  using out-of-band config flags so no string content ever needs to be compared.

## 1.0.0 — Initial release

First public release under the StatsPro name. Originally inspired by SwiftStats v2.1
by TaylorSay (MIT) — substantially rewritten, with only ~9% of upstream code remaining
verbatim (boilerplate, color defaults, basic stat list). Everything below is original
work added on top of (or in place of) the upstream foundation.

### Added

- **Defensive stats panel** — Dodge, Parry, Block, Armor (as % damage reduction).
  Independent visibility toggle from the offensive stats; per-stat color swatches; hide-zero option.
- **Durability tracking** — single-pass scan of equipment slots (skipping shirt/tabard),
  with toggle between average and worst-slot percentage. Vendor-format precision (`%.1f%%`).
- **Auto-color durability** — green ≥60%, yellow ≥30%, red <30%. Override available
  by disabling auto-color and picking a custom color.
- **Repair cost** — live vendor-format coin string using `GetCoinTextureString` with
  inline gold/silver/copper icons. Rendered on its own line below durability to avoid truncation.
- **Display modes** — three layouts: Flat (one panel, all stats), Sectioned (one panel
  with `— Defensive —` divider), Split (separate draggable panels for offensive/defensive).
- **Multi-panel positioning** — defensive panel is independently draggable when in Split mode.
- **Master visibility toggle** — show/hide all panels with a single checkbox or `/ss toggle`.
- **Settings UI rewrite** — three-tab config window (Display / Stats / Defensive) with
  inline color swatches, dependency-aware enable/disable (Repair Cost greyed out when
  Durability is off, durability swatch greyed when Auto Color is on).

### Changed

- **Default text alignment** — `RIGHT` (was `LEFT`). Migrated automatically for users
  on the old default; explicit user choices preserved.
- **Effective armor handling** — uses `pcall(UnitArmor)` and filters secret values for
  12.x retail compatibility. Refresh runs out-of-combat only.
- **Versatility** — split into rating + flat dual-source display, with combat-safe caching
  (recompute OOC, use cached value in combat).
- **Repair cost API** — switched from `GameTooltip:SetInventoryItem` (returns secret
  values in 12.x) to `C_TooltipInfo.GetInventoryItem` + `TooltipUtil.SurfaceArgs`.

### Fixed

- **Misaligned rating + percentage columns** — when both "Show Rating" and "Show Percentage"
  were on, the `|` separator and percent values drifted horizontally row-to-row because
  rating widths varied (46 vs 843). Rating is now its own RIGHT-justified third FontString
  between label and value, so all rating right-edges line up vertically and the percent
  column has a clean fixed left edge.
- **Frame position not persisting** — `SetUserPlaced(true)` now called after `SetPoint(...)`
  in `LoadPosition`, ensuring 12.x retail correctly commits the user's drag-saved anchor.
- **Position lost on /reload** — `PLAYER_LOGOUT` handler now saves both panels
  defensively, in case the user drags via paths that bypass `OnDragStop`.
- **Durability % differing from vendor** — default switched to average (matching the vendor
  display); worst-slot mode preserved as opt-in.
- **In-combat secret-value taint** — every stat-API read (`GetCombatRating`,
  `GetUnitMaxHealthModifier`, `UnitArmor`, `GetUnitSpeed`, etc.) now passes through
  `pcall` + `issecretvalue` filtering before any arithmetic or comparison.

### Migrated

- Existing **SwiftStatsLocal** users keep all their settings — `StatsProDB` is populated
  from `SwiftStatsLocalDB` on first load if present. Old DB is left untouched.
