# StatsPro

A lightweight on-screen HUD for World of Warcraft Retail. Displays secondary stats,
defensive stats, durability and repair cost in a clean, draggable panel — without
requiring any heavy framework.

> Originally inspired by [SwiftStats](https://www.curseforge.com/wow/addons/swiftstats) by
> TaylorSay (MIT). StatsPro is substantially rewritten — only ~9% of upstream code remains
> verbatim (mostly defaults and boilerplate). The defensive panel, durability/repair cost
> system, multi-panel layouts, two-column rendering pipeline, 12.x retail secret-value
> handling, and three-tab settings UI are all original work. See [`CHANGELOG.md`](CHANGELOG.md)
> for the full diff.

## Features

- **Secondary stats:** Crit, Haste, Mastery, Versatility (with rating + percentage display options)
- **Tertiary stats:** Leech, Avoidance, Speed
- **Primary stats:** Strength, Agility, Intellect (toggle per-stat)
- **Defensive panel:** Dodge, Parry, Block, Armor (as % damage reduction)
- **Durability:** Average or worst-slot percentage with auto-color thresholds
- **Repair cost:** Live vendor-format coin display (`46g 40s 81c` with embedded icons)
- **Three display modes:** Flat (single panel), Sectioned (one panel with header divider), Split (separate movable panels for offensive vs defensive)
- **Customization:** Per-stat colors, font (LibSharedMedia compatible), font size, scale, alignment
- **Light footprint:** Single-file pure Lua (~1600 lines), only one optional library (LibSharedMedia)
- **No framework dependency:** No Ace3, no LibStub addon-side, no embedded UI library

## Slash commands

| Command | Action |
|---|---|
| `/ss` or `/statspro` | Open settings window |
| `/ss show` | Show stats panel |
| `/ss hide` | Hide stats panel |
| `/ss toggle` | Toggle visibility |

## Installation

**CurseForge App:** search for `StatsPro` and click Install.

**Manual:** download the latest release from the
[Releases page](https://github.com/Antrakt92/StatsPro/releases),
extract the `StatsPro` folder into `World of Warcraft\_retail_\Interface\AddOns\`.

## Migration from SwiftStats / SwiftStatsLocal

If you previously used SwiftStats or SwiftStatsLocal, your settings will migrate
automatically on first load — no action required. After confirming everything looks
correct, you can disable the old addon in the AddOns list.

## Compatibility

- **WoW Retail** — Interface 120005 / 120007 (The War Within / Midnight)
- Classic / TBC / MoP Classic — not supported (Retail-only at this time)

## Configuration

Type `/ss` or click the entry in the Blizzard AddOns settings panel to open the
configuration window. Three tabs:

- **Display** — visibility, lock, display mode, font, alignment, size, scale, color presets
- **Stats** — toggle Primary / Tertiary stats with inline color swatches
- **Defensive** — toggle Defensive stats and Durability with auto-color thresholds and "use worst slot" override

## Acknowledgements

- **[TaylorSay](https://www.curseforge.com/members/taylorsay)** — author of the original
  [SwiftStats](https://www.curseforge.com/wow/addons/swiftstats) addon (MIT), the project
  that inspired StatsPro and from which the initial defaults and color scheme are derived.
- **[LibSharedMedia-3.0](https://www.curseforge.com/wow/addons/libsharedmedia-3-0)** — font selection support.

## License

[MIT](LICENSE) — copyright held by Antrakt for original code (~91% of the codebase) and
by TaylorSay for derived portions (~9%, mostly defaults and boilerplate from upstream
SwiftStats).
