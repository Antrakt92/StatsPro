# Contributing to StatsPro

Bug reports, translation corrections, and focused pull requests are welcome.
Please keep changes compatible with World of Warcraft Retail and Lua 5.1.

## Local verification

From the repository root, run:

```powershell
.\scripts\check-lua.ps1 -EnforceToolLocks
```

The wrapper runs Lua 5.1 syntax checks, the pure-Lua smoke harness, luacheck,
and Lua Language Server diagnostics. On a fresh Windows machine, install the
pinned local tools with:

```powershell
.\scripts\install-check-tools.ps1 -Install -EnforceToolLocks
```

For user-visible changes, also test in the Retail client after `/reload`.
Include screenshots for layout, Settings, font, color, or localization changes.

## Architecture guide

Most runtime code lives in [`StatsPro.lua`](StatsPro.lua). Important boundaries:

- `Panel:SetTextSafe` renders aligned label, rating, and percentage columns,
  with dedicated repair-row strings and clean measurement caches.
- `FmtRatingPct`, `FmtPctOnly`, and `RouteValueOnly` route display values without
  leaving empty columns when a user changes value-display options.
- `UpdateStats` builds logical Character, Offensive, Tertiary, Defensive,
  Item Level, Durability, and Repair blocks before routing them to panels.
- `LABELS_BY_LOCALE`, `L`, and the label-formatting helpers provide live
  localization and UTF-8-safe label styles.
- `MigrateDB` owns SavedVariables schema upgrades. Changes to defaults need a
  migration that preserves explicit user choices.
- Profile settings and account settings are intentionally separate. Language
  and refresh rate are account-wide; HUD content and presentation are profile-scoped.

Retail 12.x can return restricted values from stat, unit, tooltip, cooldown, and
measurement APIs. Only clean finite values may drive comparisons, visibility,
layout arithmetic, or persistent caches. Display-only paths may have narrower
rules. Follow the guarded patterns already used by adjacent code.

## Change scope

- Keep one behavior change and its regression coverage together.
- Update every affected locale when adding or changing user-visible strings.
- Keep marketplace descriptions and screenshots synchronized with the public UI.
- Do not commit local workspace notes, private plans, credentials, or generated
  release archives.

See [`CHANGELOG.md`](CHANGELOG.md) for shipped behavior and
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) for bundled dependency provenance.
