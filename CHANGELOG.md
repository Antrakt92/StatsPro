# Changelog

## 1.9.11 - 21-May-2026 — Combat crit fallback hardening

### Fixed

- **Crit updates stay safer when spell crit reads are protected in combat** — StatsPro now guards the spell-crit fallback path so melee/ranged crit can continue driving the HUD when Midnight returns protected spell crit values.

### Improved

- **Release checks catch more Archon target and metadata drift before packaging** — local and CI gates now cover target manifest parity, addon metadata shape, and release validation more strictly.

## 1.9.10 - 21-May-2026 — Midnight combat stat fixes

### Fixed

- **Stats now keep updating more reliably during combat and Mythic+ runs** — StatsPro separates renderable Midnight secret values from clean numeric logic so live HUD updates do not freeze when Blizzard protects stat reads.
- **Hidden zero-value rows stay hidden when their stat becomes protected in combat** — absent stats no longer pop back onto the HUD as misleading `0` rows.
- **Right-click no longer opens Settings during combat** — accidental clicks in keys will not bring up the configuration window.

### Improved

- **`/ss debug live` now gives better support output for combat stat reads** — diagnostics report live Crit, Haste, Mastery, and Versatility API states when a key still needs investigation.

## 1.9.9 - 21-May-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.8 - 20-May-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.7 - 19-May-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.6 - 18-May-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.5 - 17-May-2026 — Help and documentation cleanup

### Fixed

- **`/ss help` now lists every supported discovery command** — the in-game help text includes the `/statspro` alias and `/ss help` itself, matching the README and marketplace command lists.

### Improved

- **Public documentation now uses future-proof locale wording** — README and prepared marketplace copy describe support for current WoW addon locales without hardcoding a locale count that can drift.
- **Slash command documentation is easier to preserve across public copy surfaces** — README keeps the full command table, and prepared CurseForge / WoWInterface copy now includes text command fallbacks alongside the command image.
- **Local verification stays focused on real globals** — stale diagnostic allowlist entries were removed, and smoke coverage now protects the localized slash-help output.

## 1.9.4 - 17-May-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.3 - 16-May-2026 — Runtime and release hardening

### Fixed

- **Versatility no longer appears as a misleading `0.0%` during cold-start unreadable stat states** — if the first Versatility read after login or combat is missing or secret-tagged, StatsPro now waits for a clean sample instead of rendering an invented zero.

### Improved

- **Release preflight is stricter before marketplace packaging** — checks now enforce the expected SemVer bump from commit history, guard release metadata edge cases more defensively on Windows, and require fresher Archon target snapshots for tag releases.

## 1.9.2 - 16-May-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.1 - 15-May-2026 — Localization polish

### Improved

- **Archon target hovers and `/ss` confirmations now follow the selected output language** — target tooltip labels, snapshot month names, and normal slash-command responses localize together, while `/ss debug*` diagnostics remain English for support.

## 1.9.0 - 15-May-2026 — Archon target tooltips

### Added

- **Archon target tooltips for secondary stats** — hover Crit, Haste, Mastery, or Versatility to compare your current rating against generated Archon targets, including Target, Current, Missing / Over / Matched, and the snapshot source date.
- **Mythic+ and Raid target profiles** — choose whether hover targets use Archon M+ High Keys or Raid Mythic All Bosses data from `/ss` → Layout → Value Display → Tooltip Targets.
- **Generated target data for every current Midnight spec** — the bundled snapshot covers all 40 Retail specs, including Demon Hunter Devourer, with no in-game web requests or runtime scraping.

### Improved

- **Tooltip percentages now reflect real rating conversion better** — target/current/delta percentages use Blizzard's rating conversion API, Mastery's spec coefficient, and total-rating comparisons so diminishing-return brackets are handled at the current and target rating positions.
- **Target hover presentation is easier to scan** — labels now use colons, snapshot dates use `DD-Mmm-YY`, Current can inherit the stat color when Match Value Color to Stat is enabled, and Missing / Over / Matched keep their own status colors.
- **Release checks now protect target snapshots** — local verification validates M+ and Raid profile coverage, expected target counts, generated table shape, and malformed/duplicate snapshot cases before release prep.

### Fixed

- **StatsPro now appears under Combat in the modern AddOn List** across supported client locales, while keeping legacy `X-Category` metadata for addon managers.
- **Target hover rows no longer block normal panel interactions** such as right-click settings and drag behavior.
- **Target metadata skips unsafe stat reads** instead of formatting secret, malformed, missing, negative, or non-finite rating values.

### Changed

- **The project logo is cleaner and easier to read at small sizes** — the old `SP` monogram header was removed so the icon focuses on the StatsPro HUD itself.

## 1.8.0 - 14-May-2026 — Readability and branding

### Added

- **Readability controls in Appearance** — choose Text Outline (`None`, `Outline`, or `Thick Outline`) and add an optional translucent panel background without changing the default transparent HUD.
- **Localized settings labels for the new controls** across all 11 retail locales.

### Changed

- **StatsPro branding has been refreshed** — the README logo and packaged AddOn List icon now use the current stats-panel logo.

### Improved

- **Smoke coverage now protects the new visual settings** — local checks cover default population, numeric clamping, reset behavior, live config controls, both split panels, font outline flags, and panel background alpha.

## 1.7.1 - 10-May-2026 — Runtime hardening

### Fixed

- **Rare malformed stat reads no longer break rendering** — missing, secret, or malformed percentage/rating values are skipped or safely normalized before they reach numeric formatters.
- **Settings color previews clean up safely** — closing Settings, switching swatches, or resetting defaults now cancels unconfirmed color previews without leaving stale callbacks behind.
- **Font and locale hover previews restore reliably** — closing the font picker or language dropdown after browsing previews now forces the committed font back onto the HUD instead of occasionally leaving a hovered preview active.
- **`/ss debug bucket` is safer during unreadable stat states** — diagnostics now suppress secret or malformed render values instead of inspecting them.

## 1.7.0 - 10-May-2026 — Defensive and gear feedback pass

Suggested by [@tflo](https://github.com/tflo) in issues #2, #3, and #4. Thank you for the detailed feedback and testing notes.

### Added

- **Optional Stagger row for Brewmaster Monks** — Stagger now lives with the Defensive stats and has its own checkbox and color swatch. It stays hidden for non-Brewmaster specs even when zero values are shown.

### Changed

- **Item Level now belongs to Gear** — Sectioned mode groups iLvl under the Gear heading with Durability and Repair, and fresh/reset Split layouts send Item Level to the side panel with the other gear rows.
- **Block is class-aware** — Block stays visible for Warriors, Paladins, and Shamans, but hides on classes that cannot block even when `Hide Zero Values` is off. Dodge and Parry remain unchanged.

### Improved

- **Smoke coverage protects the new routing and defensive edge cases** — local checks now cover Brewmaster-only Stagger, non-block classes, Shaman zero-Block visibility, Item Level's Gear header, and the new Settings controls.

## 1.6.4 - 08-May-2026 — Verification and startup hardening

### Improved

- **Local addon checks are much stricter** — the project wrapper now runs Lua 5.1 syntax, the pure-Lua smoke harness, luacheck, and LuaLS diagnostics before release prep.
- **Smoke coverage now protects the main addon lifecycle outside the WoW client** — startup migration, legacy SwiftStats carry-forward, logout position saves, slash commands, render routing, config construction, representative settings interactions, UTF-8 labels, font compatibility helpers, repair formatting, and color normalization are covered by local checks.
- **Fresh-machine check setup is scripted** — `scripts/install-check-tools.ps1` can bootstrap the Lua 5.1, LuaLS, LuaRocks, and luacheck tools used by the local verification wrapper.
- **Release preflight now checks version consistency** — tag packaging verifies the release tag, TOC version, addon fallback version, changelog heading, and local Lua checks before marketplace upload.

### Fixed

- **Item Level follows the selected language on the HUD** — the row now localizes with the rest of the stat labels instead of always showing `iLvl`.
- **Malformed SavedVariables fall back safely** — invalid DB roots, font and position scalars, booleans, and non-finite numeric settings no longer crash early startup or invert toggles before settings can self-heal.
- **Legacy migration inputs are more defensive** — string, invalid, or non-finite `dbVersion` values now run through the forward migration path instead of breaking version comparisons or skipping repairs.

### Changed

- **Release publishing has stronger duplicate-upload guards** — tag-triggered packaging refuses forced-tag and existing-release republish paths before marketplace upload.
- **Static diagnostics are tighter** — luacheck is now a required local gate and stale named-frame diagnostic allowlist entries were removed.
- **Changelog dates are easier to read** in release notes.

## 1.6.2 - 06-May-2026 — Item Level row alignment fix

### Fixed

- **Item Level row no longer wraps mid-value in Sectioned mode** — the `277 / 277` text could split across two lines under tight panel widths, shifting every stat row below it out of alignment (Crit picked up Haste's value, Defensive header pulled in Speed's, Repair overlapped Durability). Equipped and overall iLvl now render in the same rating/value columns the rated stats use, so the row stays single-line and the separator lines up with the other rows.

### Changed

- **Item Level separator is now a gray pipe** (`iLvl: 277 | 277`) instead of a gray slash, matching the visual style used between rating and percent on Crit, Haste, Mastery, Vers, Leech, and Speed.

## 1.6.1 - 06-May-2026 — Performance hardening

### Improved

- **Item Level refresh is more efficient** — equipped / overall item level now refreshes from gear and bag-change signals instead of polling every HUD tick.
- **Hidden panels do less repeated work** — already-hidden stat panels skip redundant text/cache clearing.
- **Refresh Rate changes avoid redundant cache refresh work** while Font Size, Scale, and Text Opacity keep instant live preview as you drag.

### Fixed

- **Malformed numeric SavedVariables are clamped safely** — bad Scale, Font Size, Text Opacity, or Refresh Rate values fall back to sane runtime values instead of breaking rendering or update timing.
- **Versatility rating reads are skipped when Rating display is off** while percentage display continues updating normally.

### Changed

- **Release workflow now runs only from `v*` tags** and uses the newer checkout action runtime, removing the manual-dispatch footgun and Node.js runtime warning.

## 1.6.0 - 05-May-2026 — Item Level + configurable layout blocks

### Added

- **Item Level row** — optional `iLvl` display showing equipped / overall item level, with a warning color when your bags significantly out-level what you are wearing. Suggested by [@tflo](https://github.com/tflo) (issue #1).
- **Configurable Split mode** — choose which logical blocks live in the side panel: Character, Item Level, Offensive, Tertiary, Defensive, Durability, and Repair Cost.
- **Independent Repair Cost toggle** — repair cost can now be shown without also enabling Durability.
- **Stats / Layout / Appearance settings tabs** — settings are reorganized around what you are changing: stat rows, frame/layout behavior, and visual/localization choices.

### Fixed

- **Repair Cost no longer needs a settings toggle after login/vendor timing** — delayed tooltip/item data now triggers a repair-cost rescan when it catches up.
- **Armor damage reduction no longer flickers to 0 during transient unreadable 12.x stat reads** — the addon keeps the last clean value until fresh readable data arrives.
- **Korean / Chinese / Russian font compatibility is more reliable** — Blizzard font paths are normalized across casing/path variants, and bundled font coverage now classifies localized Blizzard fonts correctly.
- **Malformed color SavedVariables no longer break rendering** — invalid color tables/channels are repaired from defaults and clamped safely.
- **Sectioned mode now matches the new layout model** — it shows headers for visible Character, Item Level, Offensive, Tertiary, Defensive, and Gear blocks instead of only the old Defensive divider.
- **Settings launcher localization stays in sync** after language changes.

### Changed

- **Repair Cost is OFF by default for fresh/reset profiles** so it only appears when explicitly enabled.
- **Release packages include the MIT license** and exclude Codex/private development metadata.

## 1.5.0 - 04-May-2026 — Right-click opens Settings

### Added

- **Right-click on the stats panel opens Settings** — no need to remember `/ss`. Works regardless of whether the panel is locked or unlocked. Drag-aware: drag-then-release won't accidentally open Settings.

### Behavior change

- Locking the panel no longer makes it click-through to the underlying UI. Right-click on the panel now opens Settings; left-click does nothing visible. **Trade-off:** if your panel sits over the gameplay area, right-click-drag camera control through the panel area no longer works. Recommended fix: drag the panel to a margin / corner where click-through doesn't matter, or use `/ss hide` to temporarily hide it.

Suggested by [@tflo](https://github.com/tflo) (issue #1).

## 1.4.0 - 04-May-2026 — Stamina row

### Added

- **Show Stamina** — new optional toggle in Stats → Primary Stat Ratings, default OFF. Sits next to Show Main Stat with its own color picker (default pastel green). Shows your Stamina value (the third primary stat — contributes to your max health pool), with raid buffs / flask / food included. Useful for tanks watching effective HP and for any spec wanting to see the contribution of consumables.

Suggested by [@tflo](https://github.com/tflo) (issue #1).

## 1.3.2 - 03-May-2026 — Localization polish

### Fixed

- **Font picker on CJK clients without LibSharedMedia** — Korean / Simplified Chinese / Traditional Chinese installs without an LSM-providing addon (BigWigs, ElvUI, etc.) now see the canonical client-shipped script-native font as an additional picker option, and the dropdown caption matches what's actually rendering on screen. No change on non-CJK clients or with LSM installed.
- **Auto-language dropdown nested parens** — Russian / Spanish / Portuguese / Korean / Chinese clients no longer see `Auto (current: <Lang> (English))`; the English suffix is stripped from the Auto display only — explicit-pick menu items keep the full bilingual label for disambiguation.

## 1.3.1 - 03-May-2026 — Branding fix

### Fixed

- **AddOn List icon updated** to our own StatsPro logo (was a legacy fork-era icon).

## 1.3.0 - 03-May-2026 — Auto main stat + text opacity

Both features in this release were suggested by **tflo** (GitHub Issue #1) — a fellow WoW addon developer (PetWalker, Auto Quest Tracker Mk III, Goyita, Move 'em All, Auto Discount Repair, and several others). Thank you for the thoughtful and detailed feedback — much appreciated!

### Added

- **Show Main Stat** — new toggle that auto-detects your spec's primary stat (Strength / Agility / Intellect) and shows only that one. Replaces the three separate "Show Strength / Agility / Intellect" toggles — your Brewmaster's Agility, your Mage's Intellect, your Warrior's Strength all auto-resolve from the modern spec API. The two non-main primary stats are practically irrelevant to any spec, so this saves screen space without losing useful information. A single Main Stat color picker sits next to the toggle in Stats → Primary Stat Ratings (default gold) — change it once, applies to whichever stat your active spec uses.
- **Text Opacity slider** — adjust panel text transparency (25%–100%, default 100%). Located in the Appearance tab directly under Font Size. Useful if you find the default text too prominent and prefer a more subtle on-screen look (try 80–90% — what tflo originally suggested).

### Migrated

- The three primary stat toggles (Show Strength / Agility / Intellect) are gone — replaced by the single Show Main Stat toggle. If you had any of the three previously enabled, "Show Main Stat" turns ON automatically (your displayed-stat preference is preserved). If all three were OFF (the v1.2.x default — most users), main stat stays hidden — open the Stats tab and check "Show Main Stat" if you want it now.
- The three per-stat color pickers (Strength / Agility / Intellect) are collapsed into a single Main Stat color. If you previously customized any of the three away from the default gold, the most-likely-main-stat color (Intellect first, then Agility, then Strength) carries over to the new Main Stat picker — your color preference survives in the common case. Multi-class altoholics who set three different colors will only see the first carry-over (Intellect-priority); pick a new color in Stats → Show Main Stat swatch if you want a different one.

## 1.2.2 - 02-May-2026 — Repair cost loads correctly after login

### Fixed

- **Repair cost now displays right after login** instead of staying blank until you toggle Show Repair Cost off and on (or swap a piece of gear). Item data loads asynchronously after entering the world; the addon now schedules a single delayed re-scan when any slot's tooltip wasn't ready yet, so the cost catches up without manual intervention.

## 1.2.1 - 02-May-2026 — Settings window adapts to small screens

### Fixed

- **Settings window now fits on low-resolution screens and high UI-scale setups.** Previously the Reset and Close buttons could sit below the visible screen edge if your game window was small (e.g. 1024×768) or your UI Scale slider was set high — the window is now capped to ~90% of the game-window height and the inner tabs scroll if content overflows. At typical resolutions (1080p / 1440p / 4K with default UI scale) you'll see no change.

## 1.2.0 - 01-May-2026 — Full settings UI localization

### Added

- **The entire Settings window now localizes** — tabs, section headers, every checkbox / slider / dropdown label, buttons, the launcher tooltip, and the font-coverage warning. All 11 retail locales covered, with live updates on Language dropdown change without `/reload`. enUS and ruRU are native quality; the other nine (deDE / esES / esMX / frFR / itIT / ptBR / koKR / zhCN / zhTW) are best-effort drafts — native-speaker corrections welcome via GitHub Issues.

### Fixed

- **"Show Repair Cost" toggle now refreshes immediately when turned on.** Previously the toggle could display nothing or a stale value until your next gear swap, because the cache only refreshed on equipment events. Toggling Off → On with damaged items now updates the displayed cost right away.
- **Settings UI labels no longer render as `?`-boxes** when previewing or committing a non-Latin locale (Russian / Chinese) on an English client. Settings labels now auto-switch to a glyph-compatible font — same logic the stat panels were already using.
- **Section headers no longer corrupt non-ASCII letters** when rendered uppercase in localized languages. Previously Russian "Основные характеристики" produced byte garbage at the section header on non-Russian clients.
- **Font picker hover-preview no longer leaves panels stuck on a previewed font** after closing the picker. Closing without picking always reverts to the committed font, including edge cases with rapid scrolling and unusual close paths.
- **Hovering a language preview no longer leaves panels on a fallback font** after committing a different locale — e.g. hovering Russian then clicking German on an English client used to leave panels rendered in Arial Narrow despite German only needing the default Latin font.
- **Closing the Settings window via Esc no longer leaves orphan dropdown menus** visible on screen.
- **Reset to Defaults now correctly restores the Settings window's font** along with everything else.

### Improved

- **Font picker hover-preview is smoother during rapid scrolling** — redundant re-applies are deduped, and the mouse drifting to picker padding auto-cancels the preview instead of leaving it stuck.
- **Font Size slider drag and locale switching feel more responsive** — the internal pipeline now skips redundant work when only the font changes (text content unchanged). First open of the Font picker on installs with many SharedMedia fonts is also faster (the alphabetical sort runs once per session instead of per open).

### Known limitations

- **Korean / Chinese label preview on non-CJK clients** still requires a SharedMedia font with CJK coverage installed (unchanged from prior versions). Without one, labels render as `?`-boxes; the inline warning makes the issue visible.

## 1.1.8 - 30-Apr-2026 — Settings UI restructure + multi-column font picker

### Added

- **Multi-column font picker replaces the alphabetical sub-menu dropdown.** Click the Font field in Appearance → Typography and the full font list opens as a scrollable 3-column grid — no more drilling through `2-A` / `B-C` / `D-F` letter buckets. Hover any font to preview it on your panels live; click to commit; close the picker without picking to revert. The currently-selected font is tinted and the grid auto-scrolls to center it on open.
- **Hover-preview for the Language dropdown.** Open Appearance → Localization → Language and hover any locale to see your panel labels switch live to that language. Close the dropdown without clicking to revert; click to commit. When your committed font can't render the hovered locale's glyphs (e.g. Russian on an English client with the default Latin-only font), the preview also temporarily switches to a glyph-compatible fallback so labels render correctly during hover — same auto-switch the commit path already does.
- **Per-stat color customization for Strength / Agility / Intellect.** Previously all three primary stats shared a single color; now each has its own inline swatch in Stats → Primary Stat Ratings. If you'd previously customized the shared primary color, that choice is preserved across all three on upgrade — visuals unchanged unless you intentionally pick differently per stat.

### Changed

- **Settings tab order is now `Stats | Defensive | Appearance`** (was `Display | Stats | Defensive`). The former "Display" tab is renamed to "Appearance" and moved to the end — new users land on Stats first (most common configuration); appearance tweaks are one tab away when needed. The settings window also reopens on Stats by default.
- **Display Format toggles moved from Appearance to Stats tab top** — Show Rating / Show Percentage / value-color toggles now live next to the stat toggles they affect, instead of in a separate tab.
- **Appearance tab reorganized** — sliders are grouped under their conceptual section instead of trailing as orphan rows. Frame & Position holds Visibility / Lock / Layout / Scale / Refresh Rate; Typography holds Font / Font Size; Localization sits at the bottom (typically set once and never revisited).
- **Tertiary stats (Leech / Avoidance / Speed) now use a 2-column grid** matching Offensive and Defensive sections, instead of a single-column list.
- **Inline color swatches everywhere.** Offensive stat toggles (Crit / Haste / Mastery / Versatility) and the value-color picks for Show Rating / Show Percentage now use the same inline-with-checkbox swatch layout already used in Defensive and Tertiary sections — replacing the older mix of inline and separate-row swatches.

## 1.1.7 - 30-Apr-2026 — Polish & UX

### Fixed

- **Font dropdown caption now updates immediately after a language switch triggers an automatic font swap.** Previously the dropdown still showed the old font name even though the active font had changed — for example, switching to Russian on an English client silently auto-switched to Arial Narrow but the dropdown kept saying "Friz Quadrata TT".
- **Launcher description text in the Blizzard AddOns panel no longer clips off the right edge** on narrow Settings windows or low-resolution displays.

### Added

- **`/ss reset` slash command.** Resets all settings to defaults without opening the settings window — handy for quick recovery without losing the current screen context.

## 1.1.6 - 29-Apr-2026 — Settings UI polish

### Fixed

- **Durability color swatch is now always clickable.** Previously it appeared greyed out and unresponsive when "Auto Color by Threshold" was on (the default). The override color you pick still takes effect only when Auto Color is turned off — nothing else changed about the threshold behavior.
- **Tertiary stats sub-toggles (Show Leech / Avoidance / Speed) now form a clean single-column layout** with their color swatches aligned vertically. Previously the 3-stat 2-column grid produced an asymmetric L-shape of swatches.
- **All color swatches across Settings now form clean aligned columns**, regardless of label length or chosen language. Previously swatches drifted horizontally based on rendered label width — e.g. "Crit Color:" and "Versatility Color:" pushed swatches to different x positions per row.
- **Color swatches throughout Settings now have consistent sizing.** Previously the labeled "Stat Color:" pickers in the Display tab used larger swatches than the inline checkbox swatches in Stats / Defensive tabs — visually inconsistent. Now all swatches share one size and styling.
- **Section header color swatches (e.g. the shared Primary stat swatch next to the "PRIMARY STAT RATINGS" header) now sit right next to the header text** with the same gap as everywhere else, instead of at a fixed offset that left wide empty space.
- **Default stats panel font is no longer hijacked by third-party font-replacement addons** (ChonkyCharacterSheet, Tukui, ElvUI font modules, and similar). Those addons mutate Blizzard's `STANDARD_TEXT_FONT` global; previously StatsPro's defaults, migration, and auto-switch fallback followed the mutation and silently pinned your panel font to the addon's path — even if you never picked it. StatsPro now trusts `STANDARD_TEXT_FONT` only when it points to a Blizzard-shipped path; addon-overridden values fall back to Friz Quadrata. You can still pick any installed font manually via the Font dropdown.
- **Display tab dropdowns (`Display Mode`, `Language`, `Font`) now share a single column with matching width.** Previously the `Display Mode` dropdown sat far to the right while the other two clung close to their labels and rendered at three different sizes. All three now share the same left edge (column adapts to label widths in any locale) and the same body width. The Language dropdown's collapsed text is shown in compact form (e.g. `English` / `Русский` / `中文 简体`) so it fits without truncation; the menu still shows full descriptive labels when opened.
- **Tighter spacing below the Language row when no font-coverage warning is shown** (the common case). Previously a fixed 2-line warning slot was reserved unconditionally, leaving visible empty space between the Language dropdown and the Typography section.
- **Font dropdown no longer overflows the screen on systems with many SharedMedia fonts.** Users with multiple font packs registered (50–200+ entries) saw a single huge non-scrolling list that ran off the bottom of the screen with the bottom entries unreachable. The list now groups into alphabetic letter-range submenus (e.g. `A`, `B – C`, `D – F`, …) that each fit on screen. Short font lists (≤ 20 entries) still render as a single flat menu — no extra clicks for users without large font packs.

### Added

- **Settings UI now refreshes localized stat color labels immediately when you change Language**, instead of requiring `/reload`. Column alignment recomputes on the fly to fit the new locale's text widths.

## 1.1.5 - 29-Apr-2026 — Honest font coverage on cross-locale picks

### Fixed

- **Selecting a non-native locale (e.g. Russian on an English client) now auto-switches to Blizzard's built-in Arial Narrow** for readable rendering — no SharedMedia addon required. Previously the addon mistakenly assumed `Fonts\FRIZQT__.TTF` always shipped clean Cyrillic glyphs (true only on the Russian client build); on English / German / French / etc. FRIZQT is Latin-designed, with Cyrillic falling back to OS system fonts (visible but with mismatched kerning and stroke weights — hard to read). The fix recognizes ARIALN as the Blizzard-shipped Latin+Cyrillic font (universal across all non-CJK clients, since it's used for chat/nameplates with cross-realm Russian names) and auto-switches to it when needed.
- **Existing users with a stale cross-locale `forceLocale` setting now self-heal on next login.** The per-login auto-switch sees the now-correct coverage answer and picks the right font.
- **The "current font may not render cleanly" warning now correctly fires** when even the auto-fallback can't cover the chosen locale (e.g. picking Korean on an English client without a SharedMedia CJK font installed). Previously suppressed for Cyrillic on non-Russian clients due to the incorrect assumption above.

### Known limitations

- **Korean / Chinese on non-CJK clients** still requires a SharedMedia font with CJK coverage (NotoSansCJK, SourceHanSans, WenQuanYi, etc.) — Blizzard doesn't ship CJK glyphs on non-CJK client builds, and bundled CJK fonts are too large (5-20MB) to ship inside the addon. Install one of the SharedMedia CJK addons from CurseForge for clean rendering. Without one, labels render as `?`-boxes and the inline warning will stay visible.

## 1.1.4 - 28-Apr-2026 — LSM CJK font auto-detect

### Fixed

- **LSM CJK fonts (NotoCJK / SourceHan / WenQuanYi / PingFang / Microsoft YaHei / JhengHei / SimSun / SimHei / MingLiU / Malgun Gothic / Nanum / Apple SD Gothic Neo) no longer trigger a false "font may not cover glyphs" warning when picking a CJK locale.** Auto-switch logic now recognizes them by font-family name patterns; previously any non-Blizzard-shipped font was conservatively assumed Latin-only. NotoCJK and SourceHan are now also correctly recognized as covering Cyrillic — ruRU users with these fonts no longer see a false warning either.

### Known limitations

- **Custom CJK families with generic filenames** (e.g. `regular.ttf` inside a CJK font pack) still surface the warning because path-based detection can't see the font's display name. Recoverable by ignoring the warning, or report the family on GitHub Issues to add an explicit pattern.
- **Auto-fallback prefers alphabetic-first match.** When multiple LSM CJK fonts are installed, manual font selection is preferred over auto-fallback for best coverage.

## 1.1.3 - 28-Apr-2026 — Settings window layering fix

### Fixed

- **Settings window now opens above raid frames and HUD addons** (was rendering at `MEDIUM` strata, same as gameplay HUD; now uses `DIALOG`).

## 1.1.2 - 28-Apr-2026 — Fix empty panels + empty settings on v1.1.x

### Fixed

- **Panels render empty and settings window opens blank on v1.1.0 / v1.1.1.** Hotfix — no DB reset needed, all preferences preserved.

## 1.1.1 - 28-Apr-2026 — Migration fix for opted-out users

### Fixed

- **Migration honors the v1.0.x "use localized labels = off" opt-out** — earlier v1.1.0 adopters with the toggle off were silently re-enabled. If affected: open Display → Localization → pick "English".

## 1.1.0 - 28-Apr-2026 — Manual locale override + auto-switch font

### Added

- **New "Language" dropdown in Display tab → Localization.** Pick any of the 11 retail locales for on-screen labels regardless of WoW client locale. Replaces the prior `useLocalizedLabels` boolean.
- **Auto-switch font when picked locale needs glyphs the current font lacks.** Saves your previous font, switches to the locale-aware default, restores on switching back. Manually picking a font clears the auto-switch memory.
- **Inline warning under the Language dropdown** when no installed font covers the picked locale's glyphs. Doesn't block the choice.

### Known limitations

- **LSM CJK fonts treated as Latin-only by the auto-switch logic** — picking a CJK locale fires a "font may not cover glyphs" warning even if your LSM font does cover them. Workaround: pick the LSM font manually via the Font dropdown after switching locale.

## 1.0.12 - 27-Apr-2026 — Per-locale TOC Notes

### Added

- **Localized addon-list description (`## Notes-<locale>:` TOC fields)** for all 10 non-English retail locales: deDE, esES, esMX, frFR, itIT, koKR, ptBR, ruRU, zhCN, zhTW. Single-line corrections from native speakers welcome via GitHub Issues.

## 1.0.11 - 27-Apr-2026 — Localized color-picker labels + Localization toggle preview fix

### Added

- **Color-picker rows in the Display tab now show localized stat names** (e.g. ruRU `Крит Цвет:`, zhCN `暴击 颜色:`, deDE `Krit Farbe:`). The two non-stat rows ("Rating Color" / "Percentage Color") still show those words in English; only "Color" is localized.

### Fixed

- **Localization-toggle checkbox preview no longer renders as `?` boxes on CJK clients.** Was hardcoded to `Fonts\FRIZQT__.TTF` (no CJK glyphs); now uses `STANDARD_TEXT_FONT`.

## 1.0.10 - 27-Apr-2026 — Locale-aware default font (CJK fix) + RGBToHex hardening

### Fixed

- **Localized stat labels now render correctly out of the box on CJK clients (zhCN / zhTW / koKR).** Default font was `Fonts\FRIZQT__.TTF` (no CJK glyphs); now `STANDARD_TEXT_FONT` (locale-aware).
- **Existing users on the old default font are auto-upgraded** (DB v3 → v4). Explicit font choices preserved.
- **Font re-applies cleanly within the upgrade session** — no broken-glyph flash for CJK users until next `/reload`.
- **`RGBToHex` defensive guard against SavedVariables corruption** — out-of-range RGB values from a hand-edited DB are clamped to `[0, 1]`.

## 1.0.9 - 27-Apr-2026 — Carry forward settings from upstream SwiftStats (TaylorSay)

### Added

- **One-time settings carry-forward from the original SwiftStats by TaylorSay.** Users moving from CurseForge SwiftStats to StatsPro now get their panel position, font, scale, and per-stat colors copied on first launch (fresh installs only). Source priority: `SwiftStatsDB` (upstream public) > `SwiftStatsLocalDB` (older internal name).

## 1.0.8 - 27-Apr-2026 — Primary stats now show effective (buffed) values + armor combat-taint guard

### Fixed

- **Primary stats (Strength / Agility / Intellect) now show the same value Blizzard's character sheet displays.** Was capturing `UnitStat`'s base return instead of the effective return; for buffed raiders this understated by 10–25%. Affects users who explicitly enabled `Show Strength` / `Show Agility` / `Show Intellect` (off by default).
- **Armor damage-reduction calculation no longer aborts mid-pull** if `PaperDollFrame_GetArmorReduction` returns a secret-tainted number — wrapped in `pcall` + `issecretvalue` filter.

## 1.0.7 - 27-Apr-2026 — Translation polish + Korean Armor/Defensive disambiguation

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

## 1.0.6 - 27-Apr-2026 — Localized stat labels (all 11 WoW locales)

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

## 1.0.5 - 26-Apr-2026 — Offensive toggles + leak-free reset

### Added

- **Master "Show Offensive Stats" toggle on the Stats tab** — Crit / Haste / Mastery / Versatility each have their own visibility checkbox plus a master toggle. Includes an opt-in `Hide Zero Values` filter (default off).
- **`/ss debug` slash subcommand** — dumps addon version, DB version, toggle states, panel positions, and Lua memory usage into chat for self-serve diagnostics.

### Fixed

- **Defensive sub-toggles now grey out when master is off** (matches existing Tertiary / Durability dependency-disable pattern).
- **"Reset to Defaults" no longer leaks the config frame** — widget visuals are re-synced from the freshly-reset DB in-place; the frame is reused instead of orphaning child widgets in `_G` on every Reset click.
- **Repair coin moved to its own row below stats** — was sharing a row with the `Repair:` label and could overlap stat content in narrow panel layouts (visual mash like `Repair55..88..12`).

## 1.0.4 - 26-Apr-2026 — Combat-safe lock toggle

### Fixed

- **Lock Frames toggle stuck after combat** — switching off mid-combat updated DB but `Panel:Unlock` no-op'd via its `InCombatLockdown` guard. Now re-applies on `PLAYER_REGEN_ENABLED`.
- **SwiftStatsLocal migration aliased sub-tables** — first-load shallow-copy meant `StatsProDB.colors` shared a Lua table reference with `SwiftStatsLocalDB.colors` while both addons were enabled, so color-picker edits in either silently mutated the other. Now uses `CopyTable`.
- **Default-fill skipped on coincidental version match** — `MigrateDB` early-returned when `dbVersion == CURRENT_DB_VERSION`, so SwiftStatsLocal migrants whose legacy DB carried `dbVersion=3` never picked up StatsPro's defaults. Init loops now run before the version early-return.

### Improved

- **Repair cost no longer widens the panel** — coin string anchored RIGHT, free to extend leftward past the rating/value column. Panel width is now determined purely by stat content.
- **Tertiary sub-toggles grey out when master is off** (matches Defensive tab pattern).
- **Font dropdown refreshes on each open** — fonts registered via LibSharedMedia after StatsPro loads now appear without `/reload`.

## 1.0.3 - 26-Apr-2026 — Refresh-rate slider

### Added

- **Refresh Rate slider** on the Display tab (range `0.1s – 1.0s`, default `0.5s`). Replaces the hidden `/run StatsProDB.updateInterval = X` workaround.

## 1.0.2 - 26-Apr-2026 — Dynamic version display

### Fixed

- **Settings window and Blizzard interface options panel showed stale "v1.0"** — version was hardcoded; both labels now read from TOC at runtime via `C_AddOns.GetAddOnMetadata`.

## 1.0.1 - 26-Apr-2026 — Single-column display polish

### Changed

- **Single-column layout when only one display dimension is on** — toggling `Show Rating` or `Show Percentage` off now stacks every visible number in one RIGHT-justified column. Previously non-rating rows (Primary / Defensives / Durability / Repair) collapsed to a degenerate empty layout in the value column.

### Fixed

- **Wide gap / truncated percentage in single-display modes** — `GetStringWidth` on mostly-empty multi-line strings is unreliable in 12.x retail. Format helpers now route into the rating column when dual-column mode is off.
- **In-combat taint crash spam** — the all-empty short-circuit in `JoinLinesSecretSafe` compared elements against `""`, raising a taint error when in-combat reads put a secret-tainted string in the list. Comparison removed.

## 1.0.0 - 26-Apr-2026 — Initial release

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
