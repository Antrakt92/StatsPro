# StatsPro

[![Latest release](https://img.shields.io/github/v/release/Antrakt92/StatsPro?label=release&color=brightgreen)](https://github.com/Antrakt92/StatsPro/releases/latest)
[![CurseForge](https://img.shields.io/curseforge/dt/1525100?label=curseforge&color=orange)](https://www.curseforge.com/wow/addons/statspro)
[![License: MIT](https://img.shields.io/github/license/Antrakt92/StatsPro)](LICENSE)

A lightweight on-screen HUD for World of Warcraft Retail. Displays secondary stats,
defensive stats, durability and live repair cost in a clean, draggable panel — no
heavy framework needed.

![StatsPro split-mode panels](screenshots/01-split-mode-hero.jpg)

> Originally inspired by [SwiftStats by TaylorSay](https://www.curseforge.com/wow/addons/swiftstats)
> (MIT). StatsPro is substantially rewritten — only ~9% of upstream code remains
> verbatim (defaults and boilerplate). The defensive panel, durability/repair-cost
> system, multi-panel layouts, auto-aligning column rendering, 12.x retail secret-value
> handling, and the three-tab settings UI are all original work. See
> [`CHANGELOG.md`](CHANGELOG.md) for the full list of additions per version.

## Features

- **Secondary stats** — Crit, Haste, Mastery, Versatility (with rating + percentage display options)
- **Tertiary stats** — Leech, Avoidance, Speed
- **Primary stats** — Strength, Agility, Intellect (per-stat toggle)
- **Defensive panel** — Dodge, Parry, Block, Armor (as % damage reduction)
- **Durability** — average or worst-slot percentage with auto-color thresholds (green / yellow / red)
- **Repair cost** — live vendor-format coin display (`46g 40s 81c` with embedded gold/silver/copper icons)
- **Three display modes** — Flat (one panel), Sectioned (one panel with header divider), Split (separate movable panels for offensive vs defensive)
- **Customization** — per-stat colors, fonts via LibSharedMedia, font size, panel scale, refresh rate
- **Auto-aligning columns** — labels and values stay neatly aligned regardless of which stats are enabled, font, or scale; toggling rating-only or percent-only collapses cleanly into one tight column with no awkward gaps
- **Light footprint** — single-file pure Lua (~1.8k lines), no Ace3, no embedded UI library

## How it looks

**Flat mode (default) — secondary stats in one tight panel:**

![Flat default panel](screenshots/02-flat-default.jpg)

**Rating + percentage side by side — toggle both display modes for three perfectly aligned columns with a clean separator:**

![Rating and percentage columns](screenshots/08-rating-and-percentage.jpg)

**Defensive panel enabled — Dodge, Parry, Armor as % damage reduction:**

![Flat with defensives](screenshots/03-flat-with-defensives.jpg)

**Live repair cost at the vendor — vendor-format coin string with inline gold/silver/copper icons:**

![Repair cost at vendor](screenshots/04-repair-cost-vendor.jpg)

## Slash commands

| Command | Action |
|---|---|
| `/ss` or `/statspro` | Open settings window |
| `/ss show` | Show stats panel |
| `/ss hide` | Hide stats panel |
| `/ss toggle` | Toggle visibility |
| `/ss help` | List commands in chat |

## Installation

**CurseForge:** [www.curseforge.com/wow/addons/statspro](https://www.curseforge.com/wow/addons/statspro)
— install via the CurseForge App or WowUp.

**Manual:** download the latest zip from the
[Releases page](https://github.com/Antrakt92/StatsPro/releases/latest), extract the
`StatsPro` folder into `World of Warcraft\_retail_\Interface\AddOns\`.

## Configuration

Type `/ss` or click the StatsPro entry in the Blizzard AddOns settings panel to open
the configuration window.

| Tab | What lives here |
|---|---|
| **Display** | Master visibility, lock, display mode, font, font size, panel scale, refresh rate, color presets |
| **Stats** | Per-stat toggles for Primary (Str/Agi/Int) and Tertiary (Leech/Avoidance/Speed) with inline color swatches |
| **Defensive** | Per-stat toggles for Dodge/Parry/Block/Armor, durability options (auto-color, worst-slot vs average), repair cost |

![Display tab settings](screenshots/05-settings-display.jpg)

## Compatibility

- **WoW Retail** — Interface `120005, 120007` (The War Within / Midnight)
- Classic / TBC / MoP Classic — not supported (Retail-only at this time)

## Architecture (contributors / forks)

Single-file design. Everything renders out of [`StatsPro.lua`](StatsPro.lua):

- **`Panel:SetTextSafe`** — three-FontString rendering (label / rating / value), each
  with its own `JustifyH` for column alignment. Caches non-secret widths per render
  to survive in-combat measurement taint.
- **`FmtRatingPct` / `FmtPctOnly` / `RouteValueOnly`** — column-routing helpers.
  Dual-column mode = both display toggles on; otherwise everything stacks in the
  rating column. `IsDualColMode()` is the single source of truth for that decision.
- **`UpdateStats`** — drives the per-frame OnUpdate, dispatches by display mode
  (flat / sectioned / split), gates value-column joining on `IsDualColMode()`.
- **`MigrateDB`** — DB schema versioning. Bump `CURRENT_DB_VERSION` and add a
  conditional `vN-1 → vN` clause when changing a default value, so existing users
  on the old default upgrade automatically while explicit user choices are preserved.

The repository's [`CHANGELOG.md`](CHANGELOG.md) documents what shipped per version and
why. Tricky 12.x retail API behavior (secret-value handling, FontString taint, layout
ordering quirks) is annotated as `WHY:` / `WARNING:` comments at the relevant call sites.

## Bug reports / feature requests

Open an issue on [GitHub Issues](https://github.com/Antrakt92/StatsPro/issues). Helpful
to include: WoW client version, addon version (visible in the settings window header),
exact reproduction steps, and a screenshot if the issue is visual.

## Acknowledgements

- **[TaylorSay](https://www.curseforge.com/members/taylorsay)** — author of the original
  [SwiftStats](https://www.curseforge.com/wow/addons/swiftstats) addon (MIT), the
  project that inspired StatsPro and from which the initial defaults and color scheme
  are derived.
- **[LibSharedMedia-3.0](https://www.curseforge.com/wow/addons/libsharedmedia-3-0)** — font selection support.

## License

[MIT](LICENSE) — copyright held by Antrakt for original code (~91% of the codebase)
and by TaylorSay for derived portions (~9%, mostly defaults and boilerplate from
upstream SwiftStats).
