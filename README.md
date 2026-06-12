<p align="center">
  <img src="screenshots/logo.png" alt="StatsPro logo" width="280">
</p>

<h1 align="center">StatsPro</h1>

<p align="center">
  <a href="https://github.com/Antrakt92/StatsPro/releases/latest"><img src="https://img.shields.io/github/v/release/Antrakt92/StatsPro?label=release&color=brightgreen" alt="Latest release"></a>
  <a href="https://www.curseforge.com/wow/addons/statspro"><img src="https://img.shields.io/curseforge/dt/1525100?label=curseforge&color=orange" alt="CurseForge"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Antrakt92/StatsPro" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/WoW-Retail%2012.x-blueviolet" alt="WoW Retail 12.x">
  <a href="https://ko-fi.com/antrakt92"><img src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=ko-fi&logoColor=white" alt="Support on Ko-fi"></a>
</p>

<p align="center">
  A clean, colorful stat HUD for World of Warcraft Retail / Midnight 12.x.
  Secondary stats, Archon targets, item level, defensives, durability, and repair
  cost in draggable panels — without the bloat of a full framework.
</p>

<p align="center">
  <strong>Actively maintained.</strong> <span style="color: red;"><strong>Feedback and suggestions are very welcome.</strong></span>
</p>

<p align="center">
  <img src="screenshots/09-flat-in-game.jpg" alt="StatsPro — full flat panel sitting next to the action bars during real-world play">
</p>

> Originally inspired by [SwiftStats by TaylorSay](https://www.curseforge.com/wow/addons/swiftstats)
> (MIT) — substantially rewritten and extended. The side-panel layout, durability and
> repair-cost system, configurable multi-panel routing, auto-aligning column rendering, 12.x retail
> secret-value handling, and the three-tab settings UI are all original work; some
> upstream boilerplate, color defaults, and the basic stat list remain. See
> [`CHANGELOG.md`](CHANGELOG.md) for the full list of additions per version.

## At a glance

- **Secondary stat HUD** — Crit, Haste, Mastery, Versatility with rating, percentage, or both.
- **Archon target hovers** — compare your current rating to generated M+ High Keys or Raid Mythic All Bosses targets.
- **Defensive and gear rows** — Dodge, Parry, Block, Brewmaster Stagger, Armor DR, durability, repair cost, item level, and stamina.
- **Readable layouts** — Flat, Sectioned, or Split panels with auto-aligning columns and optional background/outline.
- **Live localization** — HUD, settings, target hovers, and slash confirmations follow your chosen output language.
- **Retail 12.x safety** — built around modern secret-value and tooltip API traps.

## What StatsPro shows

| Area | Rows |
|---|---|
| **Offensive** | Crit, Haste, Mastery, Versatility |
| **Character** | Main stat auto-detect, Stamina, Item Level |
| **Tertiary** | Leech, Avoidance, Movement |
| **Defensive** | Dodge, Parry, Block, Brewmaster Stagger, Armor damage reduction |
| **Gear** | Durability, worst-slot durability, live vendor-format repair cost |

Everything is optional. Keep a tiny secondary-stat strip, build a tank dashboard,
or split gear/defensive rows into a second movable panel.

## How it looks

Layouts auto-fit to enabled stats, drag panels anywhere, no awkward gaps when
toggling columns. Top: **Flat** (default secondary stats) and **Rating + Percentage**
(both columns side by side). Middle: **With Defensives** (Dodge / Parry / Block /
Brewmaster Stagger / Armor damage reduction) and **Repair Cost at Vendor** (vendor-format coin
string with inline gold / silver / copper icons). Bottom: **Split Mode** —
two independently draggable panels whose side-panel contents can be customized
from Character / Offensive / Tertiary / Defensive / Item Level / Durability / Repair.

![StatsPro display modes — flat, rating + percentage, with defensives, repair cost at vendor, and split mode](screenshots/display-modes.png)

## Archon target tooltips

Hover any secondary stat row to see how your current rating compares to generated
Archon targets for your active spec.

- Choose **Mythic+** or **Raid** targets in `/ss` → **Layout** → **Value Display** → **Tooltip Targets**
- See **Target**, **Current**, **Missing / Over / Matched**, approximate percentage impact, and snapshot date
- Current values can inherit your stat colors when **Match Value Color to Stat** is enabled
- Data ships with the addon — no web scraping, network calls, or external API access in game
- Snapshot coverage includes all 40 current Retail specs, including Demon Hunter Devourer

## Why StatsPro feels different

- **Reads at a glance** — labels and values stay aligned whether you show rating,
  percentage, or both.
- **Adapts to your spec** — main stat and Archon target hovers follow your active
  spec without per-character setup.
- **More than secondary stats** — tertiaries, defensives, durability, item level,
  and vendor-format repair cost can live in the same HUD.
- **M+ and Raid target context** — compare your current rating to generated Archon
  targets without any in-game network calls.
- **Built for Midnight (12.x)** — guarded stat reads and modern tooltip APIs keep
  the HUD stable where older stat addons can break.

## Built for Midnight (12.x)

Blizzard quietly turned many stat-API returns (`GetCombatRating`, `UnitArmor`, even
`FontString:GetStringWidth`) into "secret values" in modern Retail, and the
protection has only tightened in Midnight (12.x). Read them naively in combat
and you get `[secret]` placeholders in the UI, or — worse — silently leak taint
into action bars, macros, and other addons.

StatsPro defends against this end-to-end:

- Stat reads that can return secret values are guarded with `pcall + issecretvalue` before display
- FontString widths are cached when non-secret, so the auto-fit layout stays stable
  mid-pull instead of collapsing to zero
- Repair cost uses the modern `C_TooltipInfo.GetInventoryItem` API (the legacy
  `GameTooltip:SetInventoryItem` returns the cost as a secret value in 12.x — a lot
  of older HUD-style addons broke quietly because of this)

If you're not sure whether your current stat addon is Midnight-safe, run a heavy
pull and check whether the numbers stay correct throughout the fight.

## Localization

Stat labels render in your WoW client's language by default — no setup required.
Curated short-form translations across all current WoW addon locales keep the HUD
compact and readable, including the same `rating | percentage`, defensive stat,
item level, durability, and repair rows shown in game:

![StatsPro localization preview — live HUD label examples with rating and percentage values, defensives, item level, durability, and coin-style repair cost across current WoW addon locales](screenshots/localization.png)

To pick a different language for stat labels, open `/ss` → **Appearance**
tab → **Localization** → use the **Language** dropdown. "Auto" follows your
WoW client locale. To change how compact the labels look, open `/ss` →
**Layout** tab → **Value Display** → **Label Style** and choose **Full**,
**Short**, or **Hidden**. These settings persist across `/reload` and across
all characters on the account. The settings window, target hovers, snapshot
month names, and normal slash-command confirmations update with the selected
output language.

The in-game AddOn list (Esc → Options → AddOns) also shows StatsPro's
description in your client language — a localized one-liner per `## Notes-<locale>`
TOC field is shipped for every non-English WoW addon locale.

If a label reads oddly to you as a native speaker, please open an issue with the
suggested correction — single-row fixes ship in the next patch.

## Slash commands

| Command | Action |
|---|---|
| `/ss` or `/statspro` | Open settings window |
| `/ss show` | Show stats panel |
| `/ss hide` | Hide stats panel |
| `/ss toggle` | Toggle visibility |
| `/ss reset` | Reset all settings to defaults (without opening the window) |
| `/ss debug` | Dump runtime state to chat (for bug reports) |
| `/ss help` | List commands in chat |

**Tip:** right-click anywhere on the stats panel also opens settings — same as `/ss`. To bind a key for toggling visibility, create a macro running `/ss toggle` and bind it from Esc → Options → Keybindings → Macros.

> Note: many users add `/ss` as a screenshot macro. If you have one, use the
> `/statspro` alias instead — it's an equivalent built-in command.

## Installation

**CurseForge:** [www.curseforge.com/wow/addons/statspro](https://www.curseforge.com/wow/addons/statspro)
— install via the CurseForge App or WowUp.

**Manual:** download the latest zip from the
[Releases page](https://github.com/Antrakt92/StatsPro/releases/latest), extract the
`StatsPro` folder into `World of Warcraft\_retail_\Interface\AddOns\`.

## Configuration

Type `/ss` or click the StatsPro entry in the Blizzard AddOns settings panel to
open the configuration window. Three tabs (`Stats | Layout | Appearance`) cover
everything:

![StatsPro settings — Stats, Layout, and Appearance tabs stacked vertically](screenshots/settings-tabs.png)

| Tab | What lives here |
|---|---|
| **Stats** | Character rows (Show Main Stat, Stamina), Offensive, Tertiary, Defensive, and Gear toggles, including Item Level, with inline color swatches |
| **Layout** | Visibility / Lock, Display Mode, **Side Panel Contains** routing for Split mode, **Value Display** controls (Tooltip Targets, Show Rating / Show Percentage / Label Style / Match Value Color to Stat), Scale, Refresh Rate |
| **Appearance** | Typography (Font / Font Size / Text Opacity), Readability (Text Outline / Panel Background), Localization (Language picker + font-coverage warning) |

## Compatibility

- **WoW Retail Midnight** — Interface `120005, 120007`
- Classic / TBC / MoP Classic — not supported (Retail-only at this time)

## Local checks

For addon code changes, run the Lua syntax, smoke, luacheck, and static
diagnostics wrapper from the repository root:

```powershell
.\scripts\check-lua.ps1
```

It uses `luac5.1` for Lua 5.1 syntax, `lua5.1` for the pure-Lua smoke harness,
`luacheck` with the repository's `.luacheckrc`, and `lua-language-server` with
the repository's `.luarc.json` to catch accidental globals and other
warning-level Lua diagnostics without linting vendored libraries.

On a fresh Windows machine, bootstrap the local check tools with:

```powershell
.\scripts\install-check-tools.ps1 -Install
```

## Architecture (contributors / forks)

Core addon logic lives in [`StatsPro.lua`](StatsPro.lua):

- **`Panel:SetTextSafe`** — three-FontString rendering (label / rating / value), each
  with its own `JustifyH` for column alignment, plus two more for the dedicated
  repair row (label + coin). Caches non-secret widths per render to survive in-combat
  measurement taint.
- **`FmtRatingPct` / `FmtPctOnly` / `RouteValueOnly`** — column-routing helpers.
  Dual-column mode = both display toggles on; otherwise everything stacks in the
  rating column. `IsDualColMode()` is the single source of truth for that decision.
- **`UpdateStats`** — drives the per-frame OnUpdate, builds logical render blocks
  (Character / Offensive / Tertiary / Defensive / Item Level / Durability / Repair),
  routes them by display mode, and gates value-column joining on `IsDualColMode()`.
- **`LABELS_BY_LOCALE` + `L()` + `GetStyledLabelText()` + `FormatLabel()` + `PushLocalizedLabel`** — i18n
  and label-presentation layer. One table indexed by locale; `L()` resolves the
  active locale, `GetStyledLabelText()` applies the `Full / Short / Hidden`
  label-style rule with UTF-8-safe short labels, and `FormatLabel()` composes
  that with row color in a single call. `PushLocalizedLabel` registers
  settings-UI setter closures so labels update live when the user picks a new
  locale via the Language dropdown — no `/reload` required. Identity-fast-path
  on enUS (no allocation, no table read).
- **`MigrateDB`** — DB schema versioning. Bump `CURRENT_DB_VERSION` and add a
  conditional `vN-1 → vN` clause when changing a default value, so existing users
  on the old default upgrade automatically while explicit user choices are preserved.

The repository's [`CHANGELOG.md`](CHANGELOG.md) documents what shipped per version
and why. Tricky 12.x retail API behavior (secret-value handling, FontString taint,
layout ordering quirks) is annotated as `WHY:` / `WARNING:` comments at the
relevant call sites.

## Bug reports / feature requests

Open an issue on [GitHub Issues](https://github.com/Antrakt92/StatsPro/issues).
Helpful to include: WoW client version, addon version (visible in the settings
window header), exact reproduction steps, and a screenshot if the issue is visual.

## Support

StatsPro is free and MIT-licensed. If it saves you time and you'd like to support
continued addon work:

- **Ko-fi** — [ko-fi.com/antrakt92](https://ko-fi.com/antrakt92) (one-time or recurring)
- **GitHub Sponsors** — the **❤ Sponsor** button at the top of this repo

Bug reports and PRs remain the highest-leverage way to help — open an
[issue](https://github.com/Antrakt92/StatsPro/issues) any time.

## Acknowledgements

- **[@tflo](https://github.com/tflo)** — auto main stat, text opacity, item level,
  stamina, right-click-to-settings, label style modes, Stagger, Block visibility,
  and gear grouping feedback (issues #1-#4).
- **[TaylorSay](https://www.curseforge.com/members/taylorsay)** — author of the
  original [SwiftStats](https://www.curseforge.com/wow/addons/swiftstats) addon
  (MIT), the project that inspired StatsPro and from which the initial defaults
  and color scheme are derived.
- **[LibSharedMedia-3.0](https://www.curseforge.com/wow/addons/libsharedmedia-3-0)** — font selection support.

## License

[MIT](LICENSE). Original SwiftStats portions (boilerplate, color defaults, basic
stat list) © TaylorSay; all StatsPro extensions © Antrakt. See [`LICENSE`](LICENSE)
for the full text. Bundled runtime libraries keep their upstream licenses; see
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
