# Changelog

## 1.1.4 — LSM CJK font auto-detect

### Fixed

- **LSM CJK fonts (NotoCJK / SourceHan / WenQuanYi / PingFang / Microsoft YaHei / JhengHei / SimSun / SimHei / MingLiU / Malgun Gothic / Nanum / Apple SD Gothic Neo) no longer trigger a false "font may not cover glyphs" warning when picking a CJK locale.** Auto-switch logic now recognizes them by font-family name patterns; previously any non-Blizzard-shipped font was conservatively assumed Latin-only. NotoCJK and SourceHan are now also correctly recognized as covering Cyrillic — ruRU users with these fonts no longer see a false warning either.

### Known limitations

- **Custom CJK families with generic filenames** (e.g. `regular.ttf` inside a CJK font pack) still surface the warning because path-based detection can't see the font's display name. Recoverable by ignoring the warning, or report the family on GitHub Issues to add an explicit pattern.
- **Auto-fallback prefers alphabetic-first match.** When multiple LSM CJK fonts are installed, manual font selection is preferred over auto-fallback for best coverage.

## 1.1.3 — Settings window layering fix

### Fixed

- **Settings window now opens above raid frames and HUD addons** (was rendering at `MEDIUM` strata, same as gameplay HUD; now uses `DIALOG`).

## 1.1.2 — Fix empty panels + empty settings on v1.1.x

### Fixed

- **Panels render empty and settings window opens blank on v1.1.0 / v1.1.1.** Hotfix — no DB reset needed, all preferences preserved.

## 1.1.1 — Migration fix for opted-out users

### Fixed

- **Migration honors the v1.0.x "use localized labels = off" opt-out** — earlier v1.1.0 adopters with the toggle off were silently re-enabled. If affected: open Display → Localization → pick "English".

## 1.1.0 — Manual locale override + auto-switch font

### Added

- **New "Language" dropdown in Display tab → Localization.** Pick any of the 11 retail locales for on-screen labels regardless of WoW client locale. Replaces the prior `useLocalizedLabels` boolean.
- **Auto-switch font when picked locale needs glyphs the current font lacks.** Saves your previous font, switches to the locale-aware default, restores on switching back. Manually picking a font clears the auto-switch memory.
- **Inline warning under the Language dropdown** when no installed font covers the picked locale's glyphs. Doesn't block the choice.

### Known limitations

- **LSM CJK fonts treated as Latin-only by the auto-switch logic** — picking a CJK locale fires a "font may not cover glyphs" warning even if your LSM font does cover them. Workaround: pick the LSM font manually via the Font dropdown after switching locale.

## 1.0.12 — Per-locale TOC Notes

### Added

- **Localized addon-list description (`## Notes-<locale>:` TOC fields)** for all 10 non-English retail locales: deDE, esES, esMX, frFR, itIT, koKR, ptBR, ruRU, zhCN, zhTW. Single-line corrections from native speakers welcome via GitHub Issues.

## 1.0.11 — Localized color-picker labels + Localization toggle preview fix

### Added

- **Color-picker rows in the Display tab now show localized stat names** (e.g. ruRU `Крит Цвет:`, zhCN `暴击 颜色:`, deDE `Krit Farbe:`). The two non-stat rows ("Rating Color" / "Percentage Color") still show those words in English; only "Color" is localized.

### Fixed

- **Localization-toggle checkbox preview no longer renders as `?` boxes on CJK clients.** Was hardcoded to `Fonts\FRIZQT__.TTF` (no CJK glyphs); now uses `STANDARD_TEXT_FONT`.

## 1.0.10 — Locale-aware default font (CJK fix) + RGBToHex hardening

### Fixed

- **Localized stat labels now render correctly out of the box on CJK clients (zhCN / zhTW / koKR).** Default font was `Fonts\FRIZQT__.TTF` (no CJK glyphs); now `STANDARD_TEXT_FONT` (locale-aware).
- **Existing users on the old default font are auto-upgraded** (DB v3 → v4). Explicit font choices preserved.
- **Font re-applies cleanly within the upgrade session** — no broken-glyph flash for CJK users until next `/reload`.
- **`RGBToHex` defensive guard against SavedVariables corruption** — out-of-range RGB values from a hand-edited DB are clamped to `[0, 1]`.

## 1.0.9 — Carry forward settings from upstream SwiftStats (TaylorSay)

### Added

- **One-time settings carry-forward from the original SwiftStats by TaylorSay.** Users moving from CurseForge SwiftStats to StatsPro now get their panel position, font, scale, and per-stat colors copied on first launch (fresh installs only). Source priority: `SwiftStatsDB` (upstream public) > `SwiftStatsLocalDB` (older internal name).

## 1.0.8 — Primary stats now show effective (buffed) values + armor combat-taint guard

### Fixed

- **Primary stats (Strength / Agility / Intellect) now show the same value Blizzard's character sheet displays.** Was capturing `UnitStat`'s base return instead of the effective return; for buffed raiders this understated by 10–25%. Affects users who explicitly enabled `Show Strength` / `Show Agility` / `Show Intellect` (off by default).
- **Armor damage-reduction calculation no longer aborts mid-pull** if `PaperDollFrame_GetArmorReduction` returns a secret-tainted number — wrapped in `pcall` + `issecretvalue` filter.

## 1.0.7 — Translation polish + Korean Armor/Defensive disambiguation

### Fixed

- **Defensive panel no longer freezes in split mode when offensive stats are all disabled.** Ticker moved off `mainPanel.frame` to a dedicated invisible frame that's never hidden by user logic.
- **SwiftStatsLocal → StatsPro one-time migration now runs reliably** — moved from file scope to `PLAYER_ENTERING_WORLD`, so it fires regardless of addon load order.
- **koKR: Armor and Defensive section header no longer collide.** Armor stays `방어`; Defensive divider becomes `수비`.
- **koKR: Parry/Block now distinguishable.** Parry `쳐막`, Block `막기` (matches WoW Korean client / community convention).

### Changed

- **Translation polish across deDE / esES / esMX / frFR / itIT / ptBR / ruRU.** Most 3-char abbreviations expanded to 4-char readable forms. Selected swap-outs:
  - **ruRU:** Parry `Пар` → `Пари`, Leech `Кров` → `Вамп`, Durability `Прч` → `Проч`.
  - **deDE:** Vers `Viel` → `Viels`, Strength `Stä` → `Stär`, Durability `Halt` → `Haltb`.
  - **frFR:** Strength `For` → `Forc`, Durability `Dur` → `Dura`, Dodge `Esq` → `Esqu`.
  - **esES / esMX:** Haste `Cel` → `Cele`, Leech `Suc` → `Robo`, Strength `Fue` → `Fuer`, Agility `Agi` → `Agil`, Dodge `Esq` → `Esqu`.
  - **itIT:** Parry `Par` → `Para`, Armor `Arm` → `Armat`, Strength `For` → `Forz`, Agility `Ag` → `Agil`, Repair `Rip` → `Ripa`.
  - **ptBR:** Strength `For` → `Forç`, Agility `Agi` → `Agil`, Dodge `Esq` → `Esqu`.
  - enUS / zhCN / zhTW unchanged (already match official WoW client terminology).

## 1.0.6 — Localized stat labels (all 11 WoW locales)

### Added

- **Stat labels now display in your WoW client's language by default** across all 11 retail locales (deDE, esES, esMX, frFR, itIT, koKR, ptBR, ruRU, zhCN, zhTW; enUS unchanged). Hand-curated short forms matching StatsPro's compact 4-7 char visual language. Examples: ruRU `Крит / Хаст / Маст`, zhCN `暴击 / 急速 / 精通`, deDE `Krit / Tempo / Meist`.
- **Sectioned-mode divider is also localized** (e.g. ruRU `— Защита —`, zhCN `— 防御 —`, frFR `— Défense —`).
- **"Use localized stat names" toggle on the Display tab** — non-English clients can switch back to compact English labels. Hidden on enUS clients.
- **Translation quality note** — ruRU is user-confirmed; the other 9 locales are best-effort drafts. Native-speaker corrections welcome via GitHub Issues.

### Fixed

- **Repair-row label no longer flickers blank for one frame after a font change.** Pre-existing v1.0.5 issue; closed here because the bug becomes more visible with non-English labels.

### Behavior change for non-English-locale users

- **First `/reload` after upgrade switches your panel from English to localized labels.** To keep English: Display tab → Localization → uncheck "Use localized stat names". enUS clients see no change.

### Known limitation

- **Stat Colors color-picker rows in the settings window still show English labels.** The on-screen panel is fully localized; only the config-UI rows aren't yet.

## 1.0.5 — Offensive toggles + leak-free reset

### Added

- **Master "Show Offensive Stats" toggle on the Stats tab** — Crit / Haste / Mastery / Versatility each have their own visibility checkbox plus a master toggle. Includes an opt-in `Hide Zero Values` filter (default off).
- **`/ss debug` slash subcommand** — dumps addon version, DB version, toggle states, panel positions, and Lua memory usage into chat for self-serve diagnostics.

### Fixed

- **Defensive sub-toggles now grey out when master is off** (matches existing Tertiary / Durability dependency-disable pattern).
- **"Reset to Defaults" no longer leaks the config frame** — widget visuals are re-synced from the freshly-reset DB in-place; the frame is reused instead of orphaning child widgets in `_G` on every Reset click.
- **Repair coin moved to its own row below stats** — was sharing a row with the `Repair:` label and could overlap stat content in narrow panel layouts (visual mash like `Repair55..88..12`).

## 1.0.4 — Combat-safe lock toggle

### Fixed

- **Lock Frames toggle stuck after combat** — switching off mid-combat updated DB but `Panel:Unlock` no-op'd via its `InCombatLockdown` guard. Now re-applies on `PLAYER_REGEN_ENABLED`.
- **SwiftStatsLocal migration aliased sub-tables** — first-load shallow-copy meant `StatsProDB.colors` shared a Lua table reference with `SwiftStatsLocalDB.colors` while both addons were enabled, so color-picker edits in either silently mutated the other. Now uses `CopyTable`.
- **Default-fill skipped on coincidental version match** — `MigrateDB` early-returned when `dbVersion == CURRENT_DB_VERSION`, so SwiftStatsLocal migrants whose legacy DB carried `dbVersion=3` never picked up StatsPro's defaults. Init loops now run before the version early-return.

### Improved

- **Repair cost no longer widens the panel** — coin string anchored RIGHT, free to extend leftward past the rating/value column. Panel width is now determined purely by stat content.
- **Tertiary sub-toggles grey out when master is off** (matches Defensive tab pattern).
- **Font dropdown refreshes on each open** — fonts registered via LibSharedMedia after StatsPro loads now appear without `/reload`.

## 1.0.3 — Refresh-rate slider

### Added

- **Refresh Rate slider** on the Display tab (range `0.1s – 1.0s`, default `0.5s`). Replaces the hidden `/run StatsProDB.updateInterval = X` workaround.

## 1.0.2 — Dynamic version display

### Fixed

- **Settings window and Blizzard interface options panel showed stale "v1.0"** — version was hardcoded; both labels now read from TOC at runtime via `C_AddOns.GetAddOnMetadata`.

## 1.0.1 — Single-column display polish

### Changed

- **Single-column layout when only one display dimension is on** — toggling `Show Rating` or `Show Percentage` off now stacks every visible number in one RIGHT-justified column. Previously non-rating rows (Primary / Defensives / Durability / Repair) collapsed to a degenerate empty layout in the value column.

### Fixed

- **Wide gap / truncated percentage in single-display modes** — `GetStringWidth` on mostly-empty multi-line strings is unreliable in 12.x retail. Format helpers now route into the rating column when dual-column mode is off.
- **In-combat taint crash spam** — the all-empty short-circuit in `JoinLinesSecretSafe` compared elements against `""`, raising a taint error when in-combat reads put a secret-tainted string in the list. Comparison removed.

## 1.0.0 — Initial release

First public release under the StatsPro name. Originally inspired by SwiftStats v2.1 by TaylorSay (MIT) — substantially rewritten, with only ~9% of upstream code remaining verbatim (boilerplate, color defaults, basic stat list).

### Added

- **Defensive stats panel** — Dodge, Parry, Block, Armor (as % damage reduction). Independent visibility toggle, per-stat color swatches, hide-zero option.
- **Durability tracking** — single-pass scan of equipment slots (skipping shirt/tabard), toggle between average and worst-slot percentage. Vendor-format precision (`%.1f%%`).
- **Auto-color durability** — green ≥60%, yellow ≥30%, red <30%. Override via custom color when auto-color is off.
- **Repair cost** — live vendor-format coin string with inline gold/silver/copper icons (`GetCoinTextureString`). Rendered on its own line below durability.
- **Display modes** — Flat (one panel, all stats), Sectioned (one panel with `— Defensive —` divider), Split (separate draggable panels).
- **Multi-panel positioning** — defensive panel independently draggable in Split mode.
- **Master visibility toggle** — show/hide all panels via checkbox or `/ss toggle`.
- **Settings UI rewrite** — three-tab config window (Display / Stats / Defensive) with inline color swatches and dependency-aware enable/disable.
- **Scrollable settings window** — full Stats / Defensive content reachable on small monitors and windowed-mode layouts. Scroll resets to top on tab switch.
- **Native Blizzard Settings panel integration** — registers under `Esc → Options → AddOns → StatsPro`. Coexists with `/ss` and the launcher button.

### Changed

- **Default text alignment** — `RIGHT` (was `LEFT`). Migrated automatically; explicit user choices preserved.
- **Effective armor handling** — `pcall(UnitArmor)` + secret-value filter for 12.x retail. Refresh runs out-of-combat only.
- **Versatility** — split into rating + flat dual-source display, with combat-safe caching.
- **Repair cost API** — switched from `GameTooltip:SetInventoryItem` (returns secret values in 12.x) to `C_TooltipInfo.GetInventoryItem` + `TooltipUtil.SurfaceArgs`.

### Fixed

- **Misaligned rating + percentage columns** — rating is now its own RIGHT-justified third FontString between label and value, so all rating right-edges line up vertically and the percent column has a clean fixed left edge.
- **Frame position not persisting** — `SetUserPlaced(true)` now called after `SetPoint(...)` in `LoadPosition` (12.x retail order requirement).
- **Position lost on /reload** — `PLAYER_LOGOUT` handler saves both panels defensively, in case the user drags via paths that bypass `OnDragStop`.
- **Durability % differing from vendor** — default switched to average (matches vendor display); worst-slot mode preserved as opt-in.
- **In-combat secret-value taint** — every stat-API read passes through `pcall` + `issecretvalue` filtering before any arithmetic or comparison.

### Removed

- **Minimap button** — same actions reachable via `/ss toggle`, the Blizzard Settings entry, or the master visibility checkbox. Frees minimap real estate.
- **Legacy slash subcommands** (`move`, `unlock`, `lock`, `reset`, `scale N`, `size N`) — replaced by the redesigned Settings window. Remaining commands: `/ss` (open config), `/ss show`, `/ss hide`, `/ss toggle`, `/ss help`.

### Migrated

- Existing **SwiftStatsLocal** users keep all settings — `StatsProDB` is populated from `SwiftStatsLocalDB` on first load if present. Old DB is left untouched.
