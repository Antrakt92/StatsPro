<!--
  CurseForge project description for StatsPro — finalized, with embedded
  media.forgecdn.net image URLs (already uploaded to CurseForge once).

  How to use this file:
    1. On CurseForge → project → Description editor.
    2. **CRITICAL** — switch the dropdown in the top right from
       "WYSIWYG" to "Markdown" BEFORE pasting. Otherwise the editor
       wraps every paragraph in <div> tags and breaks markdown rendering.
    3. Clear the editor (Ctrl+A → Delete) if anything is in it.
    4. Copy everything between the COPY-FROM / COPY-UP-TO markers below
       and paste it into the editor.
    5. Save / Submit.

  All image URLs in the body are already permanent media.forgecdn.net
  links — no further upload step needed. If you need to re-upload an
  image (e.g. updated screenshot), upload via the editor's image button
  in Markdown mode and replace the corresponding URL inline.
-->

---  COPY FROM HERE ---

![StatsPro split mode panels](https://media.forgecdn.net/attachments/description/null/description_714b0dd1-58c7-4216-8423-48e7ae785b61.jpg)

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

![Flat default panel](https://media.forgecdn.net/attachments/description/null/description_f61416b2-f82f-4cdc-aebe-4e226ef334b1.jpg)

**Rating and percentage side by side — enable both display modes to see the underlying combat ratings alongside the resulting percentages, with a clean separator and three perfectly aligned columns:**

![Rating and percentage columns](https://media.forgecdn.net/attachments/description/null/description_8b0354e2-0acb-40dc-bd74-45f028fd6c3a.jpg)

**With the defensive panel enabled — Dodge, Parry, Armor as % damage reduction:**

![Flat with defensives](https://media.forgecdn.net/attachments/description/null/description_9e05008c-624d-46a3-a99f-3eb832c5303e.jpg)

**Repair cost at the vendor — vendor-format coin string with embedded gold / silver / copper icons:**

![Repair cost at vendor](https://media.forgecdn.net/attachments/description/null/description_3d816883-a8b8-461e-8bfe-8e866d42f859.jpg)

**Split mode** lets you place offensive and defensive stats as separate, independently draggable panels — see the screenshot at the top of this page.

---

## Configuration

Open the settings window with `/ss` or `/statspro`. Three tabs cover everything.

**Display tab** — visibility, lock, display mode, font, font size, panel scale, color presets:

![Display tab](https://media.forgecdn.net/attachments/description/null/description_be4c4b4a-d3fe-438f-b9e7-16ae5d190b83.jpg)

**Stats tab** — toggle Primary and Tertiary stats with inline color swatches:

![Stats tab](https://media.forgecdn.net/attachments/description/null/description_bbcfb289-bc44-4ce8-85cc-e77fa5f04a1f.jpg)

**Defensive tab** — toggle Defensive stats, Durability with auto-color thresholds, worst-slot vs average mode, and Repair Cost:

![Defensive tab](https://media.forgecdn.net/attachments/description/null/description_93fdc830-750a-4a30-a4b9-2adb14af68c7.jpg)

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
  CURSEFORGE CDN URL → LOCAL SOURCE FILE MAPPING
  ============================================================

  These are the permanent media.forgecdn.net URLs after the first
  upload through CurseForge's description editor. If a screenshot
  ever needs replacing, the local source file is the one to re-render
  / re-edit, then re-upload through the editor and swap the URL in
  the body.

    01-split-mode-hero        → .../description_714b0dd1-58c7-4216-8423-48e7ae785b61.jpg
    02-flat-default           → .../description_f61416b2-f82f-4cdc-aebe-4e226ef334b1.jpg
    08-rating-and-percentage  → .../description_8b0354e2-0acb-40dc-bd74-45f028fd6c3a.jpg
    03-flat-with-defensives   → .../description_9e05008c-624d-46a3-a99f-3eb832c5303e.jpg
    04-repair-cost-vendor     → .../description_3d816883-a8b8-461e-8bfe-8e866d42f859.jpg
    05-settings-display       → .../description_be4c4b4a-d3fe-438f-b9e7-16ae5d190b83.jpg
    06-settings-stats         → .../description_bbcfb289-bc44-4ce8-85cc-e77fa5f04a1f.jpg
    07-settings-defensive     → .../description_93fdc830-750a-4a30-a4b9-2adb14af68c7.jpg

  Extra screenshots (extra-flat-alt-1..4, extra-flat-with-defensives-alt)
  are NOT referenced in the body but stay in the repo for future use.
-->
