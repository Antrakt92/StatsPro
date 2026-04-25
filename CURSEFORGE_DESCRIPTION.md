<!--
  CurseForge project description for StatsPro.
  Paste the body below (everything after this comment) into the project's
  Description field on CurseForge in Markdown mode. Replace each
  INSERT_<filename> placeholder with the URL CurseForge gives you after
  uploading the matching image (see "How to upload images" at the bottom
  of this file).
-->

![StatsPro split mode panels](INSERT_01-split-mode-hero)

# StatsPro

A clean, lightweight **on-screen HUD for World of Warcraft Retail** that displays your secondary stats, defensive stats, durability, and live repair cost — without the bloat of a full framework.

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

**With the defensive panel enabled — Dodge, Parry, Armor as % damage reduction:**

![Flat with defensives](INSERT_03-flat-with-defensives)

**Repair cost at the vendor — vendor-format coin string with embedded gold / silver / copper icons:**

![Repair cost at vendor](INSERT_04-repair-cost-vendor)

**Split mode — separate draggable panels for offensive and defensive stats:**

![Split mode panels](INSERT_01-split-mode-hero)

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

- **Two-column rendering** — labels right-justified, values left-justified, constant tight gap on every row. Clean professional HUD look without monospace dependency.
- **TWW 12.x ready** — every stat read passes through secret-value filtering so the HUD never shows `[secret]` tokens or breaks mid-pull.
- **Repair cost actually shows** — uses `C_TooltipInfo.GetInventoryItem` plus `TooltipUtil.SurfaceArgs` (the modern Blizzard path), not the legacy `GameTooltip:SetInventoryItem` that returns secret values in 12.x.
- **Position persists across reloads** — proper `SetUserPlaced` ordering means dragged panels stay where you put them, even after `/reload` or relog.
- **Vendor-accurate repair cost format** — `GetCoinTextureString` produces the exact `46g 40s 81c` format with inline coin icons that the vendor frame uses, not a hand-rolled `46g` truncation.

---

## Migration from SwiftStats / SwiftStatsLocal

If you previously used **SwiftStats** or the **SwiftStatsLocal** fork, your settings migrate automatically on first load — no reconfiguration needed. Just install StatsPro, `/reload`, and disable the old addon in your AddOns list. Frame positions, colors, font choice, and toggles all transfer over.

---

## Compatibility

- **WoW Retail** — Interface 12.0.5 / 12.0.7 (The War Within / Midnight)
- Classic / TBC / MoP Classic — not supported (Retail-only)

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

<!--
  ============================================================
  HOW TO UPLOAD IMAGES (workflow notes — do NOT paste this section
  into the CurseForge description field)
  ============================================================

  Image placeholders in the body above (each appears once):
    INSERT_01-split-mode-hero       → screenshots/01-split-mode-hero.jpg
    INSERT_02-flat-default          → screenshots/02-flat-default.jpg
    INSERT_03-flat-with-defensives  → screenshots/03-flat-with-defensives.jpg
    INSERT_04-repair-cost-vendor    → screenshots/04-repair-cost-vendor.jpg
    INSERT_05-settings-display      → screenshots/05-settings-display.jpg
    INSERT_06-settings-stats        → screenshots/06-settings-stats.jpg
    INSERT_07-settings-defensive    → screenshots/07-settings-defensive.jpg

  Easiest workflow (one-shot):
    1. Open the project's Description editor on CurseForge in Markdown mode.
    2. Paste the entire body above.
    3. For each INSERT_<name> placeholder:
         a. Place cursor on the placeholder line.
         b. Click the "Image" button in the editor toolbar (the picture icon).
         c. Upload the matching screenshots/<name>.jpg file.
         d. The editor inserts the markdown image syntax with the CDN URL.
         e. Delete the leftover INSERT_ placeholder text on that line.
    4. Save / Submit.

  Alternative workflow (bulk upload):
    1. Open the project's "Images" tab on CurseForge.
    2. Upload all 7 numbered screenshots from the screenshots/ folder.
    3. CurseForge assigns each a permanent URL on media.forgecdn.net.
    4. In the description Markdown, replace each INSERT_<name> token with the
       matching URL.

  Extra screenshots (not referenced in the body, kept in the repo for future
  reuse — extra-flat-alt-1..4 and extra-flat-with-defensives-alt) can be
  uploaded later if you want to add more visual examples.
-->
