<!--
  CurseForge project description for StatsPro — finalized version.

  How to use this file:
    1. Copy everything between the two HORIZONTAL BAR markers below
       (skipping these top comments and the bottom comment block).
    2. On CurseForge → project → Description editor → switch to Markdown mode.
    3. Paste.
    4. For each `INSERT_<filename>` placeholder line:
         a. Click the "Image" button in the editor toolbar.
         b. Upload the matching file from screenshots/<filename>.jpg.
         c. CurseForge replaces the line with a media.forgecdn.net URL.
         d. Delete any leftover `INSERT_` token text on the line.
    5. Save / Submit.

  Reminder: do NOT use raw.githubusercontent.com URLs as image sources —
  GitHub explicitly forbids hotlinking raw content as a CDN, and the
  images will eventually 429 / 403 under traffic. CurseForge's own
  image hosting (media.forgecdn.net) is permanent and built for this.
-->

---  COPY FROM HERE ---

![StatsPro split mode panels](INSERT_01-split-mode-hero)

# StatsPro

A clean, lightweight on-screen HUD for World of Warcraft Retail. Displays your secondary stats, defensive stats, durability, and live repair cost — without the bloat of a full framework.

> Forked from [SwiftStats by TaylorSay](https://www.curseforge.com/wow/addons/swiftstats) (MIT). Adds a defensive panel, durability and repair cost integration, multi-panel layouts, and tightened two-column rendering.

---

## Features

- **Secondary stats** — Crit, Haste, Mastery, Versatility, with rating and percentage display options
- **Tertiary stats** — Leech, Avoidance, Speed
- **Primary stats** — Strength, Agility, Intellect (per-stat toggle)
- **Defensive panel** — Dodge, Parry, Block, Armor (as % damage reduction)
- **Durability** — average or worst-slot percentage with auto-color thresholds (green / yellow / red)
- **Repair cost** — live vendor-format coin display with embedded gold / silver / copper icons
- **Three display modes** — Flat, Sectioned, or Split into separate movable panels
- **Per-stat customization** — colors, font (LibSharedMedia compatible), font size, panel scale
- **Light footprint** — single-file pure Lua, no Ace3, no heavy framework dependencies

---

## How it looks

**Flat mode (default) — secondary stats in one tight panel:**

![Flat default panel](INSERT_02-flat-default)

**Rating and percentage side by side — enable both display modes to see the underlying combat ratings alongside the resulting percentages, with a clean separator and three perfectly aligned columns:**

![Rating and percentage columns](INSERT_08-rating-and-percentage)

**With the defensive panel enabled — Dodge, Parry, Armor as % damage reduction:**

![Flat with defensives](INSERT_03-flat-with-defensives)

**Repair cost at the vendor — vendor-format coin string with embedded gold / silver / copper icons:**

![Repair cost at vendor](INSERT_04-repair-cost-vendor)

**Split mode** lets you place offensive and defensive stats as separate, independently draggable panels — see the screenshot at the top of this page.

---

## Configuration

Open the settings window with `/ss` or `/statspro`. Three tabs cover everything.

**Display tab** — visibility, lock, display mode, font, font size, panel scale, color presets:

![Display tab](INSERT_05-settings-display)

**Stats tab** — toggle Primary and Tertiary stats with inline color swatches:

![Stats tab](INSERT_06-settings-stats)

**Defensive tab** — toggle Defensive stats, Durability with auto-color thresholds, worst-slot vs average mode, and Repair Cost:

![Defensive tab](INSERT_07-settings-defensive)

---

## Slash commands

| Command | Action |
|---|---|
| `/ss` or `/statspro` | Open settings window |
| `/ss show` | Show stats panel |
| `/ss hide` | Hide stats panel |
| `/ss toggle` | Toggle visibility |

---

## Why "Pro"

- **Always tight, never crooked** — the two-column layout keeps labels and values perfectly aligned regardless of which stats you enable, what font you pick, or what scale you set.
- **War Within (12.x) ready** — uses Blizzard's modern tooltip API, so repair cost actually shows up at the vendor (the legacy API silently broke this in older addons).
- **Position survives /reload** — drag your panels once, they stay there forever. No "reset to default" surprises after a UI reload or relog.
- **Vendor-accurate coin display** — repair cost shows as `46g 40s 81c` with the same inline gold / silver / copper icons the vendor frame uses, not a stripped-down `46g`.
- **No combat lag, no taint errors** — every stat read is filtered for protected values before display, so the HUD never shows `[secret]` tokens, never breaks mid-pull, and never bleeds tainted state into other addons.

---

## Migration from SwiftStats

If you previously used **SwiftStats**, your settings migrate automatically on first load — no reconfiguration needed. Just install StatsPro, `/reload`, and disable SwiftStats in your AddOns list. Frame positions, colors, font choice, and toggles all transfer over.

---

## Credits

- **TaylorSay** — author of the original [SwiftStats](https://www.curseforge.com/wow/addons/swiftstats) (MIT), on top of which StatsPro is built.
- **LibSharedMedia-3.0** — font selection support.
- **LibStub** and **CallbackHandler-1.0** — bundled standard libraries.

---

## Links

- **GitHub repository:** [github.com/Antrakt92/StatsPro](https://github.com/Antrakt92/StatsPro)
- **Bug reports / feature requests:** [GitHub Issues](https://github.com/Antrakt92/StatsPro/issues)
- **Changelog:** [CHANGELOG.md](https://github.com/Antrakt92/StatsPro/blob/main/CHANGELOG.md)

**License:** MIT — both the original SwiftStats portion (© TaylorSay) and the StatsPro extensions (© Antrakt). See [LICENSE](https://github.com/Antrakt92/StatsPro/blob/main/LICENSE) for the full text.

---  COPY UP TO HERE ---

<!--
  ============================================================
  IMAGE PLACEHOLDER → SOURCE FILE MAPPING
  ============================================================

  Each INSERT_<name> placeholder appears exactly once in the body.
  Upload these files in this order via the editor's image button:

    INSERT_01-split-mode-hero        → screenshots/01-split-mode-hero.jpg
    INSERT_02-flat-default           → screenshots/02-flat-default.jpg
    INSERT_08-rating-and-percentage  → screenshots/08-rating-and-percentage.jpg
    INSERT_03-flat-with-defensives   → screenshots/03-flat-with-defensives.jpg
    INSERT_04-repair-cost-vendor     → screenshots/04-repair-cost-vendor.jpg
    INSERT_05-settings-display       → screenshots/05-settings-display.jpg
    INSERT_06-settings-stats         → screenshots/06-settings-stats.jpg
    INSERT_07-settings-defensive     → screenshots/07-settings-defensive.jpg

  Note: 01-split-mode-hero is referenced ONCE (as the hero image at the
  top of the page). The "Split mode" entry in "How it looks" now uses a
  text-only callback to the hero shot to avoid duplicating the same
  image twice on a single page.

  Extra screenshots (extra-flat-alt-1..4, extra-flat-with-defensives-alt)
  are NOT referenced in the body but stay in the repo for future use.
-->
