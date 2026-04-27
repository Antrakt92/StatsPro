-- StatsPro.lua
-- Inspired by SwiftStats by TaylorSay (MIT). ~9% of upstream code remains verbatim
-- (boilerplate, color defaults, basic stat list); the rest is original work. See
-- LICENSE for full attribution.
local _, addon = ...

--[[ ============================================================
    1. CONSTANTS
============================================================ ]]
local CURRENT_DB_VERSION = 3

local DURABILITY_SLOT_MIN = 1
local DURABILITY_SLOT_MAX = 19
-- WHY: slot 4 = shirt, slot 18 = deprecated ranged. Slot 19 (tabard) self-filters via max>0.
local DURABILITY_SKIP_SLOTS = { [4] = true, [18] = true }

local DURABILITY_GREEN_THRESHOLD  = 60
local DURABILITY_YELLOW_THRESHOLD = 30

-- DEFENSIVE_HEADER moved into a function (DefensiveHeader) in section 7 so it picks up
-- the locale-aware divider word from L("Defensive") and reacts to toggle flips.

--[[ ============================================================
    2. LIBRARIES + API SHIMS
============================================================ ]]
-- LibSharedMedia-3.0 (soft dependency - gracefully falls back if not loaded)
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- WHY: issecretvalue is 12.0+ retail; shim falsy on older clients so addon doesn't hard-error.
local issecretvalue = _G.issecretvalue or function() return false end

-- WHY single source of truth: Version comes from the TOC `## Version:` line, which
-- BigWigs Packager substitutes from the git tag at release build time (`@project-version@`
-- → e.g. `1.0.1`). Reading via GetAddOnMetadata means every release auto-syncs the
-- in-game settings title without a code edit. Local dev (running from source) sees the
-- literal `@project-version@` token from the unsubstituted TOC — fall back to a
-- hand-maintained constant so the title still reads e.g. `v1.0.3-dev` instead of `vdev`.
-- WARNING: bump CURRENT_RELEASE on every `git tag v*` so dev builds reflect the working base.
local CURRENT_RELEASE = "1.0.7"
local ADDON_VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)("StatsPro", "Version") or "?"
if ADDON_VERSION:find("project%-version") then ADDON_VERSION = CURRENT_RELEASE .. "-dev" end

--[[ ============================================================
    3. DEFAULTS
============================================================ ]]
local defaults = {
    -- Position / appearance
    point = "CENTER",
    relativePoint = "CENTER",
    xOfs = 0,
    yOfs = 0,
    scale = 1.0,
    fontSize = 14,
    font = "Fonts\\FRIZQT__.TTF",
    textAlign = "RIGHT",
    updateInterval = 0.5,
    isVisible = true,
    isLocked = false,

    -- Display mode: "flat" | "sectioned" | "split"
    displayMode = "flat",

    -- Localization: when true, swap compact English stat labels for hand-curated short-form
    -- equivalents in the user's WoW client locale (e.g. "Crit" → "Крит" on ruRU, "暴击" on
    -- zhCN). Default true: non-English clients see localized labels by default, matching
    -- the rest of their localized WoW UI. Opt out via Display tab → Localization checkbox.
    -- enUS clients see no visible difference (LABELS_BY_LOCALE.enUS is the identity map).
    useLocalizedLabels = true,

    -- Defensive panel position
    defensive_point = "CENTER",
    defensive_relativePoint = "CENTER",
    defensive_xOfs = 0,
    defensive_yOfs = -100,

    -- Display formatting
    showRating = false,
    showPercentage = true,
    matchValueColorToStat = false,

    -- Tertiary stats
    showTertiary = false,
    hideZeroTertiary = true,
    showLeech = true,
    showAvoidance = true,
    showSpeed = true,

    -- Primary stats
    showStrength = false,
    showAgility = false,
    showIntellect = false,

    -- Defensive stats
    showDefensive = false,
    hideZeroDefensive = true,
    showDodge = true,
    showParry = true,
    showBlock = true,
    showArmor = true,

    -- Offensive stats (preserve current always-shown behavior with default true)
    showOffensive = true,
    hideZeroOffensive = false,  -- combat ratings rarely 0; opt-in only (Vers may legit hit 0)
    showCrit = true,
    showHaste = true,
    showMastery = true,
    showVersatility = true,

    -- Durability
    showDurability = false,
    showRepairCost = true,
    useAutoColorDurability = true,
    useWorstDurability = false,  -- default: average (matches vendor display); ON = show worst slot

    colors = {
        crit        = { r = 1,    g = 0,    b = 0 },
        haste       = { r = 0,    g = 0.5,  b = 1 },
        mastery     = { r = 0,    g = 1,    b = 0 },
        versatility = { r = 1,    g = 1,    b = 0 },
        rating      = { r = 0.7,  g = 0.7,  b = 0.7 },
        percentage  = { r = 1,    g = 1,    b = 1 },
        leech       = { r = 0.8,  g = 0.2,  b = 0.8 },
        avoidance   = { r = 0.2,  g = 0.8,  b = 0.8 },
        speed       = { r = 1,    g = 0.65, b = 0 },
        primary     = { r = 1,    g = 0.84, b = 0 },
        -- Defensive colors
        dodge       = { r = 0.4,  g = 0.7,  b = 1 },
        parry       = { r = 1,    g = 0.4,  b = 0.2 },
        block       = { r = 0.7,  g = 0.5,  b = 0.3 },
        armor       = { r = 0.6,  g = 0.6,  b = 0.7 },
        durability  = { r = 1,    g = 1,    b = 1 },
    },
}

--[[ ============================================================
    4. STAT DEFINITION TABLES (data-driven; UpdateStats iterates these)
============================================================ ]]
local OFFENSIVE_STATS = {
    { label = "Crit",    api = GetCritChance,    ratingCR = CR_CRIT_MELEE,  colorKey = "crit",    showKey = "showCrit"    },
    { label = "Haste",   api = GetHaste,         ratingCR = CR_HASTE_MELEE, colorKey = "haste",   showKey = "showHaste"   },
    { label = "Mastery", api = GetMasteryEffect, ratingCR = CR_MASTERY,     colorKey = "mastery", showKey = "showMastery" },
    -- versatility handled specially (dual-source: rating + flat); gated by showVersatility
}

local DEFENSIVE_STATS = {
    { label = "Dodge", api = GetDodgeChance, colorKey = "dodge", showKey = "showDodge" },
    { label = "Parry", api = GetParryChance, colorKey = "parry", showKey = "showParry" },
    { label = "Block", api = GetBlockChance, colorKey = "block", showKey = "showBlock" },
    -- Armor & DR handled specially: armor = absolute number, DR = cached arithmetic
}

local PRIMARY_STATS = {
    { label = "Strength",  unitStatId = 1, showKey = "showStrength"  },
    { label = "Agility",   unitStatId = 2, showKey = "showAgility"   },
    { label = "Intellect", unitStatId = 4, showKey = "showIntellect" },
}

local TERTIARY_STATS = {
    { label = "Leech",     api = GetLifesteal, ratingCR = CR_LIFESTEAL, colorKey = "leech",     showKey = "showLeech"     },
    { label = "Avoidance", api = GetAvoidance, ratingCR = CR_AVOIDANCE, colorKey = "avoidance", showKey = "showAvoidance" },
    -- speed handled specially (yps→% via GetUnitSpeed)
}

--[[ ============================================================
    5. CACHE KEY TABLES (single source of truth for CacheSettings loops)
============================================================ ]]
local CACHED_BOOL_KEYS = {
    "isLocked", "isVisible",
    "showRating", "showPercentage", "matchValueColorToStat",
    "showOffensive", "hideZeroOffensive",
    "showCrit", "showHaste", "showMastery", "showVersatility",
    "showTertiary", "hideZeroTertiary", "showLeech", "showAvoidance", "showSpeed",
    "showStrength", "showAgility", "showIntellect",
    -- Defensive & durability:
    "showDefensive", "hideZeroDefensive",
    "showDodge", "showParry", "showBlock", "showArmor",
    "showDurability", "showRepairCost", "useAutoColorDurability", "useWorstDurability",
    -- Localization toggle (gated by HAS_LOCALIZATION in Display tab — checkbox hidden on enUS):
    "useLocalizedLabels",
}

-- WHY: COLOR_KEYS removed - CacheSettings now iterates pairs(defaults.colors) directly
-- since defaults table IS the canonical color list; no separate string table needed.

--[[ ============================================================
    6. SAVED VARIABLES + RUNTIME STATE
============================================================ ]]
StatsProDB = StatsProDB or {}

-- WHY: one-time migration for users coming from the SwiftStatsLocal fork. Copies the
-- entire saved-variables table on first load if the new DB is empty AND the old global
-- happens to be present (only true while both addons are simultaneously enabled). After
-- migration the old DB is left untouched — disable SwiftStatsLocal in the addon list
-- to remove its panels. Safe to ship to new users: SwiftStatsLocalDB simply doesn't
-- exist for them, so the block is a no-op.
if next(StatsProDB) == nil and _G.SwiftStatsLocalDB and next(_G.SwiftStatsLocalDB) ~= nil then
    -- WHY CopyTable: shallow copy would alias sub-tables (e.g. .colors) between the two
    -- DBs. Color-picker edits in either addon while both are simultaneously enabled
    -- would silently mutate both. Deep copy breaks the aliasing.
    for k, v in pairs(_G.SwiftStatsLocalDB) do
        StatsProDB[k] = (type(v) == "table") and CopyTable(v) or v
    end
end

local cached = {
    colorStrings = {},
    -- versatility cached out-of-combat (existing)
    versTotal = 0,
    versTotalRating = 0,
    -- Defensive cached out-of-combat
    armorDR = 0,
    durabilityValue = 100,  -- holds avg or min depending on cached.useWorstDurability
    repairCost = 0,         -- live repair cost in copper (sum from per-slot tooltip scan)
    -- WARNING: GetUnitSpeed returns secret values in combat → math.max taints. Cache OOC.
    speedPct = 0,
    displayMode = "flat",
    updateInterval = 0.5,
}

-- Dirty flag for event-driven cache refresh (durability scan is per-19-slot, not free)
local durabilityDirty = true
-- Init guard: UpdateStats must not run before CacheSettings populates cached.colorStrings
local isLoaded = false

--[[ ============================================================
    7. HELPERS
============================================================ ]]

-- Compact short-form stat labels, hand-curated per locale to match StatsPro's
-- 4-7-char aesthetic across every client language. Translation philosophy:
-- preserve the same visual weight as the English "Crit" / "Vers" — abbreviated
-- where the natural translation is long, full where it's already short. Aim for
-- ≥4 chars when the language supports it (3-char abbreviations like "Par" or
-- "Cel" read as truncations rather than words and look unfinished).
--
-- Ships with all 11 retail WoW locales:
--   enUS (canonical, identity map)
--   ruRU (Russian native-speaker reviewed by maintainer)
--   zhCN / zhTW (use official WoW Chinese client stat terminology — high confidence)
--   deDE / frFR / esES / esMX / itIT / ptBR / koKR (deeper review pass against
--     each language's WoW client term + community shorthand conventions; native-
--     speaker spot-checks still welcome via GitHub Issues for per-row tweaks).
-- Locales not in this table (any future Blizzard locale, e.g. plPL) fall back
-- to enUS via the `or LABELS_BY_LOCALE.enUS` selector AND the toggle is hidden
-- in the config UI (no dead switch). HAS_LOCALIZATION below is the gate.
--
-- WARNING: keys MUST match exactly the English literals used at the call sites:
--   - def.label values from OFFENSIVE_STATS / DEFENSIVE_STATS / PRIMARY_STATS /
--     TERTIARY_STATS (section 4)
--   - hardcoded literals in special-case branches: "Vers" / "Speed" / "Armor"
--     (additive rows for dual-source stats not in the loop tables)
--   - "Durability" / "Repair" in BuildDurabilityLines
--   - "Defensive" used by DefensiveHeader() for sectioned-mode divider
-- Adding a new key here without updating callers is a no-op; adding a new caller
-- without a key here falls back gracefully to the English literal (`L(k) → k`).
--
-- WARNING: Armor and Defensive must be visually DISTINCT in the same locale.
-- Armor is a stat row label; Defensive is the sectioned-mode divider. Same word
-- for both makes the divider blend into the row beneath it.
local LABELS_BY_LOCALE = {
    enUS = {
        Crit = "Crit",          Haste = "Haste",        Mastery = "Mastery",    Vers = "Vers",
        Dodge = "Dodge",        Parry = "Parry",        Block = "Block",        Armor = "Armor",
        Strength = "Strength",  Agility = "Agility",    Intellect = "Intellect",
        Leech = "Leech",        Avoidance = "Avoidance", Speed = "Speed",
        Durability = "Durability", Repair = "Repair",
        Defensive = "Defensive",
    },

    -- ruRU: Russian. Haste/Speed disambig is structural — WoW client uses "Скорость"
    -- for BOTH stats, so we transliterate Haste as "Хаст" (community shorthand) to free
    -- "Скор" for Speed. Leech uses "Вамп" (вампиризм) over the literal "Кров" because
    -- "Кров…" risks being mis-read as "Кровотечение" (Bleed). All stat rows use 4-char
    -- forms where the language allows; "Сила" / "Блок" / "Крит" are already 4 chars.
    ruRU = {
        Crit = "Крит",          Haste = "Хаст",         Mastery = "Маст",       Vers = "Унив",
        Dodge = "Укл",          Parry = "Пари",         Block = "Блок",         Armor = "Брон",
        Strength = "Сила",      Agility = "Ловк",       Intellect = "Инт",
        Leech = "Вамп",         Avoidance = "Избег",    Speed = "Скор",
        Durability = "Проч",    Repair = "Рем",
        Defensive = "Защита",
    },

    -- deDE: German. Haste="Tempo" matches the WoW German client term; Speed="Lauf"
    -- (run-speed) keeps the Haste/Speed split clear. Vers="Viels" evokes Vielseitigkeit
    -- without colliding with the everyday word "viel" (many/much). Durability="Haltb"
    -- avoids collision with the everyday word "Halt" (stop). Strength="Stär" preserves
    -- the umlaut character of Stärke at 4 chars (single char "Stä" reads truncated).
    deDE = {
        Crit = "Krit",          Haste = "Tempo",        Mastery = "Meist",      Vers = "Viels",
        Dodge = "Ausw",         Parry = "Par",          Block = "Block",        Armor = "Rüst",
        Strength = "Stär",      Agility = "Bew",        Intellect = "Int",
        Leech = "Saug",         Avoidance = "Verm",     Speed = "Lauf",
        Durability = "Haltb",   Repair = "Repar",
        Defensive = "Defensiv",
    },

    -- frFR: French. Hâte (4 chars, accented form) is WoW's official Haste term; Vit
    -- (Vitesse) distinct. Strength="Forc" and Durability="Dura" use 4-char forms so
    -- they don't collide with the everyday words "Fort" / "Dur". Esqu (Esquive) at 4
    -- chars reads more clearly than the truncated 3-char "Esq".
    frFR = {
        Crit = "Crit",          Haste = "Hâte",         Mastery = "Maît",       Vers = "Polyv",
        Dodge = "Esqu",         Parry = "Par",          Block = "Bloc",         Armor = "Arm",
        Strength = "Forc",      Agility = "Agil",       Intellect = "Int",
        Leech = "Vamp",         Avoidance = "Évit",     Speed = "Vit",
        Durability = "Dura",    Repair = "Rép",
        Defensive = "Défense",
    },

    -- esES: Spanish (Spain). WoW Spanish client uses Celeridad / Velocidad for the
    -- Haste/Speed split → Cele / Vel. Leech="Robo" matches "Robo de vida" (life steal),
    -- the WoW Spanish term — closer to client wording than the literal "Suc(ción)".
    -- Most rows use 4-char forms (Esqu / Fuer / Agil) — 3-char abbreviations look
    -- unfinished beside Spanish's typically-longer words.
    esES = {
        Crit = "Crít",          Haste = "Cele",         Mastery = "Maest",      Vers = "Versat",
        Dodge = "Esqu",         Parry = "Par",          Block = "Bloq",         Armor = "Arm",
        Strength = "Fuer",      Agility = "Agil",       Intellect = "Int",
        Leech = "Robo",         Avoidance = "Evit",     Speed = "Vel",
        Durability = "Durab",   Repair = "Rep",
        Defensive = "Defensa",
    },

    -- esMX: Latin American Spanish — stat-term short forms are effectively shared
    -- with esES (no regional split for combat stats). Mirrored 1:1 from esES table.
    esMX = {
        Crit = "Crít",          Haste = "Cele",         Mastery = "Maest",      Vers = "Versat",
        Dodge = "Esqu",         Parry = "Par",          Block = "Bloq",         Armor = "Arm",
        Strength = "Fuer",      Agility = "Agil",       Intellect = "Int",
        Leech = "Robo",         Avoidance = "Evit",     Speed = "Vel",
        Durability = "Durab",   Repair = "Rep",
        Defensive = "Defensa",
    },

    -- itIT: Italian. Cele (Celerità) / Vel (Velocità) Haste/Speed split. Para
    -- (Parata) at 4 chars reads more naturally than "Par"; Armat (Armatura) gives
    -- enough char-count to feel like a word; Forz / Agil keep 4-char rhythm. Ag
    -- (2 chars) was clearly too short — Italian readers wouldn't recognize it.
    itIT = {
        Crit = "Crit",          Haste = "Cele",         Mastery = "Maest",      Vers = "Vers",
        Dodge = "Schiv",        Parry = "Para",         Block = "Bloc",         Armor = "Armat",
        Strength = "Forz",      Agility = "Agil",       Intellect = "Int",
        Leech = "Vamp",         Avoidance = "Evit",     Speed = "Vel",
        Durability = "Durab",   Repair = "Ripa",
        Defensive = "Difesa",
    },

    -- ptBR: Brazilian Portuguese. Cele (Celeridade) / Vel (Velocidade). Forç (with
    -- cedilla, Força) and Agil at 4 chars match Portuguese's prosody better than the
    -- 3-char truncations. Esqu (Esquiva) likewise.
    ptBR = {
        Crit = "Crít",          Haste = "Cele",         Mastery = "Maest",      Vers = "Vers",
        Dodge = "Esqu",         Parry = "Par",          Block = "Bloq",         Armor = "Arm",
        Strength = "Forç",      Agility = "Agil",       Intellect = "Int",
        Leech = "Vamp",         Avoidance = "Evit",     Speed = "Vel",
        Durability = "Durab",   Repair = "Rep",
        Defensive = "Defesa",
    },

    -- koKR: Korean. Parry/Block previously collided — both used 막기-family terms
    -- and Armor/Defensive both rendered as 방어 (a real bug — sectioned-mode header
    -- merged visually with the Armor row beneath it). New split:
    --   Parry = 쳐막 (쳐서 막다, "strike-block" — community shorthand for parry)
    --   Block = 막기 (standard WoW Korean client term for blocking)
    --   Armor = 방어 (matches WoW Korean stat terminology — 방어도)
    --   Defensive = 수비 (defense as category — distinct from 방어 above)
    -- Avoidance = 광피 (community shorthand for 광역 피해 회피, "AoE-damage avoidance")
    -- — uncommon outside dedicated theorycraft contexts but visually distinct from
    -- 회피 (Dodge). Native-speaker review still welcome via GitHub Issues.
    koKR = {
        Crit = "치명",          Haste = "가속",         Mastery = "특화",       Vers = "유연",
        Dodge = "회피",         Parry = "쳐막",         Block = "막기",         Armor = "방어",
        Strength = "힘",        Agility = "민첩",       Intellect = "지능",
        Leech = "흡혈",         Avoidance = "광피",     Speed = "이속",
        Durability = "내구",    Repair = "수리",
        Defensive = "수비",
    },

    -- zhCN: Simplified Chinese. All terms match the official WoW Chinese client
    -- terminology — 2-char widely used in CN WoW community for stat displays.
    -- 躲闪 (Dodge) vs 闪避 (Avoidance) is the standard zhCN split. High confidence.
    zhCN = {
        Crit = "暴击",          Haste = "急速",         Mastery = "精通",       Vers = "全能",
        Dodge = "躲闪",         Parry = "招架",         Block = "格挡",         Armor = "护甲",
        Strength = "力量",      Agility = "敏捷",       Intellect = "智力",
        Leech = "吸血",         Avoidance = "闪避",     Speed = "移速",
        Durability = "耐久",    Repair = "修理",
        Defensive = "防御",
    },

    -- zhTW: Traditional Chinese (Taiwan). Same 2-char convention as zhCN but
    -- Traditional script forms (護甲 vs 护甲, 格擋 vs 格挡, 迴避 vs 闪避).
    -- Matches WoW Taiwan client terminology. High confidence.
    zhTW = {
        Crit = "致命",          Haste = "加速",         Mastery = "精通",       Vers = "全能",
        Dodge = "躲避",         Parry = "招架",         Block = "格擋",         Armor = "護甲",
        Strength = "力量",      Agility = "敏捷",       Intellect = "智力",
        Leech = "汲取",         Avoidance = "迴避",     Speed = "移速",
        Durability = "耐久",    Repair = "修理",
        Defensive = "防禦",
    },
}

-- Locale resolves once at addon load (it doesn't change at runtime). If the user's
-- locale isn't curated, fall back to enUS (identity map) — toggle has no effect
-- visually, and the config UI hides the checkbox to avoid confusion.
local CURRENT_LOCALE = GetLocale()
local LOCALIZED_LABELS = LABELS_BY_LOCALE[CURRENT_LOCALE] or LABELS_BY_LOCALE.enUS
local HAS_LOCALIZATION = (LOCALIZED_LABELS ~= LABELS_BY_LOCALE.enUS)

-- WHY identity-fast-path: when toggle is off (opt-out), this is a no-op direct return.
-- When toggle is on (default), we hit one table read — still O(1), no _G access, no
-- iteration. Both paths are constant-time. `cached` upvalue is captured by reference
-- (the table is declared once at module load and never reassigned, only mutated) so
-- toggle flips reflect immediately.
local function L(englishKey)
    if cached.useLocalizedLabels then
        return LOCALIZED_LABELS[englishKey] or englishKey
    end
    return englishKey
end

-- Replaces nine `string.format("|cff%s%s:|r", color, label)` sites in builder
-- functions. Single point where coloring + localization compose. Future new stat
-- needs one row in LABELS_BY_LOCALE.enUS + one FormatLabel call site, plus a
-- translation row in each shipped non-English locale (4-7 char short form).
local function FormatLabel(colorHex, englishKey)
    return string.format("|cff%s%s:|r", colorHex, L(englishKey))
end

-- Replaces the static `local DEFENSIVE_HEADER = ...` constant. Resolves at use time
-- (not at file load) so toggle flips immediately update the divider on next render.
-- Cheap: one string.format per sectioned-mode UpdateStats (throttled to ~2/s default).
local function DefensiveHeader()
    return string.format("|cff808080— %s —|r", L("Defensive"))
end

-- Read DB value with fallback to defaults (replaces 30+ if-nil patterns)
local function GetDB(key)
    local v = StatsProDB[key]
    if v == nil then return defaults[key] end
    return v
end

-- pcall every stat API so 12.x secret values never touch our Lua logic.
-- Raw returns flow only into string.format, which Blizzard whitelisted for secrets.
local function safeCall(fn, ...)
    local ok, val = pcall(fn, ...)
    if ok then return val end
    return 0
end

-- 12.x: hideZero check on a possibly-secret value.
-- issecretvalue() == in combat → always show (real value is non-zero).
local function shouldShow(val, hideZero)
    if not hideZero then return true end
    if issecretvalue(val) then return true end
    return val ~= 0
end

local function FormatRepairCost(copper)
    -- WHY: Blizzard's GetCoinTextureString embeds gold/silver/copper icons inline,
    -- matching the vendor display exactly. Pass fontHeight explicitly — without it
    -- the helper produces `:0:0` markup which in TWW 12.x sometimes renders icons
    -- at the wrong size or with the digits floating to a separate baseline.
    if GetCoinTextureString then
        return GetCoinTextureString(copper, GetDB("fontSize"))
    end
    return string.format("%dg", math.floor(copper / 10000))
end

local function ComputeDurabilityColor(pct)
    if pct >= DURABILITY_GREEN_THRESHOLD then
        return 0.2, 1, 0.2
    elseif pct >= DURABILITY_YELLOW_THRESHOLD then
        return 1, 0.8, 0.2
    else
        return 1, 0.2, 0.2
    end
end

local function RGBToHex(r, g, b)
    -- WARNING: explicit floor for portability across Lua versions (5.1 tolerates floats; 5.3+ requires int)
    return string.format("%02x%02x%02x",
        math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5))
end

-- WARNING: table.concat rejects secret strings in 12.0; manual .. is allowed.
-- WARNING: do NOT compare elements against "" here — in-combat reads can put secret-
-- tainted strings in `lines`, and `secret_str ~= ""` raises a taint error. All-empty
-- detection lives at call sites (UpdateStats), which can decide from `cached.show*`
-- flags without touching string content.
local function JoinLinesSecretSafe(lines)
    if #lines == 0 then return "" end
    local text = lines[1]
    for i = 2, #lines do
        text = text .. "\n" .. lines[i]
    end
    return text
end

local function PrintMsg(text)
    print("|cff00ff7f[StatsPro]|r " .. text)
end

--[[ ============================================================
    8. CACHE UTILITIES
============================================================ ]]
local function CacheSettings()
    -- Booleans / scalar settings
    for _, k in ipairs(CACHED_BOOL_KEYS) do
        cached[k] = GetDB(k)
    end
    cached.updateInterval = GetDB("updateInterval")
    cached.displayMode = GetDB("displayMode")

    -- Color → hex string lookup. Iterate defaults.colors (single source of truth) to
    -- guarantee non-nil colorStrings for every key — eliminates the need for `or "ffffff"`
    -- fallbacks throughout the render pipeline.
    local userColors = StatsProDB.colors or {}
    for name, defaultColor in pairs(defaults.colors) do
        local c = userColors[name] or defaultColor
        cached.colorStrings[name] = RGBToHex(c.r, c.g, c.b)
    end
end

local function MigrateDB()
    local db = StatsProDB

    -- WHY runs before the version early-return: SwiftStatsLocal migrants whose legacy
    -- DB carried dbVersion=3 (coincidental scheme overlap) would otherwise skip these
    -- loops and never get StatsPro's defaults populated. Idempotent: only fills missing
    -- keys, never clobbers user prefs.
    for k, v in pairs(defaults) do
        if db[k] == nil and type(v) ~= "table" then
            db[k] = v
        end
    end
    if not db.colors then db.colors = {} end
    for k, v in pairs(defaults.colors) do
        if not db.colors[k] then
            db.colors[k] = { r = v.r, g = v.g, b = v.b }
        end
    end

    if db.dbVersion == CURRENT_DB_VERSION then return end

    -- v2 → v3: default textAlign changed "LEFT" → "RIGHT". Upgrade only users still on
    -- the old default; preserve any explicit user choice (CENTER/RIGHT untouched).
    if db.dbVersion == 2 and db.textAlign == "LEFT" then
        db.textAlign = "RIGHT"
    end

    db.dbVersion = CURRENT_DB_VERSION
end

local function RefreshArmorCache()
    if InCombatLockdown() then return end
    -- 12.x retail: UnitArmor returns 4 values; we want effectiveArmor (2nd).
    -- Effective armor accounts for item durability (broken items give reduced armor).
    local ok, _, effectiveArmor = pcall(UnitArmor, "player")
    -- WARNING: pcall succeeds when UnitArmor returns secret values (no Lua error fires
    -- on assignment, only on later comparison). InCombatLockdown lags real combat state
    -- in M+/transitional moments, so OOC-only guard isn't enough — must verify the value
    -- itself isn't tainted before any comparison/arithmetic.
    if not ok or issecretvalue(effectiveArmor) then return end
    if PaperDollFrame_GetArmorReduction and effectiveArmor and effectiveArmor > 0 then
        -- WARNING: PaperDollFrame_GetArmorReduction in 12.x retail returns 0..100 percent
        -- (not 0..1 fraction as some docs claim). Normalize defensively: if return is <=1
        -- treat as fraction and scale, else use as-is. Cap at 100% for sanity.
        local raw = PaperDollFrame_GetArmorReduction(effectiveArmor, UnitEffectiveLevel("player")) or 0
        if raw <= 1 then raw = raw * 100 end
        if raw > 100 then raw = 100 end
        cached.armorDR = raw
    else
        cached.armorDR = 0
    end
end

-- Single-pass scan: computes avg %, worst %, and total repair cost across all slots.
-- WHY: C_TooltipInfo.GetInventoryItem returns a TooltipData table with a .repairCost
-- field. SetInventoryItem's 3rd return became a secret value in 12.x retail (after the
-- 10.0.2 tooltip rewrite) — issecretvalue filtered it out → cost was always 0.
-- TooltipUtil.SurfaceArgs unwraps secure args into plain Lua fields. This is the path
-- modern Blizzard UI and addons (Broker Durability Info, etc.) use.
local function ScanDurabilityAndCost()
    local sum, count, totalCost = 0, 0, 0
    local minPct
    for slot = DURABILITY_SLOT_MIN, DURABILITY_SLOT_MAX do
        if not DURABILITY_SKIP_SLOTS[slot] then
            local cur, max = GetInventoryItemDurability(slot)
            if cur and max and max > 0 then
                local pct = (cur / max) * 100
                sum = sum + pct
                count = count + 1
                if not minPct or pct < minPct then minPct = pct end
                if cur < max and C_TooltipInfo and C_TooltipInfo.GetInventoryItem then
                    local data = C_TooltipInfo.GetInventoryItem("player", slot)
                    if data then
                        if TooltipUtil and TooltipUtil.SurfaceArgs then
                            TooltipUtil.SurfaceArgs(data)
                        end
                        local cost = data.repairCost
                        if cost and not issecretvalue(cost) and cost > 0 then
                            totalCost = totalCost + cost
                        end
                    end
                end
            end
        end
    end
    if count == 0 then return 100, 100, 0 end
    return sum / count, minPct, totalCost
end

local function RefreshDurabilityCache()
    local avg, mn, cost = ScanDurabilityAndCost()
    cached.durabilityValue = cached.useWorstDurability and mn or avg
    cached.repairCost = cost
    durabilityDirty = false
end

--[[ ============================================================
    9. PANEL CLASS
============================================================ ]]
local Panel = {}
Panel.__index = Panel

function Panel:New(globalName, dbKeyPrefix)
    local self = setmetatable({}, Panel)
    self.dbKeyPrefix = dbKeyPrefix or ""
    self.lastLabelText = nil
    self.lastValueText = nil
    self.lastLineCount = -1

    local frame = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
    frame:SetSize(220, 100)
    frame:SetMovable(true)
    frame:EnableMouse(false)
    frame:SetClampedToScreen(true)

    frame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0, 0, 0, 0)
    frame:SetBackdropBorderColor(0, 0, 0, 0)

    -- Three-column rendering: label (RIGHT) | rating (RIGHT) | value (LEFT).
    -- WHY right-justify labels: with left-justified labels in an auto-fit box, short
    -- labels leave huge trailing blank space. Right-justifying lines up all label
    -- right-edges at the same x, so the visual gap to the next column stays constant.
    -- WHY right-justify rating column: rating numbers vary in width (46 vs 843); a
    -- right-justified column lines up their right edges so the "|" separator and
    -- everything after it sits in a clean vertical line down all rows.
    -- WHY left-justify value column: values' left edges line up at a fixed x giving a
    -- CONSTANT visible gap from rating-end (or label-colon when no rating) to value
    -- text regardless of value length. Cost: values' right edges no longer align
    -- vertically. User chose tight constant gap over right-edge alignment.
    local labelText = frame:CreateFontString(nil, "OVERLAY")
    labelText:SetFont(GetDB("font"), GetDB("fontSize"), "OUTLINE")
    labelText:SetJustifyH("RIGHT")
    labelText:SetJustifyV("TOP")
    labelText:SetTextColor(1, 1, 1, 1)
    labelText:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    labelText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)

    -- ratingText sits between label and value. Anchored to the frame's RIGHT edge with
    -- a NEGATIVE x-offset = -(valueW + gap) so its right edge ends just before the value
    -- column starts. Offset is recomputed each SetTextSafe once valueW is measured.
    -- Initial offset 0; first render repositions it.
    local ratingText = frame:CreateFontString(nil, "OVERLAY")
    ratingText:SetFont(GetDB("font"), GetDB("fontSize"), "OUTLINE")
    ratingText:SetJustifyH("RIGHT")
    ratingText:SetJustifyV("TOP")
    ratingText:SetTextColor(1, 1, 1, 1)
    ratingText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    ratingText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

    local valueText = frame:CreateFontString(nil, "OVERLAY")
    valueText:SetFont(GetDB("font"), GetDB("fontSize"), "OUTLINE")
    valueText:SetJustifyH("LEFT")
    valueText:SetJustifyV("TOP")
    valueText:SetTextColor(1, 1, 1, 1)
    valueText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    valueText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

    -- WHY 4th FontString outside the 3-column system: Repair coin string with embedded
    -- gold/silver/copper icons is much wider than typical percent values. Including it
    -- in any of the 3 columns would inflate that column's width and bloat the whole
    -- panel just for one row. Single-line FontString anchored only TOPRIGHT (Y is set
    -- per-render in SetTextSafe to land on the same row as the "Repair:" label in the
    -- label column). Width does NOT participate in auto-fit math — wide coin strings
    -- extend leftward past frame.left if needed.
    -- WARNING: do NOT use a multi-line padded approach (`\n` * N + coin) — inline coin
    -- icons inflate that line's height (`:14:14:2:0|t` yoffset=0 puts texture top above
    -- glyph top), causing cumulative drift vs labelText's pure-text rows.
    local repairText = frame:CreateFontString(nil, "OVERLAY")
    repairText:SetFont(GetDB("font"), GetDB("fontSize"), "OUTLINE")
    repairText:SetJustifyH("RIGHT")
    repairText:SetTextColor(1, 1, 1, 1)
    repairText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)  -- y repositioned per render
    repairText:Hide()

    -- Repair row label — dedicated FontString anchored TOPLEFT below labelText (Y set
    -- per-render in SetTextSafe). Architecturally separate from labelText so the repair
    -- row sits on its own visual row below stats (visual separation), and so coin can't
    -- overlap stat-row content. Width set per-render = stats labelW for column alignment.
    local repairLabelText = frame:CreateFontString(nil, "OVERLAY")
    repairLabelText:SetFont(GetDB("font"), GetDB("fontSize"), "OUTLINE")
    repairLabelText:SetJustifyH("RIGHT")  -- match labelText alignment
    repairLabelText:SetTextColor(1, 1, 1, 1)
    repairLabelText:Hide()  -- shown only when hasRepair

    self.frame = frame
    self.labelText = labelText
    self.ratingText = ratingText
    self.valueText = valueText
    self.repairText = repairText
    self.repairLabelText = repairLabelText

    -- Drag handlers (unsecure frames; not protected in combat lockdown)
    frame:SetScript("OnMouseDown", function(f, button)
        if button == "LeftButton" and not InCombatLockdown() then
            f:StartMoving()
        end
    end)
    frame:SetScript("OnMouseUp", function(f, button)
        if button == "LeftButton" then
            f:StopMovingOrSizing()
            self:SavePosition()
        end
    end)

    return self
end

function Panel:DBKey(suffix)
    if self.dbKeyPrefix == "" then return suffix end
    return self.dbKeyPrefix .. suffix
end

function Panel:SavePosition()
    local point, _, relativePoint, xOfs, yOfs = self.frame:GetPoint()
    -- WHY: if the frame has no anchor yet (called before LoadPosition), GetPoint returns
    -- nil. Writing nil deletes the key — next load would fall back to defaults and the
    -- previously-saved position would be lost.
    if not point then return end
    StatsProDB[self:DBKey("point")] = point
    StatsProDB[self:DBKey("relativePoint")] = relativePoint
    StatsProDB[self:DBKey("xOfs")] = xOfs
    StatsProDB[self:DBKey("yOfs")] = yOfs
end

function Panel:LoadPosition()
    local point         = StatsProDB[self:DBKey("point")]         or defaults[self:DBKey("point")]         or "CENTER"
    local relativePoint = StatsProDB[self:DBKey("relativePoint")] or defaults[self:DBKey("relativePoint")] or "CENTER"
    local xOfs          = StatsProDB[self:DBKey("xOfs")]          or defaults[self:DBKey("xOfs")]          or 0
    local yOfs          = StatsProDB[self:DBKey("yOfs")]          or defaults[self:DBKey("yOfs")]          or 0

    if type(xOfs) ~= "number" or type(yOfs) ~= "number"
        or xOfs < -3000 or xOfs > 3000 or yOfs < -3000 or yOfs > 3000 then
        xOfs, yOfs = 0, 0
    end

    self.frame:ClearAllPoints()
    self.frame:SetPoint(point, UIParent, relativePoint, xOfs, yOfs)
    -- WHY: SetUserPlaced(true) AFTER SetPoint marks the frame as user-positioned at our
    -- chosen anchor. Required in 12.x retail for StartMoving/StopMovingOrSizing to commit
    -- the new position to the frame's internal anchor — without it, GetPoint() can return
    -- the pre-drag anchor on some setups, so SavePosition writes the OLD position back
    -- to SavedVariables and the move appears not to have saved. Order matters: SetPoint
    -- first, then SetUserPlaced — otherwise WoW's layout-cache could overwrite our anchor.
    self.frame:SetUserPlaced(true)
    -- WHY: scale is set via SetAllPanelsScale (single ownership); not duplicated here
end

function Panel:Lock()
    self.frame:EnableMouse(false)
end

function Panel:Unlock()
    if InCombatLockdown() then return end
    self.frame:EnableMouse(true)
end

function Panel:Hide()
    self.frame:Hide()
    self.lastLabelText = nil
    self.lastRatingText = nil
    self.lastValueText = nil
    self.lastRepairText = nil
    self.lastRepairLabelText = nil
    self.repairText:Hide()
    self.repairLabelText:Hide()
    -- WARNING: reset lineCount + hasRepair caches too; otherwise re-show may use stale
    -- height after font change OR fail to re-call SetHeight when hasRepair toggles.
    self.lastLineCount = -1
    self.lastHasRepair = nil
end

function Panel:IsShown()
    return self.frame:IsShown()
end

-- WARNING: GetStringWidth/GetStringHeight on a FontString whose text contains in-combat
-- secret-tainted substrings return secret-tainted numbers. Arithmetic on those errors.
-- Mitigation: keep last non-secret measurement; refresh cache only if current read is
-- non-secret. Used for all 4 measurement points in SetTextSafe (label/rating/value
-- widths + label height for repair Y positioning).
local function MeasuredOrCached(fs, current_cache, method)
    local v = fs[method](fs)
    if v and not issecretvalue(v) then
        return v
    end
    return current_cache
end

-- Hide frame if no lines; otherwise apply text+height.
-- WARNING: in 12.x, label/value strings may be secret-tainted (built from in-combat stat
-- API returns). String comparisons (==, ~=) on secrets error. Use lineCount (always a
-- real number) for empty-check, and SetText every call instead of deduping by text.
-- FontString:SetText accepts secrets — that's how Blizzard's own UI renders them.
function Panel:SetTextSafe(labelStr, ratingStr, valueStr, lineCount, repairStr, repairLabelStr)
    if not labelStr or lineCount == 0 then
        self:Hide()
        return
    end
    if not self:IsShown() then
        self.frame:Show()
    end
    self.labelText:SetText(labelStr)
    self.ratingText:SetText(ratingStr or "")
    self.valueText:SetText(valueStr)
    self.lastLabelText = labelStr
    self.lastRatingText = ratingStr or ""
    self.lastValueText = valueStr

    -- Measure stat columns. WHY 2px gaps: labels RIGHT-justified, rating RIGHT-justified,
    -- value LEFT-justified — at each column boundary one side is justified outward, so
    -- visible gap equals exactly this constant with no per-row variance.
    self.cachedLabelW  = MeasuredOrCached(self.labelText,  self.cachedLabelW,  "GetStringWidth")
    self.cachedRatingW = MeasuredOrCached(self.ratingText, self.cachedRatingW, "GetStringWidth")
    self.cachedValueW  = MeasuredOrCached(self.valueText,  self.cachedValueW,  "GetStringWidth")
    -- labelText height drives Repair-row Y positioning; cache same way as widths.
    self.cachedLabelH  = MeasuredOrCached(self.labelText,  self.cachedLabelH,  "GetStringHeight")

    local hasRating = (self.cachedRatingW or 0) > 0
    local hasValue  = (self.cachedValueW  or 0) > 0
    local rGap = (hasRating and hasValue) and 2 or 0
    local lGap = (hasRating or hasValue) and 2 or 0

    -- Repair row: rendered on a DEDICATED row below the stat rows (NOT as part of the
    -- multi-line labelText). Two FontStrings: repairLabelText for "Repair:" at frame.left
    -- (right-justified to align with stat labels), repairText for the coin at frame.right.
    -- WHY dedicated row: visual separation from stats + the coin width can exceed stat-
    -- column space without overlapping stat content rows.
    local hasRepair = repairStr and repairStr ~= ""
    if hasRepair then
        local lineH = (self.cachedLabelH and lineCount > 0) and (self.cachedLabelH / lineCount) or GetDB("fontSize")
        local repairRowY = -(lineCount * lineH + 1)  -- 1px visible gap separates stats and repair

        -- Repair label: width = stats labelW so "Repair:" right-aligns with other labels.
        self.repairLabelText:ClearAllPoints()
        self.repairLabelText:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, repairRowY)
        self.repairLabelText:SetWidth(self.cachedLabelW or 80)
        self.repairLabelText:SetText(repairLabelStr or "")
        self.repairLabelText:Show()

        -- Coin: anchored to frame.right, same Y as the repair label.
        self.repairText:ClearAllPoints()
        self.repairText:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", 0, repairRowY)
        self.repairText:SetText(repairStr)
        self.repairText:Show()

        -- WHY measure here (not in width math below): coin width depends on Text just set.
        self.cachedRepairW = MeasuredOrCached(self.repairText, self.cachedRepairW, "GetStringWidth")
    else
        self.repairLabelText:Hide()
        self.repairText:Hide()
        -- Reset so a previously-wide coin doesn't keep the panel inflated after the user
        -- disables Show Repair Cost or repair drops to 0g (coin string becomes "").
        self.cachedRepairW = 0
    end
    self.lastRepairText = repairStr or ""
    -- WHY: completes the five-FontString font-change resilience surface (label / rating /
    -- value / repair-coin / repair-label). Without this cache, after a font change the
    -- repairLabelText "Repair:" / "Рем:" / "修理:" stays blank for one frame until next
    -- OnUpdate re-emits. More visible on non-EN clients (the user's language flickers).
    self.lastRepairLabelText = repairLabelStr or ""

    -- Compute width totals.
    local rowsTotal = (self.cachedLabelW or 0) + lGap + (self.cachedRatingW or 0) + rGap + (self.cachedValueW or 0)
    -- WHY repair row participates in width as a SEPARATE max() candidate (not added to
    -- rowsTotal): rowsTotal is the natural width of stat content. Repair row widens the
    -- panel only when its content (label + 2 + coin) exceeds that. Adding repairW into
    -- rowsTotal would inflate rating/value column widths for stat rows too — wide coin
    -- strings would push every percent and rating column rightward on rows that have
    -- nothing to do with repair, breaking the visual contract of column alignment.
    local repairTotal = hasRepair and ((self.cachedLabelW or 0) + 2 + (self.cachedRepairW or 0)) or 0
    local totalW = math.max(rowsTotal, repairTotal, 80)

    -- WHY gated extra: only widen-by-coin causes the offset compensation. Floor 80 (when
    -- stats < 80 and no repair) must NOT trigger shift — pushing ratingText/valueText
    -- left of frame.right unnecessarily creates a different visual bug.
    local extra = (hasRepair and repairTotal > rowsTotal) and (repairTotal - rowsTotal) or 0

    -- ratingText: shift LEFT by `extra` so right edge stays at "stat-content right edge"
    -- (frame.right - extra), not frame.right. Without this, when frame is widened for
    -- coin, ratings track frame.right and create a huge gap between labels and values.
    local rOffset = -(extra + (self.cachedValueW or 0) + rGap)
    self.ratingText:ClearAllPoints()
    self.ratingText:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", rOffset, 0)
    self.ratingText:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", rOffset, 0)

    -- valueText: same shift. Was statically anchored in Panel:New (TOPRIGHT 0,0 = frame.right).
    -- Switch to dynamic per-render so it also pulls back from frame.right when widened.
    local vOffset = -extra
    self.valueText:ClearAllPoints()
    self.valueText:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", vOffset, 0)
    self.valueText:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", vOffset, 0)

    self.frame:SetWidth(totalW)

    -- Frame height: stats rows + (1 row + 1px gap if hasRepair) + 8px padding.
    -- Cache invalidates on either lineCount change or hasRepair flip — both affect height.
    if lineCount ~= self.lastLineCount or hasRepair ~= self.lastHasRepair then
        local fontSize = GetDB("fontSize")
        local h = lineCount * fontSize
        if hasRepair then h = h + fontSize + 1 end  -- 1 extra row + visual gap
        self.frame:SetHeight(h + 8)
        self.lastLineCount = lineCount
        self.lastHasRepair = hasRepair
    end
end

function Panel:ApplyStyle(font, size)
    self.labelText:SetFont(font, size, "OUTLINE")
    self.ratingText:SetFont(font, size, "OUTLINE")
    self.valueText:SetFont(font, size, "OUTLINE")
    self.repairText:SetFont(font, size, "OUTLINE")
    self.repairLabelText:SetFont(font, size, "OUTLINE")
    -- WHY: Blizzard quirk - SetFont clears text; re-apply if we have one.
    if self.lastLabelText then
        self.labelText:SetText(self.lastLabelText)
    end
    if self.lastRatingText then
        self.ratingText:SetText(self.lastRatingText)
    end
    if self.lastValueText then
        self.valueText:SetText(self.lastValueText)
    end
    if self.lastRepairText and self.lastRepairText ~= "" then
        self.repairText:SetText(self.lastRepairText)
    end
    if self.lastRepairLabelText and self.lastRepairLabelText ~= "" then
        self.repairLabelText:SetText(self.lastRepairLabelText)
    end
    -- Force resize + line-height re-measure on next SetTextSafe
    self.cachedLabelH = nil
    self.lastLineCount = -1
end

--[[ ============================================================
    10. PANELS (instantiated at file scope)
============================================================ ]]
local mainPanel      = Panel:New("StatsProFrame",          "")
local defensivePanel = Panel:New("StatsProDefensiveFrame", "defensive_")

local function ApplyTextStyleToAllPanels(font, size)
    mainPanel:ApplyStyle(font, size)
    defensivePanel:ApplyStyle(font, size)
end

local function LoadAllPositions()
    mainPanel:LoadPosition()
    defensivePanel:LoadPosition()
end

local function SetAllPanelsLockState(locked)
    if locked then
        mainPanel:Lock()
        defensivePanel:Lock()
    else
        mainPanel:Unlock()
        defensivePanel:Unlock()
    end
end

local function SetAllPanelsScale(scale)
    mainPanel.frame:SetScale(scale)
    defensivePanel.frame:SetScale(scale)
end

--[[ ============================================================
    11. RENDER LOGIC
============================================================ ]]
-- Single point of truth for column-routing decisions across FmtRatingPct / FmtPctOnly /
-- RouteValueOnly / UpdateStats's value-col join. Dual-column mode = both display toggles
-- on; in every other case (single-column or neither) all visible content stacks in the
-- rating col and the value col is force-empty to avoid the GetStringWidth degenerate
-- case on a mostly-empty multi-line string.
local function IsDualColMode()
    return cached.showRating and cached.showPercentage
end

-- Format a stat value (rating + percentage variants honoring user toggles).
-- Returns TWO strings (ratingStr, valueStr) — see IsDualColMode for routing rules.
local function FmtRatingPct(rating, pct, statColor)
    local cs = cached.colorStrings
    local rc = (cached.matchValueColorToStat and statColor) or cs.rating
    local pc = (cached.matchValueColorToStat and statColor) or cs.percentage
    if IsDualColMode() then
        return string.format("|cff%s%d|r |cff808080|||r", rc, rating),
               string.format("|cff%s%.1f%%|r", pc, pct)
    elseif cached.showRating then
        return string.format("|cff%s%d|r", rc, rating), ""
    else
        -- percent-only: route into rating col (single-column layout)
        return string.format("|cff%s%.1f%%|r", pc, pct), ""
    end
end

-- Format a percentage-only stat (no rating dimension, e.g. defensive Dodge/Parry).
-- Returns (ratingCol, valueCol) — same routing rule as FmtRatingPct.
local function FmtPctOnly(pct, statColor)
    local cs = cached.colorStrings
    local pc = (cached.matchValueColorToStat and statColor) or cs.percentage
    local pctStr = string.format("|cff%s%.1f%%|r", pc, pct)
    if IsDualColMode() then return "", pctStr end
    return pctStr, ""
end

-- Route a plain value (Primary stat int, Durability %, Repair coin string) into the
-- rating col in single-column modes, into the value col in dual-column mode.
local function RouteValueOnly(valStr)
    if IsDualColMode() then return "", valStr end
    return valStr, ""
end

-- Three-column rendering: every Build*() function pushes (label, rating, value) entries
-- into the supplied tables. UpdateStats joins them with newlines and hands one string
-- to each FontString: labelText (RIGHT), ratingText (RIGHT), valueText (LEFT).
-- WHY triple-pushed instead of a single struct: cheaper than allocating a row-table per
-- line, and lets us reuse JoinLinesSecretSafe unchanged per column.
-- For rows without a rating dimension (Primary stats, Defensives, Durability, Repair,
-- headers), the rating column is "" and that line of the rating FontString is empty.

local function PushRow(labels, ratings, values, label, rating, value)
    labels[#labels + 1] = label
    ratings[#ratings + 1] = rating
    values[#values + 1] = value
end

local function BuildPrimaryLines(labels, ratings, values)
    local cs = cached.colorStrings
    local primaryStr = cs.primary
    local valueColor = (cached.matchValueColorToStat and primaryStr) or cs.rating
    for _, def in ipairs(PRIMARY_STATS) do
        if cached[def.showKey] then
            local val = safeCall(UnitStat, "player", def.unitStatId)
            local rCol, vCol = RouteValueOnly(string.format("|cff%s%d|r", valueColor, val))
            PushRow(labels, ratings, values,
                FormatLabel(primaryStr, def.label),
                rCol, vCol)
        end
    end
end

local function BuildOffensiveLines(labels, ratings, values)
    -- master gate (P-7): hide entire section when off (cheapest check, exits whole function)
    if not cached.showOffensive then return end
    -- WHY guard: with both display toggles off the user wants offensive rows hidden
    -- entirely. Without this guard the percent-only branch of FmtRatingPct would still
    -- fire (single-column routing), producing visible percent rows and ignoring intent.
    if not (cached.showRating or cached.showPercentage) then return end
    local cs = cached.colorStrings

    -- skip the GetCombatRating fetch when rating display is off (no consumer)
    local needRating = cached.showRating
    for _, def in ipairs(OFFENSIVE_STATS) do
        if cached[def.showKey] then
            local val = safeCall(def.api)
            if shouldShow(val, cached.hideZeroOffensive) then
                local rating = needRating and safeCall(GetCombatRating, def.ratingCR) or 0
                local statColor = cs[def.colorKey]
                local rStr, vStr = FmtRatingPct(rating, val, statColor)
                PushRow(labels, ratings, values,
                    FormatLabel(statColor, def.label),
                    rStr, vStr)
            end
        end
    end

    -- Versatility: dual-source (rating bonus + flat). Cache OOC; in combat use cached.
    if cached.showVersatility then
        local versFromRating = safeCall(GetCombatRatingBonus, CR_VERSATILITY_DAMAGE_DONE)
        local versFlat       = safeCall(GetVersatilityBonus,  CR_VERSATILITY_DAMAGE_DONE)
        local versRating     = safeCall(GetCombatRating,      CR_VERSATILITY_DAMAGE_DONE)
        -- WARNING: must check ALL three for secret state before arithmetic. Different APIs may
        -- have different secret states despite same combat status (defensive: guard everything).
        if not issecretvalue(versFromRating) and not issecretvalue(versFlat) and not issecretvalue(versRating) then
            cached.versTotal = versFromRating + versFlat
            cached.versTotalRating = versRating
        end
        if shouldShow(cached.versTotal, cached.hideZeroOffensive) then
            local versStr = cs.versatility
            local vRatStr, vValStr = FmtRatingPct(cached.versTotalRating, cached.versTotal, versStr)
            PushRow(labels, ratings, values,
                FormatLabel(versStr, "Vers"),
                vRatStr, vValStr)
        end
    end
end

local function BuildTertiaryLines(labels, ratings, values)
    if not cached.showTertiary then return end
    if not (cached.showRating or cached.showPercentage) then return end
    local cs = cached.colorStrings

    local needRating = cached.showRating
    for _, def in ipairs(TERTIARY_STATS) do
        if cached[def.showKey] then
            local val = safeCall(def.api)
            if shouldShow(val, cached.hideZeroTertiary) then
                local rating = needRating and safeCall(GetCombatRating, def.ratingCR) or 0
                local statColor = cs[def.colorKey]
                local rStr, vStr = FmtRatingPct(rating, val, statColor)
                PushRow(labels, ratings, values,
                    FormatLabel(statColor, def.label),
                    rStr, vStr)
            end
        end
    end

    -- Speed: GetSpeed returns rating-derived %, GetUnitSpeed gives actual yps.
    -- Base run = 7 yps = 100%. Max of all modes covers mounts/sprint/swim.
    if cached.showSpeed then
        local cur, run, flight, swim = GetUnitSpeed("player")
        -- WARNING: 12.x retail returns secrets from GetUnitSpeed in combat → math.max
        -- triggers numeric conversion taint. Recompute OOC, reuse cached value in combat.
        if not (issecretvalue(cur) or issecretvalue(run) or issecretvalue(flight) or issecretvalue(swim)) then
            local effectiveYps = math.max(cur or 0, run or 0, flight or 0, swim or 0)
            cached.speedPct = (effectiveYps / 7) * 100
        end
        local speed = cached.speedPct
        local speedRating = needRating and safeCall(GetCombatRating, CR_SPEED) or 0
        if shouldShow(speed, cached.hideZeroTertiary) then
            local statColor = cs.speed
            local rStr, vStr = FmtRatingPct(speedRating, speed, statColor)
            PushRow(labels, ratings, values,
                FormatLabel(statColor, "Speed"),
                rStr, vStr)
        end
    end
end

local function BuildMainLines()
    local labels, ratings, values = {}, {}, {}
    BuildPrimaryLines(labels, ratings, values)
    BuildOffensiveLines(labels, ratings, values)
    BuildTertiaryLines(labels, ratings, values)
    return labels, ratings, values
end

local function BuildDefensiveLines()
    local labels, ratings, values = {}, {}, {}
    if not cached.showDefensive then return labels, ratings, values end
    local cs = cached.colorStrings

    -- Dodge / Parry / Block (table-driven)
    for _, def in ipairs(DEFENSIVE_STATS) do
        if cached[def.showKey] then
            local val = safeCall(def.api)
            if shouldShow(val, cached.hideZeroDefensive) then
                local statColor = cs[def.colorKey]
                local rStr, vStr = FmtPctOnly(val, statColor)
                PushRow(labels, ratings, values,
                    FormatLabel(statColor, def.label),
                    rStr, vStr)
            end
        end
    end

    -- Armor: shown as % damage reduction (computed from effective armor, cached OOC).
    -- WARNING: never call UnitArmor in combat - it returns secrets that break arithmetic.
    if cached.showArmor then
        local armorStr = cs.armor
        local valueColor = (cached.matchValueColorToStat and armorStr) or cs.percentage
        if shouldShow(cached.armorDR, cached.hideZeroDefensive) then
            local rCol, vCol = RouteValueOnly(string.format("|cff%s%.1f%%|r", valueColor, cached.armorDR))
            PushRow(labels, ratings, values,
                FormatLabel(armorStr, "Armor"),
                rCol, vCol)
        end
    end

    return labels, ratings, values
end

-- WHY: durability is independent of "Show Defensive Stats" — gear wear is not a
-- defensive stat (one is mitigation %, the other is item integrity). Kept as its own
-- builder so users can show only durability without enabling the dodge/parry/block block.
local function BuildDurabilityLines()
    local labels, ratings, values = {}, {}, {}
    local repairStr = ""
    if not cached.showDurability then return labels, ratings, values, repairStr end
    local cs = cached.colorStrings
    local pct = cached.durabilityValue
    local durStr = cs.durability
    local valueColor
    if cached.useAutoColorDurability then
        valueColor = RGBToHex(ComputeDurabilityColor(pct))
    else
        valueColor = durStr
    end
    -- %.1f%% matches vendor precision (95.2% vs 95%)
    do
        local rCol, vCol = RouteValueOnly(string.format("|cff%s%.1f%%|r", valueColor, pct))
        PushRow(labels, ratings, values,
            FormatLabel(durStr, "Durability"),
            rCol, vCol)
    end
    local repairLabelStr
    if cached.showRepairCost and cached.repairCost > 0 then
        -- WHY no PushRow for Repair: the label + coin render on a DEDICATED row below
        -- the stat rows (see Panel:SetTextSafe), not as part of the multi-line labelText.
        -- Two reasons: (1) the coin string with inline gold/silver/copper icons is wider
        -- than typical stat values, so putting "Repair:" in labelText keeps coin sharing
        -- a Y with that row — coin overlaps the rating/value content area and (in narrow
        -- panel modes) the label itself. (2) Visual separation: stats render as one
        -- group, repair-cost info as a distinct group below.
        -- Don't wrap the coin string in |cff...|r — coin icons render inline as textures
        -- and the color tag would tint them.
        repairLabelStr = FormatLabel(durStr, "Repair")
        repairStr = FormatRepairCost(cached.repairCost)
    end
    return labels, ratings, values, repairStr, repairLabelStr
end

-- WHY: separate header injector — sectioned mode places "— Defensive —" between sections.
-- Header text spans the label column with empty rating + value to preserve row alignment.
local function PushHeader(labels, ratings, values, headerStr)
    labels[#labels + 1] = headerStr
    ratings[#ratings + 1] = ""
    values[#values + 1] = ""
end

-- Append (srcLabels, srcRatings, srcValues) into the destination tables row-by-row.
local function AppendRows(dstLabels, dstRatings, dstValues, srcLabels, srcRatings, srcValues)
    for i = 1, #srcLabels do
        dstLabels[#dstLabels + 1] = srcLabels[i]
        dstRatings[#dstRatings + 1] = srcRatings[i]
        dstValues[#dstValues + 1] = srcValues[i]
    end
end

local function UpdateStats()
    -- WARNING: skip until init complete; cached.colorStrings is empty until CacheSettings runs
    if not isLoaded then return end

    -- WHY: master visibility toggle. When off, hide both panels and skip all work
    -- (stat APIs, slot scans). Re-enabling via slash/UI calls UpdateStats explicitly,
    -- which Shows the frame again on first non-empty SetTextSafe call.
    if cached.isVisible == false then
        mainPanel:Hide()
        defensivePanel:Hide()
        return
    end

    -- Armor refresh: cheap (one pcall + one Lua call); always do it out of combat.
    if not InCombatLockdown() and cached.showArmor then
        RefreshArmorCache()
    end

    -- Durability: event-driven (avoid scanning 19 slots every 0.5s).
    if cached.showDurability and durabilityDirty then
        RefreshDurabilityCache()
    end

    -- Build paired (label, value) row arrays per builder.
    -- repairStr + repairLabelStr are returned separately because they're rendered on
    -- a dedicated row below the stat columns (see Panel:SetTextSafe), not inside the
    -- 3-column system. Both travel with whichever panel hosts durability in the active mode.
    local mainLabels, mainRatings, mainValues = BuildMainLines()
    local defLabels,  defRatings,  defValues  = BuildDefensiveLines()
    local durLabels,  durRatings,  durValues, repairStr, repairLabelStr = BuildDurabilityLines()

    -- WHY: in single-column display modes (only rating OR only percent on, or neither),
    -- Build*/Fmt* helpers route ALL content into the rating col and push a literal "" to
    -- the value col for every row. Pass "" directly to SetTextSafe instead of joining N
    -- empty literals — joining produces "\n\n\n" which makes valueText:GetStringWidth()
    -- unreliable in 12.x (returns stale/secret-tainted, panel layout breaks). Safe because
    -- "" is a literal at all push sites in single-col mode (no taint comparison needed).
    local function JoinValuesCol(values)
        if IsDualColMode() then return JoinLinesSecretSafe(values) end
        return ""
    end

    -- Dispatch by display mode. repairStr always travels with the durability rows;
    -- in split mode that's the defensive panel, otherwise the main panel.
    local mode = cached.displayMode or "flat"
    if mode == "split" then
        mainPanel:SetTextSafe(
            JoinLinesSecretSafe(mainLabels),
            JoinLinesSecretSafe(mainRatings),
            JoinValuesCol(mainValues),
            #mainLabels, "", nil)
        -- WHY: defensive panel hosts both defensive stats and durability so the user can
        -- see them together while keeping the main panel focused on offensive/primary.
        local sideLabels, sideRatings, sideValues = {}, {}, {}
        AppendRows(sideLabels, sideRatings, sideValues, defLabels, defRatings, defValues)
        AppendRows(sideLabels, sideRatings, sideValues, durLabels, durRatings, durValues)
        if #sideLabels > 0 then
            defensivePanel:SetTextSafe(
                JoinLinesSecretSafe(sideLabels),
                JoinLinesSecretSafe(sideRatings),
                JoinValuesCol(sideValues),
                #sideLabels, repairStr, repairLabelStr)
        else
            defensivePanel:Hide()
        end
    elseif mode == "sectioned" then
        local cLabels, cRatings, cValues = {}, {}, {}
        AppendRows(cLabels, cRatings, cValues, mainLabels, mainRatings, mainValues)
        if #defLabels > 0 then
            PushHeader(cLabels, cRatings, cValues, DefensiveHeader())
            AppendRows(cLabels, cRatings, cValues, defLabels, defRatings, defValues)
        end
        AppendRows(cLabels, cRatings, cValues, durLabels, durRatings, durValues)
        mainPanel:SetTextSafe(
            JoinLinesSecretSafe(cLabels),
            JoinLinesSecretSafe(cRatings),
            JoinValuesCol(cValues),
            #cLabels, repairStr, repairLabelStr)
        defensivePanel:Hide()
    else
        -- flat (default)
        local cLabels, cRatings, cValues = {}, {}, {}
        AppendRows(cLabels, cRatings, cValues, mainLabels, mainRatings, mainValues)
        AppendRows(cLabels, cRatings, cValues, defLabels,  defRatings,  defValues)
        AppendRows(cLabels, cRatings, cValues, durLabels,  durRatings,  durValues)
        mainPanel:SetTextSafe(
            JoinLinesSecretSafe(cLabels),
            JoinLinesSecretSafe(cRatings),
            JoinValuesCol(cValues),
            #cLabels, repairStr, repairLabelStr)
        defensivePanel:Hide()
    end
end

--[[ ============================================================
    12. UPDATE TIMER (single source; lives on mainPanel)
============================================================ ]]
local timeSinceLastUpdate = 0
mainPanel.frame:SetScript("OnUpdate", function(self, elapsed)
    timeSinceLastUpdate = timeSinceLastUpdate + elapsed
    if timeSinceLastUpdate >= cached.updateInterval then
        UpdateStats()
        timeSinceLastUpdate = 0
    end
end)

--[[ ============================================================
    13. EVENT DISPATCHER
============================================================ ]]
-- isLoaded declared earlier (section 6) so UpdateStats closure captures the same upvalue

local function OnPlayerEnteringWorld()
    if not isLoaded then
        MigrateDB()
        CacheSettings()
        LoadAllPositions()
        SetAllPanelsLockState(GetDB("isLocked"))
        SetAllPanelsScale(GetDB("scale"))
        isLoaded = true
    end
    -- WHY: UpdateStats handles Show/Hide based on cached.isVisible + line content.
    durabilityDirty = true
    UpdateStats()
end

-- WHY: Armor/DR refresh runs inline in UpdateStats out-of-combat (cheap), so we
-- don't need PLAYER_REGEN_ENABLED / PLAYER_SPECIALIZATION_CHANGED / TRAIT_CONFIG_UPDATED /
-- PLAYER_LEVEL_UP handlers. Worst-case latency for stat refresh is one OnUpdate tick (~0.5s).
-- WHY: no MERCHANT_SHOW/CLOSED handlers — repair cost comes from per-slot tooltip scan
-- (Blizzard's own approach). UPDATE_INVENTORY_DURABILITY rebuilds cost on every change.
-- WHY: PLAYER_LOGOUT fires before SavedVariables are written to disk. Re-saving
-- positions here is a belt-and-suspenders backup: OnMouseUp already saves on drop,
-- but if the user reloads/quits via a path that bypasses our drag handler (rare),
-- this guarantees the latest GetPoint() is what hits disk.
local function OnPlayerLogout()
    mainPanel:SavePosition()
    defensivePanel:SavePosition()
end

local EVENT_HANDLERS = {
    PLAYER_ENTERING_WORLD       = OnPlayerEnteringWorld,
    PLAYER_LOGOUT               = OnPlayerLogout,
    UPDATE_INVENTORY_DURABILITY = function() durabilityDirty = true end,
    PLAYER_EQUIPMENT_CHANGED    = function() durabilityDirty = true end,
    -- WHY: Panel:Unlock no-ops in combat (defensive InCombatLockdown guard). Toggling
    -- Lock Frames OFF mid-combat writes DB but leaves panels mouse-disabled until
    -- /reload. Re-apply lock state on combat exit so visual matches DB.
    PLAYER_REGEN_ENABLED        = function() SetAllPanelsLockState(GetDB("isLocked")) end,
}

local eventFrame = CreateFrame("Frame")
for event in pairs(EVENT_HANDLERS) do
    eventFrame:RegisterEvent(event)
end
eventFrame:SetScript("OnEvent", function(self, event, ...)
    local handler = EVENT_HANDLERS[event]
    if handler then handler(...) end
end)

--[[ ============================================================
    14. SETTINGS UI HELPERS
============================================================ ]]
-- WHY: each helper that creates a config widget pushes a zero-arg closure that
-- re-syncs that widget's visuals from DB. Reset to Defaults walks this list
-- (Section 15) instead of rebuilding the named frame (which would leak
-- _G.StatsProConfigFrame per click — CreateFrame's named globals are immortal
-- in WoW Lua, no Hide()/SetParent(nil) releases them).
local configRefreshers = {}
local function PushRefresher(fn) tinsert(configRefreshers, fn) end

-- Single source of truth for "DB color or fallback to default". Used by every
-- color-related helper + their refreshers; lazily initializes the colors table
-- (StatsProDB may not have it yet on a fresh install).
local function GetColor(statName)
    if not StatsProDB.colors then StatsProDB.colors = {} end
    return StatsProDB.colors[statName] or defaults.colors[statName]
end

local function CreateCheckbox(parent, name, label, dbKey, x, y, onChange, textWidth)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    cb:SetSize(22, 22)
    local text = _G[name .. "Text"]
    text:SetText(label)
    text:SetFont("Fonts\\FRIZQT__.TTF", 12)
    -- textWidth: 200 default for plain checkboxes; pass 140 for "checkbox + inline color" rows
    text:SetWidth(textWidth or 200)
    text:SetJustifyH("LEFT")
    cb:SetChecked(GetDB(dbKey))
    cb:SetScript("OnClick", function(self)
        StatsProDB[dbKey] = self:GetChecked()
        CacheSettings()
        if onChange then onChange(self:GetChecked()) end
        UpdateStats()
    end)
    PushRefresher(function() cb:SetChecked(GetDB(dbKey)) end)
    return cb
end

-- Toggle a checkbox's enabled state with matching label dim. Used by dependent-toggle
-- greying patterns (Repair Cost gated on Show Durability; Leech/Avoidance/Speed gated
-- on Show Tertiary Stats master) to make the dependency visible.
local function SetCheckboxEnabled(cb, enabled)
    if not cb then return end
    local txt = _G[cb:GetName() .. "Text"]
    if enabled then
        cb:Enable()
        if txt then txt:SetTextColor(1, 1, 1, 1) end
    else
        cb:Disable()
        if txt then txt:SetTextColor(0.5, 0.5, 0.5, 1) end
    end
end

-- WHY: shared snapshot/select/cancel handler used by both CreateColorSwatch (compact 22x16
-- inline button) and CreateColorPicker (labeled "Stat Color:" 30x20 row). Snapshot is taken
-- at click time, not creation time, so cancelling a 2nd pick reverts to the user's prior
-- color, not the original default.
local function OpenColorPicker(btn, statName)
    local current = GetColor(statName)
    local snapshot = { r = current.r, g = current.g, b = current.b }
    local function OnColorSelect()
        local r, g, b = ColorPickerFrame:GetColorRGB()
        btn:SetBackdropColor(r, g, b, 1)
        StatsProDB.colors[statName] = { r = r, g = g, b = b }
        CacheSettings()
        UpdateStats()
    end
    local function OnCancel()
        btn:SetBackdropColor(snapshot.r, snapshot.g, snapshot.b, 1)
        StatsProDB.colors[statName] = snapshot
        CacheSettings()
        UpdateStats()
    end
    ColorPickerFrame:SetupColorPickerAndShow({
        r = snapshot.r, g = snapshot.g, b = snapshot.b,
        opacity = 1, hasOpacity = false,
        swatchFunc = OnColorSelect,
        cancelFunc = OnCancel,
    })
end

-- Compact color swatch (no "Color:" label). Used for inline-with-checkbox placement
-- and section-header shared colors.
local function CreateColorSwatch(parent, statName, x, y)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", x, y)
    btn:SetSize(22, 16)
    btn:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    local initialColor = GetColor(statName)
    btn:SetBackdropColor(initialColor.r, initialColor.g, initialColor.b, 1)
    btn:SetScript("OnClick", function(self) OpenColorPicker(self, statName) end)
    PushRefresher(function()
        local c = GetColor(statName)
        btn:SetBackdropColor(c.r, c.g, c.b, 1)
    end)
    return btn
end

-- Combined: checkbox with color swatch immediately to the right of label.
-- swatch x = x + 22 (checkbox) + 140 (label) + 8 (gap) = x + 170
-- Returns (cb, swatch). Most callers ignore swatch; durability captures it to grey-out
-- when Auto Color overrides the user-picked color.
local function CreateCheckboxColor(parent, name, label, dbKey, colorKey, x, y, onChange)
    local cb = CreateCheckbox(parent, name, label, dbKey, x, y, onChange, 140)
    local swatch
    if colorKey then
        swatch = CreateColorSwatch(parent, colorKey, x + 170, y - 3)
    end
    return cb, swatch
end

local function CreateColorPicker(parent, label, statName, yPos, xPos)
    local colorLabel = parent:CreateFontString(nil, "OVERLAY")
    colorLabel:SetFont("Fonts\\FRIZQT__.TTF", 12)
    colorLabel:SetPoint("TOPLEFT", xPos, yPos)
    colorLabel:SetText(label .. " Color:")

    local colorBtn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    colorBtn:SetPoint("LEFT", colorLabel, "RIGHT", 10, 0)
    colorBtn:SetSize(30, 20)
    colorBtn:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })

    local initialColor = GetColor(statName)
    colorBtn:SetBackdropColor(initialColor.r, initialColor.g, initialColor.b, 1)
    colorBtn:SetScript("OnClick", function(self) OpenColorPicker(self, statName) end)
    PushRefresher(function()
        local c = GetColor(statName)
        colorBtn:SetBackdropColor(c.r, c.g, c.b, 1)
    end)
end

--[[ ============================================================
    15. CONFIG MENU (tabs: Display / Stats / Defensive)
============================================================ ]]
local configFrame
local configSpecialFrameRegistered = false

-- Layout cursor: stateful y-position tracker; eliminates manual `y = y - 25` math
local function NewCursor(parent, padX, startY, gap)
    return {
        parent = parent, padX = padX or 12,
        y = startY or -8, gap = gap or 6,
        initialY = startY or -8,
    }
end
local function CursorAdvance(c, h) c.y = c.y - (h or 24) - c.gap end
local function CursorGap(c, n)     c.y = c.y - (n or 8) end
local function CursorUsed(c)       return math.abs(c.initialY - c.y) + 16 end
-- CursorSection: section header with green underline.
-- Optional `sharedColorKey`: places a color swatch right after the header text;
-- use this when one color applies to all stats in the section (e.g. Primary).
local function CursorSection(c, label, sharedColorKey)
    local hdr = c.parent:CreateFontString(nil, "OVERLAY")
    hdr:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    hdr:SetPoint("TOPLEFT", c.parent, "TOPLEFT", c.padX, c.y)
    hdr:SetText("|cff00ff7f" .. string.upper(label) .. "|r")
    if sharedColorKey then
        -- WHY: GetStringWidth is unreliable immediately after SetText; use a generous
        -- fixed offset that fits any of our header labels in uppercase.
        CreateColorSwatch(c.parent, sharedColorKey, c.padX + 200, c.y + 1)
    end
    local line = c.parent:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", c.parent, "TOPLEFT", c.padX, c.y - 18)
    line:SetPoint("TOPRIGHT", c.parent, "TOPRIGHT", -c.padX, c.y - 18)
    line:SetHeight(1)
    line:SetColorTexture(0, 1, 0.5, 0.25)
    c.y = c.y - 24 - c.gap
end

function addon:OpenConfigMenu()
    if configFrame then
        if configFrame:IsShown() then
            configFrame:Hide()
        else
            configFrame:Show()
            -- Always reopen on Display tab (predictable UX)
            if configFrame.SwitchToTab then configFrame.SwitchToTab(1) end
        end
        return
    end

    -- WHY: future-proofing — body below runs exactly once per session due to
    -- the early-return guard above, but if anyone makes this re-entrant the
    -- refresher list would duplicate every entry. Cheap insurance.
    wipe(configRefreshers)

    --[[ ===== Frame ===== ]]
    configFrame = CreateFrame("Frame", "StatsProConfigFrame", UIParent, "BackdropTemplate")
    configFrame:SetSize(500, 540)
    configFrame:SetPoint("CENTER")
    configFrame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 5, right = 5, top = 5, bottom = 5 },
    })
    configFrame:SetBackdropColor(0, 0, 0, 0.92)
    configFrame:EnableMouse(true)
    configFrame:SetMovable(true)
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetScript("OnDragStart", configFrame.StartMoving)
    configFrame:SetScript("OnDragStop", configFrame.StopMovingOrSizing)
    configFrame:SetClampedToScreen(true)
    -- WHY: guarded as a one-shot for symmetry — the early-return at the top of
    -- OpenConfigMenu already ensures this body runs once per session, but the flag
    -- means even a re-entrant rebuild wouldn't double-add to UISpecialFrames.
    if not configSpecialFrameRegistered then
        tinsert(UISpecialFrames, "StatsProConfigFrame")
        configSpecialFrameRegistered = true
    end

    --[[ ===== Header (title + X) ===== ]]
    local title = configFrame:CreateFontString(nil, "OVERLAY")
    title:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
    title:SetPoint("TOP", 0, -12)
    title:SetText("|cff00ff7fStatsPro|r v" .. ADDON_VERSION .. " Settings")

    local closeX = CreateFrame("Button", nil, configFrame, "UIPanelCloseButton")
    closeX:SetPoint("TOPRIGHT", -4, -4)

    -- Header separator
    local headerLine = configFrame:CreateTexture(nil, "ARTWORK")
    headerLine:SetPoint("TOPLEFT", 12, -38)
    headerLine:SetPoint("TOPRIGHT", -12, -38)
    headerLine:SetHeight(1)
    headerLine:SetColorTexture(0.3, 0.3, 0.3, 0.5)

    --[[ ===== Tab strip (custom, top-anchored, underline-active style) ===== ]]
    local TAB_HEIGHT = 28
    local tabStrip = CreateFrame("Frame", nil, configFrame)
    tabStrip:SetPoint("TOPLEFT", 18, -44)
    tabStrip:SetPoint("TOPRIGHT", -18, -44)
    tabStrip:SetHeight(TAB_HEIGHT)

    -- Separator below tab strip
    local tabsLine = configFrame:CreateTexture(nil, "ARTWORK")
    tabsLine:SetPoint("TOPLEFT", 12, -76)
    tabsLine:SetPoint("TOPRIGHT", -12, -76)
    tabsLine:SetHeight(1)
    tabsLine:SetColorTexture(0.3, 0.3, 0.3, 0.7)

    --[[ ===== Footer (Reset + Close) ===== ]]
    local footerLine = configFrame:CreateTexture(nil, "ARTWORK")
    footerLine:SetPoint("BOTTOMLEFT", 12, 50)
    footerLine:SetPoint("BOTTOMRIGHT", -12, 50)
    footerLine:SetHeight(1)
    footerLine:SetColorTexture(0.3, 0.3, 0.3, 0.7)

    local resetBtn = CreateFrame("Button", nil, configFrame, "GameMenuButtonTemplate")
    resetBtn:SetPoint("BOTTOMLEFT", 18, 14)
    resetBtn:SetSize(160, 26)
    resetBtn:SetText("Reset to Defaults")
    resetBtn:SetNormalFontObject("GameFontNormal")
    resetBtn:SetHighlightFontObject("GameFontHighlight")

    local closeBtn = CreateFrame("Button", nil, configFrame, "GameMenuButtonTemplate")
    closeBtn:SetPoint("BOTTOMRIGHT", -18, 14)
    closeBtn:SetSize(100, 26)
    closeBtn:SetText("Close")
    closeBtn:SetNormalFontObject("GameFontNormal")
    closeBtn:SetHighlightFontObject("GameFontHighlight")
    closeBtn:SetScript("OnClick", function() configFrame:Hide() end)

    --[[ ===== ScrollFrame for tab content ===== ]]
    local scrollFrame = CreateFrame("ScrollFrame", "StatsProConfigScroll", configFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 14, -82)
    scrollFrame:SetPoint("BOTTOMRIGHT", -32, 60)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(scrollFrame:GetWidth() - 4, 1)  -- height set per active tab
    scrollFrame:SetScrollChild(scrollChild)

    -- Tab content frames (children of scrollChild)
    local displayTab   = CreateFrame("Frame", nil, scrollChild)
    local statsTab     = CreateFrame("Frame", nil, scrollChild)
    local defensiveTab = CreateFrame("Frame", nil, scrollChild)
    local tabContents  = { displayTab, statsTab, defensiveTab }
    for _, tab in ipairs(tabContents) do
        tab:SetPoint("TOPLEFT", 0, 0)
        tab:SetPoint("TOPRIGHT", 0, 0)
        tab:Hide()
    end

    --[[ ===== Tab buttons (custom, with underline indicator) ===== ]]
    local tabButtons = {}

    local function CreateTabButton(label)
        local btn = CreateFrame("Button", nil, tabStrip)
        btn:SetSize(110, TAB_HEIGHT)
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(btn)
        hl:SetColorTexture(1, 1, 1, 0.06)
        local sel = btn:CreateTexture(nil, "ARTWORK")
        sel:SetPoint("BOTTOMLEFT",  btn, "BOTTOMLEFT",  8,  0)
        sel:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -8, 0)
        sel:SetHeight(2)
        sel:SetColorTexture(0, 1, 0.5, 1)
        sel:Hide()
        btn.selected = sel
        local txt = btn:CreateFontString(nil, "OVERLAY")
        txt:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
        txt:SetPoint("CENTER", 0, 1)
        txt:SetText(label)
        txt:SetTextColor(0.65, 0.65, 0.65, 1)
        btn.text = txt
        return btn
    end

    local function SwitchToTab(idx)
        for i, content in ipairs(tabContents) do
            if i == idx then
                content:Show()
                if content.contentHeight then
                    scrollChild:SetHeight(content.contentHeight)
                end
                tabButtons[i].selected:Show()
                tabButtons[i].text:SetTextColor(1, 1, 1, 1)
            else
                content:Hide()
                tabButtons[i].selected:Hide()
                tabButtons[i].text:SetTextColor(0.65, 0.65, 0.65, 1)
            end
        end
        scrollFrame:SetVerticalScroll(0)
    end
    configFrame.SwitchToTab = SwitchToTab

    do
        local names = { "Display", "Stats", "Defensive" }
        for i, name in ipairs(names) do
            local btn = CreateTabButton(name)
            if i == 1 then
                btn:SetPoint("LEFT", tabStrip, "LEFT", 0, 0)
            else
                btn:SetPoint("LEFT", tabButtons[i - 1], "RIGHT", 4, 0)
            end
            btn:SetScript("OnClick", function() SwitchToTab(i) end)
            tabButtons[i] = btn
        end
    end

    --[[ ===== DISPLAY TAB ===== ]]
    local cd = NewCursor(displayTab, 12, -8)

    -- Frame & Position section
    CursorSection(cd, "Frame & Position")
    do
        local rowY = cd.y
        -- WHY: master visibility toggle. Hides both panels without losing settings.
        -- OnClick already runs CacheSettings + UpdateStats; UpdateStats checks cached.isVisible
        -- and Hides both panels. Slash equivalents: /ss show, /ss hide, /ss toggle.
        CreateCheckbox(displayTab, "StatsProVisibleCheck",
            "Show Stats Panel", "isVisible", cd.padX, rowY, nil, 140)
        CreateCheckbox(displayTab, "StatsProLockCheck",
            "Lock Frames", "isLocked", cd.padX + 180, rowY, function(checked)
                SetAllPanelsLockState(checked)
            end, 140)
        cd.y = rowY - 26
        rowY = cd.y

        local dmLabel = displayTab:CreateFontString(nil, "OVERLAY")
        dmLabel:SetFont("Fonts\\FRIZQT__.TTF", 12)
        dmLabel:SetPoint("TOPLEFT", cd.padX, rowY - 4)
        dmLabel:SetText("Display Mode:")

        local DISPLAY_MODES = {
            { value = "flat",      label = "Flat" },
            { value = "sectioned", label = "Sectioned" },
            { value = "split",     label = "Split" },
        }
        local function GetDisplayModeLabel(value)
            for _, m in ipairs(DISPLAY_MODES) do
                if m.value == value then return m.label end
            end
            return DISPLAY_MODES[1].label
        end

        local dmDropdown = CreateFrame("Frame", "StatsProDisplayModeDropdown", displayTab, "UIDropDownMenuTemplate")
        dmDropdown:SetPoint("TOPLEFT", cd.padX + 240, rowY + 2)
        UIDropDownMenu_SetWidth(dmDropdown, 130)
        UIDropDownMenu_Initialize(dmDropdown, function(self, level)
            for _, m in ipairs(DISPLAY_MODES) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = m.label
                info.value = m.value
                info.checked = (GetDB("displayMode") == m.value)
                info.func = function()
                    StatsProDB.displayMode = m.value
                    CacheSettings()
                    UIDropDownMenu_SetText(dmDropdown, m.label)
                    CloseDropDownMenus()
                    UpdateStats()
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        UIDropDownMenu_SetText(dmDropdown, GetDisplayModeLabel(GetDB("displayMode")))
        PushRefresher(function()
            UIDropDownMenu_SetText(dmDropdown, GetDisplayModeLabel(GetDB("displayMode")))
        end)
        cd.y = rowY - 30
    end

    CursorGap(cd, 4)

    -- Display Format section
    CursorSection(cd, "Display Format")
    do
        local rowY = cd.y
        CreateCheckbox(displayTab, "StatsProRatingCheck",     "Show Rating",     "showRating",     cd.padX,       rowY)
        CreateCheckbox(displayTab, "StatsProPercentageCheck", "Show Percentage", "showPercentage", cd.padX + 200, rowY)
        cd.y = rowY - 26
    end
    CreateCheckbox(displayTab, "StatsProMatchColorCheck",
        "Match Value Color to Stat", "matchValueColorToStat", cd.padX, cd.y)
    CursorAdvance(cd, 22)
    CursorGap(cd, 4)

    -- Localization section — gated: only shown on locales we ship translations for.
    -- enUS clients see no toggle (LABELS_BY_LOCALE.enUS is identity, so the toggle has
    -- no effect). HAS_LOCALIZATION is resolved once at addon load from GetLocale().
    if HAS_LOCALIZATION then
        CursorSection(cd, "Localization")
        -- Data-driven preview: pull this locale's own translation of "Crit" so the
        -- checkbox text shows a concrete substitution preview that's always correct
        -- for whatever client the user is on. No per-locale UI string maintenance.
        local sample = LOCALIZED_LABELS.Crit or "Crit"
        CreateCheckbox(displayTab, "StatsProLocalizedLabelsCheck",
            "Use localized stat names (e.g. '" .. sample .. "' instead of 'Crit')",
            "useLocalizedLabels", cd.padX, cd.y)
        CursorAdvance(cd, 22)
        CursorGap(cd, 4)
    end

    -- Typography section
    CursorSection(cd, "Typography")
    do
        local rowY = cd.y

        local fontLabel = displayTab:CreateFontString(nil, "OVERLAY")
        fontLabel:SetFont("Fonts\\FRIZQT__.TTF", 12)
        fontLabel:SetPoint("TOPLEFT", cd.padX, rowY)
        fontLabel:SetText("Font:")

        -- WHY rebuilt on each open: LSM-registered fonts can appear after StatsPro
        -- loads (other addon registers later). Static one-time build would miss them
        -- until /reload. Cost is O(n) over ~20-30 fonts on a user click — negligible.
        local function BuildFontsList()
            if LSM then
                local list = {}
                for _, name in ipairs(LSM:List(LSM.MediaType.FONT)) do
                    list[#list + 1] = { name = name, path = LSM:Fetch(LSM.MediaType.FONT, name) }
                end
                return list
            end
            return {
                { name = "Friz Quadrata TT", path = "Fonts\\FRIZQT__.TTF" },
                { name = "Arial Narrow",     path = "Fonts\\ARIALN.TTF" },
                { name = "Skurri",           path = "Fonts\\SKURRI.TTF" },
                { name = "Morpheus",         path = "Fonts\\MORPHEUS.TTF" },
            }
        end

        local fontDropdown = CreateFrame("Frame", "StatsProFontDropdown", displayTab, "UIDropDownMenuTemplate")
        fontDropdown:SetPoint("TOPLEFT", cd.padX + 36, rowY - 4)
        UIDropDownMenu_Initialize(fontDropdown, function(self, level)
            for _, f in ipairs(BuildFontsList()) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = f.name
                info.value = f.path
                info.checked = (GetDB("font") == f.path)
                info.func = function()
                    StatsProDB.font = f.path
                    ApplyTextStyleToAllPanels(f.path, GetDB("fontSize"))
                    UIDropDownMenu_SetText(fontDropdown, f.name)
                    CloseDropDownMenus()
                    UpdateStats()
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        local function CurrentFontName()
            for _, f in ipairs(BuildFontsList()) do
                if f.path == GetDB("font") then return f.name end
            end
            return "Friz Quadrata TT"
        end
        UIDropDownMenu_SetText(fontDropdown, CurrentFontName())
        UIDropDownMenu_SetWidth(fontDropdown, 150)
        PushRefresher(function() UIDropDownMenu_SetText(fontDropdown, CurrentFontName()) end)

        -- WHY no text-alignment control: three-column rendering pins labels RIGHT,
        -- ratings RIGHT, values LEFT — there is no global alignment to adjust. The
        -- defaults.textAlign field exists in DB purely so existing saves don't lose
        -- the key on migration; nothing reads it at runtime.

        cd.y = rowY - 32
    end

    -- Font Size slider
    do
        local sliderY = cd.y
        local lbl = displayTab:CreateFontString(nil, "OVERLAY")
        lbl:SetFont("Fonts\\FRIZQT__.TTF", 12)
        lbl:SetPoint("TOPLEFT", cd.padX, sliderY)
        lbl:SetText("Font Size:")
        local slider = CreateFrame("Slider", "StatsProFontSlider", displayTab, "OptionsSliderTemplate")
        slider:SetPoint("TOPLEFT", cd.padX, sliderY - 18)
        slider:SetMinMaxValues(8, 32)
        slider:SetValue(GetDB("fontSize"))
        slider:SetValueStep(1)
        slider:SetObeyStepOnDrag(true)
        slider:SetWidth(420)
        _G[slider:GetName() .. "Low"]:SetText("8")
        _G[slider:GetName() .. "High"]:SetText("32")
        _G[slider:GetName() .. "Text"]:SetText(slider:GetValue())
        slider:SetScript("OnValueChanged", function(self, value)
            _G[self:GetName() .. "Text"]:SetText(math.floor(value))
            StatsProDB.fontSize = value
            ApplyTextStyleToAllPanels(GetDB("font"), value)
            UpdateStats()
        end)
        PushRefresher(function()
            local v = GetDB("fontSize")
            slider:SetValue(v)
            _G[slider:GetName().."Text"]:SetText(math.floor(v))
        end)
        cd.y = sliderY - 50
    end

    -- Scale slider
    do
        local sliderY = cd.y
        local lbl = displayTab:CreateFontString(nil, "OVERLAY")
        lbl:SetFont("Fonts\\FRIZQT__.TTF", 12)
        lbl:SetPoint("TOPLEFT", cd.padX, sliderY)
        lbl:SetText("Scale:")
        local slider = CreateFrame("Slider", "StatsProScaleSlider", displayTab, "OptionsSliderTemplate")
        slider:SetPoint("TOPLEFT", cd.padX, sliderY - 18)
        slider:SetMinMaxValues(0.5, 2.0)
        slider:SetValue(GetDB("scale"))
        slider:SetValueStep(0.1)
        slider:SetObeyStepOnDrag(true)
        slider:SetWidth(420)
        _G[slider:GetName() .. "Low"]:SetText("0.5")
        _G[slider:GetName() .. "High"]:SetText("2.0")
        _G[slider:GetName() .. "Text"]:SetText(string.format("%.1f", slider:GetValue()))
        slider:SetScript("OnValueChanged", function(self, value)
            _G[self:GetName() .. "Text"]:SetText(string.format("%.1f", value))
            StatsProDB.scale = value
            SetAllPanelsScale(value)
        end)
        PushRefresher(function()
            local v = GetDB("scale")
            slider:SetValue(v)
            _G[slider:GetName().."Text"]:SetText(string.format("%.1f", v))
        end)
        cd.y = sliderY - 50
    end

    -- Refresh rate slider — controls how often stat values recompute (seconds).
    -- Lower = smoother but more CPU; higher = less CPU but values lag behind gear/buff swaps.
    do
        local sliderY = cd.y
        local lbl = displayTab:CreateFontString(nil, "OVERLAY")
        lbl:SetFont("Fonts\\FRIZQT__.TTF", 12)
        lbl:SetPoint("TOPLEFT", cd.padX, sliderY)
        lbl:SetText("Refresh Rate (sec):")
        local slider = CreateFrame("Slider", "StatsProRefreshSlider", displayTab, "OptionsSliderTemplate")
        slider:SetPoint("TOPLEFT", cd.padX, sliderY - 18)
        slider:SetMinMaxValues(0.1, 1.0)
        slider:SetValue(GetDB("updateInterval"))
        slider:SetValueStep(0.05)
        slider:SetObeyStepOnDrag(true)
        slider:SetWidth(420)
        _G[slider:GetName() .. "Low"]:SetText("0.1s")
        _G[slider:GetName() .. "High"]:SetText("1.0s")
        _G[slider:GetName() .. "Text"]:SetText(string.format("%.2f", slider:GetValue()))
        slider:SetScript("OnValueChanged", function(self, value)
            _G[self:GetName() .. "Text"]:SetText(string.format("%.2f", value))
            StatsProDB.updateInterval = value
            CacheSettings()
        end)
        PushRefresher(function()
            local v = GetDB("updateInterval")
            slider:SetValue(v)
            _G[slider:GetName().."Text"]:SetText(string.format("%.2f", v))
        end)
        cd.y = sliderY - 50
    end

    CursorGap(cd, 6)

    -- Always-shown stats (Crit/Haste/Mastery/Vers) and format colors live here.
    -- Per-stat colors that have a toggle (Primary, Tertiary, Defensive, Durability)
    -- now live inline next to their checkbox in their respective tabs.
    CursorSection(cd, "Stat Colors")
    do
        local rowY = cd.y
        local function ColorRow(l1, k1, l2, k2)
            CreateColorPicker(displayTab, l1, k1, rowY, cd.padX)
            if l2 then CreateColorPicker(displayTab, l2, k2, rowY, cd.padX + 220) end
            rowY = rowY - 25
        end
        ColorRow("Crit",     "crit",     "Mastery",     "mastery")
        ColorRow("Haste",    "haste",    "Versatility", "versatility")
        ColorRow("Rating",   "rating",   "Percentage",  "percentage")
        cd.y = rowY
    end

    displayTab.contentHeight = CursorUsed(cd)
    displayTab:SetHeight(displayTab.contentHeight)

    --[[ ===== STATS TAB ===== ]]
    local cs = NewCursor(statsTab, 12, -8)

    -- Primary stats share one color, shown inline in section header
    CursorSection(cs, "Primary Stat Ratings", "primary")
    do
        local rowY = cs.y
        CreateCheckbox(statsTab, "StatsProStrCheck", "Show Strength",  "showStrength",  cs.padX,       rowY)
        CreateCheckbox(statsTab, "StatsProAgiCheck", "Show Agility",   "showAgility",   cs.padX + 220, rowY)
        cs.y = rowY - 26
        CreateCheckbox(statsTab, "StatsProIntCheck", "Show Intellect", "showIntellect", cs.padX,       cs.y)
        CursorAdvance(cs, 22)
    end

    CursorGap(cs, 6)

    CursorSection(cs, "Offensive Stats")
    do
        local rowY = cs.y
        -- Per-stat colors live in Display tab "Stat Colors" — don't duplicate inline swatches.
        local critCb, hasteCb, masteryCb, versCb
        local function ApplyOffensiveSubsEnabled(masterOn)
            SetCheckboxEnabled(critCb,    masterOn)
            SetCheckboxEnabled(hasteCb,   masterOn)
            SetCheckboxEnabled(masteryCb, masterOn)
            SetCheckboxEnabled(versCb,    masterOn)
        end
        CreateCheckbox(statsTab, "StatsProOffensiveCheck",  "Show Offensive Stats", "showOffensive",     cs.padX,       rowY,
            function(checked) ApplyOffensiveSubsEnabled(checked) end)
        CreateCheckbox(statsTab, "StatsProHideZeroOffCheck", "Hide Zero Values",    "hideZeroOffensive", cs.padX + 220, rowY)
        cs.y = rowY - 26
        critCb    = CreateCheckbox(statsTab, "StatsProCritCheck",    "Show Crit",        "showCrit",        cs.padX,       cs.y)
        hasteCb   = CreateCheckbox(statsTab, "StatsProHasteCheck",   "Show Haste",       "showHaste",       cs.padX + 220, cs.y)
        CursorAdvance(cs, 22)
        masteryCb = CreateCheckbox(statsTab, "StatsProMasteryCheck", "Show Mastery",     "showMastery",     cs.padX,       cs.y)
        versCb    = CreateCheckbox(statsTab, "StatsProVersCheck",    "Show Versatility", "showVersatility", cs.padX + 220, cs.y)
        CursorAdvance(cs, 22)
        ApplyOffensiveSubsEnabled(GetDB("showOffensive"))
        PushRefresher(function() ApplyOffensiveSubsEnabled(GetDB("showOffensive")) end)
    end

    CursorGap(cs, 6)

    CursorSection(cs, "Tertiary Stats")
    do
        local rowY = cs.y
        -- Sub-toggle refs captured to grey them when master is off (mirrors the
        -- dependency-disable pattern on the Defensive tab's Repair Cost / Auto-Color).
        local leechCb, avoidanceCb, speedCb
        local function ApplyTertiarySubsEnabled(masterOn)
            SetCheckboxEnabled(leechCb,     masterOn)
            SetCheckboxEnabled(avoidanceCb, masterOn)
            SetCheckboxEnabled(speedCb,     masterOn)
        end
        CreateCheckbox(statsTab, "StatsProTertiaryCheck", "Show Tertiary Stats", "showTertiary", cs.padX, rowY,
            function(checked) ApplyTertiarySubsEnabled(checked) end)
        CreateCheckbox(statsTab, "StatsProHideZeroCheck", "Hide Zero Values",    "hideZeroTertiary", cs.padX + 220, rowY)
        cs.y = rowY - 26
        -- Each tertiary stat with its own inline color swatch
        leechCb     = CreateCheckboxColor(statsTab, "StatsProLeechCheck",     "Show Leech",     "showLeech",     "leech",     cs.padX,       cs.y)
        avoidanceCb = CreateCheckboxColor(statsTab, "StatsProAvoidanceCheck", "Show Avoidance", "showAvoidance", "avoidance", cs.padX + 220, cs.y)
        CursorAdvance(cs, 22)
        speedCb     = CreateCheckboxColor(statsTab, "StatsProSpeedCheck",     "Show Speed",     "showSpeed",     "speed",     cs.padX,       cs.y)
        CursorAdvance(cs, 22)
        ApplyTertiarySubsEnabled(GetDB("showTertiary"))
        PushRefresher(function() ApplyTertiarySubsEnabled(GetDB("showTertiary")) end)
    end

    statsTab.contentHeight = CursorUsed(cs)
    statsTab:SetHeight(statsTab.contentHeight)

    --[[ ===== DEFENSIVE TAB ===== ]]
    local cdef = NewCursor(defensiveTab, 12, -8)

    CursorSection(cdef, "Defensive Stats")
    do
        local rowY = cdef.y
        -- Sub-toggle refs captured to grey them when master is off (mirrors Tertiary tab).
        local dodgeCb, parryCb, blockCb, armorCb
        local function ApplyDefensiveSubsEnabled(masterOn)
            SetCheckboxEnabled(dodgeCb, masterOn)
            SetCheckboxEnabled(parryCb, masterOn)
            SetCheckboxEnabled(blockCb, masterOn)
            SetCheckboxEnabled(armorCb, masterOn)
        end
        CreateCheckbox(defensiveTab, "StatsProDefensiveCheck",   "Show Defensive Stats", "showDefensive",     cdef.padX,       rowY,
            function(checked) ApplyDefensiveSubsEnabled(checked) end)
        CreateCheckbox(defensiveTab, "StatsProHideZeroDefCheck", "Hide Zero Values",     "hideZeroDefensive", cdef.padX + 220, rowY)
        cdef.y = rowY - 26
        -- Each defensive stat with its own inline color swatch
        dodgeCb = CreateCheckboxColor(defensiveTab, "StatsProDodgeCheck", "Show Dodge", "showDodge", "dodge", cdef.padX,       cdef.y)
        parryCb = CreateCheckboxColor(defensiveTab, "StatsProParryCheck", "Show Parry", "showParry", "parry", cdef.padX + 220, cdef.y)
        CursorAdvance(cdef, 22)
        blockCb = CreateCheckboxColor(defensiveTab, "StatsProBlockCheck", "Show Block", "showBlock", "block", cdef.padX,       cdef.y)
        armorCb = CreateCheckboxColor(defensiveTab, "StatsProArmorCheck", "Show Armor", "showArmor", "armor", cdef.padX + 220, cdef.y)
        CursorAdvance(cdef, 22)
        ApplyDefensiveSubsEnabled(GetDB("showDefensive"))
        PushRefresher(function() ApplyDefensiveSubsEnabled(GetDB("showDefensive")) end)
    end

    CursorGap(cdef, 6)

    CursorSection(cdef, "Durability")
    do
        local rowY = cdef.y
        -- WHY: Repair Cost only renders when Durability is on (it's appended to that line).
        -- Grey out the cost checkbox when durability is off so the dependency is visible.
        local repairCostCb
        local function ApplyRepairCostEnabled(durEnabled)
            SetCheckboxEnabled(repairCostCb, durEnabled)
        end
        -- Durability swatch is the override color used when Auto Color is OFF.
        -- WHY: also mark dirty so re-enabling after a long off period gets fresh values
        -- on the next tick, not whatever was cached when last enabled.
        local _, durSwatch = CreateCheckboxColor(defensiveTab, "StatsProDurabilityCheck", "Show Durability",  "showDurability", "durability", cdef.padX,       rowY,
            function(checked)
                ApplyRepairCostEnabled(checked)
                durabilityDirty = true
            end)
        repairCostCb = CreateCheckbox(defensiveTab, "StatsProRepairCostCheck", "Show Repair Cost", "showRepairCost", cdef.padX + 220, rowY)
        ApplyRepairCostEnabled(GetDB("showDurability"))
        PushRefresher(function() ApplyRepairCostEnabled(GetDB("showDurability")) end)
        cdef.y = rowY - 26
        -- WHY: durability swatch sets the override color, used only when Auto Color is OFF.
        -- Grey it out when auto-color is on so the dependency is visible.
        local function ApplyDurSwatchEnabled(autoColorOn)
            if not durSwatch then return end
            if autoColorOn then
                durSwatch:Disable()
                durSwatch:SetAlpha(0.4)
            else
                durSwatch:Enable()
                durSwatch:SetAlpha(1.0)
            end
        end
        CreateCheckbox(defensiveTab, "StatsProAutoColorCheck",
            "Auto Color by Threshold", "useAutoColorDurability", cdef.padX, cdef.y,
            function(checked) ApplyDurSwatchEnabled(checked) end)
        ApplyDurSwatchEnabled(GetDB("useAutoColorDurability"))
        PushRefresher(function() ApplyDurSwatchEnabled(GetDB("useAutoColorDurability")) end)
        CursorAdvance(cdef, 22)
        -- WHY: onChange forces recompute via dirty flag; otherwise display stays stale
        -- until the next equipment event (which may be far off).
        CreateCheckbox(defensiveTab, "StatsProWorstDurCheck",
            "Use Worst Slot (instead of average)", "useWorstDurability", cdef.padX, cdef.y,
            function() durabilityDirty = true end)
        CursorAdvance(cdef, 22)
    end

    defensiveTab.contentHeight = CursorUsed(cdef)
    defensiveTab:SetHeight(defensiveTab.contentHeight)

    --[[ ===== Reset action (in-place widget refresh, no frame rebuild) ===== ]]
    resetBtn:SetScript("OnClick", function()
        -- Step 1: close any open modal BEFORE touching DB.
        -- WHY: ColorPickerFrame:Hide() synchronously fires its registered cancelFunc
        -- which writes the pre-reset snapshot back to StatsProDB.colors[statName]. If
        -- we did DB reset first, that cancelFunc would clobber the just-reset default.
        -- Closing first means cancelFunc writes to a (soon-overwritten) DB — irrelevant.
        CloseDropDownMenus()
        if ColorPickerFrame and ColorPickerFrame:IsShown() then ColorPickerFrame:Hide() end

        -- Step 2: reset DB scalars + colors to defaults.
        for k, v in pairs(defaults) do
            if type(v) ~= "table" then StatsProDB[k] = v end
        end
        StatsProDB.colors = CopyTable(defaults.colors)
        StatsProDB.dbVersion = CURRENT_DB_VERSION

        -- Step 3: re-cache + re-apply panel-level visual state.
        CacheSettings()
        ApplyTextStyleToAllPanels(defaults.font, defaults.fontSize)
        SetAllPanelsScale(defaults.scale)
        LoadAllPositions()
        SetAllPanelsLockState(defaults.isLocked)
        UpdateStats()

        -- Step 4: re-sync config widget visuals from freshly-reset DB.
        -- WHY pcall: a buggy refresher should not break the entire walk. Print error
        -- context instead of silent fail (CLAUDE.md "Log meaningful context").
        for _, fn in ipairs(configRefreshers) do
            local ok, err = pcall(fn)
            if not ok then PrintMsg("refresher error: " .. tostring(err)) end
        end

        PrintMsg("Settings reset to defaults")
    end)

    --[[ ===== Initial state ===== ]]
    SwitchToTab(1)
end

-- Self-serve diagnostics: dump runtime state to chat for bug reports.
-- Each group is a separate PrintMsg so taint isolation is automatic
-- (per workspace CLAUDE.md "log fields as separate entries"); no API
-- here reads stat values, so taint is not actually a risk — but the
-- per-line format is also far more readable in chat than a 400-char wall.
function addon:PrintDebugDump()
    PrintMsg(string.format("debug v%s  dbVer %s/%d  isLoaded=%s  durDirty=%s  mem=%dKB",
        ADDON_VERSION,
        tostring(StatsProDB.dbVersion or "?"),
        CURRENT_DB_VERSION,
        tostring(isLoaded), tostring(durabilityDirty),
        math.floor(collectgarbage("count"))))

    PrintMsg(string.format("visible=%s  locked=%s  mode=%s  font=%dpx  scale=%.1f  refresh=%.2fs",
        tostring(cached.isVisible), tostring(cached.isLocked),
        tostring(GetDB("displayMode")),
        GetDB("fontSize"), GetDB("scale"), GetDB("updateInterval")))

    PrintMsg(string.format("show fmt: rating=%s pct=%s matchColor=%s",
        tostring(cached.showRating), tostring(cached.showPercentage), tostring(cached.matchValueColorToStat)))

    PrintMsg(string.format("locale: client=%s curated=%s toggle=%s",
        CURRENT_LOCALE, tostring(HAS_LOCALIZATION), tostring(cached.useLocalizedLabels)))

    PrintMsg(string.format("show stats: off=%s tert=%s defensive=%s dur=%s str=%s agi=%s int=%s",
        tostring(cached.showOffensive),
        tostring(cached.showTertiary), tostring(cached.showDefensive), tostring(cached.showDurability),
        tostring(cached.showStrength), tostring(cached.showAgility), tostring(cached.showIntellect)))

    PrintMsg(string.format("subs off: crit=%s haste=%s mastery=%s vers=%s",
        tostring(cached.showCrit), tostring(cached.showHaste), tostring(cached.showMastery), tostring(cached.showVersatility)))

    PrintMsg(string.format("subs: leech=%s avoid=%s speed=%s | dodge=%s parry=%s block=%s armor=%s",
        tostring(cached.showLeech), tostring(cached.showAvoidance), tostring(cached.showSpeed),
        tostring(cached.showDodge), tostring(cached.showParry), tostring(cached.showBlock), tostring(cached.showArmor)))

    -- Panel positions: nil-guard (DB may be partial in pre-PEW edge cases)
    local function PosLine(label, p, rp, x, y)
        if not p then return label..": <unset>" end
        return string.format("%s: %s/%s  %+d/%+d", label, p, rp, x or 0, y or 0)
    end
    PrintMsg(PosLine("main",      GetDB("point"),           GetDB("relativePoint"),           GetDB("xOfs"),           GetDB("yOfs")))
    PrintMsg(PosLine("defensive", GetDB("defensive_point"), GetDB("defensive_relativePoint"), GetDB("defensive_xOfs"), GetDB("defensive_yOfs")))
end

--[[ ============================================================
    16. BLIZZARD SETTINGS PANEL LAUNCHER
============================================================ ]]
local launcher = CreateFrame("Frame")
launcher.name = "StatsPro"

local launcherTitle = launcher:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
launcherTitle:SetPoint("TOPLEFT", 16, -16)
launcherTitle:SetText("StatsPro v" .. ADDON_VERSION)

local launcherDesc = launcher:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
launcherDesc:SetPoint("TOPLEFT", launcherTitle, "BOTTOMLEFT", 0, -8)
launcherDesc:SetWidth(560)
launcherDesc:SetJustifyH("LEFT")
launcherDesc:SetText("Displays your secondary, defensive stats and durability on screen. Click below to open the full settings window.")

local launcherBtn = CreateFrame("Button", nil, launcher, "UIPanelButtonTemplate")
launcherBtn:SetSize(180, 28)
launcherBtn:SetPoint("TOPLEFT", launcherDesc, "BOTTOMLEFT", 0, -16)
launcherBtn:SetText("Open Settings")
launcherBtn:SetScript("OnClick", function()
    if SettingsPanel and SettingsPanel:IsShown() then
        HideUIPanel(SettingsPanel)
    end
    addon:OpenConfigMenu()
end)

local launcherCategory = Settings.RegisterCanvasLayoutCategory(launcher, launcher.name)
Settings.RegisterAddOnCategory(launcherCategory)

--[[ ============================================================
    17. SLASH COMMANDS
============================================================ ]]
SLASH_STATSPRO1 = "/ss"
SLASH_STATSPRO2 = "/statspro"
local function SetVisible(visible)
    StatsProDB.isVisible = visible
    CacheSettings()
    UpdateStats()
    -- WHY: master Visible checkbox in config menu may be open; sync its state.
    local cb = _G["StatsProVisibleCheck"]
    if cb then cb:SetChecked(visible) end
end
SlashCmdList["STATSPRO"] = function(msg)
    local arg = (msg or ""):lower():match("^%s*(%S+)") or ""
    if arg == "show" then
        SetVisible(true)
        PrintMsg("Stats panel shown")
    elseif arg == "hide" then
        SetVisible(false)
        PrintMsg("Stats panel hidden")
    elseif arg == "toggle" then
        local newState = StatsProDB.isVisible == false
        SetVisible(newState)
        PrintMsg(newState and "Stats panel shown" or "Stats panel hidden")
    elseif arg == "debug" then
        addon:PrintDebugDump()
    elseif arg == "help" or arg == "?" then
        PrintMsg("Commands: /ss (config), /ss show, /ss hide, /ss toggle, /ss debug")
    else
        addon:OpenConfigMenu()
    end
end
