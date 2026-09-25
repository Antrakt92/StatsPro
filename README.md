<p align="center">
  <img src="screenshots/logo.png" alt="StatsPro logo" width="112">
</p>

<h1 align="center">StatsPro</h1>

<p align="center">
  Keep your character stats on screen without opening the Character panel.
</p>

<p align="center">
  <a href="https://www.curseforge.com/wow/addons/statspro"><strong>Install on CurseForge</strong></a>
  · <a href="https://addons.wago.io/addons/statspro">Wago Addons</a>
  · <a href="https://www.wowinterface.com/downloads/info27130-StatsPro.html">WoWInterface</a>
  · <a href="https://github.com/Antrakt92/StatsPro/releases/latest">GitHub Releases</a>
</p>

<p align="center">
  <a href="https://github.com/Antrakt92/StatsPro/releases/latest"><img src="https://img.shields.io/github/v/release/Antrakt92/StatsPro?label=release&color=brightgreen" alt="Latest release"></a>
  <a href="https://www.curseforge.com/wow/addons/statspro"><img src="https://img.shields.io/curseforge/dt/1525100?label=downloads&color=orange" alt="CurseForge downloads"></a>
  <img src="https://img.shields.io/badge/WoW-Retail%2012.x-blueviolet" alt="WoW Retail 12.x">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Antrakt92/StatsPro" alt="MIT License"></a>
</p>

StatsPro is a customizable stats and gear HUD for **World of Warcraft Retail:
Midnight**. Show Crit, Haste, Mastery and Versatility beside your action bars,
add defensive stats, or keep item level, durability and repair cost in a separate
panel. Use different settings for each specialization or one setup across all
your characters. Hover secondary stats for bundled Archon references.

![StatsPro showing character stats beside the action bars during normal play](screenshots/09-flat-in-game.jpg)

*Retained older in-game capture; fresh screenshots pending.*

## Getting started

1. Install and enable StatsPro using one of the links above.
2. On a fresh install, preview **Compact**, **DPS** or **Tank** in Quick Setup,
   then click **Use this setup**.
3. Drag the unlocked panels into place, then lock them in Settings.

Type `/ss` or `/statspro` to open Settings. Outside combat, you can also
right-click the HUD. To choose another setup later, expand **Quick Setup**
at the top of the **Stats** tab or adjust individual rows yourself.

For a manual install, download the addon archive from
[GitHub Releases](https://github.com/Antrakt92/StatsPro/releases/latest) and extract
the `StatsPro` folder into `World of Warcraft\_retail_\Interface\AddOns\`.

### Quick Setup

| Setup | What it shows |
|---|---|
| **Compact** | The four secondary stats |
| **DPS** | Secondary and tertiary stats, item level, durability and repair cost |
| **Tank** | The DPS setup with defensive stats added |

Click a setup to preview it before applying. Closing the first-login panel or
pressing Escape keeps your current settings; it will not reopen at the next login.
Quick Setup changes rows and layout while keeping your font, colors, scale and
panel positions. It applies to the settings currently in use, including an active
account-wide setup.

## Stats and gear rows

| Area | Available rows |
|---|---|
| **Secondary stats** | Crit, Haste, Mastery, Versatility |
| **Character** | Main stat, selected automatically for your specialization; Stamina |
| **Tertiary and movement** | Leech, Avoidance, ground movement speed |
| **Defensive** | Dodge, Parry, Block, Brewmaster Stagger, Armor damage reduction |
| **Gear** | Equipped and overall item level, durability, lowest-durability slot, repair cost |

Every row is optional. Rated stats can show rating, percentage or both. Defensive
rows depend on your class and specialization. Repair cost uses gold, silver and
copper icons.

Movement shows your current ground run speed, including slows, boosts and ground
mounts. Normal speed is about 100%; the value remains meaningful while stationary.

## Flexible layouts

- **Flat:** a simple list of your chosen rows.
- **Sectioned:** rows grouped under category headings.
- **Split:** two independently movable panels, with selected groups on each.

Panels resize to fit their rows, with rating and percentage columns aligned.
Fresh and reset panels have a transparent background; add a darker backing in
**Appearance** for more contrast. When unlocked, temporary outlines and drag
handles help you position them.

## Profiles and appearance

### One setup for all your characters

StatsPro remembers settings for each character and specialization automatically.
For the same HUD on every alt, open **Profiles & sharing...**, select the setup
you want and choose **Use these settings everywhere...**. This creates an
account-wide copy for all existing and future characters and specializations.

**Return to specialization settings...** restores your previous assignments.
The account-wide setup stays saved, so **Use account-wide settings...** can
activate it again later.

### Copy or share a setup

In **Profiles & sharing...**, copy **Stats**, **Layout**, **Appearance** or all
settings from another specialization. You can also share one set of settings
between specializations. **Make this specialization independent...** gives it
its own copy again.

Use **Export / import profile...** to share a profile string with another player.
Imports show a preview and let you choose which sections to use before applying.

<details>
<summary>Import behavior and saved-settings recovery</summary>

Exported strings start with `SPP1:`. The import preview shows the profile name,
format version and included sections. Unchecked sections inherit your current
settings. Imported sections create a new independent profile for the selected
specialization, or a new account-wide copy when that mode is active.

Existing profiles, other specialization assignments, language and refresh rate
are preserved. To display an imported custom font, it must also be installed on
the receiving client; otherwise StatsPro uses a fallback font.

To recover a setup replaced by an import, choose **Advanced → Recover saved
settings...** in the profile tools. Select a saved setup, review the summary and
confirm. Recovery creates a separate copy for the selected specialization, or a
new account-wide copy. It keeps the saved source, replaced setup and other
specialization assignments. Recovery is available only when an unused saved
setup exists.

Other **Advanced** tools let you reset current settings, forget an offline
character, choose Tank, Healer and Damage starting settings for new
specializations, manage the saved account-wide setup or delete unused profiles.

</details>

### Appearance themes

Adjust fonts, colors and scale yourself, or expand **Appearance Presets** to
preview **Default**, **Classic**, **Clean Dark**, **Midnight**, **Monochrome** or
**High Contrast**. Choose **Apply** to keep a theme or **Cancel preview** to
return to your saved appearance.

Appearance themes change presentation while keeping your chosen stats, layout,
scale and panel positions. They apply to the current specialization's settings
or the active account-wide setup. Settings remembers your tab and scroll
position during the game session.

<details>
<summary>Settings screenshots — earlier interface version</summary>

These screenshots show an earlier version of Settings. Some controls and labels
have changed; use the instructions above for current profile and Quick Setup tools.

![Stats controls in an earlier version of Settings](screenshots/settings-overview-v1.10.2.jpg)

![Layout controls in an earlier version of Settings](screenshots/layout-settings-v1.10.2.jpg)

![Appearance presets in an earlier version of Settings](screenshots/appearance-presets-v1.10.2.jpg)

</details>

## Archon reference snapshots

Hover Crit, Haste, Mastery or Versatility to see an **Archon reference rating for
your specialization**, the snapshot date and a comparison with your current
rating when available.

Choose from the available datasets in Settings:

- **Mythic+:** the current key bracket or High Keys, across all dungeons.
- **Raid:** Normal, Heroic or Mythic, across all bosses.

The tooltip shows **Missing**, **Over** or **Matched** against the reference.
If WoW restricts the comparison during combat, cached values are marked
**Last known**. When no safe comparison is available, the reference remains
visible on its own.

**These are reference values, not stat caps or personalized gearing
recommendations.** Use simulations to evaluate upgrades for your own character.

Snapshots cover all current Retail specializations and ship inside the addon;
they are not fetched live. A dataset that Archon is not publishing stays out of
the selector until a later addon snapshot includes it. Mythic+ current-affix
routes use Archon's rolling 14-day sample. No companion app is required.

## Localization

The HUD, Settings, profile tools and tooltips support all current Retail client
languages. Leave the language on **Auto** to follow your WoW client, or select
another language in Settings.

Language and refresh rate are account-wide. HUD appearance and visible rows
follow your current specialization's settings or the active account-wide setup.

<details>
<summary>View the language preview</summary>

![StatsPro localization preview across current Retail addon locales](screenshots/localization.png)

</details>

## Commands

| Command | Action |
|---|---|
| `/ss` or `/statspro` | Open Settings |
| `/ss show` | Show the HUD |
| `/ss hide` | Hide the HUD |
| `/ss toggle` | Toggle HUD visibility |
| `/ss help` | List available commands |
| `/ss debug` | Print support information |
| `/statspro import` | Import compatible SwiftStats settings into a new specialization or account-wide profile |
| `/ss reset` | Confirm and reset the settings currently in use; the warning identifies affected specializations or account-wide scope |
| `/ss wipe` or `/ss reset all` | Confirm and reset all profiles, assignments, role templates, account settings and saved positions |

All commands also work with `/statspro`. Use it if `/ss` conflicts with another
command. To control visibility with a keybind, put `/ss toggle` in a macro and
bind it to a key.

## Moving from SwiftStats

StatsPro carries over compatible SwiftStats settings when both addons are loaded
on your first StatsPro login. If StatsPro has already started:

1. Enable SwiftStats and StatsPro together.
2. Log in and run `/reload`.
3. Run `/statspro import` and confirm.
4. Check the new `SwiftStats Import` profile, then disable or uninstall SwiftStats.

The import creates a new profile for the current character and specialization,
or a new account-wide copy when that mode is active. Existing StatsPro profiles,
other specialization assignments, account settings and the original SwiftStats
settings are preserved.

## Compatibility

**Supported: World of Warcraft Retail — Midnight 12.1.0 and 12.1.5 PTR.** Classic and other
non-Retail clients are not supported.

## Help, feedback, and development

Open a [GitHub issue](https://github.com/Antrakt92/StatsPro/issues) for bugs,
translation corrections or feature requests. Include your WoW build, StatsPro
version, class/spec and steps to reproduce the problem. Add a screenshot for
visual issues. For combat-stat or Archon-tooltip issues, include the output of
`/statspro debug live` from the affected state.

See [`CHANGELOG.md`](CHANGELOG.md) for release history and
[`CONTRIBUTING.md`](CONTRIBUTING.md) for developer setup and verification.

StatsPro is free and MIT-licensed. Optional support is available through
[Ko-fi](https://ko-fi.com/antrakt92) or
[GitHub Sponsors](https://github.com/sponsors/Antrakt92).

## Acknowledgements

- **[@tflo](https://github.com/tflo)** — product and UX feedback across stats,
  layout, settings, labels and gear presentation.
- **[TaylorSay](https://www.curseforge.com/members/taylorsay)** — author of
  [SwiftStats](https://www.curseforge.com/wow/addons/swiftstats), the MIT-licensed
  project that originally inspired StatsPro.
- **[LibSharedMedia-3.0](https://www.curseforge.com/wow/addons/libsharedmedia-3-0)** —
  font selection support.

## License

[MIT](LICENSE). Original SwiftStats portions are © TaylorSay; StatsPro extensions
are © Antrakt. Bundled libraries retain their upstream licenses. Exact notices,
versions, provenance and hashes are listed in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
