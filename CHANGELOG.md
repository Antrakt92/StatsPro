# Changelog

## 1.10.5 - 14-Jul-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.10.4 - 13-Jul-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.10.3 - 13-Jul-2026 — Reliability and release hardening

### Fixed

- **Profile switching now recovers safely after interrupted specialization or context changes.** Automatically generated profile names stay within their limits, and invisible Unicode line or paragraph separators are rejected.
- **Restricted durability keeps the last complete reading instead of replacing it with partial data.** Late item-tooltip hydration also uses bounded retries so Repair Cost can recover without endless refresh work.
- **The font picker receives the first Escape keypress, while profile and Settings confirmations close before combat can make them unsafe.**

### Improved

- **Distribution updates are now more reliable across GitHub, CurseForge, Wago, and WoWInterface, including interrupted-release recovery and exact platform-version checks.**
- **The public guide and screenshot gallery now reflect the current Profile Manager, appearance presets, and Settings layout.**

## 1.10.2 - 12-Jul-2026 — Profiles, presets, and Settings overhaul

### Added

- **Profiles now follow each character and specialization automatically.** Existing settings migrate safely, while each spec can keep its own visible stats, layout, colors, and defensive choices.
- **A new Profile Manager supports creating, duplicating, renaming, assigning, swapping, copying selected setting groups, resetting, deleting, and reviewing profiles across visited characters.**
- **Role templates and bulk actions can seed future Tank, Healer, and Damage profiles, reuse one profile across known specs, or split shared specs into independent copies.**
- **SwiftStats import now creates an independent profile for the current character and spec.** `/ss reset` resets only the active profile, while `/ss wipe` and `/ss reset all` explicitly reset all StatsPro data.
- **Six appearance presets—Default, Classic, Clean Dark, Midnight, Monochrome, and High Contrast—support live preview, Apply, and Cancel without changing layout, visible stats, language, or assignments.** Default matches the new 14px, full-opacity, outlined, 15%-background HUD style with per-stat value colors.
- **Fresh and reset profiles now use the Default presentation:** rating and percentage values, full labels, Mythic+ tooltip targets, and stat-matched value colors.
- **When frames are unlocked, opening Settings shows clear panel outlines and drag handles outside combat, making panel placement easier.**
- **Settings now provides two compact title-bar icons that open copy-ready Ko-fi and project contact links.**

### Improved

- **Settings has been rebuilt with a polished three-tab shell, consistent controls, clearer states and tooltips, localized labels, and a responsive scroll area.** It adapts live to resolution or UI-scale changes and keeps long labels reachable.
- **Reset now sits directly below Manage in the active-profile header, while Ko-fi and Contact sit beside the title-bar close control.** The redundant bottom Close row is gone, leaving more room for settings.
- **Archon target hovers remain useful when Midnight restricts live stat values.** They retain target metadata, show a clearly labelled last-known comparison when available, and recover exact comparisons when clean reads return.
- **Section headers are brighter, cold-combat panel geometry stays readable, and wide-screen panel positions are preserved.**

### Fixed

- **Crit now matches Blizzard's paper-doll aggregation, Versatility no longer shows partial totals, and Armor uses the documented effectiveness API.**
- **Item level refreshes from Blizzard's authoritative event and floors equipped and overall values like the Character panel, including correct warning thresholds.**
- **Missing or invalid fonts recover safely; enGB and localized AddOn-list summaries use the correct presentation; font-coverage warnings wrap correctly and use localized language names instead of internal script codes.**
- **Repair cost retries are bounded when item data is incomplete, avoiding endless refresh work while preserving later recovery.**
- **Color previews no longer interfere with another addon's picker or persist when cancelled, closing Settings, reloading, or logging out.**
- **Newer-schema SavedVariables remain inspectable but read-only, preventing an older StatsPro build from overwriting newer data.**
- **Profile dialogs preserve the expected Escape order; long localized controls such as Worst Slot fit cleanly, and any truncated Settings text remains available through its tooltip.**
- **The Appearance tab now removes unused preview space, keeping Typography directly below presets until preview actions are actually needed.**
- **Profile Manager now shows Blizzard's localized specialization names for offline characters instead of raw numeric spec IDs.**
- **Checkbox labels now keep a clear visual gap from their checked-state icons throughout Settings.**

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from 12-Jul-2026 Archon data.**

## 1.9.59 - 10-Jul-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.58 - 09-Jul-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.56 - 08-Jul-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.55 - 07-Jul-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.54 - 06-Jul-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.53 - 05-Jul-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.52 - 03-Jul-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.51 - 02-Jul-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.50 - 01-Jul-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.49 - 30-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.48 - 29-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.47 - 28-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.46 - 26-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.45 - 25-Jun-2026 — PTR marketplace compatibility

### Fixed

- **PTR compatibility now publishes through marketplaces while WoWInterface still exposes only Midnight aggregate metadata.** The addon still advertises Retail 12.0.7 and PTR 12.1.0 in its TOC.

### Changed

- **Retail compatibility metadata now targets 12.0.7 and the 12.1.0 PTR.** StatsPro no longer advertises the retired older interface in the TOC or public compatibility copy.

## 1.9.43 - 25-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.42 - 24-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.41 - 21-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.40 - 20-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.39 - 19-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.38 - 18-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.37 - 17-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.36 - 16-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.35 - 15-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.34 - 14-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.33 - 12-Jun-2026 — Runtime and release hardening

### Fixed

- **Stats and repair rows now recover after temporarily unreadable Midnight data** instead of remaining blank or stale.

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.30 - 12-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.29 - 11-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.28 - 10-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.27 - 09-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.26 - 08-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.25 - 06-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.24 - 03-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.23 - 02-Jun-2026 — Movement speed display

### Fixed

- **Movement now matches the Blizzard character panel instead of the highest possible speed mode** — ground mounts no longer show the faster flying value while grounded, and run-speed buffs correctly update back down when they expire.

### Changed

- **The tertiary Speed row and setting are now labelled Movement across supported languages**, while existing choices remain unchanged.

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.22 - 01-Jun-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.21 - 31-May-2026 — HUD fixes and release checks

### Fixed

- **Rating rows stay visible through protected or missing stat reads** — rating-only rows such as Versatility and Speed no longer disappear when a percentage, bonus, or protected read is unavailable while the rating itself is still available.
- **Initial HUD refreshes no longer surface addon errors** when stats are temporarily unreadable during login or `/reload`.
- **Invalid saved display or language choices now fall back safely** instead of leaving their dropdowns inconsistent.
- **Item Level remains visible when labels are hidden** — hidden-label mode keeps the enabled Item Level values aligned with the rest of the HUD instead of suppressing the row.

## 1.9.20 - 31-May-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.19 - 30-May-2026 — Rating rows, HUD layering, and release checks

### Fixed

- **Rating-only offensive and tertiary rows stay visible when their rating is available** — rows such as Versatility and Speed no longer disappear in rating-only mode when the percentage or bonus read is missing, zero, or protected while the rating itself is readable.
- **Stats panels now sit behind raid frames and other higher-priority UI** — the always-on HUD uses background frame strata instead of overlapping gameplay panels.

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.18 - 29-May-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.17 - 28-May-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.16 - 27-May-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.15 - 26-May-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.14 - 25-May-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.13 - 24-May-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.12 - 23-May-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.11 - 22-May-2026 — Combat crit fallback hardening

### Fixed

- **Crit updates stay safer when spell crit reads are protected in combat** — StatsPro now guards the spell-crit fallback path so melee/ranged crit can continue driving the HUD when Midnight returns protected spell crit values.

## 1.9.10 - 21-May-2026 — Midnight combat stat fixes

### Fixed

- **Stats now keep updating more reliably during combat and Mythic+ runs** when Blizzard temporarily protects stat reads.
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

- **README and marketplace descriptions now cover all supported WoW addon locales** without a hardcoded locale count.
- **README, CurseForge, and WoWInterface descriptions now include complete text command lists** alongside the command image.

## 1.9.4 - 17-May-2026 — Archon target refresh

### Updated

- **Bundled M+ High Keys and Raid Mythic All Bosses target ratings were refreshed from latest Archon data.**

## 1.9.3 - 16-May-2026 — Runtime and release hardening

### Fixed

- **Versatility no longer briefly appears as `0.0%`** when it is temporarily unreadable after login or during combat.

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

- **Archon tooltip percentages now account more accurately for stat conversion, Mastery scaling, and diminishing returns.**
- **Target hover presentation is easier to scan** — labels now use colons, snapshot dates use `DD-Mmm-YY`, Current can inherit the stat color when Match Value Color to Stat is enabled, and Missing / Over / Matched keep their own status colors.

### Fixed

- **StatsPro now appears under Combat in the modern AddOn List** across supported client locales, while keeping legacy `X-Category` metadata for addon managers.
- **Target hover rows no longer block normal panel interactions** such as right-click settings and drag behavior.
- **Archon tooltips no longer error or show invalid comparisons** when the current rating is unavailable.

### Changed

- **The project logo is cleaner and easier to read at small sizes** — the old `SP` monogram header was removed so the icon focuses on the StatsPro HUD itself.

## 1.8.0 - 14-May-2026 — Readability and branding

### Added

- **Readability controls in Appearance** — choose Text Outline (`None`, `Outline`, or `Thick Outline`) and add an optional translucent panel background without changing the default transparent HUD.
- **Localized settings labels for the new controls** across all 11 retail locales.

### Changed

- **StatsPro branding has been refreshed** — the README logo and packaged AddOn List icon now use the current stats-panel logo.

## 1.7.1 - 10-May-2026 — Runtime hardening

### Fixed

- **Rare unreadable or malformed stat values no longer break the HUD.**
- **Closing Settings, switching color swatches, or resetting defaults now reliably cancels unconfirmed color previews.**
- **Font and locale hover previews restore reliably** — closing the font picker or language dropdown after browsing previews now forces the committed font back onto the HUD instead of occasionally leaving a hovered preview active.
- **`/ss debug bucket` no longer errors** when stat values are temporarily unreadable.

## 1.7.0 - 10-May-2026 — Defensive and gear feedback pass

Suggested by [@tflo](https://github.com/tflo) in issues #2, #3, and #4. Thank you for the detailed feedback and testing notes.

### Added

- **Optional Stagger row for Brewmaster Monks** — Stagger now lives with the Defensive stats and has its own checkbox and color swatch. It stays hidden for non-Brewmaster specs even when zero values are shown.

### Changed

- **Item Level now belongs to Gear** — Sectioned mode groups iLvl under the Gear heading with Durability and Repair, and fresh/reset Split layouts send Item Level to the side panel with the other gear rows.
- **Block is class-aware** — Block stays visible for Warriors, Paladins, and Shamans, but hides on classes that cannot block even when `Hide Zero Values` is off. Dodge and Parry remain unchanged.

## 1.6.4 - 08-May-2026 — Verification and startup hardening

### Fixed

- **Item Level follows the selected language on the HUD** — the row now localizes with the rest of the stat labels instead of always showing `iLvl`.
- **Corrupted saved settings no longer prevent StatsPro from starting**; invalid values fall back safely.
- **Legacy settings with invalid version data now migrate safely** instead of being skipped.

## 1.6.2 - 06-May-2026 — Item Level row alignment fix

### Fixed

- **Item Level remains on one line in Sectioned mode**, keeping its separator and every row below it aligned at narrow panel widths.

### Changed

- **Item Level separator is now a gray pipe** (`iLvl: 277 | 277`) instead of a gray slash, matching the visual style used between rating and percent on Crit, Haste, Mastery, Vers, Leech, and Speed.

## 1.6.1 - 06-May-2026 — Performance hardening

### Improved

- **Item Level now updates promptly after gear or bag changes** with less background work.
- **Hidden stat panels now use fewer resources.**
- **Refresh Rate changes are more efficient** without affecting live Appearance previews.

### Fixed

- **Invalid saved Scale, Font Size, Text Opacity, or Refresh Rate values now fall back safely.**
- **Versatility rating reads are skipped when Rating display is off** while percentage display continues updating normally.

## 1.6.0 - 05-May-2026 — Item Level + configurable layout blocks

### Added

- **Item Level row** — optional `iLvl` display showing equipped / overall item level, with a warning color when your bags significantly out-level what you are wearing. Suggested by [@tflo](https://github.com/tflo) (issue #1).
- **Configurable Split mode** — choose which logical blocks live in the side panel: Character, Item Level, Offensive, Tertiary, Defensive, Durability, and Repair Cost.
- **Independent Repair Cost toggle** — repair cost can now be shown without also enabling Durability.
- **Stats / Layout / Appearance settings tabs** — settings are reorganized around what you are changing: stat rows, frame/layout behavior, and visual/localization choices.

### Fixed

- **Repair Cost now appears automatically** when delayed item data becomes available after login or visiting a vendor.
- **Armor damage reduction no longer flickers to 0 during transient unreadable 12.x stat reads** — the addon keeps the last clean value until fresh readable data arrives.
- **Korean, Chinese, and Russian font compatibility is more reliable** across Blizzard font variants.
- **Invalid saved color values no longer break rendering** and now fall back safely.
- **Sectioned mode now matches the new layout model** — it shows headers for visible Character, Item Level, Offensive, Tertiary, Defensive, and Gear blocks instead of only the old Defensive divider.
- **Settings launcher localization stays in sync** after language changes.

### Changed

- **Repair Cost is OFF by default for fresh/reset profiles** so it only appears when explicitly enabled.

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

- Show Main Stat replaces the separate Strength, Agility, and Intellect toggles. It turns on automatically if any of those rows was enabled; otherwise it remains off.
- The three primary-stat colors are replaced by one Main Stat color. Existing custom colors carry over when possible; users with different colors for each stat may need to choose a new shared color.

## 1.2.2 - 02-May-2026 — Repair cost loads correctly after login

### Fixed

- **Repair cost now appears automatically after login** once item data is ready, without toggling the setting or swapping gear.

## 1.2.1 - 02-May-2026 — Settings window adapts to small screens

### Fixed

- **Settings window now fits on low-resolution screens and high UI-scale setups.** Previously the Reset and Close buttons could sit below the visible screen edge if your game window was small (e.g. 1024×768) or your UI Scale slider was set high — the window is now capped to ~90% of the game-window height and the inner tabs scroll if content overflows. At typical resolutions (1080p / 1440p / 4K with default UI scale) you'll see no change.

## 1.2.0 - 01-May-2026 — Full settings UI localization

### Added

- **The entire Settings window now localizes** — tabs, section headers, every checkbox / slider / dropdown label, buttons, the launcher tooltip, and the font-coverage warning. All 11 retail locales covered, with live updates on Language dropdown change without `/reload`. enUS and ruRU are native quality; the other nine (deDE / esES / esMX / frFR / itIT / ptBR / koKR / zhCN / zhTW) are best-effort drafts — native-speaker corrections welcome via GitHub Issues.

### Fixed

- **Turning on Show Repair Cost now displays the current value immediately** instead of waiting for a gear change.
- **Settings UI labels no longer render as `?`-boxes** when previewing or committing a non-Latin locale (Russian / Chinese) on an English client. Settings labels now auto-switch to a glyph-compatible font — same logic the stat panels were already using.
- **Section headers no longer corrupt non-ASCII letters** when rendered uppercase in localized languages. Previously Russian "Основные характеристики" produced byte garbage at the section header on non-Russian clients.
- **Font picker hover-preview no longer leaves panels stuck on a previewed font** after closing the picker. Closing without picking always reverts to the committed font, including edge cases with rapid scrolling and unusual close paths.
- **Hovering a language preview no longer leaves panels on a fallback font** after committing a different locale — e.g. hovering Russian then clicking German on an English client used to leave panels rendered in Arial Narrow despite German only needing the default Latin font.
- **Closing the Settings window via Esc no longer leaves orphan dropdown menus** visible on screen.
- **Reset to Defaults now correctly restores the Settings window's font** along with everything else.

### Improved

- **Font picker hover-preview is smoother during rapid scrolling** — redundant re-applies are deduped, and the mouse drifting to picker padding auto-cancels the preview instead of leaving it stuck.
- **Font Size and language previews feel more responsive**, and the font picker opens faster with large SharedMedia lists.

### Known limitations

- **Korean / Chinese label preview on non-CJK clients** still requires a SharedMedia font with CJK coverage installed (unchanged from prior versions). Without one, labels render as `?`-boxes; the inline warning makes the issue visible.

## 1.1.8 - 30-Apr-2026 — Settings UI restructure + multi-column font picker

### Added

- **Multi-column font picker replaces the alphabetical sub-menu dropdown.** Click the Font field in Appearance → Typography and the full font list opens as a scrollable 3-column grid — no more drilling through `2-A` / `B-C` / `D-F` letter buckets. Hover any font to preview it on your panels live; click to commit; close the picker without picking to revert. The currently-selected font is tinted and the grid auto-scrolls to center it on open.
- **Hover-preview for the Language dropdown.** Open Appearance → Localization → Language and hover any locale to see your panel labels switch live to that language. Close the dropdown without clicking to revert; click to commit. When your committed font can't render the hovered locale's glyphs (e.g. Russian on an English client with the default Latin-only font), the preview also temporarily switches to a glyph-compatible fallback so labels render correctly during hover — same auto-switch the commit path already does.
- **Per-stat color customization for Strength, Agility, and Intellect.** Each primary stat now has its own inline swatch, and existing custom primary-stat colors are preserved on upgrade.

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
- **Third-party font replacements no longer change StatsPro's default font unexpectedly.** Installed fonts can still be selected manually.
- **Display tab dropdowns (`Display Mode`, `Language`, `Font`) now share a single column with matching width.** Previously the `Display Mode` dropdown sat far to the right while the other two clung close to their labels and rendered at three different sizes. All three now share the same left edge (column adapts to label widths in any locale) and the same body width. The Language dropdown's collapsed text is shown in compact form (e.g. `English` / `Русский` / `中文 简体`) so it fits without truncation; the menu still shows full descriptive labels when opened.
- **Removed unnecessary empty space below Language** when no font-coverage warning is shown.
- **The Font dropdown remains usable with large SharedMedia libraries** by grouping long font lists into compact alphabetical submenus.

### Added

- **Localized stat-color labels and their alignment now update immediately** when Language changes, without `/reload`.

## 1.1.5 - 29-Apr-2026 — Honest font coverage on cross-locale picks

### Fixed

- **Selecting Russian on a non-Russian client now switches to Blizzard's Arial Narrow automatically** for clearer Cyrillic text.
- **Existing cross-locale language choices now recover to a compatible font automatically** on the next login.
- **The font-coverage warning now appears correctly** when the selected locale still lacks a compatible font.

### Known limitations

- **Korean / Chinese on non-CJK clients** still requires a SharedMedia font with CJK coverage (NotoSansCJK, SourceHanSans, WenQuanYi, etc.) — Blizzard doesn't ship CJK glyphs on non-CJK client builds, and bundled CJK fonts are too large (5-20MB) to ship inside the addon. Install one of the SharedMedia CJK addons from CurseForge for clean rendering. Without one, labels render as `?`-boxes and the inline warning will stay visible.

## 1.1.4 - 28-Apr-2026 — LSM CJK font auto-detect

### Fixed

- **Common SharedMedia CJK fonts no longer trigger false coverage warnings**; NotoCJK and SourceHan also work correctly for Russian.

### Known limitations

- **Some CJK fonts with generic filenames may still show a false coverage warning**; you can ignore it or report the font family on GitHub Issues.
- **With multiple CJK fonts installed, automatic selection may not choose your preferred font**; select it manually for best results.

## 1.1.3 - 28-Apr-2026 — Settings window layering fix

### Fixed

- **Settings now opens above raid frames and other HUD add-ons.**

## 1.1.2 - 28-Apr-2026 — Fix empty panels + empty settings on v1.1.x

### Fixed

- **Panels render empty and settings window opens blank on v1.1.0 / v1.1.1.** Hotfix — no DB reset needed, all preferences preserved.

## 1.1.1 - 28-Apr-2026 — Migration fix for opted-out users

### Fixed

- **Migration honors the v1.0.x "use localized labels = off" opt-out** — earlier v1.1.0 adopters with the toggle off were silently re-enabled. If affected: open Display → Localization → pick "English".

## 1.1.0 - 28-Apr-2026 — Manual locale override + auto-switch font

### Added

- **New Language dropdown in Display → Localization** lets you choose any supported locale regardless of the WoW client language, replacing the earlier localization toggle.
- **Auto-switch font when picked locale needs glyphs the current font lacks.** Saves your previous font, switches to the locale-aware default, restores on switching back. Manually picking a font clears the auto-switch memory.
- **Inline warning under the Language dropdown** when no installed font covers the picked locale's glyphs. Doesn't block the choice.

### Known limitations

- **LSM CJK fonts treated as Latin-only by the auto-switch logic** — picking a CJK locale fires a "font may not cover glyphs" warning even if your LSM font does cover them. Workaround: pick the LSM font manually via the Font dropdown after switching locale.

## 1.0.12 - 27-Apr-2026 — Per-locale TOC Notes

### Added

- **The AddOn List description is now localized** for all supported non-English retail locales. Native-speaker corrections are welcome via GitHub Issues.

## 1.0.11 - 27-Apr-2026 — Localized color-picker labels + Localization toggle preview fix

### Added

- **Color-picker rows in the Display tab now show localized stat names** (e.g. ruRU `Крит Цвет:`, zhCN `暴击 颜色:`, deDE `Krit Farbe:`). The two non-stat rows ("Rating Color" / "Percentage Color") still show those words in English; only "Color" is localized.

### Fixed

- **Localization-toggle previews no longer render as `?` boxes on CJK clients.**

## 1.0.10 - 27-Apr-2026 — Locale-aware default font (CJK fix) + RGBToHex hardening

### Fixed

- **Localized stat labels now render correctly out of the box on CJK clients** with a locale-appropriate default font.
- **Existing users on the old default font upgrade automatically**, while explicit font choices are preserved.
- **Font re-applies cleanly within the upgrade session** — no broken-glyph flash for CJK users until next `/reload`.
- **Out-of-range saved color values now fall back safely** instead of breaking color rendering.

## 1.0.9 - 27-Apr-2026 — Carry forward settings from upstream SwiftStats (TaylorSay)

### Added

- **One-time settings carry-forward from the original SwiftStats by TaylorSay.** Users moving from CurseForge SwiftStats to StatsPro keep their panel position, font, scale, and per-stat colors on first launch.

## 1.0.8 - 27-Apr-2026 — Primary stats now show effective (buffed) values + armor combat-taint guard

### Fixed

- **Primary stats now match Blizzard's character sheet while buffed** instead of showing an understated base value.
- **Armor damage reduction no longer disappears mid-pull** when Midnight temporarily restricts the underlying stat data.

## 1.0.7 - 27-Apr-2026 — Translation polish + Korean Armor/Defensive disambiguation

### Fixed

- **The Defensive panel no longer freezes in Split mode** when all Offensive stats are disabled.
- **One-time SwiftStats settings import now runs reliably on first login** regardless of addon load order.
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
- **`/ss debug` slash subcommand** — prints addon, settings, and panel diagnostics for troubleshooting.

### Fixed

- **Defensive sub-toggles now grey out when master is off** (matches existing Tertiary / Durability dependency-disable pattern).
- **Reset to Defaults now refreshes the existing Settings window correctly** without duplicated or orphaned controls.
- **Repair coin moved to its own row below stats** — was sharing a row with the `Repair:` label and could overlap stat content in narrow panel layouts (visual mash like `Repair55..88..12`).

## 1.0.4 - 26-Apr-2026 — Combat-safe lock toggle

### Fixed

- **Lock Frames changes made during combat now apply correctly** when combat ends.
- **Imported SwiftStats colors no longer remain linked to the original add-on**, so editing colors in either add-on does not alter the other.
- **SwiftStats imports now receive all StatsPro defaults** even when legacy version data happens to match.

### Improved

- **Repair cost uses its own auto-fit row** — the panel widens only when the complete repair row is wider than the stat rows, while stat columns retain their compact alignment.
- **Tertiary sub-toggles grey out when master is off** (matches Defensive tab pattern).
- **Font dropdown refreshes on each open** — fonts registered via LibSharedMedia after StatsPro loads now appear without `/reload`.

## 1.0.3 - 26-Apr-2026 — Refresh-rate slider

### Added

- **Refresh Rate slider** on the Display tab (range `0.1s – 1.0s`, default `0.5s`) replaces the old manual console workaround.

## 1.0.2 - 26-Apr-2026 — Dynamic version display

### Fixed

- **Settings and Blizzard's AddOns panel now show the current StatsPro version** instead of a stale hardcoded value.

## 1.0.1 - 26-Apr-2026 — Single-column display polish

### Changed

- **Single-column layout when only one display dimension is on** — toggling `Show Rating` or `Show Percentage` off now stacks every visible number in one RIGHT-justified column. Previously non-rating rows (Primary / Defensives / Durability / Repair) collapsed to a degenerate empty layout in the value column.

### Fixed

- **Single-display modes no longer leave a wide gap or truncate percentages.**
- **Protected in-combat stat text no longer causes repeated UI errors.**

## 1.0.0 - 26-Apr-2026 — Initial release

First public release under the StatsPro name. Inspired by SwiftStats v2.1 by TaylorSay (MIT), with substantial StatsPro-specific development.

### Added

- **Defensive stats panel** — Dodge, Parry, Block, Armor (as % damage reduction). Independent visibility toggle, per-stat color swatches, hide-zero option.
- **Durability tracking** — choose average or worst-slot percentage with familiar one-decimal precision.
- **Auto-color durability** — green ≥60%, yellow ≥30%, red <30%. Override via custom color when auto-color is off.
- **Repair cost** — live vendor-style gold, silver, and copper display on its own line below durability.
- **Display modes** — Flat (one panel, all stats), Sectioned (one panel with `— Defensive —` divider), Split (separate draggable panels).
- **Multi-panel positioning** — defensive panel independently draggable in Split mode.
- **Master visibility toggle** — show/hide all panels via checkbox or `/ss toggle`.
- **Settings UI rewrite** — three-tab config window (Display / Stats / Defensive) with inline color swatches and dependency-aware enable/disable.
- **Scrollable settings window** — full Stats / Defensive content reachable on small monitors and windowed-mode layouts. Scroll resets to top on tab switch.
- **Native Blizzard Settings panel integration** — registers under `Esc → Options → AddOns → StatsPro`. Coexists with `/ss` and the launcher button.

### Changed

- **Default text alignment** — `RIGHT` (was `LEFT`). Migrated automatically; explicit user choices preserved.
- **Armor damage reduction remains stable** when Midnight temporarily restricts armor data.
- **Versatility** — split into rating + flat dual-source display, with combat-safe caching.
- **Repair cost uses Midnight-compatible item data** so restricted tooltip values no longer break the row.

### Fixed

- **Misaligned rating + percentage columns** — rating is now its own RIGHT-justified third FontString between label and value, so all rating right-edges line up vertically and the percent column has a clean fixed left edge.
- **Frame positions now persist reliably** after moving a panel.
- **Panel positions are preserved across `/reload`** even after unusual drag paths.
- **Durability % differing from vendor** — default switched to average (matches vendor display); worst-slot mode preserved as opt-in.
- **Combat-protected stat reads no longer trigger addon errors.**

### Removed

- **Minimap button** — same actions reachable via `/ss toggle`, the Blizzard Settings entry, or the master visibility checkbox. Frees minimap real estate.
- **Legacy slash subcommands** (`move`, `unlock`, `lock`, `reset`, `scale N`, `size N`) — replaced by the redesigned Settings window. Remaining commands: `/ss` (open config), `/ss show`, `/ss hide`, `/ss toggle`, `/ss help`.

### Migrated

- Existing **SwiftStatsLocal** users keep all settings on first launch, and the original add-on's saved data is left untouched.
