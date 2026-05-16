-- StatsPro.lua
-- Inspired by SwiftStats by TaylorSay (MIT). Boilerplate, color defaults, and the
-- basic stat list are adapted from upstream; the rest is original work. See LICENSE
-- for full attribution.
local _, addon = ...

--[[ ============================================================
    1. CONSTANTS
============================================================ ]]
local CURRENT_DB_VERSION = 9

local DURABILITY_SLOT_MIN = 1
local DURABILITY_SLOT_MAX = 19
-- WHY: slot 4 = shirt, slot 18 = deprecated ranged. Slot 19 (tabard) self-filters via max>0.
local DURABILITY_SKIP_SLOTS = { [4] = true, [18] = true }

local DURABILITY_GREEN_THRESHOLD  = 60
local DURABILITY_YELLOW_THRESHOLD = 30

local ITEM_LEVEL_WARN_DELTA = 5
local ITEM_LEVEL_DANGER_DELTA = 20
local ITEM_LEVEL_WARN_COLOR = "ffcc33"
local ITEM_LEVEL_DANGER_COLOR = "ff3333"

local GLYPH_LATIN, GLYPH_CYR, GLYPH_HANGUL, GLYPH_HANS, GLYPH_HANT =
    "Latin", "Cyrillic", "Hangul", "Hans", "Hant"

-- WHY hybrid native+English labels for non-Latin: dropdown buttons render with the
-- system font of the dropdown frame; on non-CJK clients the frame font lacks CJK
-- glyphs and "한국어" / "中文" render as `?` boxes. Adding English in parens keeps a
-- readable fallback on every client. Latin labels render universally — kept clean.
-- WARNING: LANGUAGE_OPTIONS[1] MUST be the auto entry; CurrentLabel() falls back to
-- it on unknown forceLocale values.
--
-- WHY four locale-keyed tables, two axes — read this BEFORE adding new ones:
--   * REQUIRED-BY-OUTPUT-LOCALE (what label-set we want to render):
--     LANGUAGE_OPTIONS (UI dropdown), LOCALE_GLYPH_REQ (glyph need),
--     LABELS_BY_LOCALE (label data). Indexed by `forceLocale` / output choice.
--   * PROVIDED-BY-CLIENT-LOCALE (what physical fonts THIS install ships):
--     LOCALE_NATIVE_GLYPHS (see do-block after FONT_GLYPH_SUPPORT).
--     Indexed by `GetLocale()` / client install.
-- WARNING: indexing a table by the wrong axis silently breaks coverage detection
-- on locales that need glyphs the client-shipped font can't render — labels go to
-- `?` boxes. Per-table comments below name which axis applies.
local LANGUAGE_OPTIONS = {
    { value = "auto",  label = nil },                        -- composed dynamically (Auto + native of GetLocale())
    { value = "enUS",  label = "English" },
    { value = "deDE",  label = "Deutsch" },
    { value = "esES",  label = "Español (España)" },
    { value = "esMX",  label = "Español (México)" },
    { value = "frFR",  label = "Français" },
    { value = "itIT",  label = "Italiano" },
    { value = "ptBR",  label = "Português (Brasil)" },
    { value = "koKR",  label = "한국어 (Korean)" },
    { value = "ruRU",  label = "Русский (Russian)" },
    { value = "zhCN",  label = "中文 简体 (Simplified)" },
    { value = "zhTW",  label = "中文 繁體 (Traditional)" },
}

local LOCALE_GLYPH_REQ = {
    enUS = GLYPH_LATIN, deDE = GLYPH_LATIN, esES = GLYPH_LATIN, esMX = GLYPH_LATIN,
    frFR = GLYPH_LATIN, itIT = GLYPH_LATIN, ptBR = GLYPH_LATIN,
    ruRU = GLYPH_CYR,
    koKR = GLYPH_HANGUL, zhCN = GLYPH_HANS, zhTW = GLYPH_HANT,
}

local function FontPathKey(fontPath)
    if type(fontPath) ~= "string" then return nil end
    return (fontPath:gsub("/", "\\"):lower())
end

local function SameFontPath(a, b)
    local ak, bk = FontPathKey(a), FontPathKey(b)
    return ak ~= nil and bk ~= nil and ak == bk
end

local function IsBlizzardFontPath(fontPath)
    local key = FontPathKey(fontPath)
    return key ~= nil and string.sub(key, 1, 6) == "fonts\\"
end

-- WHY two-tier coverage detection: WoW shipped TTF filenames are stable per locale
-- install (FONT_GLYPH_SUPPORT normalized exact-match, O(1) hash); LSM-registered fonts have no
-- glyph-coverage API but popular CJK families ship under predictable filenames, so
-- FONT_GLYPH_PATTERNS (below) catches NotoCJK / SourceHan / WenQuanYi / PingFang /
-- YaHei / JhengHei / SimSun / SimHei / MingLiU / Malgun / Nanum / AppleSDGothicNeo
-- by filename pattern. Unknown paths conservatively Latin-only.
--
-- WHY ARIALN universal vs FRIZQT locale-conditional: Blizzard ships ARIALN with
-- Cyrillic on EVERY non-CJK client (it's the chat/nameplate font where cross-realm
-- Russian names appear — Latin+Cyrillic is mandatory). FRIZQT, by contrast, is the
-- brand-style font with locale-specific design — ruRU FRIZQT ships proper Cyrillic
-- glyphs, but enUS / deDE / frFR / etc. FRIZQT is Latin-design (Cyrillic renders
-- via OS system font fallback — visible but ugly, mismatched kerning/stroke weights).
-- See locale-conditional do-block below for FRIZQT populating.
-- WHY GLYPH_LATIN means StatsPro's western-locale labels (not ASCII-only):
-- frFR/esES/esMX/ptBR strings include accents. LibSharedMedia documents that
-- FRIZQT___CYR misses accented European chars, so it is Cyrillic-capable but
-- intentionally NOT GLYPH_LATIN-compatible here.
local FONT_GLYPH_SUPPORT = {}
local function AddFontGlyphSupport(path, glyphs)
    FONT_GLYPH_SUPPORT[FontPathKey(path)] = glyphs
end

AddFontGlyphSupport("Fonts\\2002.ttf",         { GLYPH_LATIN, GLYPH_CYR, GLYPH_HANGUL })
AddFontGlyphSupport("Fonts\\2002B.ttf",        { GLYPH_LATIN, GLYPH_CYR, GLYPH_HANGUL })
AddFontGlyphSupport("Fonts\\ARHei.TTF",        { GLYPH_LATIN, GLYPH_CYR, GLYPH_HANS, GLYPH_HANT })
AddFontGlyphSupport("Fonts\\ARIALN.TTF",       { GLYPH_LATIN, GLYPH_CYR })
AddFontGlyphSupport("Fonts\\ARKai_C.ttf",      { GLYPH_LATIN, GLYPH_CYR, GLYPH_HANS, GLYPH_HANT })
AddFontGlyphSupport("Fonts\\ARKai_T.ttf",      { GLYPH_LATIN, GLYPH_CYR, GLYPH_HANS, GLYPH_HANT })
AddFontGlyphSupport("Fonts\\bHEI00M.ttf",      { GLYPH_HANT })
AddFontGlyphSupport("Fonts\\bHEI01B.ttf",      { GLYPH_HANT })
AddFontGlyphSupport("Fonts\\bKAI00M.ttf",      { GLYPH_HANT })
AddFontGlyphSupport("Fonts\\bLEI00D.ttf",      { GLYPH_HANT })
-- FRIZQT__.TTF populated by the locale-conditional do-block below this table.
AddFontGlyphSupport("Fonts\\FRIZQT___CYR.TTF", { GLYPH_CYR })
AddFontGlyphSupport("Fonts\\K_Damage.TTF",     { GLYPH_CYR, GLYPH_HANGUL })
AddFontGlyphSupport("Fonts\\K_Pagetext.TTF",   { GLYPH_LATIN, GLYPH_CYR, GLYPH_HANGUL })
AddFontGlyphSupport("Fonts\\MORPHEUS.TTF",     { GLYPH_LATIN })
AddFontGlyphSupport("Fonts\\MORPHEUS_CYR.TTF", { GLYPH_LATIN, GLYPH_CYR })
AddFontGlyphSupport("Fonts\\NIM_____.ttf",     { GLYPH_LATIN, GLYPH_CYR })
AddFontGlyphSupport("Fonts\\SKURRI.TTF",       { GLYPH_LATIN })
AddFontGlyphSupport("Fonts\\SKURRI_CYR.TTF",   { GLYPH_LATIN, GLYPH_CYR })

-- WHY locale-conditional FRIZQT: same path resolves to a DIFFERENT physical file
-- per client install — properly-designed Cyrillic on ruRU; on other clients Cyrillic
-- only renders via OS system fallback (mixed glyph design). MaybeAutoSwitchFont's
-- ARIALN-fallback handles the cross-locale CYR case (see ARIALN comment above).
-- CJK clients get plain Latin too; their actual CJK coverage lives in the
-- 2002/ARKai/bHEI entries above. See axis-naming comment over LANGUAGE_OPTIONS
-- for why path-keyed (provided-by-client) is the right axis here.
do
    local LOCALE_NATIVE_GLYPHS = {
        ruRU = { GLYPH_LATIN, GLYPH_CYR },
    }
    AddFontGlyphSupport("Fonts\\FRIZQT__.TTF", LOCALE_NATIVE_GLYPHS[GetLocale()] or { GLYPH_LATIN })
end

-- Per-client-shipped Blizzard font paths (drives BuildFontsList no-LSM fallback +
-- CurrentFontName reverse-lookup). FONT_GLYPH_SUPPORT above answers "what glyphs
-- at this path?"; this table answers the orthogonal "does THIS client install
-- physically ship a working file at this path?". locale=nil → universal entry
-- (every client). locale=<L> → only on the matching client install (gated by
-- GetLocale(), NOT by db.forceLocale — file-existence axis is install-bound,
-- never user-output-bound). Descriptive names mirror LSM-list convention and
-- fit the 25-char FONT_PICKER_BTN_W ceiling.
local BLIZZARD_SHIPPED_FONTS = {
    { path = "Fonts\\FRIZQT__.TTF", name = "Friz Quadrata TT" },
    { path = "Fonts\\ARIALN.TTF",   name = "Arial Narrow" },
    { path = "Fonts\\SKURRI.TTF",   name = "Skurri" },
    { path = "Fonts\\MORPHEUS.TTF", name = "Morpheus" },
    { path = "Fonts\\ARKai_T.ttf",  name = "Chinese (Simplified)",  locale = "zhCN" },
    { path = "Fonts\\bHEI00M.ttf",  name = "Chinese (Traditional)", locale = "zhTW" },
    { path = "Fonts\\2002.ttf",     name = "Korean",                locale = "koKR" },
}

-- WHY ordered list (not hash like FONT_GLYPH_SUPPORT): patterns are first-match-wins,
-- broader/universal-coverage families first. Path basename is lowercased before match
-- (Lua 5.1 string.lower is byte-based; safe for ASCII font filenames). Each pattern
-- requires a script qualifier (cjk, sourcehan, hei, sun, yahei, msyh, msjh, mingliu,
-- pingfang, gothic, nanum, wqy/wenquanyi, applesdgothicneo) — guards against false-
-- positives on plain "Noto Mono" / "Source Sans" Latin-only fonts and addon-folder
-- substrings. WARNING: patterns are Lua patterns — escape % + - ? . ( ) [ ] $ ^ if
-- adding a literal special char in a future pattern.
local FONT_GLYPH_PATTERNS = {
    -- Adobe / Google universal CJK (documented Latin + Cyrillic + full CJK coverage)
    { pattern = "noto.*cjk",        glyphs = { GLYPH_LATIN, GLYPH_CYR, GLYPH_HANS, GLYPH_HANT, GLYPH_HANGUL } },
    { pattern = "sourcehan",        glyphs = { GLYPH_LATIN, GLYPH_CYR, GLYPH_HANS, GLYPH_HANT, GLYPH_HANGUL } },
    -- Open-source CN+TW
    { pattern = "wenquanyi",        glyphs = { GLYPH_LATIN, GLYPH_HANS, GLYPH_HANT } },
    { pattern = "wqy",              glyphs = { GLYPH_LATIN, GLYPH_HANS, GLYPH_HANT } },
    -- Apple macOS Chinese (PingFang covers SC+TC; HANGUL via separate font)
    { pattern = "pingfang",         glyphs = { GLYPH_LATIN, GLYPH_HANS, GLYPH_HANT } },
    -- Microsoft Windows Simplified Chinese
    { pattern = "yahei",            glyphs = { GLYPH_LATIN, GLYPH_HANS } },
    { pattern = "msyh",             glyphs = { GLYPH_LATIN, GLYPH_HANS } },
    -- Microsoft Windows Traditional Chinese
    { pattern = "msjh",             glyphs = { GLYPH_LATIN, GLYPH_HANT } },
    -- Legacy / classical Windows Chinese
    { pattern = "simsun",           glyphs = { GLYPH_LATIN, GLYPH_HANS } },
    { pattern = "simhei",           glyphs = { GLYPH_LATIN, GLYPH_HANS } },
    { pattern = "mingliu",          glyphs = { GLYPH_LATIN, GLYPH_HANT } },
    -- Korean (Apple, Microsoft, Naver)
    { pattern = "applesdgothicneo", glyphs = { GLYPH_LATIN, GLYPH_HANGUL } },
    { pattern = "malgun.*gothic",   glyphs = { GLYPH_LATIN, GLYPH_HANGUL } },
    { pattern = "nanum",            glyphs = { GLYPH_LATIN, GLYPH_HANGUL } },
}

-- WHY load-time sanity: catches FONT_GLYPH_PATTERNS typos (e.g. nono.*cjk) at addon
-- load, not at user-report time. Silent on success; chat warning on regression.
do
    local SAMPLES = {
        ["noto.*cjk"]        = "notosanscjk-regular.otf",
        ["sourcehan"]        = "sourcehansans-regular.otf",
        ["wenquanyi"]        = "wenquanyimicrohei.ttf",
        ["wqy"]              = "wqy-zenhei.ttc",
        ["pingfang"]         = "pingfangsc.ttf",
        ["yahei"]            = "msyahei.ttf",
        ["msyh"]             = "msyh.ttf",
        ["msjh"]             = "msjh.ttf",
        ["simsun"]           = "simsun.ttc",
        ["simhei"]           = "simhei.ttf",
        ["mingliu"]          = "mingliu.ttc",
        ["applesdgothicneo"] = "applesdgothicneo.ttc",
        ["malgun.*gothic"]   = "malgungothic.ttf",
        ["nanum"]            = "nanumgothic.ttf",
    }
    for _, p in ipairs(FONT_GLYPH_PATTERNS) do
        local sample = SAMPLES[p.pattern]
        if not (sample and string.find(sample, p.pattern)) then
            print("|cffff4444[StatsPro] FONT_GLYPH_PATTERNS regression: '"
                .. tostring(p.pattern) .. "' fails canonical sample|r")
        end
    end
end

--[[ ============================================================
    2. LIBRARIES + API SHIMS
============================================================ ]]
-- LibSharedMedia-3.0 (soft dependency - gracefully falls back if not loaded)
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- WHY: issecretvalue is 12.0+ retail; shim falsy on older clients so addon doesn't hard-error.
local issecretvalue = _G.issecretvalue or function() return false end

-- WHY hijack-guard: STANDARD_TEXT_FONT is a Blizzard global ANY addon can mutate
-- (ChonkyCharacterSheet / Tukui / ElvUI font modules / other "system font replacement"
-- addons all do). Reading it raw lets a third-party pin StatsPro's defaults, migration
-- target, fallback chain, and config UI rendering to an addon-shipped path forever.
-- Guard: trust STANDARD_TEXT_FONT only when it points to a Blizzard-shipped path
-- (`Fonts\…`). Non-Blizzard paths (`Interface\AddOns\…`) fall back to FRIZQT — the
-- localized-labels concern was always about CJK CLIENT-shipped fonts (under Fonts\),
-- not about user-installed font replacements which the user can still pick manually
-- via the Font dropdown if they want them in StatsPro specifically.
local function LocaleAwareDefaultFont()
    if IsBlizzardFontPath(STANDARD_TEXT_FONT) then
        return STANDARD_TEXT_FONT
    end
    return "Fonts\\FRIZQT__.TTF"
end

-- WHY single source of truth: Version comes from the TOC `## Version:` line, which
-- BigWigs Packager substitutes from the git tag at release build time (`@project-version@`
-- → e.g. `1.0.1`). Reading via GetAddOnMetadata means every release auto-syncs the
-- in-game settings title without a code edit. Local dev (running from source) sees the
-- literal `@project-version@` token from the unsubstituted TOC — fall back to a
-- hand-maintained constant so the title still reads e.g. `v1.0.3-dev` instead of `vdev`.
-- WARNING: bump CURRENT_RELEASE on every `git tag v*` so dev builds reflect the working base.
local CURRENT_RELEASE = "1.9.3"
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
    -- Text opacity: stored as INT 25-100 (percentage) in DB, divided by 100 on apply.
    -- WHY int-percent (not float 0..1): format-string compat with CreateConfigSlider's "%d%%".
    textAlpha = 100,
    -- Panel background alpha: stored as INT 0-80 (percentage) in DB, divided by 100 on apply.
    -- Default 0 preserves the original fully transparent HUD.
    panelBackgroundAlpha = 0,
    -- Text outline style: "none" | "outline" | "thick". Default preserves current OUTLINE text.
    textOutlineStyle = "outline",
    -- WHY LocaleAwareDefaultFont: Blizzard's locale-aware default-font global resolves
    -- to the right TTF for the current WoW client locale (CJK-supporting on zhCN/zhTW/
    -- koKR; Latin/Cyrillic-supporting elsewhere). Hardcoding FRIZQT would render
    -- localized labels (Crit / 暴击 / 치명 / etc.) as `?` boxes on CJK clients. The
    -- helper guards against font-replacement addons (Chonky, Tukui, ElvUI) that
    -- override STANDARD_TEXT_FONT to their own path — those would hijack our defaults
    -- otherwise. Falls back to FRIZQT for any non-Blizzard path.
    font = LocaleAwareDefaultFont(),
    textAlign = "RIGHT", -- DEPRECATED: kept for DB compat (v1.0+ saves still contain key); no runtime reader
    updateInterval = 0.5,
    isVisible = true,
    isLocked = false,

    -- Display mode: "flat" | "sectioned" | "split"
    displayMode = "flat",
    labelStyle = "full",

    -- Split routing: when displayMode="split", checked blocks move to the side panel.
    -- Defaults preserve the original split behavior (main = character/offense/tertiary,
    -- side = defensive/gear).
    splitCharacter = false,
    splitItemLevel = true,
    splitOffensive = false,
    splitTertiary = false,
    splitDefensive = true,
    splitDurability = true,
    splitRepairCost = true,

    -- WHY forceLocale (string) replaces the prior boolean useLocalizedLabels:
    -- "auto" follows GetLocale(); explicit value ("enUS", "ruRU", ..., "zhTW") forces
    -- panels to that locale regardless of WoW client. Auto-switches font if needed
    -- (see MaybeAutoSwitchFont). Migration v4→v5 maps legacy useLocalizedLabels=false
    -- to forceLocale="enUS"; anything else to "auto". The dropdown is shown on every
    -- client locale (replacing the prior HAS_LOCALIZATION-gated checkbox) — useful
    -- even on enUS for picking 中文 / 한국어 etc. for screenshots.
    forceLocale = "auto",

    -- Defensive panel position
    defensive_point = "CENTER",
    defensive_relativePoint = "CENTER",
    defensive_xOfs = 0,
    defensive_yOfs = -100,

    -- Display formatting
    showRating = false,
    showPercentage = true,
    matchValueColorToStat = false,
    targetSnapshot = "mythicPlus",

    -- Tertiary stats
    showTertiary = false,
    hideZeroTertiary = true,
    showLeech = true,
    showAvoidance = true,
    showSpeed = true,

    -- Primary stat: Show Main Stat (auto-resolves from spec) + Show Stamina (independent —
    -- no spec uses Stamina as primary). Item Level remains a separate gear-summary row,
    -- not a rated stat.
    showMainStat = false,
    showStamina  = false,
    showItemLevel = false,

    -- Defensive stats
    showDefensive = false,
    hideZeroDefensive = true,
    showDodge = true,
    showParry = true,
    showBlock = true,
    showArmor = true,
    showStagger = false,

    -- Offensive stats
    showOffensive = true,
    hideZeroOffensive = false,  -- combat ratings rarely 0; opt-in only (Vers may legit hit 0)
    showCrit = true,
    showHaste = true,
    showMastery = true,
    showVersatility = true,

    -- Durability / repair
    showDurability = false,
    showRepairCost = false,
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
        mainStat    = { r = 1,    g = 0.84, b = 0 },
        stamina     = { r = 0.5,  g = 1,    b = 0.5 },
        itemLevel   = { r = 0.55, g = 0.85, b = 1 },
        -- Defensive colors
        dodge       = { r = 0.4,  g = 0.7,  b = 1 },
        parry       = { r = 1,    g = 0.4,  b = 0.2 },
        block       = { r = 0.7,  g = 0.5,  b = 0.3 },
        armor       = { r = 0.6,  g = 0.6,  b = 0.7 },
        stagger     = { r = 0.3,  g = 0.8,  b = 0.5 },
        durability  = { r = 1,    g = 1,    b = 1 },
    },
}

--[[ ============================================================
    4. STAT DEFINITION TABLES (data-driven; UpdateStats iterates these)
============================================================ ]]
local OFFENSIVE_STATS = {
    { statKey = "crit",    label = "Crit",    api = GetCritChance,    ratingCR = CR_CRIT_MELEE,  colorKey = "crit",    showKey = "showCrit"    },
    { statKey = "haste",   label = "Haste",   api = GetHaste,         ratingCR = CR_HASTE_MELEE, colorKey = "haste",   showKey = "showHaste"   },
    { statKey = "mastery", label = "Mastery", api = GetMasteryEffect, ratingCR = CR_MASTERY,     colorKey = "mastery", showKey = "showMastery" },
    -- versatility handled specially (dual-source: rating + flat); gated by showVersatility
}

-- Primary stat label + unitStatId mapping. Used by BuildCharacterLines via the
-- PRIMARY_STATS_BY_ID O(1) lookup. label routes through L() for locale render.
local PRIMARY_STATS = {
    { label = "Strength",  unitStatId = 1 },
    { label = "Agility",   unitStatId = 2 },
    { label = "Intellect", unitStatId = 4 },
}

-- O(1) lookup by unitStatId (1=Str, 2=Agi, 4=Int) for BuildCharacterLines.
local PRIMARY_STATS_BY_ID = {}
for _, def in ipairs(PRIMARY_STATS) do
    PRIMARY_STATS_BY_ID[def.unitStatId] = def
end

-- Stamina is unitStatId 3 — excluded from PRIMARY_STATS / PRIMARY_STATS_BY_ID because
-- GetCurrentMainStatId never returns 3 (no spec uses Stamina as primary).
local STAMINA_UNIT_STAT_ID = 3

-- WHY shim: C_SpecializationInfo.* is the modern API in 12.x retail; legacy
-- GetSpecialization* deprecated since 11.2 and may be removed in 13.x. Defensive
-- chain mirrors the C_AddOns.GetAddOnMetadata-or-GetAddOnMetadata pattern used for ADDON_VERSION.
local function SafeGetSpecIndex()
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then
        return C_SpecializationInfo.GetSpecialization()
    end
    return GetSpecialization and GetSpecialization() or nil
end

local function SafeGetSpecInfo(idx)
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo then
        return C_SpecializationInfo.GetSpecializationInfo(idx)
    end
    return GetSpecializationInfo and GetSpecializationInfo(idx) or nil
end

-- Returns 1 (Str) / 2 (Agi) / 4 (Int) or nil (no spec selected — sub-10 alts /
-- pre-PEW edge / API stub in older clients). Per-render lookup (no caching) — matches
-- the no-spec-event-handler architecture (UpdateStats re-reads every tick anyway).
local function GetCurrentMainStatId()
    local idx = SafeGetSpecIndex()
    if not idx then return nil end
    local _, _, _, _, _, primaryStat = SafeGetSpecInfo(idx)
    return primaryStat
end

addon.archonTargets = addon.archonTargets or {}
addon.archonTargets.defaultSnapshotKey = "mythicPlus"
addon.archonTargets.snapshotOptions = {
    { value = "mythicPlus", label = "Mythic+" },
    { value = "raid",       label = "Raid" },
}
local cached

addon.archonTargets.specKeyByID = {
    [250] = "blood", [251] = "frost", [252] = "unholy",
    [577] = "havoc", [581] = "vengeance", [1480] = "devourer",
    [102] = "balance", [103] = "feral", [104] = "guardian", [105] = "restoration",
    [1467] = "devastation", [1468] = "preservation", [1473] = "augmentation",
    [253] = "beast-mastery", [254] = "marksmanship", [255] = "survival",
    [62] = "arcane", [63] = "fire", [64] = "frost",
    [268] = "brewmaster", [269] = "windwalker", [270] = "mistweaver",
    [65] = "holy", [66] = "protection", [70] = "retribution",
    [256] = "discipline", [257] = "holy", [258] = "shadow",
    [259] = "assassination", [260] = "outlaw", [261] = "subtlety",
    [262] = "elemental", [263] = "enhancement", [264] = "restoration",
    [265] = "affliction", [266] = "demonology", [267] = "destruction",
    [71] = "arms", [72] = "fury", [73] = "protection",
}

function addon.archonTargets.GetCurrentClassToken()
    local _, classToken = UnitClass("player")
    return classToken
end

function addon.archonTargets.GetCurrentSpecKey()
    local idx = SafeGetSpecIndex()
    if not idx then return nil end
    local specID = SafeGetSpecInfo(idx)
    return specID and addon.archonTargets.specKeyByID[specID] or nil
end

function addon.archonTargets.NormalizeSnapshotKey(value)
    if value == "raid" then return "raid" end
    return addon.archonTargets.defaultSnapshotKey
end

function addon.archonTargets.GetRootSnapshot(snapshotKey)
    local root = _G.StatsProArchonTargets
    if type(root) ~= "table" then return nil end
    local normalizedKey = addon.archonTargets.NormalizeSnapshotKey(snapshotKey)
    if root.schemaVersion == 2 then
        local snapshots = root.snapshots
        local snapshotRoot = type(snapshots) == "table" and snapshots[normalizedKey] or nil
        if type(snapshotRoot) ~= "table" and normalizedKey ~= addon.archonTargets.defaultSnapshotKey then
            normalizedKey = addon.archonTargets.defaultSnapshotKey
            snapshotRoot = type(snapshots) == "table" and snapshots[normalizedKey] or nil
        end
        if type(snapshotRoot) ~= "table" then return nil end
        return snapshotRoot, root, normalizedKey
    end
    if root.schemaVersion == 1 then
        return root, root, addon.archonTargets.defaultSnapshotKey
    end
    return nil
end

function addon.archonTargets.GetSnapshotLabel(snapshotRoot, snapshotKey)
    if type(snapshotRoot) == "table" and type(snapshotRoot.label) == "string" and snapshotRoot.label ~= "" then
        return snapshotRoot.label
    end
    if snapshotKey == "raid" then return "Raid Mythic All Bosses" end
    return "M+ High Keys"
end

function addon.archonTargets.GetSnapshotTitle(snapshotRoot, snapshotKey)
    if type(snapshotRoot) == "table" and type(snapshotRoot.title) == "string" and snapshotRoot.title ~= "" then
        return snapshotRoot.title
    end
    if snapshotKey == "raid" then return "Raid Target" end
    return "M+ Target"
end

function addon.archonTargets.GetSnapshot(classToken, specKey, snapshotKey)
    local snapshotRoot, root, normalizedKey = addon.archonTargets.GetRootSnapshot(snapshotKey)
    if not snapshotRoot then return nil end
    local specs = snapshotRoot.specs
    if type(specs) ~= "table" then return nil end
    local classData = specs[classToken]
    if type(classData) ~= "table" then return nil end
    local specData = classData[specKey]
    if type(specData) ~= "table" then return nil end
    return specData, snapshotRoot, root, normalizedKey
end

function addon.archonTargets.GetCurrentSnapshot()
    return addon.archonTargets.GetSnapshot(addon.archonTargets.GetCurrentClassToken(), addon.archonTargets.GetCurrentSpecKey(), cached.targetSnapshot)
end

function addon.archonTargets.GetStatTarget(statKey)
    local snapshot, snapshotRoot, root, snapshotKey = addon.archonTargets.GetCurrentSnapshot()
    local targets = snapshot and snapshot.targets
    local target = type(targets) == "table" and targets[statKey] or nil
    if type(target) ~= "number" or issecretvalue(target)
        or target ~= target or target <= 0 or target >= math.huge then return nil end
    return target, snapshot, snapshotRoot, root, snapshotKey
end

function addon.archonTargets.BuildMeta(statKey, currentRating, ratingCR, currentPct, colorKey)
    if type(currentRating) ~= "number" or issecretvalue(currentRating)
        or currentRating ~= currentRating or currentRating < 0 or currentRating >= math.huge then return nil end
    local target, snapshot, snapshotRoot, _, snapshotKey = addon.archonTargets.GetStatTarget(statKey)
    if not target then return nil end
    local displayPct = (type(currentPct) == "number" and not issecretvalue(currentPct)
        and currentPct == currentPct and currentPct > -math.huge and currentPct < math.huge) and currentPct or nil
    return {
        statKey = statKey,
        colorKey = colorKey or statKey,
        ratingCR = ratingCR,
        target = target,
        current = currentRating,
        currentPct = displayPct,
        delta = currentRating - target,
        sourceUrl = snapshot.sourceUrl,
        capturedAt = snapshotRoot.capturedAt,
        snapshotKey = snapshotKey,
        snapshotLabel = addon.archonTargets.GetSnapshotLabel(snapshotRoot, snapshotKey),
        snapshotTitle = addon.archonTargets.GetSnapshotTitle(snapshotRoot, snapshotKey),
        activity = snapshotRoot.activity,
        bracket = snapshotRoot.bracket,
        dungeon = snapshotRoot.dungeon,
        difficulty = snapshotRoot.difficulty,
        boss = snapshotRoot.boss,
        window = snapshotRoot.window,
    }
end

local function PlayerCanBlock()
    local _, classToken = UnitClass("player")
    return classToken == "PALADIN" or classToken == "SHAMAN" or classToken == "WARRIOR"
end

local function IsBrewmasterSpec()
    local _, classToken = UnitClass("player")
    if classToken ~= "MONK" then return false end
    local idx = SafeGetSpecIndex()
    if not idx then return false end
    local specID = SafeGetSpecInfo(idx)
    return specID == 268
end

local function GetStaggerChance()
    if not IsBrewmasterSpec() then return nil end
    if not C_PaperDollInfo or not C_PaperDollInfo.GetStaggerPercentage then return nil end
    local ok, stagger = pcall(C_PaperDollInfo.GetStaggerPercentage, "player")
    if not ok then return nil end
    if issecretvalue(stagger) then return stagger end
    if type(stagger) ~= "number" or stagger ~= stagger or stagger < 0 or stagger == math.huge then return nil end
    return stagger
end

local DEFENSIVE_STATS = {
    { label = "Dodge",   api = GetDodgeChance,    colorKey = "dodge",   showKey = "showDodge" },
    { label = "Parry",   api = GetParryChance,    colorKey = "parry",   showKey = "showParry" },
    { label = "Block",   api = GetBlockChance,    colorKey = "block",   showKey = "showBlock",   appliesFn = PlayerCanBlock },
    { label = "Stagger", api = GetStaggerChance,  colorKey = "stagger", showKey = "showStagger", appliesFn = IsBrewmasterSpec },
    -- Armor & DR handled specially: armor = absolute number, DR = cached arithmetic
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
    "showMainStat", "showStamina", "showItemLevel",
    -- Defensive & durability:
    "showDefensive", "hideZeroDefensive",
    "showDodge", "showParry", "showBlock", "showArmor", "showStagger",
    "showDurability", "showRepairCost", "useAutoColorDurability", "useWorstDurability",
    -- Split routing:
    "splitCharacter", "splitItemLevel", "splitOffensive", "splitTertiary",
    "splitDefensive", "splitDurability", "splitRepairCost",
}

--[[ ============================================================
    6. SAVED VARIABLES + RUNTIME STATE
============================================================ ]]
if type(StatsProDB) ~= "table" then StatsProDB = {} end

local function EnsureStatsProDBTable()
    if type(StatsProDB) ~= "table" then StatsProDB = {} end
    return StatsProDB
end

-- Legacy-DB carry-forward runs in OnPlayerEnteringWorld (section 13) — NOT here at
-- file scope. Two sources are checked:
--   * `_G.SwiftStatsDB` — the original public SwiftStats by TaylorSay (the upstream
--     this addon was inspired by); covers the common case of a user moving from the
--     CurseForge upstream to StatsPro.
--   * `_G.SwiftStatsLocalDB` — fallback for an earlier internal name of this addon
--     (renamed to StatsPro before publication); a tiny audience.
-- WoW loads addon SavedVariables alongside the addon's code in alphabetical folder-
-- name order. StatsPro loads BEFORE either source addon, so at file scope the source
-- globals are still nil. By PEW every enabled addon's SavedVariables are loaded; the
-- check fires reliably regardless of load order.

cached = {
    colorStrings = {},
    -- WHY {}: cached table inits at file scope BEFORE LABELS_BY_LOCALE declaration
    -- (sect 6 vs sect 7). Empty table fallback gives identity-map L() behavior
    -- (table[key]=nil; "nil or englishKey" returns the English key) — safe for any
    -- L()-using code that runs pre-CacheSettings at config build time before PEW.
    -- CacheSettings overwrites with real LABELS_BY_LOCALE entry at PEW.
    -- WARNING: never mutate; treat read-only.
    activeLabels = {},
    activeLabelsLocale = "enUS",
    -- WARNING: versatility / armor reads taint in combat — cache clean values,
    -- reuse cached value during combat. Vers starts unknown so cold-start
    -- secret/nil reads do not render as a real 0.0%.
    versTotal = nil,
    versTotalRating = 0,
    armorDR = 0,
    itemLevelOverall = nil,
    itemLevelEquipped = nil,
    durabilityValue = 100,  -- holds avg or min depending on cached.useWorstDurability
    repairCost = 0,         -- live repair cost in copper (sum from per-slot tooltip scan)
    -- WARNING: GetUnitSpeed returns secret values in combat → math.max taints. Cache OOC.
    speedPct = 0,
    displayMode = "flat",
    labelStyle = "full",
    targetSnapshot = "mythicPlus",
    updateInterval = 0.5,
}

-- Dirty flag for event-driven cache refresh (durability scan is per-19-slot, not free)
local durabilityDirty = true
-- Dirty flag for item-level refresh (overall iLvl can change from gear or bags)
local itemLevelDirty = true
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
-- to enUS via the `or LABELS_BY_LOCALE.enUS` selector in CacheSettings — panels
-- silently render English labels for the unsupported locale.
--
-- LOAD-BEARING INVARIANT: LABELS_BY_LOCALE.enUS MUST exist as the universal
-- fallback. Removing it breaks every L() call when forceLocale resolves to a
-- locale missing from this table.
--
-- WARNING: keys MUST match exactly the English literals used at the call sites:
--   - def.label values from OFFENSIVE_STATS / DEFENSIVE_STATS / PRIMARY_STATS /
--     TERTIARY_STATS (section 4)
--   - hardcoded literals in special-case branches: "Vers" / "Speed" / "Armor"
--     (additive rows for dual-source stats not in the loop tables)
--   - "Durability" in BuildDurabilityLines / "Repair" in BuildRepairCostPayload
--   - section keys used by SectionHeader(): Character / Offensive / Tertiary /
--     Defensive / Gear
-- Adding a new key here without updating callers is a no-op; adding a new caller
-- without a key here falls back gracefully to the English literal (`L(k) → k`).
--
-- WARNING: Armor and Defensive must be visually DISTINCT in the same locale.
-- Armor is a stat row label; Defensive is the sectioned-mode divider. Same word
-- for both makes the divider blend into the row beneath it.
local LABELS_BY_LOCALE = {
    enUS = {
        Crit = "Crit",          Haste = "Haste",        Mastery = "Mastery",    Vers = "Vers",
        Dodge = "Dodge",        Parry = "Parry",        Block = "Block",        Armor = "Armor",        Stagger = "Stagger",
        Strength = "Strength",  Agility = "Agility",    Intellect = "Intellect", Stamina = "Stamina",
        ItemLevel = "iLvl",
        Leech = "Leech",        Avoidance = "Avoidance", Speed = "Speed",
        Durability = "Durability", Repair = "Repair",
        Defensive = "Defensive",
        -- Settings UI words (config menu only, never appear on the panel itself):
        Color = "Color",
        -- ===== Settings UI strings =====
        -- Tabs (Defensive reuses the existing key above):
        ["Stats"] = "Stats", ["Layout"] = "Layout", ["Appearance"] = "Appearance",
        -- Section headers / split block labels (Durability reuses the existing key above):
        ["Character"] = "Character", ["Item Level"] = "Item Level",
        ["Offensive"] = "Offensive", ["Tertiary"] = "Tertiary",
        ["Gear"] = "Gear", ["Repair Cost"] = "Repair Cost",
        ["Side Panel"] = "Side Panel", ["Side Panel Contains"] = "Side Panel Contains",
        ["Value Display"] = "Value Display",
        ["Frame & Position"] = "Frame & Position",
        ["Typography"] = "Typography",
        ["Readability"] = "Readability",
        ["Localization"] = "Localization",
        ["Offensive Stats"] = "Offensive Stats",
        ["Tertiary Stats"] = "Tertiary Stats",
        ["Defensive Stats"] = "Defensive Stats",
        -- Checkboxes:
        ["Show Stats Panel"] = "Show Stats Panel", ["Lock Frames"] = "Lock Frames",
        ["Show Main Stat"] = "Show Main Stat",
        ["Show Stamina"] = "Show Stamina",
        ["Show Item Level"] = "Show Item Level",
        ["Show Rating"] = "Show Rating", ["Show Percentage"] = "Show Percentage",
        ["Match Value Color to Stat"] = "Match Value Color to Stat",
        ["Show Offensive Stats"] = "Show Offensive Stats", ["Hide Zero Values"] = "Hide Zero Values",
        ["Show Crit"] = "Show Crit", ["Show Haste"] = "Show Haste",
        ["Show Mastery"] = "Show Mastery", ["Show Versatility"] = "Show Versatility",
        ["Show Tertiary Stats"] = "Show Tertiary Stats",
        ["Show Leech"] = "Show Leech", ["Show Avoidance"] = "Show Avoidance", ["Show Speed"] = "Show Speed",
        ["Show Defensive Stats"] = "Show Defensive Stats",
        ["Show Dodge"] = "Show Dodge", ["Show Parry"] = "Show Parry",
        ["Show Block"] = "Show Block", ["Show Armor"] = "Show Armor", ["Show Stagger"] = "Show Stagger",
        ["Show Durability"] = "Show Durability", ["Show Repair Cost"] = "Show Repair Cost",
        ["Auto Color by Threshold"] = "Auto Color by Threshold",
        ["Use Worst Slot (instead of average)"] = "Use Worst Slot (instead of average)",
        -- Sliders:
        ["Scale:"] = "Scale:", ["Refresh Rate (sec):"] = "Refresh Rate (sec):", ["Font Size:"] = "Font Size:", ["Text Opacity:"] = "Text Opacity:", ["Panel Background:"] = "Panel Background:",
        -- Dropdown captions:
        ["Display Mode:"] = "Display Mode:", ["Tooltip Targets:"] = "Tooltip Targets:", ["Label Style:"] = "Label Style:", ["Text Outline:"] = "Text Outline:", ["Font:"] = "Font:", ["Language:"] = "Language:",
        -- Dropdown options (Display Mode):
        ["Flat"] = "Flat", ["Sectioned"] = "Sectioned", ["Split"] = "Split",
        ["Mythic+"] = "Mythic+", ["Raid"] = "Raid",
        ["Full"] = "Full", ["Short"] = "Short", ["Hidden"] = "Hidden",
        ["None"] = "None", ["Outline"] = "Outline", ["Thick Outline"] = "Thick Outline",
        ["M+ Target"] = "M+ Target", ["Raid Target"] = "Raid Target",
        ["M+ High Keys"] = "M+ High Keys", ["Raid Mythic All Bosses"] = "Raid Mythic All Bosses",
        ["Target:"] = "Target:", ["Current:"] = "Current:", ["Missing:"] = "Missing:",
        ["Over:"] = "Over:", ["Matched:"] = "Matched:", ["Snapshot:"] = "Snapshot:",
        ["Stats panel shown"] = "Stats panel shown", ["Stats panel hidden"] = "Stats panel hidden",
        ["Settings reset to defaults"] = "Settings reset to defaults",
        ["Commands: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug"] = "Commands: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug",
        -- Buttons + title:
        ["Reset to Defaults"] = "Reset to Defaults", ["Close"] = "Close",
        ["Open Settings"] = "Open Settings", ["Settings"] = "Settings",
        -- Templates:
        ["Auto (current: %s)"] = "Auto (current: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage.",
        -- Launcher description:
        ["Displays your secondary, defensive stats and durability on screen. Click below to open the full settings window."] = "Displays your secondary, defensive stats and durability on screen. Click below to open the full settings window.",
    },

    -- ruRU: Russian. Haste/Speed disambig is structural — WoW client uses "Скорость"
    -- for BOTH stats, so we transliterate Haste as "Хаст" (community shorthand) to free
    -- "Скор" for Speed. Leech uses "Вамп" (вампиризм) over the literal "Кров" because
    -- "Кров…" risks being mis-read as "Кровотечение" (Bleed). All stat rows use 4-char
    -- forms where the language allows; "Сила" / "Блок" / "Крит" are already 4 chars.
    ruRU = {
        Crit = "Крит",          Haste = "Хаст",         Mastery = "Маст",       Vers = "Унив",
        Dodge = "Укл",          Parry = "Пари",         Block = "Блок",         Armor = "Брон",         Stagger = "Пошат",
        Strength = "Сила",      Agility = "Ловк",       Intellect = "Инт",      Stamina = "Выно",
        ItemLevel = "УрП",
        Leech = "Вамп",         Avoidance = "Избег",    Speed = "Скор",
        Durability = "Проч",    Repair = "Рем",
        Defensive = "Защита",
        Color = "Цвет",
        -- ===== Settings UI =====
        -- Tabs (Defensive uses "Защита" via the existing key above):
        ["Stats"] = "Статы", ["Layout"] = "Макет", ["Appearance"] = "Внешний вид",
        -- Section headers / split block labels (Durability reuses "Проч" — short form):
        ["Character"] = "Персонаж", ["Item Level"] = "Уровень предметов",
        ["Offensive"] = "Атака", ["Tertiary"] = "Третичные",
        ["Gear"] = "Экипировка", ["Repair Cost"] = "Стоимость ремонта",
        ["Side Panel"] = "Боковая панель", ["Side Panel Contains"] = "В боковой панели",
        ["Value Display"] = "Отображение значений",
        ["Frame & Position"] = "Окно и позиция",
        ["Typography"] = "Типографика",
        ["Readability"] = "Читаемость",
        ["Localization"] = "Локализация",
        ["Offensive Stats"] = "Атакующие характеристики",
        ["Tertiary Stats"] = "Третичные характеристики",
        ["Defensive Stats"] = "Защитные характеристики",
        -- Checkboxes:
        ["Show Stats Panel"] = "Показать панель статов", ["Lock Frames"] = "Закрепить окна",
        ["Show Main Stat"] = "Показывать мейн-стат",
        ["Show Stamina"] = "Показывать Выносливость",
        ["Show Item Level"] = "Показывать уровень предметов",
        ["Show Rating"] = "Показывать рейтинг", ["Show Percentage"] = "Показывать процент",
        ["Match Value Color to Stat"] = "Цвет значения по характеристике",
        ["Show Offensive Stats"] = "Показывать атакующие", ["Hide Zero Values"] = "Скрывать нулевые значения",
        ["Show Crit"] = "Показывать Крит", ["Show Haste"] = "Показывать Хаст",
        ["Show Mastery"] = "Показывать Мастерство", ["Show Versatility"] = "Показывать Универсальность",
        ["Show Tertiary Stats"] = "Показывать третичные",
        ["Show Leech"] = "Показывать Вампиризм", ["Show Avoidance"] = "Показывать Избегание", ["Show Speed"] = "Показывать Скорость",
        ["Show Defensive Stats"] = "Показывать защитные",
        ["Show Dodge"] = "Показывать Уклонение", ["Show Parry"] = "Показывать Парирование",
        ["Show Block"] = "Показывать Блок", ["Show Armor"] = "Показывать Броню", ["Show Stagger"] = "Показывать Пошатывание",
        ["Show Durability"] = "Показывать прочность", ["Show Repair Cost"] = "Показывать стоимость ремонта",
        ["Auto Color by Threshold"] = "Авто-цвет по порогу",
        ["Use Worst Slot (instead of average)"] = "По худшему слоту (вместо среднего)",
        -- Sliders:
        ["Scale:"] = "Масштаб:", ["Refresh Rate (sec):"] = "Частота обновления (сек):", ["Font Size:"] = "Размер шрифта:", ["Text Opacity:"] = "Прозрачность текста:", ["Panel Background:"] = "Фон панели:",
        -- Dropdown captions:
        ["Display Mode:"] = "Режим отображения:", ["Tooltip Targets:"] = "Цели в подсказке:", ["Label Style:"] = "Стиль меток:", ["Text Outline:"] = "Контур текста:", ["Font:"] = "Шрифт:", ["Language:"] = "Язык:",
        -- Dropdown options (Display Mode):
        ["Flat"] = "Плоский", ["Sectioned"] = "По секциям", ["Split"] = "Разделённый",
        ["Mythic+"] = "Мифик+", ["Raid"] = "Рейд",
        ["Full"] = "Полный", ["Short"] = "Короткий", ["Hidden"] = "Скрытый",
        ["None"] = "Нет", ["Outline"] = "Контур", ["Thick Outline"] = "Толстый контур",
        ["M+ Target"] = "Цель M+", ["Raid Target"] = "Цель рейда",
        ["M+ High Keys"] = "M+ высокие ключи", ["Raid Mythic All Bosses"] = "Эпох. рейд, все боссы",
        ["Target:"] = "Цель:", ["Current:"] = "Сейчас:", ["Missing:"] = "Не хватает:",
        ["Over:"] = "Сверх:", ["Matched:"] = "Совпало:", ["Snapshot:"] = "Снимок:",
        ["Stats panel shown"] = "Панель статов показана", ["Stats panel hidden"] = "Панель статов скрыта",
        ["Settings reset to defaults"] = "Настройки сброшены по умолчанию",
        ["Commands: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug"] = "Команды: /ss (настройки), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug",
        -- Buttons + title:
        ["Reset to Defaults"] = "Сбросить настройки", ["Close"] = "Закрыть",
        ["Open Settings"] = "Открыть настройки", ["Settings"] = "Настройки",
        -- Templates:
        ["Auto (current: %s)"] = "Авто (сейчас: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r Шрифт может не отображать символы %s. Выберите шрифт SharedMedia с нужным покрытием.",
        -- Launcher description:
        ["Displays your secondary, defensive stats and durability on screen. Click below to open the full settings window."] = "Отображает вторичные, защитные характеристики и прочность экипировки на экране. Нажмите ниже, чтобы открыть окно настроек.",
    },

    -- deDE: German. Haste="Tempo" matches the WoW German client term; Speed="Lauf"
    -- (run-speed) keeps the Haste/Speed split clear. Vers="Viels" evokes Vielseitigkeit
    -- without colliding with the everyday word "viel" (many/much). Durability="Haltb"
    -- avoids collision with the everyday word "Halt" (stop). Strength="Stär" preserves
    -- the umlaut character of Stärke at 4 chars (single char "Stä" reads truncated).
    deDE = {
        Crit = "Krit",          Haste = "Tempo",        Mastery = "Meist",      Vers = "Viels",
        Dodge = "Ausw",         Parry = "Par",          Block = "Block",        Armor = "Rüst",         Stagger = "Staff",
        Strength = "Stär",      Agility = "Bew",        Intellect = "Int",      Stamina = "Aus",
        ItemLevel = "GS",
        Leech = "Saug",         Avoidance = "Verm",     Speed = "Lauf",
        Durability = "Haltb",   Repair = "Repar",
        Defensive = "Defensiv",
        Color = "Farbe",
        -- ===== Settings UI (best-effort draft, native-speaker review welcome via Issues) =====
        -- Speed checkbox uses "Lauftempo" (long form) to disambiguate from Haste="Tempo".
        ["Stats"] = "Werte", ["Layout"] = "Layout", ["Appearance"] = "Darstellung",
        ["Character"] = "Charakter", ["Item Level"] = "Gegenstandsstufe",
        ["Offensive"] = "Offensiv", ["Tertiary"] = "Tertiär",
        ["Gear"] = "Ausrüstung", ["Repair Cost"] = "Reparaturkosten",
        ["Side Panel"] = "Seitenpanel", ["Side Panel Contains"] = "Seitenpanel enthält",
        ["Value Display"] = "Werteanzeige",
        ["Frame & Position"] = "Fenster & Position",
        ["Typography"] = "Typografie",
        ["Readability"] = "Lesbarkeit",
        ["Localization"] = "Lokalisierung",
        ["Offensive Stats"] = "Offensivwerte",
        ["Tertiary Stats"] = "Tertiärwerte",
        ["Defensive Stats"] = "Defensivwerte",
        ["Show Stats Panel"] = "Wertepanel anzeigen", ["Lock Frames"] = "Fenster sperren",
        ["Show Main Stat"] = "Hauptattribut anzeigen",
        ["Show Stamina"] = "Ausdauer anzeigen",
        ["Show Item Level"] = "Gegenstandsstufe anzeigen",
        ["Show Rating"] = "Wertung anzeigen", ["Show Percentage"] = "Prozent anzeigen",
        ["Match Value Color to Stat"] = "Wertfarbe wie Statfarbe",
        ["Show Offensive Stats"] = "Offensivwerte anzeigen", ["Hide Zero Values"] = "Nullwerte ausblenden",
        ["Show Crit"] = "Krit. anzeigen", ["Show Haste"] = "Tempo anzeigen",
        ["Show Mastery"] = "Meisterschaft anzeigen", ["Show Versatility"] = "Vielseitigkeit anzeigen",
        ["Show Tertiary Stats"] = "Tertiärwerte anzeigen",
        ["Show Leech"] = "Aussaugen anzeigen", ["Show Avoidance"] = "Vermeidung anzeigen", ["Show Speed"] = "Lauftempo anzeigen",
        ["Show Defensive Stats"] = "Defensivwerte anzeigen",
        ["Show Dodge"] = "Ausweichen anzeigen", ["Show Parry"] = "Parieren anzeigen",
        ["Show Block"] = "Blocken anzeigen", ["Show Armor"] = "Rüstung anzeigen", ["Show Stagger"] = "Staffeln anzeigen",
        ["Show Durability"] = "Haltbarkeit anzeigen", ["Show Repair Cost"] = "Reparaturkosten anzeigen",
        ["Auto Color by Threshold"] = "Auto-Farbe nach Schwellwert",
        ["Use Worst Slot (instead of average)"] = "Schlechtester Slot (statt Durchschnitt)",
        ["Scale:"] = "Skalierung:", ["Refresh Rate (sec):"] = "Aktualisierungsrate (Sek.):", ["Font Size:"] = "Schriftgröße:", ["Text Opacity:"] = "Textdeckkraft:", ["Panel Background:"] = "Panelhintergrund:",
        ["Display Mode:"] = "Anzeigemodus:", ["Tooltip Targets:"] = "Tooltip-Ziele:", ["Label Style:"] = "Labelstil:", ["Text Outline:"] = "Textkontur:", ["Font:"] = "Schrift:", ["Language:"] = "Sprache:",
        ["Flat"] = "Flach", ["Sectioned"] = "Gruppiert", ["Split"] = "Geteilt",
        ["Mythic+"] = "Mythic+", ["Raid"] = "Raid",
        ["Full"] = "Voll", ["Short"] = "Kurz", ["Hidden"] = "Versteckt",
        ["None"] = "Keine", ["Outline"] = "Kontur", ["Thick Outline"] = "Dicke Kontur",
        ["M+ Target"] = "M+ Ziel", ["Raid Target"] = "Raid-Ziel",
        ["M+ High Keys"] = "M+ hohe Schlüssel", ["Raid Mythic All Bosses"] = "Raid Mythisch alle Bosse",
        ["Target:"] = "Ziel:", ["Current:"] = "Aktuell:", ["Missing:"] = "Fehlt:",
        ["Over:"] = "Drüber:", ["Matched:"] = "Erreicht:", ["Snapshot:"] = "Datenstand:",
        ["Stats panel shown"] = "Statpanel angezeigt", ["Stats panel hidden"] = "Statpanel ausgeblendet",
        ["Settings reset to defaults"] = "Einstellungen auf Standard zurückgesetzt",
        ["Commands: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug"] = "Befehle: /ss (Einstellungen), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug",
        ["Reset to Defaults"] = "Auf Standard", ["Close"] = "Schließen",
        ["Open Settings"] = "Einstellungen öffnen", ["Settings"] = "Einstellungen",
        ["Auto (current: %s)"] = "Auto (aktuell: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r Schrift unterstützt %s eventuell nicht. Wähle eine SharedMedia-Schrift mit Glyphenabdeckung.",
        ["Displays your secondary, defensive stats and durability on screen. Click below to open the full settings window."] = "Zeigt sekundäre, defensive Werte und Haltbarkeit auf dem Bildschirm an. Klicke unten, um das Einstellungsfenster zu öffnen.",
    },

    -- frFR: French. Hâte (4 chars, accented form) is WoW's official Haste term; Vit
    -- (Vitesse) distinct. Strength="Forc" and Durability="Dura" use 4-char forms so
    -- they don't collide with the everyday words "Fort" / "Dur". Esqu (Esquive) at 4
    -- chars reads more clearly than the truncated 3-char "Esq".
    frFR = {
        Crit = "Crit",          Haste = "Hâte",         Mastery = "Maît",       Vers = "Polyv",
        Dodge = "Esqu",         Parry = "Par",          Block = "Bloc",         Armor = "Arm",          Stagger = "Report",
        Strength = "Forc",      Agility = "Agil",       Intellect = "Int",      Stamina = "End",
        ItemLevel = "NivObj",
        Leech = "Vamp",         Avoidance = "Évit",     Speed = "Vit",
        Durability = "Dura",    Repair = "Rép",
        Defensive = "Défense",
        Color = "Couleur",
        -- ===== Settings UI (best-effort draft, native-speaker review welcome via Issues) =====
        ["Stats"] = "Stats", ["Layout"] = "Disposition", ["Appearance"] = "Apparence",
        ["Character"] = "Personnage", ["Item Level"] = "Niveau d'objet",
        ["Offensive"] = "Offensif", ["Tertiary"] = "Tertiaire",
        ["Gear"] = "Équipement", ["Repair Cost"] = "Coût de réparation",
        ["Side Panel"] = "Panneau latéral", ["Side Panel Contains"] = "Panneau latéral contient",
        ["Value Display"] = "Affichage des valeurs",
        ["Frame & Position"] = "Cadre & Position",
        ["Typography"] = "Typographie",
        ["Readability"] = "Lisibilité",
        ["Localization"] = "Localisation",
        ["Offensive Stats"] = "Stats Offensives",
        ["Tertiary Stats"] = "Stats Tertiaires",
        ["Defensive Stats"] = "Stats Défensives",
        ["Show Stats Panel"] = "Afficher le panneau", ["Lock Frames"] = "Verrouiller les cadres",
        ["Show Main Stat"] = "Afficher stat principale",
        ["Show Stamina"] = "Afficher Endurance",
        ["Show Item Level"] = "Afficher niveau d'objet",
        ["Show Rating"] = "Afficher cote", ["Show Percentage"] = "Afficher %",
        ["Match Value Color to Stat"] = "Couleur valeur = stat",
        ["Show Offensive Stats"] = "Afficher offensives", ["Hide Zero Values"] = "Masquer valeurs nulles",
        ["Show Crit"] = "Afficher Crit", ["Show Haste"] = "Afficher Hâte",
        ["Show Mastery"] = "Afficher Maîtrise", ["Show Versatility"] = "Afficher Polyvalence",
        ["Show Tertiary Stats"] = "Afficher tertiaires",
        ["Show Leech"] = "Afficher Vampirisme", ["Show Avoidance"] = "Afficher Évitement", ["Show Speed"] = "Afficher Vitesse",
        ["Show Defensive Stats"] = "Afficher défensives",
        ["Show Dodge"] = "Afficher Esquive", ["Show Parry"] = "Afficher Parade",
        ["Show Block"] = "Afficher Blocage", ["Show Armor"] = "Afficher Armure", ["Show Stagger"] = "Afficher Report",
        ["Show Durability"] = "Afficher durabilité", ["Show Repair Cost"] = "Afficher coût de réparation",
        ["Auto Color by Threshold"] = "Couleur auto par seuil",
        ["Use Worst Slot (instead of average)"] = "Pire emplacement (vs moyenne)",
        ["Scale:"] = "Échelle :", ["Refresh Rate (sec):"] = "Fréquence (sec) :", ["Font Size:"] = "Taille de police :", ["Text Opacity:"] = "Opacité du texte :", ["Panel Background:"] = "Arrière-plan du panneau :",
        ["Display Mode:"] = "Mode d'affichage :", ["Tooltip Targets:"] = "Cibles infobulle :", ["Label Style:"] = "Style d'étiquette :", ["Text Outline:"] = "Contour du texte :", ["Font:"] = "Police :", ["Language:"] = "Langue :",
        ["Flat"] = "Plat", ["Sectioned"] = "Par sections", ["Split"] = "Séparé",
        ["Mythic+"] = "Mythique+", ["Raid"] = "Raid",
        ["Full"] = "Complet", ["Short"] = "Court", ["Hidden"] = "Masqué",
        ["None"] = "Aucun", ["Outline"] = "Contour", ["Thick Outline"] = "Contour épais",
        ["M+ Target"] = "Cible M+", ["Raid Target"] = "Cible raid",
        ["M+ High Keys"] = "M+ hautes clés", ["Raid Mythic All Bosses"] = "Raid mythique tous les boss",
        ["Target:"] = "Cible :", ["Current:"] = "Actuel :", ["Missing:"] = "Manquant :",
        ["Over:"] = "Excès :", ["Matched:"] = "Atteint :", ["Snapshot:"] = "Instantané :",
        ["Stats panel shown"] = "Panneau de stats affiché", ["Stats panel hidden"] = "Panneau de stats masqué",
        ["Settings reset to defaults"] = "Paramètres réinitialisés",
        ["Commands: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug"] = "Commandes : /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug",
        ["Reset to Defaults"] = "Par défaut", ["Close"] = "Fermer",
        ["Open Settings"] = "Ouvrir les paramètres", ["Settings"] = "Paramètres",
        ["Auto (current: %s)"] = "Auto (actuel : %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r La police peut ne pas afficher les glyphes %s. Choisissez une police SharedMedia avec couverture appropriée.",
        ["Displays your secondary, defensive stats and durability on screen. Click below to open the full settings window."] = "Affiche vos statistiques secondaires, défensives et la durabilité à l'écran. Cliquez ci-dessous pour ouvrir la fenêtre de paramètres complète.",
    },

    -- esES: Spanish (Spain). WoW Spanish client uses Celeridad / Velocidad for the
    -- Haste/Speed split → Cele / Vel. Leech="Robo" matches "Robo de vida" (life steal),
    -- the WoW Spanish term — closer to client wording than the literal "Suc(ción)".
    -- Most rows use 4-char forms (Esqu / Fuer / Agil) — 3-char abbreviations look
    -- unfinished beside Spanish's typically-longer words.
    esES = {
        Crit = "Crít",          Haste = "Cele",         Mastery = "Maest",      Vers = "Versat",
        Dodge = "Esqu",         Parry = "Par",          Block = "Bloq",         Armor = "Arm",          Stagger = "Aplaz",
        Strength = "Fuer",      Agility = "Agil",       Intellect = "Int",      Stamina = "Aguante",
        ItemLevel = "NvObj",
        Leech = "Robo",         Avoidance = "Evit",     Speed = "Vel",
        Durability = "Durab",   Repair = "Rep",
        Defensive = "Defensa",
        Color = "Color",
        -- ===== Settings UI (best-effort draft, native-speaker review welcome via Issues) =====
        ["Stats"] = "Atributos", ["Layout"] = "Diseño", ["Appearance"] = "Apariencia",
        ["Character"] = "Personaje", ["Item Level"] = "Nivel de objeto",
        ["Offensive"] = "Ofensivo", ["Tertiary"] = "Terciario",
        ["Gear"] = "Equipo", ["Repair Cost"] = "Coste reparación",
        ["Side Panel"] = "Panel lateral", ["Side Panel Contains"] = "Panel lateral contiene",
        ["Value Display"] = "Valores",
        ["Frame & Position"] = "Marco y Posición",
        ["Typography"] = "Tipografía",
        ["Readability"] = "Legibilidad",
        ["Localization"] = "Localización",
        ["Offensive Stats"] = "Stats Ofensivas",
        ["Tertiary Stats"] = "Stats Terciarias",
        ["Defensive Stats"] = "Stats Defensivas",
        ["Show Stats Panel"] = "Mostrar panel", ["Lock Frames"] = "Bloquear ventanas",
        ["Show Main Stat"] = "Mostrar stat principal",
        ["Show Stamina"] = "Mostrar Aguante",
        ["Show Item Level"] = "Mostrar nivel de objeto",
        ["Show Rating"] = "Mostrar valor", ["Show Percentage"] = "Mostrar %",
        ["Match Value Color to Stat"] = "Color valor = stat",
        ["Show Offensive Stats"] = "Mostrar ofensivas", ["Hide Zero Values"] = "Ocultar valores cero",
        ["Show Crit"] = "Mostrar Crít.", ["Show Haste"] = "Mostrar Celeridad",
        ["Show Mastery"] = "Mostrar Maestría", ["Show Versatility"] = "Mostrar Versatilidad",
        ["Show Tertiary Stats"] = "Mostrar terciarias",
        ["Show Leech"] = "Mostrar Robo", ["Show Avoidance"] = "Mostrar Evitación", ["Show Speed"] = "Mostrar Velocidad",
        ["Show Defensive Stats"] = "Mostrar defensivas",
        ["Show Dodge"] = "Mostrar Esquiva", ["Show Parry"] = "Mostrar Parada",
        ["Show Block"] = "Mostrar Bloqueo", ["Show Armor"] = "Mostrar Armadura", ["Show Stagger"] = "Mostrar Aplazar",
        ["Show Durability"] = "Mostrar durabilidad", ["Show Repair Cost"] = "Mostrar coste reparación",
        ["Auto Color by Threshold"] = "Color auto por umbral",
        ["Use Worst Slot (instead of average)"] = "Peor ranura (en vez de media)",
        ["Scale:"] = "Escala:", ["Refresh Rate (sec):"] = "Frecuencia (s):", ["Font Size:"] = "Tamaño de fuente:", ["Text Opacity:"] = "Opacidad del texto:", ["Panel Background:"] = "Fondo del panel:",
        ["Display Mode:"] = "Modo:", ["Tooltip Targets:"] = "Objetivos tooltip:", ["Label Style:"] = "Estilo de etiqueta:", ["Text Outline:"] = "Contorno del texto:", ["Font:"] = "Fuente:", ["Language:"] = "Idioma:",
        ["Flat"] = "Plano", ["Sectioned"] = "Por secciones", ["Split"] = "Dividido",
        ["Mythic+"] = "Mítico+", ["Raid"] = "Banda",
        ["Full"] = "Completo", ["Short"] = "Corto", ["Hidden"] = "Oculto",
        ["None"] = "Ninguno", ["Outline"] = "Contorno", ["Thick Outline"] = "Contorno grueso",
        ["M+ Target"] = "Objetivo M+", ["Raid Target"] = "Objetivo banda",
        ["M+ High Keys"] = "M+ llaves altas", ["Raid Mythic All Bosses"] = "Banda mítica todos los jefes",
        ["Target:"] = "Objetivo:", ["Current:"] = "Actual:", ["Missing:"] = "Falta:",
        ["Over:"] = "Exceso:", ["Matched:"] = "Igualado:", ["Snapshot:"] = "Captura:",
        ["Stats panel shown"] = "Panel de estadísticas mostrado", ["Stats panel hidden"] = "Panel de estadísticas oculto",
        ["Settings reset to defaults"] = "Ajustes restablecidos",
        ["Commands: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug"] = "Comandos: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug",
        ["Reset to Defaults"] = "Restablecer", ["Close"] = "Cerrar",
        ["Open Settings"] = "Abrir ajustes", ["Settings"] = "Ajustes",
        ["Auto (current: %s)"] = "Auto (actual: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r La fuente puede no mostrar glifos %s. Elige una fuente SharedMedia con cobertura.",
        ["Displays your secondary, defensive stats and durability on screen. Click below to open the full settings window."] = "Muestra atributos secundarios, defensivos y durabilidad en pantalla. Haz clic abajo para abrir la ventana de ajustes.",
    },

    -- esMX: Latin American Spanish — stat-term short forms are effectively shared
    -- with esES (no regional split for combat stats). Mirrored 1:1 from esES table.
    esMX = {
        Crit = "Crít",          Haste = "Cele",         Mastery = "Maest",      Vers = "Versat",
        Dodge = "Esqu",         Parry = "Par",          Block = "Bloq",         Armor = "Arm",          Stagger = "Aplaz",
        Strength = "Fuer",      Agility = "Agil",       Intellect = "Int",      Stamina = "Aguante",
        ItemLevel = "NvObj",
        Leech = "Robo",         Avoidance = "Evit",     Speed = "Vel",
        Durability = "Durab",   Repair = "Rep",
        Defensive = "Defensa",
        Color = "Color",
        -- ===== Settings UI (best-effort draft — mirrors esES with regional swaps:
        --   "ajustes" → "configuración" (esMX preferred); "haz clic" → "da clic".
        ["Stats"] = "Atributos", ["Layout"] = "Diseño", ["Appearance"] = "Apariencia",
        ["Character"] = "Personaje", ["Item Level"] = "Nivel de objeto",
        ["Offensive"] = "Ofensivo", ["Tertiary"] = "Terciario",
        ["Gear"] = "Equipo", ["Repair Cost"] = "Costo reparación",
        ["Side Panel"] = "Panel lateral", ["Side Panel Contains"] = "Panel lateral contiene",
        ["Value Display"] = "Valores",
        ["Frame & Position"] = "Marco y Posición",
        ["Typography"] = "Tipografía",
        ["Readability"] = "Legibilidad",
        ["Localization"] = "Localización",
        ["Offensive Stats"] = "Stats Ofensivas",
        ["Tertiary Stats"] = "Stats Terciarias",
        ["Defensive Stats"] = "Stats Defensivas",
        ["Show Stats Panel"] = "Mostrar panel", ["Lock Frames"] = "Bloquear ventanas",
        ["Show Main Stat"] = "Mostrar stat principal",
        ["Show Stamina"] = "Mostrar Aguante",
        ["Show Item Level"] = "Mostrar nivel de objeto",
        ["Show Rating"] = "Mostrar valor", ["Show Percentage"] = "Mostrar %",
        ["Match Value Color to Stat"] = "Color valor = stat",
        ["Show Offensive Stats"] = "Mostrar ofensivas", ["Hide Zero Values"] = "Ocultar valores cero",
        ["Show Crit"] = "Mostrar Crít.", ["Show Haste"] = "Mostrar Celeridad",
        ["Show Mastery"] = "Mostrar Maestría", ["Show Versatility"] = "Mostrar Versatilidad",
        ["Show Tertiary Stats"] = "Mostrar terciarias",
        ["Show Leech"] = "Mostrar Robo", ["Show Avoidance"] = "Mostrar Evitación", ["Show Speed"] = "Mostrar Velocidad",
        ["Show Defensive Stats"] = "Mostrar defensivas",
        ["Show Dodge"] = "Mostrar Esquiva", ["Show Parry"] = "Mostrar Parada",
        ["Show Block"] = "Mostrar Bloqueo", ["Show Armor"] = "Mostrar Armadura", ["Show Stagger"] = "Mostrar Aplazar",
        ["Show Durability"] = "Mostrar durabilidad", ["Show Repair Cost"] = "Mostrar costo de reparación",
        ["Auto Color by Threshold"] = "Color auto por umbral",
        ["Use Worst Slot (instead of average)"] = "Peor ranura (en vez del promedio)",
        ["Scale:"] = "Escala:", ["Refresh Rate (sec):"] = "Frecuencia (s):", ["Font Size:"] = "Tamaño de fuente:", ["Text Opacity:"] = "Opacidad del texto:", ["Panel Background:"] = "Fondo del panel:",
        ["Display Mode:"] = "Modo:", ["Tooltip Targets:"] = "Objetivos tooltip:", ["Label Style:"] = "Estilo de etiqueta:", ["Text Outline:"] = "Contorno del texto:", ["Font:"] = "Fuente:", ["Language:"] = "Idioma:",
        ["Flat"] = "Plano", ["Sectioned"] = "Por secciones", ["Split"] = "Dividido",
        ["Mythic+"] = "Mítico+", ["Raid"] = "Banda",
        ["Full"] = "Completo", ["Short"] = "Corto", ["Hidden"] = "Oculto",
        ["None"] = "Ninguno", ["Outline"] = "Contorno", ["Thick Outline"] = "Contorno grueso",
        ["M+ Target"] = "Objetivo M+", ["Raid Target"] = "Objetivo banda",
        ["M+ High Keys"] = "M+ llaves altas", ["Raid Mythic All Bosses"] = "Banda mítica todos los jefes",
        ["Target:"] = "Objetivo:", ["Current:"] = "Actual:", ["Missing:"] = "Falta:",
        ["Over:"] = "Exceso:", ["Matched:"] = "Igualado:", ["Snapshot:"] = "Captura:",
        ["Stats panel shown"] = "Panel de estadísticas mostrado", ["Stats panel hidden"] = "Panel de estadísticas oculto",
        ["Settings reset to defaults"] = "Configuración restablecida",
        ["Commands: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug"] = "Comandos: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug",
        ["Reset to Defaults"] = "Restablecer", ["Close"] = "Cerrar",
        ["Open Settings"] = "Abrir configuración", ["Settings"] = "Configuración",
        ["Auto (current: %s)"] = "Auto (actual: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r La fuente puede no mostrar glifos %s. Elige una fuente SharedMedia con cobertura.",
        ["Displays your secondary, defensive stats and durability on screen. Click below to open the full settings window."] = "Muestra atributos secundarios, defensivos y durabilidad en pantalla. Da clic abajo para abrir la ventana de configuración.",
    },

    -- itIT: Italian. Cele (Celerità) / Vel (Velocità) Haste/Speed split. Para
    -- (Parata) at 4 chars reads more naturally than "Par"; Armat (Armatura) gives
    -- enough char-count to feel like a word; Forz / Agil keep 4-char rhythm. Ag
    -- (2 chars) was clearly too short — Italian readers wouldn't recognize it.
    itIT = {
        Crit = "Crit",          Haste = "Cele",         Mastery = "Maest",      Vers = "Vers",
        Dodge = "Schiv",        Parry = "Para",         Block = "Bloc",         Armor = "Armat",        Stagger = "Barc",
        Strength = "Forz",      Agility = "Agil",       Intellect = "Int",      Stamina = "Cost",
        ItemLevel = "LivOg",
        Leech = "Vamp",         Avoidance = "Evit",     Speed = "Vel",
        Durability = "Durab",   Repair = "Ripa",
        Defensive = "Difesa",
        Color = "Colore",
        -- ===== Settings UI (best-effort draft, native-speaker review welcome via Issues) =====
        ["Stats"] = "Stat", ["Layout"] = "Layout", ["Appearance"] = "Aspetto",
        ["Character"] = "Personaggio", ["Item Level"] = "Livello oggetto",
        ["Offensive"] = "Offensivo", ["Tertiary"] = "Terziario",
        ["Gear"] = "Equipaggiamento", ["Repair Cost"] = "Costo riparazione",
        ["Side Panel"] = "Pannello laterale", ["Side Panel Contains"] = "Pannello laterale contiene",
        ["Value Display"] = "Valori",
        ["Frame & Position"] = "Cornice e Posizione",
        ["Typography"] = "Tipografia",
        ["Readability"] = "Leggibilità",
        ["Localization"] = "Localizzazione",
        ["Offensive Stats"] = "Stat Offensive",
        ["Tertiary Stats"] = "Stat Terziarie",
        ["Defensive Stats"] = "Stat Difensive",
        ["Show Stats Panel"] = "Mostra pannello", ["Lock Frames"] = "Blocca finestre",
        ["Show Main Stat"] = "Mostra stat principale",
        ["Show Stamina"] = "Mostra Costituzione",
        ["Show Item Level"] = "Mostra livello oggetto",
        ["Show Rating"] = "Mostra valore", ["Show Percentage"] = "Mostra %",
        ["Match Value Color to Stat"] = "Colore valore = stat",
        ["Show Offensive Stats"] = "Mostra offensive", ["Hide Zero Values"] = "Nascondi valori zero",
        ["Show Crit"] = "Mostra Crit", ["Show Haste"] = "Mostra Celerità",
        ["Show Mastery"] = "Mostra Maestria", ["Show Versatility"] = "Mostra Versatilità",
        ["Show Tertiary Stats"] = "Mostra terziarie",
        ["Show Leech"] = "Mostra Vampirismo", ["Show Avoidance"] = "Mostra Evitazione", ["Show Speed"] = "Mostra Velocità",
        ["Show Defensive Stats"] = "Mostra difensive",
        ["Show Dodge"] = "Mostra Schivata", ["Show Parry"] = "Mostra Parata",
        ["Show Block"] = "Mostra Blocco", ["Show Armor"] = "Mostra Armatura", ["Show Stagger"] = "Mostra Barcollamento",
        ["Show Durability"] = "Mostra durata", ["Show Repair Cost"] = "Mostra costo riparazione",
        ["Auto Color by Threshold"] = "Colore auto per soglia",
        ["Use Worst Slot (instead of average)"] = "Slot peggiore (anziché media)",
        ["Scale:"] = "Scala:", ["Refresh Rate (sec):"] = "Frequenza (sec):", ["Font Size:"] = "Dimensione font:", ["Text Opacity:"] = "Opacità del testo:", ["Panel Background:"] = "Sfondo pannello:",
        ["Display Mode:"] = "Modalità:", ["Tooltip Targets:"] = "Target tooltip:", ["Label Style:"] = "Stile etichetta:", ["Text Outline:"] = "Contorno testo:", ["Font:"] = "Font:", ["Language:"] = "Lingua:",
        ["Flat"] = "Piatto", ["Sectioned"] = "A sezioni", ["Split"] = "Diviso",
        ["Mythic+"] = "Mitica+", ["Raid"] = "Incursione",
        ["Full"] = "Completo", ["Short"] = "Corto", ["Hidden"] = "Nascosto",
        ["None"] = "Nessuno", ["Outline"] = "Contorno", ["Thick Outline"] = "Contorno spesso",
        ["M+ Target"] = "Bersaglio M+", ["Raid Target"] = "Bersaglio incursione",
        ["M+ High Keys"] = "M+ chiavi alte", ["Raid Mythic All Bosses"] = "Incursione Mitica tutti i boss",
        ["Target:"] = "Bersaglio:", ["Current:"] = "Attuale:", ["Missing:"] = "Manca:",
        ["Over:"] = "Oltre:", ["Matched:"] = "Raggiunto:", ["Snapshot:"] = "Istantanea:",
        ["Stats panel shown"] = "Pannello statistiche mostrato", ["Stats panel hidden"] = "Pannello statistiche nascosto",
        ["Settings reset to defaults"] = "Impostazioni ripristinate",
        ["Commands: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug"] = "Comandi: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug",
        ["Reset to Defaults"] = "Predefiniti", ["Close"] = "Chiudi",
        ["Open Settings"] = "Apri impostazioni", ["Settings"] = "Impostazioni",
        ["Auto (current: %s)"] = "Auto (attuale: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r Il font potrebbe non visualizzare i glifi %s. Scegli un font SharedMedia con copertura adeguata.",
        ["Displays your secondary, defensive stats and durability on screen. Click below to open the full settings window."] = "Visualizza statistiche secondarie, difensive e durata equipaggiamento sullo schermo. Clicca sotto per aprire le impostazioni complete.",
    },

    -- ptBR: Brazilian Portuguese. Cele (Celeridade) / Vel (Velocidade). Forç (with
    -- cedilla, Força) and Agil at 4 chars match Portuguese's prosody better than the
    -- 3-char truncations. Esqu (Esquiva) likewise.
    ptBR = {
        Crit = "Crít",          Haste = "Cele",         Mastery = "Maest",      Vers = "Vers",
        Dodge = "Esqu",         Parry = "Par",          Block = "Bloq",         Armor = "Arm",          Stagger = "Camb",
        Strength = "Forç",      Agility = "Agil",       Intellect = "Int",      Stamina = "Vig",
        ItemLevel = "NvItem",
        Leech = "Vamp",         Avoidance = "Evit",     Speed = "Vel",
        Durability = "Durab",   Repair = "Rep",
        Defensive = "Defesa",
        Color = "Cor",
        -- ===== Settings UI (best-effort draft, native-speaker review welcome via Issues) =====
        ["Stats"] = "Atributos", ["Layout"] = "Layout", ["Appearance"] = "Aparência",
        ["Character"] = "Personagem", ["Item Level"] = "Nível de item",
        ["Offensive"] = "Ofensivo", ["Tertiary"] = "Terciário",
        ["Gear"] = "Equipamento", ["Repair Cost"] = "Custo de reparo",
        ["Side Panel"] = "Painel lateral", ["Side Panel Contains"] = "Painel lateral contém",
        ["Value Display"] = "Valores",
        ["Frame & Position"] = "Janela e Posição",
        ["Typography"] = "Tipografia",
        ["Readability"] = "Legibilidade",
        ["Localization"] = "Localização",
        ["Offensive Stats"] = "Atributos Ofensivos",
        ["Tertiary Stats"] = "Atributos Terciários",
        ["Defensive Stats"] = "Atributos Defensivos",
        ["Show Stats Panel"] = "Mostrar painel", ["Lock Frames"] = "Travar janelas",
        ["Show Main Stat"] = "Mostrar stat principal",
        ["Show Stamina"] = "Mostrar Vigor",
        ["Show Item Level"] = "Mostrar nível de item",
        ["Show Rating"] = "Mostrar valor", ["Show Percentage"] = "Mostrar %",
        ["Match Value Color to Stat"] = "Cor do valor = atributo",
        ["Show Offensive Stats"] = "Mostrar ofensivos", ["Hide Zero Values"] = "Ocultar valores zero",
        ["Show Crit"] = "Mostrar Crít.", ["Show Haste"] = "Mostrar Celeridade",
        ["Show Mastery"] = "Mostrar Maestria", ["Show Versatility"] = "Mostrar Versatilidade",
        ["Show Tertiary Stats"] = "Mostrar terciários",
        ["Show Leech"] = "Mostrar Vampirismo", ["Show Avoidance"] = "Mostrar Evasão", ["Show Speed"] = "Mostrar Velocidade",
        ["Show Defensive Stats"] = "Mostrar defensivos",
        ["Show Dodge"] = "Mostrar Esquiva", ["Show Parry"] = "Mostrar Aparar",
        ["Show Block"] = "Mostrar Bloqueio", ["Show Armor"] = "Mostrar Armadura", ["Show Stagger"] = "Mostrar Cambalear",
        ["Show Durability"] = "Mostrar durabilidade", ["Show Repair Cost"] = "Mostrar custo de reparo",
        ["Auto Color by Threshold"] = "Cor auto por limite",
        ["Use Worst Slot (instead of average)"] = "Pior slot (em vez de média)",
        ["Scale:"] = "Escala:", ["Refresh Rate (sec):"] = "Atualização (s):", ["Font Size:"] = "Tamanho da fonte:", ["Text Opacity:"] = "Opacidade do texto:", ["Panel Background:"] = "Fundo do painel:",
        ["Display Mode:"] = "Modo:", ["Tooltip Targets:"] = "Alvos do tooltip:", ["Label Style:"] = "Estilo do rótulo:", ["Text Outline:"] = "Contorno do texto:", ["Font:"] = "Fonte:", ["Language:"] = "Idioma:",
        ["Flat"] = "Plano", ["Sectioned"] = "Por seções", ["Split"] = "Dividido",
        ["Mythic+"] = "Mítico+", ["Raid"] = "Raide",
        ["Full"] = "Completo", ["Short"] = "Curto", ["Hidden"] = "Oculto",
        ["None"] = "Nenhum", ["Outline"] = "Contorno", ["Thick Outline"] = "Contorno grosso",
        ["M+ Target"] = "Alvo M+", ["Raid Target"] = "Alvo de raide",
        ["M+ High Keys"] = "M+ chaves altas", ["Raid Mythic All Bosses"] = "Raide Mítico todos os chefes",
        ["Target:"] = "Alvo:", ["Current:"] = "Atual:", ["Missing:"] = "Falta:",
        ["Over:"] = "Acima:", ["Matched:"] = "Igualado:", ["Snapshot:"] = "Registro:",
        ["Stats panel shown"] = "Painel de atributos mostrado", ["Stats panel hidden"] = "Painel de atributos oculto",
        ["Settings reset to defaults"] = "Configurações restauradas",
        ["Commands: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug"] = "Comandos: /ss (configurações), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug",
        ["Reset to Defaults"] = "Restaurar", ["Close"] = "Fechar",
        ["Open Settings"] = "Abrir configurações", ["Settings"] = "Configurações",
        ["Auto (current: %s)"] = "Auto (atual: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r A fonte pode não exibir glifos %s. Escolha uma fonte SharedMedia com cobertura.",
        ["Displays your secondary, defensive stats and durability on screen. Click below to open the full settings window."] = "Exibe atributos secundários, defensivos e durabilidade na tela. Clique abaixo para abrir a janela de configurações.",
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
        Dodge = "회피",         Parry = "쳐막",         Block = "막기",         Armor = "방어",         Stagger = "시간차",
        Strength = "힘",        Agility = "민첩",       Intellect = "지능",      Stamina = "체력",
        ItemLevel = "템렙",
        Leech = "흡혈",         Avoidance = "광피",     Speed = "이속",
        Durability = "내구",    Repair = "수리",
        Defensive = "수비",
        Color = "색상",
        -- ===== Settings UI (best-effort draft — native review welcomed via Issues) =====
        ["Stats"] = "능력치", ["Layout"] = "배치", ["Appearance"] = "외형",
        ["Character"] = "캐릭터", ["Item Level"] = "아이템 레벨",
        ["Offensive"] = "공격", ["Tertiary"] = "보조",
        ["Gear"] = "장비", ["Repair Cost"] = "수리 비용",
        ["Side Panel"] = "보조 패널", ["Side Panel Contains"] = "보조 패널 포함",
        ["Value Display"] = "값 표시",
        ["Frame & Position"] = "창 및 위치",
        ["Typography"] = "글꼴",
        ["Readability"] = "가독성",
        ["Localization"] = "현지화",
        ["Offensive Stats"] = "공격 능력치",
        ["Tertiary Stats"] = "3차 능력치",
        ["Defensive Stats"] = "방어 능력치",
        ["Show Stats Panel"] = "능력치 패널 표시", ["Lock Frames"] = "창 고정",
        ["Show Main Stat"] = "주요 능력치 표시",
        ["Show Stamina"] = "체력 표시",
        ["Show Item Level"] = "아이템 레벨 표시",
        ["Show Rating"] = "수치 표시", ["Show Percentage"] = "% 표시",
        ["Match Value Color to Stat"] = "값 색상 = 능력치",
        ["Show Offensive Stats"] = "공격 능력치 표시", ["Hide Zero Values"] = "0 값 숨김",
        ["Show Crit"] = "치명 표시", ["Show Haste"] = "가속 표시",
        ["Show Mastery"] = "특화 표시", ["Show Versatility"] = "유연 표시",
        ["Show Tertiary Stats"] = "3차 능력치 표시",
        ["Show Leech"] = "흡혈 표시", ["Show Avoidance"] = "광피 표시", ["Show Speed"] = "이속 표시",
        ["Show Defensive Stats"] = "방어 능력치 표시",
        ["Show Dodge"] = "회피 표시", ["Show Parry"] = "쳐막 표시",
        ["Show Block"] = "막기 표시", ["Show Armor"] = "방어도 표시", ["Show Stagger"] = "시간차 표시",
        ["Show Durability"] = "내구도 표시", ["Show Repair Cost"] = "수리 비용 표시",
        ["Auto Color by Threshold"] = "임계값 자동 색상",
        ["Use Worst Slot (instead of average)"] = "최악 슬롯 사용 (평균 대신)",
        ["Scale:"] = "크기:", ["Refresh Rate (sec):"] = "갱신 주기 (초):", ["Font Size:"] = "글꼴 크기:", ["Text Opacity:"] = "텍스트 투명도:", ["Panel Background:"] = "패널 배경:",
        ["Display Mode:"] = "표시 모드:", ["Tooltip Targets:"] = "툴팁 목표:", ["Label Style:"] = "라벨 스타일:", ["Text Outline:"] = "글자 외곽선:", ["Font:"] = "글꼴:", ["Language:"] = "언어:",
        ["Flat"] = "단일", ["Sectioned"] = "구역별", ["Split"] = "분리",
        ["Mythic+"] = "쐐기+", ["Raid"] = "공격대",
        ["Full"] = "전체", ["Short"] = "짧게", ["Hidden"] = "숨김",
        ["None"] = "없음", ["Outline"] = "외곽선", ["Thick Outline"] = "굵은 외곽선",
        ["M+ Target"] = "쐐기+ 목표", ["Raid Target"] = "공격대 목표",
        ["M+ High Keys"] = "쐐기+ 고단", ["Raid Mythic All Bosses"] = "신화 공격대 모든 우두머리",
        ["Target:"] = "목표:", ["Current:"] = "현재:", ["Missing:"] = "부족:",
        ["Over:"] = "초과:", ["Matched:"] = "일치:", ["Snapshot:"] = "스냅샷:",
        ["Stats panel shown"] = "능력치 패널 표시됨", ["Stats panel hidden"] = "능력치 패널 숨김",
        ["Settings reset to defaults"] = "설정이 기본값으로 초기화되었습니다",
        ["Commands: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug"] = "명령어: /ss (설정), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug",
        ["Reset to Defaults"] = "기본값", ["Close"] = "닫기",
        ["Open Settings"] = "설정 열기", ["Settings"] = "설정",
        ["Auto (current: %s)"] = "자동 (현재: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r 이 글꼴은 %s 글리프를 표시하지 못할 수 있습니다. SharedMedia에서 적합한 글꼴을 선택하세요.",
        ["Displays your secondary, defensive stats and durability on screen. Click below to open the full settings window."] = "보조 능력치, 방어 능력치 및 내구도를 화면에 표시합니다. 아래를 눌러 전체 설정 창을 엽니다.",
    },

    -- zhCN: Simplified Chinese. All terms match the official WoW Chinese client
    -- terminology — 2-char widely used in CN WoW community for stat displays.
    -- 躲闪 (Dodge) vs 闪避 (Avoidance) is the standard zhCN split. High confidence.
    zhCN = {
        Crit = "暴击",          Haste = "急速",         Mastery = "精通",       Vers = "全能",
        Dodge = "躲闪",         Parry = "招架",         Block = "格挡",         Armor = "护甲",         Stagger = "醉拳",
        Strength = "力量",      Agility = "敏捷",       Intellect = "智力",      Stamina = "耐力",
        ItemLevel = "装等",
        Leech = "吸血",         Avoidance = "闪避",     Speed = "移速",
        Durability = "耐久",    Repair = "修理",
        Defensive = "防御",
        Color = "颜色",
        -- ===== Settings UI (best-effort draft, native-speaker review welcome via Issues) =====
        ["Stats"] = "属性", ["Layout"] = "布局", ["Appearance"] = "外观",
        ["Character"] = "角色", ["Item Level"] = "装等",
        ["Offensive"] = "进攻", ["Tertiary"] = "第三属性",
        ["Gear"] = "装备", ["Repair Cost"] = "修理费用",
        ["Side Panel"] = "侧面板", ["Side Panel Contains"] = "侧面板包含",
        ["Value Display"] = "数值显示",
        ["Frame & Position"] = "窗口与位置",
        ["Typography"] = "字体",
        ["Readability"] = "可读性",
        ["Localization"] = "本地化",
        ["Offensive Stats"] = "进攻属性",
        ["Tertiary Stats"] = "三级属性",
        ["Defensive Stats"] = "防御属性",
        ["Show Stats Panel"] = "显示属性面板", ["Lock Frames"] = "锁定窗口",
        ["Show Main Stat"] = "显示主属性",
        ["Show Stamina"] = "显示耐力",
        ["Show Item Level"] = "显示装等",
        ["Show Rating"] = "显示等级", ["Show Percentage"] = "显示百分比",
        ["Match Value Color to Stat"] = "数值颜色匹配属性",
        ["Show Offensive Stats"] = "显示进攻属性", ["Hide Zero Values"] = "隐藏零值",
        ["Show Crit"] = "显示暴击", ["Show Haste"] = "显示急速",
        ["Show Mastery"] = "显示精通", ["Show Versatility"] = "显示全能",
        ["Show Tertiary Stats"] = "显示三级属性",
        ["Show Leech"] = "显示吸血", ["Show Avoidance"] = "显示闪避", ["Show Speed"] = "显示移速",
        ["Show Defensive Stats"] = "显示防御属性",
        ["Show Dodge"] = "显示躲闪", ["Show Parry"] = "显示招架",
        ["Show Block"] = "显示格挡", ["Show Armor"] = "显示护甲", ["Show Stagger"] = "显示醉拳",
        ["Show Durability"] = "显示耐久", ["Show Repair Cost"] = "显示修理费用",
        ["Auto Color by Threshold"] = "按阈值自动着色",
        ["Use Worst Slot (instead of average)"] = "最差栏位（替代平均值）",
        ["Scale:"] = "缩放:", ["Refresh Rate (sec):"] = "刷新率 (秒):", ["Font Size:"] = "字体大小:", ["Text Opacity:"] = "文字不透明度:", ["Panel Background:"] = "面板背景:",
        ["Display Mode:"] = "显示模式:", ["Tooltip Targets:"] = "提示目标:", ["Label Style:"] = "标签样式:", ["Text Outline:"] = "文字描边:", ["Font:"] = "字体:", ["Language:"] = "语言:",
        ["Flat"] = "扁平", ["Sectioned"] = "分组", ["Split"] = "分离",
        ["Mythic+"] = "史诗+", ["Raid"] = "团队",
        ["Full"] = "完整", ["Short"] = "简短", ["Hidden"] = "隐藏",
        ["None"] = "无", ["Outline"] = "描边", ["Thick Outline"] = "粗描边",
        ["M+ Target"] = "史诗+目标", ["Raid Target"] = "团队目标",
        ["M+ High Keys"] = "史诗+高层", ["Raid Mythic All Bosses"] = "史诗团队全部首领",
        ["Target:"] = "目标:", ["Current:"] = "当前:", ["Missing:"] = "缺少:",
        ["Over:"] = "超出:", ["Matched:"] = "已达成:", ["Snapshot:"] = "快照:",
        ["Stats panel shown"] = "属性面板已显示", ["Stats panel hidden"] = "属性面板已隐藏",
        ["Settings reset to defaults"] = "设置已恢复默认",
        ["Commands: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug"] = "命令: /ss (设置), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug",
        ["Reset to Defaults"] = "恢复默认", ["Close"] = "关闭",
        ["Open Settings"] = "打开设置", ["Settings"] = "设置",
        ["Auto (current: %s)"] = "自动（当前: %s）",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r 字体可能无法显示 %s 字形。请从 SharedMedia 选择合适的字体。",
        ["Displays your secondary, defensive stats and durability on screen. Click below to open the full settings window."] = "在屏幕上显示副属性、防御属性和装备耐久度。点击下方打开完整设置窗口。",
    },

    -- zhTW: Traditional Chinese (Taiwan). Same 2-char convention as zhCN but
    -- Traditional script forms (護甲 vs 护甲, 格擋 vs 格挡, 迴避 vs 闪避).
    -- Matches WoW Taiwan client terminology. High confidence.
    zhTW = {
        Crit = "致命",          Haste = "加速",         Mastery = "精通",       Vers = "全能",
        Dodge = "躲避",         Parry = "招架",         Block = "格擋",         Armor = "護甲",         Stagger = "醉拳",
        Strength = "力量",      Agility = "敏捷",       Intellect = "智力",      Stamina = "耐力",
        ItemLevel = "裝等",
        Leech = "汲取",         Avoidance = "迴避",     Speed = "移速",
        Durability = "耐久",    Repair = "修理",
        Defensive = "防禦",
        Color = "顏色",
        -- ===== Settings UI (best-effort draft, Traditional script) =====
        ["Stats"] = "屬性", ["Layout"] = "版面", ["Appearance"] = "外觀",
        ["Character"] = "角色", ["Item Level"] = "裝等",
        ["Offensive"] = "攻擊", ["Tertiary"] = "第三屬性",
        ["Gear"] = "裝備", ["Repair Cost"] = "修理費用",
        ["Side Panel"] = "側面板", ["Side Panel Contains"] = "側面板包含",
        ["Value Display"] = "數值顯示",
        ["Frame & Position"] = "視窗與位置",
        ["Typography"] = "字型",
        ["Readability"] = "可讀性",
        ["Localization"] = "在地化",
        ["Offensive Stats"] = "進攻屬性",
        ["Tertiary Stats"] = "三級屬性",
        ["Defensive Stats"] = "防禦屬性",
        ["Show Stats Panel"] = "顯示屬性面板", ["Lock Frames"] = "鎖定視窗",
        ["Show Main Stat"] = "顯示主屬性",
        ["Show Stamina"] = "顯示耐力",
        ["Show Item Level"] = "顯示裝等",
        ["Show Rating"] = "顯示等級", ["Show Percentage"] = "顯示百分比",
        ["Match Value Color to Stat"] = "數值色彩配合屬性",
        ["Show Offensive Stats"] = "顯示進攻屬性", ["Hide Zero Values"] = "隱藏零值",
        ["Show Crit"] = "顯示致命一擊", ["Show Haste"] = "顯示加速",
        ["Show Mastery"] = "顯示精通", ["Show Versatility"] = "顯示全能",
        ["Show Tertiary Stats"] = "顯示三級屬性",
        ["Show Leech"] = "顯示汲取", ["Show Avoidance"] = "顯示迴避", ["Show Speed"] = "顯示移速",
        ["Show Defensive Stats"] = "顯示防禦屬性",
        ["Show Dodge"] = "顯示躲避", ["Show Parry"] = "顯示招架",
        ["Show Block"] = "顯示格擋", ["Show Armor"] = "顯示護甲", ["Show Stagger"] = "顯示醉拳",
        ["Show Durability"] = "顯示耐久", ["Show Repair Cost"] = "顯示修理費用",
        ["Auto Color by Threshold"] = "依閾值自動上色",
        ["Use Worst Slot (instead of average)"] = "最差欄位（替代平均值）",
        ["Scale:"] = "縮放:", ["Refresh Rate (sec):"] = "更新率 (秒):", ["Font Size:"] = "字型大小:", ["Text Opacity:"] = "文字不透明度:", ["Panel Background:"] = "面板背景:",
        ["Display Mode:"] = "顯示模式:", ["Tooltip Targets:"] = "提示目標:", ["Label Style:"] = "標籤樣式:", ["Text Outline:"] = "文字描邊:", ["Font:"] = "字型:", ["Language:"] = "語言:",
        ["Flat"] = "扁平", ["Sectioned"] = "分組", ["Split"] = "分離",
        ["Mythic+"] = "傳奇+", ["Raid"] = "團隊",
        ["Full"] = "完整", ["Short"] = "簡短", ["Hidden"] = "隱藏",
        ["None"] = "無", ["Outline"] = "描邊", ["Thick Outline"] = "粗描邊",
        ["M+ Target"] = "傳奇+目標", ["Raid Target"] = "團隊目標",
        ["M+ High Keys"] = "傳奇+高層", ["Raid Mythic All Bosses"] = "傳奇團隊全部首領",
        ["Target:"] = "目標:", ["Current:"] = "目前:", ["Missing:"] = "缺少:",
        ["Over:"] = "超出:", ["Matched:"] = "已達成:", ["Snapshot:"] = "快照:",
        ["Stats panel shown"] = "屬性面板已顯示", ["Stats panel hidden"] = "屬性面板已隱藏",
        ["Settings reset to defaults"] = "設定已恢復預設",
        ["Commands: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug"] = "指令: /ss (設定), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug",
        ["Reset to Defaults"] = "恢復預設", ["Close"] = "關閉",
        ["Open Settings"] = "開啟設定", ["Settings"] = "設定",
        ["Auto (current: %s)"] = "自動（目前: %s）",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r 字型可能無法顯示 %s 字形。請從 SharedMedia 選擇合適的字型。",
        ["Displays your secondary, defensive stats and durability on screen. Click below to open the full settings window."] = "在螢幕上顯示副屬性、防禦屬性和裝備耐久度。點擊下方開啟完整設定視窗。",
    },
}

-- WARNING: must precede ResolveActiveLocale — forward-ref to GetDB resolves as _G.GetDB at parse time.
local function GetDB(key)
    local db = EnsureStatsProDBTable()
    local v = db[key]
    if v == nil then return defaults[key] end
    return v
end

local function GetBoolDB(key)
    local db = EnsureStatsProDBTable()
    if type(db[key]) == "boolean" then return db[key] end
    return defaults[key] == true
end

local function GetFontDB()
    local db = EnsureStatsProDBTable()
    if type(db.font) == "string" and db.font ~= "" then return db.font end
    return defaults.font
end

local function GetSavedAutoFontDB()
    local db = EnsureStatsProDBTable()
    if type(db.fontBeforeAutoSwitch) == "string" and db.fontBeforeAutoSwitch ~= "" then
        return db.fontBeforeAutoSwitch
    end
    return nil
end

local function IsFiniteNumber(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local VALID_ANCHOR_POINTS = {
    CENTER = true,
    TOP = true,
    BOTTOM = true,
    LEFT = true,
    RIGHT = true,
    TOPLEFT = true,
    TOPRIGHT = true,
    BOTTOMLEFT = true,
    BOTTOMRIGHT = true,
}

local function NormalizeAnchorPoint(value, fallback)
    if type(value) == "string" and VALID_ANCHOR_POINTS[value] then return value end
    if type(fallback) == "string" and VALID_ANCHOR_POINTS[fallback] then return fallback end
    return "CENTER"
end

local function NormalizePositionOffset(value, fallback)
    if IsFiniteNumber(value) and value >= -3000 and value <= 3000 then return value end
    if IsFiniteNumber(fallback) and fallback >= -3000 and fallback <= 3000 then return fallback end
    return 0
end

local function NormalizeDBVersion(value)
    local n = tonumber(value)
    if not IsFiniteNumber(n) then return 0 end
    return math.floor(n)
end

local NUMBER_SETTING_META = {
    scale                = { min = 0.5, max = 2.0, step = 0.1 },
    fontSize             = { min = 8,   max = 32,  step = 1 },
    textAlpha            = { min = 25,  max = 100, step = 5 },
    panelBackgroundAlpha = { min = 0,   max = 80,  step = 5 },
    updateInterval       = { min = 0.1, max = 1.0, step = 0.05 },
}

local function NormalizeNumberSetting(key, value)
    local meta = NUMBER_SETTING_META[key]
    if not meta then return value end
    local fallback = defaults[key]
    local n = tonumber(value)
    if not IsFiniteNumber(n) then n = fallback end
    if meta.step and meta.step > 0 then
        n = meta.min + math.floor(((n - meta.min) / meta.step) + 0.5) * meta.step
    end
    if n < meta.min then n = meta.min end
    if n > meta.max then n = meta.max end
    return n
end

local function GetNumberDB(key)
    local db = EnsureStatsProDBTable()
    local v = db[key]
    if v == nil then v = defaults[key] end
    return NormalizeNumberSetting(key, v)
end

-- Resolve the active locale: forceLocale="auto" (default) → GetLocale(); explicit
-- value forces panels to that locale regardless of WoW client locale.
local function ResolveActiveLocale()
    local force = GetDB("forceLocale")
    if not force or force == "auto" then return GetLocale() end
    return force
end

local function NormalizeLabelStyle(value)
    if value == "short" or value == "hidden" then
        return value
    end
    return "full"
end

addon.readabilityConfig = {
    textOutlineOptions = {
        { value = "none",    label = "None" },
        { value = "outline", label = "Outline" },
        { value = "thick",   label = "Thick Outline" },
    },
}

function addon.readabilityConfig.normalizeTextOutlineStyle(value)
    if value == "none" or value == "thick" then
        return value
    end
    return "outline"
end

function addon.readabilityConfig.textOutlineStyleToFontFlags(value)
    local style = addon.readabilityConfig.normalizeTextOutlineStyle(value)
    if style == "none" then return nil end
    if style == "thick" then return "THICKOUTLINE" end
    return "OUTLINE"
end

function addon.readabilityConfig.getTextOutlineStyleDB()
    return addon.readabilityConfig.normalizeTextOutlineStyle(GetDB("textOutlineStyle"))
end

local function FontSupports(fontPath, glyph)
    if not fontPath then return glyph == GLYPH_LATIN end
    local key = FontPathKey(fontPath)
    if not key then return glyph == GLYPH_LATIN end
    local entry = FONT_GLYPH_SUPPORT[key]
    if not entry then
        -- WHY basename: anchor patterns to filename, not addon-folder substrings.
        local lower = (string.match(fontPath, "[^\\/]+$") or fontPath):lower()
        for _, p in ipairs(FONT_GLYPH_PATTERNS) do
            if string.find(lower, p.pattern) then entry = p.glyphs; break end
        end
        -- Write-back memoize: a font file's glyph coverage is immutable for the
        -- session (file content can't change without /reload). FindCompatibleFont's
        -- LSM scan calls FontSupports for every registered font on every locale
        -- switch — this turns those repeated pattern-scans into O(1) hash hits.
        if entry then FONT_GLYPH_SUPPORT[key] = entry end
    end
    if not entry then return glyph == GLYPH_LATIN end
    for _, g in ipairs(entry) do
        if g == glyph then return true end
    end
    return false
end

-- WHY identity-fast-path remains: cached.activeLabels for enUS IS the identity map
-- (LABELS_BY_LOCALE.enUS where every key maps to itself). Pre-CacheSettings the table
-- is empty {} (see cached init in section 6) → nil lookup → "or englishKey" fallback
-- also yields identity. Both paths are O(1) single table access.
local function L(englishKey)
    return cached.activeLabels[englishKey] or englishKey
end

local GetStyledLabelText

-- Single point where coloring + localization compose. New stat needs one row in
-- LABELS_BY_LOCALE.enUS + one FormatLabel call site, plus a translation row in
-- each shipped non-English locale (4-7 char short form).
local function FormatLabel(colorHex, englishKey)
    local text = GetStyledLabelText(englishKey, cached.labelStyle)
    if text == "" then return "" end
    return string.format("|cff%s%s|r", colorHex, text)
end

-- WHY function (not a constant): resolved at use time so locale-toggle flips update
-- section headers on next render. Cheap: one string.format per visible section.
local function SectionHeader(labelKey)
    return string.format("|cff808080— %s —|r", L(labelKey))
end

-- pcall every stat API so 12.x secret values never touch our Lua logic.
-- Raw returns flow only into string.format, which Blizzard whitelisted for secrets.
local function safeCall(fn, ...)
    local ok, val = pcall(fn, ...)
    if ok then return val end
    return 0
end

local SAFE_NUM = {}

function SAFE_NUM.IsCleanFiniteNumber(value)
    if issecretvalue(value) then return false end
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

function SAFE_NUM.IsRenderableNumberValue(value)
    if issecretvalue(value) then return true end
    return SAFE_NUM.IsCleanFiniteNumber(value)
end

function SAFE_NUM.NormalizeRatingValue(value)
    if issecretvalue(value) then return value end
    if not SAFE_NUM.IsCleanFiniteNumber(value) or value < 0 then return 0 end
    return value
end

function SAFE_NUM.SafeDisplayPercent(fn, ...)
    local value = safeCall(fn, ...)
    if SAFE_NUM.IsRenderableNumberValue(value) then return value end
    return nil
end

function SAFE_NUM.SafeRatingInt(fn, ...)
    return SAFE_NUM.NormalizeRatingValue(safeCall(fn, ...))
end

function SAFE_NUM.CleanRatingInt(fn, ...)
    local ok, value = pcall(fn, ...)
    if not ok or not SAFE_NUM.IsCleanFiniteNumber(value) or value < 0 then return nil end
    return value
end

-- WHY dedicated helper for UnitStat: the API returns FOUR values
--   (stat, effectiveStat, posBuff, negBuff)
-- where `stat` is base (level + items, no temporary buffs) and `effectiveStat`
-- includes raid/food/flask/cooldown buffs. Blizzard's own CharacterFrame
-- displays `effectiveStat`, so users expect the same. `safeCall` only returns
-- the first value (stat), which would silently understate Primary stats for
-- any buffed player. Fall back chain: effectiveStat → stat → 0 covers a
-- hypothetical future API change that returns only one value.
local function GetEffectiveStat(statId)
    local ok, stat, effectiveStat = pcall(UnitStat, "player", statId)
    if not ok then return nil end
    local value = effectiveStat or stat
    if SAFE_NUM.IsRenderableNumberValue(value) then return value end
    return nil
end

local function IsCleanNonNegativeNumber(value)
    return value ~= nil and not issecretvalue(value) and SAFE_NUM.IsCleanFiniteNumber(value) and value >= 0
end

local function RefreshItemLevelCache()
    if not GetAverageItemLevel then
        itemLevelDirty = false
        return
    end
    local ok, overall, equipped = pcall(GetAverageItemLevel)
    if not ok then return end
    if not IsCleanNonNegativeNumber(overall) or not IsCleanNonNegativeNumber(equipped) then return end
    cached.itemLevelOverall = overall
    cached.itemLevelEquipped = equipped
    itemLevelDirty = false
end

local function IsRenderablePercentValue(val)
    return SAFE_NUM.IsRenderableNumberValue(val)
end

-- 12.x: hideZero check on a possibly-secret value.
-- issecretvalue() == in combat → always show (real value is non-zero).
local function shouldShow(val, hideZero)
    if not IsRenderablePercentValue(val) then return false end
    if not hideZero then return true end
    if issecretvalue(val) then return true end
    return val ~= 0
end

local function FormatRepairCost(copper)
    -- WHY: Blizzard's GetCoinTextureString embeds gold/silver/copper icons inline,
    -- matching the vendor display exactly. Pass fontHeight explicitly — without it
    -- the helper produces `:0:0` markup which in Retail 12.x sometimes renders icons
    -- at the wrong size or with the digits floating to a separate baseline.
    return GetCoinTextureString(copper, GetNumberDB("fontSize"))
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

local function ClampColorChannel(value, fallback)
    local n = tonumber(value)
    if n == nil then n = fallback or 0 end
    return math.max(0, math.min(1, n))
end

local function IsCompleteColor(c)
    return type(c) == "table" and tonumber(c.r) ~= nil and tonumber(c.g) ~= nil and tonumber(c.b) ~= nil
end

local function NormalizeColor(c, fallback)
    fallback = type(fallback) == "table" and fallback or nil
    if type(c) ~= "table" then c = nil end
    return
        ClampColorChannel(c and c.r, fallback and fallback.r),
        ClampColorChannel(c and c.g, fallback and fallback.g),
        ClampColorChannel(c and c.b, fallback and fallback.b)
end

local function RGBToHex(r, g, b)
    -- WARNING: explicit floor for portability across Lua versions (5.1 tolerates floats; 5.3+ requires int)
    -- WARNING: clamp + nil-coalesce defends against SavedVariables corruption / manual
    -- edits. Out-of-range values (e.g. r=2 from a hand-edited Lua file) would render
    -- as 3-hex-digit substrings (`1fe`) and corrupt the surrounding `|cffXXXXXX...|r`
    -- color escape — every stat row downstream would render with broken colors until
    -- the user resets settings. ColorPicker always returns 0..1, so this is purely
    -- a defensive guard against external DB tampering, not a hot-path concern.
    r = ClampColorChannel(r, 0)
    g = ClampColorChannel(g, 0)
    b = ClampColorChannel(b, 0)
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

local function JoinLabelsCol(labels, labelStyle)
    if NormalizeLabelStyle(labelStyle) == "hidden" then
        return ""
    end
    return JoinLinesSecretSafe(labels)
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
        cached[k] = GetBoolDB(k)
    end
    cached.updateInterval = GetNumberDB("updateInterval")
    cached.displayMode = GetDB("displayMode")
    cached.labelStyle = NormalizeLabelStyle(GetDB("labelStyle"))
    cached.targetSnapshot = addon.archonTargets.NormalizeSnapshotKey(GetDB("targetSnapshot"))
    -- WHY runtime clamp: corrupt SavedVariables should not make text invisible,
    -- spam OnUpdate, or break font/scale arithmetic. Do not write back here; UI
    -- slider commits remain the only normal path that mutates SavedVariables.
    cached.textAlpha = GetNumberDB("textAlpha") / 100
    cached.panelBackgroundAlpha = GetNumberDB("panelBackgroundAlpha") / 100
    cached.textOutlineStyle = addon.readabilityConfig.getTextOutlineStyleDB()

    -- Resolve labels for the active locale. forceLocale="auto" → GetLocale().
    -- WHY reference, not copy: LABELS_BY_LOCALE entries are never mutated; reference
    -- assignment is O(1) vs O(n) deep copy. WARNING: never mutate cached.activeLabels —
    -- it is a REFERENCE to the LABELS_BY_LOCALE entry.
    local activeLocale = ResolveActiveLocale()
    cached.activeLabels = LABELS_BY_LOCALE[activeLocale] or LABELS_BY_LOCALE.enUS
    cached.activeLabelsLocale = LABELS_BY_LOCALE[activeLocale] and activeLocale or "enUS"

    -- Color → hex string lookup. Iterate defaults.colors (single source of truth) to
    -- guarantee non-nil colorStrings for every key — eliminates the need for `or "ffffff"`
    -- fallbacks throughout the render pipeline.
    local db = EnsureStatsProDBTable()
    local userColors = type(db.colors) == "table" and db.colors or {}
    for name, defaultColor in pairs(defaults.colors) do
        local r, g, b = NormalizeColor(userColors[name], defaultColor)
        cached.colorStrings[name] = RGBToHex(r, g, b)
    end
end

local function MigrateDB()
    local db = EnsureStatsProDBTable()
    local preDefaultShowDurability = db.showDurability
    local preDefaultShowRepairCost = db.showRepairCost

    -- WHY runs before the version early-return: legacy migrants (from SwiftStats or the
    -- earlier internal SwiftStatsLocal name) whose source DB carried a dbVersion equal
    -- to ours would otherwise skip these loops and never get StatsPro's defaults
    -- populated. Idempotent: only fills missing keys, never clobbers user prefs.
    for k, v in pairs(defaults) do
        if db[k] == nil and type(v) ~= "table" then
            db[k] = v
        end
    end
    if type(db.colors) ~= "table" then db.colors = {} end
    for k, v in pairs(defaults.colors) do
        if not db.colors[k] then
            db.colors[k] = { r = v.r, g = v.g, b = v.b }
        end
    end
    if type(db.font) ~= "string" or db.font == "" then db.font = defaults.font end
    if db.fontBeforeAutoSwitch ~= nil
        and (type(db.fontBeforeAutoSwitch) ~= "string" or db.fontBeforeAutoSwitch == "") then
        db.fontBeforeAutoSwitch = nil
    end

    local dbVersion = NormalizeDBVersion(db.dbVersion)
    if dbVersion == CURRENT_DB_VERSION then return end

    -- v2 → v3: default textAlign changed "LEFT" → "RIGHT". Upgrade only users still on
    -- the old default; preserve any explicit user choice (CENTER/RIGHT untouched).
    if dbVersion == 2 and db.textAlign == "LEFT" then
        db.textAlign = "RIGHT"
    end

    -- v3 → v4: default font changed from hardcoded `Fonts\FRIZQT__.TTF` to the
    -- locale-aware `STANDARD_TEXT_FONT` global. Upgrade only users still on the old
    -- hardcoded default — preserve any explicit user choice (LSM-registered font,
    -- ARIALN, etc.). For enUS clients STANDARD_TEXT_FONT typically resolves to
    -- FRIZQT__.TTF anyway, so the migration is visually a no-op there; on
    -- zhCN/zhTW/koKR clients it switches to the CJK-supporting default font so
    -- localized labels render correctly out of the box.
    -- WHY LocaleAwareDefaultFont (not raw STANDARD_TEXT_FONT): the global is mutated by
    -- font-replacement addons (ChonkyCharacterSheet, Tukui font modules, ElvUI, etc.).
    -- Reading raw at PEW lets a third-party hijack pin db.font to an addon-shipped path
    -- forever (migration runs once, dbVersion bumps, hijacked path persists). Guarded
    -- helper falls back to FRIZQT for non-Blizzard paths.
    -- WHY FontSupports over the original path-equality check: the conceptually-
    -- correct heuristic is "swap if saved font lacks the client's required glyph",
    -- not "swap if saved font is the legacy hardcoded default". Equivalent for the
    -- common case (legacy FRIZQT default), strictly broader for the rare pre-v3
    -- user pinned on a custom Latin-only LSM font on a CJK client. Reuses
    -- LOCALE_GLYPH_REQ — the locale → glyph table consumed by MaybeAutoSwitchFont
    -- and ConfigFont resolver. GetLocale() (client-locale, file-shipping axis)
    -- over ResolveActiveLocale() (output-locale axis) because the swap target is
    -- itself client-locale-bound.
    if dbVersion <= 3 then
        local req = LOCALE_GLYPH_REQ[GetLocale()] or GLYPH_LATIN
        if not FontSupports(db.font, req) then
            db.font = LocaleAwareDefaultFont()
        end
    end

    -- v4 → v5: replaced boolean useLocalizedLabels with forceLocale string.
    -- Only legacy users with useLocalizedLabels=false (explicit opt-out) need an
    -- override; useLocalizedLabels=true|nil already maps to forceLocale="auto" via the
    -- defaults loop above.
    --
    -- WHY guard `db.forceLocale == "auto"` (not == nil): the defaults loop above
    -- already pre-populated forceLocale="auto" for any pre-v5 user (the field didn't
    -- exist before this version). Checking == nil would be a no-op. Checking == "auto"
    -- only overrides the just-prefilled default — preserves any manually-edited
    -- forceLocale value (corrupted DB with both keys, downgrade-then-upgrade flow).
    if dbVersion <= 4 then
        if db.forceLocale == "auto" and db.useLocalizedLabels == false then
            db.forceLocale = "enUS"
        end
        db.useLocalizedLabels = nil  -- drop legacy field unconditionally
    end

    -- v5 → v6: split single colors.primary into per-stat colors.strength/agility/intellect.
    -- WHY copy then drop: pre-v6 user customized colors.primary applied uniformly to all
    -- three primary stats; preserve that choice across all three new keys so visuals don't
    -- change on upgrade. The defaults loop above already pre-populated the new keys with
    -- their default gold (r=1,g=0.84,b=0), which we overwrite here when a custom value
    -- exists. Drop colors.primary so it doesn't linger as orphaned data.
    if dbVersion <= 5 and type(db.colors) == "table" and IsCompleteColor(db.colors.primary) then
        local p = db.colors.primary
        db.colors.strength  = { r = p.r, g = p.g, b = p.b }
        db.colors.agility   = { r = p.r, g = p.g, b = p.b }
        db.colors.intellect = { r = p.r, g = p.g, b = p.b }
        db.colors.primary = nil
    end

    -- v6 → v7: collapse three Show Strength/Agility/Intellect toggles into single
    -- showMainStat (auto-detects active spec's primary). Preserve user intent: if any
    -- of three was ON, replace with showMainStat=true (their displayed-stat preference
    -- carries over via spec API auto-resolution). If all three were OFF (v1.2.x default —
    -- silent majority), keep hidden — user can enable via Stats tab toggle if desired.
    --
    -- Color migration: also collapse three per-stat colors into single mainStat. Defaults
    -- loop above already seeded mainStat=gold; overwrite if any of three was customized
    -- away from gold (int>agi>str preference — int = most common main stat). Recovers
    -- v5→v6 cascade customization (v5's single colors.primary was split into 3 identical
    -- at v6; int picks it up by chance) AND respects v6 users who customized just one.
    -- type-check guards against corrupt DB (`db.colors.intellect = "string"` etc.).
    if dbVersion <= 6 then
        db.showMainStat = (db.showStrength == true or db.showAgility == true or db.showIntellect == true)
        db.showStrength = nil
        db.showAgility = nil
        db.showIntellect = nil
        if type(db.colors) == "table" then
            local function isCustom(c)
                return type(c) == "table" and c.r and c.g and c.b
                   and not (c.r == 1 and c.g == 0.84 and c.b == 0)
            end
            for _, key in ipairs({ "intellect", "agility", "strength" }) do
                if isCustom(db.colors[key]) then
                    local c = db.colors[key]
                    db.colors.mainStat = { r = c.r, g = c.g, b = c.b }
                    break
                end
            end
            db.colors.strength = nil
            db.colors.agility = nil
            db.colors.intellect = nil
        end
    end

    -- v7 -> v8: Repair Cost becomes independent from Durability and changes from a
    -- hidden-on-most-saves default ON to default OFF. Preserve visible old layouts
    -- (Durability ON + Repair ON), but do not suddenly show a repair-only row for users
    -- whose DB merely carried the old invisible default while Durability was OFF.
    if dbVersion <= 7 then
        if preDefaultShowDurability == true and preDefaultShowRepairCost == nil then
            db.showRepairCost = true
        elseif preDefaultShowDurability ~= true and preDefaultShowRepairCost == true then
            db.showRepairCost = false
        end
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
    if not ok or issecretvalue(effectiveArmor) or not SAFE_NUM.IsCleanFiniteNumber(effectiveArmor) then return end
    if effectiveArmor <= 0 then
        cached.armorDR = 0
        return
    end

    local okLevel, level = pcall(UnitEffectiveLevel, "player")
    if not okLevel or issecretvalue(level) or not SAFE_NUM.IsCleanFiniteNumber(level) then return end

    -- WARNING: PaperDollFrame_GetArmorReduction in 12.x retail returns 0..100 percent
    -- (not 0..1 fraction as some docs claim). Normalize defensively: if return is <=1
    -- treat as fraction and scale, else use as-is. Clamp to 0..100 for sanity.
    -- WARNING: armor effectiveness can be secret-tagged in M+ transitional combat
    -- moments where InCombatLockdown lags real combat state — the OOC guard above
    -- isn't sufficient. Filter the return value before any comparison or arithmetic;
    -- comparing a secret number to 1 raises a taint error and aborts the OnUpdate.
    local okReduction, raw = pcall(PaperDollFrame_GetArmorReduction, effectiveArmor, level)
    if not okReduction or issecretvalue(raw) or not SAFE_NUM.IsCleanFiniteNumber(raw) then return end
    if raw <= 1 then raw = raw * 100 end
    if raw < 0 then raw = 0 end
    if raw > 100 then raw = 100 end
    cached.armorDR = raw
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
    local repairCostPending = false
    for slot = DURABILITY_SLOT_MIN, DURABILITY_SLOT_MAX do
        if not DURABILITY_SKIP_SLOTS[slot] then
            local cur, max = GetInventoryItemDurability(slot)
            if SAFE_NUM.IsCleanFiniteNumber(cur) and SAFE_NUM.IsCleanFiniteNumber(max) and max > 0 then
                local pct = (cur / max) * 100
                sum = sum + pct
                count = count + 1
                if not minPct or pct < minPct then minPct = pct end
                if cached.showRepairCost and cur < max and C_TooltipInfo and C_TooltipInfo.GetInventoryItem then
                    local data = C_TooltipInfo.GetInventoryItem("player", slot)
                    if data then
                        if TooltipUtil and TooltipUtil.SurfaceArgs then
                            TooltipUtil.SurfaceArgs(data)
                        end
                        local cost = data.repairCost
                        if SAFE_NUM.IsCleanFiniteNumber(cost) and not issecretvalue(cost) then
                            if cost > 0 then
                                totalCost = totalCost + cost
                            end
                        else
                            repairCostPending = true
                        end
                    else
                        repairCostPending = true
                    end
                end
            end
        end
    end
    if count == 0 then return 100, 100, 0, repairCostPending end
    return sum / count, minPct, totalCost, repairCostPending
end

-- WARNING: repairCost can lag behind durability: C_TooltipInfo may return nil
-- post-login, or return data with repairCost still nil/secret until item/vendor
-- info catches up. No durability event fires for plain data-load — schedule one
-- delayed re-scan if any damaged slot's repair cost was pending. Flag prevents
-- pile-up if multiple early refreshes hit pending state simultaneously.
local durabilityRetryScheduled = false

local function RefreshDurabilityCache()
    local avg, mn, cost, repairCostPending = ScanDurabilityAndCost()
    cached.durabilityValue = cached.useWorstDurability and mn or avg
    if repairCostPending and cost <= 0 then
        cached.repairCost = cached.repairCost or 0
    else
        cached.repairCost = cost
    end
    durabilityDirty = false

    if repairCostPending and not durabilityRetryScheduled then
        durabilityRetryScheduled = true
        C_Timer.After(3, function()
            durabilityRetryScheduled = false
            durabilityDirty = true
        end)
    end
end

--[[ ============================================================
    9. PANEL CLASS
============================================================ ]]
local Panel = {}
Panel.__index = Panel

function Panel:New(globalName, dbKeyPrefix)
    local panel = setmetatable({}, Panel)
    panel.dbKeyPrefix = dbKeyPrefix or ""
    panel.lastLabelText = nil
    panel.lastValueText = nil
    panel.lastLineCount = -1

    local frame = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
    frame:SetSize(220, 100)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)

    frame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    frame:SetBackdropColor(0, 0, 0, 0)
    frame:SetBackdropBorderColor(0, 0, 0, 0)

    local backgroundTexture = frame:CreateTexture(nil, "BACKGROUND")
    backgroundTexture:SetPoint("TOPLEFT", frame, "TOPLEFT", -4, 4)
    backgroundTexture:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 4, -4)
    backgroundTexture:SetColorTexture(0, 0, 0, GetNumberDB("panelBackgroundAlpha") / 100)

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
    local font = GetFontDB()
    local fontSize = GetNumberDB("fontSize")
    local outlineStyle = addon.readabilityConfig.getTextOutlineStyleDB()
    local fontFlags = addon.readabilityConfig.textOutlineStyleToFontFlags(outlineStyle)

    local labelText = frame:CreateFontString(nil, "OVERLAY")
    labelText:SetFont(font, fontSize, fontFlags)
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
    ratingText:SetFont(font, fontSize, fontFlags)
    ratingText:SetJustifyH("RIGHT")
    ratingText:SetJustifyV("TOP")
    ratingText:SetTextColor(1, 1, 1, 1)
    ratingText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    ratingText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

    local valueText = frame:CreateFontString(nil, "OVERLAY")
    valueText:SetFont(font, fontSize, fontFlags)
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
    repairText:SetFont(font, fontSize, fontFlags)
    repairText:SetJustifyH("RIGHT")
    repairText:SetTextColor(1, 1, 1, 1)
    repairText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)  -- y repositioned per render
    repairText:Hide()

    -- Repair row label — dedicated FontString anchored TOPLEFT below labelText (Y set
    -- per-render in SetTextSafe). Architecturally separate from labelText so the repair
    -- row sits on its own visual row below stats (visual separation), and so coin can't
    -- overlap stat-row content. Width set per-render = stats labelW for column alignment.
    local repairLabelText = frame:CreateFontString(nil, "OVERLAY")
    repairLabelText:SetFont(font, fontSize, fontFlags)
    repairLabelText:SetJustifyH("RIGHT")  -- match labelText alignment
    repairLabelText:SetTextColor(1, 1, 1, 1)
    repairLabelText:Hide()  -- shown only when hasRepair

    local tooltipOverlays = {}
    local function makeTooltipOverlay()
        local overlay = CreateFrame("Frame", nil, frame)
        overlay:EnableMouse(true)
        overlay:SetFrameLevel(frame:GetFrameLevel() + 10)
        overlay:Hide()
        overlay:RegisterForDrag("LeftButton")
        overlay:SetScript("OnDragStart", function()
            if InCombatLockdown() or cached.isLocked then return end
            frame.wasDragging = true
            frame:StartMoving()
        end)
        overlay:SetScript("OnDragStop", function()
            frame:StopMovingOrSizing()
            panel:SavePosition()
            C_Timer.After(0.1, function() frame.wasDragging = false end)
        end)
        overlay:SetScript("OnMouseUp", function(_, button)
            if button == "RightButton" and not frame.wasDragging then
                addon:OpenConfigMenu()
            end
        end)
        overlay:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        return overlay
    end

    panel.frame = frame
    panel.labelText = labelText
    panel.ratingText = ratingText
    panel.valueText = valueText
    panel.repairText = repairText
    panel.repairLabelText = repairLabelText
    panel.tooltipOverlays = tooltipOverlays
    panel.makeTooltipOverlay = makeTooltipOverlay
    panel.lastTargetRows = nil
    panel.backgroundTexture = backgroundTexture
    -- WHY initialize from inline SetFont args above: Panel:ApplyStyle's idempotency check
    -- (early-return when font+size match cache) would otherwise miss the very first PEW-time
    -- apply when args happen to match the file-scope-inline SetFont calls — wasting 10
    -- SetFont + 10 SetText per panel on every /reload. With this initialization, the
    -- post-MaybeAutoSwitchFont apply at PEW becomes a no-op when MAS didn't swap.
    panel.appliedFont = font
    panel.appliedSize = fontSize
    panel.appliedTextOutlineStyle = outlineStyle

    -- Drag handlers (unsecure frames; not protected in combat lockdown).
    -- RegisterForDrag honors WoW's system drag-distance threshold — single clicks
    -- without movement do NOT fire OnDragStart, so wasDragging stays false on pure
    -- right-clicks and the OnMouseUp guard below correctly opens Settings.
    -- Lock state gates drag inside OnDragStart via cached.isLocked; mouse-enable is
    -- permanently true (Panel:New) so right-click → Settings works regardless of lock.
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(f)
        if InCombatLockdown() or cached.isLocked then return end
        f.wasDragging = true
        f:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        panel:SavePosition()
        -- 100ms guard absorbs the OnMouseUp that fires immediately after a drag, so
        -- the right-click handler doesn't open Settings on drag-end. Pure clicks
        -- don't pass the drag-distance threshold, never set wasDragging, unaffected.
        C_Timer.After(0.1, function() f.wasDragging = false end)
    end)
    -- Right-click → Settings (drag-aware via wasDragging guard).
    frame:SetScript("OnMouseUp", function(f, button)
        if button == "RightButton" and not f.wasDragging then
            addon:OpenConfigMenu()
        end
    end)

    return panel
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
    local db = EnsureStatsProDBTable()
    local pointKey         = self:DBKey("point")
    local relativePointKey = self:DBKey("relativePoint")
    local xOfsKey          = self:DBKey("xOfs")
    local yOfsKey          = self:DBKey("yOfs")
    local point            = NormalizeAnchorPoint(db[pointKey], defaults[pointKey] or "CENTER")
    local relativePoint    = NormalizeAnchorPoint(db[relativePointKey], defaults[relativePointKey] or "CENTER")
    local xOfs             = NormalizePositionOffset(db[xOfsKey], defaults[xOfsKey] or 0)
    local yOfs             = NormalizePositionOffset(db[yOfsKey], defaults[yOfsKey] or 0)

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

-- WHY no-op: see Panel:New EnableMouse(true), drag gated by cached.isLocked
function Panel:Lock() end
function Panel:Unlock() end

function Panel:Hide()
    if not self:IsShown() and self.lastLineCount == -1 and not self.lastRepairText then return end
    self.frame:Hide()
    self:ApplyTooltipRows(nil, 0)
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

function addon.archonTargets.FormatSignedRatingDelta(delta)
    if type(delta) ~= "number" or issecretvalue(delta) then return nil end
    if delta >= 0 then return "+" .. tostring(delta) end
    return "-" .. tostring(math.abs(delta))
end

function addon.archonTargets.GetRatingBonusForValue(ratingCR, rating)
    if type(GetCombatRatingBonusForCombatRatingValue) ~= "function" then return nil end
    if not SAFE_NUM.IsCleanFiniteNumber(ratingCR) or not SAFE_NUM.IsCleanFiniteNumber(rating) or rating < 0 then return nil end
    local okBonus, bonus = pcall(GetCombatRatingBonusForCombatRatingValue, ratingCR, rating)
    if not okBonus then return nil end
    if not SAFE_NUM.IsCleanFiniteNumber(bonus) then return nil end
    if ratingCR == CR_MASTERY then
        if type(GetMasteryEffect) ~= "function" then return nil end
        local ok, _, coefficient = pcall(GetMasteryEffect)
        if not ok or not SAFE_NUM.IsCleanFiniteNumber(coefficient) then return nil end
        bonus = bonus * coefficient
    end
    if not SAFE_NUM.IsCleanFiniteNumber(bonus) then return nil end
    return bonus
end

function addon.archonTargets.FormatPercentBonus(value, signed)
    if not SAFE_NUM.IsCleanFiniteNumber(value) then return nil end
    if math.abs(value) < 0.05 then value = 0 end
    if signed then
        local sign = value >= 0 and "+" or "-"
        return string.format("%s%.1f%%", sign, math.abs(value))
    end
    return string.format("%.1f%%", value)
end

function addon.archonTargets.FormatRatingWithBonus(rating, bonus, signedBonus)
    local ratingText = tostring(rating)
    local pctText = addon.archonTargets.FormatPercentBonus(bonus, signedBonus)
    if not pctText then return ratingText end
    return ratingText .. " (~" .. pctText .. ")"
end

function addon.archonTargets.GetTooltipValueColor(meta)
    if not cached.matchValueColorToStat or type(meta) ~= "table" then return nil end
    local colorKey = meta.colorKey or meta.statKey
    local colorHex = colorKey and cached.colorStrings[colorKey] or nil
    if type(colorHex) == "string" and colorHex ~= "" then return colorHex end
    return nil
end

function addon.archonTargets.ColorTooltipValue(text, colorHex)
    if not colorHex then return text end
    return "|cff" .. colorHex .. text .. "|r"
end

addon.archonTargets.monthAbbrsByLocale = {
    enUS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" },
    ruRU = { "янв", "фев", "мар", "апр", "май", "июн", "июл", "авг", "сен", "окт", "ноя", "дек" },
    deDE = { "Jan", "Feb", "Mär", "Apr", "Mai", "Jun", "Jul", "Aug", "Sep", "Okt", "Nov", "Dez" },
    frFR = { "janv", "févr", "mars", "avr", "mai", "juin", "juil", "août", "sept", "oct", "nov", "déc" },
    esES = { "ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic" },
    esMX = { "ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic" },
    itIT = { "gen", "feb", "mar", "apr", "mag", "giu", "lug", "ago", "set", "ott", "nov", "dic" },
    ptBR = { "jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez" },
    koKR = { "1월", "2월", "3월", "4월", "5월", "6월", "7월", "8월", "9월", "10월", "11월", "12월" },
    zhCN = { "1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月" },
    zhTW = { "1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月" },
}

addon.archonTargets.monthDays = {
    31, 28, 31, 30, 31, 30,
    31, 31, 30, 31, 30, 31,
}

function addon.archonTargets.GetMonthAbbr(monthNum)
    local allMonthAbbrs = addon.archonTargets.monthAbbrsByLocale
    local monthAbbrs = allMonthAbbrs[cached.activeLabelsLocale] or allMonthAbbrs.enUS
    return monthAbbrs[monthNum]
end

function addon.archonTargets.GetLocalizedSnapshotLabel(snapshotKey)
    if addon.archonTargets.NormalizeSnapshotKey(snapshotKey) == "raid" then
        return L("Raid Mythic All Bosses")
    end
    return L("M+ High Keys")
end

function addon.archonTargets.GetLocalizedSnapshotTitle(snapshotKey)
    if addon.archonTargets.NormalizeSnapshotKey(snapshotKey) == "raid" then
        return L("Raid Target")
    end
    return L("M+ Target")
end

function addon.archonTargets.IsLeapYear(year)
    return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

function addon.archonTargets.FormatSnapshotDate(capturedAt)
    if type(capturedAt) ~= "string" or issecretvalue(capturedAt) then return nil end
    local year, month, day = capturedAt:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not year then return capturedAt end
    local yearNum = tonumber(year)
    local monthNum = tonumber(month)
    local dayNum = tonumber(day)
    local monthName = addon.archonTargets.GetMonthAbbr(monthNum)
    local maxDay = addon.archonTargets.monthDays[monthNum]
    if monthNum == 2 and addon.archonTargets.IsLeapYear(yearNum) then maxDay = 29 end
    if not monthName or not dayNum or dayNum < 1 or dayNum > maxDay then return capturedAt end
    return day .. "-" .. monthName .. "-" .. year:sub(3, 4)
end

function addon.archonTargets.ShowTooltip(anchor, meta)
    if not meta then return end
    local currentBonus = addon.archonTargets.GetRatingBonusForValue(meta.ratingCR, meta.current)
    local targetBonus = addon.archonTargets.GetRatingBonusForValue(meta.ratingCR, meta.target)
    local deltaBonus
    -- WHY: subtract converted total ratings, not converted `abs(delta)`, so DR brackets
    -- and hard caps are evaluated at the player's current/target stat positions.
    if SAFE_NUM.IsCleanFiniteNumber(currentBonus) and SAFE_NUM.IsCleanFiniteNumber(targetBonus) then
        deltaBonus = targetBonus - currentBonus
    end
    local currentDisplayBonus = SAFE_NUM.IsCleanFiniteNumber(meta.currentPct) and meta.currentPct or currentBonus
    local targetDisplayBonus = targetBonus
    if SAFE_NUM.IsCleanFiniteNumber(meta.currentPct) and SAFE_NUM.IsCleanFiniteNumber(deltaBonus) then
        targetDisplayBonus = meta.currentPct + deltaBonus
    end
    local valueColor = addon.archonTargets.GetTooltipValueColor(meta)
    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    GameTooltip:AddLine("StatsPro " .. addon.archonTargets.GetLocalizedSnapshotTitle(meta.snapshotKey), 1, 0.82, 0)
    GameTooltip:AddDoubleLine(L("Target:"), addon.archonTargets.FormatRatingWithBonus(meta.target, targetDisplayBonus, false), 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine(L("Current:"), addon.archonTargets.ColorTooltipValue(addon.archonTargets.FormatRatingWithBonus(meta.current, currentDisplayBonus, false), valueColor), 0.7, 0.7, 0.7, 1, 1, 1)
    if meta.delta < 0 then
        GameTooltip:AddDoubleLine(L("Missing:"), addon.archonTargets.FormatRatingWithBonus(math.abs(meta.delta), deltaBonus, true), 1, 0.35, 0.35, 1, 0.35, 0.35)
    elseif meta.delta > 0 then
        GameTooltip:AddDoubleLine(L("Over:"), addon.archonTargets.FormatRatingWithBonus(addon.archonTargets.FormatSignedRatingDelta(meta.delta), deltaBonus and -deltaBonus, true), 0.35, 0.8, 1, 0.35, 0.8, 1)
    else
        GameTooltip:AddDoubleLine(L("Matched:"), addon.archonTargets.FormatRatingWithBonus(0, deltaBonus, true), 0.5, 1, 0.5, 0.5, 1, 0.5)
    end
    local snapshotDate = addon.archonTargets.FormatSnapshotDate(meta.capturedAt)
    if snapshotDate then
        GameTooltip:AddDoubleLine(L("Snapshot:"), addon.archonTargets.GetLocalizedSnapshotLabel(meta.snapshotKey) .. ", " .. snapshotDate, 0.7, 0.7, 0.7, 0.85, 0.85, 0.85)
    end
    GameTooltip:Show()
end

function Panel:ApplyTooltipRows(targetRows, lineCount)
    self.lastTargetRows = targetRows
    local rowHeight = self.lastLineH or GetNumberDB("fontSize")
    if not SAFE_NUM.IsCleanFiniteNumber(rowHeight) or rowHeight <= 0 then rowHeight = 1 end
    for i = 1, math.max(#(targetRows or {}), #(self.tooltipOverlays or {})) do
        local overlay = self.tooltipOverlays[i]
        if not overlay then
            overlay = self.makeTooltipOverlay()
            self.tooltipOverlays[i] = overlay
        end
        local meta = targetRows and targetRows[i] or nil
        if meta and i <= (lineCount or 0) then
            overlay:ClearAllPoints()
            overlay:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -((i - 1) * rowHeight))
            overlay:SetPoint("RIGHT", self.frame, "RIGHT", 0, 0)
            overlay:SetHeight(rowHeight)
            overlay:SetScript("OnEnter", function(f)
                addon.archonTargets.ShowTooltip(f, meta)
            end)
            overlay:Show()
        else
            overlay:Hide()
            overlay:SetScript("OnEnter", nil)
        end
    end
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
function Panel:SetTextSafe(labelStr, ratingStr, valueStr, lineCount, repairStr, repairLabelStr, targetRows)
    local hasRows = lineCount and lineCount > 0
    local hasRepair = repairStr and repairStr ~= ""
    local labelStyle = NormalizeLabelStyle(cached.labelStyle)
    local labelsHidden = labelStyle == "hidden"
    if not labelStr or (not hasRows and not hasRepair) then
        self:Hide()
        return
    end
    if not self:IsShown() then
        self.frame:Show()
    end
    self.labelText:SetText(hasRows and labelStr or "")
    self.ratingText:SetText(hasRows and (ratingStr or "") or "")
    self.valueText:SetText(hasRows and (valueStr or "") or "")
    self.lastLabelText = hasRows and labelStr or ""
    self.lastRatingText = ratingStr or ""
    self.lastValueText = hasRows and (valueStr or "") or ""

    -- Measure stat columns. WHY 2px gaps: labels RIGHT-justified, rating RIGHT-justified,
    -- value LEFT-justified — at each column boundary one side is justified outward, so
    -- visible gap equals exactly this constant with no per-row variance.
    if hasRows then
        self.cachedRatingW = MeasuredOrCached(self.ratingText, self.cachedRatingW, "GetStringWidth")
        self.cachedValueW  = MeasuredOrCached(self.valueText,  self.cachedValueW,  "GetStringWidth")
        if not labelsHidden then
            self.cachedLabelW = MeasuredOrCached(self.labelText, self.cachedLabelW, "GetStringWidth")
            -- labelText height drives Repair-row Y positioning; cache same way as widths.
            self.cachedLabelH = MeasuredOrCached(self.labelText, self.cachedLabelH, "GetStringHeight")
        end
    end

    local labelW = (hasRows and not labelsHidden) and (self.cachedLabelW or 0) or 0
    local ratingW = hasRows and (self.cachedRatingW or 0) or 0
    local valueW = hasRows and (self.cachedValueW or 0) or 0
    local hasRating = ratingW > 0
    local hasValue  = valueW > 0
    local rGap = (hasRating and hasValue) and 2 or 0
    local lGap = (labelW > 0 and (hasRating or hasValue)) and 2 or 0

    -- Repair row: rendered on a DEDICATED row below the stat rows (NOT as part of the
    -- multi-line labelText). Two FontStrings: repairLabelText for "Repair:" at frame.left
    -- (right-justified to align with stat labels), repairText for the coin at frame.right.
    -- WHY dedicated row: visual separation from stats + the coin width can exceed stat-
    -- column space without overlapping stat content rows.
    local repairLabelW = 0
    local lineH = GetNumberDB("fontSize")
    if hasRows and not labelsHidden and self.cachedLabelH then
        lineH = self.cachedLabelH / lineCount
    end
    self.lastLineH = lineH

    if hasRepair then
        local repairLabelVisible = repairLabelStr and repairLabelStr ~= ""
        local repairRowY = hasRows and -(lineCount * lineH + 1) or 0  -- 1px gap only when below stat rows

        -- Repair label: use stat labelW when below stat rows; measure its own label for
        -- repair-only panels so a stale previous stat width cannot collapse or overinflate.
        self.repairLabelText:ClearAllPoints()
        self.repairLabelText:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, repairRowY)
        self.repairLabelText:SetText(repairLabelStr or "")
        if repairLabelVisible then
            repairLabelW = hasRows and labelW or (MeasuredOrCached(self.repairLabelText, self.cachedRepairLabelW, "GetStringWidth") or 80)
            self.cachedRepairLabelW = repairLabelW
            self.repairLabelText:SetWidth(repairLabelW)
            self.repairLabelText:Show()
        else
            self.cachedRepairLabelW = 0
            self.repairLabelText:SetWidth(0)
            self.repairLabelText:Hide()
        end

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
    local rowsTotal = hasRows and (labelW + lGap + ratingW + rGap + valueW) or 0
    -- WHY repair row participates in width as a SEPARATE max() candidate (not added to
    -- rowsTotal): rowsTotal is the natural width of stat content. Repair row widens the
    -- panel only when its content (label + 2 + coin) exceeds that. Adding repairW into
    -- rowsTotal would inflate rating/value column widths for stat rows too — wide coin
    -- strings would push every percent and rating column rightward on rows that have
    -- nothing to do with repair, breaking the visual contract of column alignment.
    local repairGap = (repairLabelW > 0) and 2 or 0
    local repairTotal = hasRepair and (repairLabelW + repairGap + (self.cachedRepairW or 0)) or 0
    local totalW = math.max(rowsTotal, repairTotal, 80)

    -- WHY gated extra: only widen-by-coin causes the offset compensation. Floor 80 (when
    -- stats < 80 and no repair) must NOT trigger shift — pushing ratingText/valueText
    -- left of frame.right unnecessarily creates a different visual bug.
    local extra = (hasRepair and repairTotal > rowsTotal) and (repairTotal - rowsTotal) or 0

    -- ratingText: shift LEFT by `extra` so right edge stays at "stat-content right edge"
    -- (frame.right - extra), not frame.right. Without this, when frame is widened for
    -- coin, ratings track frame.right and create a huge gap between labels and values.
    local rOffset = -(extra + valueW + rGap)
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

    -- Frame height: text content bounds only. The optional background texture adds
    -- symmetric visual padding around this frame, so the text itself stays anchored
    -- exactly where older transparent-panel users placed it.
    -- Cache invalidates on lineCount change, hasRepair flip, OR font/size change
    -- (signaled via heightDirty by Panel:ApplyStyle). Reusing lastLineCount alone
    -- would conflate "text changed" vs "font changed" — Panel:Reflow needs
    -- lastLineCount preserved across ApplyStyle as the content-line-count marker.
    if lineCount ~= self.lastLineCount or hasRepair ~= self.lastHasRepair or self.heightDirty then
        local h = lineCount * lineH
        if hasRepair then h = h + lineH + (hasRows and 1 or 0) end  -- repair row + gap when below stats
        self.frame:SetHeight(h)
        self.lastLineCount = lineCount
        self.lastHasRepair = hasRepair
        self.heightDirty = false
    end
    self:ApplyTooltipRows(targetRows, lineCount)
end

function Panel:ApplyStyle(font, size, force)
    -- WHY idempotency: ApplyStyle is hot — fires from PEW (after MAS may have already
    -- applied), Reset, font/locale preview-cancel, lang commit's conditional restore,
    -- and the Font Size slider's OnValueChanged. Same-args calls cost 10 SetFont +
    -- 10 SetText + cache invalidations + a follow-up UpdateStats re-measure pass.
    -- Early return saves all of that whenever the panel is already at (font,size,outline).
    local outlineStyle = cached.textOutlineStyle or addon.readabilityConfig.getTextOutlineStyleDB()
    if not force
        and SameFontPath(self.appliedFont, font)
        and self.appliedSize == size
        and self.appliedTextOutlineStyle == outlineStyle then return end
    local fontFlags = addon.readabilityConfig.textOutlineStyleToFontFlags(outlineStyle)
    self.appliedFont = font
    self.appliedSize = size
    self.appliedTextOutlineStyle = outlineStyle
    self.labelText:SetFont(font, size, fontFlags)
    self.ratingText:SetFont(font, size, fontFlags)
    self.valueText:SetFont(font, size, fontFlags)
    self.repairText:SetFont(font, size, fontFlags)
    self.repairLabelText:SetFont(font, size, fontFlags)
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
    -- Force re-measure on next SetTextSafe: cachedLabelH=nil drops the previous
    -- glyph-height read; heightDirty=true makes the height-gate fire even when
    -- lineCount + hasRepair are unchanged (the Reflow path always feeds the same
    -- lineCount back). lastLineCount is intentionally NOT reset here — Panel:Reflow
    -- relies on it as the cached content-line-count for re-feeding SetTextSafe.
    self.cachedLabelH = nil
    self.heightDirty = true
end

-- WHY SetAlpha (region prop), not SetTextColor(r,g,b,a): color escape codes
-- |cffRRGGBB...|r in text content override the SetTextColor RGB, but alpha is
-- a separate region-level prop applied after color resolution. SetAlpha is the
-- canonical Blizzard pattern for transparent text with inline color escapes.
-- WHY no defensive re-call from Panel:ApplyStyle: SetFont clears text only, not
-- region transforms — alpha survives. Re-calling here would defeat ApplyStyle's
-- idempotency early-return optimization for no benefit.
function Panel:ApplyTextAlpha(alpha)
    self.labelText:SetAlpha(alpha)
    self.ratingText:SetAlpha(alpha)
    self.valueText:SetAlpha(alpha)
    self.repairText:SetAlpha(alpha)
    self.repairLabelText:SetAlpha(alpha)
end

-- Re-runs SetTextSafe with the last-known content. For font-only changes (font picker
-- hover/commit, FontSize slider) where line text hasn't changed but glyph widths have —
-- skip the heavy BuildLines + stat-API rescan that UpdateStats() does. SetTextSafe
-- handles all the actual measurement / sizing / re-positioning that the new font needs.
-- No-op pre-first-render or post-Hide (no rows and no repair payload); callers there fall
-- back to the regular UpdateStats path indirectly via the next OnUpdate tick.
function Panel:Reflow()
    local hasRepair = self.lastRepairText and self.lastRepairText ~= ""
    if (not self.lastLabelText or self.lastLineCount < 0) and not hasRepair then return end
    self:SetTextSafe(
        self.lastLabelText,
        self.lastRatingText or "",
        self.lastValueText or "",
        self.lastLineCount,
        self.lastRepairText or "",
        self.lastRepairLabelText or "",
        self.lastTargetRows
    )
end

--[[ ============================================================
    10. PANELS (instantiated at file scope)
============================================================ ]]
local mainPanel      = Panel:New("StatsProFrame",          "")
local defensivePanel = Panel:New("StatsProDefensiveFrame", "defensive_")

local function ApplyTextStyleToAllPanels(font, size, force)
    mainPanel:ApplyStyle(font, size, force)
    defensivePanel:ApplyStyle(font, size, force)
end

function Panel:ApplyBackgroundAlpha(alpha)
    self.frame:SetBackdropColor(0, 0, 0, 0)
    self.backgroundTexture:SetColorTexture(0, 0, 0, alpha)
end

local function ApplyTextAlphaToAllPanels(alpha)
    if mainPanel then mainPanel:ApplyTextAlpha(alpha) end
    if defensivePanel then defensivePanel:ApplyTextAlpha(alpha) end
end

addon.readabilityConfig.applyPanelBackgroundAlphaToAllPanels = function(alpha)
    if mainPanel then mainPanel:ApplyBackgroundAlpha(alpha) end
    if defensivePanel then defensivePanel:ApplyBackgroundAlpha(alpha) end
end

-- Companion to ApplyTextStyleToAllPanels: re-flows both panels after a font/size change
-- using cached text content. Use INSTEAD OF UpdateStats() in font-only paths (font picker,
-- FontSize slider) — same visual result, ~10× cheaper since the stat/gear builders
-- + stat-API scans + JoinLinesSecretSafe are skipped. Locale-change paths must keep
-- UpdateStats() since label text actually changes there.
local function ReflowAllPanels()
    mainPanel:Reflow()
    defensivePanel:Reflow()
end

addon.readabilityConfig.getTextOutlineStyle = addon.readabilityConfig.getTextOutlineStyleDB

addon.readabilityConfig.selectTextOutlineStyle = function(value, opt, dropdown)
    StatsProDB.textOutlineStyle = addon.readabilityConfig.normalizeTextOutlineStyle(value)
    CacheSettings()
    UIDropDownMenu_SetText(dropdown, L(opt.label))
    CloseDropDownMenus()
    ApplyTextStyleToAllPanels(GetFontDB(), GetNumberDB("fontSize"))
    ReflowAllPanels()
end

addon.readabilityConfig.changePanelBackgroundAlpha = function(value)
    cached.panelBackgroundAlpha = value / 100
    addon.readabilityConfig.applyPanelBackgroundAlphaToAllPanels(cached.panelBackgroundAlpha)
end

-- Forward-decl: both helpers are defined in section 14 alongside their companions
-- but are called from MaybeAutoSwitchFont below + PreviewLanguage/CancelLanguagePreview
-- much later. Without forward-decl, the function body captures `ResolveConfigFont` /
-- `ApplyConfigFont` as global lookups (resolution at definition time) and crashes
-- with "attempt to call a nil value" at PEW (AGENTS.md: "Runtime error attempt to
-- call a nil value from a function calling another function defined later").
-- WHY safe to call before menu opened: registry is empty pre-first-open so
-- ApplyConfigFont walks zero FontStrings; cached currentConfigFont is still updated,
-- so first-open's RegisterConfigFont picks up the right font.
local ResolveConfigFont
local ApplyConfigFont

-- Auto-switch panel font when active locale needs glyphs the current font lacks.
-- Saves the previous font in db.fontBeforeAutoSwitch so we can revert when the user
-- moves back to a compatible locale.
--
-- WHY `fontBeforeAutoSwitch or cur` (not just cur): chained switches (Russian →
-- Chinese → Korean) must preserve the ORIGINAL user-picked font, not an intermediate
-- one. Saving "or cur" only fires the first time; subsequent switches keep original.
--
-- WHY idempotent: when current font already supports active locale, function checks
-- restore-path opportunistically and otherwise returns. Safe to call from PEW + every
-- dropdown change without producing extra SetFont noise.
--
-- Read-only resolver: returns a font path that supports `req` glyph for `currentFont`.
-- Pure function — no DB writes, no SetFont calls. Callsites:
--   1. MaybeAutoSwitchFont (commit path) — wraps with DB mutations + ApplyTextStyle.
--   2. PreviewLanguage hover (Localization do-block) — visual-only preview, no DB writes.
-- Returns currentFont if already compatible (caller can use this to detect "no swap needed").
-- Returns nil if no compatible font found anywhere in the 3-tier fallback chain
-- (caller should leave font alone — RefreshLanguageWarning will surface the issue).
-- Three-tier fallback:
--   1. LocaleAwareDefaultFont (Blizzard-shipped STANDARD_TEXT_FONT, hijack-guarded).
--   2. ARIALN (Blizzard ships Latin+Cyrillic universally — saves cross-locale
--      Russian users from needing an LSM addon for clean rendering).
--   3. LSM scan (catches CJK / installed Cyrillic fonts).
local function FindCompatibleFont(currentFont, req)
    if FontSupports(currentFont, req) then return currentFont end
    local fallback = LocaleAwareDefaultFont()
    if fallback and FontSupports(fallback, req) then return fallback end
    if not SameFontPath(currentFont, "Fonts\\ARIALN.TTF") and FontSupports("Fonts\\ARIALN.TTF", req) then
        return "Fonts\\ARIALN.TTF"
    end
    if LSM then
        for _, name in ipairs(LSM:List(LSM.MediaType.FONT)) do
            local p = LSM:Fetch(LSM.MediaType.FONT, name)
            if p and FontSupports(p, req) then return p end
        end
    end
    return nil
end

-- Caller must set StatsProDB.forceLocale + run CacheSettings BEFORE calling.
local function MaybeAutoSwitchFont()
    local db = EnsureStatsProDBTable()
    local active = ResolveActiveLocale()
    local req    = LOCALE_GLYPH_REQ[active] or GLYPH_LATIN
    local cur    = GetFontDB()

    if FontSupports(cur, req) then
        local saved = GetSavedAutoFontDB()
        if db.fontBeforeAutoSwitch ~= nil and not saved then
            db.fontBeforeAutoSwitch = nil
        end
        if saved and not SameFontPath(saved, cur) and FontSupports(saved, req) then
            db.font = saved
            db.fontBeforeAutoSwitch = nil
            ApplyTextStyleToAllPanels(saved, GetNumberDB("fontSize"))
        end
        ApplyConfigFont(ResolveConfigFont(active))
        return
    end

    local fallback = FindCompatibleFont(cur, req)
    if fallback and not SameFontPath(fallback, cur) then
        db.fontBeforeAutoSwitch = GetSavedAutoFontDB() or cur
        db.font = fallback
        ApplyTextStyleToAllPanels(fallback, GetNumberDB("fontSize"))
    end
    ApplyConfigFont(ResolveConfigFont(active))
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
    scale = NormalizeNumberSetting("scale", scale)
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

-- Compose colored "X.X%" string. 5-callsite hot path; centralizes precision.
local function FmtColorPct(colorHex, pct)
    return string.format("|cff%s%.1f%%|r", colorHex, pct)
end

-- Format a stat value (rating + percentage variants honoring user toggles).
-- Returns TWO strings (ratingStr, valueStr) — see IsDualColMode for routing rules.
local function FmtRatingPct(rating, pct, statColor)
    local cs = cached.colorStrings
    local rc = (cached.matchValueColorToStat and statColor) or cs.rating
    local pc = (cached.matchValueColorToStat and statColor) or cs.percentage
    if IsDualColMode() then
        return string.format("|cff%s%d|r |cff808080|||r", rc, rating), FmtColorPct(pc, pct)
    elseif cached.showRating then
        return string.format("|cff%s%d|r", rc, rating), ""
    else
        -- percent-only: route into rating col (single-column layout)
        return FmtColorPct(pc, pct), ""
    end
end

-- Format a percentage-only stat (no rating dimension, e.g. defensive Dodge/Parry).
-- Returns (ratingCol, valueCol) — same routing rule as FmtRatingPct.
local function FmtPctOnly(pct, statColor)
    local cs = cached.colorStrings
    local pc = (cached.matchValueColorToStat and statColor) or cs.percentage
    local pctStr = FmtColorPct(pc, pct)
    if IsDualColMode() then return "", pctStr end
    return pctStr, ""
end

-- Route a plain value (Character stat int, Item Level, Durability %) into the
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
-- For rows without a rating dimension (Character stats, Defensives, Durability,
-- headers), the rating column is "" and that line of the rating FontString is empty.

local function PushRow(labels, ratings, values, label, rating, value)
    labels[#labels + 1] = label
    ratings[#ratings + 1] = rating
    values[#values + 1] = value
end

-- Compose+push one Primary-section flat-value row. Shared by Main Stat and Stamina
-- branches in BuildCharacterLines — both resolve color via colorKey, optionally tint
-- value via matchValueColorToStat, render numeric value through RouteValueOnly.
local function PushPrimaryStatRow(labels, ratings, values, colorKey, statId, labelKey)
    local cs = cached.colorStrings
    local statStr = cs[colorKey]
    local valueColor = (cached.matchValueColorToStat and statStr) or cs.rating
    local val = GetEffectiveStat(statId)
    if not SAFE_NUM.IsRenderableNumberValue(val) then return end
    local rCol, vCol = RouteValueOnly(string.format("|cff%s%d|r", valueColor, val))
    PushRow(labels, ratings, values, FormatLabel(statStr, labelKey), rCol, vCol)
end

-- WHY split equipped+overall across rating/value columns: mirrors FmtRatingPct's
-- column layout so the iLvl row's "|" lands at the same X as the rated rows'
-- "|" (rating column right-edge). Equipped goes in rating col with the trailing
-- gray pipe, overall goes in value col left-justified. Each cell is short enough
-- that the multi-line FontString can't wrap (the ratings + values mid-string wrap
-- bug we hit earlier was specifically "277 / 277" in a single value-col cell —
-- splitting across columns gives 4-5 char cells with no whitespace candidates
-- between numbers).
-- WHY hidden labelStyle skip: labelText is hidden in that style, so showing
-- iLvl rating/value alone (without the "iLvl:" label) would orphan the row.
local function PushItemLevelRow(labels, ratings, values)
    if not cached.itemLevelOverall or not cached.itemLevelEquipped then return end
    local labelStr = GetStyledLabelText("ItemLevel", cached.labelStyle)
    if labelStr == "" then return end
    local cs = cached.colorStrings
    local itemLevelColor = cs.itemLevel
    local valueColor = (cached.matchValueColorToStat and itemLevelColor) or cs.rating
    local overall = math.floor(cached.itemLevelOverall + 0.5)
    local equipped = math.floor(cached.itemLevelEquipped + 0.5)
    local delta = math.max(0, overall - equipped)
    local equippedColor = valueColor
    if delta >= ITEM_LEVEL_DANGER_DELTA then
        equippedColor = ITEM_LEVEL_DANGER_COLOR
    elseif delta >= ITEM_LEVEL_WARN_DELTA then
        equippedColor = ITEM_LEVEL_WARN_COLOR
    end
    local label = string.format("|cff%s%s|r", itemLevelColor, labelStr)
    local rStr, vStr
    if IsDualColMode() then
        -- Dual: rating col gets "EQUIPPED |" (right-justified, aligns with rated
        -- "RATING |" rows); value col gets "OVERALL" (left-justified, aligns with
        -- rated "PERCENT%" rows).
        rStr = string.format("|cff%s%d|r |cff808080|||r", equippedColor, equipped)
        vStr = string.format("|cff%s%d|r", valueColor, overall)
    else
        -- Single-col mode: ALL content routes into the rating column, value col is "".
        -- Mirrors FmtRatingPct's single-col fallback (and JoinValuesCol returns "" in
        -- non-dual-col mode regardless, so anything pushed to value col would be
        -- dropped). No whitespace around the pipe so the multi-line rating FontString
        -- won't word-wrap mid-string.
        rStr = string.format("|cff%s%d|r|cff808080|||r|cff%s%d|r",
                             equippedColor, equipped, valueColor, overall)
        vStr = ""
    end
    PushRow(labels, ratings, values, label, rStr, vStr)
end

local function BuildCharacterLines(labels, ratings, values)
    if not cached.showMainStat and not cached.showStamina then return labels, ratings, values end
    if cached.showMainStat then
        local def = PRIMARY_STATS_BY_ID[GetCurrentMainStatId()]
        if def then -- silently skip when sub-10 alt / pre-PEW; don't blank Stamina row
            PushPrimaryStatRow(labels, ratings, values, "mainStat", def.unitStatId, def.label)
        end
    end

    if cached.showStamina then
        PushPrimaryStatRow(labels, ratings, values, "stamina", STAMINA_UNIT_STAT_ID, "Stamina")
    end
    return labels, ratings, values
end

local function BuildItemLevelLines(labels, ratings, values)
    if cached.showItemLevel then
        PushItemLevelRow(labels, ratings, values)
    end
    return labels, ratings, values
end

local function BuildOffensiveLines(labels, ratings, values, targetRows)
    -- Master gate: hide entire section when off (cheapest check, exits whole function).
    if not cached.showOffensive then return labels, ratings, values end
    -- WHY guard: with both display toggles off the user wants offensive rows hidden
    -- entirely. Without this guard the percent-only branch of FmtRatingPct would still
    -- fire (single-column routing), producing visible percent rows and ignoring intent.
    if not (cached.showRating or cached.showPercentage) then return labels, ratings, values end
    local cs = cached.colorStrings

    -- Tooltip targets need the raw rating even when the rating column is hidden.
    local needTargetRating = targetRows ~= nil
    for _, def in ipairs(OFFENSIVE_STATS) do
        if cached[def.showKey] then
            local val = SAFE_NUM.SafeDisplayPercent(def.api)
            if shouldShow(val, cached.hideZeroOffensive) then
                local targetRating = needTargetRating and SAFE_NUM.CleanRatingInt(GetCombatRating, def.ratingCR) or nil
                local rating = cached.showRating and (targetRating or SAFE_NUM.SafeRatingInt(GetCombatRating, def.ratingCR)) or 0
                local statColor = cs[def.colorKey]
                local rStr, vStr = FmtRatingPct(rating, val, statColor)
                if targetRows then
                    targetRows[#targetRows + 1] = addon.archonTargets.BuildMeta(def.statKey, targetRating, def.ratingCR, val, def.colorKey) or false
                end
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
        local targetVersRating
        -- WARNING: must check operands for secret state before arithmetic. Rating
        -- may be read for either the visible rating column or target-hover metadata;
        -- percent cache can still refresh independently.
        if SAFE_NUM.IsCleanFiniteNumber(versFromRating) and SAFE_NUM.IsCleanFiniteNumber(versFlat)
            and not issecretvalue(versFromRating) and not issecretvalue(versFlat) then
            cached.versTotal = versFromRating + versFlat
        end
        if cached.showRating or needTargetRating then
            targetVersRating = SAFE_NUM.CleanRatingInt(GetCombatRating, CR_VERSATILITY_DAMAGE_DONE)
            if targetVersRating then
                cached.versTotalRating = targetVersRating
            end
        end
        if shouldShow(cached.versTotal, cached.hideZeroOffensive) then
            local versStr = cs.versatility
            local vRatStr, vValStr = FmtRatingPct(cached.versTotalRating, cached.versTotal, versStr)
            if targetRows then
                targetRows[#targetRows + 1] = addon.archonTargets.BuildMeta("versatility", targetVersRating, CR_VERSATILITY_DAMAGE_DONE, cached.versTotal, "versatility") or false
            end
            PushRow(labels, ratings, values,
                FormatLabel(versStr, "Vers"),
                vRatStr, vValStr)
        end
    end
    return labels, ratings, values
end

local function BuildTertiaryLines(labels, ratings, values)
    if not cached.showTertiary then return labels, ratings, values end
    if not (cached.showRating or cached.showPercentage) then return labels, ratings, values end
    local cs = cached.colorStrings

    local needRating = cached.showRating
    for _, def in ipairs(TERTIARY_STATS) do
        if cached[def.showKey] then
            local val = SAFE_NUM.SafeDisplayPercent(def.api)
            if shouldShow(val, cached.hideZeroTertiary) then
                local rating = needRating and SAFE_NUM.SafeRatingInt(GetCombatRating, def.ratingCR) or 0
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
        if not (issecretvalue(cur) or issecretvalue(run) or issecretvalue(flight) or issecretvalue(swim))
            and (cur == nil or SAFE_NUM.IsCleanFiniteNumber(cur))
            and (run == nil or SAFE_NUM.IsCleanFiniteNumber(run))
            and (flight == nil or SAFE_NUM.IsCleanFiniteNumber(flight))
            and (swim == nil or SAFE_NUM.IsCleanFiniteNumber(swim)) then
            local effectiveYps = math.max(cur or 0, run or 0, flight or 0, swim or 0)
            cached.speedPct = (effectiveYps / 7) * 100
        end
        local speed = cached.speedPct
        local speedRating = needRating and SAFE_NUM.SafeRatingInt(GetCombatRating, CR_SPEED) or 0
        if shouldShow(speed, cached.hideZeroTertiary) then
            local statColor = cs.speed
            local rStr, vStr = FmtRatingPct(speedRating, speed, statColor)
            PushRow(labels, ratings, values,
                FormatLabel(statColor, "Speed"),
                rStr, vStr)
        end
    end
    return labels, ratings, values
end

local function BuildDefensiveLines(labels, ratings, values)
    if not cached.showDefensive then return labels, ratings, values end
    local cs = cached.colorStrings

    -- Dodge / Parry / Block / Stagger (table-driven)
    for _, def in ipairs(DEFENSIVE_STATS) do
        if cached[def.showKey] and (not def.appliesFn or def.appliesFn()) then
            local val = safeCall(def.api)
            if IsRenderablePercentValue(val) and shouldShow(val, cached.hideZeroDefensive) then
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
            local rCol, vCol = RouteValueOnly(FmtColorPct(valueColor, cached.armorDR))
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
local function BuildDurabilityLines(labels, ratings, values)
    if not cached.showDurability then return labels, ratings, values end
    local cs = cached.colorStrings
    local pct = cached.durabilityValue
    if not SAFE_NUM.IsCleanFiniteNumber(pct) then pct = 100 end
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    local durStr = cs.durability
    local valueColor
    if cached.useAutoColorDurability then
        valueColor = RGBToHex(ComputeDurabilityColor(pct))
    else
        valueColor = durStr
    end
    -- %.1f%% matches vendor precision (95.2% vs 95%)
    do
        local rCol, vCol = RouteValueOnly(FmtColorPct(valueColor, pct))
        PushRow(labels, ratings, values,
            FormatLabel(durStr, "Durability"),
            rCol, vCol)
    end
    return labels, ratings, values
end

local function BuildRepairCostPayload()
    if not cached.showRepairCost or cached.repairCost <= 0 then return "", nil end
    local cs = cached.colorStrings
    local repairLabelStr
    -- WHY no PushRow for Repair: the label + coin render on a DEDICATED row below
    -- the stat rows (see Panel:SetTextSafe), not as part of the multi-line labelText.
    -- Two reasons: (1) the coin string with inline gold/silver/copper icons is wider
    -- than typical stat values, so putting it into a normal value column can overlap
    -- stat rows. (2) Visual separation: stats render as one group, repair-cost info
    -- as a distinct row. Don't wrap the coin string in |cff...|r — coin icons render
    -- inline as textures and the color tag would tint them.
    repairLabelStr = FormatLabel(cs.durability, "Repair")
    return FormatRepairCost(cached.repairCost), repairLabelStr
end

-- WHY: separate header injector — sectioned mode places localized structural rows
-- between logical stat blocks. Header text spans the label column with empty rating
-- + value to preserve row alignment.
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

function addon.archonTargets.AppendTargetRows(dst, src, rowCount)
    dst = dst or {}
    for i = 1, rowCount do
        dst[#dst + 1] = (src and src[i]) or false
    end
    return dst
end

-- Build*Lines share one contract: mutate the supplied row arrays and return them.
-- The return fallback preserves rows if a future builder accidentally stays mutate-only.
local function BuildRowBlock(def)
    local labels, ratings, values = {}, {}, {}
    local targetRows = def.splitKey == "splitOffensive" and {} or nil
    local outLabels, outRatings, outValues = def.buildFn(labels, ratings, values, targetRows)
    if outLabels then
        labels = outLabels
        ratings = outRatings or ratings
        values = outValues or values
    end
    return {
        splitKey = def.splitKey,
        sectionKey = def.sectionKey,
        labels = labels or {},
        ratings = ratings or {},
        values = values or {},
        targetRows = targetRows,
        repairStr = "",
        repairLabelStr = nil,
    }
end

local function BuildRepairBlock(def)
    local repairStr, repairLabelStr = BuildRepairCostPayload()
    return {
        splitKey = def.splitKey,
        sectionKey = def.sectionKey,
        labels = {},
        ratings = {},
        values = {},
        repairStr = repairStr,
        repairLabelStr = repairLabelStr,
    }
end

local RENDER_BLOCK_DEFS = {
    { splitKey = "splitCharacter",  sectionKey = "Character",  buildFn = BuildCharacterLines },
    { splitKey = "splitOffensive",  sectionKey = "Offensive",  buildFn = BuildOffensiveLines },
    { splitKey = "splitTertiary",   sectionKey = "Tertiary",   buildFn = BuildTertiaryLines },
    { splitKey = "splitDefensive",  sectionKey = "Defensive",  buildFn = BuildDefensiveLines },
    { splitKey = "splitItemLevel",  sectionKey = "Gear",       buildFn = BuildItemLevelLines },
    { splitKey = "splitDurability", sectionKey = "Gear",       buildFn = BuildDurabilityLines },
    { splitKey = "splitRepairCost", sectionKey = "Gear",       buildRepair = true },
}

local function NewRenderBucket()
    return { labels = {}, ratings = {}, values = {}, targetRows = {}, repairStr = "", repairLabelStr = nil }
end

local function AddBlockToBucket(bucket, block)
    AppendRows(bucket.labels, bucket.ratings, bucket.values, block.labels, block.ratings, block.values)
    bucket.targetRows = addon.archonTargets.AppendTargetRows(bucket.targetRows, block.targetRows, #block.labels)
    if block.repairStr and block.repairStr ~= "" then
        bucket.repairStr = block.repairStr
        bucket.repairLabelStr = block.repairLabelStr
    end
end

local function BlockHasContent(block)
    return #block.labels > 0 or (block.repairStr and block.repairStr ~= "")
end

local function AddSectionedBlockToBucket(bucket, block, lastSectionKey, labelStyle)
    if not BlockHasContent(block) then return lastSectionKey end
    if NormalizeLabelStyle(labelStyle) ~= "hidden" and block.sectionKey and block.sectionKey ~= lastSectionKey then
        PushHeader(bucket.labels, bucket.ratings, bucket.values, SectionHeader(block.sectionKey))
        bucket.targetRows[#bucket.targetRows + 1] = false
        lastSectionKey = block.sectionKey
    elseif block.sectionKey and block.sectionKey ~= lastSectionKey then
        lastSectionKey = block.sectionKey
    end
    AddBlockToBucket(bucket, block)
    return lastSectionKey
end

local function BucketHasContent(bucket)
    return #bucket.labels > 0 or (bucket.repairStr and bucket.repairStr ~= "")
end

local function RenderBucket(panel, bucket)
    if BucketHasContent(bucket) then
        panel:SetTextSafe(
            JoinLabelsCol(bucket.labels, cached.labelStyle),
            JoinLinesSecretSafe(bucket.ratings),
            JoinValuesCol(bucket.values),
            #bucket.labels,
            bucket.repairStr,
            bucket.repairLabelStr,
            bucket.targetRows)
    else
        panel:Hide()
    end
end

local function BuildRenderBlocks()
    local blocks = {}
    for _, def in ipairs(RENDER_BLOCK_DEFS) do
        blocks[#blocks + 1] = def.buildRepair and BuildRepairBlock(def) or BuildRowBlock(def)
    end
    return blocks
end

local function RouteRenderBlocks(blocks, mode, splitSelection, labelStyle)
    local mainBucket = NewRenderBucket()
    local sideBucket = NewRenderBucket()
    local style = NormalizeLabelStyle(labelStyle or cached.labelStyle)
    if mode == "split" then
        local selection = splitSelection or cached
        for _, block in ipairs(blocks) do
            AddBlockToBucket(selection[block.splitKey] and sideBucket or mainBucket, block)
        end
    elseif mode == "sectioned" then
        local lastSectionKey
        for _, block in ipairs(blocks) do
            lastSectionKey = AddSectionedBlockToBucket(mainBucket, block, lastSectionKey, style)
        end
    else
        for _, block in ipairs(blocks) do
            AddBlockToBucket(mainBucket, block)
        end
    end
    return mainBucket, sideBucket
end

local updateCount = 0
local function UpdateStats()
    -- WARNING: skip until init complete; cached.colorStrings is empty until CacheSettings runs
    if not isLoaded then return end
    updateCount = updateCount + 1

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

    -- Gear cache: event-driven (avoid scanning 19 slots every 0.5s). Repair Cost can
    -- now render independently from Durability, so either visible gear block needs data.
    if (cached.showDurability or cached.showRepairCost) and durabilityDirty then
        RefreshDurabilityCache()
    end

    if cached.showItemLevel and itemLevelDirty then
        RefreshItemLevelCache()
    end

    local blocks = BuildRenderBlocks()
    local mode = cached.displayMode or "flat"
    local mainBucket, sideBucket = RouteRenderBlocks(blocks, mode, cached, cached.labelStyle)
    RenderBucket(mainPanel, mainBucket)
    if mode == "split" then
        RenderBucket(defensivePanel, sideBucket)
    else
        defensivePanel:Hide()
    end
end

--[[ ============================================================
    12. UPDATE TIMER (dedicated invisible frame)
============================================================ ]]
-- WARNING: do NOT host this OnUpdate on mainPanel.frame or defensivePanel.frame.
-- WoW only fires OnUpdate on SHOWN frames. Both panels can become hidden via
-- normal user paths: (a) cached.isVisible=false from /ss hide, (b) split mode
-- with all primary/offensive/tertiary stats disabled — mainPanel:SetTextSafe
-- with lineCount=0 calls Hide(), and the defensive-only data on the OTHER panel
-- would freeze because the ticker stopped firing. A standalone, never-hidden
-- frame keeps the update loop independent of user-visible panel state.
-- The cost of running UpdateStats during /ss hide is one early-return per tick.
local timeSinceLastUpdate = 0
local tickerFrame = CreateFrame("Frame")
tickerFrame:SetScript("OnUpdate", function(self, elapsed)
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

local RefreshPersistentLocalization

local function OnPlayerEnteringWorld()
    if not isLoaded then
        -- One-time legacy-DB carry-forward. Runs at PEW (not at file scope) so source
        -- globals are reliably populated regardless of addon load order. Triggers only
        -- when StatsPro's DB is empty AND a legacy global has content — these guards
        -- prevent clobbering existing StatsPro state and avoid no-op writes on fresh
        -- installs. Source priority:
        --   1. `_G.SwiftStatsDB` — the original public SwiftStats by TaylorSay (most
        --      users coming from the upstream addon land here).
        --   2. `_G.SwiftStatsLocalDB` — fallback for an earlier internal name of this
        --      addon (renamed to StatsPro before publication).
        -- CopyTable: deep copy so color-picker edits in either addon, while both are
        -- simultaneously enabled, don't silently alias and mutate the other's table.
        local db = EnsureStatsProDBTable()
        if next(db) == nil then
            local swiftStatsDB = type(_G.SwiftStatsDB) == "table" and _G.SwiftStatsDB or nil
            local swiftStatsLocalDB = type(_G.SwiftStatsLocalDB) == "table" and _G.SwiftStatsLocalDB or nil
            local source = (swiftStatsDB and next(swiftStatsDB) ~= nil and swiftStatsDB)
                        or (swiftStatsLocalDB and next(swiftStatsLocalDB) ~= nil and swiftStatsLocalDB)
            if source then
                for k, v in pairs(source) do
                    db[k] = (type(v) == "table") and CopyTable(v) or v
                end
            end
        end
        MigrateDB()
        CacheSettings()
        if RefreshPersistentLocalization then RefreshPersistentLocalization() end
        -- WHY here: forceLocale is migrated + cached.activeLabels resolved; if active
        -- locale needs glyphs db.font lacks, auto-switch BEFORE the
        -- ApplyTextStyleToAllPanels call below so the FontStrings load with the
        -- correct font on the very first frame (no `?` boxes for one session).
        MaybeAutoSwitchFont()
        LoadAllPositions()
        SetAllPanelsLockState(GetBoolDB("isLocked"))
        SetAllPanelsScale(GetNumberDB("scale"))
        -- WHY re-apply font/size at PEW: Panel:New creates FontStrings at file scope
        -- with whatever GetFontDB() returns BEFORE MigrateDB runs. If the migration
        -- changed db.font (e.g. v3→v4 hardcoded → STANDARD_TEXT_FONT auto-upgrade),
        -- the FontStrings would still hold the pre-migration font for the entire
        -- session until /reload. CJK users on the old default would see `?` boxes for
        -- their localized labels for one whole session. Re-applying after MigrateDB
        -- closes that window.
        ApplyTextStyleToAllPanels(GetFontDB(), GetNumberDB("fontSize"))
        -- WHY re-apply textAlpha at PEW: Panel:New runs at file scope before CacheSettings,
        -- so cached.textAlpha is nil at FontString creation. This propagates the user's
        -- saved alpha to FontStrings on the first frame.
        ApplyTextAlphaToAllPanels(cached.textAlpha)
        addon.readabilityConfig.applyPanelBackgroundAlphaToAllPanels(cached.panelBackgroundAlpha)
        isLoaded = true
    end
    -- WHY: UpdateStats handles Show/Hide based on cached.isVisible + line content.
    durabilityDirty = true
    itemLevelDirty = true
    UpdateStats()
end

-- WHY: Armor/DR refresh runs inline in UpdateStats out-of-combat (cheap), so we
-- don't need PLAYER_REGEN_ENABLED / PLAYER_SPECIALIZATION_CHANGED / TRAIT_CONFIG_UPDATED /
-- PLAYER_LEVEL_UP handlers. Worst-case latency for stat refresh is one OnUpdate tick (~0.5s).
-- WHY MERCHANT_SHOW marks dirty: repairCost can surface after the old cached scan
-- already settled at 0, and opening a vendor does not necessarily fire a durability event.
-- The handler only flips the dirty flag; the OnUpdate path still coalesces the scan.
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
    PLAYER_EQUIPMENT_CHANGED    = function() durabilityDirty = true; itemLevelDirty = true end,
    BAG_UPDATE_DELAYED          = function() itemLevelDirty = true end,
    MERCHANT_SHOW               = function() durabilityDirty = true end,
    -- WHY: lock state is stored in cached.isLocked and read by OnDragStart. Mouse stays
    -- enabled permanently so right-click Settings works even while locked; Panel:Lock /
    -- Panel:Unlock are no-op stubs kept behind this semantic wrapper.
    PLAYER_REGEN_ENABLED        = function() SetAllPanelsLockState(GetBoolDB("isLocked")) end,
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

-- WHY centralized layout constants: a tweak (tighter swatch gap, wider columns) used
-- to require hunting ~10 callsites with hardcoded 6/220/12/"FRIZQT" literals — easy to
-- miss one and ship inconsistent UI. CONFIG_FONT routes through LocaleAwareDefaultFont
-- to dodge the FRIZQT-on-CJK rendering trap (AGENTS.md "Hardcoded default font path")
-- while resisting third-party-addon hijacks of the STANDARD_TEXT_FONT global.
local CONFIG_FONT       = LocaleAwareDefaultFont()
local CONFIG_FONT_SIZE  = 12

-- Locale-aware settings UI font: same idea as MaybeAutoSwitchFont for stat panels,
-- but for the config window's CreateFontString-based labels (title, tabs, section
-- headers, checkboxes, sliders, dropdown captions, font picker rows, langWarn).
-- Blizzard FontObjects (GameFontNormal etc. used by buttons) carry built-in OS
-- fallback so they render Cyrillic/CJK acceptably; explicit SetFont(CONFIG_FONT, ...)
-- does NOT — without this swap, ruRU/zhCN previews on enUS clients render as boxes
-- even though stat panels next to them render correctly. RegisterConfigFont collects
-- every settings-UI FontString + its (size, flags) at creation time so ApplyConfigFont
-- can re-apply with a glyph-compatible font on language change without rebuilding.
local currentConfigFont    = CONFIG_FONT
local localizedConfigFonts = {}

-- Pure resolver mirroring ResolveActiveLocale → MaybeAutoSwitchFont's FindCompatibleFont
-- pattern, but with CONFIG_FONT as baseline (settings UI default) instead of db.font.
-- Returns CONFIG_FONT unchanged when current locale's glyphs are already covered
-- (e.g. enUS-back-switch from ruRU). Returns nil-via-`or` fallback only when no font
-- in the 3-tier chain supports the locale (Korean on enUS without LSM K_Damage) —
-- visible glyph gap is acceptable, langWarn already surfaces the problem.
-- WHY no `local`: assigning the forward-decl'd upvalue declared earlier in this section.
ResolveConfigFont = function(activeLocale)
    local req = LOCALE_GLYPH_REQ[activeLocale] or GLYPH_LATIN
    return FindCompatibleFont(CONFIG_FONT, req) or CONFIG_FONT
end

-- Settings-UI font register: collects every settings FontString + its (size, flags) so
-- ApplyConfigFont can re-apply with a glyph-compatible font on language change without
-- a UI rebuild. Initial set uses currentConfigFont (locale-correct via PEW MaybeAutoSwitchFont).
local function RegisterConfigFont(fs, size, flags)
    fs:SetFont(currentConfigFont, size, flags)
    tinsert(localizedConfigFonts, { fs = fs, size = size, flags = flags })
end

-- Called from MaybeAutoSwitchFont and PreviewLanguage/CancelLanguagePreview. Idempotent
-- fast-path skips work when currentConfigFont already matches (covers PEW + back-to-
-- default-locale scenarios). WHY no `local`: assigns the forward-decl'd upvalue.
ApplyConfigFont = function(font)
    if SameFontPath(font, currentConfigFont) then return end
    currentConfigFont = font
    for _, e in ipairs(localizedConfigFonts) do
        e.fs:SetFont(font, e.size, e.flags)
    end
end
local CONFIG_SWATCH_GAP = 6     -- label.RIGHT → swatch.LEFT
local CONFIG_COL_OFFSET = 220   -- left-col x → right-col x within a 2-column section
-- WHY separate from CONFIG_SWATCH_GAP: heavy chrome on UIDropDownMenuTemplate may want
-- different breathing room than flat color swatches; tracked independently so a future
-- visual tweak to the dropdown column doesn't ripple through swatch placements.
local CONFIG_DROPDOWN_GAP = 6   -- label.RIGHT → dropdown TOPLEFT x gap (matches swatch column rhythm)
-- Vertical offset from a label row's baseline (rowY) to its dropdown's TOPLEFT y. Positive
-- value lifts the dropdown 2px above rowY so the dropdown chrome visually centers around
-- the label text. Shared across Display Mode / Language / Font so all 3 rows align identically.
local CONFIG_DROPDOWN_Y_OFFSET = 2
-- Dropdown body width: 100px for all three (Display Mode / Language / Font). Long-content
-- labels (Language's "Auto (current: %s)" and Latin-with-parenthetical locale labels) get
-- a CompactLabel transform that strips parentheticals so text fits without truncation. Menu
-- items keep the full label form for disambiguation when picking. Font names from SharedMedia
-- can occasionally overflow at 100px — accepted: rare, names truncate to "Long Name..." and
-- the user can hover the dropdown for full text via Blizzard's tooltip.

-- Single source of truth for "DB color or fallback to default". Used by every
-- color-related helper + their refreshers; lazily initializes the colors table
-- (StatsProDB may not have it yet on a fresh install).
local function GetColor(statName)
    local db = EnsureStatsProDBTable()
    if type(db.colors) ~= "table" then db.colors = {} end
    local r, g, b = NormalizeColor(db.colors[statName], defaults.colors[statName])
    return { r = r, g = g, b = b }
end

-- WHY forward-decl: CreateCheckbox / CursorSection / CreateConfigSlider / CreateTabButton
-- below all register a setter via PushLocalizedLabel, but the function body lives further
-- down in the file (it depends on localizedConfigLabels declared lower). Upvalue resolution
-- is at call time — assignment happens before any helper is invoked from OpenConfigMenu.
local PushLocalizedLabel

local function CreateCheckbox(parent, name, label, dbKey, x, y, onChange, textWidth)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    cb:SetSize(22, 22)
    local text = _G[name .. "Text"]
    PushLocalizedLabel(function() text:SetText(L(label)) end)
    RegisterConfigFont(text, CONFIG_FONT_SIZE)
    -- textWidth: 200 default for plain checkboxes; pass 140 for "checkbox + inline color"
    -- rows (CreateCheckboxColor overrides the bound width to actual text width post-call).
    text:SetWidth(textWidth or 200)
    text:SetJustifyH("LEFT")
    cb:SetChecked(GetBoolDB(dbKey))
    cb:SetScript("OnClick", function(self)
        StatsProDB[dbKey] = self:GetChecked()
        CacheSettings()
        if onChange then onChange(self:GetChecked()) end
        UpdateStats()
    end)
    PushRefresher(function() cb:SetChecked(GetBoolDB(dbKey)) end)
    return cb, text
end

-- Toggle a checkbox's enabled state with matching label dim. Used by dependent-toggle
-- greying patterns (split routing gated on Split mode; Leech/Avoidance/Speed gated on
-- Show Tertiary Stats master) to make the dependency visible.
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

-- WHY: shared snapshot/select/cancel handler used by every swatch (CreateColorSwatch
-- buttons route OnClick here). Snapshot is taken at click time, not creation time, so
-- cancelling a 2nd pick reverts to the user's prior color, not the original default.
local COLOR_PICKER_STATE = { active = nil, token = 0 }

function COLOR_PICKER_STATE.IsActive(session)
    return COLOR_PICKER_STATE.active == session
end

function COLOR_PICKER_STATE.Clear(session)
    if COLOR_PICKER_STATE.IsActive(session) then
        COLOR_PICKER_STATE.active = nil
    end
end

function COLOR_PICKER_STATE.OnFrameHide()
    if COLOR_PICKER_STATE.active then
        COLOR_PICKER_STATE.active = nil
    end
end

function COLOR_PICKER_STATE.EnsureFrameHook()
    if COLOR_PICKER_STATE.hooked then return end
    if ColorPickerFrame and ColorPickerFrame.HookScript then
        ColorPickerFrame:HookScript("OnHide", COLOR_PICKER_STATE.OnFrameHide)
        COLOR_PICKER_STATE.hooked = true
    end
end

function COLOR_PICKER_STATE.Close()
    local session = COLOR_PICKER_STATE.active
    if not session then return end
    if ColorPickerFrame and ColorPickerFrame:IsShown() then
        if session.cancelFunc then
            session.cancelFunc()
        else
            COLOR_PICKER_STATE.Clear(session)
        end
        ColorPickerFrame:Hide()
    else
        COLOR_PICKER_STATE.Clear(session)
    end
end
StatsProCloseColorPicker = COLOR_PICKER_STATE.Close

local function OpenColorPicker(btn, statName)
    COLOR_PICKER_STATE.Close()
    COLOR_PICKER_STATE.EnsureFrameHook()
    -- WHY: capture "uses default" state so cancel can restore exactly that — writing
    -- the resolved-default tuple back would convert unset → explicit-default in DB
    -- (visible only between cancel and the next /reload, but the invariant is correct).
    if type(StatsProDB.colors) ~= "table" then StatsProDB.colors = {} end
    local hadExplicitColor = IsCompleteColor(StatsProDB.colors[statName])
    local current = GetColor(statName)
    local snapshot = { r = current.r, g = current.g, b = current.b }

    COLOR_PICKER_STATE.token = COLOR_PICKER_STATE.token + 1
    local session = {
        token = COLOR_PICKER_STATE.token,
        btn = btn,
        statName = statName,
        hadExplicitColor = hadExplicitColor,
        snapshot = snapshot,
    }

    local function OnColorSelect()
        if not COLOR_PICKER_STATE.IsActive(session) then return end
        local r, g, b = ColorPickerFrame:GetColorRGB()
        btn:SetBackdropColor(r, g, b, 1)
        StatsProDB.colors[statName] = { r = r, g = g, b = b }
        CacheSettings()
        UpdateStats()
    end
    local function OnCancel()
        if not COLOR_PICKER_STATE.IsActive(session) then return end
        btn:SetBackdropColor(snapshot.r, snapshot.g, snapshot.b, 1)
        StatsProDB.colors[statName] = hadExplicitColor and { r = snapshot.r, g = snapshot.g, b = snapshot.b } or nil
        CacheSettings()
        UpdateStats()
        COLOR_PICKER_STATE.Clear(session)
    end
    session.swatchFunc = OnColorSelect
    session.cancelFunc = OnCancel
    ColorPickerFrame:SetupColorPickerAndShow({
        r = snapshot.r, g = snapshot.g, b = snapshot.b,
        opacity = 1, hasOpacity = false,
        swatchFunc = OnColorSelect,
        cancelFunc = OnCancel,
    })
    COLOR_PICKER_STATE.active = session
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

-- WHY swatch anchored to text:RIGHT (not absolute x): the swatch hugs the actual rendered
-- label end with CONFIG_SWATCH_GAP — works for any locale (en "Show Avoidance" ≠ ru "Уворот"
-- pixel widths). For groups of rows that should form a vertical column of swatches, call
-- AlignSwatchColumn(rows) post-creation — it normalizes all texts to the group's max
-- GetStringWidth so swatches line up at the same x relative to column start.
local function CreateCheckboxColor(parent, name, label, dbKey, colorKey, x, y, onChange)
    local cb, text = CreateCheckbox(parent, name, label, dbKey, x, y, onChange, 140)
    local swatch
    if colorKey then
        -- Override the 140-bound width with actual text rendering width — swatch needs
        -- to hug the text end, not the right edge of the 140px reservation.
        text:SetWidth(text:GetStringWidth())
        swatch = CreateColorSwatch(parent, colorKey, 0, 0)
        swatch:ClearAllPoints()
        swatch:SetPoint("LEFT", text, "RIGHT", CONFIG_SWATCH_GAP, 0)
    end
    return cb, swatch, text
end

-- Tracked groups + L()-using labels for re-alignment on language change. Config labels
-- are rebuilt/wiped with the config window; persistent labels are file-scope launchers
-- that must survive OpenConfigMenu's one-shot registry reset.
local alignmentGroups = {}
local localizedConfigLabels = {}
local localizedPersistentLabels = {}

-- WHY unconstrain-before-measure: a prior AlignSwatchColumn or a SetText with text wider
-- than the current SetWidth would leave the FontString in wrap/truncate mode, where
-- GetStringWidth returns the wrapped width (≤ SetWidth), not the natural width. Setting a
-- huge SetWidth first forces single-line layout so GetStringWidth returns the real width
-- of the new text — critical when language switch grows a label (en "Crit" → ru "Крит. удар").
local function ReAlignGroupImpl(rows, gap)
    for _, row in ipairs(rows) do
        row.text:SetWidth(9999)
    end
    local maxW = 0
    for _, row in ipairs(rows) do
        local w = row.text:GetStringWidth()
        if w > maxW then maxW = w end
    end
    for _, row in ipairs(rows) do
        row.text:SetWidth(maxW)
        if row.swatch then
            row.swatch:ClearAllPoints()
            row.swatch:SetPoint("LEFT", row.text, "RIGHT", gap, 0)
        elseif row.dropdown then
            -- WHY TOPLEFT (not LEFT-to-RIGHT like swatches): UIDropDownMenuTemplate's chrome
            -- height and internal vertical padding aren't reliable to compute a y-offset that
            -- centers dropdown text on label baseline. Preserve each row's original TOPLEFT y
            -- (hand-tuned at row creation) and only update x to the shared column.
            row.dropdown:ClearAllPoints()
            row.dropdown:SetPoint("TOPLEFT", row.dropdownParent, "TOPLEFT",
                row.dropdownX_base + maxW + gap, row.dropdownY)
        end
    end
end

-- AlignSwatchColumn: post-creation max-width sync for a group of rows that should share a
-- control column (swatch OR dropdown — both anchor relative to label.RIGHT, dispatch on
-- which field is set). rows[i] = { text=FontString, swatch=Frame? } for swatch rows;
-- { text=FontString, dropdown=Frame, dropdownX_base=number, dropdownY=number,
-- dropdownParent=Frame } for dropdown rows. Locale-aware: measures actual rendered widths
-- in the current font, no hardcoded en-biased SetWidth(N). Registers the group so
-- RefreshConfigLocalization() can re-run alignment after a language switch shrinks or
-- grows the labels.
local function AlignSwatchColumn(rows, gap)
    gap = gap or CONFIG_SWATCH_GAP
    ReAlignGroupImpl(rows, gap)
    tinsert(alignmentGroups, { rows = rows, gap = gap })
end

-- PushLocalizedLabel: register a setter closure that calls fs:SetText with a fresh L()-resolved
-- string. RefreshConfigLocalization() replays every setter when forceLocale changes, then
-- re-aligns all groups (label widths shift on translation: "Versatility" → "Унив" is shorter,
-- "Crit" → "致命一击" is wider). Initial set is performed here so callers don't duplicate it.
-- WHY no `local`: forward-declared above CreateCheckbox; reassigns the existing upvalue.
PushLocalizedLabel = function(setter)
    tinsert(localizedConfigLabels, setter)
    setter()
end

local function PushPersistentLocalizedLabel(setter)
    tinsert(localizedPersistentLabels, setter)
    setter()
end

RefreshPersistentLocalization = function()
    for _, setter in ipairs(localizedPersistentLabels) do setter() end
end

-- RefreshConfigLocalization: re-runs all SetText setters and re-aligns every registered group.
-- Called from the Language dropdown's selection handler after CacheSettings() updates
-- cached.activeLabels — all L() calls inside setters now resolve to the new locale.
local function RefreshConfigLocalization()
    RefreshPersistentLocalization()
    for _, setter in ipairs(localizedConfigLabels) do setter() end
    for _, g in ipairs(alignmentGroups) do
        ReAlignGroupImpl(g.rows, g.gap)
    end
end

--[[ ============================================================
    15. CONFIG MENU (tabs: Stats / Layout / Appearance)
============================================================ ]]
-- Forward-decls — assigned during OpenConfigMenu's Appearance-tab build pass
-- (the Lua frame variable is `displayTab`; UI label is "Appearance").
-- RefreshLanguageWarning: assigned in Localization section; captured by font dropdown's
-- PickFont closure to refresh the inline warning when the user picks a font that may not
-- cover the active locale's glyphs.
-- fontDropdown / CurrentFontName: assigned in Typography section (which builds AFTER
-- Localization in the source); captured by language-dropdown info.func to keep the font
-- dropdown caption in sync after MaybeAutoSwitchFont silently changes db.font.
local RefreshLanguageWarning
local fontDropdown
local CurrentFontName

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

-- WHY: Lua 5.1 string.upper is byte-based; mangles UTF-8. ASCII fast-pathed,
-- Cyrillic basic+extended (а..я + ё/ѐ/і/ї/ў etc.) and Latin Supplement (à-þ excl.
-- ÷/ß/ÿ) mapped via byte arithmetic. 3/4-byte sequences (CJK/emoji) pass identity.
-- Lead-byte ranges per RFC 3629; malformed input progresses 1 byte to avoid infinite loop.
local function Utf8CharLen(s, i)
    local b1 = s and string.byte(s, i or 1)
    if not b1 then return 0 end
    if b1 < 0x80 then return 1 end
    if b1 >= 0xC2 and b1 <= 0xDF then return 2 end
    if b1 >= 0xE0 and b1 <= 0xEF then return 3 end
    if b1 >= 0xF0 and b1 <= 0xF7 then return 4 end
    return 1
end

local function Utf8Upper(s)
    if not string.find(s, "[\128-\255]") then return string.upper(s) end
    local out, i, n = {}, 1, #s
    while i <= n do
        local b1 = string.byte(s, i)
        if b1 < 0x80 then
            out[#out+1] = string.upper(string.char(b1))
            i = i + 1
        elseif b1 == 0xD0 then
            local b2 = string.byte(s, i+1)
            if b2 and b2 >= 0xB0 and b2 <= 0xBF then
                out[#out+1] = string.char(0xD0, b2 - 0x20)
            else
                out[#out+1] = string.sub(s, i, i+1)
            end
            i = i + 2
        elseif b1 == 0xD1 then
            local b2 = string.byte(s, i+1)
            if b2 and b2 >= 0x80 and b2 <= 0x8F then
                out[#out+1] = string.char(0xD0, b2 + 0x20)
            elseif b2 and b2 >= 0x90 and b2 <= 0x9F then
                out[#out+1] = string.char(0xD0, b2 - 0x10)
            else
                out[#out+1] = string.sub(s, i, i+1)
            end
            i = i + 2
        elseif b1 == 0xC3 then
            -- Latin Supplement (à-ï/ñ-ö/ø-þ): b2 - 0x20 mirrors ASCII toupper.
            -- Skip 0xB7 (÷ — math sign, not a letter); 0xBF (ÿ → Ÿ U+0178) is
            -- 2-byte→2-byte to a different page (C5 B8) — rare, identity for v1.
            -- 0x9F (ß) stays identity (case-folds to "SS" in modern German, length-changing).
            local b2 = string.byte(s, i+1)
            if b2 and b2 >= 0xA0 and b2 <= 0xBE and b2 ~= 0xB7 then
                out[#out+1] = string.char(0xC3, b2 - 0x20)
            else
                out[#out+1] = string.sub(s, i, i+1)
            end
            i = i + 2
        else
            local charLen = Utf8CharLen(s, i)
            out[#out+1] = string.sub(s, i, i + charLen - 1)
            i = i + charLen
        end
    end
    return table.concat(out)
end

local function FirstUTF8Char(s)
    if not s or s == "" then return "" end
    local charLen = Utf8CharLen(s, 1)
    if charLen <= 0 then return "" end
    return string.sub(s, 1, charLen)
end

GetStyledLabelText = function(englishKey, labelStyle)
    local base = L(englishKey)
    if not base or base == "" then return "" end

    local style = NormalizeLabelStyle(labelStyle)
    if style == "hidden" then
        return ""
    elseif style == "short" then
        local first = FirstUTF8Char(base)
        if first == "" then return "" end
        return first .. ":"
    end
    return base .. ":"
end
-- CursorSection: section header with green underline. label is dual-role: L-key + enUS fallback.
local function CursorSection(c, label)
    local hdr = c.parent:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(hdr, CONFIG_FONT_SIZE, "OUTLINE")
    hdr:SetPoint("TOPLEFT", c.parent, "TOPLEFT", c.padX, c.y)
    PushLocalizedLabel(function() hdr:SetText("|cff00ff7f" .. Utf8Upper(L(label)) .. "|r") end)
    local line = c.parent:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", c.parent, "TOPLEFT", c.padX, c.y - 18)
    line:SetPoint("TOPRIGHT", c.parent, "TOPRIGHT", -c.padX, c.y - 18)
    line:SetHeight(1)
    line:SetColorTexture(0, 1, 0.5, 0.25)
    c.y = c.y - 24 - c.gap
end

local coalesceGenerations = {}
local function RunCoalesced(key, delay, fn)
    coalesceGenerations[key] = (coalesceGenerations[key] or 0) + 1
    local generation = coalesceGenerations[key]
    C_Timer.After(delay, function()
        if coalesceGenerations[key] == generation then
            fn()
        end
    end)
end

-- CreateConfigSlider: standard label-on-top + horizontal slider pattern used across
-- the Appearance tab. valueFmt is a string.format specifier (e.g. "%.1f", "%d") applied
-- to both initial display and live OnValueChanged updates. SetObeyStepOnDrag(true) +
-- step=1 guarantees integer values for "%d" sliders. cd cursor advances by 50.
local function CreateConfigSlider(parent, name, labelText, dbKey, cd, minVal, maxVal, step, lowText, highText, valueFmt, onChange)
    local sliderY = cd.y
    local lbl = parent:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(lbl, CONFIG_FONT_SIZE)
    lbl:SetPoint("TOPLEFT", cd.padX, sliderY)
    PushLocalizedLabel(function() lbl:SetText(L(labelText)) end)

    local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", cd.padX, sliderY - 18)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    slider:SetWidth(420)
    local initialValue = NUMBER_SETTING_META[dbKey] and GetNumberDB(dbKey) or GetDB(dbKey)
    slider:SetValue(initialValue)
    _G[name .. "Low"]:SetText(lowText)
    _G[name .. "High"]:SetText(highText)
    _G[name .. "Text"]:SetText(string.format(valueFmt, slider:GetValue()))

    slider:SetScript("OnValueChanged", function(self, value)
        local normalized = NUMBER_SETTING_META[dbKey] and NormalizeNumberSetting(dbKey, value) or value
        _G[self:GetName() .. "Text"]:SetText(string.format(valueFmt, normalized))
        StatsProDB[dbKey] = normalized
        if onChange then onChange(normalized) end
    end)

    PushRefresher(function()
        local v = NUMBER_SETTING_META[dbKey] and GetNumberDB(dbKey) or GetDB(dbKey)
        slider:SetValue(v)
        _G[slider:GetName() .. "Text"]:SetText(string.format(valueFmt, v))
    end)

    cd.y = sliderY - 50
    return slider
end

-- Reset all settings to defaults — callable from both the resetBtn:OnClick (in
-- OpenConfigMenu) and the /ss reset slash command (section 17). All deps are
-- file-scope or global; configRefreshers / RefreshConfigLocalization no-op safely
-- when settings UI has never been opened (empty arrays at file scope).
local function ResetToDefaults()
    -- Preserve the user's current output language for the confirmation, because
    -- reset itself restores forceLocale to "auto" before the final chat message.
    local resetMessage = L("Settings reset to defaults")

    -- Step 1: close any open modal BEFORE touching DB.
    -- WHY: StatsPro's color picker close path explicitly restores its snapshot
    -- before hiding the Blizzard singleton; ColorPickerFrame:Hide() alone does
    -- not call cancelFunc on current retail clients. If
    -- we did DB reset first, that cancelFunc would clobber the just-reset default.
    -- Closing first means cancelFunc writes to a (soon-overwritten) DB — irrelevant.
    -- Custom font picker is NOT a Blizzard dropdown so CloseDropDownMenus doesn't reach it;
    -- explicit Hide triggers its OnHide which forcibly re-syncs panels with DB.font.
    CloseDropDownMenus()
    if _G.StatsProFontPicker and _G.StatsProFontPicker:IsShown() then
        _G.StatsProFontPicker:Hide()
    end
    COLOR_PICKER_STATE.Close()

    -- Step 2: reset DB scalars + colors to defaults.
    for k, v in pairs(defaults) do
        if type(v) ~= "table" then StatsProDB[k] = v end
    end
    -- Explicit cleanup of fields not in defaults (the loop above only writes present-key
    -- defaults). These would linger in DB across Reset otherwise:
    --   - useLocalizedLabels: dropped in v4→v5 migration; legacy users may still have it
    --   - fontBeforeAutoSwitch: transient runtime state set when MaybeAutoSwitchFont fires
    StatsProDB.useLocalizedLabels = nil
    StatsProDB.fontBeforeAutoSwitch = nil
    StatsProDB.colors = CopyTable(defaults.colors)
    StatsProDB.dbVersion = CURRENT_DB_VERSION

    -- Step 3: re-cache + re-apply panel-level visual state.
    CacheSettings()
    ApplyTextStyleToAllPanels(defaults.font, defaults.fontSize)
    ApplyTextAlphaToAllPanels(cached.textAlpha)
    addon.readabilityConfig.applyPanelBackgroundAlphaToAllPanels(cached.panelBackgroundAlpha)
    -- Sync settings-UI font to the fresh default-locale state. Without this, a Reset
    -- performed while forceLocale was a non-baseline locale (e.g. ruRU on enUS — UI was
    -- in ARIALN via prior MaybeAutoSwitchFont) would leave currentConfigFont stuck on
    -- ARIALN even though forceLocale just reset to "auto" → enUS. Idempotent — no-op
    -- when font is already the locale-correct baseline.
    ApplyConfigFont(ResolveConfigFont(ResolveActiveLocale()))
    SetAllPanelsScale(defaults.scale)
    LoadAllPositions()
    SetAllPanelsLockState(defaults.isLocked)
    UpdateStats()

    -- Step 4: re-sync config widget visuals from freshly-reset DB.
    -- WHY pcall: a buggy refresher should not break the entire walk. Print error
    -- context instead of silent fail (AGENTS.md "Log meaningful context").
    -- No-op when configRefreshers is empty (slash called pre-config-open).
    for _, fn in ipairs(configRefreshers) do
        local ok, err = pcall(fn)
        if not ok then PrintMsg("refresher error: " .. tostring(err)) end
    end
    -- WHY also RefreshConfigLocalization: Reset writes forceLocale=auto, so L() now
    -- resolves to a (potentially) different locale. Stat color picker labels need to
    -- re-set + groups re-align to match. configRefreshers above only re-sync checkbox
    -- states / swatch colors / dropdown text, not L()-using labels. No-op when
    -- localizedConfigLabels and alignmentGroups are empty (slash called pre-config-open).
    RefreshConfigLocalization()

    PrintMsg(resetMessage)
end

function addon.archonTargets.GetTargetSnapshotDropdownValue()
    return addon.archonTargets.NormalizeSnapshotKey(GetDB("targetSnapshot"))
end

function addon.archonTargets.SelectTargetSnapshotDropdownValue(value, opt, dropdown)
    StatsProDB.targetSnapshot = addon.archonTargets.NormalizeSnapshotKey(value)
    CacheSettings()
    UIDropDownMenu_SetText(dropdown, L(opt.label))
    CloseDropDownMenus()
    UpdateStats()
end
-- WARNING: OpenConfigMenu is already near Lua 5.1's 60-upvalue function limit.
-- Keep these as global bridge references instead of local upvalues inside the builder.
_G.StatsProTargetSnapshotDropdownOptions = addon.archonTargets.snapshotOptions
_G.StatsProGetTargetSnapshotDropdownValue = addon.archonTargets.GetTargetSnapshotDropdownValue
_G.StatsProSelectTargetSnapshotDropdownValue = addon.archonTargets.SelectTargetSnapshotDropdownValue

function addon:OpenConfigMenu()
    if configFrame then
        if configFrame:IsShown() then
            configFrame:Hide()
        else
            configFrame:Show()
            -- Always reopen on the first tab (Stats) — predictable UX, matches initial open.
            if configFrame.SwitchToTab then configFrame.SwitchToTab(1) end
        end
        return
    end

    -- WHY: future-proofing — body below runs exactly once per session due to
    -- the early-return guard above, but if anyone makes this re-entrant the
    -- refresher list would duplicate every entry. Cheap insurance.
    wipe(configRefreshers)
    wipe(alignmentGroups)
    wipe(localizedConfigLabels)
    wipe(localizedConfigFonts)
    -- Function-local: collected during the Appearance tab build, aligned once at end of
    -- the Typography section via AlignSwatchColumn(displayDropdownRows, CONFIG_DROPDOWN_GAP).
    -- Table reference retained via alignmentGroups after registration so RefreshConfigLocalization
    -- can re-run alignment when locale-driven label widths shift.
    local layoutDropdownRows = {}
    local displayDropdownRows = {}
    local function CreateSimpleDropdownRow(parent, rows, frameName, labelKey, options, cursor, getValue, onSelect)
        local rowY = cursor.y

        local label = parent:CreateFontString(nil, "OVERLAY")
        RegisterConfigFont(label, CONFIG_FONT_SIZE)
        label:SetPoint("TOPLEFT", cursor.padX, rowY - 4)

        local dropdown = CreateFrame("Frame", frameName, parent, "UIDropDownMenuTemplate")
        -- Placeholder anchor; AlignSwatchColumn re-anchors at column x = cd.padX + maxLabelW + CONFIG_DROPDOWN_GAP after all dropdown rows build.
        dropdown:SetPoint("TOPLEFT", cursor.padX + 100, rowY + CONFIG_DROPDOWN_Y_OFFSET)
        UIDropDownMenu_SetWidth(dropdown, 100)
        UIDropDownMenu_JustifyText(dropdown, "CENTER")

        local function ResolveOption(value)
            for _, opt in ipairs(options) do
                if opt.value == value then return opt end
            end
            return options[1]
        end

        local function RefreshDropdownText()
            label:SetText(L(labelKey))
            UIDropDownMenu_SetText(dropdown, L(ResolveOption(getValue()).label))
        end

        UIDropDownMenu_Initialize(dropdown, function()
            local current = getValue()
            for _, opt in ipairs(options) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = L(opt.label)
                info.value = opt.value
                info.checked = (current == opt.value)
                info.func = function()
                    onSelect(opt.value, ResolveOption(opt.value), dropdown)
                end
                UIDropDownMenu_AddButton(info)
            end
        end)

        PushLocalizedLabel(RefreshDropdownText)
        PushRefresher(RefreshDropdownText)
        tinsert(rows, {
            text = label, dropdown = dropdown,
            dropdownX_base = cursor.padX, dropdownY = rowY + CONFIG_DROPDOWN_Y_OFFSET, dropdownParent = parent,
        })
        cursor.y = rowY - 30
        return dropdown, label
    end

    --[[ ===== Frame ===== ]]
    configFrame = CreateFrame("Frame", "StatsProConfigFrame", UIParent, "BackdropTemplate")

    -- WARNING: cap by parent so footer (Reset/Close at BOTTOM y=14) stays on-screen.
    -- Floor 200 protects ScrollFrame chrome (82+60=142) from collapse on low-res.
    local function ApplyConfigFrameSize()
        local maxH = math.max(200, math.min(540, UIParent:GetHeight() * 0.9))
        configFrame:SetSize(500, maxH)
    end
    ApplyConfigFrameSize()

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
    configFrame:SetFrameStrata("DIALOG")
    -- WHY: guarded as a one-shot for symmetry — the early-return at the top of
    -- OpenConfigMenu already ensures this body runs once per session, but the flag
    -- means even a re-entrant rebuild wouldn't double-add to UISpecialFrames.
    if not configSpecialFrameRegistered then
        tinsert(UISpecialFrames, "StatsProConfigFrame")
        configSpecialFrameRegistered = true
    end

    configFrame:HookScript("OnShow", ApplyConfigFrameSize)

    -- Auto-close font picker + Blizzard dropdown lists when Settings UI hides (e.g., /ss
    -- toggle, click X, Esc). Both are parented to UIParent (NOT configFrame) so neither
    -- auto-hides via parent — without these calls Esc-while-langDropdown-open leaves an
    -- orphan dropdown list above (and a stale langPreview state until user clicks elsewhere
    -- to trigger DropDownList1:OnHide → CancelLanguagePreview).
    configFrame:HookScript("OnHide", function()
        CloseDropDownMenus()  -- closes any active Blizzard dropdown; fires its OnHide → CancelLanguagePreview
        if StatsProCloseColorPicker then StatsProCloseColorPicker() end
        if _G.StatsProFontPicker and _G.StatsProFontPicker:IsShown() then
            _G.StatsProFontPicker:Hide()
        end
    end)

    --[[ ===== Header (title + X) ===== ]]
    local title = configFrame:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(title, 16, "OUTLINE")
    title:SetPoint("TOP", 0, -12)
    PushLocalizedLabel(function()
        title:SetText("|cff00ff7fStatsPro|r v" .. ADDON_VERSION .. " " .. L("Settings"))
    end)

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
    PushLocalizedLabel(function() resetBtn:SetText(L("Reset to Defaults")) end)
    resetBtn:SetNormalFontObject("GameFontNormal")
    resetBtn:SetHighlightFontObject("GameFontHighlight")

    local closeBtn = CreateFrame("Button", nil, configFrame, "GameMenuButtonTemplate")
    closeBtn:SetPoint("BOTTOMRIGHT", -18, 14)
    closeBtn:SetSize(100, 26)
    PushLocalizedLabel(function() closeBtn:SetText(L("Close")) end)
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

    -- Tab content frames (children of scrollChild). Tab order: content toggles (Stats),
    -- layout/routing, then appearance (typography / localization). Variable
    -- `displayTab` backs the UI tab labelled "Appearance" (see `names` array below).
    local displayTab   = CreateFrame("Frame", nil, scrollChild)
    local statsTab     = CreateFrame("Frame", nil, scrollChild)
    local layoutTab    = CreateFrame("Frame", nil, scrollChild)
    local tabContents  = { statsTab, layoutTab, displayTab }
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
        RegisterConfigFont(txt, 13, "OUTLINE")
        txt:SetPoint("CENTER", 0, 1)
        PushLocalizedLabel(function() txt:SetText(L(label)) end)
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
        local names = { "Stats", "Layout", "Appearance" }
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

    --[[ ===== LAYOUT TAB ===== ]]
    local cd = NewCursor(layoutTab, 12, -8)
    local splitBlockChecks = {}
    local function ApplySplitBlockChecksEnabled()
        local enabled = GetDB("displayMode") == "split"
        for _, cb in ipairs(splitBlockChecks) do
            SetCheckboxEnabled(cb, enabled)
        end
    end

    -- Frame & Position section: panel-level container settings (visibility, lock, layout
    -- mode, scale, update rate). Most-used controls; sits at top.
    CursorSection(cd, "Frame & Position")
    do
        local rowY = cd.y
        -- WHY: master visibility toggle. Hides both panels without losing settings.
        -- OnClick already runs CacheSettings + UpdateStats; UpdateStats checks cached.isVisible
        -- and Hides both panels. Slash equivalents: /ss show, /ss hide, /ss toggle.
        CreateCheckbox(layoutTab, "StatsProVisibleCheck",
            "Show Stats Panel", "isVisible", cd.padX, rowY, nil, 140)
        CreateCheckbox(layoutTab, "StatsProLockCheck",
            "Lock Frames", "isLocked", cd.padX + CONFIG_COL_OFFSET, rowY, function(checked)
                SetAllPanelsLockState(checked)
            end, 140)
        cd.y = rowY - 26

        local DISPLAY_MODES = {
            { value = "flat",      label = "Flat" },
            { value = "sectioned", label = "Sectioned" },
            { value = "split",     label = "Split" },
        }
        CreateSimpleDropdownRow(
            layoutTab,
            layoutDropdownRows,
            "StatsProDisplayModeDropdown",
            "Display Mode:",
            DISPLAY_MODES,
            cd,
            function() return GetDB("displayMode") end,
            function(value, opt, dropdown)
                StatsProDB.displayMode = value
                CacheSettings()
                UIDropDownMenu_SetText(dropdown, L(opt.label))
                ApplySplitBlockChecksEnabled()
                CloseDropDownMenus()
                UpdateStats()
            end)
    end

    -- Scale slider — panel-level visual scale. Grouped with Frame & Position because it
    -- sizes the panel (visual layout), not the text rendering.
    CreateConfigSlider(layoutTab, "StatsProScaleSlider", "Scale:", "scale", cd,
        0.5, 2.0, 0.1, "0.5", "2.0", "%.1f",
        function()
            -- Scale is a visual preview control: keep immediate feedback while dragging.
            SetAllPanelsScale(GetNumberDB("scale"))
        end)

    -- Refresh rate slider — controls how often stat values recompute (seconds).
    -- Lower = smoother but more CPU; higher = less CPU but values lag behind gear/buff swaps.
    -- Grouped with Frame & Position (panel update rate, not a text/i18n concern).
    CreateConfigSlider(layoutTab, "StatsProRefreshSlider", "Refresh Rate (sec):", "updateInterval", cd,
        0.1, 1.0, 0.05, "0.1s", "1.0s", "%.2f",
        function()
            RunCoalesced("updateInterval", 0.05, CacheSettings)
        end)

    CursorGap(cd, 4)

    CursorSection(cd, "Side Panel Contains")
    do
        local rowY = cd.y
        local function AddSplitCheck(name, label, key, x, y)
            local cb = CreateCheckbox(layoutTab, name, label, key, x, y)
            splitBlockChecks[#splitBlockChecks + 1] = cb
            return cb
        end
        AddSplitCheck("StatsProSplitCharacterCheck",  "Character",    "splitCharacter",  cd.padX,                       rowY)
        AddSplitCheck("StatsProSplitItemLevelCheck",  "Item Level",   "splitItemLevel",  cd.padX + CONFIG_COL_OFFSET, rowY)
        cd.y = rowY - 26
        AddSplitCheck("StatsProSplitOffensiveCheck",  "Offensive",    "splitOffensive",  cd.padX,                       cd.y)
        AddSplitCheck("StatsProSplitTertiaryCheck",   "Tertiary",     "splitTertiary",   cd.padX + CONFIG_COL_OFFSET, cd.y)
        CursorAdvance(cd, 22)
        AddSplitCheck("StatsProSplitDefensiveCheck",  "Defensive",    "splitDefensive",  cd.padX,                       cd.y)
        AddSplitCheck("StatsProSplitDurabilityCheck", "Durability",   "splitDurability", cd.padX + CONFIG_COL_OFFSET, cd.y)
        CursorAdvance(cd, 22)
        AddSplitCheck("StatsProSplitRepairCheck",     "Repair Cost",  "splitRepairCost", cd.padX,                       cd.y)
        CursorAdvance(cd, 22)
        ApplySplitBlockChecksEnabled()
        PushRefresher(ApplySplitBlockChecksEnabled)
    end

    CursorGap(cd, 6)

    -- Value Display covers rated-stat column visibility plus label presentation for all
    -- normal HUD rows.
    CursorSection(cd, "Value Display")
    CreateSimpleDropdownRow(
        layoutTab,
        layoutDropdownRows,
        "StatsProTargetSnapshotDropdown",
        "Tooltip Targets:",
        _G.StatsProTargetSnapshotDropdownOptions,
        cd,
        _G.StatsProGetTargetSnapshotDropdownValue,
        _G.StatsProSelectTargetSnapshotDropdownValue)
    do
        local rowY = cd.y
        local leftRows, rightRows = {}, {}
        local _, sw, txt
        _, sw, txt = CreateCheckboxColor(layoutTab, "StatsProRatingCheck",     "Show Rating",     "showRating",     "rating",     cd.padX,                       rowY)
        leftRows[#leftRows + 1]   = { text = txt, swatch = sw }
        _, sw, txt = CreateCheckboxColor(layoutTab, "StatsProPercentageCheck", "Show Percentage", "showPercentage", "percentage", cd.padX + CONFIG_COL_OFFSET, rowY)
        rightRows[#rightRows + 1] = { text = txt, swatch = sw }
        AlignSwatchColumn(leftRows)
        AlignSwatchColumn(rightRows)
        cd.y = rowY - 26
    end
    do
        local LABEL_STYLE_OPTIONS = {
            { value = "full",   label = "Full" },
            { value = "short",  label = "Short" },
            { value = "hidden", label = "Hidden" },
        }
        CreateSimpleDropdownRow(
            layoutTab,
            layoutDropdownRows,
            "StatsProLabelStyleDropdown",
            "Label Style:",
            LABEL_STYLE_OPTIONS,
            cd,
            function() return NormalizeLabelStyle(GetDB("labelStyle")) end,
            function(value, opt, dropdown)
                StatsProDB.labelStyle = value
                CacheSettings()
                UIDropDownMenu_SetText(dropdown, L(opt.label))
                CloseDropDownMenus()
                UpdateStats()
            end)
    end
    CreateCheckbox(layoutTab, "StatsProMatchColorCheck",
        "Match Value Color to Stat", "matchValueColorToStat", cd.padX, cd.y)
    CursorAdvance(cd, 22)

    AlignSwatchColumn(layoutDropdownRows, CONFIG_DROPDOWN_GAP)
    layoutTab.contentHeight = CursorUsed(cd)
    layoutTab:SetHeight(layoutTab.contentHeight)

    --[[ ===== APPEARANCE TAB (Lua var: displayTab) ===== ]]
    cd = NewCursor(displayTab, 12, -8)

    -- Typography section: text rendering (font face + size).
    CursorSection(cd, "Typography")
    do
        local rowY = cd.y

        local fontLabel = displayTab:CreateFontString(nil, "OVERLAY")
        RegisterConfigFont(fontLabel, CONFIG_FONT_SIZE)
        fontLabel:SetPoint("TOPLEFT", cd.padX, rowY)
        PushLocalizedLabel(function() fontLabel:SetText(L("Font:")) end)

        -- WHY rebuilt on demand (not at load): LSM-registered fonts can appear after
        -- StatsPro loads (other addon registers later); static one-time build would miss
        -- them until /reload. WHY cached across calls: BuildFontsList runs from the font
        -- picker's PopulateFontPicker AND from CurrentFontName (called on Reset, on every
        -- lang commit, and at initial picker setup) — that's 5-10× per session. The sort
        -- inside is the dominant cost (each compare allocates two lowercased strings via
        -- string.lower); on heavy LSM installs (~200 fonts) it runs ~16ms per uncached
        -- call. Length-based signature catches the common LSM-add/remove invalidation case;
        -- same-name font swaps are accepted as a stale-cache edge (rare and harmless —
        -- worst case a stale path until next /reload).
        local cachedFontsList
        local cachedFontsListLen = -1
        local function BuildFontsList()
            local lsmLen = LSM and #LSM:List(LSM.MediaType.FONT) or 0
            if cachedFontsList and cachedFontsListLen == lsmLen then
                return cachedFontsList
            end
            local list
            if LSM then
                list = {}
                for _, name in ipairs(LSM:List(LSM.MediaType.FONT)) do
                    list[#list + 1] = {
                        name = name,
                        path = LSM:Fetch(LSM.MediaType.FONT, name),
                        sortKey = name:lower(),
                    }
                end
            else
                list = {}
                local clientLocale = GetLocale()
                for _, f in ipairs(BLIZZARD_SHIPPED_FONTS) do
                    if not f.locale or f.locale == clientLocale then
                        list[#list + 1] = {
                            name = f.name,
                            path = f.path,
                            sortKey = f.name:lower(),
                        }
                    end
                end
            end
            -- Stable sort independent of LSM internal ordering, so alphabetic bucketing below
            -- always matches user expectation (case-insensitive). Pre-computed sortKey
            -- avoids the comparator allocating two lowercased strings per compare —
            -- table.sort fires ~N log N compares for N=200 ≈ 1600 compares × 2 string.lower
            -- calls each becomes N + N log N compares against an already-lowered string.
            table.sort(list, function(a, b) return a.sortKey < b.sortKey end)
            cachedFontsList = list
            cachedFontsListLen = lsmLen
            return list
        end

        -- Assignment to forward-declared upvalue (section 15 prelude); language-dropdown
        -- info.func captures fontDropdown / CurrentFontName to sync caption after
        -- MaybeAutoSwitchFont silently changes db.font on a locale switch.
        fontDropdown = CreateFrame("Frame", "StatsProFontDropdown", displayTab, "UIDropDownMenuTemplate")
        -- Placeholder anchor; AlignSwatchColumn re-anchors at column x = cd.padX + maxLabelW + CONFIG_DROPDOWN_GAP after the Appearance-tab dropdown rows build.
        fontDropdown:SetPoint("TOPLEFT", cd.padX + 100, rowY + CONFIG_DROPDOWN_Y_OFFSET)
        -- Hover-preview: while font picker is open, hovering a font button applies it to
        -- panels temporarily without writing DB. Picker's OnHide handler is the SINGLE source
        -- of font-state sync — it forcibly re-applies DB.font after close, so cancel-on-close
        -- happens automatically (preview never wrote DB; PickFont wrote DB on commit-path).
        -- WHY immediate Reflow after Apply: ApplyStyle invalidates cachedLabelH + sets
        -- heightDirty; without an immediate SetTextSafe re-measure, frame width / repair
        -- row anchor stay stale until the next OnUpdate tick (≤ updateInterval, ~0.5s).
        --
        -- Hover-preview state shared across font picker buttons + commit/cancel paths:
        --   previewedPath = nil  → no preview applied; panels show DB.font
        --   previewedPath = "X"  → panels currently showing preview of font X
        -- Without this dedup, scrolling the picker fires OnEnter dozens of times in <1s
        -- (each scroll tick re-targets a different button under the cursor), each call
        -- re-running the apply pipeline. hoverGen + deferred-cancel pattern below adds an
        -- OnLeave path that auto-restores when the mouse drifts off all buttons, so the
        -- panels don't stay stuck on a previewed font when the user moves to the picker's
        -- padding without clicking.
        local previewedPath
        local hoverGen = 0
        -- WHY ReflowAllPanels (not UpdateStats) for font-only paths: line text doesn't
        -- change on font swap — only glyph widths do. Reflow re-feeds cached strings to
        -- SetTextSafe so frame width / repair-row Y / column alignment all re-measure
        -- under the new font, while skipping the stat/gear builders + the stat-API
        -- rescan that UpdateStats does. Subjective speed-up on font-picker scroll-hover
        -- where each unique button fires Apply + Reflow ~30× per second of scroll.
        local function PreviewFont(path)
            if SameFontPath(path, previewedPath) then return end
            previewedPath = path
            ApplyTextStyleToAllPanels(path, GetNumberDB("fontSize"))
            ReflowAllPanels()
        end
        -- WHY unconditional restore (no `previewedPath~=nil` gate): preview-state
        -- tracking can desync against panel-applied state via three paths — OnLeave-timer
        -- racing PickFont's nil-write, SetFont silent-fallback poisoning ApplyStyle's
        -- appliedFont cache, and Frame:Hide → child OnLeave event ordering. Force the
        -- restore so a poisoned appliedFont cache cannot leave the HUD stuck on the
        -- last hovered preview when the picker closes without a font pick.
        local function CancelFontPreview()
            previewedPath = nil
            ApplyTextStyleToAllPanels(GetFontDB(), GetNumberDB("fontSize"), true)
            ReflowAllPanels()
        end
        local function PickFont(f)
            StatsProDB.font = f.path
            StatsProDB.fontBeforeAutoSwitch = nil  -- explicit user pick clears auto-switch memory
            -- Skip Apply when preview already painted the same font (common path: hover
            -- then click). DB write above is the only mandatory step in that branch.
            if not SameFontPath(previewedPath, f.path) then
                ApplyTextStyleToAllPanels(f.path, GetNumberDB("fontSize"))
                ReflowAllPanels()
            end
            previewedPath = nil  -- preview is now committed; OnHide force-syncs to DB.font
            UIDropDownMenu_SetText(fontDropdown, f.name)
            CloseDropDownMenus()  -- defensive; no-op when no Blizzard dropdown is open
            RefreshLanguageWarning()  -- new font may not cover active locale's glyphs
        end
        UIDropDownMenu_SetWidth(fontDropdown, 100)
        UIDropDownMenu_JustifyText(fontDropdown, "CENTER")
        -- NOTE: UIDropDownMenu_Initialize is intentionally NOT called — Blizzard's default
        -- popup is replaced by a custom multi-column picker (see Block B below). Without
        -- Initialize, the template's default OnClick would open an empty DropDownList1, but
        -- Block E overrides Button:OnClick to open our picker instead.

        --[[ ===== Custom multi-column font picker ===== ]]
        -- Geometry constants — tweak here, do NOT inline magic numbers at call sites.
        local FONT_PICKER_COLS         = 3
        local FONT_PICKER_BTN_W        = 160      -- ~25 char names fit at CONFIG_FONT 12pt
        local FONT_PICKER_BTN_H        = 22
        local FONT_PICKER_PAD          = 8
        local FONT_PICKER_SCROLLBAR_W  = 22
        local FONT_PICKER_VISIBLE_ROWS = 14       -- visible area = 14 * 22 = 308px before scroll
        local FONT_PICKER_FRAME_W      = FONT_PICKER_COLS * FONT_PICKER_BTN_W + FONT_PICKER_PAD * 2 + FONT_PICKER_SCROLLBAR_W  -- 518
        local FONT_PICKER_FRAME_H      = FONT_PICKER_VISIBLE_ROWS * FONT_PICKER_BTN_H + FONT_PICKER_PAD * 2                    -- 324

        local fontPickerFrame
        local fontPickerScroll
        local fontPickerContent
        local fontPickerCatcher
        local fontPickerButtons = {}   -- pool of font-button frames; reused across Populate calls
        local fontPickerInitialized = false

        local function HideFontPicker()
            -- Single entry. picker:OnHide handler (set in Build) cancels active preview and
            -- hides catcher; both are idempotent so calling here covers programmatic close paths.
            if fontPickerFrame and fontPickerFrame:IsShown() then
                fontPickerFrame:Hide()
            end
            if fontPickerCatcher and fontPickerCatcher:IsShown() then
                fontPickerCatcher:Hide()
            end
        end

        local function BuildFontPickerFrame()
            -- Picker frame — DialogBox border style for visual parity with configFrame.
            fontPickerFrame = CreateFrame("Frame", "StatsProFontPicker", UIParent, "BackdropTemplate")
            fontPickerFrame:SetSize(FONT_PICKER_FRAME_W, FONT_PICKER_FRAME_H)
            fontPickerFrame:SetFrameStrata("DIALOG")
            -- Initial frame level; ShowFontPicker re-applies on each show in case configFrame's
            -- level shifted (e.g., Blizzard Settings API re-parented configFrame between sessions).
            fontPickerFrame:SetFrameLevel((configFrame and configFrame:GetFrameLevel() or 100) + 50)
            fontPickerFrame:SetClampedToScreen(true)
            fontPickerFrame:SetBackdrop({
                bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 16, edgeSize = 16,
                insets = { left = 4, right = 4, top = 4, bottom = 4 },
            })
            fontPickerFrame:SetBackdropColor(0, 0, 0, 0.92)
            fontPickerFrame:Hide()

            -- Click-catcher: invisible fullscreen frame BEHIND picker, ABOVE other DIALOG content.
            -- WHY consume click: standard modal-popup pattern (matches ColorPickerFrame, StaticPopup).
            -- Trade-off: 2-click penalty for trigger toggle and tab-switch.
            fontPickerCatcher = CreateFrame("Frame", nil, UIParent)
            fontPickerCatcher:SetAllPoints(UIParent)
            fontPickerCatcher:SetFrameStrata("DIALOG")
            fontPickerCatcher:SetFrameLevel(fontPickerFrame:GetFrameLevel() - 1)
            fontPickerCatcher:EnableMouse(true)
            fontPickerCatcher:Hide()
            fontPickerCatcher:SetScript("OnMouseDown", HideFontPicker)

            -- ScrollFrame — UIPanelScrollFrameTemplate matches configFrame's existing scroll pattern.
            fontPickerScroll = CreateFrame("ScrollFrame", "StatsProFontPickerScroll", fontPickerFrame, "UIPanelScrollFrameTemplate")
            fontPickerScroll:SetPoint("TOPLEFT", FONT_PICKER_PAD, -FONT_PICKER_PAD)
            fontPickerScroll:SetPoint("BOTTOMRIGHT", -(FONT_PICKER_PAD + FONT_PICKER_SCROLLBAR_W), FONT_PICKER_PAD)

            fontPickerContent = CreateFrame("Frame", nil, fontPickerScroll)
            fontPickerContent:SetSize(FONT_PICKER_COLS * FONT_PICKER_BTN_W, 100)  -- height set in Populate
            fontPickerScroll:SetScrollChild(fontPickerContent)

            -- OnHide: cancels active preview + hides catcher. Covers ALL close paths (Esc,
            -- click-outside, font-button click, /ss reset, configFrame-Hide hook). Catcher
            -- hide is unconditional (it's just a UIParent overlay); preview restore goes
            -- through CancelFontPreview's forced DB-font sync. PickFont writes DB first,
            -- so the commit path still lands on the chosen font when Hide fires.
            fontPickerFrame:SetScript("OnHide", function()
                if fontPickerCatcher then fontPickerCatcher:Hide() end
                CancelFontPreview()
            end)

            -- Esc-to-close. UISpecialFrames pops top-most special frame on Esc — picker added
            -- AFTER configFrame so picker closes first.
            tinsert(UISpecialFrames, "StatsProFontPicker")
        end

        local function PopulateFontPicker()
            local fonts = BuildFontsList()
            local currentPath = GetFontDB()
            local rows = math.ceil(#fonts / FONT_PICKER_COLS)
            local currentRow = nil

            fontPickerContent:SetHeight(math.max(rows * FONT_PICKER_BTN_H, 1))

            for i, f in ipairs(fonts) do
                local btn = fontPickerButtons[i]
                if not btn then
                    -- Lazy create + permanent setup. Pool-style — created once, reused.
                    btn = CreateFrame("Button", nil, fontPickerContent)
                    btn:SetSize(FONT_PICKER_BTN_W, FONT_PICKER_BTN_H)

                    btn.bg = btn:CreateTexture(nil, "BACKGROUND")
                    btn.bg:SetAllPoints()
                    btn.bg:SetColorTexture(0, 0, 0, 0)

                    -- Mouse-hover highlight — Blizzard standard listbox texture for consistency.
                    btn:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2")
                    local hl = btn:GetHighlightTexture()
                    hl:SetBlendMode("ADD")
                    hl:SetVertexColor(1, 1, 1, 0.4)

                    btn.text = btn:CreateFontString(nil, "OVERLAY")
                    RegisterConfigFont(btn.text, CONFIG_FONT_SIZE)
                    btn.text:SetPoint("LEFT", 6, 0)
                    btn.text:SetPoint("RIGHT", -4, 0)
                    btn.text:SetJustifyH("LEFT")
                    -- WHY no-wrap: long font names (>25 char) would wrap to a 2nd line, breaking
                    -- the row-height grid. Single-line overflow visually clipped by FontString.
                    btn.text:SetWordWrap(false)
                    btn.text:SetMaxLines(1)

                    -- hoverGen pattern: OnEnter bumps gen + applies preview; OnLeave captures
                    -- current gen and schedules a 0-tick deferred cancel. If the mouse moves
                    -- to ANOTHER button before the timer fires, that button's OnEnter bumps
                    -- gen — the captured-gen comparison fails, cancel is skipped (preview
                    -- transitions directly button→button without an Apply DB.font in between).
                    -- If the mouse leaves all buttons (drifts to picker padding or out of the
                    -- frame), no OnEnter fires before the timer → cancel runs, panels return
                    -- to DB.font. Without OnLeave, hovering then moving to padding leaves the
                    -- preview "stuck" until the user clicks something — felt as the picker
                    -- "fixating" on a random font in the user-facing report.
                    btn:SetScript("OnEnter", function(button)
                        hoverGen = hoverGen + 1
                        PreviewFont(button.fontPath)
                    end)
                    btn:SetScript("OnLeave", function()
                        local myGen = hoverGen
                        C_Timer.After(0, function()
                            if myGen == hoverGen then CancelFontPreview() end
                        end)
                    end)
                    btn:SetScript("OnClick", function(button)
                        PickFont({ name = button.fontName, path = button.fontPath })
                        HideFontPicker()
                    end)

                    fontPickerButtons[i] = btn
                end

                local row = math.floor((i - 1) / FONT_PICKER_COLS)
                local col = (i - 1) % FONT_PICKER_COLS
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", col * FONT_PICKER_BTN_W, -row * FONT_PICKER_BTN_H)
                btn.fontName = f.name
                btn.fontPath = f.path
                btn.text:SetText(f.name)

                -- Current-committed font marker: subtle green-cyan tint.
                if SameFontPath(f.path, currentPath) then
                    btn.bg:SetColorTexture(0, 1, 0.5, 0.18)
                    currentRow = row
                else
                    btn.bg:SetColorTexture(0, 0, 0, 0)
                end
                btn:Show()
            end

            -- Hide leftover buttons if list shrank (LSM addon disabled mid-session).
            for i = #fonts + 1, #fontPickerButtons do
                fontPickerButtons[i]:Hide()
            end

            -- Center current font in visible area; if in first half of viewport, scroll stays at 0.
            if currentRow then
                local centerOffset = math.floor(FONT_PICKER_VISIBLE_ROWS / 2)
                local targetScroll = math.max(0, (currentRow - centerOffset) * FONT_PICKER_BTN_H)
                local maxScroll    = math.max(0, rows * FONT_PICKER_BTN_H - FONT_PICKER_VISIBLE_ROWS * FONT_PICKER_BTN_H)
                fontPickerScroll:SetVerticalScroll(math.min(targetScroll, maxScroll))
            else
                fontPickerScroll:SetVerticalScroll(0)
            end
        end

        local function ShowFontPicker()
            if not fontPickerInitialized then
                BuildFontPickerFrame()
                fontPickerInitialized = true
            end
            -- Clean slate per show: any deferred-cancel timer captured prior session's
            -- hoverGen; bumping here ensures it can't false-positive against this session.
            -- previewedPath should already be nil from prior OnHide, but reset defensively.
            previewedPath = nil
            hoverGen = hoverGen + 1
            PopulateFontPicker()  -- always refresh: picks up LSM-added fonts + current-marker drift

            -- Re-apply frame level — defensive against configFrame re-parenting.
            fontPickerFrame:SetFrameLevel((configFrame and configFrame:GetFrameLevel() or 100) + 50)
            fontPickerCatcher:SetFrameLevel(fontPickerFrame:GetFrameLevel() - 1)

            -- Anchor TOPLEFT to fontDropdownButton's BOTTOMLEFT (NOT to fontDropdown frame —
            -- frame includes template chrome with padding; button is the visible edge).
            local btn = _G["StatsProFontDropdownButton"] or fontDropdown.Button
            fontPickerFrame:ClearAllPoints()
            if btn then
                fontPickerFrame:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
            else
                fontPickerFrame:SetPoint("TOPLEFT", fontDropdown, "BOTTOMLEFT", 16, -2)
            end
            fontPickerCatcher:Show()
            fontPickerFrame:Show()
        end

        local function ToggleFontPicker()
            if fontPickerFrame and fontPickerFrame:IsShown() then
                HideFontPicker()
            else
                ShowFontPicker()
            end
        end

        CurrentFontName = function()
            for _, f in ipairs(BuildFontsList()) do
                if SameFontPath(f.path, GetFontDB()) then return f.name end
            end
            return "Friz Quadrata TT"
        end
        UIDropDownMenu_SetText(fontDropdown, CurrentFontName())
        PushRefresher(function() UIDropDownMenu_SetText(fontDropdown, CurrentFontName()) end)

        -- Override Blizzard's default UIDropDownMenu trigger; open custom picker instead.
        -- UIDropDownMenuTemplate creates child Button at <frame_name>Button (Cataclysm-stable
        -- convention) OR exposes as frame.Button (Mixin-style). Defensive lookup covers both.
        local fontDropdownButton = _G["StatsProFontDropdownButton"] or fontDropdown.Button
        if fontDropdownButton then
            fontDropdownButton:SetScript("OnClick", function()
                PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)  -- audio parity with other dropdowns
                ToggleFontPicker()
            end)
        end

        tinsert(displayDropdownRows, {
            text = fontLabel, dropdown = fontDropdown,
            dropdownX_base = cd.padX, dropdownY = rowY + CONFIG_DROPDOWN_Y_OFFSET, dropdownParent = displayTab,
        })

        -- WHY no text-alignment control: three-column rendering pins labels RIGHT,
        -- ratings RIGHT, values LEFT — there is no global alignment to adjust. The
        -- defaults.textAlign field exists in DB purely so existing saves don't lose
        -- the key on migration; nothing reads it at runtime.

        cd.y = rowY - 32
    end

    -- Font Size slider — text rendering size. Naturally pairs with Font dropdown above.
    -- ReflowAllPanels (not UpdateStats) for the same reason as font picker: size change
    -- only affects measurements, not text content. Slider fires OnValueChanged per
    -- step-tick during drag (8→9→...→32 = up to 25 events), intentionally preserving
    -- live visual preview because this control is adjusted rarely but benefits hugely
    -- from immediate feedback.
    CreateConfigSlider(displayTab, "StatsProFontSlider", "Font Size:", "fontSize", cd,
        8, 32, 1, "8", "32", "%d",
        function()
            ApplyTextStyleToAllPanels(GetFontDB(), GetNumberDB("fontSize"))
            ReflowAllPanels()
        end)

    -- Text Opacity slider — adjust panel text transparency. Stored as INT 25-100 in DB
    -- (matches CreateConfigSlider's format-string contract); cached as float 0.25-1.0
    -- for SetAlpha. Default 100 = zero behavior change for existing users.
    CreateConfigSlider(displayTab, "StatsProTextAlphaSlider", "Text Opacity:", "textAlpha", cd,
        25, 100, 5, "25%", "100%", "%d%%",
        function(value)
            cached.textAlpha = value / 100
            ApplyTextAlphaToAllPanels(cached.textAlpha)
        end)

    CursorGap(cd, 4)
    CursorSection(cd, "Readability")
    CreateSimpleDropdownRow(
        displayTab,
        displayDropdownRows,
        "StatsProTextOutlineDropdown",
        "Text Outline:",
        self.readabilityConfig.textOutlineOptions,
        cd,
        self.readabilityConfig.getTextOutlineStyle,
        self.readabilityConfig.selectTextOutlineStyle)

    CreateConfigSlider(displayTab, "StatsProPanelBackgroundSlider", "Panel Background:", "panelBackgroundAlpha", cd,
        0, 80, 5, "0%", "80%", "%d%%",
        self.readabilityConfig.changePanelBackgroundAlpha)

    CursorGap(cd, 4)

    -- Localization section. Always shown — useful even on enUS for screenshot-locale
    -- picks (中文 / 한국어). Placed at bottom: typically set once on install and
    -- never revisited.
    CursorSection(cd, "Localization")
    do
        local rowY = cd.y

        local langLabel = displayTab:CreateFontString(nil, "OVERLAY")
        RegisterConfigFont(langLabel, CONFIG_FONT_SIZE)
        langLabel:SetPoint("TOPLEFT", cd.padX, rowY)
        PushLocalizedLabel(function() langLabel:SetText(L("Language:")) end)

        -- Linear scan LANGUAGE_OPTIONS for opt.value == value match. 3 callsites.
        local function FindLangOption(value)
            for _, o in ipairs(LANGUAGE_OPTIONS) do
                if o.value == value then return o end
            end
            return nil
        end

        -- StripParenSuffix: trim trailing " (Foo)" clarifier from a bilingual label.
        -- Reused by DisplayLabel and CompactLabel for the LANGUAGE_OPTIONS native+English
        -- form ("Русский (Russian)" -> "Русский"). Returns "" for nil so CompactLabel's
        -- explicit-pick branch keeps its prior nil-coalesce semantics.
        local function StripParenSuffix(s)
            if not s then return "" end
            return s:match("^(.-)%s*%(") or s
        end

        -- DisplayLabel: native form for menu items. For non-Latin Auto entries we strip
        -- the "(English)" clarifier — "Auto (current: Русский)" reads cleanly while the
        -- explicit-pick rows below keep the full bilingual label for disambiguation.
        local function DisplayLabel(opt)
            if opt.value ~= "auto" then return opt.label end
            local cur = GetLocale()
            local o = FindLangOption(cur)
            return string.format(L("Auto (current: %s)"), StripParenSuffix((o and o.label) or cur))
        end

        -- CompactLabel: short form for the dropdown's collapsed current-text field, sized to
        -- fit a 100px-wide dropdown body. Strips trailing parentheticals from explicit-pick
        -- labels ("Español (España)" -> "Español"); for "auto" mode shows native name only.
        local function CompactLabel(opt)
            if opt.value == "auto" then
                local cur = GetLocale()
                local o = FindLangOption(cur)
                return StripParenSuffix((o and o.label) or cur)
            end
            return StripParenSuffix(opt.label)
        end

        local function CurrentLabel()
            local opt = FindLangOption(GetDB("forceLocale"))
            if opt then return CompactLabel(opt) end
            return CompactLabel(LANGUAGE_OPTIONS[1])  -- fallback for unknown values
        end

        -- Hover-preview: hovering a language item swaps panel labels live; close-without-pick
        -- restores. Visual-only preview — no DB writes (so /reload mid-hover doesn't persist
        -- anything); no langWarn refresh (settings UI stays stable). When the committed font
        -- doesn't cover the hovered locale's glyphs (e.g. ruRU on enUS client with FRIZQT —
        -- no Cyrillic), we ALSO preview the auto-fallback font so labels don't render as
        -- boxes. ruRU client is a no-op via FONT_GLYPH_SUPPORT's locale-conditional FRIZQT
        -- entry (Cyrillic-supported on ruRU clients only) — FindCompatibleFont returns the
        -- current font unchanged.
        local langPreviewActive     = false
        local langPreviewSwappedFnt = false  -- true when preview ApplyTextStyle'd a fallback
        local langPreviewLocale            -- last applied preview's resolved locale, for dedup

        local function PreviewLanguage(value)
            local locale = (value == "auto") and GetLocale() or value
            -- Dedup: hovering the SAME locale row twice in succession (mouse jitter,
            -- entering then exiting then re-entering same item) repeats the heavy work
            -- (ApplyTextStyleToAllPanels + ApplyConfigFont walking 10 FontStrings +
            -- RefreshConfigLocalization replaying ~60 setters + alignment re-measure +
            -- UpdateStats full panel rebuild). Bail when nothing actually changed.
            if locale == langPreviewLocale then return end
            langPreviewLocale = locale
            cached.activeLabels = LABELS_BY_LOCALE[locale] or LABELS_BY_LOCALE.enUS
            cached.activeLabelsLocale = LABELS_BY_LOCALE[locale] and locale or "enUS"

            -- Visual font swap if the committed font lacks the previewed locale's glyphs.
            -- WHY GetFontDB() (committed) and not the currently-rendered preview font:
            -- consecutive hovers must each evaluate against the BASELINE, otherwise hover
            -- ru→ARIALN→hover de would compare ARIALN(Latin-OK) and skip restoring FRIZQT.
            local req      = LOCALE_GLYPH_REQ[locale] or GLYPH_LATIN
            local cur      = GetFontDB()
            local fallback = FindCompatibleFont(cur, req)
            if fallback and not SameFontPath(fallback, cur) then
                ApplyTextStyleToAllPanels(fallback, GetNumberDB("fontSize"))
                langPreviewSwappedFnt = true
            elseif langPreviewSwappedFnt then
                -- Previous hover swapped to fallback; this hover doesn't need to. Force
                -- the restore for the same cache-drift class as picker/dropdown cancel.
                ApplyTextStyleToAllPanels(cur, GetNumberDB("fontSize"), true)
                langPreviewSwappedFnt = false
            end

            langPreviewActive = true
            -- Replay every settings-UI label setter so the open config window reflects the
            -- previewed locale live alongside the panel-side UpdateStats below — symmetry
            -- with the commit path's RefreshConfigLocalization at the dropdown info.func.
            -- Also re-font settings UI labels: hovering ruRU on enUS client must swap our
            -- custom CreateFontStrings to ARIALN (Cyrillic) so they don't render as boxes —
            -- mirrors ApplyTextStyleToAllPanels above for the stat panels' baseline.
            ApplyConfigFont(ResolveConfigFont(locale))
            RefreshConfigLocalization()
            UpdateStats()
        end

        -- WHY re-resolve from DB instead of stored baseline: mirrors font picker's OnHide
        -- pattern. Commit path overwrote forceLocale + cleared the flag, so this is a no-op
        -- post-commit; close-without-pick path restores to baseline (=current forceLocale).
        local function CancelLanguagePreview()
            if not langPreviewActive then return end
            local active = ResolveActiveLocale()
            cached.activeLabels = LABELS_BY_LOCALE[active] or LABELS_BY_LOCALE.enUS
            cached.activeLabelsLocale = LABELS_BY_LOCALE[active] and active or "enUS"
            if langPreviewSwappedFnt then
                ApplyTextStyleToAllPanels(GetFontDB(), GetNumberDB("fontSize"), true)
                langPreviewSwappedFnt = false
            end
            langPreviewActive = false
            langPreviewLocale = nil  -- next preview must always run a fresh apply
            -- Restore settings-UI font for the COMMITTED locale (mirrors stat-panel restore
            -- above): hover-ruRU-then-cancel on enUS must put our CreateFontStrings back to
            -- the enUS-baseline CONFIG_FONT, otherwise they'd stay on ARIALN unnecessarily.
            ApplyConfigFont(ResolveConfigFont(active))
            RefreshConfigLocalization()
            UpdateStats()
        end

        local langDropdown = CreateFrame("Frame", "StatsProLanguageDropdown", displayTab, "UIDropDownMenuTemplate")
        -- Placeholder anchor; AlignSwatchColumn re-anchors at column x = cd.padX + maxLabelW + CONFIG_DROPDOWN_GAP after the Appearance-tab dropdown rows build.
        langDropdown:SetPoint("TOPLEFT", cd.padX + 100, rowY + CONFIG_DROPDOWN_Y_OFFSET)
        UIDropDownMenu_SetWidth(langDropdown, 100)
        UIDropDownMenu_JustifyText(langDropdown, "CENTER")
        UIDropDownMenu_Initialize(langDropdown, function()
            for _, opt in ipairs(LANGUAGE_OPTIONS) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = DisplayLabel(opt)
                info.value = opt.value
                info.checked = (GetDB("forceLocale") == opt.value)
                info.func = function()
                    -- Commit supersedes any in-flight hover preview. MaybeAutoSwitchFont
                    -- is the authoritative font owner from this point on.
                    StatsProDB.forceLocale = opt.value
                    CacheSettings()
                    MaybeAutoSwitchFont()
                    -- WHY conditional restore AFTER MAS: hover preview may have swapped
                    -- panels to a fallback (e.g. ARIALN for ruRU on enUS). MAS only calls
                    -- ApplyTextStyleToAllPanels when its own swap decision fires — committing
                    -- to a same-script-as-baseline locale (hover ruRU then commit deDE on
                    -- enUS) leaves MAS short-circuiting via FontSupports(FRIZQT, LATIN)=true,
                    -- so panels remain stuck on ARIALN. Force re-apply db.font (post-MAS,
                    -- authoritative) to undo the preview leak even if appliedFont cache
                    -- drifted. CancelLanguagePreview does the same conditional restore for
                    -- the close-without-pick path.
                    -- ApplyConfigFont is unconditionally called inside MAS so the settings
                    -- UI doesn't share this asymmetry — panels are the only side affected.
                    if langPreviewSwappedFnt then
                        ApplyTextStyleToAllPanels(GetFontDB(), GetNumberDB("fontSize"), true)
                    end
                    langPreviewActive     = false
                    langPreviewSwappedFnt = false
                    -- WHY: auto-switch may have changed db.font; PushRefresher only fires on Reset.
                    UIDropDownMenu_SetText(fontDropdown, CurrentFontName())
                    UIDropDownMenu_SetText(langDropdown, CompactLabel(opt))
                    CloseDropDownMenus()
                    RefreshLanguageWarning()
                    RefreshConfigLocalization()
                    UpdateStats()
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        UIDropDownMenu_SetText(langDropdown, CurrentLabel())

        -- Per-button OnEnter hover hook for live preview. WARNING: DropDownList1 is shared
        -- across all UIDropDownMenuTemplate dropdowns (Display Mode, Language) — filter via
        -- UIDROPDOWNMENU_OPEN_MENU == langDropdown so Display Mode hovers don't trigger us.
        local function HookLanguageMenuButtons()
            if not DropDownList1 or UIDROPDOWNMENU_OPEN_MENU ~= langDropdown then return end
            for i = 1, 32 do
                local btn = _G["DropDownList1Button" .. i]
                if not btn then break end
                if not btn._statsProLangPreviewHooked then
                    btn:HookScript("OnEnter", function(button)
                        if UIDROPDOWNMENU_OPEN_MENU ~= langDropdown then return end
                        if button.value == nil then return end  -- separator/title row
                        PreviewLanguage(button.value)
                    end)
                    btn._statsProLangPreviewHooked = true
                end
            end
        end

        if DropDownList1 then
            DropDownList1:HookScript("OnShow", HookLanguageMenuButtons)
            DropDownList1:HookScript("OnHide", CancelLanguagePreview)
        end

        -- 24 + cd.gap (6) = 30 effective; matches Display Mode dropdown row pattern.
        CursorAdvance(cd, 24)

        local langWarn = displayTab:CreateFontString(nil, "OVERLAY")
        RegisterConfigFont(langWarn, 11)
        langWarn:SetPoint("TOPLEFT", cd.padX, cd.y)
        langWarn:SetWidth(470)
        langWarn:SetJustifyH("LEFT")
        langWarn:SetTextColor(1, 0.6, 0.2)
        langWarn:SetText("")

        -- Assignment to file-scope upvalue declared in section 15 prelude (NOT a global).
        RefreshLanguageWarning = function()
            local active = ResolveActiveLocale()
            local req    = LOCALE_GLYPH_REQ[active] or GLYPH_LATIN
            if FontSupports(GetFontDB(), req) then
                langWarn:SetText("")
            else
                langWarn:SetText(string.format(L(
                    "|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."
                ), req))
            end
        end
        -- WHY register as localized: warning text changes on language switch (req glyph
        -- tag stays raw — it's a script name, not a translatable phrase). Setter replays
        -- from RefreshConfigLocalization so wording tracks active locale; RefreshLanguageWarning
        -- is also called from the language dropdown's commit handler for the immediate recheck.
        PushLocalizedLabel(function() RefreshLanguageWarning() end)
        -- WHY 14 (single-line at 11pt): shortened warning fits one line at SetWidth(440).
        -- Empty (common) state shows tight gap to next section; non-empty (rare, font/locale
        -- mismatch) shows one orange line below the dropdown. 14 + cd.gap (6) = 20 effective.
        CursorAdvance(cd, 14)

        -- Reset button: re-syncs both dropdown SetText and warning state.
        PushRefresher(function()
            UIDropDownMenu_SetText(langDropdown, CurrentLabel())
            RefreshLanguageWarning()
        end)

        tinsert(displayDropdownRows, {
            text = langLabel, dropdown = langDropdown,
            dropdownX_base = cd.padX, dropdownY = rowY + CONFIG_DROPDOWN_Y_OFFSET, dropdownParent = displayTab,
        })
    end

    -- Align Appearance-tab dropdowns into one column. Re-runs on language change via
    -- RefreshConfigLocalization (alignmentGroups iteration), so locale label-width shifts
    -- automatically widen or shrink the column.
    AlignSwatchColumn(displayDropdownRows, CONFIG_DROPDOWN_GAP)

    displayTab.contentHeight = CursorUsed(cd)
    displayTab:SetHeight(displayTab.contentHeight)

    --[[ ===== STATS TAB ===== ]]
    local cs = NewCursor(statsTab, 12, -8)

    -- Character-sheet rows. Inline color swatches per row drive label color +
    -- matchValueColorToStat coloring.
    CursorSection(cs, "Character")
    do
        local rowY = cs.y
        local leftRows, rightRows = {}, {}
        local _, sw, txt
        _, sw, txt = CreateCheckboxColor(statsTab, "StatsProMainStatCheck",
            "Show Main Stat", "showMainStat", "mainStat", cs.padX,                       rowY)
        leftRows[#leftRows + 1]   = { text = txt, swatch = sw }
        _, sw, txt = CreateCheckboxColor(statsTab, "StatsProStaminaCheck",
            "Show Stamina",   "showStamina",  "stamina",  cs.padX + CONFIG_COL_OFFSET, rowY)
        rightRows[#rightRows + 1] = { text = txt, swatch = sw }
        AlignSwatchColumn(leftRows)
        AlignSwatchColumn(rightRows)
        cs.y = rowY - 26
    end

    CursorGap(cs, 6)

    CursorSection(cs, "Offensive Stats")
    do
        local rowY = cs.y
        local critCb, hasteCb, masteryCb, versCb
        local function ApplyOffensiveSubsEnabled(masterOn)
            SetCheckboxEnabled(critCb,    masterOn)
            SetCheckboxEnabled(hasteCb,   masterOn)
            SetCheckboxEnabled(masteryCb, masterOn)
            SetCheckboxEnabled(versCb,    masterOn)
        end
        CreateCheckbox(statsTab, "StatsProOffensiveCheck",  "Show Offensive Stats", "showOffensive",     cs.padX,       rowY,
            function(checked) ApplyOffensiveSubsEnabled(checked) end)
        CreateCheckbox(statsTab, "StatsProHideZeroOffCheck", "Hide Zero Values",    "hideZeroOffensive", cs.padX + CONFIG_COL_OFFSET, rowY)
        cs.y = rowY - 26
        -- Inline color swatches per stat (mirrors Defensive dodge/parry/block/armor pattern).
        -- Two-column AlignSwatchColumn — left and right column widths measured independently.
        local leftRows, rightRows = {}, {}
        local sw, txt
        critCb,    sw, txt = CreateCheckboxColor(statsTab, "StatsProCritCheck",    "Show Crit",        "showCrit",        "crit",        cs.padX,                       cs.y)
        leftRows[#leftRows + 1]   = { text = txt, swatch = sw }
        hasteCb,   sw, txt = CreateCheckboxColor(statsTab, "StatsProHasteCheck",   "Show Haste",       "showHaste",       "haste",       cs.padX + CONFIG_COL_OFFSET, cs.y)
        rightRows[#rightRows + 1] = { text = txt, swatch = sw }
        CursorAdvance(cs, 22)
        masteryCb, sw, txt = CreateCheckboxColor(statsTab, "StatsProMasteryCheck", "Show Mastery",     "showMastery",     "mastery",     cs.padX,                       cs.y)
        leftRows[#leftRows + 1]   = { text = txt, swatch = sw }
        versCb,    sw, txt = CreateCheckboxColor(statsTab, "StatsProVersCheck",    "Show Versatility", "showVersatility", "versatility", cs.padX + CONFIG_COL_OFFSET, cs.y)
        rightRows[#rightRows + 1] = { text = txt, swatch = sw }
        CursorAdvance(cs, 22)
        AlignSwatchColumn(leftRows)
        AlignSwatchColumn(rightRows)
        ApplyOffensiveSubsEnabled(GetBoolDB("showOffensive"))
        PushRefresher(function() ApplyOffensiveSubsEnabled(GetBoolDB("showOffensive")) end)
    end

    CursorGap(cs, 6)

    CursorSection(cs, "Tertiary Stats")
    do
        local rowY = cs.y
        -- Sub-toggle refs captured to grey them when master is off (mirrors the
        -- dependency-disable pattern in the Defensive Stats section).
        local leechCb, avoidanceCb, speedCb
        local function ApplyTertiarySubsEnabled(masterOn)
            SetCheckboxEnabled(leechCb,     masterOn)
            SetCheckboxEnabled(avoidanceCb, masterOn)
            SetCheckboxEnabled(speedCb,     masterOn)
        end
        CreateCheckbox(statsTab, "StatsProTertiaryCheck", "Show Tertiary Stats", "showTertiary", cs.padX, rowY,
            function(checked) ApplyTertiarySubsEnabled(checked) end)
        CreateCheckbox(statsTab, "StatsProHideZeroCheck", "Hide Zero Values",    "hideZeroTertiary", cs.padX + CONFIG_COL_OFFSET, rowY)
        cs.y = rowY - 26
        -- Two-column grid matches Offensive/Defensive sections. With 3 stats the right
        -- side of row 2 is empty; left/right columns align via independent AlignSwatchColumn.
        local leftRows, rightRows = {}, {}
        local sw, txt
        leechCb,     sw, txt = CreateCheckboxColor(statsTab, "StatsProLeechCheck",     "Show Leech",     "showLeech",     "leech",     cs.padX,                       cs.y)
        leftRows[#leftRows + 1]   = { text = txt, swatch = sw }
        avoidanceCb, sw, txt = CreateCheckboxColor(statsTab, "StatsProAvoidanceCheck", "Show Avoidance", "showAvoidance", "avoidance", cs.padX + CONFIG_COL_OFFSET, cs.y)
        rightRows[#rightRows + 1] = { text = txt, swatch = sw }
        CursorAdvance(cs, 22)
        speedCb,     sw, txt = CreateCheckboxColor(statsTab, "StatsProSpeedCheck",     "Show Speed",     "showSpeed",     "speed",     cs.padX,                       cs.y)
        leftRows[#leftRows + 1]   = { text = txt, swatch = sw }
        CursorAdvance(cs, 22)
        AlignSwatchColumn(leftRows)
        AlignSwatchColumn(rightRows)
        ApplyTertiarySubsEnabled(GetBoolDB("showTertiary"))
        PushRefresher(function() ApplyTertiarySubsEnabled(GetBoolDB("showTertiary")) end)
    end

    CursorGap(cs, 6)

    CursorSection(cs, "Defensive Stats")
    do
        local rowY = cs.y
        -- Sub-toggle refs captured to grey them when master is off (mirrors Tertiary tab).
        local dodgeCb, parryCb, blockCb, armorCb, staggerCb
        local function ApplyDefensiveSubsEnabled(masterOn)
            SetCheckboxEnabled(dodgeCb, masterOn)
            SetCheckboxEnabled(parryCb, masterOn)
            SetCheckboxEnabled(blockCb, masterOn)
            SetCheckboxEnabled(armorCb, masterOn)
            SetCheckboxEnabled(staggerCb, masterOn)
        end
        CreateCheckbox(statsTab, "StatsProDefensiveCheck",   "Show Defensive Stats", "showDefensive",     cs.padX,       rowY,
            function(checked) ApplyDefensiveSubsEnabled(checked) end)
        CreateCheckbox(statsTab, "StatsProHideZeroDefCheck", "Hide Zero Values",     "hideZeroDefensive", cs.padX + CONFIG_COL_OFFSET, rowY)
        cs.y = rowY - 26
        -- Each defensive stat with its own inline color swatch. Two balanced columns;
        -- aligned per-column via AlignSwatchColumn so left swatches share an x and right
        -- swatches share an x (each column's max GetStringWidth measured independently).
        local leftRows, rightRows = {}, {}
        local sw, txt
        dodgeCb, sw, txt = CreateCheckboxColor(statsTab, "StatsProDodgeCheck", "Show Dodge", "showDodge", "dodge", cs.padX,                       cs.y)
        leftRows[#leftRows + 1]   = { text = txt, swatch = sw }
        parryCb, sw, txt = CreateCheckboxColor(statsTab, "StatsProParryCheck", "Show Parry", "showParry", "parry", cs.padX + CONFIG_COL_OFFSET, cs.y)
        rightRows[#rightRows + 1] = { text = txt, swatch = sw }
        CursorAdvance(cs, 22)
        blockCb, sw, txt = CreateCheckboxColor(statsTab, "StatsProBlockCheck", "Show Block", "showBlock", "block", cs.padX,                       cs.y)
        leftRows[#leftRows + 1]   = { text = txt, swatch = sw }
        armorCb, sw, txt = CreateCheckboxColor(statsTab, "StatsProArmorCheck", "Show Armor", "showArmor", "armor", cs.padX + CONFIG_COL_OFFSET, cs.y)
        rightRows[#rightRows + 1] = { text = txt, swatch = sw }
        CursorAdvance(cs, 22)
        staggerCb, sw, txt = CreateCheckboxColor(statsTab, "StatsProStaggerCheck", "Show Stagger", "showStagger", "stagger", cs.padX, cs.y)
        leftRows[#leftRows + 1] = { text = txt, swatch = sw }
        CursorAdvance(cs, 22)
        AlignSwatchColumn(leftRows)
        AlignSwatchColumn(rightRows)
        ApplyDefensiveSubsEnabled(GetBoolDB("showDefensive"))
        PushRefresher(function() ApplyDefensiveSubsEnabled(GetBoolDB("showDefensive")) end)
    end

    CursorGap(cs, 6)

    CursorSection(cs, "Gear")
    do
        local rowY = cs.y
        local leftRows, rightRows = {}, {}
        local sw, txt
        _, sw, txt = CreateCheckboxColor(statsTab, "StatsProItemLevelCheck",
            "Show Item Level", "showItemLevel", "itemLevel", cs.padX, rowY,
            function(checked) if checked then itemLevelDirty = true end end)
        leftRows[#leftRows + 1] = { text = txt, swatch = sw }
        -- Durability swatch is the override color used when Auto Color is OFF.
        -- WHY: also mark dirty so re-enabling after a long off period gets fresh values
        -- on the next tick, not whatever was cached when last enabled.
        _, sw, txt = CreateCheckboxColor(statsTab, "StatsProDurabilityCheck", "Show Durability",  "showDurability", "durability", cs.padX + CONFIG_COL_OFFSET, rowY,
            function() durabilityDirty = true end)
        rightRows[#rightRows + 1] = { text = txt, swatch = sw }
        AlignSwatchColumn(leftRows)
        AlignSwatchColumn(rightRows)
        cs.y = rowY - 26
        CreateCheckbox(statsTab, "StatsProRepairCostCheck", "Show Repair Cost", "showRepairCost", cs.padX, cs.y,
            function() durabilityDirty = true end)
        CursorAdvance(cs, 22)
        CreateCheckbox(statsTab, "StatsProAutoColorCheck",
            "Auto Color by Threshold", "useAutoColorDurability", cs.padX, cs.y)
        CursorAdvance(cs, 22)
        -- WHY: onChange forces recompute via dirty flag; otherwise display stays stale
        -- until the next equipment event (which may be far off).
        CreateCheckbox(statsTab, "StatsProWorstDurCheck",
            "Use Worst Slot (instead of average)", "useWorstDurability", cs.padX, cs.y,
            function() durabilityDirty = true end)
        CursorAdvance(cs, 22)
    end

    statsTab.contentHeight = CursorUsed(cs)
    statsTab:SetHeight(statsTab.contentHeight)

    --[[ ===== Reset action (in-place widget refresh, no frame rebuild) ===== ]]
    resetBtn:SetScript("OnClick", function() ResetToDefaults() end)

    --[[ ===== Initial state ===== ]]
    SwitchToTab(1)
end

-- Self-serve diagnostics: dump runtime state to chat for bug reports.
-- Each group is a separate PrintMsg so taint isolation is automatic
-- (per workspace AGENTS.md "log fields as separate entries"); no API
-- here reads stat values, so taint is not actually a risk — but the
-- per-line format is also far more readable in chat than a 400-char wall.
function addon:PrintDebugDump()
    PrintMsg(string.format("debug v%s  dbVer %s/%d  isLoaded=%s  durDirty=%s  mem=%dKB",
        ADDON_VERSION,
        tostring(StatsProDB.dbVersion or "?"),
        CURRENT_DB_VERSION,
        tostring(isLoaded), tostring(durabilityDirty),
        math.floor(collectgarbage("count"))))

    PrintMsg(string.format("visible=%s  locked=%s  mode=%s  labelStyle=%s  outline=%s  font=%dpx  scale=%.1f  refresh=%.2fs  textAlpha=%d%%  bgAlpha=%d%%",
        tostring(cached.isVisible), tostring(cached.isLocked),
        tostring(GetDB("displayMode")), tostring(cached.labelStyle), tostring(cached.textOutlineStyle),
        GetNumberDB("fontSize"), GetNumberDB("scale"), GetNumberDB("updateInterval"),
        GetNumberDB("textAlpha"), GetNumberDB("panelBackgroundAlpha")))

    PrintMsg(string.format("show fmt: rating=%s pct=%s matchColor=%s target=%s",
        tostring(cached.showRating), tostring(cached.showPercentage),
        tostring(cached.matchValueColorToStat), tostring(cached.targetSnapshot)))

    PrintMsg(string.format("split side: character=%s itemLevel=%s off=%s tert=%s defensive=%s dur=%s repair=%s",
        tostring(cached.splitCharacter), tostring(cached.splitItemLevel),
        tostring(cached.splitOffensive), tostring(cached.splitTertiary),
        tostring(cached.splitDefensive), tostring(cached.splitDurability),
        tostring(cached.splitRepairCost)))

    local active = ResolveActiveLocale()
    local req    = LOCALE_GLYPH_REQ[active] or GLYPH_LATIN
    PrintMsg(string.format("locale: client=%s force=%s active=%s",
        GetLocale(), tostring(GetDB("forceLocale")), active))
    PrintMsg(string.format("font: path=%s glyphReq=%s supports=%s saved=%s",
        tostring(GetFontDB() or "?"),
        req,
        tostring(FontSupports(GetFontDB(), req)),
        tostring(StatsProDB.fontBeforeAutoSwitch)))

    PrintMsg(string.format("show stats: off=%s tert=%s defensive=%s dur=%s repair=%s cost=%s mainStat=%s liveMainId=%s stamina=%s itemLevel=%s %s/%s",
        tostring(cached.showOffensive),
        tostring(cached.showTertiary), tostring(cached.showDefensive), tostring(cached.showDurability),
        tostring(cached.showRepairCost), tostring(cached.repairCost or 0),
        tostring(cached.showMainStat), tostring(GetCurrentMainStatId()), tostring(cached.showStamina),
        tostring(cached.showItemLevel), tostring(cached.itemLevelEquipped or "?"), tostring(cached.itemLevelOverall or "?")))

    PrintMsg(string.format("subs off: crit=%s haste=%s mastery=%s vers=%s",
        tostring(cached.showCrit), tostring(cached.showHaste), tostring(cached.showMastery), tostring(cached.showVersatility)))

    PrintMsg(string.format("subs: leech=%s avoid=%s speed=%s | dodge=%s parry=%s block=%s armor=%s stagger=%s",
        tostring(cached.showLeech), tostring(cached.showAvoidance), tostring(cached.showSpeed),
        tostring(cached.showDodge), tostring(cached.showParry), tostring(cached.showBlock),
        tostring(cached.showArmor), tostring(cached.showStagger)))

    -- Panel positions: nil-guard (DB may be partial in pre-PEW edge cases)
    local function PosLine(label, p, rp, x, y)
        if not p then return label..": <unset>" end
        return string.format("%s: %s/%s  %+d/%+d", label, p, rp, x or 0, y or 0)
    end
    PrintMsg(PosLine("main",      GetDB("point"),           GetDB("relativePoint"),           GetDB("xOfs"),           GetDB("yOfs")))
    PrintMsg(PosLine("side",      GetDB("defensive_point"), GetDB("defensive_relativePoint"), GetDB("defensive_xOfs"), GetDB("defensive_yOfs")))
end

local function PrintDebugPerf()
    PrintMsg(string.format("debug perf: mem=%dKB updates=%d refresh=%.2fs elapsed=%.2fs",
        math.floor(collectgarbage("count")),
        updateCount,
        cached.updateInterval or GetNumberDB("updateInterval"),
        timeSinceLastUpdate or 0))
    PrintMsg(string.format("debug perf: visible=%s mode=%s mainShown=%s sideShown=%s",
        tostring(cached.isVisible),
        tostring(cached.displayMode),
        tostring(mainPanel:IsShown()),
        tostring(defensivePanel:IsShown())))
    PrintMsg(string.format("debug perf: dirty durability=%s itemLevel=%s repairCost=%s durability=%.1f",
        tostring(durabilityDirty),
        tostring(itemLevelDirty),
        tostring(cached.repairCost or 0),
        cached.durabilityValue or 0))
    PrintMsg(string.format("debug perf: itemLevel enabled=%s equipped=%s overall=%s",
        tostring(cached.showItemLevel),
        tostring(cached.itemLevelEquipped or "?"),
        tostring(cached.itemLevelOverall or "?")))
end

-- WHY: row-shift bug class diagnostic. Strips color escapes + texture markup so
-- chat output is readable, AND escapes control chars (\n \r \t) as literal "\n"
-- so embedded newlines (the leading shift hypothesis) are VISIBLE in the dump
-- instead of silently splitting the line.
local function StripDumpEscapes(s)
    if issecretvalue(s) then return "<secret>" end
    if not s then return "" end
    if type(s) ~= "string" then return "<non-string>" end
    if s == "" then return "" end
    return (s:gsub("|c%x%x%x%x%x%x%x%x", "")
             :gsub("|r", "")
             :gsub("|T[^|]+|t", "[icon]")
             :gsub("\n", "\\n")
             :gsub("\r", "\\r")
             :gsub("\t", "\\t"))
end

function SAFE_NUM.DumpCell(s)
    return StripDumpEscapes(s)
end

function SAFE_NUM.DumpNumber(value, fmt, fallback)
    if issecretvalue(value) or not SAFE_NUM.IsCleanFiniteNumber(value) then return fallback or "?" end
    return string.format(fmt, value)
end

function addon.archonTargets.CleanNumberCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok and SAFE_NUM.IsCleanFiniteNumber(value) then return value end
    return nil
end

function addon:PrintDebugRatingConversion()
    local rows = {
        { "crit", CR_CRIT_MELEE },
        { "haste", CR_HASTE_MELEE },
        { "mastery", CR_MASTERY },
        { "vers", CR_VERSATILITY_DAMAGE_DONE },
    }
    for _, row in ipairs(rows) do
        local label, ratingCR = row[1], row[2]
        local rating = addon.archonTargets.CleanNumberCall(GetCombatRating, ratingCR)
        local live = addon.archonTargets.CleanNumberCall(GetCombatRatingBonus, ratingCR)
        local converted = rating and addon.archonTargets.CleanNumberCall(GetCombatRatingBonusForCombatRatingValue, ratingCR, rating) or nil
        local delta = (live and converted) and (converted - live) or nil
        local text = string.format("debug rating %s: rating=%s live=%s converted=%s delta=%s",
            label,
            SAFE_NUM.DumpNumber(rating, "%d", "?"),
            SAFE_NUM.DumpNumber(live, "%.2f", "?"),
            SAFE_NUM.DumpNumber(converted, "%.2f", "?"),
            SAFE_NUM.DumpNumber(delta, "%.2f", "?"))
        if ratingCR == CR_MASTERY then
            local okMastery, _, coefficient = pcall(GetMasteryEffect)
            if not okMastery or not SAFE_NUM.IsCleanFiniteNumber(coefficient) then coefficient = nil end
            local effective = (converted and coefficient) and (converted * coefficient) or nil
            text = text .. string.format(" effective=%s coefficient=%s",
                SAFE_NUM.DumpNumber(effective, "%.2f", "?"),
                SAFE_NUM.DumpNumber(coefficient, "%.2f", "?"))
        end
        PrintMsg(text)
    end
end

-- WHY local pipeline rerun (BuildRenderBlocks + RouteRenderBlocks): UpdateStats's
-- last result is collapsed into joined strings on the FontStrings; the per-row
-- arrays are not retained. Re-running the pipeline read-only (no SetTextSafe)
-- snapshots the same data without touching live render state. Manual-only
-- (/ss debug bucket), not in OnUpdate hot path.
local function PrintDebugBucketDump()
    if not isLoaded then PrintMsg("debug bucket: not loaded yet"); return end

    local mode = cached.displayMode or "flat"
    PrintMsg(string.format("bucket: mode=%s labelStyle=%s dur=%s speed=%s armorDR=%s vers=%s cost=%s",
        tostring(mode), tostring(cached.labelStyle),
        SAFE_NUM.DumpNumber(cached.durabilityValue, "%.1f", "?"),
        SAFE_NUM.DumpNumber(cached.speedPct, "%.1f", "?"),
        SAFE_NUM.DumpNumber(cached.armorDR, "%.1f", "?"),
        SAFE_NUM.DumpNumber(cached.versTotal, "%.1f", "?"),
        SAFE_NUM.DumpNumber(cached.repairCost, "%d", "?")))

    -- Per-panel widget state (read what's CURRENTLY rendered, not the snapshot below).
    local panels = { { "main", mainPanel }, { "side", defensivePanel } }
    for _, p in ipairs(panels) do
        local n, panel = p[1], p[2]
        PrintMsg(string.format("bucket: %s shown=%s lineN=%s hasRepair=%s W=%dx%d",
            n, tostring(panel:IsShown()),
            tostring(panel.lastLineCount or "?"),
            tostring(panel.lastHasRepair),
            math.floor(panel.frame:GetWidth() or 0),
            math.floor(panel.frame:GetHeight() or 0)))
        PrintMsg(string.format("bucket: %s cached LW=%s RW=%s VW=%s LH=%s RpW=%s RpLW=%s",
            n,
            tostring(panel.cachedLabelW), tostring(panel.cachedRatingW),
            tostring(panel.cachedValueW), tostring(panel.cachedLabelH),
            tostring(panel.cachedRepairW), tostring(panel.cachedRepairLabelW)))
    end

    -- Read-only snapshot: same pipeline UpdateStats uses, no SetTextSafe call.
    local okSnapshot, blocks = pcall(BuildRenderBlocks)
    if not okSnapshot then
        PrintMsg("bucket: snapshot failed: " .. SAFE_NUM.DumpCell(blocks))
        return
    end
    local main, side = RouteRenderBlocks(blocks, mode, cached, cached.labelStyle)

    for _, b in ipairs({ { "main", main }, { "side", side } }) do
        local n, bucket = b[1], b[2]
        -- WHY nL/nR/nV (not L/R/V): "L" would shadow the localization function L()
        -- declared at file scope. Even though we don't call L() in this loop, the
        -- shadow is a future-edit hazard (someone adds L("...") and gets a confusing
        -- "attempt to call a number value" error).
        local nL, nR, nV = #bucket.labels, #bucket.ratings, #bucket.values
        PrintMsg(string.format("bucket: %s L=%d R=%d V=%d parity=%s repair=%q",
            n, nL, nR, nV, tostring(nL == nR and nR == nV),
            SAFE_NUM.DumpCell(bucket.repairStr or "")))
    end

    -- Per-row dump (mainBucket only; side is empty in non-split modes).
    local rowMax = math.max(#main.labels, #main.ratings, #main.values)
    for i = 1, rowMax do
        PrintMsg(string.format("  [%02d] L=%q R=%q V=%q",
            i,
            SAFE_NUM.DumpCell(main.labels[i] or ""),
            SAFE_NUM.DumpCell(main.ratings[i] or ""),
            SAFE_NUM.DumpCell(main.values[i] or "")))
    end

    -- Raw FormatRepairCost — confirms whether visible "86.4%" inside Repair-row
    -- comes from coin-string itself or from a misaligned value column above.
    local rawCopper = (SAFE_NUM.IsCleanFiniteNumber(cached.repairCost) and not issecretvalue(cached.repairCost)) and cached.repairCost or 0
    local raw = FormatRepairCost(rawCopper)
    local rawStr = SAFE_NUM.DumpCell(raw)
    local rawLen = rawStr == "<secret>" and "<secret>" or tostring(#rawStr)
    local rawHead = rawStr == "<secret>" and "<secret>" or SAFE_NUM.DumpCell(rawStr:sub(1, 30))
    local rawTail = rawStr == "<secret>" and "<secret>" or SAFE_NUM.DumpCell(rawStr:sub(-30))
    PrintMsg(string.format("bucket: rawRepair len=%s head=%q tail=%q",
        rawLen, rawHead, rawTail))
end

local function CollectRenderRoutingSmokeFailures()
    local failures = {}
    local function Check(name, ok, detail)
        if not ok then failures[#failures + 1] = name .. ": " .. detail end
    end
    local function Block(splitKey, sectionKey, labels, ratings, values, repairStr, repairLabelStr)
        return {
            splitKey = splitKey,
            sectionKey = sectionKey,
            labels = labels or {},
            ratings = ratings or {},
            values = values or {},
            repairStr = repairStr or "",
            repairLabelStr = repairLabelStr,
        }
    end
    local function CountLabel(bucket, label)
        local n = 0
        for _, v in ipairs(bucket.labels) do
            if v == label then n = n + 1 end
        end
        return n
    end
    -- WHY: row-shift bug class — labels/ratings/values FontStrings are joined with "\n"
    -- and rendered as parallel multi-line columns. If counts diverge, value-N visually
    -- aligns with label-(N-k). Asymmetric pushes were ruled out by code-grep, but a
    -- field-grade invariant guards against future regressions and any embedded "\n"
    -- inside individual cell strings (which JoinLinesSecretSafe forwards as extra lines).
    local function CountRenderedLines(lines)
        local n = 0
        for _, v in ipairs(lines) do
            if type(v) == "string" then
                local _, extra = v:gsub("\n", "\n")
                n = n + 1 + extra
            else
                n = n + 1
            end
        end
        return n
    end
    local function CheckParity(name, bucket)
        local labelLines = CountRenderedLines(bucket.labels)
        local ratingLines = CountRenderedLines(bucket.ratings)
        local valueLines = CountRenderedLines(bucket.values)
        Check(name .. "-parity",
              labelLines == ratingLines and ratingLines == valueLines,
              string.format("L=%d R=%d V=%d", labelLines, ratingLines, valueLines))
    end

    local character = Block("splitCharacter", "Character", { "Crit:" }, { "123" }, { "12.3%" })
    local defensive = Block("splitDefensive", "Defensive", { "Dodge:" }, { "17.2%" }, { "" })
    local durability = Block("splitDurability", "Gear", { "Durability:" }, { "86.4%" }, { "" })
    local repair = Block("splitRepairCost", "Gear", {}, {}, {}, "243g", "Repair:")
    local empty = Block("splitOffensive", "Offensive")

    local main, side = RouteRenderBlocks({ character, defensive, repair }, "flat", { splitDefensive = true, splitRepairCost = true }, "full")
    Check("flat-main-rows", #main.labels == 2, "expected two normal rows in main")
    Check("flat-main-repair", main.repairStr == "243g" and main.repairLabelStr == "Repair:", "repair payload missing from main")
    Check("flat-side-empty", not BucketHasContent(side), "side bucket should stay empty")
    CheckParity("flat-main", main); CheckParity("flat-side", side)

    main, side = RouteRenderBlocks({ character, defensive, repair }, "split", { splitDefensive = true, splitRepairCost = true }, "full")
    Check("split-main-character", #main.labels == 1 and main.labels[1] == "Crit:", "character row should remain in main")
    Check("split-side-defensive", #side.labels == 1 and side.labels[1] == "Dodge:", "defensive row should route to side")
    Check("split-side-repair", side.repairStr == "243g" and side.repairLabelStr == "Repair:", "repair payload should route to side")
    CheckParity("split-main", main); CheckParity("split-side", side)

    main, side = RouteRenderBlocks({ empty }, "sectioned", nil, "full")
    Check("sectioned-empty-main", not BucketHasContent(main), "empty block should not create a header")
    Check("sectioned-empty-side", not BucketHasContent(side), "side bucket should stay empty")
    CheckParity("sectioned-empty-main", main); CheckParity("sectioned-empty-side", side)

    main = RouteRenderBlocks({ empty, defensive }, "sectioned", nil, "full")
    Check("sectioned-defensive-header", main.labels[1] == SectionHeader("Defensive"), "missing Defensive header")
    Check("sectioned-defensive-row", main.labels[2] == "Dodge:" and #main.labels == 2, "defensive row/header shape changed")
    Check("sectioned-skip-empty-header", CountLabel(main, SectionHeader("Offensive")) == 0, "empty Offensive block inserted a header")
    CheckParity("sectioned-defensive", main)

    main = RouteRenderBlocks({ durability, repair }, "sectioned", nil, "full")
    Check("sectioned-gear-header-once", CountLabel(main, SectionHeader("Gear")) == 1, "Gear header should appear once")
    Check("sectioned-gear-row", main.labels[2] == "Durability:" and #main.labels == 2, "durability row should sit under Gear header")
    Check("sectioned-gear-repair", main.repairStr == "243g" and main.repairLabelStr == "Repair:", "repair payload missing under Gear")
    CheckParity("sectioned-gear", main)

    main = RouteRenderBlocks({ repair }, "sectioned", nil, "full")
    Check("sectioned-repair-only-header", #main.labels == 1 and main.labels[1] == SectionHeader("Gear"), "repair-only should produce only Gear header")
    Check("sectioned-repair-only-payload", main.repairStr == "243g", "repair-only payload missing")
    CheckParity("sectioned-repair-only", main)

    main = RouteRenderBlocks({ defensive }, "sectioned", nil, "hidden")
    Check("sectioned-hidden-no-header", CountLabel(main, SectionHeader("Defensive")) == 0, "hidden label style should suppress section headers")
    Check("sectioned-hidden-rows-stay", #main.labels == 1 and main.labels[1] == "Dodge:", "hidden label style should keep data rows")
    CheckParity("sectioned-hidden-defensive", main)

    main = RouteRenderBlocks({ repair }, "sectioned", nil, "hidden")
    Check("sectioned-hidden-repair-no-header", #main.labels == 0, "hidden repair-only should not inject a Gear header")
    Check("sectioned-hidden-repair-payload", main.repairStr == "243g" and main.repairLabelStr == "Repair:", "hidden repair-only should keep repair payload")
    CheckParity("sectioned-hidden-repair-only", main)

    return failures
end

local function RunRenderRoutingSmokeCheck()
    local failures = CollectRenderRoutingSmokeFailures()
    if #failures == 0 then
        PrintMsg("debug routing: PASS")
    else
        PrintMsg(string.format("debug routing: FAIL (%d)", #failures))
        for _, failure in ipairs(failures) do
            PrintMsg("debug routing: " .. failure)
        end
    end
end

local function CollectLabelStyleSmokeFailures()
    local failures = {}
    local function Check(name, actual, expected)
        if actual ~= expected then
            failures[#failures + 1] = string.format("%s: expected %q, got %q", name, tostring(expected), tostring(actual))
        end
    end

    Check("ascii", FirstUTF8Char("Crit"), "C")
    Check("cyrillic", FirstUTF8Char("Крит"), "К")
    Check("cjk", FirstUTF8Char("暴击"), "暴")
    Check("empty", FirstUTF8Char(""), "")
    Check("nil", FirstUTF8Char(nil), "")
    local activeCrit = L("Crit")
    Check("full-active-locale", GetStyledLabelText("Crit", "full"), activeCrit .. ":")
    Check("short-active-locale", GetStyledLabelText("Crit", "short"), FirstUTF8Char(activeCrit) .. ":")
    Check("hidden-active-locale", GetStyledLabelText("Crit", "hidden"), "")

    return failures
end

local function RunLabelStyleSmokeCheck()
    local failures = CollectLabelStyleSmokeFailures()
    if #failures == 0 then
        PrintMsg("debug labelstyle: PASS")
    else
        PrintMsg(string.format("debug labelstyle: FAIL (%d)", #failures))
        for _, failure in ipairs(failures) do
            PrintMsg("debug labelstyle: " .. failure)
        end
    end
end

if addon and addon.__statsproSmoke == true then
    addon.__test = {
        currentDBVersion = function() return CURRENT_DB_VERSION end,
        cachedUpdateInterval = function() return cached.updateInterval end,
        cachedTextAlpha = function() return cached.textAlpha end,
        cachedPanelBackgroundAlpha = function() return cached.panelBackgroundAlpha end,
        cachedTargetSnapshot = function() return cached.targetSnapshot end,
        copyDefaults = function() return CopyTable(defaults) end,
        migrateDB = MigrateDB,
        cacheSettings = CacheSettings,
        getBoolDB = GetBoolDB,
        normalizeNumberSetting = NormalizeNumberSetting,
        fontPathKey = FontPathKey,
        sameFontPath = SameFontPath,
        isBlizzardFontPath = IsBlizzardFontPath,
        fontSupports = FontSupports,
        findCompatibleFont = FindCompatibleFont,
        formatRepairCost = FormatRepairCost,
        refreshDurabilityCache = RefreshDurabilityCache,
        durabilityState = function()
            return {
                durabilityValue = cached.durabilityValue,
                repairCost = cached.repairCost,
                dirty = durabilityDirty,
                retryScheduled = durabilityRetryScheduled,
            }
        end,
        normalizeColor = NormalizeColor,
        rgbToHex = RGBToHex,
        getArchonTargetSnapshot = addon.archonTargets.GetSnapshot,
        buildArchonTargetMeta = addon.archonTargets.BuildMeta,
        formatSnapshotDate = addon.archonTargets.FormatSnapshotDate,
        buildRenderBlocks = BuildRenderBlocks,
        routeRenderBlocks = RouteRenderBlocks,
        bucketHasContent = BucketHasContent,
        applyTextStyleToAllPanels = ApplyTextStyleToAllPanels,
        panelFontState = function()
            return {
                mainAppliedFont = mainPanel.appliedFont,
                mainAppliedSize = mainPanel.appliedSize,
                mainAppliedTextOutlineStyle = mainPanel.appliedTextOutlineStyle,
                mainLabelFont = mainPanel.labelText.font,
                mainLabelSize = mainPanel.labelText.fontSize,
                mainLabelFlags = mainPanel.labelText.fontFlags,
                sideAppliedFont = defensivePanel.appliedFont,
                sideAppliedSize = defensivePanel.appliedSize,
                sideAppliedTextOutlineStyle = defensivePanel.appliedTextOutlineStyle,
                sideLabelFont = defensivePanel.labelText.font,
                sideLabelSize = defensivePanel.labelText.fontSize,
                sideLabelFlags = defensivePanel.labelText.fontFlags,
            }
        end,
        panelVisualState = function()
            return {
                textOutlineStyle = cached.textOutlineStyle,
                mainFrameHeight = mainPanel.frame:GetHeight(),
                mainBackgroundAlpha = mainPanel.frame.backdropColor and mainPanel.frame.backdropColor.a or nil,
                mainBackgroundTextureAlpha = mainPanel.backgroundTexture and mainPanel.backgroundTexture.colorTexture and mainPanel.backgroundTexture.colorTexture.a or nil,
                mainBackgroundTexturePoints = mainPanel.backgroundTexture and mainPanel.backgroundTexture.points or nil,
                mainLabelFlags = mainPanel.labelText.fontFlags,
                mainRatingFlags = mainPanel.ratingText.fontFlags,
                mainValueFlags = mainPanel.valueText.fontFlags,
                mainRepairFlags = mainPanel.repairText.fontFlags,
                mainRepairLabelFlags = mainPanel.repairLabelText.fontFlags,
                sideFrameHeight = defensivePanel.frame:GetHeight(),
                sideBackgroundAlpha = defensivePanel.frame.backdropColor and defensivePanel.frame.backdropColor.a or nil,
                sideBackgroundTextureAlpha = defensivePanel.backgroundTexture and defensivePanel.backgroundTexture.colorTexture and defensivePanel.backgroundTexture.colorTexture.a or nil,
                sideBackgroundTexturePoints = defensivePanel.backgroundTexture and defensivePanel.backgroundTexture.points or nil,
                sideLabelFlags = defensivePanel.labelText.fontFlags,
                sideRatingFlags = defensivePanel.ratingText.fontFlags,
                sideValueFlags = defensivePanel.valueText.fontFlags,
                sideRepairFlags = defensivePanel.repairText.fontFlags,
                sideRepairLabelFlags = defensivePanel.repairLabelText.fontFlags,
            }
        end,
        renderMainPanelForSmoke = function(labelStr, ratingStr, valueStr, lineCount, repairStr, repairLabelStr, targetRows)
            mainPanel:SetTextSafe(labelStr, ratingStr, valueStr, lineCount, repairStr, repairLabelStr, targetRows)
        end,
        mainPanelTooltipState = function()
            return {
                overlayCount = #(mainPanel.tooltipOverlays or {}),
                firstShown = mainPanel.tooltipOverlays[1] and mainPanel.tooltipOverlays[1]:IsShown() or false,
                secondShown = mainPanel.tooltipOverlays[2] and mainPanel.tooltipOverlays[2]:IsShown() or false,
                lastTargetRows = mainPanel.lastTargetRows,
            }
        end,
        fireMainPanelTooltipOverlayForSmoke = function(index, scriptName, ...)
            local overlay = mainPanel.tooltipOverlays and mainPanel.tooltipOverlays[index]
            local script = overlay and overlay.scripts and overlay.scripts[scriptName]
            if script then script(overlay, ...) end
        end,
        setPanelAppliedStyleForSmoke = function(font, size, outlineStyle)
            mainPanel.appliedFont = font
            mainPanel.appliedSize = size
            mainPanel.appliedTextOutlineStyle = outlineStyle or cached.textOutlineStyle or addon.readabilityConfig.getTextOutlineStyleDB()
            defensivePanel.appliedFont = font
            defensivePanel.appliedSize = size
            defensivePanel.appliedTextOutlineStyle = outlineStyle or cached.textOutlineStyle or addon.readabilityConfig.getTextOutlineStyleDB()
        end,
        isCleanFiniteNumber = SAFE_NUM.IsCleanFiniteNumber,
        stripDumpEscapes = StripDumpEscapes,
        firstUTF8Char = FirstUTF8Char,
        getStyledLabelText = GetStyledLabelText,
        collectRenderRoutingSmokeFailures = CollectRenderRoutingSmokeFailures,
        collectLabelStyleSmokeFailures = CollectLabelStyleSmokeFailures,
    }
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
-- Dual-anchor instead of SetWidth: launcher is canvas-resized by Settings panel,
-- so deriving width from anchor span avoids right-edge clipping on narrow / low-res
-- windows. launcherBtn anchors to launcherDesc BOTTOMLEFT — picks up the dynamic
-- height from word-wrap automatically.
launcherDesc:SetPoint("TOPLEFT", launcherTitle, "BOTTOMLEFT", 0, -8)
launcherDesc:SetPoint("RIGHT", launcher, "RIGHT", -16, 0)
launcherDesc:SetJustifyH("LEFT")
PushPersistentLocalizedLabel(function()
    launcherDesc:SetText(L("Displays your secondary, defensive stats and durability on screen. Click below to open the full settings window."))
end)

local launcherBtn = CreateFrame("Button", nil, launcher, "UIPanelButtonTemplate")
launcherBtn:SetSize(180, 28)
launcherBtn:SetPoint("TOPLEFT", launcherDesc, "BOTTOMLEFT", 0, -16)
PushPersistentLocalizedLabel(function() launcherBtn:SetText(L("Open Settings")) end)
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
    local db = EnsureStatsProDBTable()
    db.isVisible = visible
    CacheSettings()
    UpdateStats()
    -- WHY: master Visible checkbox in config menu may be open; sync its state.
    local cb = _G["StatsProVisibleCheck"]
    if cb then cb:SetChecked(visible) end
end
SlashCmdList["STATSPRO"] = function(msg)
    local input = (msg or ""):lower()
    local arg, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
    arg = arg or ""
    rest = rest or ""
    if arg == "show" then
        SetVisible(true)
        PrintMsg(L("Stats panel shown"))
    elseif arg == "hide" then
        SetVisible(false)
        PrintMsg(L("Stats panel hidden"))
    elseif arg == "toggle" then
        local newState = not GetBoolDB("isVisible")
        SetVisible(newState)
        PrintMsg(L(newState and "Stats panel shown" or "Stats panel hidden"))
    elseif arg == "reset" then
        ResetToDefaults()
    elseif arg == "debug" then
        local debugArg = rest:match("^(%S+)") or ""
        if debugArg == "routing" then
            RunRenderRoutingSmokeCheck()
        elseif debugArg == "labelstyle" then
            RunLabelStyleSmokeCheck()
        elseif debugArg == "perf" then
            PrintDebugPerf()
        elseif debugArg == "rating" then
            addon:PrintDebugRatingConversion()
        elseif debugArg == "bucket" then
            PrintDebugBucketDump()
        else
            addon:PrintDebugDump()
        end
    elseif arg == "help" or arg == "?" then
        PrintMsg(L("Commands: /ss (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss debug"))
    else
        addon:OpenConfigMenu()
    end
end
