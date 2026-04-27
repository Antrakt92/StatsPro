# Changelog

## 1.0.8 — Primary stats now show effective (buffed) values + armor combat-taint guard

### Fixed

- **Primary stats (Strength / Agility / Intellect) now show the same value
  Blizzard's character sheet displays.** The addon was capturing `UnitStat`'s
  first return value (base stat — level + items, no temporary modifiers)
  instead of the second (effective stat — including raid buffs, food, flask,
  and active cooldowns). For a buffed raider this could understate Primary
  by 10–25%; for an unbuffed character solo'ing in the world the values
  matched. New dedicated `GetEffectiveStat` helper captures both returns and
  prefers `effectiveStat`, falling back to `stat` if the API ever drops the
  second value. Affects users who explicitly enabled `Show Strength` /
  `Show Agility` / `Show Intellect` (off by default).
- **Armor damage-reduction calculation no longer aborts mid-pull on
  `[ADDON_BLOCKED]` if armor effectiveness is briefly secret-tagged.** In
  Mythic+ transitional moments where `InCombatLockdown()` lags real combat
  state, `PaperDollFrame_GetArmorReduction` can return a secret-tainted
  number; the subsequent `if raw <= 1` comparison would raise a taint error
  and silently abort the OnUpdate tick. The function is now wrapped in
  `pcall` and the return is filtered through `issecretvalue` before any
  arithmetic — the row simply shows 0% briefly until the next clean tick,
  rather than nuking the whole stats refresh.

### Internal

- `BuildDurabilityLines` early-return path now explicitly returns 5 values
  (`labels, ratings, values, repairStr, nil`) matching the normal path's
  arity. Cosmetic — consumers already handled the implicit nil via `or ""`
  fallback in `Panel:SetTextSafe` — but explicit intent prevents a future
  reader from wondering whether the missing return is load-bearing.

## 1.0.7 — Translation polish + Korean Armor/Defensive disambiguation

### Fixed

- **Defensive panel no longer freezes in split mode when offensive stats are
  all disabled.** The per-frame update timer was hosted on `mainPanel.frame`;
  when that panel went empty (split mode + primary/offensive/tertiary all off
  → `lineCount=0` → `Hide()`), WoW stopped firing OnUpdate on the hidden
  frame and the defensive panel's live values (Dodge / Parry / Armor /
  Durability) would freeze on whatever was last computed. Tank-focused
  defensive-only configurations were the most likely to hit this. The ticker
  now lives on a dedicated invisible frame that's never hidden by user logic.
- **SwiftStatsLocal → StatsPro one-time migration now runs reliably.** WoW
  loads each addon's SavedVariables alongside that addon's code; in the
  typical alphabetical install order (`StatsPro` loads before
  `SwiftStatsLocal`), `_G.SwiftStatsLocalDB` was still nil at StatsPro's
  file-scope migration check — the check silently skipped and the user's
  legacy panel position, font, and colors didn't carry forward to a fresh
  StatsPro install. The migration now runs in `PLAYER_ENTERING_WORLD` (after
  every enabled addon's SavedVariables are loaded), making the carry-forward
  reliable regardless of which addon happened to load first.
- **koKR: Armor and Defensive section header no longer collide.** Both labels
  rendered as `방어` previously, which made the sectioned-mode `— 방어 —`
  divider visually merge with the Armor row immediately beneath it. New split:
  Armor stays `방어` (matches WoW Korean stat term `방어도`), Defensive section
  divider becomes `수비` — clearly distinct and reads as a category header.
- **koKR: Parry/Block now distinguishable.** Parry was `막기`, Block was `방패`
  — readable but inverted from the most common Korean WoW community convention.
  New split: Parry = `쳐막` (community shorthand for `쳐서 막다`, "strike-block"),
  Block = `막기` (standard WoW Korean client term for blocking).

### Changed

- **Translation polish across deDE / esES / esMX / frFR / itIT / ptBR / ruRU.**
  Deeper review pass against each language's WoW client term and theorycrafting
  community shorthand. Most rows where the previous draft used 3-char
  abbreviations (e.g. `Cel` / `Esq` / `Par` / `Forc` / `Agi`) now use 4-char
  forms that read as words rather than truncations. Selected swap-outs:
  - **ruRU:** Parry `Пар` → `Пари`, Leech `Кров` → `Вамп` (avoids confusion
    with `Кровотечение` / Bleed), Durability `Прч` → `Проч`.
  - **deDE:** Vers `Viel` → `Viels` (evokes `Vielseitigkeit`, doesn't collide
    with the everyday word `viel` = much/many), Strength `Stä` → `Stär`,
    Durability `Halt` → `Haltb` (avoids `Halt` = stop).
  - **frFR:** Strength `For` → `Forc`, Durability `Dur` → `Dura` (avoids
    `Dur` = hard), Dodge `Esq` → `Esqu`.
  - **esES** / **esMX:** Haste `Cel` → `Cele`, Leech `Suc` → `Robo` (matches
    WoW Spanish `Robo de vida` term), Strength `Fue` → `Fuer`, Agility `Agi` → `Agil`,
    Dodge `Esq` → `Esqu`.
  - **itIT:** Parry `Par` → `Para`, Armor `Arm` → `Armat`, Strength `For` → `Forz`,
    Agility `Ag` → `Agil` (`Ag` was visibly truncated at 2 chars), Repair `Rip` → `Ripa`.
  - **ptBR:** Strength `For` → `Forç` (with cedilla), Agility `Agi` → `Agil`,
    Dodge `Esq` → `Esqu`.
  - **enUS / zhCN / zhTW:** unchanged — already match official WoW client
    terminology (CJK locales use the in-game WoW Chinese stat terms verbatim).

### Internal

- Comment hygiene: removed two stale "line N" references in source comments
  (line numbers drift after every edit) and two version-tag references
  (`v1.0.4` / `v1.0`) — bug history belongs in this CHANGELOG and `git log`,
  source comments stay timeless. `LABELS_BY_LOCALE` header comment now warns
  about the Armor/Defensive same-word trap so future locale additions don't
  reintroduce it.

## 1.0.6 — Localized stat labels (all 11 WoW locales)

### Added

- **Stat labels now display in your WoW client's language by default** —
  on-screen labels (Crit / Haste / Mastery / Vers / Dodge / Parry / Block /
  Armor / Strength / Agility / Intellect / Leech / Avoidance / Speed /
  Durability / Repair) are translated into hand-curated short-form
  equivalents matching StatsPro's compact 4-7 char visual language across
  all 11 retail WoW locales: deDE, esES, esMX, frFR, itIT, koKR, ptBR,
  ruRU, zhCN, zhTW (enUS is unchanged). Examples: ruRU shows "Крит / Хаст /
  Маст / ...", zhCN shows "暴击 / 急速 / 精通 / ...", deDE shows "Krit /
  Tempo / Meist / ...". Translations cover both standard WoW client terms
  (e.g. zhCN's `暴击`) and theorycrafting-community shorthand where the
  client term is too long (e.g. ruRU's `Хаст` for Haste, since the WoW
  client uses "Скорость" which would collide with Speed).
- **Sectioned-mode divider is also localized** — in Sectioned display mode,
  the `— Defensive —` separator between offensive and defensive rows now
  uses the same locale (e.g. ruRU `— Защита —`, zhCN `— 防御 —`,
  frFR `— Défense —`).
- **"Use localized stat names" toggle on the Display tab** — non-English
  clients can switch back to the previous compact English labels via this
  checkbox (Display tab → Localization). Toggle is hidden on enUS clients
  (no localized form to switch to). Saves automatically; no `/reload`
  needed. The toggle's example text dynamically reflects the user's own
  locale — e.g. on a German client it reads "(e.g. 'Krit' instead of
  'Crit')" with the locale's actual translation embedded.
- **Translation quality note** — ruRU is user-confirmed; the other 9
  locales are best-effort drafts based on cognates, theorycraft community
  conventions, and per-locale WoW client term truncations. If a label
  reads oddly to you as a native speaker of your client's language,
  please open an issue at github.com/Antrakt92/StatsPro/issues with the
  suggested correction — it's a one-string per-row fix and would ship
  in v1.0.7. Native font glyphs (Cyrillic, Hangul, CJK) render correctly
  out of the box on default WoW fonts; if you've selected a custom Latin-
  only font via LibSharedMedia and labels show as `?` boxes, switch back
  to a default font in Display tab → Typography.

### Fixed

- **Repair-row label no longer flickers blank for one frame after a
  font change.** Previously `Panel:ApplyStyle` re-applied every other
  panel FontString from cached text, but `repairLabelText` was missed —
  the "Repair:" / "Рем:" / "修理:" word would vanish for one OnUpdate
  tick after a Display tab → Typography font change. Pre-existing
  v1.0.5 issue; closed for v1.0.6 because the bug becomes more visible
  on non-English clients (the user's own language flickers).

### Behavior change for non-English-locale users

- **First `/reload` after upgrade switches your panel from English to
  localized labels.** This is the new default. To keep the previous
  English appearance: open Display tab → Localization → uncheck "Use
  localized stat names". Setting persists across `/reload`, logout,
  and across all characters on the account (StatsPro DB is account-wide).
- **English (enUS) clients see no change.** The Localization section is
  hidden in your settings; your panel renders exactly as before.

### Known limitation (acknowledged, fix tracked for v1.0.7+)

- The Stat Colors color-picker rows in the settings window still show
  English labels ("Crit color", "Mastery color", etc.) even when the
  panel is rendering in your locale. The on-screen panel — the surface
  you actually look at during play — is fully localized; only the
  config-UI rows are still English. A separate L-table for the entire
  settings window is tracked.

### Internal

- `LABELS_BY_LOCALE` table indexed by `GetLocale()` return values; each
  locale entry has 17 keys (16 stat-label keys + `Defensive` for the
  sectioned-mode divider). At addon load `LOCALIZED_LABELS` is selected
  once via `LABELS_BY_LOCALE[GetLocale()] or LABELS_BY_LOCALE.enUS`.
- New helpers: `L(englishKey)` (identity-fast-path when toggle off,
  single table read when on); `FormatLabel(colorHex, englishKey)`
  (replaces nine hand-rolled `string.format("|cff%s%s:|r", ...)` sites
  across `BuildPrimaryLines` / `BuildOffensiveLines` (table loop + Vers
  branch) / `BuildTertiaryLines` (table loop + Speed branch) /
  `BuildDefensiveLines` (table loop + Armor branch) / `BuildDurabilityLines`
  (Durability + Repair)); `DefensiveHeader()` (replaces the static
  `DEFENSIVE_HEADER` constant for sectioned-mode divider — resolves at
  use time so toggle flips immediately update the divider).
- `HAS_LOCALIZATION` flag (resolved once at load) gates the config UI:
  the Localization section + checkbox render only on non-enUS locales.
  No dead switch on enUS.
- `Panel:ApplyStyle` now caches `lastRepairLabelText` symmetrically with
  the existing `lastLabelText` / `lastRatingText` / `lastValueText` /
  `lastRepairText` family — completes the font-change resilience surface.
- `CURRENT_DB_VERSION` stays at 3 (no schema-flip; existing idempotent
  init-loop in `MigrateDB` populates the new field on upgrade — same
  pattern v1.0.5 used for its five new defaults).
- `/ss debug` dump now includes a `locale: client=<X> curated=<bool>
  toggle=<bool>` line for self-serve diagnosis.

## 1.0.5 — Offensive toggles + leak-free reset

### Added

- **Master "Show Offensive Stats" toggle on the Stats tab** — Crit / Haste /
  Mastery / Versatility now each have their own visibility checkbox plus a
  master toggle, mirroring the Tertiary and Defensive sections. Healers and
  tanks who only want defensive + tertiary stats on screen can finally hide
  the offensive block without disabling both display-format toggles. Includes
  an opt-in `Hide Zero Values` filter (default off) for users with classes
  that drop a stat to zero.
- **`/ss debug` slash subcommand** — dumps addon version, DB version, all
  visible-toggle states, panel positions, and current Lua memory usage into
  chat. Useful for self-serve bug-report diagnostics — paste the output
  instead of describing config state by hand.

### Fixed

- **Defensive sub-toggles now grey out when master is off** — `Show Dodge` /
  `Show Parry` / `Show Block` / `Show Armor` now follow the same dependency-
  disable pattern already used by the Tertiary tab (Leech/Avoidance/Speed
  greyed when master Tertiary is off) and the Durability sub-controls.
- **"Reset to Defaults" no longer leaks the config frame** — every Reset click
  used to orphan the previous `StatsProConfigFrame` global plus all its child
  widgets in `_G` (CreateFrame's named globals are immortal in WoW Lua) and
  build a brand new frame. Long sessions with frequent resets gradually grew
  Lua memory. Widget visuals are now re-synced from the freshly-reset DB
  in-place; the frame is reused.
- **Repair coin moved to its own row below stats** — the coin string with
  embedded gold/silver/copper icons used to share a row with the `Repair:`
  label inside the multi-line stats label FontString, and the coin width was
  not participating in panel auto-fit. In narrower panel layouts (single-
  column display modes with no defensive rows) the coin extended leftward
  across the rating/value area and into the `Repair:` label, producing a
  visual mash like `Repair55..88..12`. The Repair row is now visually
  separated from the stats: stat columns render compactly at the top of the
  panel, and the Repair label + coin sit on a dedicated row below them with
  a 1px gap. Stat columns stay packed at the panel's left edge even when the
  panel widens to accommodate the coin, so values are no longer pushed to the
  far-right with a big gap from their labels. Toggling `Show Repair Cost`
  off shrinks the panel back to stat-content size.

### Internal

- Config-UI helpers (`CreateCheckbox`, `CreateColorSwatch`, `CreateColorPicker`)
  auto-register a "refresher" closure when they build a widget. The Reset
  button walks this list to re-sync each widget's visual state from DB
  without rebuilding the frame.
- Extracted `GetColor(statName)` helper — shared between `OpenColorPicker`,
  `CreateColorSwatch`, `CreateColorPicker`, and the new color-swatch
  refreshers. Single source of truth for "DB color or fallback to default".
- `OFFENSIVE_STATS` table extended with a `showKey` field per row, enabling
  the per-stat guard in `BuildOffensiveLines` (mirrors the existing
  `DEFENSIVE_STATS` / `TERTIARY_STATS` pattern).

## 1.0.4 — Combat-safe lock toggle

### Fixed

- **Lock Frames toggle stuck after combat** — switching the toggle off mid-combat
  updated saved settings but `Panel:Unlock` no-op'd via its `InCombatLockdown`
  guard, leaving panels mouse-disabled until `/reload`. A `PLAYER_REGEN_ENABLED`
  handler now re-applies the saved lock state on combat exit.
- **SwiftStatsLocal migration aliased sub-tables** — first-load migration
  shallow-copied the legacy DB, so `StatsProDB.colors` shared a Lua table reference with
  `SwiftStatsLocalDB.colors` for as long as both addons were enabled. Color-picker
  edits in either silently mutated the other. Sub-tables now go through `CopyTable`.
- **Default-fill skipped on coincidental version match** — `MigrateDB`
  early-returned when `db.dbVersion == CURRENT_DB_VERSION`, so SwiftStatsLocal migrants
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

- **Wide gap / truncated percentage in single-display modes** —
  `FontString:GetStringWidth()` on a mostly-empty multi-line string (e.g. `"\n\n\n92.3%"`) is unreliable
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
- **Scrollable settings window** — the config window is now wrapped in a `ScrollFrame`,
  so the full Stats / Defensive content remains reachable on small monitors and
  windowed-mode layouts where the upstream fixed-height frame used to clip controls
  off the bottom of the screen. Scroll position resets to top on tab switch.
- **Native Blizzard Settings panel integration** — StatsPro registers itself as a
  category in WoW's built-in Settings UI (`Esc → Options → AddOns → StatsPro`).
  Clicking the launcher opens the addon's three-tab config window. Discoverable
  for users who never learn slash commands; coexists with `/ss` and the in-game
  config opened from the launcher button.

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

### Removed

- **Minimap button** — the upstream `SwiftStatsMinimapButton` (drag-around minimap
  icon with left-click toggle and right-click config) was removed. The same actions
  are now reachable via `/ss toggle`, the native Blizzard Settings entry, or the
  master visibility checkbox in the config window. Frees minimap real estate for
  users running many addons; the `showMinimapButton` and `minimapPos` settings are
  no longer read.
- **Legacy slash subcommands** — the upstream `move`, `unlock`, `lock`, `reset`,
  `scale N`, and `size N` verbs were removed in favor of doing the same actions
  through the redesigned Settings window (drag-to-move while unlocked, scale slider,
  font-size slider, Reset button). Remaining commands: `/ss` (open config),
  `/ss show`, `/ss hide`, `/ss toggle`, `/ss help`. Macros referencing the removed
  verbs need to be updated.

### Migrated

- Existing **SwiftStatsLocal** users keep all their settings — `StatsProDB` is populated
  from `SwiftStatsLocalDB` on first load if present. Old DB is left untouched.
