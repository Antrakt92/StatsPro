-- StatsPro.lua
-- Inspired by SwiftStats by TaylorSay (MIT). Boilerplate, color defaults, and the
-- basic stat list are adapted from upstream; the rest is original work. See LICENSE
-- for full attribution.
local _, addon = ...
addon.fontRuntime = {}
addon.panelEditRuntime = { requested = false }
addon.resetRuntime = { pending = nil }
addon.wipeRuntime = { pending = nil }
addon.durabilityRuntime = {
    generation = 0,
    attemptedGeneration = nil,
    scheduledGeneration = nil,
}

--[[ ============================================================
    1. CONSTANTS
============================================================ ]]
local CURRENT_DB_VERSION = 10

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

-- WHY early: font paths can come from SavedVariables or external media catalogs.
-- Reject secret-tagged values before any path normalization or SetFont call.
local issecretvalue = _G.issecretvalue or function() return false end

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
    { value = "esES",  label = "Español (España)", compactLabel = "Español ES" },
    { value = "esMX",  label = "Español (México)", compactLabel = "Español MX" },
    { value = "frFR",  label = "Français" },
    { value = "itIT",  label = "Italiano" },
    { value = "ptBR",  label = "Português (Brasil)" },
    { value = "koKR",  label = "한국어 (Korean)", compactLabel = "한국어 / Korean" },
    { value = "ruRU",  label = "Русский (Russian)" },
    { value = "zhCN",  label = "中文 简体 (Simplified)", compactLabel = "中文 / Simpl." },
    { value = "zhTW",  label = "中文 繁體 (Traditional)", compactLabel = "中文 / Trad." },
}

local LOCALE_GLYPH_REQ = {
    enUS = GLYPH_LATIN, deDE = GLYPH_LATIN, esES = GLYPH_LATIN, esMX = GLYPH_LATIN,
    frFR = GLYPH_LATIN, itIT = GLYPH_LATIN, ptBR = GLYPH_LATIN,
    ruRU = GLYPH_CYR,
    koKR = GLYPH_HANGUL, zhCN = GLYPH_HANS, zhTW = GLYPH_HANT,
}

local function FontPathKey(fontPath)
    if type(fontPath) ~= "string" then return nil end
    local ok, secret = pcall(issecretvalue, fontPath)
    if not ok or secret then return nil end
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

-- WHY explicit package discriminator: the checked-in TOC has a numeric version, so
-- metadata alone cannot distinguish a junction/source checkout from a release zip.
-- BigWigs Packager rewrites the resolver argument below while copying Lua files. A
-- source checkout appends -dev to its TOC version (falling back to CURRENT_RELEASE
-- when metadata is invalid); a package uses its exact project version, including the
-- branch build suffix in CI dry runs.
-- WARNING: bump CURRENT_RELEASE on every `git tag v*` so dev builds reflect the working base.
local CURRENT_RELEASE = "1.9.59"

function addon.ResolveAddonVersion(packagerProjectVersion, metadataVersion, sourceVersion)
    if type(packagerProjectVersion) == "string" then
        local packagedVersion = packagerProjectVersion:match("^v(%d+%.%d+%.%d+)$")
            or packagerProjectVersion:match("^v(%d+%.%d+%.%d+%-%d+%-g%x+)$")
        if packagedVersion then return packagedVersion end
    end
    local fallback = type(metadataVersion) == "string"
        and metadataVersion:match("^(%d+%.%d+%.%d+)$")
    if not fallback then
        fallback = type(sourceVersion) == "string"
        and sourceVersion:match("^(%d+%.%d+%.%d+)$")
    end
    return (fallback or "?") .. "-dev"
end

local ADDON_VERSION = addon.ResolveAddonVersion("@project-version@",
    (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)("StatsPro", "Version"),
    CURRENT_RELEASE)

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
    -- Optional provenance only: old profiles intentionally resolve to Custom without
    -- a schema migration or any write during load. Fresh/reset profiles start Classic.
    appearancePresetID = "classic",
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
-- WHY: Blizzard's paper doll defines spell crit as the minimum across schools
-- 2..MAX_SPELL_SCHOOLS, then chooses the best of spell/ranged/melee. In restricted
-- content any school can be secret, so an incomplete spell aggregate must never
-- masquerade as a clean partial min.
function addon.GetMaxSpellSchool()
    local value = _G.MAX_SPELL_SCHOOLS
    if issecretvalue(value) or type(value) ~= "number" or value ~= value
        or value <= -math.huge or value >= math.huge or value < 2 then
        return 7
    end
    return math.floor(value)
end

function addon.GetBestCritChance()
    local function read(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, value = pcall(fn, ...)
        if ok then return value end
        return nil
    end
    local function isCleanFinite(value)
        return not issecretvalue(value) and type(value) == "number" and value == value
            and value > -math.huge and value < math.huge
    end
    local function maxClean(...)
        local best
        for i = 1, select("#", ...) do
            local value = select(i, ...)
            if isCleanFinite(value) then
                best = best and math.max(best, value) or value
            end
        end
        return best
    end
    local melee = read(GetCritChance)
    local ranged = read(GetRangedCritChance)
    local maxSpellSchool = addon.GetMaxSpellSchool()
    local spell, secretSpell
    local spellComplete, hasSecretSpell = true, false
    for school = 2, maxSpellSchool do
        local value = read(GetSpellCritChance, school)
        if issecretvalue(value) then
            if not hasSecretSpell then
                secretSpell = value
                hasSecretSpell = true
            end
            spellComplete = false
        elseif isCleanFinite(value) then
            spell = spell and math.min(spell, value) or value
        else
            spellComplete = false
        end
    end
    if not spellComplete then spell = nil end
    local clean = maxClean(melee, ranged, spell)
    if clean ~= nil then return clean end
    if hasSecretSpell then return secretSpell end
    if issecretvalue(ranged) then return ranged end
    if issecretvalue(melee) then return melee end
    return nil
end

local OFFENSIVE_STATS = {
    { statKey = "crit",    label = "Crit",    api = addon.GetBestCritChance, ratingCR = CR_CRIT_MELEE,  colorKey = "crit",    showKey = "showCrit"    },
    { statKey = "haste",   label = "Haste",   api = GetHaste,         ratingCR = CR_HASTE_MELEE, colorKey = "haste",   showKey = "showHaste"   },
    { statKey = "mastery", label = "Mastery", api = GetMasteryEffect, ratingCR = CR_MASTERY,     colorKey = "mastery", showKey = "showMastery" },
    -- versatility handled specially (dual-source: rating + flat); gated by showVersatility
}

-- Appearance presets deliberately exclude font, layout, visibility, routing, scale,
-- locale, refresh rate, positions, and assignments. Every color palette is complete so
-- applying a preset never inherits a partially customized table by accident.
addon.appearancePresets = {
    order = { "classic", "clean-dark", "midnight", "monochrome", "high-contrast" },
    allowlist = {
        fontSize = true,
        textAlpha = true,
        panelBackgroundAlpha = true,
        textOutlineStyle = true,
        matchValueColorToStat = true,
        useAutoColorDurability = true,
        colors = true,
    },
    definitions = {
        classic = {
            label = "Classic", fontSize = 14, textAlpha = 100,
            panelBackgroundAlpha = 0, textOutlineStyle = "outline",
            matchValueColorToStat = false, useAutoColorDurability = true,
            colors = {
                crit={r=1,g=0,b=0}, haste={r=0,g=.5,b=1}, mastery={r=0,g=1,b=0},
                versatility={r=1,g=1,b=0}, rating={r=.7,g=.7,b=.7},
                percentage={r=1,g=1,b=1}, leech={r=.8,g=.2,b=.8},
                avoidance={r=.2,g=.8,b=.8}, speed={r=1,g=.65,b=0},
                mainStat={r=1,g=.84,b=0}, stamina={r=.5,g=1,b=.5},
                itemLevel={r=.55,g=.85,b=1}, dodge={r=.4,g=.7,b=1},
                parry={r=1,g=.4,b=.2}, block={r=.7,g=.5,b=.3},
                armor={r=.6,g=.6,b=.7}, stagger={r=.3,g=.8,b=.5},
                durability={r=1,g=1,b=1},
            },
        },
        ["clean-dark"] = {
            label = "Clean Dark", fontSize = 14, textAlpha = 100,
            panelBackgroundAlpha = 55, textOutlineStyle = "outline",
            matchValueColorToStat = false, useAutoColorDurability = true,
            colors = {
                crit={r=.95,g=.36,b=.36}, haste={r=.38,g=.70,b=1},
                mastery={r=.35,g=.90,b=.62}, versatility={r=.92,g=.78,b=.35},
                rating={r=.68,g=.72,b=.70}, percentage={r=.96,g=.98,b=.97},
                leech={r=.78,g=.48,b=.88}, avoidance={r=.35,g=.78,b=.80},
                speed={r=.96,g=.68,b=.32}, mainStat={r=.95,g=.82,b=.42},
                stamina={r=.55,g=.85,b=.62}, itemLevel={r=.50,g=.78,b=.95},
                dodge={r=.42,g=.68,b=.90}, parry={r=.90,g=.48,b=.35},
                block={r=.72,g=.58,b=.42}, armor={r=.67,g=.69,b=.75},
                stagger={r=.40,g=.78,b=.58}, durability={r=.92,g=.94,b=.93},
            },
        },
        midnight = {
            label = "Midnight", fontSize = 14, textAlpha = 100,
            panelBackgroundAlpha = 35, textOutlineStyle = "outline",
            matchValueColorToStat = false, useAutoColorDurability = true,
            colors = {
                crit={r=.95,g=.38,b=.48}, haste={r=.18,g=.72,b=.92},
                mastery={r=.10,g=.82,b=.48}, versatility={r=.62,g=.55,b=.95},
                rating={r=.48,g=.63,b=.72}, percentage={r=.90,g=.96,b=1},
                leech={r=.70,g=.40,b=.90}, avoidance={r=.20,g=.75,b=.78},
                speed={r=.30,g=.82,b=.68}, mainStat={r=.20,g=.78,b=.92},
                stamina={r=.35,g=.90,b=.66}, itemLevel={r=.35,g=.68,b=1},
                dodge={r=.28,g=.68,b=.95}, parry={r=.88,g=.42,b=.60},
                block={r=.55,g=.55,b=.80}, armor={r=.50,g=.62,b=.72},
                stagger={r=.15,g=.82,b=.55}, durability={r=.82,g=.90,b=.95},
            },
        },
        monochrome = {
            label = "Monochrome", fontSize = 14, textAlpha = 95,
            panelBackgroundAlpha = 30, textOutlineStyle = "none",
            matchValueColorToStat = false, useAutoColorDurability = false,
            colors = {
                crit={r=.82,g=.82,b=.82}, haste={r=.76,g=.76,b=.76},
                mastery={r=.88,g=.88,b=.88}, versatility={r=.72,g=.72,b=.72},
                rating={r=.62,g=.62,b=.62}, percentage={r=.96,g=.96,b=.96},
                leech={r=.78,g=.78,b=.78}, avoidance={r=.74,g=.74,b=.74},
                speed={r=.84,g=.84,b=.84}, mainStat={r=.92,g=.92,b=.92},
                stamina={r=.80,g=.80,b=.80}, itemLevel={r=.86,g=.86,b=.86},
                dodge={r=.76,g=.76,b=.76}, parry={r=.82,g=.82,b=.82},
                block={r=.68,g=.68,b=.68}, armor={r=.64,g=.64,b=.64},
                stagger={r=.72,g=.72,b=.72}, durability={r=.90,g=.90,b=.90},
            },
        },
        ["high-contrast"] = {
            label = "High Contrast", fontSize = 16, textAlpha = 100,
            panelBackgroundAlpha = 75, textOutlineStyle = "thick",
            matchValueColorToStat = true, useAutoColorDurability = true,
            colors = {
                crit={r=1,g=.18,b=.18}, haste={r=.12,g=.72,b=1},
                mastery={r=.12,g=1,b=.30}, versatility={r=1,g=.88,b=.10},
                rating={r=.72,g=.78,b=.84}, percentage={r=1,g=1,b=1},
                leech={r=1,g=.28,b=1}, avoidance={r=.10,g=1,b=1},
                speed={r=1,g=.62,b=.05}, mainStat={r=1,g=.86,b=.10},
                stamina={r=.35,g=1,b=.35}, itemLevel={r=.25,g=.80,b=1},
                dodge={r=.20,g=.65,b=1}, parry={r=1,g=.30,b=.12},
                block={r=1,g=.62,b=.18}, armor={r=.72,g=.75,b=.90},
                stagger={r=.18,g=1,b=.45}, durability={r=1,g=1,b=1},
            },
        },
    },
    session = nil,
    ui = nil,
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
-- chain preserves the legacy fallback for clients missing the modern namespace.
local function SafeGetSpecIndex()
    local fn = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization
        or GetSpecialization
    if type(fn) ~= "function" then return nil end
    local ok, idx = pcall(fn)
    if not ok then return nil end
    local secretOK, secret = pcall(issecretvalue, idx)
    if not secretOK or secret or type(idx) ~= "number"
        or idx ~= idx or idx <= 0 or idx ~= math.floor(idx) then
        return nil
    end
    return idx
end

local function SafeGetSpecInfo(idx)
    local fn = C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo
        or GetSpecializationInfo
    if type(fn) ~= "function" then return nil end
    local ok, specID, name, description, icon, role, primaryStat = pcall(fn, idx)
    if not ok then return nil end
    return specID, name, description, icon, role, primaryStat
end

-- Returns 1 (Str) / 2 (Agi) / 4 (Int) or nil (no spec selected — sub-10 alts /
-- pre-PEW edge / API stub in older clients). Per-render lookup (no caching) — matches
-- the no-spec-event-handler architecture (UpdateStats re-reads every tick anyway).
local function GetCurrentMainStatId()
    local idx = SafeGetSpecIndex()
    if not idx then return nil end
    local _, _, _, _, _, primaryStat = SafeGetSpecInfo(idx)
    local secretOK, secret = pcall(issecretvalue, primaryStat)
    if not secretOK or secret or type(primaryStat) ~= "number" then return nil end
    if primaryStat == 1 or primaryStat == 2 or primaryStat == 4 then return primaryStat end
    return nil
end

addon.archonTargets = addon.archonTargets or {}
addon.archonTargets.defaultSnapshotKey = "mythicPlus"
addon.archonTargets.snapshotOptions = {
    { value = "mythicPlus", label = "Mythic+" },
    { value = "raid",       label = "Raid" },
}
-- Session-local by design: a character change reloads addon Lua, while zoning into
-- Mythic+ does not. Context changes clear entries so switching away and back cannot
-- revive a comparison captured before the switch.
addon.archonTargets.comparisonCache = {
    generation = 0,
    entries = {},
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
    if type(classToken) ~= "string" or issecretvalue(classToken) or classToken == "" then return nil end
    return classToken
end

function addon.archonTargets.GetCurrentSpecKey()
    local idx = SafeGetSpecIndex()
    if type(idx) ~= "number" or issecretvalue(idx) then return nil end
    local specID = SafeGetSpecInfo(idx)
    if type(specID) ~= "number" or issecretvalue(specID) then return nil end
    return addon.archonTargets.specKeyByID[specID]
end

function addon.archonTargets.IsCleanFiniteNumber(value)
    if issecretvalue(value) then return false end
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

function addon.archonTargets.IsCleanContextKey(value)
    return type(value) == "string" and not issecretvalue(value) and value ~= ""
end

function addon.archonTargets.ActivateComparisonContext(classToken, specKey, snapshotKey)
    if not addon.archonTargets.IsCleanContextKey(classToken)
        or not addon.archonTargets.IsCleanContextKey(specKey)
        or not addon.archonTargets.IsCleanContextKey(snapshotKey) then return nil end
    local cache = addon.archonTargets.comparisonCache
    if cache.classToken ~= classToken or cache.specKey ~= specKey or cache.snapshotKey ~= snapshotKey then
        cache.generation = cache.generation + 1
        cache.classToken = classToken
        cache.specKey = specKey
        cache.snapshotKey = snapshotKey
        cache.entries = {}
    end
    return cache
end

function addon.archonTargets.GetCachedComparison(classToken, specKey, snapshotKey, statKey,
                                                  target, ratingCR, capturedAt)
    if not addon.archonTargets.IsCleanContextKey(statKey)
        or not addon.archonTargets.IsCleanFiniteNumber(target)
        or not addon.archonTargets.IsCleanFiniteNumber(ratingCR)
        or type(capturedAt) ~= "string" or issecretvalue(capturedAt) then return nil end
    local cache = addon.archonTargets.ActivateComparisonContext(classToken, specKey, snapshotKey)
    if not cache then return nil end
    local entry = cache.entries[statKey]
    if type(entry) ~= "table" or entry.generation ~= cache.generation
        or entry.classToken ~= classToken or entry.specKey ~= specKey
        or entry.snapshotKey ~= snapshotKey or entry.statKey ~= statKey
        or entry.target ~= target or entry.ratingCR ~= ratingCR
        or entry.capturedAt ~= capturedAt then
        cache.entries[statKey] = nil
        return nil
    end
    if not addon.archonTargets.IsCleanFiniteNumber(entry.current)
        or not addon.archonTargets.IsCleanFiniteNumber(entry.delta) then
        cache.entries[statKey] = nil
        return nil
    end
    if entry.currentPct ~= nil and not addon.archonTargets.IsCleanFiniteNumber(entry.currentPct) then
        cache.entries[statKey] = nil
        return nil
    end
    return entry
end

function addon.archonTargets.StoreCleanComparison(classToken, specKey, snapshotKey, statKey,
                                                   target, ratingCR, capturedAt,
                                                   current, currentPct, delta)
    if not addon.archonTargets.IsCleanContextKey(statKey)
        or not addon.archonTargets.IsCleanFiniteNumber(target)
        or not addon.archonTargets.IsCleanFiniteNumber(ratingCR)
        or not addon.archonTargets.IsCleanFiniteNumber(current)
        or not addon.archonTargets.IsCleanFiniteNumber(delta)
        or type(capturedAt) ~= "string" or issecretvalue(capturedAt) then return end
    if currentPct ~= nil and not addon.archonTargets.IsCleanFiniteNumber(currentPct) then return end
    local cache = addon.archonTargets.ActivateComparisonContext(classToken, specKey, snapshotKey)
    if not cache then return end
    cache.entries[statKey] = {
        generation = cache.generation,
        classToken = classToken,
        specKey = specKey,
        snapshotKey = snapshotKey,
        statKey = statKey,
        target = target,
        ratingCR = ratingCR,
        capturedAt = capturedAt,
        current = current,
        currentPct = currentPct,
        delta = delta,
    }
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
    if type(specs) ~= "table" then return nil, snapshotRoot, root, normalizedKey end
    local classData = specs[classToken]
    if type(classData) ~= "table" then return nil, snapshotRoot, root, normalizedKey end
    local specData = classData[specKey]
    if type(specData) ~= "table" then return nil, snapshotRoot, root, normalizedKey end
    return specData, snapshotRoot, root, normalizedKey
end

function addon.archonTargets.GetCurrentSnapshot()
    local classToken = addon.archonTargets.GetCurrentClassToken()
    local specKey = addon.archonTargets.GetCurrentSpecKey()
    if not classToken or not specKey then return nil end
    local snapshot, snapshotRoot, root, snapshotKey = addon.archonTargets.GetSnapshot(classToken, specKey, cached.targetSnapshot)
    snapshotKey = snapshotKey or addon.archonTargets.NormalizeSnapshotKey(cached.targetSnapshot)
    addon.archonTargets.ActivateComparisonContext(classToken, specKey, snapshotKey)
    return snapshot, snapshotRoot, root, snapshotKey, classToken, specKey
end

function addon.archonTargets.GetStatTarget(statKey)
    local snapshot, snapshotRoot, root, snapshotKey, classToken, specKey = addon.archonTargets.GetCurrentSnapshot()
    local targets = snapshot and snapshot.targets
    local target = type(targets) == "table" and targets[statKey] or nil
    if type(target) ~= "number" or issecretvalue(target)
        or target ~= target or target <= 0 or target >= math.huge then return nil end
    return target, snapshot, snapshotRoot, root, snapshotKey, classToken, specKey
end

function addon.archonTargets.BuildMeta(statKey, currentRating, ratingCR, currentPct, colorKey)
    local hasCleanCurrent = addon.archonTargets.IsCleanFiniteNumber(currentRating) and currentRating >= 0
    local target, snapshot, snapshotRoot, _, snapshotKey, classToken, specKey = addon.archonTargets.GetStatTarget(statKey)
    if not target then return nil end
    if type(snapshot) ~= "table" or type(snapshotRoot) ~= "table" then return nil end
    local cleanRatingCR = addon.archonTargets.IsCleanFiniteNumber(ratingCR) and ratingCR or nil
    local capturedAt = snapshotRoot.capturedAt
    local meta = {
        statKey = statKey,
        colorKey = colorKey or statKey,
        ratingCR = cleanRatingCR,
        target = target,
        comparisonState = "targetOnly",
        sourceUrl = snapshot.sourceUrl,
        capturedAt = capturedAt,
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
    if hasCleanCurrent then
        local displayPct = addon.archonTargets.IsCleanFiniteNumber(currentPct) and currentPct or nil
        local delta = currentRating - target
        if addon.archonTargets.IsCleanFiniteNumber(delta) then
            meta.comparisonState = "exact"
            meta.current = currentRating
            meta.currentPct = displayPct
            meta.delta = delta
            addon.archonTargets.StoreCleanComparison(
                classToken, specKey, snapshotKey, statKey, target, cleanRatingCR,
                capturedAt, currentRating, displayPct, delta)
        end
        return meta
    end
    local entry = addon.archonTargets.GetCachedComparison(
        classToken, specKey, snapshotKey, statKey, target, cleanRatingCR, capturedAt)
    if entry then
        meta.comparisonState = "lastKnown"
        meta.current = entry.current
        meta.currentPct = entry.currentPct
        meta.delta = entry.delta
    end
    return meta
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
    -- speed handled specially (Movement % via GetUnitSpeed)
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
    armorDR = nil,
    itemLevelOverall = nil,
    itemLevelEquipped = nil,
    durabilityValue = 100,  -- holds avg or min depending on cached.useWorstDurability
    repairCost = nil,       -- exact live repair cost; nil while any damaged slot is unresolved
    repairCostComplete = false,
    -- WARNING: GetUnitSpeed returns secret values in combat → arithmetic taints. Cache OOC.
    speedPct = nil,
    speedWasSwimming = nil,
    -- Last clean hide-zero decision per stat row. Secret combat reads cannot be safely
    -- compared to 0, so they reuse this instead of making absent rows appear.
    cleanRowVisibility = {},
    updateErrorCount = 0,
    lastUpdateError = nil,
    displayMode = "flat",
    labelStyle = "full",
    targetSnapshot = "mythicPlus",
    updateInterval = 0.5,
}

-- Dirty flag for event-driven cache refresh (durability scan is per-19-slot, not free)
local durabilityDirty = true

-- External inventory/config events open one fresh delayed-retry generation. Timer
-- callbacks never reset this budget, so a stable nil/secret tooltip state cannot
-- create an endless three-second scan loop.
function addon.durabilityRuntime.MarkDirty()
    addon.durabilityRuntime.generation = addon.durabilityRuntime.generation + 1
    durabilityDirty = true
end
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
-- Ships with current WoW addon locale tables:
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
--   - hardcoded literal keys in special-case branches: "Vers" / "Speed" / "Armor"
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
        Leech = "Leech",        Avoidance = "Avoidance", Speed = "Movement",
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
        ["Appearance Presets"] = "Appearance Presets", ["Preset:"] = "Preset:",
        ["Classic"] = "Classic", ["Clean Dark"] = "Clean Dark", ["Midnight"] = "Midnight",
        ["Monochrome"] = "Monochrome", ["High Contrast"] = "High Contrast", ["Custom"] = "Custom",
        ["Previewing: %s"] = "Previewing: %s", ["Apply"] = "Apply", ["Cancel preview"] = "Cancel preview",
        ["Presets change font size, opacity, outline, panel background, HUD colors, and color behavior. They keep font face, layout, visible stats, scale, language, and refresh rate."] = "Presets change font size, opacity, outline, panel background, HUD colors, and color behavior. They keep font face, layout, visible stats, scale, language, and refresh rate.",
        ["This profile is shared by %d specs and %d other references. Applying changes all of them."] = "This profile is shared by %d specs and %d other references. Applying changes all of them.",
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
        ["Requires %s."] = "Requires %s.",
        ["Show Crit"] = "Show Crit", ["Show Haste"] = "Show Haste",
        ["Show Mastery"] = "Show Mastery", ["Show Versatility"] = "Show Versatility",
        ["Show Tertiary Stats"] = "Show Tertiary Stats",
        ["Show Leech"] = "Show Leech", ["Show Avoidance"] = "Show Avoidance", ["Show Speed"] = "Show Movement",
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
        ["Last known comparison"] = "Last known comparison", ["Source:"] = "Source:",
        ["Stats panel shown"] = "Stats panel shown", ["Stats panel hidden"] = "Stats panel hidden",
        ["Settings reset to defaults"] = "Settings reset to defaults",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /statspro import, /ss debug, /ss help"] = "Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again.",
        ["SwiftStats has no supported settings to import."] = "SwiftStats has no supported settings to import.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "These settings use a newer schema and cannot be imported by this StatsPro version.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "SwiftStats import is unavailable during combat. Try again after combat.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged.",
        ["Import"] = "Import",
        ["SwiftStats settings imported into new profile \"%s\"."] = "SwiftStats settings imported into new profile \"%s\".",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "SwiftStats import failed; profiles and assignments were preserved.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged.",
        ["All StatsPro data reset to defaults."] = "All StatsPro data reset to defaults.",
        -- Buttons + title:
        ["Reset to Defaults"] = "Reset to Defaults", ["Close"] = "Close",
        ["Open Settings"] = "Open Settings", ["Settings"] = "Settings",
        ["Profile:"] = "Profile:", ["Manage"] = "Manage", ["Profile Manager"] = "Profile Manager",
        ["Automatic - %s / %s"] = "Automatic - %s / %s", ["Shared by %d specs"] = "Shared by %d specs",
        ["Switch pending until combat ends"] = "Switch pending until combat ends", ["Account default profile"] = "Account default profile",
        ["Current"] = "Current", ["Active"] = "Active", ["Character default"] = "Character default",
        ["Assigned profile:"] = "Assigned profile:", ["Independent"] = "Independent", ["No visited characters"] = "No visited characters",
        ["Spec %d"] = "Spec %d", ["Profile changes are unavailable during combat."] = "Profile changes are unavailable during combat.",
        ["Waiting for a safe profile context."] = "Waiting for a safe profile context.",
        ["Compatibility mode - profiles are read-only."] = "Compatibility mode - profiles are read-only.",
        ["Profile to manage:"] = "Profile to manage:", ["Choose a profile"] = "Choose a profile",
        ["All settings"] = "All settings", ["Stat and gear settings"] = "Stat and gear settings", ["Layout settings"] = "Layout settings", ["Appearance settings"] = "Appearance settings", ["Choose settings to copy"] = "Choose settings to copy",
        ["Copy %s from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "Copy %s from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references.",
        ["Assign to selected context"] = "Assign to selected context", ["New from defaults..."] = "New from defaults...",
        ["Duplicate profile..."] = "Duplicate profile...", ["Rename profile..."] = "Rename profile...",
        ["Copy settings to assigned profile..."] = "Copy settings to assigned profile...", ["Swap assignments..."] = "Swap assignments...",
        ["Reset active profile..."] = "Reset active profile...", ["Delete profile..."] = "Delete profile...",
        ["Forget character..."] = "Forget character...", ["Confirm"] = "Confirm",
        ["Selected character"] = "Selected character", ["%s - %d known specs"] = "%s - %d known specs",
        ["Future new contexts"] = "Future new contexts", ["Tank: %s"] = "Tank: %s",
        ["Healer: %s"] = "Healer: %s", ["Damage: %s"] = "Damage: %s",
        ["Tank"] = "Tank", ["Healer"] = "Healer", ["Damage"] = "Damage",
        ["Use profile for all known specs..."] = "Use profile for all known specs...",
        ["Make shared specs independent..."] = "Make shared specs independent...",
        ["Set future role template..."] = "Set future role template...", ["Choose a role"] = "Choose a role",
        ["Use \"%s\" for all %d known specs of \"%s\"? Existing profiles and settings will be kept."] = "Use \"%s\" for all %d known specs of \"%s\"? Existing profiles and settings will be kept.",
        ["Make %d shared specs of \"%s\" independent? Each affected spec receives a separate copy; existing profiles stay unchanged."] = "Make %d shared specs of \"%s\" independent? Each affected spec receives a separate copy; existing profiles stay unchanged.",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy.",
        ["Unused"] = "Unused", ["Unused profile"] = "Unused profile", ["New Profile"] = "New Profile",
        ["%s Copy"] = "%s Copy", ["Choose a replacement profile"] = "Choose a replacement profile",
        ["Choose a context"] = "Choose a context", ["%d assigned specs, %d other references"] = "%d assigned specs, %d other references",
        ["Profile changes saved."] = "Profile changes saved.", ["Enter a valid profile name."] = "Enter a valid profile name.",
        ["Profile names can contain at most %d characters."] = "Profile names can contain at most %d characters.",
        ["A profile with this name already exists."] = "A profile with this name already exists.",
        ["Profiles changed; review and try again."] = "Profiles changed; review and try again.",
        ["The last profile cannot be deleted."] = "The last profile cannot be deleted.",
        ["Choose a replacement profile."] = "Choose a replacement profile.",
        ["The current character cannot be forgotten."] = "The current character cannot be forgotten.",
        ["Nothing changed."] = "Nothing changed.",
        ["Profile operation failed. Review the selection and try again."] = "Profile operation failed. Review the selection and try again.",
        ["Delete profile \"%s\" and replace all references with \"%s\"? This affects %d assigned specs and %d other references."] = "Delete profile \"%s\" and replace all references with \"%s\"? This affects %d assigned specs and %d other references.",
        ["Swap \"%s\" and \"%s\"? Their profile settings stay unchanged."] = "Swap \"%s\" and \"%s\"? Their profile settings stay unchanged.",
        ["Rename shared profile \"%s\" to \"%s\"? This affects %d assigned specs and %d other references."] = "Rename shared profile \"%s\" to \"%s\"? This affects %d assigned specs and %d other references.",
        ["Copy settings from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "Copy settings from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references.",
        ["Delete unused profile \"%s\"?"] = "Delete unused profile \"%s\"?",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "Forget \"%s\"? Its character record will be removed, but profile settings will be kept.",
        -- Templates:
        ["Auto (current: %s)"] = "Auto (current: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage.",
        -- Launcher description:
        ["Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window."] = "Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window.",
    },

    -- ruRU: Russian. Haste/Movement disambig is structural — WoW client uses speed
    -- words for both concepts, so Haste stays "Хаст" and Movement uses "Движ".
    -- Leech uses "Вамп" (вампиризм) over the literal "Кров" because
    -- "Кров…" risks being mis-read as "Кровотечение" (Bleed). All stat rows use 4-char
    -- forms where the language allows; "Сила" / "Блок" / "Крит" are already 4 chars.
    ruRU = {
        Crit = "Крит",          Haste = "Хаст",         Mastery = "Маст",       Vers = "Унив",
        Dodge = "Укл",          Parry = "Пари",         Block = "Блок",         Armor = "Брон",         Stagger = "Пошат",
        Strength = "Сила",      Agility = "Ловк",       Intellect = "Инт",      Stamina = "Выно",
        ItemLevel = "УрП",
        Leech = "Вамп",         Avoidance = "Избег",    Speed = "Движ",
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
        ["Appearance Presets"] = "Пресеты оформления", ["Preset:"] = "Пресет:",
        ["Classic"] = "Классика", ["Clean Dark"] = "Чистый тёмный", ["Midnight"] = "Полночь",
        ["Monochrome"] = "Монохром", ["High Contrast"] = "Высокий контраст", ["Custom"] = "Свой",
        ["Previewing: %s"] = "Предпросмотр: %s", ["Apply"] = "Применить", ["Cancel preview"] = "Отменить просмотр",
        ["Presets change font size, opacity, outline, panel background, HUD colors, and color behavior. They keep font face, layout, visible stats, scale, language, and refresh rate."] = "Пресеты меняют размер, прозрачность, обводку, фон, цвета HUD и поведение цветов. Гарнитура, макет, видимые статы, масштаб, язык и частота сохраняются.",
        ["This profile is shared by %d specs and %d other references. Applying changes all of them."] = "Профиль используют %d специализаций и ещё %d привязок. Изменения затронут их все.",
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
        ["Requires %s."] = "Требуется: %s.",
        ["Show Crit"] = "Показывать Крит", ["Show Haste"] = "Показывать Хаст",
        ["Show Mastery"] = "Показывать Мастерство", ["Show Versatility"] = "Показывать Универсальность",
        ["Show Tertiary Stats"] = "Показывать третичные",
        ["Show Leech"] = "Показывать Вампиризм", ["Show Avoidance"] = "Показывать Избегание", ["Show Speed"] = "Показывать скорость передвижения",
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
        ["Last known comparison"] = "Последнее известное сравнение", ["Source:"] = "Источник:",
        ["Stats panel shown"] = "Панель статов показана", ["Stats panel hidden"] = "Панель статов скрыта",
        ["Settings reset to defaults"] = "Настройки сброшены по умолчанию",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /statspro import, /ss debug, /ss help"] = "Команды: /ss или /statspro (настройки), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "Настройки SwiftStats не загружены. Включите SwiftStats на один вход в игру, выполните /reload, затем снова введите /statspro import.",
        ["SwiftStats has no supported settings to import."] = "В SwiftStats нет поддерживаемых настроек для импорта.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "Эти настройки используют более новую схему и не могут быть импортированы этой версией StatsPro.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "Настройки доступны только для чтения, поскольку они сохранены более новой версией StatsPro. Обновите StatsPro, чтобы изменять их.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "Импорт SwiftStats недоступен в бою. Повторите после боя.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "Импортировать совместимые настройки SwiftStats в новый профиль для текущего персонажа и специализации? Существующие профили, другие назначения, настройки аккаунта и данные SwiftStats останутся без изменений.",
        ["Import"] = "Импорт",
        ["SwiftStats settings imported into new profile \"%s\"."] = "Настройки SwiftStats импортированы в новый профиль «%s».",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "Не удалось импортировать SwiftStats; профили и назначения сохранены.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "Сбросить все данные StatsPro? Это безвозвратно удалит все профили, назначения персонажей и специализаций, шаблоны ролей, настройки аккаунта и сохранённые позиции. Данные SwiftStats останутся без изменений.",
        ["All StatsPro data reset to defaults."] = "Все данные StatsPro сброшены до значений по умолчанию.",
        -- Buttons + title:
        ["Reset to Defaults"] = "Сбросить настройки", ["Close"] = "Закрыть",
        ["Open Settings"] = "Открыть настройки", ["Settings"] = "Настройки",
        ["Profile:"] = "Профиль:", ["Manage"] = "Управление", ["Profile Manager"] = "Управление профилями",
        ["Automatic - %s / %s"] = "Автоматически — %s / %s", ["Shared by %d specs"] = "Общий для специализаций: %d",
        ["Switch pending until combat ends"] = "Переключение после окончания боя", ["Account default profile"] = "Профиль аккаунта по умолчанию",
        ["Current"] = "Текущий", ["Active"] = "Активно", ["Character default"] = "По умолчанию для персонажа",
        ["Assigned profile:"] = "Назначенный профиль:", ["Independent"] = "Независимый", ["No visited characters"] = "Нет посещённых персонажей",
        ["Spec %d"] = "Специализация %d", ["Profile changes are unavailable during combat."] = "Изменение профилей недоступно в бою.",
        ["Waiting for a safe profile context."] = "Ожидание безопасного контекста профиля.",
        ["Compatibility mode - profiles are read-only."] = "Режим совместимости — профили доступны только для чтения.",
        ["Profile to manage:"] = "Профиль для управления:", ["Choose a profile"] = "Выберите профиль",
        ["All settings"] = "Все настройки", ["Stat and gear settings"] = "Показатели и экипировка", ["Layout settings"] = "Расположение", ["Appearance settings"] = "Внешний вид", ["Choose settings to copy"] = "Выберите настройки для копирования",
        ["Copy %s from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "Копировать раздел «%s» из «%s» в «%s»? Будут изменены специализации: %d, другие ссылки: %d.",
        ["Assign to selected context"] = "Назначить выбранному контексту", ["New from defaults..."] = "Новый из настроек по умолчанию...",
        ["Duplicate profile..."] = "Дублировать профиль...", ["Rename profile..."] = "Переименовать профиль...",
        ["Copy settings to assigned profile..."] = "Копировать настройки в назначенный профиль...", ["Swap assignments..."] = "Поменять назначения местами...",
        ["Reset active profile..."] = "Сбросить активный профиль...", ["Delete profile..."] = "Удалить профиль...",
        ["Forget character..."] = "Забыть персонажа...", ["Confirm"] = "Подтвердить",
        ["Selected character"] = "Выбранный персонаж", ["%s - %d known specs"] = "%s — %d известных специализаций",
        ["Future new contexts"] = "Будущие новые контексты", ["Tank: %s"] = "Танк: %s",
        ["Healer: %s"] = "Лекарь: %s", ["Damage: %s"] = "Урон: %s",
        ["Tank"] = "Танк", ["Healer"] = "Лекарь", ["Damage"] = "Урон",
        ["Use profile for all known specs..."] = "Для всех известных специализаций...",
        ["Make shared specs independent..."] = "Разделить общие специализации...",
        ["Set future role template..."] = "Шаблон для будущей роли...", ["Choose a role"] = "Выберите роль",
        ["Use \"%s\" for all %d known specs of \"%s\"? Existing profiles and settings will be kept."] = "Использовать «%s» для всех %d известных специализаций персонажа «%s»? Существующие профили и настройки будут сохранены.",
        ["Make %d shared specs of \"%s\" independent? Each affected spec receives a separate copy; existing profiles stay unchanged."] = "Сделать %d общих специализаций персонажа «%s» независимыми? Каждая получит отдельную копию; существующие профили не изменятся.",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "Использовать «%s» как источник для будущих специализаций танка? Существующие назначения не изменятся; каждый новый контекст получит независимую копию.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "Использовать «%s» как источник для будущих специализаций лекаря? Существующие назначения не изменятся; каждый новый контекст получит независимую копию.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "Использовать «%s» как источник для будущих специализаций урона? Существующие назначения не изменятся; каждый новый контекст получит независимую копию.",
        ["Unused"] = "Не используется", ["Unused profile"] = "Неиспользуемый профиль", ["New Profile"] = "Новый профиль",
        ["%s Copy"] = "Копия %s", ["Choose a replacement profile"] = "Выберите профиль для замены",
        ["Choose a context"] = "Выберите контекст", ["%d assigned specs, %d other references"] = "Назначено специализациям: %d, других ссылок: %d",
        ["Profile changes saved."] = "Изменения профилей сохранены.", ["Enter a valid profile name."] = "Введите допустимое имя профиля.",
        ["Profile names can contain at most %d characters."] = "Имя профиля может содержать не более %d символов.",
        ["A profile with this name already exists."] = "Профиль с таким именем уже существует.",
        ["Profiles changed; review and try again."] = "Профили изменились. Проверьте выбор и повторите попытку.",
        ["The last profile cannot be deleted."] = "Последний профиль нельзя удалить.",
        ["Choose a replacement profile."] = "Выберите профиль для замены.",
        ["The current character cannot be forgotten."] = "Текущего персонажа нельзя забыть.",
        ["Nothing changed."] = "Ничего не изменилось.",
        ["Profile operation failed. Review the selection and try again."] = "Операция с профилем не выполнена. Проверьте выбор и повторите попытку.",
        ["Delete profile \"%s\" and replace all references with \"%s\"? This affects %d assigned specs and %d other references."] = "Удалить профиль «%s» и заменить все ссылки профилем «%s»? Будут затронуты специализации: %d, другие ссылки: %d.",
        ["Swap \"%s\" and \"%s\"? Their profile settings stay unchanged."] = "Поменять местами «%s» и «%s»? Настройки профилей не изменятся.",
        ["Rename shared profile \"%s\" to \"%s\"? This affects %d assigned specs and %d other references."] = "Переименовать общий профиль «%s» в «%s»? Будут затронуты специализации: %d, другие ссылки: %d.",
        ["Copy settings from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "Копировать настройки из «%s» в «%s»? Будут изменены специализации: %d, другие ссылки: %d.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "Сбросить активный профиль «%s»? Будут изменены специализации: %d, другие ссылки: %d.",
        ["Delete unused profile \"%s\"?"] = "Удалить неиспользуемый профиль «%s»?",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "Забыть «%s»? Запись персонажа будет удалена, но настройки профилей сохранятся.",
        -- Templates:
        ["Auto (current: %s)"] = "Авто (сейчас: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r Шрифт может не отображать символы %s. Выберите шрифт SharedMedia с нужным покрытием.",
        -- Launcher description:
        ["Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window."] = "HUD характеристик и экипировки: уровень предметов, прочность, стоимость ремонта и цели характеристик Archon. Нажмите ниже, чтобы открыть окно настроек.",
    },

    -- deDE: German. Haste="Tempo" matches the WoW German client term; Movement="Beweg"
    -- keeps the Haste/Movement split clear. Vers="Viels" evokes Vielseitigkeit
    -- without colliding with the everyday word "viel" (many/much). Durability="Haltb"
    -- avoids collision with the everyday word "Halt" (stop). Strength="Stär" preserves
    -- the umlaut character of Stärke at 4 chars (single char "Stä" reads truncated).
    deDE = {
        Crit = "Krit",          Haste = "Tempo",        Mastery = "Meist",      Vers = "Viels",
        Dodge = "Ausw",         Parry = "Par",          Block = "Block",        Armor = "Rüst",         Stagger = "Staff",
        Strength = "Stär",      Agility = "Bew",        Intellect = "Int",      Stamina = "Aus",
        ItemLevel = "GS",
        Leech = "Saug",         Avoidance = "Verm",     Speed = "Beweg",
        Durability = "Haltb",   Repair = "Repar",
        Defensive = "Defensiv",
        Color = "Farbe",
        -- ===== Settings UI (best-effort draft, native-speaker review welcome via Issues) =====
        -- Movement checkbox uses the long form to disambiguate from Haste="Tempo".
        ["Stats"] = "Werte", ["Layout"] = "Layout", ["Appearance"] = "Darstellung",
        ["Character"] = "Charakter", ["Item Level"] = "Gegenstandsstufe",
        ["Offensive"] = "Offensiv", ["Tertiary"] = "Tertiär",
        ["Gear"] = "Ausrüstung", ["Repair Cost"] = "Reparaturkosten",
        ["Side Panel"] = "Seitenpanel", ["Side Panel Contains"] = "Seitenpanel enthält",
        ["Value Display"] = "Werteanzeige",
        ["Frame & Position"] = "Fenster & Position",
        ["Typography"] = "Typografie",
        ["Appearance Presets"] = "Darstellungsvorlagen", ["Preset:"] = "Vorlage:",
        ["Classic"] = "Klassisch", ["Clean Dark"] = "Klar Dunkel", ["Midnight"] = "Mitternacht",
        ["Monochrome"] = "Monochrom", ["High Contrast"] = "Hoher Kontrast", ["Custom"] = "Benutzerdefiniert",
        ["Previewing: %s"] = "Vorschau: %s", ["Apply"] = "Anwenden", ["Cancel preview"] = "Vorschau abbrechen",
        ["Presets change font size, opacity, outline, panel background, HUD colors, and color behavior. They keep font face, layout, visible stats, scale, language, and refresh rate."] = "Vorlagen ändern Schriftgröße, Deckkraft, Kontur, Panelhintergrund, HUD-Farben und Farbverhalten. Schriftart, Layout, sichtbare Werte, Skalierung, Sprache und Aktualisierungsrate bleiben erhalten.",
        ["This profile is shared by %d specs and %d other references. Applying changes all of them."] = "Dieses Profil wird von %d Spezialisierungen und %d weiteren Verweisen geteilt. Anwenden ändert alle.",
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
        ["Requires %s."] = "Erfordert %s.",
        ["Show Crit"] = "Krit. anzeigen", ["Show Haste"] = "Tempo anzeigen",
        ["Show Mastery"] = "Meisterschaft anzeigen", ["Show Versatility"] = "Vielseitigkeit anzeigen",
        ["Show Tertiary Stats"] = "Tertiärwerte anzeigen",
        ["Show Leech"] = "Aussaugen anzeigen", ["Show Avoidance"] = "Vermeidung anzeigen", ["Show Speed"] = "Bewegung anzeigen",
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
        ["Last known comparison"] = "Letzter bekannter Vergleich", ["Source:"] = "Quelle:",
        ["Stats panel shown"] = "Statpanel angezeigt", ["Stats panel hidden"] = "Statpanel ausgeblendet",
        ["Settings reset to defaults"] = "Einstellungen auf Standard zurückgesetzt",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /statspro import, /ss debug, /ss help"] = "Befehle: /ss oder /statspro (Einstellungen), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "SwiftStats-Einstellungen sind nicht geladen. Aktiviere SwiftStats für eine Anmeldung, führe /reload aus und gib danach erneut /statspro import ein.",
        ["SwiftStats has no supported settings to import."] = "SwiftStats enthält keine unterstützten Einstellungen zum Importieren.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "Diese Einstellungen verwenden ein neueres Schema und können von dieser StatsPro-Version nicht importiert werden.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "Die Einstellungen sind schreibgeschützt, da sie mit einer neueren StatsPro-Version gespeichert wurden. Aktualisiere StatsPro, um sie zu ändern.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "Der SwiftStats-Import ist im Kampf nicht verfügbar. Versuche es nach dem Kampf erneut.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "Kompatible SwiftStats-Einstellungen in ein neues Profil für den aktuellen Charakter und die aktuelle Spezialisierung importieren? Bestehende Profile, andere Zuweisungen, Kontoeinstellungen und SwiftStats-Daten bleiben unverändert.",
        ["Import"] = "Importieren",
        ["SwiftStats settings imported into new profile \"%s\"."] = "SwiftStats-Einstellungen wurden in das neue Profil „%s“ importiert.",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "SwiftStats-Import fehlgeschlagen; Profile und Zuweisungen wurden beibehalten.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "Alle StatsPro-Daten zurücksetzen? Dadurch werden dauerhaft alle Profile, Charakter- und Spezialisierungszuweisungen, Rollenvorlagen, Kontoeinstellungen und gespeicherten Positionen entfernt. SwiftStats-Daten bleiben unverändert.",
        ["All StatsPro data reset to defaults."] = "Alle StatsPro-Daten wurden auf die Standardwerte zurückgesetzt.",
        ["Reset to Defaults"] = "Auf Standard", ["Close"] = "Schließen",
        ["Open Settings"] = "Einstellungen öffnen", ["Settings"] = "Einstellungen",
        ["Profile:"] = "Profil:", ["Manage"] = "Verwalten", ["Profile Manager"] = "Profilverwaltung",
        ["Automatic - %s / %s"] = "Automatisch – %s / %s", ["Shared by %d specs"] = "Von %d Spezialisierungen geteilt",
        ["Switch pending until combat ends"] = "Wechsel nach Kampfende", ["Account default profile"] = "Standardprofil des Accounts",
        ["Current"] = "Aktuell", ["Active"] = "Aktiv", ["Character default"] = "Charakterstandard",
        ["Assigned profile:"] = "Zugewiesenes Profil:", ["Independent"] = "Unabhängig", ["No visited characters"] = "Keine besuchten Charaktere",
        ["Spec %d"] = "Spezialisierung %d", ["Profile changes are unavailable during combat."] = "Profiländerungen sind im Kampf nicht verfügbar.",
        ["Waiting for a safe profile context."] = "Warten auf einen sicheren Profilkontext.",
        ["Compatibility mode - profiles are read-only."] = "Kompatibilitätsmodus – Profile sind schreibgeschützt.",
        ["Profile to manage:"] = "Zu verwaltendes Profil:", ["Choose a profile"] = "Profil auswählen",
        ["All settings"] = "Alle Einstellungen", ["Stat and gear settings"] = "Werte und Ausrüstung", ["Layout settings"] = "Layout-Einstellungen", ["Appearance settings"] = "Darstellung", ["Choose settings to copy"] = "Zu kopierende Einstellungen auswählen",
        ["Copy %s from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "%s von „%s“ nach „%s“ kopieren? Geändert werden %d zugewiesene Spezialisierungen und %d weitere Verweise.",
        ["Assign to selected context"] = "Ausgewähltem Kontext zuweisen", ["New from defaults..."] = "Neu aus Standardwerten...",
        ["Duplicate profile..."] = "Profil duplizieren...", ["Rename profile..."] = "Profil umbenennen...",
        ["Copy settings to assigned profile..."] = "Einstellungen ins zugewiesene Profil kopieren...", ["Swap assignments..."] = "Zuweisungen tauschen...",
        ["Reset active profile..."] = "Aktives Profil zurücksetzen...", ["Delete profile..."] = "Profil löschen...",
        ["Forget character..."] = "Charakter vergessen...", ["Confirm"] = "Bestätigen",
        ["Selected character"] = "Ausgewählter Charakter", ["%s - %d known specs"] = "%s – %d bekannte Spezialisierungen",
        ["Future new contexts"] = "Künftige neue Kontexte", ["Tank: %s"] = "Tank: %s",
        ["Healer: %s"] = "Heiler: %s", ["Damage: %s"] = "Schaden: %s",
        ["Tank"] = "Tank", ["Healer"] = "Heiler", ["Damage"] = "Schaden",
        ["Use profile for all known specs..."] = "Profil für alle bekannten Spezialisierungen...",
        ["Make shared specs independent..."] = "Geteilte Spezialisierungen unabhängig machen...",
        ["Set future role template..."] = "Künftige Rollenvorlage festlegen...", ["Choose a role"] = "Rolle auswählen",
        ["Use \"%s\" for all %d known specs of \"%s\"? Existing profiles and settings will be kept."] = "„%s“ für alle %d bekannten Spezialisierungen von „%s“ verwenden? Bestehende Profile und Einstellungen bleiben erhalten.",
        ["Make %d shared specs of \"%s\" independent? Each affected spec receives a separate copy; existing profiles stay unchanged."] = "%d geteilte Spezialisierungen von „%s“ unabhängig machen? Jede betroffene Spezialisierung erhält eine eigene Kopie; bestehende Profile bleiben unverändert.",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "„%s“ als Quelle für künftige Tank-Kontexte verwenden? Bestehende Zuweisungen ändern sich nicht; jeder neue Kontext erhält eine unabhängige Kopie.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "„%s“ als Quelle für künftige Heiler-Kontexte verwenden? Bestehende Zuweisungen ändern sich nicht; jeder neue Kontext erhält eine unabhängige Kopie.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "„%s“ als Quelle für künftige Schadenskontexte verwenden? Bestehende Zuweisungen ändern sich nicht; jeder neue Kontext erhält eine unabhängige Kopie.",
        ["Unused"] = "Ungenutzt", ["Unused profile"] = "Ungenutztes Profil", ["New Profile"] = "Neues Profil",
        ["%s Copy"] = "Kopie von %s", ["Choose a replacement profile"] = "Ersatzprofil auswählen",
        ["Choose a context"] = "Kontext auswählen", ["%d assigned specs, %d other references"] = "%d zugewiesene Spezialisierungen, %d weitere Verweise",
        ["Profile changes saved."] = "Profiländerungen gespeichert.", ["Enter a valid profile name."] = "Gib einen gültigen Profilnamen ein.",
        ["Profile names can contain at most %d characters."] = "Profilnamen dürfen höchstens %d Zeichen enthalten.",
        ["A profile with this name already exists."] = "Ein Profil mit diesem Namen existiert bereits.",
        ["Profiles changed; review and try again."] = "Die Profile wurden geändert. Prüfe die Auswahl und versuche es erneut.",
        ["The last profile cannot be deleted."] = "Das letzte Profil kann nicht gelöscht werden.",
        ["Choose a replacement profile."] = "Wähle ein Ersatzprofil aus.",
        ["The current character cannot be forgotten."] = "Der aktuelle Charakter kann nicht vergessen werden.",
        ["Nothing changed."] = "Es wurde nichts geändert.",
        ["Profile operation failed. Review the selection and try again."] = "Der Profilvorgang ist fehlgeschlagen. Prüfe die Auswahl und versuche es erneut.",
        ["Delete profile \"%s\" and replace all references with \"%s\"? This affects %d assigned specs and %d other references."] = "Profil „%s“ löschen und alle Verweise durch „%s“ ersetzen? Betroffen: %d zugewiesene Spezialisierungen und %d weitere Verweise.",
        ["Swap \"%s\" and \"%s\"? Their profile settings stay unchanged."] = "„%s“ und „%s“ tauschen? Ihre Profileinstellungen bleiben unverändert.",
        ["Rename shared profile \"%s\" to \"%s\"? This affects %d assigned specs and %d other references."] = "Geteiltes Profil „%s“ in „%s“ umbenennen? Betroffen: %d zugewiesene Spezialisierungen und %d weitere Verweise.",
        ["Copy settings from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "Einstellungen von „%s“ nach „%s“ kopieren? Geändert werden %d zugewiesene Spezialisierungen und %d weitere Verweise.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "Aktives Profil „%s“ auf Standardwerte zurücksetzen? Geändert werden %d zugewiesene Spezialisierungen und %d weitere Verweise.",
        ["Delete unused profile \"%s\"?"] = "Ungenutztes Profil „%s“ löschen?",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "„%s“ vergessen? Der Charaktereintrag wird entfernt, die Profileinstellungen bleiben erhalten.",
        ["Auto (current: %s)"] = "Auto (aktuell: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r Schrift unterstützt %s eventuell nicht. Wähle eine SharedMedia-Schrift mit Glyphenabdeckung.",
        ["Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window."] = "HUD für Werte und Ausrüstung: Gegenstandsstufe, Haltbarkeit, Reparaturkosten und Archon-Stat-Ziele. Klicke unten, um die vollständigen Einstellungen zu öffnen.",
    },

    -- frFR: French. Hâte (4 chars, accented form) is WoW's official Haste term; Dépl
    -- (déplacement) distinguishes Movement. Strength="Forc" and Durability="Dura" use 4-char forms so
    -- they don't collide with the everyday words "Fort" / "Dur". Esqu (Esquive) at 4
    -- chars reads more clearly than the truncated 3-char "Esq".
    frFR = {
        Crit = "Crit",          Haste = "Hâte",         Mastery = "Maît",       Vers = "Polyv",
        Dodge = "Esqu",         Parry = "Par",          Block = "Bloc",         Armor = "Arm",          Stagger = "Report",
        Strength = "Forc",      Agility = "Agil",       Intellect = "Int",      Stamina = "End",
        ItemLevel = "NivObj",
        Leech = "Vamp",         Avoidance = "Évit",     Speed = "Dépl",
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
        ["Appearance Presets"] = "Préréglages d'apparence", ["Preset:"] = "Préréglage :",
        ["Classic"] = "Classique", ["Clean Dark"] = "Sombre épuré", ["Midnight"] = "Minuit",
        ["Monochrome"] = "Monochrome", ["High Contrast"] = "Contraste élevé", ["Custom"] = "Personnalisé",
        ["Previewing: %s"] = "Aperçu : %s", ["Apply"] = "Appliquer", ["Cancel preview"] = "Annuler l'aperçu",
        ["Presets change font size, opacity, outline, panel background, HUD colors, and color behavior. They keep font face, layout, visible stats, scale, language, and refresh rate."] = "Les préréglages changent taille, opacité, contour, fond, couleurs du HUD et comportement des couleurs. Police, disposition, statistiques visibles, échelle, langue et fréquence restent inchangées.",
        ["This profile is shared by %d specs and %d other references. Applying changes all of them."] = "Ce profil est partagé par %d spécialisations et %d autres références. L'application les modifie toutes.",
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
        ["Requires %s."] = "Nécessite %s.",
        ["Show Crit"] = "Afficher Crit", ["Show Haste"] = "Afficher Hâte",
        ["Show Mastery"] = "Afficher Maîtrise", ["Show Versatility"] = "Afficher Polyvalence",
        ["Show Tertiary Stats"] = "Afficher tertiaires",
        ["Show Leech"] = "Afficher Vampirisme", ["Show Avoidance"] = "Afficher Évitement", ["Show Speed"] = "Afficher déplacement",
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
        ["Last known comparison"] = "Dernière comparaison connue", ["Source:"] = "Source :",
        ["Stats panel shown"] = "Panneau de stats affiché", ["Stats panel hidden"] = "Panneau de stats masqué",
        ["Settings reset to defaults"] = "Paramètres réinitialisés",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /statspro import, /ss debug, /ss help"] = "Commandes : /ss ou /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "Les réglages de SwiftStats ne sont pas chargés. Activez SwiftStats pour une connexion, exécutez /reload, puis relancez /statspro import.",
        ["SwiftStats has no supported settings to import."] = "SwiftStats ne contient aucun réglage pris en charge à importer.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "Ces réglages utilisent un schéma plus récent et ne peuvent pas être importés par cette version de StatsPro.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "Les paramètres sont en lecture seule, car ils ont été enregistrés par une version plus récente de StatsPro. Mettez StatsPro à jour pour les modifier.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "L’importation SwiftStats est indisponible en combat. Réessayez après le combat.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "Importer les réglages SwiftStats compatibles dans un nouveau profil pour le personnage et la spécialisation actuels ? Les profils existants, les autres affectations, les paramètres du compte et les données SwiftStats resteront inchangés.",
        ["Import"] = "Importer",
        ["SwiftStats settings imported into new profile \"%s\"."] = "Réglages SwiftStats importés dans le nouveau profil « %s ».",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "Échec de l’importation SwiftStats ; les profils et les affectations ont été conservés.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "Réinitialiser toutes les données StatsPro ? Cela supprimera définitivement tous les profils, les affectations de personnages et de spécialisations, les modèles de rôle, les paramètres du compte et les positions enregistrées. Les données SwiftStats resteront inchangées.",
        ["All StatsPro data reset to defaults."] = "Toutes les données StatsPro ont été réinitialisées aux valeurs par défaut.",
        ["Reset to Defaults"] = "Par défaut", ["Close"] = "Fermer",
        ["Open Settings"] = "Ouvrir les paramètres", ["Settings"] = "Paramètres",
        ["Profile:"] = "Profil :", ["Manage"] = "Gérer", ["Profile Manager"] = "Gestionnaire de profils",
        ["Automatic - %s / %s"] = "Automatique – %s / %s", ["Shared by %d specs"] = "Partagé par %d spécialisations",
        ["Switch pending until combat ends"] = "Changement après le combat", ["Account default profile"] = "Profil de compte par défaut",
        ["Current"] = "Actuel", ["Active"] = "Actif", ["Character default"] = "Profil de personnage par défaut",
        ["Assigned profile:"] = "Profil attribué :", ["Independent"] = "Indépendant", ["No visited characters"] = "Aucun personnage visité",
        ["Spec %d"] = "Spécialisation %d", ["Profile changes are unavailable during combat."] = "Les changements de profil sont indisponibles en combat.",
        ["Waiting for a safe profile context."] = "En attente d’un contexte de profil sûr.",
        ["Compatibility mode - profiles are read-only."] = "Mode de compatibilité – les profils sont en lecture seule.",
        ["Profile to manage:"] = "Profil à gérer :", ["Choose a profile"] = "Choisir un profil",
        ["All settings"] = "Tous les réglages", ["Stat and gear settings"] = "Caractéristiques et équipement", ["Layout settings"] = "Disposition", ["Appearance settings"] = "Apparence", ["Choose settings to copy"] = "Choisir les réglages à copier",
        ["Copy %s from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "Copier « %s » de « %s » vers « %s » ? Cela modifie %d spécialisations attribuées et %d autres références.",
        ["Assign to selected context"] = "Attribuer au contexte sélectionné", ["New from defaults..."] = "Nouveau depuis les valeurs par défaut...",
        ["Duplicate profile..."] = "Dupliquer le profil...", ["Rename profile..."] = "Renommer le profil...",
        ["Copy settings to assigned profile..."] = "Copier les réglages vers le profil attribué...", ["Swap assignments..."] = "Échanger les attributions...",
        ["Reset active profile..."] = "Réinitialiser le profil actif...", ["Delete profile..."] = "Supprimer le profil...",
        ["Forget character..."] = "Oublier le personnage...", ["Confirm"] = "Confirmer",
        ["Selected character"] = "Personnage sélectionné", ["%s - %d known specs"] = "%s – %d spécialisations connues",
        ["Future new contexts"] = "Nouveaux contextes futurs", ["Tank: %s"] = "Tank : %s",
        ["Healer: %s"] = "Soigneur : %s", ["Damage: %s"] = "Dégâts : %s",
        ["Tank"] = "Tank", ["Healer"] = "Soigneur", ["Damage"] = "Dégâts",
        ["Use profile for all known specs..."] = "Utiliser pour toutes les spécialisations...",
        ["Make shared specs independent..."] = "Rendre indépendantes les spécialisations partagées...",
        ["Set future role template..."] = "Définir le modèle de rôle futur...", ["Choose a role"] = "Choisir un rôle",
        ["Use \"%s\" for all %d known specs of \"%s\"? Existing profiles and settings will be kept."] = "Utiliser « %s » pour les %d spécialisations connues de « %s » ? Les profils et réglages existants seront conservés.",
        ["Make %d shared specs of \"%s\" independent? Each affected spec receives a separate copy; existing profiles stay unchanged."] = "Rendre indépendantes %d spécialisations partagées de « %s » ? Chacune recevra une copie distincte ; les profils existants resteront inchangés.",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "Utiliser « %s » comme source des futurs contextes Tank ? Les attributions existantes ne changeront pas ; chaque nouveau contexte recevra une copie indépendante.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "Utiliser « %s » comme source des futurs contextes Soigneur ? Les attributions existantes ne changeront pas ; chaque nouveau contexte recevra une copie indépendante.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "Utiliser « %s » comme source des futurs contextes Dégâts ? Les attributions existantes ne changeront pas ; chaque nouveau contexte recevra une copie indépendante.",
        ["Unused"] = "Inutilisé", ["Unused profile"] = "Profil inutilisé", ["New Profile"] = "Nouveau profil",
        ["%s Copy"] = "Copie de %s", ["Choose a replacement profile"] = "Choisir un profil de remplacement",
        ["Choose a context"] = "Choisir un contexte", ["%d assigned specs, %d other references"] = "%d spécialisations attribuées, %d autres références",
        ["Profile changes saved."] = "Modifications des profils enregistrées.", ["Enter a valid profile name."] = "Saisissez un nom de profil valide.",
        ["Profile names can contain at most %d characters."] = "Les noms de profil peuvent contenir au maximum %d caractères.",
        ["A profile with this name already exists."] = "Un profil portant ce nom existe déjà.",
        ["Profiles changed; review and try again."] = "Les profils ont changé. Vérifiez la sélection et réessayez.",
        ["The last profile cannot be deleted."] = "Le dernier profil ne peut pas être supprimé.",
        ["Choose a replacement profile."] = "Choisissez un profil de remplacement.",
        ["The current character cannot be forgotten."] = "Le personnage actuel ne peut pas être oublié.",
        ["Nothing changed."] = "Aucune modification.",
        ["Profile operation failed. Review the selection and try again."] = "L’opération sur le profil a échoué. Vérifiez la sélection et réessayez.",
        ["Delete profile \"%s\" and replace all references with \"%s\"? This affects %d assigned specs and %d other references."] = "Supprimer le profil « %s » et remplacer toutes les références par « %s » ? Cela affecte %d spécialisations attribuées et %d autres références.",
        ["Swap \"%s\" and \"%s\"? Their profile settings stay unchanged."] = "Échanger « %s » et « %s » ? Leurs réglages de profil resteront inchangés.",
        ["Rename shared profile \"%s\" to \"%s\"? This affects %d assigned specs and %d other references."] = "Renommer le profil partagé « %s » en « %s » ? Cela affecte %d spécialisations attribuées et %d autres références.",
        ["Copy settings from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "Copier les réglages de « %s » vers « %s » ? Cela modifie %d spécialisations attribuées et %d autres références.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "Réinitialiser le profil actif « %s » ? Cela modifie %d spécialisations attribuées et %d autres références.",
        ["Delete unused profile \"%s\"?"] = "Supprimer le profil inutilisé « %s » ?",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "Oublier « %s » ? Sa fiche de personnage sera supprimée, mais les réglages des profils seront conservés.",
        ["Auto (current: %s)"] = "Auto (actuel : %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r La police peut ne pas afficher les glyphes %s. Choisissez une police SharedMedia avec couverture appropriée.",
        ["Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window."] = "HUD de caractéristiques et d'équipement : niveau d'objet, durabilité, coût de réparation et objectifs de caractéristiques Archon. Cliquez ci-dessous pour ouvrir la fenêtre de paramètres complète.",
    },

    -- esES: Spanish (Spain). Haste stays Celeridad; Movement uses Movimiento
    -- to avoid the old Speed-rating wording. Leech="Robo" matches "Robo de vida" (life steal),
    -- the WoW Spanish term — closer to client wording than the literal "Suc(ción)".
    -- Most rows use 4-char forms (Esqu / Fuer / Agil) — 3-char abbreviations look
    -- unfinished beside Spanish's typically-longer words.
    esES = {
        Crit = "Crít",          Haste = "Cele",         Mastery = "Maest",      Vers = "Versat",
        Dodge = "Esqu",         Parry = "Par",          Block = "Bloq",         Armor = "Arm",          Stagger = "Aplaz",
        Strength = "Fuer",      Agility = "Agil",       Intellect = "Int",      Stamina = "Aguante",
        ItemLevel = "NvObj",
        Leech = "Robo",         Avoidance = "Evit",     Speed = "Mov",
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
        ["Appearance Presets"] = "Preajustes de apariencia", ["Preset:"] = "Preajuste:",
        ["Classic"] = "Clásico", ["Clean Dark"] = "Oscuro limpio", ["Midnight"] = "Medianoche",
        ["Monochrome"] = "Monocromo", ["High Contrast"] = "Alto contraste", ["Custom"] = "Personalizado",
        ["Previewing: %s"] = "Vista previa: %s", ["Apply"] = "Aplicar", ["Cancel preview"] = "Cancelar vista previa",
        ["Presets change font size, opacity, outline, panel background, HUD colors, and color behavior. They keep font face, layout, visible stats, scale, language, and refresh rate."] = "Los preajustes cambian tamaño, opacidad, contorno, fondo, colores del HUD y comportamiento del color. Conservan tipografía, diseño, estadísticas visibles, escala, idioma y frecuencia.",
        ["This profile is shared by %d specs and %d other references. Applying changes all of them."] = "Este perfil se comparte entre %d especializaciones y %d referencias más. Aplicar las cambia todas.",
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
        ["Requires %s."] = "Requiere %s.",
        ["Show Crit"] = "Mostrar Crít.", ["Show Haste"] = "Mostrar Celeridad",
        ["Show Mastery"] = "Mostrar Maestría", ["Show Versatility"] = "Mostrar Versatilidad",
        ["Show Tertiary Stats"] = "Mostrar terciarias",
        ["Show Leech"] = "Mostrar Robo", ["Show Avoidance"] = "Mostrar Evitación", ["Show Speed"] = "Mostrar movimiento",
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
        ["Last known comparison"] = "Última comparación conocida", ["Source:"] = "Fuente:",
        ["Stats panel shown"] = "Panel de estadísticas mostrado", ["Stats panel hidden"] = "Panel de estadísticas oculto",
        ["Settings reset to defaults"] = "Ajustes restablecidos",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /statspro import, /ss debug, /ss help"] = "Comandos: /ss o /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "Los ajustes de SwiftStats no están cargados. Activa SwiftStats durante un inicio de sesión, ejecuta /reload y vuelve a usar /statspro import.",
        ["SwiftStats has no supported settings to import."] = "SwiftStats no tiene ajustes compatibles para importar.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "Estos ajustes usan un esquema más reciente y esta versión de StatsPro no puede importarlos.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "Los ajustes son de solo lectura porque se guardaron con una versión más reciente de StatsPro. Actualiza StatsPro para modificarlos.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "La importación de SwiftStats no está disponible en combate. Inténtalo de nuevo después.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "¿Importar la configuración compatible de SwiftStats en un perfil nuevo para el personaje y la especialización actuales? Los perfiles existentes, las demás asignaciones, la configuración de la cuenta y los datos de SwiftStats no cambiarán.",
        ["Import"] = "Importar",
        ["SwiftStats settings imported into new profile \"%s\"."] = "La configuración de SwiftStats se importó al perfil nuevo «%s».",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "La importación de SwiftStats falló; se conservaron los perfiles y las asignaciones.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "¿Restablecer todos los datos de StatsPro? Esto eliminará permanentemente todos los perfiles, las asignaciones de personajes y especializaciones, las plantillas de rol, la configuración de la cuenta y las posiciones guardadas. Los datos de SwiftStats no cambiarán.",
        ["All StatsPro data reset to defaults."] = "Todos los datos de StatsPro se restablecieron a los valores predeterminados.",
        ["Reset to Defaults"] = "Restablecer", ["Close"] = "Cerrar",
        ["Open Settings"] = "Abrir ajustes", ["Settings"] = "Ajustes",
        ["Profile:"] = "Perfil:", ["Manage"] = "Gestionar", ["Profile Manager"] = "Gestor de perfiles",
        ["Automatic - %s / %s"] = "Automático – %s / %s", ["Shared by %d specs"] = "Compartido por %d especializaciones",
        ["Switch pending until combat ends"] = "Cambio al terminar el combate", ["Account default profile"] = "Perfil de cuenta predeterminado",
        ["Current"] = "Actual", ["Active"] = "Activo", ["Character default"] = "Predeterminado del personaje",
        ["Assigned profile:"] = "Perfil asignado:", ["Independent"] = "Independiente", ["No visited characters"] = "No hay personajes visitados",
        ["Spec %d"] = "Especialización %d", ["Profile changes are unavailable during combat."] = "Los cambios de perfil no están disponibles en combate.",
        ["Waiting for a safe profile context."] = "Esperando un contexto de perfil seguro.",
        ["Compatibility mode - profiles are read-only."] = "Modo de compatibilidad: los perfiles son de solo lectura.",
        ["Profile to manage:"] = "Perfil que gestionar:", ["Choose a profile"] = "Elige un perfil",
        ["All settings"] = "Todos los ajustes", ["Stat and gear settings"] = "Estadísticas y equipo", ["Layout settings"] = "Diseño", ["Appearance settings"] = "Apariencia", ["Choose settings to copy"] = "Elige los ajustes que copiar",
        ["Copy %s from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "¿Copiar «%s» de «%s» a «%s»? Esto cambia %d especializaciones asignadas y %d referencias más.",
        ["Assign to selected context"] = "Asignar al contexto seleccionado", ["New from defaults..."] = "Nuevo desde valores predeterminados...",
        ["Duplicate profile..."] = "Duplicar perfil...", ["Rename profile..."] = "Cambiar nombre del perfil...",
        ["Copy settings to assigned profile..."] = "Copiar ajustes al perfil asignado...", ["Swap assignments..."] = "Intercambiar asignaciones...",
        ["Reset active profile..."] = "Restablecer perfil activo...", ["Delete profile..."] = "Eliminar perfil...",
        ["Forget character..."] = "Olvidar personaje...", ["Confirm"] = "Confirmar",
        ["Selected character"] = "Personaje seleccionado", ["%s - %d known specs"] = "%s – %d especializaciones conocidas",
        ["Future new contexts"] = "Nuevos contextos futuros", ["Tank: %s"] = "Tanque: %s",
        ["Healer: %s"] = "Sanador: %s", ["Damage: %s"] = "Daño: %s",
        ["Tank"] = "Tanque", ["Healer"] = "Sanador", ["Damage"] = "Daño",
        ["Use profile for all known specs..."] = "Usar en todas las especializaciones conocidas...",
        ["Make shared specs independent..."] = "Independizar especializaciones compartidas...",
        ["Set future role template..."] = "Definir plantilla de rol futura...", ["Choose a role"] = "Elige un rol",
        ["Use \"%s\" for all %d known specs of \"%s\"? Existing profiles and settings will be kept."] = "¿Usar «%s» para las %d especializaciones conocidas de «%s»? Se conservarán los perfiles y ajustes existentes.",
        ["Make %d shared specs of \"%s\" independent? Each affected spec receives a separate copy; existing profiles stay unchanged."] = "¿Independizar %d especializaciones compartidas de «%s»? Cada una recibirá una copia distinta; los perfiles existentes no cambiarán.",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "¿Usar «%s» como origen para futuros contextos de Tanque? Las asignaciones existentes no cambiarán; cada contexto nuevo recibirá una copia independiente.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "¿Usar «%s» como origen para futuros contextos de Sanador? Las asignaciones existentes no cambiarán; cada contexto nuevo recibirá una copia independiente.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "¿Usar «%s» como origen para futuros contextos de Daño? Las asignaciones existentes no cambiarán; cada contexto nuevo recibirá una copia independiente.",
        ["Unused"] = "Sin usar", ["Unused profile"] = "Perfil sin usar", ["New Profile"] = "Perfil nuevo",
        ["%s Copy"] = "Copia de %s", ["Choose a replacement profile"] = "Elige un perfil de reemplazo",
        ["Choose a context"] = "Elige un contexto", ["%d assigned specs, %d other references"] = "%d especializaciones asignadas, %d referencias más",
        ["Profile changes saved."] = "Cambios de perfiles guardados.", ["Enter a valid profile name."] = "Introduce un nombre de perfil válido.",
        ["Profile names can contain at most %d characters."] = "Los nombres de perfil pueden tener un máximo de %d caracteres.",
        ["A profile with this name already exists."] = "Ya existe un perfil con este nombre.",
        ["Profiles changed; review and try again."] = "Los perfiles han cambiado. Revisa la selección e inténtalo de nuevo.",
        ["The last profile cannot be deleted."] = "No se puede eliminar el último perfil.",
        ["Choose a replacement profile."] = "Elige un perfil de reemplazo.",
        ["The current character cannot be forgotten."] = "No se puede olvidar al personaje actual.",
        ["Nothing changed."] = "No se ha cambiado nada.",
        ["Profile operation failed. Review the selection and try again."] = "La operación del perfil ha fallado. Revisa la selección e inténtalo de nuevo.",
        ["Delete profile \"%s\" and replace all references with \"%s\"? This affects %d assigned specs and %d other references."] = "¿Eliminar el perfil «%s» y reemplazar todas las referencias por «%s»? Esto afecta a %d especializaciones asignadas y %d referencias más.",
        ["Swap \"%s\" and \"%s\"? Their profile settings stay unchanged."] = "¿Intercambiar «%s» y «%s»? Sus ajustes de perfil no cambiarán.",
        ["Rename shared profile \"%s\" to \"%s\"? This affects %d assigned specs and %d other references."] = "¿Cambiar el nombre del perfil compartido «%s» a «%s»? Esto afecta a %d especializaciones asignadas y %d referencias más.",
        ["Copy settings from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "¿Copiar los ajustes de «%s» a «%s»? Esto cambia %d especializaciones asignadas y %d referencias más.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "¿Restablecer el perfil activo «%s»? Esto cambia %d especializaciones asignadas y %d referencias más.",
        ["Delete unused profile \"%s\"?"] = "¿Eliminar el perfil sin usar «%s»?",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "¿Olvidar a «%s»? Se eliminará su registro de personaje, pero se conservarán los ajustes de perfiles.",
        ["Auto (current: %s)"] = "Auto (actual: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r La fuente puede no mostrar glifos %s. Elige una fuente SharedMedia con cobertura.",
        ["Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window."] = "HUD de estadísticas y equipo: nivel de objeto, durabilidad, coste de reparación y objetivos de estadísticas de Archon. Haz clic abajo para abrir la ventana de ajustes.",
    },

    -- esMX: Latin American Spanish — stat-term short forms are effectively shared
    -- with esES (no regional split for combat stats). Mirrored 1:1 from esES table.
    esMX = {
        Crit = "Crít",          Haste = "Cele",         Mastery = "Maest",      Vers = "Versat",
        Dodge = "Esqu",         Parry = "Par",          Block = "Bloq",         Armor = "Arm",          Stagger = "Aplaz",
        Strength = "Fuer",      Agility = "Agil",       Intellect = "Int",      Stamina = "Aguante",
        ItemLevel = "NvObj",
        Leech = "Robo",         Avoidance = "Evit",     Speed = "Mov",
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
        ["Appearance Presets"] = "Preajustes de apariencia", ["Preset:"] = "Preajuste:",
        ["Classic"] = "Clásico", ["Clean Dark"] = "Oscuro limpio", ["Midnight"] = "Medianoche",
        ["Monochrome"] = "Monocromo", ["High Contrast"] = "Alto contraste", ["Custom"] = "Personalizado",
        ["Previewing: %s"] = "Vista previa: %s", ["Apply"] = "Aplicar", ["Cancel preview"] = "Cancelar vista previa",
        ["Presets change font size, opacity, outline, panel background, HUD colors, and color behavior. They keep font face, layout, visible stats, scale, language, and refresh rate."] = "Los preajustes cambian tamaño, opacidad, contorno, fondo, colores del HUD y comportamiento del color. Conservan tipografía, diseño, estadísticas visibles, escala, idioma y frecuencia.",
        ["This profile is shared by %d specs and %d other references. Applying changes all of them."] = "Este perfil se comparte entre %d especializaciones y %d referencias más. Aplicar las cambia todas.",
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
        ["Requires %s."] = "Requiere %s.",
        ["Show Crit"] = "Mostrar Crít.", ["Show Haste"] = "Mostrar Celeridad",
        ["Show Mastery"] = "Mostrar Maestría", ["Show Versatility"] = "Mostrar Versatilidad",
        ["Show Tertiary Stats"] = "Mostrar terciarias",
        ["Show Leech"] = "Mostrar Robo", ["Show Avoidance"] = "Mostrar Evitación", ["Show Speed"] = "Mostrar movimiento",
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
        ["Last known comparison"] = "Última comparación conocida", ["Source:"] = "Fuente:",
        ["Stats panel shown"] = "Panel de estadísticas mostrado", ["Stats panel hidden"] = "Panel de estadísticas oculto",
        ["Settings reset to defaults"] = "Configuración restablecida",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /statspro import, /ss debug, /ss help"] = "Comandos: /ss o /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "La configuración de SwiftStats no está cargada. Activa SwiftStats durante un inicio de sesión, ejecuta /reload y vuelve a usar /statspro import.",
        ["SwiftStats has no supported settings to import."] = "SwiftStats no tiene opciones compatibles para importar.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "Esta configuración usa un esquema más reciente y esta versión de StatsPro no puede importarla.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "La configuración es de solo lectura porque se guardó con una versión más reciente de StatsPro. Actualiza StatsPro para modificarla.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "La importación de SwiftStats no está disponible en combate. Inténtalo de nuevo al terminar.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "¿Importar los ajustes compatibles de SwiftStats en un perfil nuevo para el personaje y la especialización actuales? Los perfiles existentes, las demás asignaciones, los ajustes de la cuenta y los datos de SwiftStats no cambiarán.",
        ["Import"] = "Importar",
        ["SwiftStats settings imported into new profile \"%s\"."] = "Los ajustes de SwiftStats se importaron al nuevo perfil «%s».",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "La importación de SwiftStats falló; se conservaron los perfiles y las asignaciones.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "¿Restablecer todos los datos de StatsPro? Esto eliminará permanentemente todos los perfiles, las asignaciones de personajes y especializaciones, las plantillas de rol, los ajustes de la cuenta y las posiciones guardadas. Los datos de SwiftStats no cambiarán.",
        ["All StatsPro data reset to defaults."] = "Todos los datos de StatsPro se restablecieron a los valores predeterminados.",
        ["Reset to Defaults"] = "Restablecer", ["Close"] = "Cerrar",
        ["Open Settings"] = "Abrir configuración", ["Settings"] = "Configuración",
        ["Profile:"] = "Perfil:", ["Manage"] = "Administrar", ["Profile Manager"] = "Administrador de perfiles",
        ["Automatic - %s / %s"] = "Automático – %s / %s", ["Shared by %d specs"] = "Compartido por %d especializaciones",
        ["Switch pending until combat ends"] = "Cambio al terminar el combate", ["Account default profile"] = "Perfil predeterminado de la cuenta",
        ["Current"] = "Actual", ["Active"] = "Activo", ["Character default"] = "Predeterminado del personaje",
        ["Assigned profile:"] = "Perfil asignado:", ["Independent"] = "Independiente", ["No visited characters"] = "No hay personajes visitados",
        ["Spec %d"] = "Especialización %d", ["Profile changes are unavailable during combat."] = "Los cambios de perfil no están disponibles en combate.",
        ["Waiting for a safe profile context."] = "Esperando un contexto de perfil seguro.",
        ["Compatibility mode - profiles are read-only."] = "Modo de compatibilidad: los perfiles son de solo lectura.",
        ["Profile to manage:"] = "Perfil que administrar:", ["Choose a profile"] = "Elige un perfil",
        ["All settings"] = "Todos los ajustes", ["Stat and gear settings"] = "Estadísticas y equipo", ["Layout settings"] = "Diseño", ["Appearance settings"] = "Apariencia", ["Choose settings to copy"] = "Elige los ajustes que copiar",
        ["Copy %s from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "¿Copiar «%s» de «%s» a «%s»? Esto cambia %d especializaciones asignadas y %d referencias más.",
        ["Assign to selected context"] = "Asignar al contexto seleccionado", ["New from defaults..."] = "Nuevo desde valores predeterminados...",
        ["Duplicate profile..."] = "Duplicar perfil...", ["Rename profile..."] = "Cambiar nombre del perfil...",
        ["Copy settings to assigned profile..."] = "Copiar ajustes al perfil asignado...", ["Swap assignments..."] = "Intercambiar asignaciones...",
        ["Reset active profile..."] = "Restablecer perfil activo...", ["Delete profile..."] = "Eliminar perfil...",
        ["Forget character..."] = "Olvidar personaje...", ["Confirm"] = "Confirmar",
        ["Selected character"] = "Personaje seleccionado", ["%s - %d known specs"] = "%s – %d especializaciones conocidas",
        ["Future new contexts"] = "Nuevos contextos futuros", ["Tank: %s"] = "Tanque: %s",
        ["Healer: %s"] = "Sanador: %s", ["Damage: %s"] = "Daño: %s",
        ["Tank"] = "Tanque", ["Healer"] = "Sanador", ["Damage"] = "Daño",
        ["Use profile for all known specs..."] = "Usar en todas las especializaciones conocidas...",
        ["Make shared specs independent..."] = "Independizar especializaciones compartidas...",
        ["Set future role template..."] = "Definir plantilla de rol futura...", ["Choose a role"] = "Elige un rol",
        ["Use \"%s\" for all %d known specs of \"%s\"? Existing profiles and settings will be kept."] = "¿Usar «%s» para las %d especializaciones conocidas de «%s»? Se conservarán los perfiles y ajustes existentes.",
        ["Make %d shared specs of \"%s\" independent? Each affected spec receives a separate copy; existing profiles stay unchanged."] = "¿Independizar %d especializaciones compartidas de «%s»? Cada una recibirá una copia distinta; los perfiles existentes no cambiarán.",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "¿Usar «%s» como origen para futuros contextos de Tanque? Las asignaciones existentes no cambiarán; cada contexto nuevo recibirá una copia independiente.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "¿Usar «%s» como origen para futuros contextos de Sanador? Las asignaciones existentes no cambiarán; cada contexto nuevo recibirá una copia independiente.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "¿Usar «%s» como origen para futuros contextos de Daño? Las asignaciones existentes no cambiarán; cada contexto nuevo recibirá una copia independiente.",
        ["Unused"] = "Sin usar", ["Unused profile"] = "Perfil sin usar", ["New Profile"] = "Perfil nuevo",
        ["%s Copy"] = "Copia de %s", ["Choose a replacement profile"] = "Elige un perfil de reemplazo",
        ["Choose a context"] = "Elige un contexto", ["%d assigned specs, %d other references"] = "%d especializaciones asignadas, %d referencias más",
        ["Profile changes saved."] = "Cambios de perfiles guardados.", ["Enter a valid profile name."] = "Ingresa un nombre de perfil válido.",
        ["Profile names can contain at most %d characters."] = "Los nombres de perfil pueden tener un máximo de %d caracteres.",
        ["A profile with this name already exists."] = "Ya existe un perfil con este nombre.",
        ["Profiles changed; review and try again."] = "Los perfiles cambiaron. Revisa la selección e inténtalo de nuevo.",
        ["The last profile cannot be deleted."] = "No se puede eliminar el último perfil.",
        ["Choose a replacement profile."] = "Elige un perfil de reemplazo.",
        ["The current character cannot be forgotten."] = "No se puede olvidar al personaje actual.",
        ["Nothing changed."] = "No se cambió nada.",
        ["Profile operation failed. Review the selection and try again."] = "La operación del perfil falló. Revisa la selección e inténtalo de nuevo.",
        ["Delete profile \"%s\" and replace all references with \"%s\"? This affects %d assigned specs and %d other references."] = "¿Eliminar el perfil «%s» y reemplazar todas las referencias por «%s»? Esto afecta a %d especializaciones asignadas y %d referencias más.",
        ["Swap \"%s\" and \"%s\"? Their profile settings stay unchanged."] = "¿Intercambiar «%s» y «%s»? Sus ajustes de perfil no cambiarán.",
        ["Rename shared profile \"%s\" to \"%s\"? This affects %d assigned specs and %d other references."] = "¿Cambiar el nombre del perfil compartido «%s» a «%s»? Esto afecta a %d especializaciones asignadas y %d referencias más.",
        ["Copy settings from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "¿Copiar los ajustes de «%s» a «%s»? Esto cambia %d especializaciones asignadas y %d referencias más.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "¿Restablecer el perfil activo «%s»? Esto cambia %d especializaciones asignadas y %d referencias más.",
        ["Delete unused profile \"%s\"?"] = "¿Eliminar el perfil sin usar «%s»?",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "¿Olvidar a «%s»? Se eliminará su registro de personaje, pero se conservarán los ajustes de perfiles.",
        ["Auto (current: %s)"] = "Auto (actual: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r La fuente puede no mostrar glifos %s. Elige una fuente SharedMedia con cobertura.",
        ["Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window."] = "HUD de estadísticas y equipo: nivel de objeto, durabilidad, costo de reparación y objetivos de estadísticas de Archon. Da clic abajo para abrir la ventana de configuración.",
    },

    -- itIT: Italian. Cele (Celerità) / Mov (Movimento) Haste/Movement split. Para
    -- (Parata) at 4 chars reads more naturally than "Par"; Armat (Armatura) gives
    -- enough char-count to feel like a word; Forz / Agil keep 4-char rhythm. Ag
    -- (2 chars) was clearly too short — Italian readers wouldn't recognize it.
    itIT = {
        Crit = "Crit",          Haste = "Cele",         Mastery = "Maest",      Vers = "Vers",
        Dodge = "Schiv",        Parry = "Para",         Block = "Bloc",         Armor = "Armat",        Stagger = "Barc",
        Strength = "Forz",      Agility = "Agil",       Intellect = "Int",      Stamina = "Cost",
        ItemLevel = "LivOg",
        Leech = "Vamp",         Avoidance = "Evit",     Speed = "Mov",
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
        ["Appearance Presets"] = "Preimpostazioni aspetto", ["Preset:"] = "Preimpostazione:",
        ["Classic"] = "Classico", ["Clean Dark"] = "Scuro pulito", ["Midnight"] = "Mezzanotte",
        ["Monochrome"] = "Monocromatico", ["High Contrast"] = "Alto contrasto", ["Custom"] = "Personalizzato",
        ["Previewing: %s"] = "Anteprima: %s", ["Apply"] = "Applica", ["Cancel preview"] = "Annulla anteprima",
        ["Presets change font size, opacity, outline, panel background, HUD colors, and color behavior. They keep font face, layout, visible stats, scale, language, and refresh rate."] = "Le preimpostazioni cambiano dimensione, opacità, contorno, sfondo, colori HUD e comportamento colore. Mantengono carattere, layout, statistiche visibili, scala, lingua e frequenza.",
        ["This profile is shared by %d specs and %d other references. Applying changes all of them."] = "Questo profilo è condiviso da %d specializzazioni e %d altri riferimenti. L'applicazione li modifica tutti.",
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
        ["Requires %s."] = "Richiede %s.",
        ["Show Crit"] = "Mostra Crit", ["Show Haste"] = "Mostra Celerità",
        ["Show Mastery"] = "Mostra Maestria", ["Show Versatility"] = "Mostra Versatilità",
        ["Show Tertiary Stats"] = "Mostra terziarie",
        ["Show Leech"] = "Mostra Vampirismo", ["Show Avoidance"] = "Mostra Evitazione", ["Show Speed"] = "Mostra movimento",
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
        ["Last known comparison"] = "Ultimo confronto noto", ["Source:"] = "Fonte:",
        ["Stats panel shown"] = "Pannello statistiche mostrato", ["Stats panel hidden"] = "Pannello statistiche nascosto",
        ["Settings reset to defaults"] = "Impostazioni ripristinate",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /statspro import, /ss debug, /ss help"] = "Comandi: /ss o /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "Le impostazioni di SwiftStats non sono caricate. Abilita SwiftStats per un accesso, esegui /reload, quindi usa di nuovo /statspro import.",
        ["SwiftStats has no supported settings to import."] = "SwiftStats non contiene impostazioni supportate da importare.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "Queste impostazioni usano uno schema più recente e non possono essere importate da questa versione di StatsPro.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "Le impostazioni sono in sola lettura perché sono state salvate da una versione più recente di StatsPro. Aggiorna StatsPro per modificarle.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "L’importazione di SwiftStats non è disponibile in combattimento. Riprova al termine.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "Importare le impostazioni SwiftStats compatibili in un nuovo profilo per il personaggio e la specializzazione attuali? I profili esistenti, le altre assegnazioni, le impostazioni dell’account e i dati SwiftStats resteranno invariati.",
        ["Import"] = "Importa",
        ["SwiftStats settings imported into new profile \"%s\"."] = "Impostazioni SwiftStats importate nel nuovo profilo «%s».",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "Importazione di SwiftStats non riuscita; profili e assegnazioni sono stati conservati.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "Ripristinare tutti i dati di StatsPro? Verranno rimossi definitivamente tutti i profili, le assegnazioni di personaggi e specializzazioni, i modelli di ruolo, le impostazioni dell’account e le posizioni salvate. I dati SwiftStats resteranno invariati.",
        ["All StatsPro data reset to defaults."] = "Tutti i dati di StatsPro sono stati ripristinati ai valori predefiniti.",
        ["Reset to Defaults"] = "Predefiniti", ["Close"] = "Chiudi",
        ["Open Settings"] = "Apri impostazioni", ["Settings"] = "Impostazioni",
        ["Profile:"] = "Profilo:", ["Manage"] = "Gestisci", ["Profile Manager"] = "Gestione profili",
        ["Automatic - %s / %s"] = "Automatico – %s / %s", ["Shared by %d specs"] = "Condiviso da %d specializzazioni",
        ["Switch pending until combat ends"] = "Cambio dopo il combattimento", ["Account default profile"] = "Profilo account predefinito",
        ["Current"] = "Attuale", ["Active"] = "Attivo", ["Character default"] = "Predefinito del personaggio",
        ["Assigned profile:"] = "Profilo assegnato:", ["Independent"] = "Indipendente", ["No visited characters"] = "Nessun personaggio visitato",
        ["Spec %d"] = "Specializzazione %d", ["Profile changes are unavailable during combat."] = "Le modifiche ai profili non sono disponibili in combattimento.",
        ["Waiting for a safe profile context."] = "In attesa di un contesto profilo sicuro.",
        ["Compatibility mode - profiles are read-only."] = "Modalità compatibilità – i profili sono in sola lettura.",
        ["Profile to manage:"] = "Profilo da gestire:", ["Choose a profile"] = "Scegli un profilo",
        ["All settings"] = "Tutte le impostazioni", ["Stat and gear settings"] = "Statistiche ed equipaggiamento", ["Layout settings"] = "Disposizione", ["Appearance settings"] = "Aspetto", ["Choose settings to copy"] = "Scegli le impostazioni da copiare",
        ["Copy %s from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "Copiare «%s» da «%s» a «%s»? Verranno modificate %d specializzazioni assegnate e %d altri riferimenti.",
        ["Assign to selected context"] = "Assegna al contesto selezionato", ["New from defaults..."] = "Nuovo dai valori predefiniti...",
        ["Duplicate profile..."] = "Duplica profilo...", ["Rename profile..."] = "Rinomina profilo...",
        ["Copy settings to assigned profile..."] = "Copia impostazioni nel profilo assegnato...", ["Swap assignments..."] = "Scambia assegnazioni...",
        ["Reset active profile..."] = "Ripristina profilo attivo...", ["Delete profile..."] = "Elimina profilo...",
        ["Forget character..."] = "Dimentica personaggio...", ["Confirm"] = "Conferma",
        ["Selected character"] = "Personaggio selezionato", ["%s - %d known specs"] = "%s – %d specializzazioni note",
        ["Future new contexts"] = "Nuovi contesti futuri", ["Tank: %s"] = "Difensore: %s",
        ["Healer: %s"] = "Guaritore: %s", ["Damage: %s"] = "Assaltatore: %s",
        ["Tank"] = "Difensore", ["Healer"] = "Guaritore", ["Damage"] = "Assaltatore",
        ["Use profile for all known specs..."] = "Usa per tutte le specializzazioni note...",
        ["Make shared specs independent..."] = "Rendi indipendenti le specializzazioni condivise...",
        ["Set future role template..."] = "Imposta modello ruolo futuro...", ["Choose a role"] = "Scegli un ruolo",
        ["Use \"%s\" for all %d known specs of \"%s\"? Existing profiles and settings will be kept."] = "Usare «%s» per tutte le %d specializzazioni note di «%s»? I profili e le impostazioni esistenti verranno conservati.",
        ["Make %d shared specs of \"%s\" independent? Each affected spec receives a separate copy; existing profiles stay unchanged."] = "Rendere indipendenti %d specializzazioni condivise di «%s»? Ognuna riceverà una copia separata; i profili esistenti resteranno invariati.",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "Usare «%s» come origine per i futuri contesti Difensore? Le assegnazioni esistenti non cambieranno; ogni nuovo contesto riceverà una copia indipendente.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "Usare «%s» come origine per i futuri contesti Guaritore? Le assegnazioni esistenti non cambieranno; ogni nuovo contesto riceverà una copia indipendente.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "Usare «%s» come origine per i futuri contesti Assaltatore? Le assegnazioni esistenti non cambieranno; ogni nuovo contesto riceverà una copia indipendente.",
        ["Unused"] = "Inutilizzato", ["Unused profile"] = "Profilo inutilizzato", ["New Profile"] = "Nuovo profilo",
        ["%s Copy"] = "Copia di %s", ["Choose a replacement profile"] = "Scegli un profilo sostitutivo",
        ["Choose a context"] = "Scegli un contesto", ["%d assigned specs, %d other references"] = "%d specializzazioni assegnate, %d altri riferimenti",
        ["Profile changes saved."] = "Modifiche ai profili salvate.", ["Enter a valid profile name."] = "Inserisci un nome profilo valido.",
        ["Profile names can contain at most %d characters."] = "I nomi dei profili possono contenere al massimo %d caratteri.",
        ["A profile with this name already exists."] = "Esiste già un profilo con questo nome.",
        ["Profiles changed; review and try again."] = "I profili sono cambiati. Controlla la selezione e riprova.",
        ["The last profile cannot be deleted."] = "L'ultimo profilo non può essere eliminato.",
        ["Choose a replacement profile."] = "Scegli un profilo sostitutivo.",
        ["The current character cannot be forgotten."] = "Il personaggio attuale non può essere dimenticato.",
        ["Nothing changed."] = "Nessuna modifica.",
        ["Profile operation failed. Review the selection and try again."] = "Operazione sul profilo non riuscita. Controlla la selezione e riprova.",
        ["Delete profile \"%s\" and replace all references with \"%s\"? This affects %d assigned specs and %d other references."] = "Eliminare il profilo «%s» e sostituire tutti i riferimenti con «%s»? Verranno coinvolte %d specializzazioni assegnate e %d altri riferimenti.",
        ["Swap \"%s\" and \"%s\"? Their profile settings stay unchanged."] = "Scambiare «%s» e «%s»? Le impostazioni dei profili resteranno invariate.",
        ["Rename shared profile \"%s\" to \"%s\"? This affects %d assigned specs and %d other references."] = "Rinominare il profilo condiviso «%s» in «%s»? Verranno coinvolte %d specializzazioni assegnate e %d altri riferimenti.",
        ["Copy settings from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "Copiare le impostazioni da «%s» a «%s»? Verranno modificate %d specializzazioni assegnate e %d altri riferimenti.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "Ripristinare il profilo attivo «%s»? Verranno modificate %d specializzazioni assegnate e %d altri riferimenti.",
        ["Delete unused profile \"%s\"?"] = "Eliminare il profilo inutilizzato «%s»?",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "Dimenticare «%s»? Il record del personaggio verrà rimosso, ma le impostazioni dei profili saranno conservate.",
        ["Auto (current: %s)"] = "Auto (attuale: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r Il font potrebbe non visualizzare i glifi %s. Scegli un font SharedMedia con copertura adeguata.",
        ["Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window."] = "HUD di statistiche ed equipaggiamento: livello oggetto, durabilità, costo di riparazione e obiettivi statistiche Archon. Clicca sotto per aprire le impostazioni complete.",
    },

    -- ptBR: Brazilian Portuguese. Cele (Celeridade) / Mov (Movimento). Forç (with
    -- cedilla, Força) and Agil at 4 chars match Portuguese's prosody better than the
    -- 3-char truncations. Esqu (Esquiva) likewise.
    ptBR = {
        Crit = "Crít",          Haste = "Cele",         Mastery = "Maest",      Vers = "Vers",
        Dodge = "Esqu",         Parry = "Par",          Block = "Bloq",         Armor = "Arm",          Stagger = "Camb",
        Strength = "Forç",      Agility = "Agil",       Intellect = "Int",      Stamina = "Vig",
        ItemLevel = "NvItem",
        Leech = "Vamp",         Avoidance = "Evit",     Speed = "Mov",
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
        ["Appearance Presets"] = "Predefinições de aparência", ["Preset:"] = "Predefinição:",
        ["Classic"] = "Clássico", ["Clean Dark"] = "Escuro limpo", ["Midnight"] = "Meia-noite",
        ["Monochrome"] = "Monocromático", ["High Contrast"] = "Alto contraste", ["Custom"] = "Personalizado",
        ["Previewing: %s"] = "Prévia: %s", ["Apply"] = "Aplicar", ["Cancel preview"] = "Cancelar prévia",
        ["Presets change font size, opacity, outline, panel background, HUD colors, and color behavior. They keep font face, layout, visible stats, scale, language, and refresh rate."] = "As predefinições alteram tamanho, opacidade, contorno, fundo, cores do HUD e comportamento das cores. Mantêm fonte, layout, atributos visíveis, escala, idioma e atualização.",
        ["This profile is shared by %d specs and %d other references. Applying changes all of them."] = "Este perfil é compartilhado por %d especializações e %d outras referências. Aplicar altera todas.",
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
        ["Requires %s."] = "Requer %s.",
        ["Show Crit"] = "Mostrar Crít.", ["Show Haste"] = "Mostrar Celeridade",
        ["Show Mastery"] = "Mostrar Maestria", ["Show Versatility"] = "Mostrar Versatilidade",
        ["Show Tertiary Stats"] = "Mostrar terciários",
        ["Show Leech"] = "Mostrar Vampirismo", ["Show Avoidance"] = "Mostrar Evasão", ["Show Speed"] = "Mostrar movimento",
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
        ["Last known comparison"] = "Última comparação conhecida", ["Source:"] = "Fonte:",
        ["Stats panel shown"] = "Painel de atributos mostrado", ["Stats panel hidden"] = "Painel de atributos oculto",
        ["Settings reset to defaults"] = "Configurações restauradas",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /statspro import, /ss debug, /ss help"] = "Comandos: /ss ou /statspro (configurações), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "As configurações do SwiftStats não estão carregadas. Ative o SwiftStats por um login, execute /reload e use /statspro import novamente.",
        ["SwiftStats has no supported settings to import."] = "O SwiftStats não tem configurações compatíveis para importar.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "Estas configurações usam um esquema mais recente e não podem ser importadas por esta versão do StatsPro.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "As configurações estão somente para leitura porque foram salvas por uma versão mais recente do StatsPro. Atualize o StatsPro para alterá-las.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "A importação do SwiftStats não está disponível em combate. Tente novamente depois.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "Importar as configurações compatíveis do SwiftStats para um novo perfil do personagem e da especialização atuais? Os perfis existentes, as outras atribuições, as configurações da conta e os dados do SwiftStats permanecerão inalterados.",
        ["Import"] = "Importar",
        ["SwiftStats settings imported into new profile \"%s\"."] = "Configurações do SwiftStats importadas para o novo perfil “%s”.",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "Falha ao importar o SwiftStats; os perfis e as atribuições foram preservados.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "Redefinir todos os dados do StatsPro? Isso removerá permanentemente todos os perfis, as atribuições de personagens e especializações, os modelos de função, as configurações da conta e as posições salvas. Os dados do SwiftStats permanecerão inalterados.",
        ["All StatsPro data reset to defaults."] = "Todos os dados do StatsPro foram redefinidos para os padrões.",
        ["Reset to Defaults"] = "Restaurar", ["Close"] = "Fechar",
        ["Open Settings"] = "Abrir configurações", ["Settings"] = "Configurações",
        ["Profile:"] = "Perfil:", ["Manage"] = "Gerenciar", ["Profile Manager"] = "Gerenciador de perfis",
        ["Automatic - %s / %s"] = "Automático – %s / %s", ["Shared by %d specs"] = "Compartilhado por %d especializações",
        ["Switch pending until combat ends"] = "Troca após o combate", ["Account default profile"] = "Perfil padrão da conta",
        ["Current"] = "Atual", ["Active"] = "Ativo", ["Character default"] = "Padrão do personagem",
        ["Assigned profile:"] = "Perfil atribuído:", ["Independent"] = "Independente", ["No visited characters"] = "Nenhum personagem visitado",
        ["Spec %d"] = "Especialização %d", ["Profile changes are unavailable during combat."] = "Alterações de perfil não estão disponíveis em combate.",
        ["Waiting for a safe profile context."] = "Aguardando um contexto de perfil seguro.",
        ["Compatibility mode - profiles are read-only."] = "Modo de compatibilidade – os perfis são somente leitura.",
        ["Profile to manage:"] = "Perfil para gerenciar:", ["Choose a profile"] = "Escolha um perfil",
        ["All settings"] = "Todas as configurações", ["Stat and gear settings"] = "Atributos e equipamento", ["Layout settings"] = "Layout", ["Appearance settings"] = "Aparência", ["Choose settings to copy"] = "Escolha as configurações para copiar",
        ["Copy %s from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "Copiar “%s” de “%s” para “%s”? Isso altera %d especializações atribuídas e %d outras referências.",
        ["Assign to selected context"] = "Atribuir ao contexto selecionado", ["New from defaults..."] = "Novo a partir dos padrões...",
        ["Duplicate profile..."] = "Duplicar perfil...", ["Rename profile..."] = "Renomear perfil...",
        ["Copy settings to assigned profile..."] = "Copiar configurações para o perfil atribuído...", ["Swap assignments..."] = "Trocar atribuições...",
        ["Reset active profile..."] = "Redefinir perfil ativo...", ["Delete profile..."] = "Excluir perfil...",
        ["Forget character..."] = "Esquecer personagem...", ["Confirm"] = "Confirmar",
        ["Selected character"] = "Personagem selecionado", ["%s - %d known specs"] = "%s – %d especializações conhecidas",
        ["Future new contexts"] = "Novos contextos futuros", ["Tank: %s"] = "Tanque: %s",
        ["Healer: %s"] = "Cura: %s", ["Damage: %s"] = "Dano: %s",
        ["Tank"] = "Tanque", ["Healer"] = "Cura", ["Damage"] = "Dano",
        ["Use profile for all known specs..."] = "Usar em todas as especializações conhecidas...",
        ["Make shared specs independent..."] = "Tornar especializações compartilhadas independentes...",
        ["Set future role template..."] = "Definir modelo de função futura...", ["Choose a role"] = "Escolha uma função",
        ["Use \"%s\" for all %d known specs of \"%s\"? Existing profiles and settings will be kept."] = "Usar «%s» em todas as %d especializações conhecidas de «%s»? Os perfis e ajustes existentes serão mantidos.",
        ["Make %d shared specs of \"%s\" independent? Each affected spec receives a separate copy; existing profiles stay unchanged."] = "Tornar independentes %d especializações compartilhadas de «%s»? Cada uma receberá uma cópia separada; os perfis existentes permanecerão inalterados.",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "Usar «%s» como origem para futuros contextos de Tanque? As atribuições existentes não mudarão; cada novo contexto receberá uma cópia independente.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "Usar «%s» como origem para futuros contextos de Cura? As atribuições existentes não mudarão; cada novo contexto receberá uma cópia independente.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "Usar «%s» como origem para futuros contextos de Dano? As atribuições existentes não mudarão; cada novo contexto receberá uma cópia independente.",
        ["Unused"] = "Não usado", ["Unused profile"] = "Perfil não usado", ["New Profile"] = "Novo perfil",
        ["%s Copy"] = "Cópia de %s", ["Choose a replacement profile"] = "Escolha um perfil substituto",
        ["Choose a context"] = "Escolha um contexto", ["%d assigned specs, %d other references"] = "%d especializações atribuídas, %d outras referências",
        ["Profile changes saved."] = "Alterações de perfil salvas.", ["Enter a valid profile name."] = "Digite um nome de perfil válido.",
        ["Profile names can contain at most %d characters."] = "Os nomes de perfil podem ter no máximo %d caracteres.",
        ["A profile with this name already exists."] = "Já existe um perfil com este nome.",
        ["Profiles changed; review and try again."] = "Os perfis mudaram. Revise a seleção e tente novamente.",
        ["The last profile cannot be deleted."] = "O último perfil não pode ser excluído.",
        ["Choose a replacement profile."] = "Escolha um perfil substituto.",
        ["The current character cannot be forgotten."] = "O personagem atual não pode ser esquecido.",
        ["Nothing changed."] = "Nada foi alterado.",
        ["Profile operation failed. Review the selection and try again."] = "A operação do perfil falhou. Revise a seleção e tente novamente.",
        ["Delete profile \"%s\" and replace all references with \"%s\"? This affects %d assigned specs and %d other references."] = "Excluir o perfil “%s” e substituir todas as referências por “%s”? Isso afeta %d especializações atribuídas e %d outras referências.",
        ["Swap \"%s\" and \"%s\"? Their profile settings stay unchanged."] = "Trocar “%s” e “%s”? As configurações dos perfis permanecerão inalteradas.",
        ["Rename shared profile \"%s\" to \"%s\"? This affects %d assigned specs and %d other references."] = "Renomear o perfil compartilhado “%s” para “%s”? Isso afeta %d especializações atribuídas e %d outras referências.",
        ["Copy settings from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "Copiar configurações de “%s” para “%s”? Isso altera %d especializações atribuídas e %d outras referências.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "Redefinir o perfil ativo “%s” para os padrões? Isso altera %d especializações atribuídas e %d outras referências.",
        ["Delete unused profile \"%s\"?"] = "Excluir o perfil não usado “%s”?",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "Esquecer “%s”? O registro do personagem será removido, mas as configurações dos perfis serão mantidas.",
        ["Auto (current: %s)"] = "Auto (atual: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r A fonte pode não exibir glifos %s. Escolha uma fonte SharedMedia com cobertura.",
        ["Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window."] = "HUD de atributos e equipamento: nível de item, durabilidade, custo de reparo e metas de atributos do Archon. Clique abaixo para abrir a janela de configurações.",
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
        Leech = "흡혈",         Avoidance = "광피",     Speed = "이동",
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
        ["Appearance Presets"] = "외형 프리셋", ["Preset:"] = "프리셋:",
        ["Classic"] = "클래식", ["Clean Dark"] = "깔끔한 어둠", ["Midnight"] = "한밤",
        ["Monochrome"] = "단색", ["High Contrast"] = "고대비", ["Custom"] = "사용자 지정",
        ["Previewing: %s"] = "미리 보기: %s", ["Apply"] = "적용", ["Cancel preview"] = "미리 보기 취소",
        ["Presets change font size, opacity, outline, panel background, HUD colors, and color behavior. They keep font face, layout, visible stats, scale, language, and refresh rate."] = "프리셋은 글꼴 크기, 투명도, 외곽선, 배경, HUD 색상과 색상 동작을 변경합니다. 글꼴 종류, 배치, 표시 능력치, 크기, 언어와 갱신 주기는 유지합니다.",
        ["This profile is shared by %d specs and %d other references. Applying changes all of them."] = "이 프로필은 %d개 전문화와 기타 %d개 참조가 공유합니다. 적용하면 모두 변경됩니다.",
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
        ["Requires %s."] = "%s 필요.",
        ["Show Crit"] = "치명 표시", ["Show Haste"] = "가속 표시",
        ["Show Mastery"] = "특화 표시", ["Show Versatility"] = "유연 표시",
        ["Show Tertiary Stats"] = "3차 능력치 표시",
        ["Show Leech"] = "흡혈 표시", ["Show Avoidance"] = "광피 표시", ["Show Speed"] = "이동 속도 표시",
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
        ["Last known comparison"] = "마지막으로 확인된 비교", ["Source:"] = "출처:",
        ["Stats panel shown"] = "능력치 패널 표시됨", ["Stats panel hidden"] = "능력치 패널 숨김",
        ["Settings reset to defaults"] = "설정이 기본값으로 초기화되었습니다",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /statspro import, /ss debug, /ss help"] = "명령어: /ss 또는 /statspro (설정), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "SwiftStats 설정이 로드되지 않았습니다. 한 번 로그인하는 동안 SwiftStats를 활성화하고 /reload 후 /statspro import를 다시 실행하세요.",
        ["SwiftStats has no supported settings to import."] = "SwiftStats에 가져올 수 있는 지원 설정이 없습니다.",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "이 설정은 더 새로운 스키마를 사용하므로 현재 StatsPro 버전에서 가져올 수 없습니다.",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "더 최신 StatsPro 버전에서 저장한 설정이므로 읽기 전용입니다. 설정을 변경하려면 StatsPro를 업데이트하세요.",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "전투 중에는 SwiftStats 설정을 가져올 수 없습니다. 전투 후 다시 시도하세요.",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "현재 캐릭터와 전문화용 새 프로필로 호환되는 SwiftStats 설정을 가져오시겠습니까? 기존 프로필, 다른 할당, 계정 설정 및 SwiftStats 데이터는 변경되지 않습니다.",
        ["Import"] = "가져오기",
        ["SwiftStats settings imported into new profile \"%s\"."] = "SwiftStats 설정을 새 프로필 \"%s\"에 가져왔습니다.",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "SwiftStats 설정 가져오기에 실패했습니다. 프로필과 할당은 유지되었습니다.",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "모든 StatsPro 데이터를 초기화하시겠습니까? 모든 프로필, 캐릭터 및 전문화 할당, 역할 템플릿, 계정 설정, 저장된 위치가 영구적으로 삭제됩니다. SwiftStats 데이터는 변경되지 않습니다.",
        ["All StatsPro data reset to defaults."] = "모든 StatsPro 데이터를 기본값으로 초기화했습니다.",
        ["Reset to Defaults"] = "기본값", ["Close"] = "닫기",
        ["Open Settings"] = "설정 열기", ["Settings"] = "설정",
        ["Profile:"] = "프로필:", ["Manage"] = "관리", ["Profile Manager"] = "프로필 관리",
        ["Automatic - %s / %s"] = "자동 – %s / %s", ["Shared by %d specs"] = "전문화 %d개에서 공유",
        ["Switch pending until combat ends"] = "전투 종료 후 전환", ["Account default profile"] = "계정 기본 프로필",
        ["Current"] = "현재", ["Active"] = "활성", ["Character default"] = "캐릭터 기본값",
        ["Assigned profile:"] = "지정된 프로필:", ["Independent"] = "독립", ["No visited characters"] = "방문한 캐릭터 없음",
        ["Spec %d"] = "전문화 %d", ["Profile changes are unavailable during combat."] = "전투 중에는 프로필을 변경할 수 없습니다.",
        ["Waiting for a safe profile context."] = "안전한 프로필 상태를 기다리는 중입니다.",
        ["Compatibility mode - profiles are read-only."] = "호환 모드 – 프로필이 읽기 전용입니다.",
        ["Profile to manage:"] = "관리할 프로필:", ["Choose a profile"] = "프로필 선택",
        ["All settings"] = "모든 설정", ["Stat and gear settings"] = "능력치 및 장비 설정", ["Layout settings"] = "배치 설정", ["Appearance settings"] = "외형 설정", ["Choose settings to copy"] = "복사할 설정 선택",
        ["Copy %s from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "\"%s\"을(를) \"%s\"에서 \"%s\"(으)로 복사하시겠습니까? 할당된 전문화 %d개와 기타 참조 %d개가 변경됩니다.",
        ["Assign to selected context"] = "선택한 항목에 할당", ["New from defaults..."] = "기본값으로 새로 만들기...",
        ["Duplicate profile..."] = "프로필 복제...", ["Rename profile..."] = "프로필 이름 변경...",
        ["Copy settings to assigned profile..."] = "할당된 프로필에 설정 복사...", ["Swap assignments..."] = "할당 교환...",
        ["Reset active profile..."] = "활성 프로필 초기화...", ["Delete profile..."] = "프로필 삭제...",
        ["Forget character..."] = "캐릭터 기록 삭제...", ["Confirm"] = "확인",
        ["Selected character"] = "선택한 캐릭터", ["%s - %d known specs"] = "%s – 알려진 전문화 %d개",
        ["Future new contexts"] = "향후 새 컨텍스트", ["Tank: %s"] = "방어 전담: %s",
        ["Healer: %s"] = "치유 전담: %s", ["Damage: %s"] = "공격 전담: %s",
        ["Tank"] = "방어 전담", ["Healer"] = "치유 전담", ["Damage"] = "공격 전담",
        ["Use profile for all known specs..."] = "알려진 모든 전문화에 프로필 사용...",
        ["Make shared specs independent..."] = "공유 전문화를 독립 프로필로 분리...",
        ["Set future role template..."] = "향후 역할 템플릿 설정...", ["Choose a role"] = "역할 선택",
        ["Use \"%s\" for all %d known specs of \"%s\"? Existing profiles and settings will be kept."] = "%s 프로필을 알려진 전문화 %d개 모두에 적용하시겠습니까? 대상 캐릭터: %s. 기존 프로필과 설정은 유지됩니다.",
        ["Make %d shared specs of \"%s\" independent? Each affected spec receives a separate copy; existing profiles stay unchanged."] = "%d개의 공유 전문화를 ‘%s’에서 독립시키시겠습니까? 각 전문화에 별도 복사본이 생성되며 기존 프로필은 변경되지 않습니다.",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "%s 프로필을 향후 방어 전담 컨텍스트의 원본으로 사용하시겠습니까? 기존 할당은 바뀌지 않으며 새 컨텍스트마다 독립 복사본이 생성됩니다.",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "%s 프로필을 향후 치유 전담 컨텍스트의 원본으로 사용하시겠습니까? 기존 할당은 바뀌지 않으며 새 컨텍스트마다 독립 복사본이 생성됩니다.",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "%s 프로필을 향후 공격 전담 컨텍스트의 원본으로 사용하시겠습니까? 기존 할당은 바뀌지 않으며 새 컨텍스트마다 독립 복사본이 생성됩니다.",
        ["Unused"] = "미사용", ["Unused profile"] = "사용하지 않는 프로필", ["New Profile"] = "새 프로필",
        ["%s Copy"] = "%s 복사본", ["Choose a replacement profile"] = "대체 프로필 선택",
        ["Choose a context"] = "항목 선택", ["%d assigned specs, %d other references"] = "할당된 전문화 %d개, 기타 참조 %d개",
        ["Profile changes saved."] = "프로필 변경 사항을 저장했습니다.", ["Enter a valid profile name."] = "올바른 프로필 이름을 입력하세요.",
        ["Profile names can contain at most %d characters."] = "프로필 이름은 최대 %d자까지 사용할 수 있습니다.",
        ["A profile with this name already exists."] = "같은 이름의 프로필이 이미 있습니다.",
        ["Profiles changed; review and try again."] = "프로필이 변경되었습니다. 선택을 확인하고 다시 시도하세요.",
        ["The last profile cannot be deleted."] = "마지막 프로필은 삭제할 수 없습니다.",
        ["Choose a replacement profile."] = "대체 프로필을 선택하세요.",
        ["The current character cannot be forgotten."] = "현재 캐릭터의 기록은 삭제할 수 없습니다.",
        ["Nothing changed."] = "변경된 내용이 없습니다.",
        ["Profile operation failed. Review the selection and try again."] = "프로필 작업에 실패했습니다. 선택을 확인하고 다시 시도하세요.",
        ["Delete profile \"%s\" and replace all references with \"%s\"? This affects %d assigned specs and %d other references."] = "프로필 \"%s\"을(를) 삭제하고 모든 참조를 \"%s\"(으)로 바꾸시겠습니까? 할당된 전문화 %d개와 기타 참조 %d개에 영향을 줍니다.",
        ["Swap \"%s\" and \"%s\"? Their profile settings stay unchanged."] = "\"%s\"과(와) \"%s\"을(를) 교환하시겠습니까? 프로필 설정은 변경되지 않습니다.",
        ["Rename shared profile \"%s\" to \"%s\"? This affects %d assigned specs and %d other references."] = "공유 프로필 \"%s\"의 이름을 \"%s\"(으)로 바꾸시겠습니까? 할당된 전문화 %d개와 기타 참조 %d개에 영향을 줍니다.",
        ["Copy settings from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "\"%s\"의 설정을 \"%s\"에 복사하시겠습니까? 할당된 전문화 %d개와 기타 참조 %d개가 변경됩니다.",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "활성 프로필 \"%s\"을(를) 기본값으로 초기화하시겠습니까? 할당된 전문화 %d개와 기타 참조 %d개가 변경됩니다.",
        ["Delete unused profile \"%s\"?"] = "사용하지 않는 프로필 \"%s\"을(를) 삭제하시겠습니까?",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "\"%s\"의 기록을 삭제하시겠습니까? 캐릭터 기록만 제거되고 프로필 설정은 유지됩니다.",
        ["Auto (current: %s)"] = "자동 (현재: %s)",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r 이 글꼴은 %s 글리프를 표시하지 못할 수 있습니다. SharedMedia에서 적합한 글꼴을 선택하세요.",
        ["Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window."] = "능력치·장비 HUD: 아이템 레벨, 내구도, 수리 비용, Archon 능력치 목표. 아래를 눌러 전체 설정 창을 엽니다.",
    },

    -- zhCN: Simplified Chinese. All terms match the official WoW Chinese client
    -- terminology — 2-char widely used in CN WoW community for stat displays.
    -- 躲闪 (Dodge) vs 闪避 (Avoidance) is the standard zhCN split. High confidence.
    zhCN = {
        Crit = "暴击",          Haste = "急速",         Mastery = "精通",       Vers = "全能",
        Dodge = "躲闪",         Parry = "招架",         Block = "格挡",         Armor = "护甲",         Stagger = "醉拳",
        Strength = "力量",      Agility = "敏捷",       Intellect = "智力",      Stamina = "耐力",
        ItemLevel = "装等",
        Leech = "吸血",         Avoidance = "闪避",     Speed = "移动",
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
        ["Appearance Presets"] = "外观预设", ["Preset:"] = "预设：",
        ["Classic"] = "经典", ["Clean Dark"] = "简洁深色", ["Midnight"] = "午夜",
        ["Monochrome"] = "单色", ["High Contrast"] = "高对比度", ["Custom"] = "自定义",
        ["Previewing: %s"] = "正在预览：%s", ["Apply"] = "应用", ["Cancel preview"] = "取消预览",
        ["Presets change font size, opacity, outline, panel background, HUD colors, and color behavior. They keep font face, layout, visible stats, scale, language, and refresh rate."] = "预设会更改字号、透明度、描边、面板背景、HUD颜色和颜色行为。字体、布局、可见属性、缩放、语言和刷新频率保持不变。",
        ["This profile is shared by %d specs and %d other references. Applying changes all of them."] = "此配置由%d个专精和%d个其他引用共享。应用会更改全部引用。",
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
        ["Requires %s."] = "需要%s。",
        ["Show Crit"] = "显示暴击", ["Show Haste"] = "显示急速",
        ["Show Mastery"] = "显示精通", ["Show Versatility"] = "显示全能",
        ["Show Tertiary Stats"] = "显示三级属性",
        ["Show Leech"] = "显示吸血", ["Show Avoidance"] = "显示闪避", ["Show Speed"] = "显示移动速度",
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
        ["Last known comparison"] = "上次已知对比", ["Source:"] = "来源:",
        ["Stats panel shown"] = "属性面板已显示", ["Stats panel hidden"] = "属性面板已隐藏",
        ["Settings reset to defaults"] = "设置已恢复默认",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /statspro import, /ss debug, /ss help"] = "命令: /ss 或 /statspro (设置), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "未加载 SwiftStats 设置。请启用 SwiftStats 登录一次，执行 /reload，然后再次运行 /statspro import。",
        ["SwiftStats has no supported settings to import."] = "SwiftStats 中没有可导入的受支持设置。",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "这些设置使用较新的数据结构，当前版本的 StatsPro 无法导入。",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "这些设置由较新版本的 StatsPro 保存，因此当前为只读。请更新 StatsPro 后再进行修改。",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "战斗中无法导入 SwiftStats 设置。请在战斗结束后重试。",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "要将兼容的 SwiftStats 设置导入到当前角色和专精的新配置中吗？现有配置、其他分配、账号设置和 SwiftStats 数据均不会更改。",
        ["Import"] = "导入",
        ["SwiftStats settings imported into new profile \"%s\"."] = "SwiftStats 设置已导入新配置“%s”。",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "SwiftStats 导入失败；配置和分配已保留。",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "要重置所有 StatsPro 数据吗？这将永久删除所有配置、角色和专精分配、职责模板、账号设置及保存的位置。SwiftStats 数据不会更改。",
        ["All StatsPro data reset to defaults."] = "所有 StatsPro 数据已重置为默认值。",
        ["Reset to Defaults"] = "恢复默认", ["Close"] = "关闭",
        ["Open Settings"] = "打开设置", ["Settings"] = "设置",
        ["Profile:"] = "配置：", ["Manage"] = "管理", ["Profile Manager"] = "配置管理",
        ["Automatic - %s / %s"] = "自动 – %s / %s", ["Shared by %d specs"] = "被 %d 个专精共享",
        ["Switch pending until combat ends"] = "战斗结束后切换", ["Account default profile"] = "账号默认配置",
        ["Current"] = "当前", ["Active"] = "激活", ["Character default"] = "角色默认配置",
        ["Assigned profile:"] = "已分配配置：", ["Independent"] = "独立", ["No visited characters"] = "没有已访问角色",
        ["Spec %d"] = "专精 %d", ["Profile changes are unavailable during combat."] = "战斗中无法更改配置。",
        ["Waiting for a safe profile context."] = "正在等待安全的配置环境。",
        ["Compatibility mode - profiles are read-only."] = "兼容模式 – 配置为只读。",
        ["Profile to manage:"] = "要管理的配置：", ["Choose a profile"] = "选择配置",
        ["All settings"] = "所有设置", ["Stat and gear settings"] = "属性与装备设置", ["Layout settings"] = "布局设置", ["Appearance settings"] = "外观设置", ["Choose settings to copy"] = "选择要复制的设置",
        ["Copy %s from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "将“%s”从“%s”复制到“%s”？这会更改 %d 个已分配专精和 %d 个其他引用。",
        ["Assign to selected context"] = "分配给所选项", ["New from defaults..."] = "从默认值新建...",
        ["Duplicate profile..."] = "复制配置...", ["Rename profile..."] = "重命名配置...",
        ["Copy settings to assigned profile..."] = "复制设置到已分配配置...", ["Swap assignments..."] = "交换分配...",
        ["Reset active profile..."] = "重置当前配置...", ["Delete profile..."] = "删除配置...",
        ["Forget character..."] = "移除角色记录...", ["Confirm"] = "确认",
        ["Selected character"] = "所选角色", ["%s - %d known specs"] = "%s – %d 个已知专精",
        ["Future new contexts"] = "未来新环境", ["Tank: %s"] = "坦克：%s",
        ["Healer: %s"] = "治疗：%s", ["Damage: %s"] = "输出：%s",
        ["Tank"] = "坦克", ["Healer"] = "治疗", ["Damage"] = "输出",
        ["Use profile for all known specs..."] = "用于所有已知专精...",
        ["Make shared specs independent..."] = "将共享专精设为独立...",
        ["Set future role template..."] = "设置未来职责模板...", ["Choose a role"] = "选择职责",
        ["Use \"%s\" for all %d known specs of \"%s\"? Existing profiles and settings will be kept."] = "将“%s”用于全部 %d 个已知专精（角色：“%s”）？现有配置和设置将保留。",
        ["Make %d shared specs of \"%s\" independent? Each affected spec receives a separate copy; existing profiles stay unchanged."] = "将 %d 个共享专精设为独立（角色：“%s”）？每个受影响专精都会获得单独副本；现有配置保持不变。",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "将“%s”作为未来坦克环境的来源？现有分配不会改变；每个新环境都会获得独立副本。",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "将“%s”作为未来治疗环境的来源？现有分配不会改变；每个新环境都会获得独立副本。",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "将“%s”作为未来输出环境的来源？现有分配不会改变；每个新环境都会获得独立副本。",
        ["Unused"] = "未使用", ["Unused profile"] = "未使用的配置", ["New Profile"] = "新配置",
        ["%s Copy"] = "%s 副本", ["Choose a replacement profile"] = "选择替代配置",
        ["Choose a context"] = "选择项目", ["%d assigned specs, %d other references"] = "已分配专精 %d 个，其他引用 %d 个",
        ["Profile changes saved."] = "配置更改已保存。", ["Enter a valid profile name."] = "请输入有效的配置名称。",
        ["Profile names can contain at most %d characters."] = "配置名称最多可包含 %d 个字符。",
        ["A profile with this name already exists."] = "已存在同名配置。",
        ["Profiles changed; review and try again."] = "配置已发生变化。请检查选择后重试。",
        ["The last profile cannot be deleted."] = "无法删除最后一个配置。",
        ["Choose a replacement profile."] = "请选择替代配置。",
        ["The current character cannot be forgotten."] = "无法移除当前角色的记录。",
        ["Nothing changed."] = "没有任何更改。",
        ["Profile operation failed. Review the selection and try again."] = "配置操作失败。请检查选择后重试。",
        ["Delete profile \"%s\" and replace all references with \"%s\"? This affects %d assigned specs and %d other references."] = "删除配置“%s”并将所有引用替换为“%s”？这会影响 %d 个已分配专精和 %d 个其他引用。",
        ["Swap \"%s\" and \"%s\"? Their profile settings stay unchanged."] = "交换“%s”和“%s”？它们的配置设置不会改变。",
        ["Rename shared profile \"%s\" to \"%s\"? This affects %d assigned specs and %d other references."] = "将共享配置“%s”重命名为“%s”？这会影响 %d 个已分配专精和 %d 个其他引用。",
        ["Copy settings from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "将设置从“%s”复制到“%s”？这会更改 %d 个已分配专精和 %d 个其他引用。",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "将当前配置“%s”重置为默认值？这会更改 %d 个已分配专精和 %d 个其他引用。",
        ["Delete unused profile \"%s\"?"] = "删除未使用的配置“%s”？",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "移除“%s”的记录？角色记录将被删除，但配置设置会保留。",
        ["Auto (current: %s)"] = "自动（当前: %s）",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r 字体可能无法显示 %s 字形。请从 SharedMedia 选择合适的字体。",
        ["Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window."] = "属性与装备 HUD：装等、耐久度、修理费用及 Archon 属性目标。点击下方打开完整设置窗口。",
    },

    -- zhTW: Traditional Chinese (Taiwan). Same 2-char convention as zhCN but
    -- Traditional script forms (護甲 vs 护甲, 格擋 vs 格挡, 迴避 vs 闪避).
    -- Matches WoW Taiwan client terminology. High confidence.
    zhTW = {
        Crit = "致命",          Haste = "加速",         Mastery = "精通",       Vers = "全能",
        Dodge = "躲避",         Parry = "招架",         Block = "格擋",         Armor = "護甲",         Stagger = "醉拳",
        Strength = "力量",      Agility = "敏捷",       Intellect = "智力",      Stamina = "耐力",
        ItemLevel = "裝等",
        Leech = "汲取",         Avoidance = "迴避",     Speed = "移動",
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
        ["Appearance Presets"] = "外觀預設", ["Preset:"] = "預設：",
        ["Classic"] = "經典", ["Clean Dark"] = "簡潔深色", ["Midnight"] = "午夜",
        ["Monochrome"] = "單色", ["High Contrast"] = "高對比", ["Custom"] = "自訂",
        ["Previewing: %s"] = "預覽中：%s", ["Apply"] = "套用", ["Cancel preview"] = "取消預覽",
        ["Presets change font size, opacity, outline, panel background, HUD colors, and color behavior. They keep font face, layout, visible stats, scale, language, and refresh rate."] = "預設會變更字號、透明度、外框、面板背景、HUD顏色與顏色行為。字型、版面、顯示屬性、縮放、語言與更新頻率維持不變。",
        ["This profile is shared by %d specs and %d other references. Applying changes all of them."] = "此設定檔由%d個專精與%d個其他參照共用。套用會變更全部參照。",
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
        ["Requires %s."] = "需要%s。",
        ["Show Crit"] = "顯示致命一擊", ["Show Haste"] = "顯示加速",
        ["Show Mastery"] = "顯示精通", ["Show Versatility"] = "顯示全能",
        ["Show Tertiary Stats"] = "顯示三級屬性",
        ["Show Leech"] = "顯示汲取", ["Show Avoidance"] = "顯示迴避", ["Show Speed"] = "顯示移動速度",
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
        ["Last known comparison"] = "上次已知比較", ["Source:"] = "來源:",
        ["Stats panel shown"] = "屬性面板已顯示", ["Stats panel hidden"] = "屬性面板已隱藏",
        ["Settings reset to defaults"] = "設定已恢復預設",
        ["Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /statspro import, /ss debug, /ss help"] = "指令: /ss 或 /statspro (設定), /ss show, /ss hide, /ss toggle, /ss reset, /ss wipe, /statspro import, /ss debug, /ss help",
        ["SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."] = "未載入 SwiftStats 設定。請啟用 SwiftStats 登入一次，執行 /reload，然後再次輸入 /statspro import。",
        ["SwiftStats has no supported settings to import."] = "SwiftStats 中沒有可匯入的支援設定。",
        ["These settings use a newer schema and cannot be imported by this StatsPro version."] = "這些設定使用較新的資料結構，目前版本的 StatsPro 無法匯入。",
        ["Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."] = "這些設定由較新版本的 StatsPro 儲存，因此目前為唯讀。請更新 StatsPro 後再進行修改。",
        ["SwiftStats import is unavailable during combat. Try again after combat."] = "戰鬥中無法匯入 SwiftStats 設定。請在戰鬥結束後重試。",
        ["Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged."] = "要將相容的 SwiftStats 設定匯入目前角色與專精的新設定檔嗎？現有設定檔、其他指派、帳號設定和 SwiftStats 資料都不會變更。",
        ["Import"] = "匯入",
        ["SwiftStats settings imported into new profile \"%s\"."] = "SwiftStats 設定已匯入新設定檔「%s」。",
        ["SwiftStats import failed; profiles and assignments were preserved."] = "SwiftStats 匯入失敗；設定檔和指派已保留。",
        ["Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged."] = "要重設所有 StatsPro 資料嗎？這將永久刪除所有設定檔、角色與專精指派、職責範本、帳號設定和已儲存的位置。SwiftStats 資料不會變更。",
        ["All StatsPro data reset to defaults."] = "所有 StatsPro 資料已重設為預設值。",
        ["Reset to Defaults"] = "恢復預設", ["Close"] = "關閉",
        ["Open Settings"] = "開啟設定", ["Settings"] = "設定",
        ["Profile:"] = "設定檔：", ["Manage"] = "管理", ["Profile Manager"] = "設定檔管理",
        ["Automatic - %s / %s"] = "自動 – %s / %s", ["Shared by %d specs"] = "由 %d 個專精共用",
        ["Switch pending until combat ends"] = "戰鬥結束後切換", ["Account default profile"] = "帳號預設設定檔",
        ["Current"] = "目前", ["Active"] = "啟用", ["Character default"] = "角色預設設定檔",
        ["Assigned profile:"] = "已指派設定檔：", ["Independent"] = "獨立", ["No visited characters"] = "沒有已造訪角色",
        ["Spec %d"] = "專精 %d", ["Profile changes are unavailable during combat."] = "戰鬥中無法變更設定檔。",
        ["Waiting for a safe profile context."] = "正在等待安全的設定檔環境。",
        ["Compatibility mode - profiles are read-only."] = "相容模式 – 設定檔為唯讀。",
        ["Profile to manage:"] = "要管理的設定檔：", ["Choose a profile"] = "選擇設定檔",
        ["All settings"] = "所有設定", ["Stat and gear settings"] = "屬性與裝備設定", ["Layout settings"] = "版面設定", ["Appearance settings"] = "外觀設定", ["Choose settings to copy"] = "選擇要複製的設定",
        ["Copy %s from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "將「%s」從「%s」複製到「%s」？這會變更 %d 個已指派專精和 %d 個其他參照。",
        ["Assign to selected context"] = "指派給所選項目", ["New from defaults..."] = "從預設值新增...",
        ["Duplicate profile..."] = "複製設定檔...", ["Rename profile..."] = "重新命名設定檔...",
        ["Copy settings to assigned profile..."] = "複製設定到已指派設定檔...", ["Swap assignments..."] = "交換指派...",
        ["Reset active profile..."] = "重設目前設定檔...", ["Delete profile..."] = "刪除設定檔...",
        ["Forget character..."] = "移除角色記錄...", ["Confirm"] = "確認",
        ["Selected character"] = "所選角色", ["%s - %d known specs"] = "%s – %d 個已知專精",
        ["Future new contexts"] = "未來新環境", ["Tank: %s"] = "坦克：%s",
        ["Healer: %s"] = "治療：%s", ["Damage: %s"] = "輸出：%s",
        ["Tank"] = "坦克", ["Healer"] = "治療", ["Damage"] = "輸出",
        ["Use profile for all known specs..."] = "用於所有已知專精...",
        ["Make shared specs independent..."] = "將共用專精設為獨立...",
        ["Set future role template..."] = "設定未來職責範本...", ["Choose a role"] = "選擇職責",
        ["Use \"%s\" for all %d known specs of \"%s\"? Existing profiles and settings will be kept."] = "將「%s」用於全部 %d 個已知專精（角色：「%s」）？現有設定檔和設定將保留。",
        ["Make %d shared specs of \"%s\" independent? Each affected spec receives a separate copy; existing profiles stay unchanged."] = "將 %d 個共用專精設為獨立（角色：「%s」）？每個受影響專精都會取得獨立副本；現有設定檔保持不變。",
        ["Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."] = "將「%s」作為未來坦克環境的來源？現有指派不會變更；每個新環境都會取得獨立副本。",
        ["Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."] = "將「%s」作為未來治療環境的來源？現有指派不會變更；每個新環境都會取得獨立副本。",
        ["Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."] = "將「%s」作為未來輸出環境的來源？現有指派不會變更；每個新環境都會取得獨立副本。",
        ["Unused"] = "未使用", ["Unused profile"] = "未使用的設定檔", ["New Profile"] = "新設定檔",
        ["%s Copy"] = "%s 副本", ["Choose a replacement profile"] = "選擇替代設定檔",
        ["Choose a context"] = "選擇項目", ["%d assigned specs, %d other references"] = "已指派專精 %d 個，其他參照 %d 個",
        ["Profile changes saved."] = "設定檔變更已儲存。", ["Enter a valid profile name."] = "請輸入有效的設定檔名稱。",
        ["Profile names can contain at most %d characters."] = "設定檔名稱最多可包含 %d 個字元。",
        ["A profile with this name already exists."] = "已有同名設定檔。",
        ["Profiles changed; review and try again."] = "設定檔已發生變更。請檢查選擇後再試一次。",
        ["The last profile cannot be deleted."] = "無法刪除最後一個設定檔。",
        ["Choose a replacement profile."] = "請選擇替代設定檔。",
        ["The current character cannot be forgotten."] = "無法移除目前角色的記錄。",
        ["Nothing changed."] = "沒有任何變更。",
        ["Profile operation failed. Review the selection and try again."] = "設定檔操作失敗。請檢查選擇後再試一次。",
        ["Delete profile \"%s\" and replace all references with \"%s\"? This affects %d assigned specs and %d other references."] = "刪除設定檔「%s」並將所有參照替換為「%s」？這會影響 %d 個已指派專精和 %d 個其他參照。",
        ["Swap \"%s\" and \"%s\"? Their profile settings stay unchanged."] = "交換「%s」與「%s」？兩者的設定檔內容不會變更。",
        ["Rename shared profile \"%s\" to \"%s\"? This affects %d assigned specs and %d other references."] = "將共用設定檔「%s」重新命名為「%s」？這會影響 %d 個已指派專精和 %d 個其他參照。",
        ["Copy settings from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."] = "將設定從「%s」複製到「%s」？這會變更 %d 個已指派專精和 %d 個其他參照。",
        ["Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."] = "將目前設定檔「%s」重設為預設值？這會變更 %d 個已指派專精和 %d 個其他參照。",
        ["Delete unused profile \"%s\"?"] = "刪除未使用的設定檔「%s」？",
        ["Forget \"%s\"? Its character record will be removed, but profile settings will be kept."] = "移除「%s」的記錄？角色記錄將被刪除，但設定檔內容會保留。",
        ["Auto (current: %s)"] = "自動（目前: %s）",
        ["|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."] = "|cffffaa44⚠|r 字型可能無法顯示 %s 字形。請從 SharedMedia 選擇合適的字型。",
        ["Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window."] = "屬性與裝備 HUD：裝等、耐久度、修理費用及 Archon 屬性目標。點擊下方開啟完整設定視窗。",
    },
}

-- WARNING: must precede ResolveActiveLocale — forward-ref to GetDB resolves as _G.GetDB at parse time.
local function GetDB(key)
    local db = addon.dbRuntime.GetSettingStore(key)
    local v = db[key]
    local secretOK, secret = pcall(issecretvalue, v)
    if not secretOK or secret or v == nil then v = defaults[key] end
    if addon.appearancePresets and addon.appearancePresets.ResolveValue then
        return addon.appearancePresets.ResolveValue(key, v)
    end
    return v
end

local function GetBoolDB(key)
    local db = addon.dbRuntime.GetSettingStore(key)
    local value
    if addon.dbRuntime.IsCleanType(db[key], "boolean") then
        value = db[key]
    else
        value = defaults[key] == true
    end
    if addon.appearancePresets and addon.appearancePresets.ResolveValue then
        return addon.appearancePresets.ResolveValue(key, value) == true
    end
    return value
end

local function GetFontDB()
    local db = addon.dbRuntime.GetActiveSettings()
    local usable = addon.fontRuntime.usablePath and addon.fontRuntime.usablePath(db.font)
    if usable then return usable end
    if addon.fontRuntime.safeDefaultPath then return addon.fontRuntime.safeDefaultPath() end
    return "Fonts\\FRIZQT__.TTF"
end

local function GetSavedAutoFontDB()
    local db = addon.dbRuntime.GetActiveSettings()
    if not addon.fontRuntime.usablePath then return nil end
    return addon.fontRuntime.usablePath(db.fontBeforeAutoSwitch)
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
    local secretOK, secret = pcall(issecretvalue, value)
    -- WARNING: an unreadable/secret schema marker must block mutation like a
    -- future version; treating it as version 0 would run destructive migrations.
    if not secretOK or secret then return CURRENT_DB_VERSION + 1, false end
    local numberOK, n = pcall(tonumber, value)
    if not numberOK then return 0, true end
    if not IsFiniteNumber(n) then return 0, true end
    return math.floor(n), true
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
    local db = addon.dbRuntime.GetSettingStore(key)
    local v = db[key]
    local secretOK, secret = pcall(issecretvalue, v)
    if not secretOK or secret then v = nil end
    if v == nil then v = defaults[key] end
    if addon.appearancePresets and addon.appearancePresets.ResolveValue then
        v = addon.appearancePresets.ResolveValue(key, v)
    end
    return NormalizeNumberSetting(key, v)
end

-- WHY addon-table helpers: this file is close to Lua 5.1 top-level local limits.
-- Keeping small DB normalizers off file-scope locals avoids chunk-local overflow.
function addon.NormalizeDisplayMode(value)
    if value == "sectioned" or value == "split" then
        return value
    end
    return "flat"
end

function addon.NormalizeForceLocale(value)
    for _, opt in ipairs(LANGUAGE_OPTIONS) do
        if value == opt.value then return value end
    end
    return "auto"
end

-- enGB uses the existing English translation pack. Keep this alias on the
-- output-language axis; raw client locale still drives client-shipped fonts.
function addon.NormalizeOutputLocale(value)
    if value == "enGB" then return "enUS" end
    return value
end

-- Resolve the active output locale: forceLocale="auto" (default) follows the
-- client's supported presentation; an explicit value overrides the client locale.
local function ResolveActiveLocale()
    local force = addon.NormalizeForceLocale(GetDB("forceLocale"))
    if force == "auto" then return addon.NormalizeOutputLocale(GetLocale()) end
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

-- Font asset validity is separate from heuristic glyph coverage. LSM accepts
-- arbitrary FONT data, and SavedVariables can retain paths after a media addon is
-- removed, so only a successful real SetFont probe proves that a path is usable.
addon.fontRuntime.probeFontString = UIParent:CreateFontString(nil, "OVERLAY")
addon.fontRuntime.probeFontString:Hide()
addon.fontRuntime.probeResults = {}

function addon.fontRuntime.rawLSMPath(name)
    if not LSM then return nil end
    local mediaType = LSM.MediaType.FONT
    if LSM.HashTable then
        local paths = LSM:HashTable(mediaType)
        return type(paths) == "table" and paths[name] or nil
    end
    return LSM:Fetch(mediaType, name)
end

function addon.fontRuntime.catalogEntry(fontPath)
    local key = FontPathKey(fontPath)
    if not key then return nil, nil end

    local localeDefault = LocaleAwareDefaultFont()
    if SameFontPath(fontPath, localeDefault) then return localeDefault, nil end
    local clientLocale = GetLocale()
    for _, entry in ipairs(BLIZZARD_SHIPPED_FONTS) do
        if (not entry.locale or entry.locale == clientLocale) and SameFontPath(fontPath, entry.path) then
            return entry.path, entry.name
        end
    end
    if LSM then
        for _, name in ipairs(LSM:List(LSM.MediaType.FONT)) do
            local path = addon.fontRuntime.rawLSMPath(name)
            if SameFontPath(fontPath, path) then return path, name end
        end
    end
    return nil, nil
end

function addon.fontRuntime.probe(fontPath, size, flags)
    local key = FontPathKey(fontPath)
    if not key then return false end
    local cacheKey = key .. "\031" .. (flags or "") .. "\031" .. tostring(size)
    local cachedResult = addon.fontRuntime.probeResults[cacheKey]
    if cachedResult ~= nil then return cachedResult end
    local ok, success = pcall(addon.fontRuntime.probeFontString.SetFont,
        addon.fontRuntime.probeFontString, fontPath, size, flags)
    local usable = ok and success == true
    addon.fontRuntime.probeResults[cacheKey] = usable
    return usable
end

function addon.fontRuntime.usableCatalogPath(fontPath)
    if not FontPathKey(fontPath) then return nil end
    if addon.fontRuntime.probe(fontPath, defaults.fontSize, nil) then return fontPath end
    return nil
end

function addon.fontRuntime.usablePath(fontPath)
    if not FontPathKey(fontPath) then return nil end
    local catalogPath = addon.fontRuntime.catalogEntry(fontPath)
    return catalogPath and addon.fontRuntime.usableCatalogPath(catalogPath) or nil
end

function addon.fontRuntime.safeDefaultPath()
    local candidates = {
        LocaleAwareDefaultFont(),
        "Fonts\\FRIZQT__.TTF",
        "Fonts\\ARIALN.TTF",
    }
    for _, entry in ipairs(BLIZZARD_SHIPPED_FONTS) do
        if not entry.locale or entry.locale == GetLocale() then
            candidates[#candidates + 1] = entry.path
        end
    end
    for _, candidate in ipairs(candidates) do
        local usable = addon.fontRuntime.usablePath(candidate)
        if usable then return usable end
    end
    return "Fonts\\FRIZQT__.TTF"
end

function addon.fontRuntime.catalogName(fontPath)
    if not FontPathKey(fontPath) then return "Font" end
    local _, name = addon.fontRuntime.catalogEntry(fontPath)
    if name then return name end
    if SameFontPath(fontPath, LocaleAwareDefaultFont()) then
        for _, entry in ipairs(BLIZZARD_SHIPPED_FONTS) do
            if SameFontPath(fontPath, entry.path) then return entry.name end
        end
    end
    return (type(fontPath) == "string" and string.match(fontPath, "[^\\/]+$")) or "Font"
end

local function FindCompatibleFont(currentFont, req)
    local seen = {}
    local function consider(path, knownCatalogEntry)
        local usable = knownCatalogEntry
            and addon.fontRuntime.usableCatalogPath(path)
            or addon.fontRuntime.usablePath(path)
        local key = FontPathKey(usable)
        if not key or seen[key] then return nil end
        seen[key] = true
        if FontSupports(usable, req) then return usable end
        return nil
    end

    local match = consider(currentFont)
        or consider(LocaleAwareDefaultFont())
        or consider("Fonts\\ARIALN.TTF")
    if match then return match end
    for _, entry in ipairs(BLIZZARD_SHIPPED_FONTS) do
        if not entry.locale or entry.locale == GetLocale() then
            match = consider(entry.path, true)
            if match then return match end
        end
    end
    if LSM then
        for _, name in ipairs(LSM:List(LSM.MediaType.FONT)) do
            match = consider(addon.fontRuntime.rawLSMPath(name), true)
            if match then return match end
        end
    end
    return nil
end

function addon.fontRuntime.resolveUsableFlags(usable, size, requestedFlags)
    if not FontPathKey(usable) then return nil, nil end
    if requestedFlags and addon.fontRuntime.probe(usable, size, requestedFlags) then
        return usable, requestedFlags
    end
    if addon.fontRuntime.probe(usable, size, nil) then return usable, nil end
    return nil, nil
end

function addon.fontRuntime.resolveFlags(fontPath, size, requestedFlags)
    local usable = addon.fontRuntime.usablePath(fontPath)
    if not usable then return nil, nil end
    return addon.fontRuntime.resolveUsableFlags(usable, size, requestedFlags)
end

function addon.fontRuntime.setRegionFont(region, fontPath, size, flags)
    local ok, success = pcall(region.SetFont, region, fontPath, size, flags)
    return ok and success == true
end

function addon.fontRuntime.applyExact(regions, fontPath, size, requestedFlags)
    local resolvedFont, effectiveFlags = addon.fontRuntime.resolveFlags(fontPath, size, requestedFlags)
    if not resolvedFont then return false end
    for _, region in ipairs(regions) do
        if not addon.fontRuntime.setRegionFont(region, resolvedFont, size, effectiveFlags) then
            return false
        end
    end
    return true, resolvedFont, effectiveFlags
end

function addon.fontRuntime.restore(regions, fontPath, size, flags)
    if not fontPath then return end
    for _, region in ipairs(regions) do
        addon.fontRuntime.setRegionFont(region, fontPath, size, flags)
    end
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

-- pcall every stat API so 12.x secret values never touch unsafe Lua logic.
-- Raw successful returns flow only into string.format/SetText paths that Blizzard
-- allows for secrets. API failures stay nil rather than rendering fake 0 values.
local function safeCall(fn, ...)
    local ok, val = pcall(fn, ...)
    if ok then return val end
    return nil
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

function SAFE_NUM.ReadRatingValue(fn, ...)
    local value = safeCall(fn, ...)
    if issecretvalue(value) then return value, nil end
    if SAFE_NUM.IsCleanFiniteNumber(value) and value >= 0 then return value, value end
    return nil, nil
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
    return not issecretvalue(value) and SAFE_NUM.IsCleanFiniteNumber(value) and value >= 0
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
-- Secret values cannot be compared with 0, so hide-zero rows reuse the last clean
-- visibility decision. Cold secret reads stay hidden rather than surfacing fake 0 rows.
local function shouldShow(rowKey, val, hideZero)
    if not IsRenderablePercentValue(val) then return false end
    local isSecret = issecretvalue(val)
    if not isSecret and rowKey then
        cached.cleanRowVisibility[rowKey] = val ~= 0
    end
    if not hideZero then return true end
    if isSecret then return rowKey and cached.cleanRowVisibility[rowKey] == true end
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

-- One dynamic boundary owns every SavedVariables read/write. Schema v10 leaves the
-- old flat fields untouched at the root as a one-generation downgrade shadow, while
-- current code reads profile settings and the two account-wide settings only through
-- these accessors. Re-evaluate every attempted mutation so root/version/profile changes
-- invalidate stale modal callbacks before they can write into a different payload.
addon.dbRuntime = {
    readOnly = false,
    mode = "legacy",
    version = 0,
    versionDisplay = "0",
    warned = false,
    rootRef = nil,
    activeAccount = nil,
    activeSettings = nil,
    activeProfileID = nil,
    registryReady = false,
    generation = 0,
    validationCount = 0,
    migrationFailedRoot = nil,
    validatedRootRef = nil,
    validatedAccountRef = nil,
    validatedProfilesRef = nil,
    validatedRoleTemplatesRef = nil,
    validatedCharactersRef = nil,
    validatedDefaultProfileID = nil,
    validatedDefaultProfileRef = nil,
    validatedActiveProfileRef = nil,
    readFallback = {},
    maxProfileNumber = 99999999999999,
    accountSettingKeys = { forceLocale = true, updateInterval = true },
    registryRootKeys = {
        dbVersion = true,
        account = true,
        profiles = true,
        roleTemplates = true,
        characters = true,
    },
    legacySettingKeys = {
        useLocalizedLabels = true,
        showStrength = true,
        showAgility = true,
        showIntellect = true,
        fontBeforeAutoSwitch = true,
    },
}

addon.profileRuntime = {
    activeGUID = nil,
    activeSpecID = nil,
    activeDisplayName = nil,
    activeSpecName = nil,
    activeRole = nil,
    knownSpecNames = {},
    forceReapply = false,
    forceReapplyRetryCount = 0,
    forceReapplyRetryToken = nil,
    pendingResolution = false,
    scheduledToken = nil,
    noSpecRetryToken = nil,
    settlingNoSpec = false,
    requestGeneration = 0,
    transitioning = false,
    suppressIntermediateRefresh = false,
    activationCount = 0,
    applyCount = 0,
    configRefreshCount = 0,
    contextRenderCount = 0,
    structuralCommitCount = 0,
    contextReadCount = 0,
}

addon.profileUI = {
    refreshCount = 0,
    selectedGUID = nil,
    selectedSpecID = nil,
    selectedProfileID = nil,
}

addon.profileOps = {
    inProgress = false,
    operationCount = 0,
    maxNameCodepoints = 40,
    testFailureStage = nil,
    roleOrder = { "TANK", "HEALER", "DAMAGER" },
    roleKeys = { TANK = true, HEALER = true, DAMAGER = true },
    positionKeys = {
        "point", "relativePoint", "xOfs", "yOfs",
        "defensive_point", "defensive_relativePoint",
        "defensive_xOfs", "defensive_yOfs",
    },
    copyScopeKeys = {
        stats = {
            showRating = true, showPercentage = true, matchValueColorToStat = true,
            targetSnapshot = true, showTertiary = true, hideZeroTertiary = true,
            showLeech = true, showAvoidance = true, showSpeed = true,
            showMainStat = true, showStamina = true, showItemLevel = true,
            showDefensive = true, hideZeroDefensive = true, showDodge = true,
            showParry = true, showBlock = true, showArmor = true, showStagger = true,
            showOffensive = true, hideZeroOffensive = true, showCrit = true,
            showHaste = true, showMastery = true, showVersatility = true,
            showDurability = true, showRepairCost = true,
            useAutoColorDurability = true, useWorstDurability = true, colors = true,
        },
        layout = {
            point = true, relativePoint = true, xOfs = true, yOfs = true,
            defensive_point = true, defensive_relativePoint = true,
            defensive_xOfs = true, defensive_yOfs = true,
            scale = true, isVisible = true, isLocked = true,
            displayMode = true, labelStyle = true,
            splitCharacter = true, splitItemLevel = true, splitOffensive = true,
            splitTertiary = true, splitDefensive = true,
            splitDurability = true, splitRepairCost = true,
        },
        appearance = {
            font = true, fontSize = true, textAlpha = true,
            panelBackgroundAlpha = true, textOutlineStyle = true,
            fontBeforeAutoSwitch = true, appearancePresetID = true,
            matchValueColorToStat = true, useAutoColorDurability = true,
            colors = true,
        },
    },
}

function addon.profileUI.RefreshSafe()
    local refresh = addon.profileUI.refreshAll
    if type(refresh) == "function" then pcall(refresh) end
    local design = addon.settingsDesign
    if design and type(design.RefreshMutationControls) == "function" then
        pcall(design.RefreshMutationControls)
    end
    if addon.appearancePresets and type(addon.appearancePresets.RefreshUI) == "function" then
        pcall(addon.appearancePresets.RefreshUI)
    end
end

function addon.profileOps.CountSpecAssignments(root)
    local counts = {}
    for _, character in pairs(root.characters or {}) do
        for _, profileID in pairs(character.specProfiles or {}) do
            counts[profileID] = (counts[profileID] or 0) + 1
        end
    end
    return counts
end

function addon.profileOps.CountSharedCharacterSpecs(root, guid, assignmentCounts)
    local character = root.characters and root.characters[guid] or nil
    if type(character) ~= "table" or not addon.dbRuntime.IsCleanTable(character) then return 0 end
    local specProfiles = rawget(character, "specProfiles")
    if type(specProfiles) ~= "table"
        or not addon.dbRuntime.IsCleanTable(specProfiles) then return 0 end
    local counts = assignmentCounts or addon.profileOps.CountSpecAssignments(root)
    local shared = 0
    for _, profileID in pairs(specProfiles) do
        if (counts[profileID] or 0) > 1 then shared = shared + 1 end
    end
    return shared
end

function addon.profileUI.BuildViewModel()
    local root = addon.dbRuntime.Refresh()
    local runtime = addon.profileRuntime
    local pending = runtime.pendingResolution or runtime.scheduledToken ~= nil
        or runtime.noSpecRetryToken ~= nil
    local combat = runtime.ReadCombatState()
    local model = {
        mode = addon.dbRuntime.mode,
        readOnly = addon.dbRuntime.readOnly or not addon.dbRuntime.registryReady,
        pending = pending,
        combat = combat,
        canMutate = false,
        activeGUID = runtime.activeGUID,
        activeSpecID = runtime.activeSpecID,
        activeDisplayName = runtime.activeDisplayName,
        activeSpecName = runtime.activeSpecName,
        activeProfileID = addon.dbRuntime.activeProfileID,
        activeProfileName = nil,
        activeSharedCount = 0,
        accountDefaultProfileID = nil,
        roleTemplates = {},
        characters = {},
        profiles = {},
    }
    if model.readOnly then return model end

    model.accountDefaultProfileID = root.account.defaultProfileID
    model.canMutate = combat == false and not pending
        and not runtime.transitioning and not addon.profileOps.inProgress
    local assignmentCounts = addon.profileOps.CountSpecAssignments(root)
    for _, role in ipairs(addon.profileOps.roleOrder) do
        local profileID = root.roleTemplates[role]
        local profile = root.profiles[profileID]
        model.roleTemplates[role] = {
            role = role,
            profileID = profileID,
            profileName = profile and profile.name or "",
        }
    end

    local activeProfile = root.profiles[model.activeProfileID]
    if addon.dbRuntime.IsCleanTable(activeProfile)
        and addon.dbRuntime.IsCleanType(activeProfile.name, "string") then
        model.activeProfileName = activeProfile.name
        model.activeSharedCount = assignmentCounts[model.activeProfileID] or 0
    end

    for guid, character in pairs(root.characters) do
        local characterModel = {
            guid = guid,
            displayName = character.displayName or "Character",
            lastSeen = character.lastSeen or 0,
            isCurrent = guid == model.activeGUID,
            defaultProfileID = character.defaultProfileID,
            defaultProfileName = nil,
            defaultSharedCount = assignmentCounts[character.defaultProfileID] or 0,
            knownSpecCount = 0,
            sharedSpecCount = addon.profileOps.CountSharedCharacterSpecs(
                root, guid, assignmentCounts),
            specs = {},
        }
        local defaultProfile = character.defaultProfileID
            and root.profiles[character.defaultProfileID] or nil
        if defaultProfile then characterModel.defaultProfileName = defaultProfile.name end
        for specID, profileID in pairs(character.specProfiles or {}) do
            local profile = root.profiles[profileID]
            characterModel.specs[#characterModel.specs + 1] = {
                specID = specID,
                specName = runtime.knownSpecNames[specID],
                profileID = profileID,
                profileName = profile and profile.name or "",
                sharedCount = assignmentCounts[profileID] or 0,
                isActive = guid == model.activeGUID and specID == model.activeSpecID
                    and profileID == model.activeProfileID,
            }
            characterModel.knownSpecCount = characterModel.knownSpecCount + 1
        end
        table.sort(characterModel.specs, function(left, right)
            if left.isActive ~= right.isActive then return left.isActive end
            return left.specID < right.specID
        end)
        model.characters[#model.characters + 1] = characterModel
    end
    table.sort(model.characters, function(left, right)
        if left.isCurrent ~= right.isCurrent then return left.isCurrent end
        if left.lastSeen ~= right.lastSeen then return left.lastSeen > right.lastSeen end
        return left.guid < right.guid
    end)
    model.profiles = addon.profileOps.BuildProfileCatalog(root, assignmentCounts)
    return model
end

function addon.profileRuntime.BlocksUserWrites()
    return not addon.profileRuntime.transitioning
        and (addon.profileRuntime.pendingResolution
            or addon.profileRuntime.scheduledToken ~= nil)
end

function addon.dbRuntime.IsCleanType(value, expectedType)
    local secretOK, secret = pcall(issecretvalue, value)
    return secretOK and not secret and type(value) == expectedType
end

function addon.dbRuntime.IsCleanTable(value)
    if not addon.dbRuntime.IsCleanType(value, "table") then return false end
    if type(_G.issecrettable) == "function" then
        local ok, secret = pcall(_G.issecrettable, value)
        if not ok or secret then return false end
    end
    return pcall(next, value, nil)
end

-- Serializable clone with ancestry-only cycle detection. Repeated source tables are
-- copied independently, so profile payloads cannot retain aliases from hand-edited or
-- legacy SavedVariables. Cycles/secret/unsupported values fail before inspection.
function addon.dbRuntime.CloneSerializable(value, ancestors)
    local secretOK, secret = pcall(issecretvalue, value)
    if not secretOK or secret then return nil, false end
    local valueType = type(value)
    if valueType == "nil" or valueType == "boolean"
        or valueType == "number" or valueType == "string" then
        return value, true
    end
    if valueType ~= "table" or not addon.dbRuntime.IsCleanTable(value) then return nil, false end
    ancestors = ancestors or {}
    if ancestors[value] then return nil, false end
    ancestors[value] = true
    local copy = {}
    local key = nil
    while true do
        local nextOK, nextKey, nextValue = pcall(next, value, key)
        if not nextOK then
            ancestors[value] = nil
            return nil, false
        end
        if type(nextKey) == "nil" then break end
        local keyType = type(nextKey)
        local cleanKey = addon.dbRuntime.IsCleanType(nextKey, keyType)
        if not cleanKey or (keyType ~= "string" and keyType ~= "number") then
            ancestors[value] = nil
            return nil, false
        end
        local clonedValue, cloned = addon.dbRuntime.CloneSerializable(nextValue, ancestors)
        if not cloned then
            ancestors[value] = nil
            return nil, false
        end
        copy[nextKey] = clonedValue
        key = nextKey
    end
    ancestors[value] = nil
    return copy, true
end

-- Validate a serializable table graph and optionally reject all repeated table
-- references. A separate forbidden set protects the flat downgrade shadow from
-- becoming writable through any registry/profile path.
function addon.dbRuntime.CollectTableReferences(value, seen, ancestors, rejectAliases, forbidden)
    local secretOK, secret = pcall(issecretvalue, value)
    if not secretOK or secret then return false end
    local valueType = type(value)
    if valueType == "nil" or valueType == "boolean"
        or valueType == "number" or valueType == "string" then
        return true
    end
    if valueType ~= "table" or not addon.dbRuntime.IsCleanTable(value) then return false end
    ancestors = ancestors or {}
    if ancestors[value] or (forbidden and forbidden[value]) then return false end
    if seen[value] then return not rejectAliases end
    seen[value] = true
    ancestors[value] = true
    local key = nil
    while true do
        local nextOK, nextKey, nextValue = pcall(next, value, key)
        if not nextOK then
            ancestors[value] = nil
            return false
        end
        if type(nextKey) == "nil" then break end
        local keyType = type(nextKey)
        if (keyType ~= "string" and keyType ~= "number")
            or not addon.dbRuntime.IsCleanType(nextKey, keyType)
            or not addon.dbRuntime.CollectTableReferences(
                nextValue, seen, ancestors, rejectAliases, forbidden) then
            ancestors[value] = nil
            return false
        end
        key = nextKey
    end
    ancestors[value] = nil
    return true
end

-- Rollback-shadow data is never read or written by current code, so unsupported or
-- secret legacy extras may remain there. Collect only table identities that can be
-- observed safely; this is enough to forbid registry aliases without interpreting
-- opaque shadow content.
function addon.dbRuntime.CollectShadowTableReferences(value, references, visited)
    if type(value) ~= "table" then return end
    references[value] = true
    visited = visited or {}
    if visited[value] then return end
    visited[value] = true
    local secretOK, secret = pcall(issecretvalue, value)
    if not secretOK or secret then return end
    if type(_G.issecrettable) == "function" then
        local tableOK, secretTable = pcall(_G.issecrettable, value)
        if not tableOK or secretTable then return end
    end
    local key = nil
    while true do
        local nextOK, nextKey, nextValue = pcall(next, value, key)
        if not nextOK or type(nextKey) == "nil" then return end
        addon.dbRuntime.CollectShadowTableReferences(nextValue, references, visited)
        key = nextKey
    end
end

function addon.dbRuntime.IsMigrationSettingKey(key)
    return type(key) == "string"
        and (type(defaults[key]) ~= "nil" or addon.dbRuntime.legacySettingKeys[key] == true)
end

-- Clone flat fields independently. A malformed known setting blocks migration,
-- while an unknown non-serializable field remains only in the untouched rollback
-- shadow. Clean unknown fields are preserved in the new profile.
function addon.dbRuntime.CloneMigrationWork(source, dbVersion)
    if not addon.dbRuntime.IsCleanTable(source) then return nil end
    local copy = {}
    local key = nil
    while true do
        local nextOK, nextKey, nextValue = pcall(next, source, key)
        if not nextOK then return nil end
        if type(nextKey) == "nil" then break end
        local keyType = type(nextKey)
        if (keyType ~= "string" and keyType ~= "number")
            or not addon.dbRuntime.IsCleanType(nextKey, keyType) then
            return nil
        end
        if keyType == "string" and not addon.dbRuntime.registryRootKeys[nextKey] then
            local clonedValue, cloned = addon.dbRuntime.CloneSerializable(nextValue)
            if cloned then
                copy[nextKey] = clonedValue
            elseif addon.dbRuntime.IsMigrationSettingKey(nextKey) then
                return nil
            end
        end
        key = nextKey
    end
    copy.dbVersion = dbVersion
    return copy
end

function addon.dbRuntime.ValidateRegistry(root)
    addon.dbRuntime.validationCount = addon.dbRuntime.validationCount + 1
    if not addon.dbRuntime.IsCleanTable(root) then return false end
    local account = rawget(root, "account")
    local profiles = rawget(root, "profiles")
    local roleTemplates = rawget(root, "roleTemplates")
    local characters = rawget(root, "characters")
    if not addon.dbRuntime.IsCleanTable(account)
        or not addon.dbRuntime.IsCleanTable(profiles)
        or not addon.dbRuntime.IsCleanTable(roleTemplates)
        or not addon.dbRuntime.IsCleanTable(characters) then
        return false
    end

    local shadowReferences, shadowVisited = {}, {}
    local rootKey = nil
    while true do
        local nextOK, nextKey, nextValue = pcall(next, root, rootKey)
        if not nextOK then return false end
        if type(nextKey) == "nil" then break end
        if not addon.dbRuntime.IsCleanType(nextKey, "string")
            or not addon.dbRuntime.registryRootKeys[nextKey] then
            addon.dbRuntime.CollectShadowTableReferences(
                nextValue, shadowReferences, shadowVisited)
        end
        rootKey = nextKey
    end
    local registryReferences = {}
    for _, value in ipairs({ account, profiles, roleTemplates, characters }) do
        if not addon.dbRuntime.CollectTableReferences(
            value, registryReferences, nil, true, shadowReferences) then
            return false
        end
    end

    local profileID = account.defaultProfileID
    if not addon.dbRuntime.IsCleanType(profileID, "string") or profileID == "" then
        return false
    end
    if not addon.dbRuntime.IsCleanType(account.forceLocale, "string")
        or addon.NormalizeForceLocale(account.forceLocale) ~= account.forceLocale
        or not addon.dbRuntime.IsCleanType(account.updateInterval, "number")
        or not IsFiniteNumber(account.updateInterval)
        or account.updateInterval < NUMBER_SETTING_META.updateInterval.min
        or account.updateInterval > NUMBER_SETTING_META.updateInterval.max then
        return false
    end
    local nextProfileID = account.nextProfileID
    if not addon.dbRuntime.IsCleanType(nextProfileID, "number")
        or not IsFiniteNumber(nextProfileID) or nextProfileID < 2
        or nextProfileID > addon.dbRuntime.maxProfileNumber
        or nextProfileID ~= math.floor(nextProfileID) then
        return false
    end

    local highestProfileNumber = 0
    local profileCount = 0
    for candidateID, profile in pairs(profiles) do
        if not addon.dbRuntime.IsCleanType(candidateID, "string") then return false end
        local suffix = candidateID:match("^p([1-9]%d*)$")
        local numericID = suffix and tonumber(suffix) or nil
        if not numericID or numericID > addon.dbRuntime.maxProfileNumber
            or not addon.dbRuntime.IsCleanTable(profile)
            or not addon.dbRuntime.IsCleanType(profile.name, "string") or profile.name == ""
            or not addon.dbRuntime.IsCleanTable(profile.settings)
            or rawget(profile.settings, "forceLocale") ~= nil
            or rawget(profile.settings, "updateInterval") ~= nil then
            return false
        end
        profileCount = profileCount + 1
        if numericID > highestProfileNumber then highestProfileNumber = numericID end
    end
    if profileCount == 0 or nextProfileID <= highestProfileNumber
        or rawget(profiles, "p" .. tostring(nextProfileID)) ~= nil then
        return false
    end
    local profile = profiles[profileID]
    if not addon.dbRuntime.IsCleanTable(profile) then return false end

    for _, role in ipairs({ "TANK", "HEALER", "DAMAGER" }) do
        local roleProfileID = roleTemplates[role]
        local roleProfile = addon.dbRuntime.IsCleanType(roleProfileID, "string")
            and profiles[roleProfileID] or nil
        if not addon.dbRuntime.IsCleanType(roleProfileID, "string")
            or not addon.dbRuntime.IsCleanTable(roleProfile) then
            return false
        end
    end

    for guid, character in pairs(characters) do
        if not addon.dbRuntime.IsCleanType(guid, "string") or guid == ""
            or not addon.dbRuntime.IsCleanTable(character) then
            return false
        end
        if type(character.displayName) ~= "nil"
            and (not addon.dbRuntime.IsCleanType(character.displayName, "string")
                or character.displayName == "") then
            return false
        end
        if type(character.classID) ~= "nil"
            and (not addon.dbRuntime.IsCleanType(character.classID, "number")
                or not IsFiniteNumber(character.classID) or character.classID <= 0
                or character.classID ~= math.floor(character.classID)) then
            return false
        end
        if type(character.lastSeen) ~= "nil"
            and (not addon.dbRuntime.IsCleanType(character.lastSeen, "number")
                or not IsFiniteNumber(character.lastSeen)) then
            return false
        end
        if type(character.defaultProfileID) ~= "nil"
            and (not addon.dbRuntime.IsCleanType(character.defaultProfileID, "string")
                or not addon.dbRuntime.IsCleanTable(profiles[character.defaultProfileID])) then
            return false
        end
        if type(character.specProfiles) ~= "nil" then
            if not addon.dbRuntime.IsCleanTable(character.specProfiles) then return false end
            for specID, assignedProfileID in pairs(character.specProfiles) do
                if not addon.dbRuntime.IsCleanType(specID, "number")
                    or not IsFiniteNumber(specID) or specID <= 0
                    or specID ~= math.floor(specID)
                    or not addon.dbRuntime.IsCleanType(assignedProfileID, "string")
                    or not addon.dbRuntime.IsCleanTable(profiles[assignedProfileID]) then
                    return false
                end
            end
        end
    end
    return true, account, profileID, profile.settings
end

function addon.dbRuntime.Invalidate()
    addon.dbRuntime.rootRef = nil
    addon.dbRuntime.validatedRootRef = nil
end

function addon.dbRuntime.CacheValidatedRegistry(root, account, defaultProfileID)
    addon.dbRuntime.validatedRootRef = root
    addon.dbRuntime.validatedAccountRef = account
    addon.dbRuntime.validatedProfilesRef = rawget(root, "profiles")
    addon.dbRuntime.validatedRoleTemplatesRef = rawget(root, "roleTemplates")
    addon.dbRuntime.validatedCharactersRef = rawget(root, "characters")
    addon.dbRuntime.validatedDefaultProfileID = defaultProfileID
    addon.dbRuntime.validatedDefaultProfileRef = addon.dbRuntime.validatedProfilesRef[defaultProfileID]
end

-- Frequent UI mutations only need to prove that the already-validated registry
-- boundaries and active payload identities did not move. Structural profile/character
-- operations must call Invalidate(), which forces the full graph validator once.
function addon.dbRuntime.CanReuseRegistryValidation(root, activeProfileID, activeSettings)
    if not rawequal(root, addon.dbRuntime.validatedRootRef) then return false end
    local account = rawget(root, "account")
    local profiles = rawget(root, "profiles")
    if not rawequal(account, addon.dbRuntime.validatedAccountRef)
        or not rawequal(profiles, addon.dbRuntime.validatedProfilesRef)
        or not rawequal(rawget(root, "roleTemplates"), addon.dbRuntime.validatedRoleTemplatesRef)
        or not rawequal(rawget(root, "characters"), addon.dbRuntime.validatedCharactersRef) then
        return false
    end
    local idOK, defaultUnchanged = pcall(function()
        return account.defaultProfileID == addon.dbRuntime.validatedDefaultProfileID
    end)
    if not idOK or not defaultUnchanged
        or not rawequal(profiles[addon.dbRuntime.validatedDefaultProfileID],
            addon.dbRuntime.validatedDefaultProfileRef) then
        return false
    end
    local activeProfile = activeProfileID and profiles[activeProfileID] or nil
    return type(activeProfile) == "table"
        and rawequal(activeProfile, addon.dbRuntime.validatedActiveProfileRef)
        and rawequal(activeProfile.settings, activeSettings)
end

function addon.dbRuntime.Refresh()
    local root = EnsureStatsProDBTable()
    local previousRoot = addon.dbRuntime.rootRef
    local previousSettings = addon.dbRuntime.activeSettings
    local previousProfileID = addon.dbRuntime.activeProfileID
    local version, versionReadable = NormalizeDBVersion(root.dbVersion)
    local valid, account, defaultProfileID

    addon.dbRuntime.version = version
    addon.dbRuntime.versionDisplay = versionReadable and string.format("%d", version) or "<unavailable>"
    addon.dbRuntime.mode = version > CURRENT_DB_VERSION and "future" or "legacy"
    addon.dbRuntime.readOnly = version > CURRENT_DB_VERSION
    addon.dbRuntime.registryReady = false
    addon.dbRuntime.activeAccount = root
    addon.dbRuntime.activeSettings = root
    addon.dbRuntime.activeProfileID = nil

    if rawequal(addon.dbRuntime.migrationFailedRoot, root) then
        addon.dbRuntime.mode = "corrupt"
        addon.dbRuntime.readOnly = true
    elseif version == CURRENT_DB_VERSION then
        if addon.dbRuntime.CanReuseRegistryValidation(root, previousProfileID, previousSettings) then
            valid = true
            account = addon.dbRuntime.validatedAccountRef
            defaultProfileID = addon.dbRuntime.validatedDefaultProfileID
        else
            valid, account, defaultProfileID = addon.dbRuntime.ValidateRegistry(root)
            if valid then
                addon.dbRuntime.CacheValidatedRegistry(root, account, defaultProfileID)
            else
                addon.dbRuntime.migrationFailedRoot = root
            end
        end
        if valid then
            local requestedProfileID = previousProfileID
            local requestedProfile = requestedProfileID and root.profiles[requestedProfileID] or nil
            addon.dbRuntime.activeProfileID = type(requestedProfile) == "table"
                and type(requestedProfile.settings) == "table" and requestedProfileID or defaultProfileID
            local activeProfile = root.profiles[addon.dbRuntime.activeProfileID]
            addon.dbRuntime.activeAccount = account
            addon.dbRuntime.activeSettings = activeProfile.settings
            addon.dbRuntime.validatedActiveProfileRef = activeProfile
            addon.dbRuntime.registryReady = true
            addon.dbRuntime.mode = "current"
            addon.dbRuntime.readOnly = false
        else
            addon.dbRuntime.mode = "corrupt"
            addon.dbRuntime.readOnly = true
        end
    end

    addon.dbRuntime.rootRef = root
    if not rawequal(previousRoot, root)
        or not rawequal(previousSettings, addon.dbRuntime.activeSettings)
        or previousProfileID ~= addon.dbRuntime.activeProfileID then
        addon.dbRuntime.generation = addon.dbRuntime.generation + 1
    end
    if not addon.dbRuntime.readOnly then addon.dbRuntime.warned = false end
    return root
end

function addon.dbRuntime.GetRoot()
    local root = EnsureStatsProDBTable()
    if not rawequal(root, addon.dbRuntime.rootRef) then addon.dbRuntime.Refresh() end
    return root
end

function addon.dbRuntime.GetActiveSettings()
    local root = EnsureStatsProDBTable()
    if not rawequal(root, addon.dbRuntime.rootRef) then addon.dbRuntime.Refresh() end
    if addon.dbRuntime.readOnly then return addon.dbRuntime.readFallback end
    return addon.dbRuntime.activeSettings or root
end

function addon.dbRuntime.GetAccount()
    local root = EnsureStatsProDBTable()
    if not rawequal(root, addon.dbRuntime.rootRef) then addon.dbRuntime.Refresh() end
    if addon.dbRuntime.readOnly then return addon.dbRuntime.readFallback end
    return addon.dbRuntime.activeAccount or root
end

function addon.dbRuntime.ActivateProfile(profileID)
    local root = addon.dbRuntime.Refresh()
    if addon.dbRuntime.readOnly or not addon.dbRuntime.registryReady
        or not addon.dbRuntime.IsCleanType(profileID, "string") then
        return false, false
    end
    local profile = root.profiles[profileID]
    if not addon.dbRuntime.IsCleanTable(profile)
        or not addon.dbRuntime.IsCleanTable(profile.settings) then
        return false, false
    end
    if addon.dbRuntime.activeProfileID == profileID
        and rawequal(addon.dbRuntime.activeSettings, profile.settings) then
        return true, false
    end
    addon.dbRuntime.activeProfileID = profileID
    addon.dbRuntime.activeSettings = profile.settings
    addon.dbRuntime.activeAccount = root.account
    addon.dbRuntime.validatedActiveProfileRef = profile
    addon.dbRuntime.generation = addon.dbRuntime.generation + 1
    return true, true
end

function addon.dbRuntime.GetSettingStore(key)
    if addon.dbRuntime.accountSettingKeys[key] then return addon.dbRuntime.GetAccount() end
    return addon.dbRuntime.GetActiveSettings()
end

function addon.dbRuntime.ShowReadOnlyGuidance(showGuidance)
    if showGuidance == true and not addon.dbRuntime.warned then
        addon.dbRuntime.warned = true
        PrintMsg(L("Settings are read-only because they were saved by a newer StatsPro version. Update StatsPro to change them."))
    end
end

function addon.dbRuntime.GetWritableRoot(showGuidance)
    local root = addon.dbRuntime.Refresh()
    if not addon.dbRuntime.readOnly and not addon.profileRuntime.BlocksUserWrites() then
        return root
    end
    if addon.dbRuntime.readOnly then addon.dbRuntime.ShowReadOnlyGuidance(showGuidance) end
    return nil
end

function addon.dbRuntime.GetWritableSettings(showGuidance, key)
    addon.dbRuntime.Refresh()
    if not addon.dbRuntime.readOnly and not addon.profileRuntime.BlocksUserWrites() then
        return addon.dbRuntime.GetSettingStore(key)
    end
    if addon.dbRuntime.readOnly then addon.dbRuntime.ShowReadOnlyGuidance(showGuidance) end
    return nil
end

function addon.dbRuntime.GetWritableAccount(showGuidance)
    addon.dbRuntime.Refresh()
    if not addon.dbRuntime.readOnly and not addon.profileRuntime.BlocksUserWrites() then
        return addon.dbRuntime.GetAccount()
    end
    if addon.dbRuntime.readOnly then addon.dbRuntime.ShowReadOnlyGuidance(showGuidance) end
    return nil
end

function addon.dbRuntime.ReplaceTableContents(target, source)
    for key in pairs(target) do target[key] = nil end
    for key, value in pairs(source) do target[key] = value end
end

function addon.dbRuntime.BuildRegistry(flat)
    local settings = {}
    for key, value in pairs(flat) do
        if type(key) == "string"
            and not addon.dbRuntime.registryRootKeys[key]
            and not addon.dbRuntime.accountSettingKeys[key]
            and not addon.dbRuntime.legacySettingKeys[key] then
            local cloned, clonedOK = addon.dbRuntime.CloneSerializable(value)
            if not clonedOK then return nil end
            settings[key] = cloned
        end
    end
    if type(flat.fontBeforeAutoSwitch) ~= "nil" then
        local savedFont, savedOK = addon.dbRuntime.CloneSerializable(flat.fontBeforeAutoSwitch)
        if not savedOK then return nil end
        settings.fontBeforeAutoSwitch = savedFont
    end
    local registry = {
        dbVersion = CURRENT_DB_VERSION,
        account = {
            forceLocale = addon.NormalizeForceLocale(flat.forceLocale),
            updateInterval = NormalizeNumberSetting("updateInterval", flat.updateInterval),
            defaultProfileID = "p1",
            nextProfileID = 2,
        },
        profiles = {
            p1 = { name = "Default", settings = settings },
        },
        roleTemplates = { TANK = "p1", HEALER = "p1", DAMAGER = "p1" },
        characters = {},
    }
    if not addon.dbRuntime.ValidateRegistry(registry) then return nil end
    return registry
end

function addon.profileRuntime.ReadCombatState()
    local ok, value = pcall(InCombatLockdown)
    if not ok then return nil end
    local secretOK, secret = pcall(issecretvalue, value)
    if not secretOK or secret or type(value) ~= "boolean" then return nil end
    return value
end

function addon.profileRuntime.ReadPlayerContext()
    addon.profileRuntime.contextReadCount = addon.profileRuntime.contextReadCount + 1
    if type(UnitGUID) ~= "function" then return nil, "unavailable" end
    local guidOK, guid = pcall(UnitGUID, "player")
    if not guidOK or not addon.dbRuntime.IsCleanType(guid, "string") or guid == "" then
        return nil, "unknown"
    end

    local getSpecIndex = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization
        or GetSpecialization
    if type(getSpecIndex) ~= "function" then return nil, "unknown" end
    local indexOK, specIndex = pcall(getSpecIndex)
    if not indexOK then return nil, "unknown" end
    local indexSecretOK, indexSecret = pcall(issecretvalue, specIndex)
    if not indexSecretOK or indexSecret then return nil, "unknown" end
    if type(specIndex) == "nil" then return nil, "no-spec" end
    if type(specIndex) ~= "number" or not IsFiniteNumber(specIndex)
        or specIndex <= 0 or specIndex ~= math.floor(specIndex) then
        return nil, "unknown"
    end

    local getSpecInfo = C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo
        or GetSpecializationInfo
    if type(getSpecInfo) ~= "function" then return nil, "unknown" end
    local infoOK, specID, specName, _, _, role = pcall(getSpecInfo, specIndex)
    if not infoOK or not addon.dbRuntime.IsCleanType(specID, "number")
        or not IsFiniteNumber(specID) or specID <= 0 or specID ~= math.floor(specID) then
        return nil, "unknown"
    end

    local context = { guid = guid, specID = specID }
    if addon.dbRuntime.IsCleanType(specName, "string") and specName ~= "" then
        context.specName = specName
    end
    if addon.dbRuntime.IsCleanType(role, "string")
        and (role == "TANK" or role == "HEALER" or role == "DAMAGER") then
        context.role = role
    end

    if type(UnitFullName) == "function" then
        local nameOK, name, realm = pcall(UnitFullName, "player")
        if nameOK and addon.dbRuntime.IsCleanType(name, "string") and name ~= "" then
            if addon.dbRuntime.IsCleanType(realm, "string") and realm ~= "" then
                context.displayName = name .. "-" .. realm
            else
                context.displayName = name
            end
        end
    end
    if type(UnitClass) == "function" then
        local classOK, _, _, classID = pcall(UnitClass, "player")
        if classOK and addon.dbRuntime.IsCleanType(classID, "number")
            and IsFiniteNumber(classID) and classID > 0 and classID == math.floor(classID) then
            context.classID = classID
        end
    end
    if type(GetServerTime) == "function" then
        local timeOK, lastSeen = pcall(GetServerTime)
        if timeOK and addon.dbRuntime.IsCleanType(lastSeen, "number")
            and IsFiniteNumber(lastSeen) and lastSeen >= 0
            and lastSeen == math.floor(lastSeen) then
            context.lastSeen = lastSeen
        end
    end
    return context, "valid"
end

function addon.profileRuntime.ShallowCopy(source)
    local copy = {}
    for key, value in pairs(source) do copy[key] = value end
    return copy
end

function addon.profileRuntime.AllocateProfileID(account, profiles)
    local number = account.nextProfileID
    if not addon.dbRuntime.IsCleanType(number, "number")
        or number < 2 or number >= addon.dbRuntime.maxProfileNumber
        or number ~= math.floor(number) then
        return nil
    end
    local profileID = "p" .. tostring(number)
    if profiles[profileID] ~= nil then return nil end
    account.nextProfileID = number + 1
    return profileID
end

function addon.profileRuntime.ProfileName(context, suffix)
    local base = context.displayName or "Character"
    if suffix == "default" then return base .. " - Default" end
    return base .. " - " .. (context.specName or string.format("Spec %d", context.specID))
end

function addon.profileRuntime.CloneProfile(sourceProfile, name)
    if not addon.dbRuntime.IsCleanTable(sourceProfile)
        or not addon.dbRuntime.IsCleanTable(sourceProfile.settings) then
        return nil
    end
    local settings, copied = addon.dbRuntime.CloneSerializable(sourceProfile.settings)
    if not copied then return nil end
    return { name = name, settings = settings }
end

function addon.profileRuntime.PrepareContextTransaction(context)
    local root = addon.dbRuntime.Refresh()
    if addon.dbRuntime.readOnly or not addon.dbRuntime.registryReady then return nil, nil end
    local currentCharacter = root.characters[context.guid]
    local existingProfileID = currentCharacter and currentCharacter.specProfiles
        and currentCharacter.specProfiles[context.specID] or nil
    if addon.dbRuntime.IsCleanType(existingProfileID, "string")
        and addon.dbRuntime.IsCleanTable(root.profiles[existingProfileID]) then
        local metadataChanged = (context.displayName and context.displayName ~= currentCharacter.displayName)
            or (context.classID and context.classID ~= currentCharacter.classID)
            or (context.lastSeen and context.lastSeen ~= currentCharacter.lastSeen)
        if not metadataChanged then return nil, existingProfileID end
        local character, copied = addon.dbRuntime.CloneSerializable(currentCharacter)
        if not copied then return nil, nil end
        if context.displayName then character.displayName = context.displayName end
        if context.classID then character.classID = context.classID end
        if context.lastSeen then character.lastSeen = context.lastSeen end
        local characters = addon.profileRuntime.ShallowCopy(root.characters)
        characters[context.guid] = character
        local candidate = addon.profileRuntime.ShallowCopy(root)
        candidate.characters = characters
        if not addon.dbRuntime.ValidateRegistry(candidate) then return nil, nil end
        return {
            root = root,
            oldAccount = root.account,
            oldProfiles = root.profiles,
            oldCharacters = root.characters,
            account = root.account,
            profiles = root.profiles,
            characters = characters,
        }, existingProfileID
    end

    local account, accountCopied = addon.dbRuntime.CloneSerializable(root.account)
    if not accountCopied or type(account) ~= "table"
        or not addon.dbRuntime.IsCleanTable(account)
        or type(account.defaultProfileID) ~= "string"
        or not addon.dbRuntime.IsCleanType(account.defaultProfileID, "string") then
        return nil, nil
    end
    local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
    local characters = addon.profileRuntime.ShallowCopy(root.characters)
    local character
    if currentCharacter then
        local characterCopied
        character, characterCopied = addon.dbRuntime.CloneSerializable(currentCharacter)
        if not characterCopied or type(character) ~= "table" then return nil, nil end
    else
        local defaultSource = profiles[account.defaultProfileID]
        local defaultProfileID = addon.profileRuntime.AllocateProfileID(account, profiles)
        if type(defaultProfileID) ~= "string"
            or not addon.dbRuntime.IsCleanType(defaultProfileID, "string") then return nil, nil end
        local defaultProfile = addon.profileRuntime.CloneProfile(
            defaultSource, addon.profileRuntime.ProfileName(context, "default"))
        if type(defaultProfile) ~= "table" then return nil, nil end
        profiles[defaultProfileID] = defaultProfile
        character = { defaultProfileID = defaultProfileID, specProfiles = {} }
    end
    if not addon.dbRuntime.IsCleanTable(character) then return nil, nil end
    if type(character.specProfiles) ~= "table" then character.specProfiles = {} end

    local sourceProfileID = context.role and root.roleTemplates[context.role] or nil
    if type(sourceProfileID) ~= "string" then sourceProfileID = account.defaultProfileID end
    local sourceProfile = profiles[sourceProfileID]
    if type(sourceProfile) ~= "table" then return nil, nil end
    local specProfileID = addon.profileRuntime.AllocateProfileID(account, profiles)
    if type(specProfileID) ~= "string"
        or not addon.dbRuntime.IsCleanType(specProfileID, "string") then return nil, nil end
    local specProfile = addon.profileRuntime.CloneProfile(
        sourceProfile, addon.profileRuntime.ProfileName(context, "spec"))
    if type(specProfile) ~= "table" then return nil, nil end
    profiles[specProfileID] = specProfile
    character.specProfiles[context.specID] = specProfileID
    if context.displayName then character.displayName = context.displayName end
    if context.classID then character.classID = context.classID end
    if context.lastSeen then character.lastSeen = context.lastSeen end
    characters[context.guid] = character

    local candidate = addon.profileRuntime.ShallowCopy(root)
    candidate.account = account
    candidate.profiles = profiles
    candidate.characters = characters
    local valid = addon.dbRuntime.ValidateRegistry(candidate)
    if not valid then return nil, nil end
    return {
        root = root,
        oldAccount = root.account,
        oldProfiles = root.profiles,
        oldCharacters = root.characters,
        account = account,
        profiles = profiles,
        characters = characters,
    }, specProfileID
end

function addon.profileRuntime.CommitTransaction(transaction)
    if not transaction then return true end
    local root = transaction.root
    root.account = transaction.account
    root.profiles = transaction.profiles
    if transaction.roleTemplates then root.roleTemplates = transaction.roleTemplates end
    root.characters = transaction.characters
    addon.dbRuntime.Invalidate()
    addon.profileRuntime.structuralCommitCount = addon.profileRuntime.structuralCommitCount + 1
    return true
end

function addon.profileRuntime.RollbackTransaction(transaction)
    if not transaction then return end
    local root = transaction.root
    root.account = transaction.oldAccount
    root.profiles = transaction.oldProfiles
    if transaction.oldRoleTemplates then root.roleTemplates = transaction.oldRoleTemplates end
    root.characters = transaction.oldCharacters
    addon.dbRuntime.Invalidate()
    addon.dbRuntime.Refresh()
end

function addon.profileRuntime.CloseOwnedSettingsModals()
    local close = addon.profileRuntime.closeOwnedSettingsModals
    if type(close) ~= "function" then return true end
    local ok = pcall(close)
    return ok
end

function addon.profileRuntime.ActivateResolvedContext(context, transaction, profileID, initializing)
    local runtime = addon.profileRuntime
    local oldProfileID = addon.dbRuntime.activeProfileID
    local oldSettings = addon.dbRuntime.activeSettings
    local oldGUID, oldSpecID = runtime.activeGUID, runtime.activeSpecID
    local oldDisplayName, oldSpecName, oldRole =
        runtime.activeDisplayName, runtime.activeSpecName, runtime.activeRole

    runtime.transitioning = true
    runtime.suppressIntermediateRefresh = true
    if not initializing and addon.dbRuntime.IsCleanTable(oldSettings) then
        local saveOK = type(runtime.saveActivePositions) ~= "function"
            or pcall(runtime.saveActivePositions, oldSettings)
        if not saveOK then
            runtime.suppressIntermediateRefresh = false
            runtime.transitioning = false
            addon.profileUI.RefreshSafe()
            return false
        end
        if not runtime.CloseOwnedSettingsModals() then
            runtime.suppressIntermediateRefresh = false
            runtime.transitioning = false
            addon.profileUI.RefreshSafe()
            return false
        end
    end
    runtime.suppressIntermediateRefresh = false

    runtime.CommitTransaction(transaction)
    local activated = addon.dbRuntime.ActivateProfile(profileID)
    if not activated then
        runtime.RollbackTransaction(transaction)
        addon.dbRuntime.ActivateProfile(oldProfileID)
        runtime.transitioning = false
        addon.profileUI.RefreshSafe()
        return false
    end

    local targetSettings = addon.dbRuntime.activeSettings
    local targetSnapshot, copied = addon.dbRuntime.CloneSerializable(targetSettings)
    if not copied then
        runtime.RollbackTransaction(transaction)
        addon.dbRuntime.ActivateProfile(oldProfileID)
        runtime.transitioning = false
        addon.profileUI.RefreshSafe()
        return false
    end

    local applied = true
    if not initializing and type(runtime.applyActiveSettings) == "function" then
        applied = pcall(runtime.applyActiveSettings)
    end
    if not applied then
        if targetSnapshot and addon.dbRuntime.IsCleanTable(targetSettings) then
            wipe(targetSettings)
            for key, value in pairs(targetSnapshot) do targetSettings[key] = value end
            addon.dbRuntime.Invalidate()
        end
        runtime.RollbackTransaction(transaction)
        addon.dbRuntime.ActivateProfile(oldProfileID)
        runtime.activeGUID, runtime.activeSpecID = oldGUID, oldSpecID
        runtime.activeDisplayName, runtime.activeSpecName, runtime.activeRole =
            oldDisplayName, oldSpecName, oldRole
        if type(runtime.applyActiveSettings) == "function" then
            pcall(runtime.applyActiveSettings)
        end
        runtime.transitioning = false
        addon.profileUI.RefreshSafe()
        return false
    end

    runtime.activeGUID = context.guid
    runtime.activeSpecID = context.specID
    local activeRoot = addon.dbRuntime.rootRef
    local activeCharacter = transaction and transaction.characters
        and transaction.characters[context.guid]
        or (activeRoot and activeRoot.characters and activeRoot.characters[context.guid])
    runtime.activeDisplayName = context.displayName
        or (activeCharacter and activeCharacter.displayName)
    runtime.activeSpecName = context.specName
    runtime.activeRole = context.role
    if context.specName then runtime.knownSpecNames[context.specID] = context.specName end
    runtime.forceReapply = false
    runtime.forceReapplyRetryCount = 0
    runtime.forceReapplyRetryToken = nil
    runtime.pendingResolution = false
    runtime.activationCount = runtime.activationCount + 1
    runtime.transitioning = false
    addon.profileUI.RefreshSafe()
    return true
end

function addon.profileRuntime.ResolveCurrent(initializing)
    local runtime = addon.profileRuntime
    local combat = runtime.ReadCombatState()
    if combat ~= false then
        runtime.pendingResolution = true
        addon.profileUI.RefreshSafe()
        return false
    end
    local context, contextStatus = runtime.ReadPlayerContext()
    if not context then
        if contextStatus == "unavailable" then
            runtime.pendingResolution = false
        elseif contextStatus == "no-spec" and runtime.settlingNoSpec then
            runtime.pendingResolution = false
        else
            runtime.pendingResolution = true
            if contextStatus == "no-spec" and runtime.noSpecRetryToken == nil then
                local token = runtime.requestGeneration
                runtime.noSpecRetryToken = token
                C_Timer.After(0.1, function()
                    if runtime.noSpecRetryToken ~= token then return end
                    runtime.noSpecRetryToken = nil
                    if runtime.requestGeneration ~= token then return end
                    runtime.settlingNoSpec = true
                    runtime.ResolveCurrent(false)
                    runtime.settlingNoSpec = false
                end)
            end
        end
        addon.profileUI.RefreshSafe()
        return false
    end
    runtime.noSpecRetryToken = nil

    local root = addon.dbRuntime.Refresh()
    if addon.dbRuntime.readOnly or not addon.dbRuntime.registryReady then
        runtime.pendingResolution = true
        addon.profileUI.RefreshSafe()
        return false
    end
    local character = root.characters and root.characters[context.guid]
    local mappedProfileID = character and character.specProfiles
        and character.specProfiles[context.specID] or nil
    if runtime.activeGUID == context.guid and runtime.activeSpecID == context.specID
        and addon.dbRuntime.activeProfileID == mappedProfileID then
        if runtime.forceReapply then
            runtime.transitioning = true
            local journal = addon.profileOps.CaptureMutationJournal(addon.dbRuntime.activeSettings)
            local applied = journal and type(runtime.applyActiveSettings) == "function"
                and pcall(runtime.applyActiveSettings)
            if not applied and journal then addon.profileOps.RestoreMutationJournal(journal) end
            runtime.transitioning = false
            if not applied then
                runtime.pendingResolution = true
                runtime.forceReapplyRetryCount = runtime.forceReapplyRetryCount + 1
                if runtime.forceReapplyRetryCount <= 3
                    and runtime.forceReapplyRetryToken == nil then
                    local retryToken = {}
                    runtime.forceReapplyRetryToken = retryToken
                    C_Timer.After(math.min(0.25 * runtime.forceReapplyRetryCount, 1), function()
                        if runtime.forceReapplyRetryToken ~= retryToken then return end
                        runtime.forceReapplyRetryToken = nil
                        runtime.ResolveCurrent(false)
                    end)
                end
                addon.profileUI.RefreshSafe()
                return false
            end
            runtime.forceReapply = false
            runtime.forceReapplyRetryCount = 0
            runtime.forceReapplyRetryToken = nil
            runtime.pendingResolution = false
            addon.profileUI.RefreshSafe()
            return true
        end
        -- A same-context event is still allowed to enrich late character/spec metadata.
        -- Do not reapply the profile payload or disturb open settings controls.
        local transaction, profileID = runtime.PrepareContextTransaction(context)
        if profileID ~= mappedProfileID then
            runtime.pendingResolution = true
            addon.profileUI.RefreshSafe()
            return false
        end
        runtime.CommitTransaction(transaction)
        local updatedCharacter = transaction and transaction.characters[context.guid] or character
        runtime.activeDisplayName = context.displayName
            or (updatedCharacter and updatedCharacter.displayName)
            or runtime.activeDisplayName
        runtime.activeSpecName = context.specName or runtime.activeSpecName
        runtime.activeRole = context.role or runtime.activeRole
        if context.specName then runtime.knownSpecNames[context.specID] = context.specName end
        runtime.pendingResolution = false
        addon.profileUI.RefreshSafe()
        return true
    end

    local transaction, profileID = runtime.PrepareContextTransaction(context)
    if not addon.dbRuntime.IsCleanType(profileID, "string") then
        runtime.pendingResolution = true
        addon.profileUI.RefreshSafe()
        return false
    end
    return runtime.ActivateResolvedContext(context, transaction, profileID, initializing)
end

function addon.profileRuntime.RequestResolution(immediate)
    local runtime = addon.profileRuntime
    if type(UnitGUID) ~= "function" then
        runtime.pendingResolution = false
        addon.profileUI.RefreshSafe()
        return false
    end
    runtime.pendingResolution = true
    runtime.requestGeneration = runtime.requestGeneration + 1
    runtime.noSpecRetryToken = nil
    addon.profileUI.RefreshSafe()
    if immediate then return runtime.ResolveCurrent(true) end
    if runtime.scheduledToken ~= nil then return true end
    local token = runtime.requestGeneration
    runtime.scheduledToken = token
    C_Timer.After(0, function()
        if runtime.scheduledToken ~= token then return end
        runtime.scheduledToken = nil
        runtime.ResolveCurrent(false)
    end)
    return true
end

function addon.profileRuntime.ResolvePending()
    local runtime = addon.profileRuntime
    if not runtime.pendingResolution and runtime.scheduledToken == nil then return false end
    runtime.requestGeneration = runtime.requestGeneration + 1
    runtime.scheduledToken = nil
    runtime.noSpecRetryToken = nil
    return runtime.ResolveCurrent(false)
end

function addon.profileOps.ShouldFail(stage)
    if addon.__statsproSmoke ~= true or addon.profileOps.testFailureStage ~= stage then
        return false
    end
    addon.profileOps.testFailureStage = nil
    return true
end

function addon.profileOps.ValidateName(rawName, profiles, exceptProfileID)
    if not addon.dbRuntime.IsCleanType(rawName, "string") then return nil, "invalid-name" end
    local name = rawName:match("^ *(.-) *$")
    if name == "" then return nil, "invalid-name" end

    local index, byteCount, codepoints = 1, #name, 0
    while index <= byteCount do
        local first = string.byte(name, index)
        local length, secondMin, secondMax = 1, nil, nil
        local codepoint = first
        if first < 0x80 then
            if first < 0x20 or first == 0x7F or first == 0x7C then
                return nil, "invalid-name"
            end
        elseif first >= 0xC2 and first <= 0xDF then
            length, secondMin, secondMax = 2, 0x80, 0xBF
        elseif first == 0xE0 then
            length, secondMin, secondMax = 3, 0xA0, 0xBF
        elseif (first >= 0xE1 and first <= 0xEC)
            or (first >= 0xEE and first <= 0xEF) then
            length, secondMin, secondMax = 3, 0x80, 0xBF
        elseif first == 0xED then
            length, secondMin, secondMax = 3, 0x80, 0x9F
        elseif first == 0xF0 then
            length, secondMin, secondMax = 4, 0x90, 0xBF
        elseif first >= 0xF1 and first <= 0xF3 then
            length, secondMin, secondMax = 4, 0x80, 0xBF
        elseif first == 0xF4 then
            length, secondMin, secondMax = 4, 0x80, 0x8F
        else
            return nil, "invalid-name"
        end
        if length > 1 then
            local second = string.byte(name, index + 1)
            if not second or second < secondMin or second > secondMax then
                return nil, "invalid-name"
            end
            for offset = 2, length - 1 do
                local continuation = string.byte(name, index + offset)
                if not continuation or continuation < 0x80 or continuation > 0xBF then
                    return nil, "invalid-name"
                end
            end
            if length == 2 then
                codepoint = (first - 0xC0) * 0x40 + (second - 0x80)
            elseif length == 3 then
                codepoint = (first - 0xE0) * 0x1000
                    + (second - 0x80) * 0x40 + (string.byte(name, index + 2) - 0x80)
            else
                codepoint = (first - 0xF0) * 0x40000
                    + (second - 0x80) * 0x1000
                    + (string.byte(name, index + 2) - 0x80) * 0x40
                    + (string.byte(name, index + 3) - 0x80)
            end
        end
        if (codepoint >= 0x80 and codepoint <= 0x9F) or codepoint == 0xA0
            or codepoint == 0xAD or codepoint == 0x61C
            or (codepoint >= 0x200B and codepoint <= 0x200F)
            or codepoint == 0x2028 or codepoint == 0x2029
            or (codepoint >= 0x202A and codepoint <= 0x202E)
            or (codepoint >= 0x2060 and codepoint <= 0x2069)
            or codepoint == 0xFEFF then
            return nil, "invalid-name"
        end
        index = index + length
        codepoints = codepoints + 1
        if codepoints > addon.profileOps.maxNameCodepoints then
            return nil, "name-too-long"
        end
    end

    for profileID, profile in pairs(profiles or {}) do
        if profileID ~= exceptProfileID and profile.name == name then
            return nil, "duplicate-name"
        end
    end
    return name, codepoints
end

function addon.profileOps.BuildDefaultSettings()
    local settings, copied = addon.dbRuntime.CloneSerializable(defaults)
    if not copied then return nil end
    settings.forceLocale = nil
    settings.updateInterval = nil
    return settings
end

function addon.profileOps.CountReferences(root, profileID)
    local counts = {
        specs = 0,
        characterDefaults = 0,
        accountDefault = 0,
        roleTemplates = 0,
        total = 0,
    }
    if root.account.defaultProfileID == profileID then counts.accountDefault = 1 end
    for _, assignedProfileID in pairs(root.roleTemplates) do
        if assignedProfileID == profileID then
            counts.roleTemplates = counts.roleTemplates + 1
        end
    end
    for _, character in pairs(root.characters) do
        if character.defaultProfileID == profileID then
            counts.characterDefaults = counts.characterDefaults + 1
        end
        for _, assignedProfileID in pairs(character.specProfiles or {}) do
            if assignedProfileID == profileID then counts.specs = counts.specs + 1 end
        end
    end
    counts.total = counts.specs + counts.characterDefaults
        + counts.accountDefault + counts.roleTemplates
    return counts
end

function addon.profileOps.BuildProfileCatalog(root, assignmentCounts)
    local catalog = {}
    for profileID, profile in pairs(root.profiles) do
        local references = addon.profileOps.CountReferences(root, profileID)
        catalog[#catalog + 1] = {
            profileID = profileID,
            name = profile.name,
            assignmentCount = assignmentCounts and assignmentCounts[profileID]
                or references.specs,
            references = references,
            isActive = profileID == addon.dbRuntime.activeProfileID,
        }
    end
    table.sort(catalog, function(left, right)
        if left.name ~= right.name then return left.name < right.name end
        local leftNumber = tonumber(left.profileID:match("^p(%d+)$")) or math.huge
        local rightNumber = tonumber(right.profileID:match("^p(%d+)$")) or math.huge
        return leftNumber < rightNumber
    end)
    return catalog
end

function addon.profileOps.ResolveAssignment(root, guid, specID)
    if not addon.dbRuntime.IsCleanType(guid, "string") or guid == "" then return nil end
    local character = root.characters[guid]
    if not addon.dbRuntime.IsCleanTable(character) then return nil end
    if specID == nil then
        return character.defaultProfileID or root.account.defaultProfileID
    end
    if not addon.dbRuntime.IsCleanType(specID, "number") or not IsFiniteNumber(specID)
        or specID <= 0 or specID ~= math.floor(specID) then return nil end
    return character.specProfiles and character.specProfiles[specID] or nil
end

function addon.profileOps.ReadCurrentGUID()
    if type(UnitGUID) ~= "function" then return nil end
    local ok, guid = pcall(UnitGUID, "player")
    if not ok or not addon.dbRuntime.IsCleanType(guid, "string") or guid == "" then return nil end
    return guid
end

function addon.profileOps.ContextIsActive(guid, specID)
    return guid == addon.profileRuntime.activeGUID
        and specID ~= nil and specID == addon.profileRuntime.activeSpecID
end

function addon.profileOps.CheckExpected(root, expected)
    if type(expected) ~= "table" then return true end
    if expected.rootRef and not rawequal(root, expected.rootRef) then return false end
    if expected.generation and expected.generation ~= addon.dbRuntime.generation then return false end
    if expected.profilesRef and not rawequal(root.profiles, expected.profilesRef) then return false end
    if expected.roleTemplatesRef
        and not rawequal(root.roleTemplates, expected.roleTemplatesRef) then return false end
    if expected.activeProfileID
        and expected.activeProfileID ~= addon.dbRuntime.activeProfileID then return false end
    if expected.profileID and expected.profileRef
        and not rawequal(root.profiles[expected.profileID], expected.profileRef) then return false end
    if expected.profileID and expected.settingsRef
        and (not root.profiles[expected.profileID]
            or not rawequal(root.profiles[expected.profileID].settings,
                expected.settingsRef)) then return false end
    if expected.guid and expected.assignmentID
        and addon.profileOps.ResolveAssignment(root, expected.guid, expected.specID)
            ~= expected.assignmentID then
        return false
    end
    if expected.guid and expected.characterRef
        and not rawequal(root.characters[expected.guid], expected.characterRef) then return false end
    return true
end

function addon.profileOps.Gate(expected, internal)
    local runtime = addon.profileRuntime
    if addon.profileOps.inProgress and not internal then return nil, "busy" end
    if runtime.transitioning then return nil, "busy" end
    local combat = runtime.ReadCombatState()
    if combat == true then return nil, "combat" end
    if combat ~= false then return nil, "unsafe-context" end
    local root = addon.dbRuntime.Refresh()
    if addon.dbRuntime.readOnly or not addon.dbRuntime.registryReady then
        return nil, "read-only"
    end
    if runtime.pendingResolution or runtime.scheduledToken ~= nil
        or runtime.noSpecRetryToken ~= nil then
        return nil, "pending"
    end
    if not addon.profileOps.CheckExpected(root, expected) then return nil, "stale" end
    return root
end

function addon.profileOps.NewTransaction(root)
    return {
        root = root,
        oldAccount = root.account,
        oldProfiles = root.profiles,
        oldRoleTemplates = root.roleTemplates,
        oldCharacters = root.characters,
        account = root.account,
        profiles = root.profiles,
        roleTemplates = root.roleTemplates,
        characters = root.characters,
    }
end

function addon.profileOps.BuildCandidate(transaction)
    local candidate = addon.profileRuntime.ShallowCopy(transaction.root)
    candidate.account = transaction.account
    candidate.profiles = transaction.profiles
    candidate.roleTemplates = transaction.roleTemplates
    candidate.characters = transaction.characters
    return candidate
end

function addon.profileOps.CapturePositionFields(settings)
    local snapshot = {}
    for _, key in ipairs(addon.profileOps.positionKeys) do
        snapshot[key] = { present = rawget(settings, key) ~= nil, value = rawget(settings, key) }
    end
    return snapshot
end

function addon.profileOps.RestorePositionFields(settings, snapshot)
    if not settings or not snapshot then return end
    for _, key in ipairs(addon.profileOps.positionKeys) do
        local entry = snapshot[key]
        settings[key] = entry and entry.present and entry.value or nil
    end
end

function addon.profileOps.CaptureMutationJournal(rootTable)
    local journal = { entries = {}, visited = {} }
    local function capture(value)
        if type(value) ~= "table" or journal.visited[value] then return end
        journal.visited[value] = true
        local values = {}
        for key, child in pairs(value) do
            values[key] = child
            if type(child) == "table" then capture(child) end
        end
        journal.entries[#journal.entries + 1] = { target = value, values = values }
    end
    capture(rootTable)
    return journal
end

function addon.profileOps.RestoreMutationJournal(journal)
    if not journal then return end
    for _, entry in ipairs(journal.entries) do
        for key in pairs(entry.target) do entry.target[key] = nil end
        for key, value in pairs(entry.values) do entry.target[key] = value end
    end
end

function addon.profileOps.ResolveCandidateActiveProfileID(transaction, fallbackProfileID)
    local guid, specID = addon.profileRuntime.activeGUID, addon.profileRuntime.activeSpecID
    if guid and specID then
        local character = transaction.characters[guid]
        if not character then return nil end
        local profileID = character.specProfiles and character.specProfiles[specID]
            or character.defaultProfileID or transaction.account.defaultProfileID
        if transaction.profiles[profileID] then return profileID end
        return nil
    end
    if transaction.profiles[fallbackProfileID] then return fallbackProfileID end
    if transaction.profiles[transaction.account.defaultProfileID] then
        return transaction.account.defaultProfileID
    end
    return nil
end

function addon.profileOps.Execute(expected, builder)
    local root, gateReason = addon.profileOps.Gate(expected, false)
    if not root then return false, gateReason end
    addon.profileOps.inProgress = true

    local function finish(ok, result)
        addon.profileOps.inProgress = false
        addon.profileRuntime.transitioning = false
        addon.profileUI.RefreshSafe()
        return ok, result
    end

    if not addon.profileRuntime.CloseOwnedSettingsModals() then
        return finish(false, "close-failed")
    end
    root, gateReason = addon.profileOps.Gate(expected, true)
    if not root then return finish(false, gateReason) end

    local oldProfileID = addon.dbRuntime.activeProfileID
    local oldSettings = addon.dbRuntime.activeSettings
    local positionSnapshot = addon.profileOps.CapturePositionFields(oldSettings)
    if type(addon.profileRuntime.saveActivePositions) == "function"
        and not pcall(addon.profileRuntime.saveActivePositions, oldSettings) then
        addon.profileOps.RestorePositionFields(oldSettings, positionSnapshot)
        return finish(false, "position-failed")
    end

    local built, transaction, buildStatus, result = pcall(builder, root)
    if not built or not transaction then
        addon.profileOps.RestorePositionFields(oldSettings, positionSnapshot)
        return finish(false, built and buildStatus or "prepare-failed")
    end
    local desiredProfileID = addon.profileOps.ResolveCandidateActiveProfileID(
        transaction, oldProfileID)
    if not desiredProfileID then
        addon.profileOps.RestorePositionFields(oldSettings, positionSnapshot)
        return finish(false, "active-orphan")
    end
    local desiredProfile = transaction.profiles[desiredProfileID]
    local reapply = desiredProfileID ~= oldProfileID
        or not rawequal(desiredProfile.settings, oldSettings)
    if not addon.dbRuntime.ValidateRegistry(addon.profileOps.BuildCandidate(transaction))
        or addon.profileOps.ShouldFail("validate") then
        addon.profileOps.RestorePositionFields(oldSettings, positionSnapshot)
        return finish(false, "validate-failed")
    end

    addon.profileRuntime.transitioning = true
    if addon.profileOps.ShouldFail("commit") then
        transaction.root.account = transaction.account
        transaction.root.profiles = transaction.profiles
        if transaction.roleTemplates then
            transaction.root.roleTemplates = transaction.roleTemplates
        end
        transaction.root.characters = transaction.characters
        addon.profileRuntime.RollbackTransaction(transaction)
        addon.profileOps.RestorePositionFields(oldSettings, positionSnapshot)
        addon.dbRuntime.ActivateProfile(oldProfileID)
        return finish(false, "commit-failed")
    end

    addon.profileRuntime.CommitTransaction(transaction)
    if reapply then
        local activated = addon.dbRuntime.ActivateProfile(desiredProfileID)
        if not activated then
            addon.profileRuntime.RollbackTransaction(transaction)
            addon.profileOps.RestorePositionFields(oldSettings, positionSnapshot)
            addon.dbRuntime.ActivateProfile(oldProfileID)
            return finish(false, "activate-failed")
        end
        local targetSettings = addon.dbRuntime.activeSettings
        local targetJournal = addon.profileOps.CaptureMutationJournal(targetSettings)
        local applied = not addon.profileOps.ShouldFail("apply")
            and type(addon.profileRuntime.applyActiveSettings) == "function"
            and pcall(addon.profileRuntime.applyActiveSettings)
        if not applied then
            addon.profileOps.RestoreMutationJournal(targetJournal)
            addon.profileRuntime.RollbackTransaction(transaction)
            addon.profileOps.RestorePositionFields(oldSettings, positionSnapshot)
            addon.dbRuntime.ActivateProfile(oldProfileID)
            local rollbackJournal = addon.profileOps.CaptureMutationJournal(oldSettings)
            local rollbackApplied = false
            if type(addon.profileRuntime.applyActiveSettings) == "function" then
                rollbackApplied = pcall(addon.profileRuntime.applyActiveSettings)
            end
            if not rollbackApplied then
                addon.profileOps.RestoreMutationJournal(rollbackJournal)
                addon.profileRuntime.forceReapply = true
                addon.profileRuntime.forceReapplyRetryCount = 0
                addon.profileRuntime.pendingResolution = true
                addon.profileRuntime.transitioning = false
                addon.profileRuntime.RequestResolution(false)
                return finish(false, "rollback-apply-failed")
            end
            return finish(false, "apply-failed")
        end
    else
        addon.dbRuntime.Refresh()
    end

    addon.profileOps.operationCount = addon.profileOps.operationCount + 1
    return finish(true, result)
end

-- Full wipe is intentionally a root-pointer transaction rather than a component
-- swap. Replacing only account/profiles/characters would leave the v9 flat downgrade
-- shadow and any unknown root fields behind, so it would not actually erase all
-- StatsPro data. The old root stays untouched and can be restored by identity if
-- activation or runtime application fails.
function addon.profileOps.ExecuteRootReplacement(expected, builder)
    local root, gateReason = addon.profileOps.Gate(expected, false)
    if not root then return false, gateReason end
    addon.profileOps.inProgress = true

    local function finish(ok, result)
        addon.profileOps.inProgress = false
        addon.profileRuntime.transitioning = false
        addon.profileUI.RefreshSafe()
        return ok, result
    end

    if not addon.profileRuntime.CloseOwnedSettingsModals() then
        return finish(false, "close-failed")
    end
    root, gateReason = addon.profileOps.Gate(expected, true)
    if not root then return finish(false, gateReason) end

    local oldRoot = root
    local oldProfileID = addon.dbRuntime.activeProfileID
    local oldSettings = addon.dbRuntime.activeSettings
    local positionSnapshot = addon.profileOps.CapturePositionFields(oldSettings)
    if type(addon.profileRuntime.saveActivePositions) == "function"
        and not pcall(addon.profileRuntime.saveActivePositions, oldSettings) then
        addon.profileOps.RestorePositionFields(oldSettings, positionSnapshot)
        return finish(false, "position-failed")
    end

    local built, freshRoot, buildStatus, result = pcall(builder, oldRoot)
    if not built or not freshRoot then
        addon.profileOps.RestorePositionFields(oldSettings, positionSnapshot)
        return finish(false, built and buildStatus or "prepare-failed")
    end
    local valid, _, desiredProfileID = addon.dbRuntime.ValidateRegistry(freshRoot)
    if not valid or not desiredProfileID or addon.profileOps.ShouldFail("validate") then
        addon.profileOps.RestorePositionFields(oldSettings, positionSnapshot)
        return finish(false, "validate-failed")
    end

    local function publishFreshRoot()
        _G.StatsProDB = freshRoot
        addon.dbRuntime.Invalidate()
        addon.dbRuntime.Refresh()
    end

    local function restoreOldRoot(reapply)
        _G.StatsProDB = oldRoot
        addon.dbRuntime.Invalidate()
        addon.dbRuntime.Refresh()
        addon.profileOps.RestorePositionFields(oldSettings, positionSnapshot)
        if not addon.dbRuntime.ActivateProfile(oldProfileID) then return false end
        if not reapply then return true end
        local rollbackJournal = addon.profileOps.CaptureMutationJournal(oldSettings)
        local rollbackApplied = type(addon.profileRuntime.applyActiveSettings) == "function"
            and pcall(addon.profileRuntime.applyActiveSettings)
        if rollbackApplied then return true end
        addon.profileOps.RestoreMutationJournal(rollbackJournal)
        addon.profileRuntime.forceReapply = true
        addon.profileRuntime.forceReapplyRetryCount = 0
        addon.profileRuntime.pendingResolution = true
        addon.profileRuntime.transitioning = false
        addon.profileRuntime.RequestResolution(false)
        return false
    end

    addon.profileRuntime.transitioning = true
    if addon.profileOps.ShouldFail("commit") then
        publishFreshRoot()
        restoreOldRoot(false)
        return finish(false, "commit-failed")
    end

    publishFreshRoot()
    addon.profileRuntime.structuralCommitCount =
        addon.profileRuntime.structuralCommitCount + 1
    if not addon.dbRuntime.ActivateProfile(desiredProfileID) then
        restoreOldRoot(false)
        return finish(false, "activate-failed")
    end
    local applied = not addon.profileOps.ShouldFail("apply")
        and type(addon.profileRuntime.applyActiveSettings) == "function"
        and pcall(addon.profileRuntime.applyActiveSettings)
    if not applied then
        if not restoreOldRoot(true) then
            return finish(false, "rollback-apply-failed")
        end
        return finish(false, "apply-failed")
    end

    addon.profileRuntime.forceReapply = false
    addon.profileRuntime.forceReapplyRetryCount = 0
    addon.profileRuntime.pendingResolution = false
    addon.profileOps.operationCount = addon.profileOps.operationCount + 1
    return finish(true, result)
end

function addon.profileOps.UniqueProfileName(baseName, profiles)
    local name = addon.profileOps.ValidateName(baseName, profiles)
    if name then return name end
    for suffix = 2, 9999 do
        local candidate = baseName .. " " .. suffix
        name = addon.profileOps.ValidateName(candidate, profiles)
        if name then return name end
    end
    return nil
end

function addon.profileOps.Create(name, expected)
    return addon.profileOps.Execute(expected, function(root)
        local normalized, nameStatus = addon.profileOps.ValidateName(name, root.profiles)
        if not normalized then return nil, nameStatus end
        local account, copied = addon.dbRuntime.CloneSerializable(root.account)
        if not copied or not addon.dbRuntime.IsCleanTable(account) then
            return nil, "clone-failed"
        end
        local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
        local profileID = addon.profileRuntime.AllocateProfileID(account, profiles)
        local settings = addon.profileOps.BuildDefaultSettings()
        if not profileID or not settings then return nil, "clone-failed" end
        profiles[profileID] = { name = normalized, settings = settings }
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.account = account
        transaction.profiles = profiles
        return transaction, { reapply = false }, profileID
    end)
end

function addon.profileOps.Duplicate(sourceProfileID, name, expected)
    return addon.profileOps.Execute(expected, function(root)
        local source = root.profiles[sourceProfileID]
        if not source then return nil, "missing-profile" end
        local normalized, nameStatus = addon.profileOps.ValidateName(name, root.profiles)
        if not normalized then return nil, nameStatus end
        local account, copied = addon.dbRuntime.CloneSerializable(root.account)
        local duplicate = addon.profileRuntime.CloneProfile(source, normalized)
        if not copied or not duplicate then return nil, "clone-failed" end
        local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
        local profileID = addon.profileRuntime.AllocateProfileID(account, profiles)
        if not profileID then return nil, "id-exhausted" end
        profiles[profileID] = duplicate
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.account = account
        transaction.profiles = profiles
        return transaction, { reapply = false }, profileID
    end)
end

function addon.profileOps.Rename(profileID, name, expected)
    return addon.profileOps.Execute(expected, function(root)
        local profile = root.profiles[profileID]
        if not profile then return nil, "missing-profile" end
        local normalized, nameStatus = addon.profileOps.ValidateName(
            name, root.profiles, profileID)
        if not normalized then return nil, nameStatus end
        if profile.name == normalized then return nil, "no-change" end
        local renamed = addon.profileRuntime.ShallowCopy(profile)
        renamed.name = normalized
        local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
        profiles[profileID] = renamed
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.profiles = profiles
        return transaction, { reapply = false }, profileID
    end)
end

function addon.profileOps.CopySettings(sourceProfileID, targetProfileID, scope, expected)
    if type(scope) == "table" and expected == nil then
        expected, scope = scope, "all"
    end
    scope = scope or "all"
    return addon.profileOps.Execute(expected, function(root)
        if sourceProfileID == targetProfileID then return nil, "same-profile" end
        local source, target = root.profiles[sourceProfileID], root.profiles[targetProfileID]
        if not source or not target then return nil, "missing-profile" end
        if not addon.dbRuntime.IsCleanTable(source.settings)
            or not addon.dbRuntime.IsCleanTable(target.settings) then
            return nil, "clone-failed"
        end
        local settings, copied
        if scope == "all" then
            settings, copied = addon.dbRuntime.CloneSerializable(source.settings)
            if copied and addon.dbRuntime.IsCleanTable(settings) then
                settings.forceLocale = nil
                settings.updateInterval = nil
            end
        else
            local scopeKeys = addon.profileOps.copyScopeKeys[scope]
            if not scopeKeys then return nil, "invalid-scope" end
            settings, copied = addon.dbRuntime.CloneSerializable(target.settings)
            if copied and addon.dbRuntime.IsCleanTable(settings) then
                for key in pairs(scopeKeys) do
                    local sourceValue = source.settings[key]
                    if sourceValue == nil then
                        settings[key] = nil
                    else
                        local copiedValue, valueCopied =
                            addon.dbRuntime.CloneSerializable(sourceValue)
                        if not valueCopied then return nil, "clone-failed" end
                        settings[key] = copiedValue
                    end
                end
                if scope == "stats" then
                    settings.appearancePresetID = "custom"
                end
            end
        end
        if not copied or not addon.dbRuntime.IsCleanTable(settings) then
            return nil, "clone-failed"
        end
        local changedTarget = addon.profileRuntime.ShallowCopy(target)
        changedTarget.settings = settings
        local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
        profiles[targetProfileID] = changedTarget
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.profiles = profiles
        return transaction, {
            reapply = targetProfileID == addon.dbRuntime.activeProfileID,
            activeProfileID = addon.dbRuntime.activeProfileID,
        }, targetProfileID
    end)
end

function addon.profileOps.Assign(guid, specID, profileID, expected)
    return addon.profileOps.Execute(expected, function(root)
        if not root.profiles[profileID] then return nil, "missing-profile" end
        local character = root.characters[guid]
        if not character then return nil, "missing-context" end
        local oldAssignment = addon.profileOps.ResolveAssignment(root, guid, specID)
        if not oldAssignment then return nil, "missing-context" end
        if oldAssignment == profileID then return nil, "same-profile" end
        local changedCharacter, copied = addon.dbRuntime.CloneSerializable(character)
        if not copied or type(changedCharacter) ~= "table"
            or not addon.dbRuntime.IsCleanTable(changedCharacter) then
            return nil, "clone-failed"
        end
        if specID == nil then
            changedCharacter.defaultProfileID = profileID
        else
            local specProfiles = rawget(changedCharacter, "specProfiles")
            if type(specProfiles) ~= "table" or not addon.dbRuntime.IsCleanTable(specProfiles)
                or not specProfiles[specID] then return nil, "missing-context" end
            specProfiles[specID] = profileID
        end
        local characters = addon.profileRuntime.ShallowCopy(root.characters)
        characters[guid] = changedCharacter
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.characters = characters
        local active = addon.profileOps.ContextIsActive(guid, specID)
        return transaction, {
            reapply = active,
            activeProfileID = active and profileID or addon.dbRuntime.activeProfileID,
        }, profileID
    end)
end

function addon.profileOps.UseProfileForKnownSpecs(guid, profileID, expected)
    return addon.profileOps.Execute(expected, function(root)
        if not addon.dbRuntime.IsCleanType(guid, "string") or guid == "" then
            return nil, "missing-context"
        end
        if not addon.dbRuntime.IsCleanType(profileID, "string")
            or not root.profiles[profileID] then return nil, "missing-profile" end
        local character = root.characters[guid]
        if type(character) ~= "table"
            or not addon.dbRuntime.IsCleanTable(character) then return nil, "missing-context" end
        local sourceSpecProfiles = rawget(character, "specProfiles")
        if type(sourceSpecProfiles) ~= "table"
            or not addon.dbRuntime.IsCleanTable(sourceSpecProfiles) then return nil, "missing-context" end
        local changedCharacter, copied = addon.dbRuntime.CloneSerializable(character)
        if not copied or type(changedCharacter) ~= "table"
            or not addon.dbRuntime.IsCleanTable(changedCharacter) then
            return nil, "clone-failed"
        end
        local specProfiles = rawget(changedCharacter, "specProfiles")
        if type(specProfiles) ~= "table"
            or not addon.dbRuntime.IsCleanTable(specProfiles) then return nil, "clone-failed" end
        local knownCount, changedCount = 0, 0
        for specID, assignedProfileID in pairs(specProfiles) do
            knownCount = knownCount + 1
            if assignedProfileID ~= profileID then
                specProfiles[specID] = profileID
                changedCount = changedCount + 1
            end
        end
        if knownCount == 0 then return nil, "missing-context" end
        if changedCount == 0 then return nil, "no-change" end
        local characters = addon.profileRuntime.ShallowCopy(root.characters)
        characters[guid] = changedCharacter
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.characters = characters
        return transaction, { reapply = guid == addon.profileRuntime.activeGUID }, {
            profileID = profileID,
            changedCount = changedCount,
        }
    end)
end

function addon.profileOps.MakeKnownSpecsIndependent(guid, expected)
    return addon.profileOps.Execute(expected, function(root)
        if not addon.dbRuntime.IsCleanType(guid, "string") or guid == "" then
            return nil, "missing-context"
        end
        local character = root.characters[guid]
        if type(character) ~= "table" or not addon.dbRuntime.IsCleanTable(character) then
            return nil, "missing-context"
        end
        local sourceSpecProfiles = rawget(character, "specProfiles")
        if type(sourceSpecProfiles) ~= "table"
            or not addon.dbRuntime.IsCleanTable(sourceSpecProfiles) then return nil, "missing-context" end
        local assignmentCounts = addon.profileOps.CountSpecAssignments(root)
        local affectedSpecs = {}
        for specID, sourceProfileID in pairs(sourceSpecProfiles) do
            if (assignmentCounts[sourceProfileID] or 0) > 1 then
                affectedSpecs[#affectedSpecs + 1] = specID
            end
        end
        table.sort(affectedSpecs)
        if #affectedSpecs == 0 then return nil, "no-change" end

        local account, accountCopied = addon.dbRuntime.CloneSerializable(root.account)
        local changedCharacter, characterCopied = addon.dbRuntime.CloneSerializable(character)
        if not accountCopied or type(account) ~= "table"
            or not addon.dbRuntime.IsCleanTable(account)
            or not characterCopied or type(changedCharacter) ~= "table"
            or not addon.dbRuntime.IsCleanTable(changedCharacter) then
            return nil, "clone-failed"
        end
        local changedSpecProfiles = rawget(changedCharacter, "specProfiles")
        if type(changedSpecProfiles) ~= "table"
            or not addon.dbRuntime.IsCleanTable(changedSpecProfiles) then
            return nil, "clone-failed"
        end
        local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
        local assignments = {}
        local changedCount = 0
        for _, specID in ipairs(affectedSpecs) do
            local sourceProfileID = changedSpecProfiles[specID]
            local sourceProfile = profiles[sourceProfileID]
            if type(sourceProfile) ~= "table"
                or not addon.dbRuntime.IsCleanTable(sourceProfile) then
                return nil, "missing-profile"
            end
            local profileID = addon.profileRuntime.AllocateProfileID(account, profiles)
            if not profileID then return nil, "id-exhausted" end
            local context = {
                displayName = character.displayName,
                specID = specID,
                specName = addon.profileRuntime.knownSpecNames[specID],
            }
            local name = addon.profileRuntime.ProfileName(context, "spec")
            for _, profile in pairs(profiles) do
                if profile.name == name then
                    name = name .. " [" .. profileID .. "]"
                    break
                end
            end
            local clone = addon.profileRuntime.CloneProfile(sourceProfile, name)
            if type(clone) ~= "table"
                or not addon.dbRuntime.IsCleanTable(clone) then return nil, "clone-failed" end
            profiles[profileID] = clone
            changedSpecProfiles[specID] = profileID
            assignments[specID] = profileID
            changedCount = changedCount + 1
        end
        if changedCount ~= #affectedSpecs then return nil, "clone-failed" end
        local characters = addon.profileRuntime.ShallowCopy(root.characters)
        characters[guid] = changedCharacter
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.account = account
        transaction.profiles = profiles
        transaction.characters = characters
        return transaction, { reapply = guid == addon.profileRuntime.activeGUID }, {
            assignments = assignments,
            changedCount = changedCount,
        }
    end)
end

function addon.profileOps.SetRoleTemplate(role, profileID, expected)
    return addon.profileOps.Execute(expected, function(root)
        if not addon.dbRuntime.IsCleanType(role, "string")
            or not addon.profileOps.roleKeys[role] then return nil, "invalid-role" end
        if not addon.dbRuntime.IsCleanType(profileID, "string")
            or not root.profiles[profileID] then return nil, "missing-profile" end
        if root.roleTemplates[role] == profileID then return nil, "no-change" end
        local roleTemplates = addon.profileRuntime.ShallowCopy(root.roleTemplates)
        roleTemplates[role] = profileID
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.roleTemplates = roleTemplates
        return transaction, { reapply = false }, {
            role = role,
            profileID = profileID,
        }
    end)
end

function addon.profileOps.Swap(left, right, expected)
    return addon.profileOps.Execute(expected, function(root)
        if type(left) ~= "table" or type(right) ~= "table"
            or (left.guid == right.guid and left.specID == right.specID) then
            return nil, "same-context"
        end
        local leftProfileID = addon.profileOps.ResolveAssignment(root, left.guid, left.specID)
        local rightProfileID = addon.profileOps.ResolveAssignment(root, right.guid, right.specID)
        if not leftProfileID or not rightProfileID then return nil, "missing-context" end
        if leftProfileID == rightProfileID then return nil, "same-profile" end
        local characters = addon.profileRuntime.ShallowCopy(root.characters)
        local changed = {}
        for _, context in ipairs({ left, right }) do
            if not changed[context.guid] then
                local character, copied = addon.dbRuntime.CloneSerializable(root.characters[context.guid])
                if not copied or not addon.dbRuntime.IsCleanTable(character) then
                    return nil, "clone-failed"
                end
                changed[context.guid] = character
                characters[context.guid] = character
            end
        end
        local function setAssignment(context, profileID)
            local character = changed[context.guid]
            if context.specID == nil then
                character.defaultProfileID = profileID
            else
                character.specProfiles[context.specID] = profileID
            end
        end
        setAssignment(left, rightProfileID)
        setAssignment(right, leftProfileID)
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.characters = characters
        local leftActive = addon.profileOps.ContextIsActive(left.guid, left.specID)
        local rightActive = addon.profileOps.ContextIsActive(right.guid, right.specID)
        local activeProfileID = addon.dbRuntime.activeProfileID
        if leftActive then activeProfileID = rightProfileID end
        if rightActive then activeProfileID = leftProfileID end
        return transaction, {
            reapply = leftActive or rightActive,
            activeProfileID = activeProfileID,
        }, { left = rightProfileID, right = leftProfileID }
    end)
end

function addon.profileOps.ResetCurrent(expectedActiveProfileID, expected)
    return addon.profileOps.Execute(expected, function(root)
        local profileID = addon.dbRuntime.activeProfileID
        if profileID ~= expectedActiveProfileID then return nil, "stale" end
        local profile = root.profiles[profileID]
        if not profile then return nil, "missing-profile" end
        local settings = addon.profileOps.BuildDefaultSettings()
        if not settings then return nil, "clone-failed" end
        local resetProfile = addon.profileRuntime.ShallowCopy(profile)
        resetProfile.settings = settings
        local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
        profiles[profileID] = resetProfile
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.profiles = profiles
        return transaction, { reapply = true, activeProfileID = profileID }, profileID
    end)
end

function addon.profileOps.ImportAndAssign(importedSettings, expected)
    return addon.profileOps.Execute(expected, function(root)
        local guid = addon.profileRuntime.activeGUID
        local specID = addon.profileRuntime.activeSpecID
        if type(guid) ~= "string" or not addon.dbRuntime.IsCleanType(guid, "string")
            or guid == "" or type(specID) ~= "number"
            or not addon.dbRuntime.IsCleanType(specID, "number")
            or not IsFiniteNumber(specID) or specID <= 0
            or specID ~= math.floor(specID) then
            return nil, "missing-context"
        end
        local character = root.characters[guid]
        if type(character) ~= "table" or not addon.dbRuntime.IsCleanTable(character) then
            return nil, "missing-context"
        end
        local changedCharacter, characterCopied =
            addon.dbRuntime.CloneSerializable(character)
        local account, accountCopied = addon.dbRuntime.CloneSerializable(root.account)
        local settings, settingsCopied = addon.dbRuntime.CloneSerializable(importedSettings)
        if not characterCopied or type(changedCharacter) ~= "table"
            or not addon.dbRuntime.IsCleanTable(changedCharacter)
            or not accountCopied or type(account) ~= "table"
            or not addon.dbRuntime.IsCleanTable(account)
            or not settingsCopied or type(settings) ~= "table"
            or not addon.dbRuntime.IsCleanTable(settings) then
            return nil, "clone-failed"
        end
        local specProfiles = rawget(changedCharacter, "specProfiles")
        if type(specProfiles) ~= "table" then return nil, "missing-context" end
        if not addon.dbRuntime.IsCleanTable(specProfiles)
            or not specProfiles[specID] then return nil, "missing-context" end

        -- Account locale/update cadence belong to StatsPro as a whole, not to the
        -- imported character/spec profile. Candidate extraction can carry them only
        -- in its detached account record; never leak them into profile settings.
        settings.forceLocale = nil
        settings.updateInterval = nil
        local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
        local profileID = addon.profileRuntime.AllocateProfileID(account, profiles)
        if not profileID then return nil, "id-exhausted" end
        local name = addon.profileOps.UniqueProfileName("SwiftStats Import", profiles)
        if not name then return nil, "duplicate-name" end
        profiles[profileID] = { name = name, settings = settings }
        specProfiles[specID] = profileID
        local characters = addon.profileRuntime.ShallowCopy(root.characters)
        characters[guid] = changedCharacter
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.account = account
        transaction.profiles = profiles
        transaction.characters = characters
        return transaction, {
            reapply = true,
            activeProfileID = profileID,
        }, { profileID = profileID, name = name }
    end)
end

function addon.profileOps.FullWipe(expected)
    return addon.profileOps.ExecuteRootReplacement(expected, function()
        local guid = addon.profileRuntime.activeGUID
        local specID = addon.profileRuntime.activeSpecID
        if type(guid) ~= "string" or not addon.dbRuntime.IsCleanType(guid, "string")
            or guid == "" or type(specID) ~= "number"
            or not addon.dbRuntime.IsCleanType(specID, "number")
            or not IsFiniteNumber(specID) or specID <= 0
            or specID ~= math.floor(specID) then
            return nil, "missing-context"
        end
        local freshRoot = addon.dbRuntime.BuildRegistry(defaults)
        if type(freshRoot) ~= "table" or not addon.dbRuntime.IsCleanTable(freshRoot) then
            return nil, "clone-failed"
        end
        local character = {
            defaultProfileID = "p1",
            specProfiles = { [specID] = "p1" },
        }
        if addon.dbRuntime.IsCleanType(addon.profileRuntime.activeDisplayName, "string") then
            character.displayName = addon.profileRuntime.activeDisplayName
        end
        freshRoot.characters[guid] = character
        if not addon.dbRuntime.ValidateRegistry(freshRoot) then
            return nil, "validate-failed"
        end
        return freshRoot, nil, "p1"
    end)
end

function addon.profileOps.DeleteWithReplacement(profileID, replacementProfileID, expected)
    return addon.profileOps.Execute(expected, function(root)
        if not root.profiles[profileID] then return nil, "missing-profile" end
        if replacementProfileID == profileID then return nil, "same-profile" end
        local profileCount = 0
        for _ in pairs(root.profiles) do profileCount = profileCount + 1 end
        if profileCount <= 1 then return nil, "last-profile" end
        local references = addon.profileOps.CountReferences(root, profileID)
        if references.total > 0 then
            if not root.profiles[replacementProfileID] then
                return nil, "replacement-required"
            end
        elseif profileID == addon.dbRuntime.activeProfileID
            and not root.profiles[replacementProfileID] then
            return nil, "replacement-required"
        elseif replacementProfileID ~= nil and not root.profiles[replacementProfileID] then
            return nil, "missing-profile"
        end

        local transaction = addon.profileOps.NewTransaction(root)
        local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
        profiles[profileID] = nil
        transaction.profiles = profiles
        if references.accountDefault > 0 then
            local account, copied = addon.dbRuntime.CloneSerializable(root.account)
            if not copied or type(account) ~= "table"
                or not addon.dbRuntime.IsCleanTable(account) then return nil, "clone-failed" end
            account.defaultProfileID = replacementProfileID
            transaction.account = account
        end
        if references.roleTemplates > 0 then
            local roleTemplates = addon.profileRuntime.ShallowCopy(root.roleTemplates)
            for role, assignedProfileID in pairs(roleTemplates) do
                if assignedProfileID == profileID then roleTemplates[role] = replacementProfileID end
            end
            transaction.roleTemplates = roleTemplates
        end
        if references.specs > 0 or references.characterDefaults > 0 then
            local characters = addon.profileRuntime.ShallowCopy(root.characters)
            for guid, character in pairs(root.characters) do
                local needsClone = character.defaultProfileID == profileID
                if not needsClone then
                    for _, assignedProfileID in pairs(character.specProfiles or {}) do
                        if assignedProfileID == profileID then needsClone = true; break end
                    end
                end
                if needsClone then
                    local changedCharacter, copied = addon.dbRuntime.CloneSerializable(character)
                    if not copied or type(changedCharacter) ~= "table"
                        or not addon.dbRuntime.IsCleanTable(changedCharacter) then
                        return nil, "clone-failed"
                    end
                    if changedCharacter.defaultProfileID == profileID then
                        changedCharacter.defaultProfileID = replacementProfileID
                    end
                    local specProfiles = rawget(changedCharacter, "specProfiles")
                    if type(specProfiles) ~= "table"
                        or not addon.dbRuntime.IsCleanTable(specProfiles) then
                        return nil, "clone-failed"
                    end
                    for specID, assignedProfileID in pairs(specProfiles) do
                        if assignedProfileID == profileID then
                            specProfiles[specID] = replacementProfileID
                        end
                    end
                    characters[guid] = changedCharacter
                end
            end
            transaction.characters = characters
        end
        local active = profileID == addon.dbRuntime.activeProfileID
        return transaction, {
            reapply = active,
            activeProfileID = active and replacementProfileID or addon.dbRuntime.activeProfileID,
        }, replacementProfileID
    end)
end

function addon.profileOps.ForgetCharacter(guid, expected)
    return addon.profileOps.Execute(expected, function(root)
        local currentGUID = addon.profileOps.ReadCurrentGUID()
        if not currentGUID then return nil, "unsafe-context" end
        if guid == currentGUID then return nil, "current-character" end
        if not root.characters[guid] then return nil, "missing-context" end
        local characters = addon.profileRuntime.ShallowCopy(root.characters)
        characters[guid] = nil
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.characters = characters
        return transaction, { reapply = false }, guid
    end)
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
    cached.displayMode = addon.NormalizeDisplayMode(GetDB("displayMode"))
    cached.labelStyle = NormalizeLabelStyle(GetDB("labelStyle"))
    cached.targetSnapshot = addon.archonTargets.NormalizeSnapshotKey(GetDB("targetSnapshot"))
    -- WHY runtime clamp: corrupt SavedVariables should not make text invisible,
    -- spam OnUpdate, or break font/scale arithmetic. Do not write back here; UI
    -- slider commits remain the only normal path that mutates SavedVariables.
    cached.textAlpha = GetNumberDB("textAlpha") / 100
    cached.panelBackgroundAlpha = GetNumberDB("panelBackgroundAlpha") / 100
    cached.textOutlineStyle = addon.readabilityConfig.getTextOutlineStyleDB()

    -- Resolve labels for the active output locale.
    -- WHY reference, not copy: LABELS_BY_LOCALE entries are never mutated; reference
    -- assignment is O(1) vs O(n) deep copy. WARNING: never mutate cached.activeLabels —
    -- it is a REFERENCE to the LABELS_BY_LOCALE entry.
    local activeLocale = ResolveActiveLocale()
    cached.activeLabels = LABELS_BY_LOCALE[activeLocale] or LABELS_BY_LOCALE.enUS
    cached.activeLabelsLocale = LABELS_BY_LOCALE[activeLocale] and activeLocale or "enUS"

    -- Color → hex string lookup. Iterate defaults.colors (single source of truth) to
    -- guarantee non-nil colorStrings for every key — eliminates the need for `or "ffffff"`
    -- fallbacks throughout the render pipeline.
    local db = addon.dbRuntime.GetActiveSettings()
    local userColors = type(db.colors) == "table" and db.colors or {}
    userColors = addon.appearancePresets.ResolveValue("colors", userColors)
    for name, defaultColor in pairs(defaults.colors) do
        local r, g, b = NormalizeColor(userColors[name], defaultColor)
        cached.colorStrings[name] = RGBToHex(r, g, b)
    end
end

local function MigrateDB(dbOverride)
    local destination = dbOverride or EnsureStatsProDBTable()
    local dbVersion = NormalizeDBVersion(destination.dbVersion)
    if dbVersion > CURRENT_DB_VERSION then return false end
    if dbVersion == CURRENT_DB_VERSION then
        local valid = addon.dbRuntime.ValidateRegistry(destination)
        if rawequal(destination, EnsureStatsProDBTable()) then
            if valid then
                addon.dbRuntime.migrationFailedRoot = nil
            else
                addon.dbRuntime.migrationFailedRoot = destination
            end
            addon.dbRuntime.Invalidate()
        end
        return valid == true
    end

    -- Build every legacy transformation and the complete registry off to the side.
    -- The live flat root remains the exact downgrade shadow; only reserved registry
    -- fields are attached after validation, with dbVersion committed last.
    local db = addon.dbRuntime.CloneMigrationWork(destination, dbVersion)
    if type(db) ~= "table" then
        if rawequal(destination, EnsureStatsProDBTable()) then
            addon.dbRuntime.migrationFailedRoot = destination
            addon.dbRuntime.Invalidate()
        end
        return false
    end

    local preDefaultShowDurability = db.showDurability
    local preDefaultShowRepairCost = db.showRepairCost

    -- WHY runs before the current-version early-return: legacy migrants (from SwiftStats or the
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
    if not FontPathKey(db.font) then db.font = defaults.font end
    if type(db.fontBeforeAutoSwitch) ~= "nil"
        and not FontPathKey(db.fontBeforeAutoSwitch) then
        db.fontBeforeAutoSwitch = nil
    end

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

    -- The detached working copy now represents the effective v9 flat settings.
    -- BuildRegistry deep-copies known profile fields again, preventing aliases with
    -- both the live downgrade shadow and the migration work table.
    db.dbVersion = 9
    local registry = addon.dbRuntime.BuildRegistry(db)
    if not registry then
        if rawequal(destination, EnsureStatsProDBTable()) then
            addon.dbRuntime.migrationFailedRoot = destination
            addon.dbRuntime.Invalidate()
        end
        return false
    end

    destination.account = registry.account
    destination.profiles = registry.profiles
    destination.roleTemplates = registry.roleTemplates
    destination.characters = registry.characters
    destination.dbVersion = CURRENT_DB_VERSION
    if rawequal(destination, EnsureStatsProDBTable()) then
        addon.dbRuntime.migrationFailedRoot = nil
        addon.dbRuntime.Invalidate()
    end
    return true
end

-- SwiftStats migration is intentionally field-driven. Legacy SavedVariables are
-- external input: never iterate their keys or retain their tables, because unknown
-- fields, cyclic tables, and later source-addon mutations must not enter StatsProDB.
addon.legacyImport = {
    publicBooleanKeys = {
        "isVisible", "isLocked", "showRating", "showPercentage",
        "showTertiary", "hideZeroTertiary", "showLeech", "showAvoidance",
        "showSpeed", "showStrength", "showAgility", "showIntellect",
        "matchValueColorToStat",
    },
    publicNumberKeys = { "scale", "fontSize", "updateInterval" },
    publicColorKeys = {
        "crit", "haste", "mastery", "versatility", "rating", "percentage",
        "leech", "avoidance", "speed", "primary",
    },
    localLegacyBooleanKeys = {
        "useLocalizedLabels", "showStrength", "showAgility", "showIntellect",
    },
    localLegacyColorKeys = { "primary", "strength", "agility", "intellect" },
    allowedStrings = {
        displayMode = { flat = true, sectioned = true, split = true },
        labelStyle = { full = true, short = true, hidden = true },
        targetSnapshot = { mythicPlus = true, raid = true },
        textOutlineStyle = { none = true, outline = true, thick = true },
    },
}

function addon.legacyImport.IsCleanType(value, expectedType)
    local ok, secret = pcall(issecretvalue, value)
    if not ok or secret or type(value) ~= expectedType then return false end
    if expectedType == "number" then return IsFiniteNumber(value) end
    if expectedType == "table" then
        if type(_G.issecrettable) == "function" then
            local tableOK, secretTable = pcall(_G.issecrettable, value)
            if not tableOK or secretTable then return false end
        end
        -- A secret/inaccessible table can still report type "table". Probe with
        -- rawget inside pcall before any field read; metatables remain bypassed.
        if not pcall(rawget, value, "__statspro_import_access_probe") then return false end
    end
    return true
end

function addon.legacyImport.SafeRawGet(source, key)
    if not addon.legacyImport.IsCleanType(source, "table") then return nil, false end
    local ok, value = pcall(rawget, source, key)
    if not ok then return nil, false end
    return value, true
end

function addon.legacyImport.CopyBoolean(source, candidate, key)
    local value = addon.legacyImport.SafeRawGet(source, key)
    if not addon.legacyImport.IsCleanType(value, "boolean") then return false end
    candidate[key] = value
    return true
end

function addon.legacyImport.CopyNumberSetting(source, candidate, key)
    local value = addon.legacyImport.SafeRawGet(source, key)
    if not addon.legacyImport.IsCleanType(value, "number") then return false end
    candidate[key] = NormalizeNumberSetting(key, value)
    return true
end

function addon.legacyImport.CopyPosition(source, candidate, prefix)
    prefix = prefix or ""
    local point = addon.legacyImport.SafeRawGet(source, prefix .. "point")
    local relativePoint = addon.legacyImport.SafeRawGet(source, prefix .. "relativePoint")
    local xOfs = addon.legacyImport.SafeRawGet(source, prefix .. "xOfs")
    local yOfs = addon.legacyImport.SafeRawGet(source, prefix .. "yOfs")
    if not addon.legacyImport.IsCleanType(point, "string") or not VALID_ANCHOR_POINTS[point]
        or not addon.legacyImport.IsCleanType(relativePoint, "string") or not VALID_ANCHOR_POINTS[relativePoint]
        or not addon.legacyImport.IsCleanType(xOfs, "number") or xOfs < -3000 or xOfs > 3000
        or not addon.legacyImport.IsCleanType(yOfs, "number") or yOfs < -3000 or yOfs > 3000 then
        return false
    end
    candidate[prefix .. "point"] = point
    candidate[prefix .. "relativePoint"] = relativePoint
    candidate[prefix .. "xOfs"] = xOfs
    candidate[prefix .. "yOfs"] = yOfs
    return true
end

function addon.legacyImport.CopyColor(sourceColors, candidate, key)
    if not addon.legacyImport.IsCleanType(sourceColors, "table") then return false end
    local color = addon.legacyImport.SafeRawGet(sourceColors, key)
    if not addon.legacyImport.IsCleanType(color, "table") then return false end
    local r = addon.legacyImport.SafeRawGet(color, "r")
    local g = addon.legacyImport.SafeRawGet(color, "g")
    local b = addon.legacyImport.SafeRawGet(color, "b")
    if not addon.legacyImport.IsCleanType(r, "number") or r < 0 or r > 1
        or not addon.legacyImport.IsCleanType(g, "number") or g < 0 or g > 1
        or not addon.legacyImport.IsCleanType(b, "number") or b < 0 or b > 1 then
        return false
    end
    candidate.colors = candidate.colors or {}
    candidate.colors[key] = { r = r, g = g, b = b }
    return true
end

function addon.legacyImport.CopyFont(source, candidate)
    local font = addon.legacyImport.SafeRawGet(source, "font")
    if not addon.legacyImport.IsCleanType(font, "string") then return false end
    local usable = addon.fontRuntime.usablePath(font)
    if not usable then return false end
    candidate.font = usable
    return true
end

function addon.legacyImport.BuildPublicCandidate(source)
    if not addon.legacyImport.IsCleanType(source, "table") then return nil, false end
    local candidate, found = {}, false
    for _, key in ipairs(addon.legacyImport.publicBooleanKeys) do
        if addon.legacyImport.CopyBoolean(source, candidate, key) then found = true end
    end
    for _, key in ipairs(addon.legacyImport.publicNumberKeys) do
        if addon.legacyImport.CopyNumberSetting(source, candidate, key) then found = true end
    end
    if addon.legacyImport.CopyFont(source, candidate) then found = true end
    if addon.legacyImport.CopyPosition(source, candidate, "") then found = true end
    local sourceColors = addon.legacyImport.SafeRawGet(source, "colors")
    for _, key in ipairs(addon.legacyImport.publicColorKeys) do
        if addon.legacyImport.CopyColor(sourceColors, candidate, key) then found = true end
    end
    if not found then return nil, false end
    if not MigrateDB(candidate) then return nil, false end
    candidate.appearancePresetID = "custom"
    return candidate, true
end

function addon.legacyImport.BuildLocalCandidate(source)
    if not addon.legacyImport.IsCleanType(source, "table") then return nil, "missing" end
    local candidate, found = {}, false
    local sourceVersion = addon.legacyImport.SafeRawGet(source, "dbVersion")
    local sourceVersionIsClean = addon.legacyImport.IsCleanType(sourceVersion, "number")
    if sourceVersionIsClean then
        sourceVersion = math.max(0, math.floor(sourceVersion))
        if sourceVersion > CURRENT_DB_VERSION then return nil, "future" end
        candidate.dbVersion = sourceVersion
    elseif type(sourceVersion) ~= "nil" then
        return nil, "future"
    end
    for key, defaultValue in pairs(defaults) do
        if type(defaultValue) == "boolean" then
            if addon.legacyImport.CopyBoolean(source, candidate, key) then found = true end
        elseif NUMBER_SETTING_META[key] then
            if addon.legacyImport.CopyNumberSetting(source, candidate, key) then found = true end
        end
    end
    for _, key in ipairs(addon.legacyImport.localLegacyBooleanKeys) do
        if addon.legacyImport.CopyBoolean(source, candidate, key) then found = true end
    end
    if addon.legacyImport.CopyPosition(source, candidate, "") then found = true end
    if addon.legacyImport.CopyPosition(source, candidate, "defensive_") then found = true end
    if addon.legacyImport.CopyFont(source, candidate) then found = true end
    for key, allowed in pairs(addon.legacyImport.allowedStrings) do
        local value = addon.legacyImport.SafeRawGet(source, key)
        if addon.legacyImport.IsCleanType(value, "string") and allowed[value] then
            candidate[key] = value
            found = true
        end
    end
    local forceLocale = addon.legacyImport.SafeRawGet(source, "forceLocale")
    if addon.legacyImport.IsCleanType(forceLocale, "string")
        and (forceLocale == "auto" or LOCALE_GLYPH_REQ[forceLocale]) then
        candidate.forceLocale = forceLocale
        found = true
    end
    local sourceColors = addon.legacyImport.SafeRawGet(source, "colors")
    for key in pairs(defaults.colors) do
        if addon.legacyImport.CopyColor(sourceColors, candidate, key) then found = true end
    end
    for _, key in ipairs(addon.legacyImport.localLegacyColorKeys) do
        if addon.legacyImport.CopyColor(sourceColors, candidate, key) then found = true end
    end
    if not found then return nil, "empty" end
    if not MigrateDB(candidate) then return nil, "invalid" end
    candidate.appearancePresetID = "custom"
    return candidate, "ready"
end

function addon.legacyImport.FindCandidate()
    local sawSource, sawFuture = false, false
    if type(_G.SwiftStatsDB) == "table" then
        sawSource = true
        local candidate, found = addon.legacyImport.BuildPublicCandidate(_G.SwiftStatsDB)
        if found then return candidate, "ready" end
    end
    if type(_G.SwiftStatsLocalDB) == "table" then
        sawSource = true
        local candidate, status = addon.legacyImport.BuildLocalCandidate(_G.SwiftStatsLocalDB)
        if status == "ready" then return candidate, status end
        if status == "future" then sawFuture = true end
    end
    if sawFuture then return nil, "future" end
    return nil, sawSource and "empty" or "missing"
end

function addon.legacyImport.ImportFreshIfAvailable()
    local db = addon.dbRuntime.GetWritableRoot(false)
    if not db then return false end
    if next(db) ~= nil then return false end
    local candidate = addon.legacyImport.FindCandidate()
    if not candidate then return false end
    _G.StatsProDB = candidate
    return true
end

local function RefreshArmorCache()
    if InCombatLockdown() then return end
    local reductionFn, returnsFraction
    if C_PaperDollInfo and type(C_PaperDollInfo.GetArmorEffectiveness) == "function" then
        reductionFn = C_PaperDollInfo.GetArmorEffectiveness
        returnsFraction = true
    elseif type(PaperDollFrame_GetArmorReduction) == "function" then
        reductionFn = PaperDollFrame_GetArmorReduction
        returnsFraction = false
    else
        return
    end

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
    if not okLevel or issecretvalue(level) or not SAFE_NUM.IsCleanFiniteNumber(level) or level <= 0 then return end

    -- WHY source-specific units: the documented C API returns a 0..1 fraction;
    -- Blizzard's legacy FrameXML helper already multiplies that value by 100.
    -- Use the private helper only when the public symbol is absent, not to retry a
    -- failed/secret public call that the helper would simply invoke again.
    -- WARNING: armor effectiveness can be secret-tagged in M+ transitional combat
    -- moments where InCombatLockdown lags real combat state — the OOC guard above
    -- isn't sufficient. Filter the return value before any comparison or arithmetic;
    -- multiplying or comparing a secret number aborts the OnUpdate.
    local okReduction, raw = pcall(reductionFn, effectiveArmor, level)
    if not okReduction or issecretvalue(raw) or not SAFE_NUM.IsCleanFiniteNumber(raw) then return end
    if returnsFraction then raw = raw * 100 end
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
    local repairCostRetryable = false
    for slot = DURABILITY_SLOT_MIN, DURABILITY_SLOT_MAX do
        if not DURABILITY_SKIP_SLOTS[slot] then
            local cur, max = GetInventoryItemDurability(slot)
            if SAFE_NUM.IsCleanFiniteNumber(cur) and SAFE_NUM.IsCleanFiniteNumber(max) and max > 0 then
                local pct = (cur / max) * 100
                sum = sum + pct
                count = count + 1
                if not minPct or pct < minPct then minPct = pct end
                if cached.showRepairCost and cur < max then
                    if C_TooltipInfo and C_TooltipInfo.GetInventoryItem then
                        local okData, data = pcall(C_TooltipInfo.GetInventoryItem, "player", slot)
                        if okData and data then
                            local surfaced = true
                            if TooltipUtil and TooltipUtil.SurfaceArgs then
                                surfaced = pcall(TooltipUtil.SurfaceArgs, data)
                            end
                            if surfaced then
                                local okCost, cost = pcall(function() return data.repairCost end)
                                if okCost and IsCleanNonNegativeNumber(cost) then
                                    totalCost = totalCost + cost
                                else
                                    repairCostPending = true
                                    if not okCost or not issecretvalue(cost) then repairCostRetryable = true end
                                end
                            else
                                repairCostPending = true
                                repairCostRetryable = true
                            end
                        else
                            repairCostPending = true
                            repairCostRetryable = true
                        end
                    else
                        repairCostPending = true
                    end
                end
            elseif cached.showRepairCost and (issecretvalue(cur) or issecretvalue(max)) then
                repairCostPending = true
            end
        end
    end
    if count == 0 then return 100, 100, 0, repairCostPending, repairCostRetryable end
    return sum / count, minPct, totalCost, repairCostPending, repairCostRetryable
end

-- WARNING: repairCost can lag behind durability: C_TooltipInfo may return nil
-- post-login, or return data with repairCost still nil/secret until item/vendor
-- info catches up. No durability event fires for plain data-load, so each external
-- dirty generation gets one delayed re-scan. A generation token makes older timers
-- harmless after a newer inventory/config event.

local function RefreshDurabilityCache()
    local avg, mn, cost, repairCostPending, repairCostRetryable = ScanDurabilityAndCost()
    cached.durabilityValue = cached.useWorstDurability and mn or avg
    cached.repairCostComplete = not repairCostPending
    cached.repairCost = cached.repairCostComplete and cost or nil
    durabilityDirty = false

    local retryGeneration = addon.durabilityRuntime.generation
    if repairCostPending and repairCostRetryable
            and addon.durabilityRuntime.attemptedGeneration ~= retryGeneration then
        addon.durabilityRuntime.attemptedGeneration = retryGeneration
        addon.durabilityRuntime.scheduledGeneration = retryGeneration
        C_Timer.After(3, function()
            if addon.durabilityRuntime.scheduledGeneration == retryGeneration then
                addon.durabilityRuntime.scheduledGeneration = nil
            end
            if addon.durabilityRuntime.generation == retryGeneration
                    and cached.repairCostComplete == false then
                durabilityDirty = true
            end
        end)
    end
end

--[[ ============================================================
    9. PANEL CLASS
============================================================ ]]
local Panel = {}
Panel.__index = Panel
-- Font-size units, not pixels: cold restricted geometry must scale with the successfully
-- applied 8..32px face and disappear as soon as a clean measurement is available.
Panel.SECRET_FULL_LABEL_WIDTH_UNITS = 8
Panel.SECRET_SHORT_LABEL_WIDTH_UNITS = 4
Panel.SECRET_NUMERIC_WIDTH_UNITS = 4
Panel.SECRET_REPAIR_WIDTH_UNITS = 8

function Panel:New(globalName, dbKeyPrefix)
    local panel = setmetatable({}, Panel)
    panel.dbKeyPrefix = dbKeyPrefix or ""
    panel.lastLabelText = nil
    panel.lastValueText = nil
    panel.lastLineCount = -1

    local frame = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
    frame:SetFrameStrata("BACKGROUND")
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

    -- Runtime-only edit chrome is a UIParent sibling, not a child of the content
    -- frame. Split/Flat routing can legitimately hide either panel; a child outline
    -- would disappear with that hidden frame and leave an empty panel impossible to
    -- locate. The outline itself is click-through so row tooltips keep ownership;
    -- only the small top handle accepts drag input while Settings is open.
    local editOutline = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    editOutline:SetPoint("TOPLEFT", frame, "TOPLEFT", -5, 5)
    editOutline:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 5, -5)
    editOutline:SetFrameStrata("LOW")
    editOutline:SetFrameLevel(frame:GetFrameLevel() + 1)
    editOutline:EnableMouse(false)
    editOutline:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    editOutline:SetBackdropColor(0, 0, 0, 0)
    editOutline:SetBackdropBorderColor(1, 0.82, 0.2, 0.72)
    editOutline:Hide()

    local editHandle = CreateFrame("Frame", nil, editOutline, "BackdropTemplate")
    editHandle:SetSize(42, 12)
    editHandle:SetPoint("TOP", editOutline, "TOP", 0, 5)
    editHandle:SetFrameLevel(editOutline:GetFrameLevel() + 1)
    editHandle:EnableMouse(true)
    editHandle:RegisterForDrag("LeftButton")
    editHandle:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    editHandle:SetBackdropColor(0, 0, 0, 0.82)
    editHandle:SetBackdropBorderColor(1, 0.82, 0.2, 0.9)

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
    -- File-scope construction must never touch a saved custom path: the media addon
    -- that registered it may not be loaded yet, and a dangling path can throw before
    -- PLAYER_ENTERING_WORLD gets a chance to repair SavedVariables.
    local font = addon.fontRuntime.safeDefaultPath()
    local fontSize = GetNumberDB("fontSize")
    local outlineStyle = addon.readabilityConfig.getTextOutlineStyleDB()
    local fontFlags = addon.readabilityConfig.textOutlineStyleToFontFlags(outlineStyle)

    local labelText = frame:CreateFontString(nil, "OVERLAY")
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
    ratingText:SetJustifyH("RIGHT")
    ratingText:SetJustifyV("TOP")
    ratingText:SetTextColor(1, 1, 1, 1)
    ratingText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    ratingText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

    local valueText = frame:CreateFontString(nil, "OVERLAY")
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
    repairText:SetJustifyH("RIGHT")
    repairText:SetTextColor(1, 1, 1, 1)
    repairText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)  -- y repositioned per render
    repairText:Hide()

    -- Repair row label — dedicated FontString anchored TOPLEFT below labelText (Y set
    -- per-render in SetTextSafe). Architecturally separate from labelText so the repair
    -- row sits on its own visual row below stats (visual separation), and so coin can't
    -- overlap stat-row content. Width set per-render = stats labelW for column alignment.
    local repairLabelText = frame:CreateFontString(nil, "OVERLAY")
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
            if button == "RightButton" and not frame.wasDragging and not InCombatLockdown() then
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
    panel.editOutline = editOutline
    panel.editHandle = editHandle
    panel.editAffordanceShown = false
    panel.editDragging = false

    editHandle:SetScript("OnDragStart", function()
        if not panel.editAffordanceShown or cached.isLocked then return end
        if addon.profileRuntime.ReadCombatState() ~= false then return end
        if not addon.dbRuntime.GetWritableSettings(false) then return end
        panel.editDragging = true
        frame.wasDragging = true
        frame:StartMoving()
    end)
    editHandle:SetScript("OnDragStop", function()
        panel:FinishEditDrag()
    end)
    local initialRegions = { labelText, ratingText, valueText, repairText, repairLabelText }
    local fontApplied, appliedFont, appliedFlags = addon.fontRuntime.applyExact(
        initialRegions, font, fontSize, fontFlags)
    panel.appliedFont = fontApplied and appliedFont or nil
    panel.appliedSize = fontApplied and fontSize or nil
    panel.appliedTextOutlineStyle = fontApplied and outlineStyle or nil
    panel.appliedFontFlags = fontApplied and appliedFlags or nil

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
    -- Right-click -> Settings while out of combat (drag-aware via wasDragging guard).
    frame:SetScript("OnMouseUp", function(f, button)
        if button == "RightButton" and not f.wasDragging and not InCombatLockdown() then
            addon:OpenConfigMenu()
        end
    end)

    return panel
end

function Panel:DBKey(suffix)
    if self.dbKeyPrefix == "" then return suffix end
    return self.dbKeyPrefix .. suffix
end

function Panel:SavePositionTo(db)
    local point, _, relativePoint, xOfs, yOfs = self.frame:GetPoint()
    -- WHY: if the frame has no anchor yet (called before LoadPosition), GetPoint returns
    -- nil. Writing nil deletes the key — next load would fall back to defaults and the
    -- previously-saved position would be lost.
    if not point or not addon.dbRuntime.IsCleanTable(db) then return end
    db[self:DBKey("point")] = point
    db[self:DBKey("relativePoint")] = relativePoint
    db[self:DBKey("xOfs")] = xOfs
    db[self:DBKey("yOfs")] = yOfs
end

function Panel:FinishEditDrag()
    if not self.editDragging then return end
    self.frame:StopMovingOrSizing()
    self:SavePosition()
    self.editDragging = false
    C_Timer.After(0.1, function() self.frame.wasDragging = false end)
end

function Panel:SetEditAffordanceVisible(show)
    show = show == true
    if self.editAffordanceShown == show then return end
    self.editAffordanceShown = show
    if show then
        self.editOutline:Show()
    else
        self:FinishEditDrag()
        self.editOutline:Hide()
    end
end

function Panel:SavePosition()
    local db = addon.dbRuntime.GetWritableSettings(false)
    if not db then return end
    self:SavePositionTo(db)
end

function Panel:LoadPosition()
    local db = addon.dbRuntime.GetActiveSettings()
    local pointKey         = self:DBKey("point")
    local relativePointKey = self:DBKey("relativePoint")
    local xOfsKey          = self:DBKey("xOfs")
    local yOfsKey          = self:DBKey("yOfs")
    local point            = NormalizeAnchorPoint(db[pointKey], defaults[pointKey] or "CENTER")
    local relativePoint    = NormalizeAnchorPoint(db[relativePointKey], defaults[relativePointKey] or "CENTER")
    local xOfs             = NormalizePositionOffset(db[xOfsKey], defaults[xOfsKey] or 0)
    local yOfs             = NormalizePositionOffset(db[yOfsKey], defaults[yOfsKey] or 0)

    local oldPoint, oldRelativeTo, oldRelativePoint, oldX, oldY = self.frame:GetPoint()
    self.frame:ClearAllPoints()
    local positioned = pcall(
        self.frame.SetPoint, self.frame, point, UIParent, relativePoint, xOfs, yOfs)
    -- WHY: SetUserPlaced(true) AFTER SetPoint marks the frame as user-positioned at our
    -- chosen anchor. Required in 12.x retail for StartMoving/StopMovingOrSizing to commit
    -- the new position to the frame's internal anchor — without it, GetPoint() can return
    -- the pre-drag anchor on some setups, so SavePosition writes the OLD position back
    -- to SavedVariables and the move appears not to have saved. Order matters: SetPoint
    -- first, then SetUserPlaced — otherwise WoW's layout-cache could overwrite our anchor.
    if positioned then
        positioned = pcall(self.frame.SetUserPlaced, self.frame, true)
    end
    if not positioned then
        self.frame:ClearAllPoints()
        if oldPoint then
            pcall(self.frame.SetPoint, self.frame,
                oldPoint, oldRelativeTo, oldRelativePoint, oldX, oldY)
        end
        error("panel position apply failed")
    end
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
    if type(meta) ~= "table" or not SAFE_NUM.IsCleanFiniteNumber(meta.target) or meta.target < 0 then return end
    local comparisonState = meta.comparisonState
    local hasCleanComparison = SAFE_NUM.IsCleanFiniteNumber(meta.current) and meta.current >= 0
        and SAFE_NUM.IsCleanFiniteNumber(meta.delta)
    -- Compatibility for smoke/manual metadata built before comparisonState existed.
    if comparisonState == nil and hasCleanComparison then comparisonState = "exact" end
    local hasComparison = (comparisonState == "exact" or comparisonState == "lastKnown")
        and hasCleanComparison
    local hasCleanCurrentPct = SAFE_NUM.IsCleanFiniteNumber(meta.currentPct)
    local currentBonus, targetBonus
    -- Versatility includes a flat component that rating conversion cannot recover.
    -- Without a clean complete currentPct, raw-rating percentages would be partial.
    if meta.statKey ~= "versatility" or hasCleanCurrentPct then
        if hasComparison then
            currentBonus = addon.archonTargets.GetRatingBonusForValue(meta.ratingCR, meta.current)
        end
        targetBonus = addon.archonTargets.GetRatingBonusForValue(meta.ratingCR, meta.target)
    end
    local deltaBonus
    -- WHY: subtract converted total ratings, not converted `abs(delta)`, so DR brackets
    -- and hard caps are evaluated at the player's current/target stat positions.
    if SAFE_NUM.IsCleanFiniteNumber(currentBonus) and SAFE_NUM.IsCleanFiniteNumber(targetBonus) then
        deltaBonus = targetBonus - currentBonus
    end
    local currentDisplayBonus = hasCleanCurrentPct and meta.currentPct or currentBonus
    local targetDisplayBonus = targetBonus
    if meta.statKey == "versatility" then targetDisplayBonus = nil end
    if hasCleanCurrentPct and SAFE_NUM.IsCleanFiniteNumber(deltaBonus) then
        targetDisplayBonus = meta.currentPct + deltaBonus
    end
    local valueColor = addon.archonTargets.GetTooltipValueColor(meta)
    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    GameTooltip:AddLine("StatsPro " .. addon.archonTargets.GetLocalizedSnapshotTitle(meta.snapshotKey), 1, 0.82, 0)
    if comparisonState == "lastKnown" then
        GameTooltip:AddLine(L("Last known comparison"), 0.7, 0.7, 0.7)
    end
    GameTooltip:AddDoubleLine(L("Target:"), addon.archonTargets.FormatRatingWithBonus(meta.target, targetDisplayBonus, false), 0.7, 0.7, 0.7, 1, 1, 1)
    if hasComparison then
        GameTooltip:AddDoubleLine(L("Current:"), addon.archonTargets.ColorTooltipValue(addon.archonTargets.FormatRatingWithBonus(meta.current, currentDisplayBonus, false), valueColor), 0.7, 0.7, 0.7, 1, 1, 1)
        if meta.delta < 0 then
            GameTooltip:AddDoubleLine(L("Missing:"), addon.archonTargets.FormatRatingWithBonus(math.abs(meta.delta), deltaBonus, true), 1, 0.35, 0.35, 1, 0.35, 0.35)
        elseif meta.delta > 0 then
            GameTooltip:AddDoubleLine(L("Over:"), addon.archonTargets.FormatRatingWithBonus(addon.archonTargets.FormatSignedRatingDelta(meta.delta), deltaBonus and -deltaBonus, true), 0.35, 0.8, 1, 0.35, 0.8, 1)
        else
            GameTooltip:AddDoubleLine(L("Matched:"), addon.archonTargets.FormatRatingWithBonus(0, deltaBonus, true), 0.5, 1, 0.5, 0.5, 1, 0.5)
        end
    end
    local snapshotDate = addon.archonTargets.FormatSnapshotDate(meta.capturedAt)
    if snapshotDate then
        GameTooltip:AddDoubleLine(L("Snapshot:"), addon.archonTargets.GetLocalizedSnapshotLabel(meta.snapshotKey) .. ", " .. snapshotDate, 0.7, 0.7, 0.7, 0.85, 0.85, 0.85)
    end
    if type(meta.sourceUrl) == "string" and not issecretvalue(meta.sourceUrl) and meta.sourceUrl ~= "" then
        GameTooltip:AddDoubleLine(L("Source:"), "Archon", 0.7, 0.7, 0.7, 0.85, 0.85, 0.85)
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
-- Mitigation: keep last non-secret measurement separate from the conservative fallback
-- used by this render. The second return value is always the last CLEAN measurement;
-- fallback geometry must not masquerade as clean cache state across content changes.
local function MeasuredOrCached(fs, current_cache, method, fallback)
    local v = fs[method](fs)
    if v and not issecretvalue(v) then
        return v, v
    end
    if fallback and (not current_cache or current_cache < fallback) then
        return fallback, current_cache
    end
    return current_cache, current_cache
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
    -- Cold secret reads use font-scaled geometry for this render only. Empty columns still
    -- return a clean zero, so rating-only / percentage-only routing gets no phantom value
    -- column. Height fallbacks are aggregate (lineCount * size), matching cached semantics.
    local effectiveFontSize = self.appliedSize or GetNumberDB("fontSize")
    local labelW, ratingW, valueW = 0, 0, 0
    local labelH, ratingH, valueH
    if hasRows then
        local minTextH = lineCount * effectiveFontSize
        ratingW, self.cachedRatingW = MeasuredOrCached(
            self.ratingText, self.cachedRatingW, "GetStringWidth",
            effectiveFontSize * Panel.SECRET_NUMERIC_WIDTH_UNITS)
        valueW, self.cachedValueW = MeasuredOrCached(
            self.valueText, self.cachedValueW, "GetStringWidth",
            effectiveFontSize * Panel.SECRET_NUMERIC_WIDTH_UNITS)
        ratingH, self.cachedRatingH = MeasuredOrCached(
            self.ratingText, self.cachedRatingH, "GetStringHeight", minTextH)
        valueH, self.cachedValueH = MeasuredOrCached(
            self.valueText, self.cachedValueH, "GetStringHeight", minTextH)
        if not labelsHidden then
            local labelWidthUnits = labelStyle == "short"
                and Panel.SECRET_SHORT_LABEL_WIDTH_UNITS
                or Panel.SECRET_FULL_LABEL_WIDTH_UNITS
            labelW, self.cachedLabelW = MeasuredOrCached(
                self.labelText, self.cachedLabelW, "GetStringWidth",
                effectiveFontSize * labelWidthUnits)
            -- labelText height drives Repair-row Y positioning; cache same way as widths.
            labelH, self.cachedLabelH = MeasuredOrCached(
                self.labelText, self.cachedLabelH, "GetStringHeight", minTextH)
        end
    end

    -- Single-column routing is an out-of-band clean invariant: when either rated-stat
    -- dimension is off, all visible cells are in ratingText and valueText is inactive.
    -- Force its effective width to zero even if Retail reports a sticky secret measurement
    -- after the prior dual-column text was replaced with a clean empty string.
    if cached.showRating ~= nil and cached.showPercentage ~= nil
        and not (cached.showRating and cached.showPercentage) then
        valueW = 0
    end

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
    local lineH = effectiveFontSize
    if hasRows then
        if labelsHidden then
            local renderedH = 0
            if hasRating and ratingH then renderedH = math.max(renderedH, ratingH) end
            if hasValue and valueH then renderedH = math.max(renderedH, valueH) end
            if renderedH > 0 then lineH = renderedH / lineCount end
        elseif labelH then
            lineH = labelH / lineCount
        end
    end
    local lineHChanged = self.lastLineH ~= lineH
    self.lastLineH = lineH
    self.lastRenderedLabelW = labelW
    self.lastRenderedRatingW = ratingW
    self.lastRenderedValueW = valueW

    if hasRepair then
        local repairLabelVisible = repairLabelStr and repairLabelStr ~= ""
        local repairRowY = hasRows and -(lineCount * lineH + 1) or 0  -- 1px gap only when below stat rows

        -- Repair label: use stat labelW when below stat rows; measure its own label for
        -- repair-only panels so a stale previous stat width cannot collapse or overinflate.
        self.repairLabelText:ClearAllPoints()
        self.repairLabelText:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, repairRowY)
        self.repairLabelText:SetText(repairLabelStr or "")
        if repairLabelVisible then
            if hasRows then
                repairLabelW = labelW
            else
                repairLabelW, self.cachedRepairLabelW = MeasuredOrCached(
                    self.repairLabelText, self.cachedRepairLabelW, "GetStringWidth", 80)
            end
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
        self.lastRenderedRepairW, self.cachedRepairW = MeasuredOrCached(
            self.repairText, self.cachedRepairW, "GetStringWidth",
            effectiveFontSize * Panel.SECRET_REPAIR_WIDTH_UNITS)
    else
        self.repairLabelText:Hide()
        self.repairText:Hide()
        -- Reset so a previously-wide coin doesn't keep the panel inflated after the user
        -- disables Show Repair Cost or repair drops to 0g (coin string becomes "").
        self.cachedRepairW = 0
        self.lastRenderedRepairW = 0
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
    local repairTotal = hasRepair and (repairLabelW + repairGap + (self.lastRenderedRepairW or 0)) or 0
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
    -- Cache invalidates on lineCount change, hasRepair flip, font/size change
    -- (heightDirty), OR an effective line-height change such as cold-fallback recovery.
    -- Reusing lastLineCount alone would conflate "text changed" vs "font changed" —
    -- Panel:Reflow needs it preserved across ApplyStyle as the content-line-count marker.
    if lineCount ~= self.lastLineCount or hasRepair ~= self.lastHasRepair or self.heightDirty or lineHChanged then
        local h = lineCount * lineH
        if hasRepair then h = h + lineH + (hasRows and 1 or 0) end  -- repair row + gap when below stats
        self.frame:SetHeight(h)
        self.lastLineCount = lineCount
        self.lastHasRepair = hasRepair
        self.heightDirty = false
    end
    self:ApplyTooltipRows(targetRows, lineCount)
end

function Panel:FontRegions()
    return { self.labelText, self.ratingText, self.valueText, self.repairText, self.repairLabelText }
end

function Panel:RestoreCachedText()
    if self.lastLabelText then self.labelText:SetText(self.lastLabelText) end
    if self.lastRatingText then self.ratingText:SetText(self.lastRatingText) end
    if self.lastValueText then self.valueText:SetText(self.lastValueText) end
    if self.lastRepairText and self.lastRepairText ~= "" then self.repairText:SetText(self.lastRepairText) end
    if self.lastRepairLabelText and self.lastRepairLabelText ~= "" then
        self.repairLabelText:SetText(self.lastRepairLabelText)
    end
end

function Panel:ApplyStyle(font, size, force, requestedOutlineStyle)
    -- WHY idempotency: ApplyStyle is hot — fires from PEW (after MAS may have already
    -- applied), Reset, font/locale preview-cancel, lang commit's conditional restore,
    -- and the Font Size slider's OnValueChanged. Same-args calls cost 10 SetFont +
    -- 10 SetText + cache invalidations + a follow-up UpdateStats re-measure pass.
    -- Early return saves all of that whenever the panel is already at (font,size,outline).
    local outlineStyle = requestedOutlineStyle
        or cached.textOutlineStyle
        or addon.readabilityConfig.getTextOutlineStyleDB()
    if not force
        and SameFontPath(self.appliedFont, font)
        and self.appliedSize == size
        and self.appliedTextOutlineStyle == outlineStyle then
        return true, self.appliedFont, self.appliedTextOutlineStyle, self.appliedFontFlags
    end
    local fontFlags = addon.readabilityConfig.textOutlineStyleToFontFlags(outlineStyle)
    local oldFont, oldSize, oldFlags = self.appliedFont, self.appliedSize, self.appliedFontFlags
    local regions = self:FontRegions()
    local applied, effectiveFont, effectiveFlags = addon.fontRuntime.applyExact(
        regions, font, size, fontFlags)
    if not applied then
        addon.fontRuntime.restore(regions, oldFont, oldSize, oldFlags)
        self:RestoreCachedText()
        return false
    end
    self.appliedFont = effectiveFont
    self.appliedSize = size
    self.appliedTextOutlineStyle = outlineStyle
    self.appliedFontFlags = effectiveFlags
    -- WHY: Blizzard quirk - SetFont clears text; re-apply if we have one.
    self:RestoreCachedText()
    -- Force re-measure on next SetTextSafe: cachedLabelH=nil drops the previous
    -- glyph-height read; heightDirty=true makes the height-gate fire even when
    -- lineCount + hasRepair are unchanged (the Reflow path always feeds the same
    -- lineCount back). lastLineCount is intentionally NOT reset here — Panel:Reflow
    -- relies on it as the cached content-line-count for re-feeding SetTextSafe.
    self.cachedLabelH = nil
    self.cachedRatingH = nil
    self.cachedValueH = nil
    self.heightDirty = true
    return true, effectiveFont, outlineStyle, effectiveFlags
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

addon.profileRuntime.saveActivePositions = function(settings)
    mainPanel:SavePositionTo(settings)
    defensivePanel:SavePositionTo(settings)
end

local function ApplyTextStyleToAllPanels(font, size, force)
    local oldMainFont, oldMainSize, oldMainOutline =
        mainPanel.appliedFont, mainPanel.appliedSize, mainPanel.appliedTextOutlineStyle
    local applied, effectiveFont, effectiveOutline, effectiveFlags = mainPanel:ApplyStyle(font, size, force)
    if not applied then return false end
    local sideApplied = defensivePanel:ApplyStyle(effectiveFont, size, force, effectiveOutline)
    if not sideApplied then
        mainPanel:ApplyStyle(oldMainFont, oldMainSize, true, oldMainOutline)
        return false
    end
    return true, effectiveFont, effectiveOutline, effectiveFlags
end

function addon.fontRuntime.applyCommittedTextStyle(font, size, force, allowFontFallback)
    local applied, effectiveFont, effectiveOutline, effectiveFlags =
        ApplyTextStyleToAllPanels(font, size, force)
    if not applied and allowFontFallback ~= false then
        local active = ResolveActiveLocale()
        local req = LOCALE_GLYPH_REQ[active] or GLYPH_LATIN
        local fallback = FindCompatibleFont(addon.fontRuntime.safeDefaultPath(), req)
        if fallback and not SameFontPath(fallback, font) then
            applied, effectiveFont, effectiveOutline, effectiveFlags =
                ApplyTextStyleToAllPanels(fallback, size, true)
        end
    end
    if not applied then return false end

    addon.fontRuntime.committedFont = effectiveFont
    local db = addon.dbRuntime.GetWritableSettings(false)
    if db then db.font = effectiveFont end
    if addon.fontRuntime.refreshCaption then addon.fontRuntime.refreshCaption() end
    return true, effectiveFont, effectiveOutline, effectiveFlags
end

function addon.fontRuntime.currentPath()
    return addon.fontRuntime.committedFont or GetFontDB()
end

function addon.fontRuntime.repairSavedPaths()
    local db = addon.dbRuntime.GetWritableSettings(false)
    if not db then return end

    local current = addon.fontRuntime.usablePath(db.font)
    if not current then
        local active = ResolveActiveLocale()
        local req = LOCALE_GLYPH_REQ[active] or GLYPH_LATIN
        current = FindCompatibleFont(addon.fontRuntime.safeDefaultPath(), req)
    end
    if current then db.font = current end

    if type(db.fontBeforeAutoSwitch) ~= "nil" then
        db.fontBeforeAutoSwitch = addon.fontRuntime.usablePath(db.fontBeforeAutoSwitch)
    end
end

function addon.fontRuntime.clearSavedAutoFont()
    local db = addon.dbRuntime.GetWritableSettings(false)
    if db then db.fontBeforeAutoSwitch = nil end
end

function addon.fontRuntime.canMutateDB(showGuidance)
    return addon.dbRuntime.GetWritableSettings(showGuidance) ~= nil
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
    if not addon.appearancePresets.BeforeManualEdit("textOutlineStyle") then
        CloseDropDownMenus()
        return false
    end
    local previous = addon.readabilityConfig.getTextOutlineStyleDB()
    local db = addon.dbRuntime.GetWritableSettings(true)
    if not db then
        CloseDropDownMenus()
        return false
    end
    local selected = addon.readabilityConfig.normalizeTextOutlineStyle(value)
    db.textOutlineStyle = selected
    CacheSettings()
    local applied = addon.fontRuntime.applyCommittedTextStyle(
        addon.fontRuntime.currentPath(), GetNumberDB("fontSize"), false, true)
    if not applied then
        db.textOutlineStyle = previous
        CacheSettings()
        for _, previousOpt in ipairs(addon.readabilityConfig.textOutlineOptions) do
            if previousOpt.value == previous then
                UIDropDownMenu_SetText(dropdown, L(previousOpt.label))
                break
            end
        end
        CloseDropDownMenus()
        return false
    end
    UIDropDownMenu_SetText(dropdown, L(opt.label))
    if selected ~= previous then addon.appearancePresets.MarkCustom(db) end
    CloseDropDownMenus()
    ReflowAllPanels()
    return true
end

addon.readabilityConfig.changePanelBackgroundAlpha = function(value)
    cached.panelBackgroundAlpha = value / 100
    addon.readabilityConfig.applyPanelBackgroundAlphaToAllPanels(cached.panelBackgroundAlpha)
end

-- Forward-decl: both helpers are defined in section 14 alongside their companions
-- but are called from MaybeAutoSwitchFont below + PreviewLanguage/CancelLanguagePreview
-- much later. Without forward-decl, the function body captures `ResolveConfigFont` /
-- `ApplyConfigFont` as global lookups (resolution at definition time) and crashes
-- with "attempt to call a nil value" at PEW when a later-defined helper is
-- captured as a global lookup.
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
-- Read-only resolver: returns a loadable font path that supports `req` glyph for
-- `currentFont`. It may use the hidden probe FontString, but never writes DB or HUD
-- state. Callsites:
--   1. MaybeAutoSwitchFont (commit path) — wraps with DB mutations + ApplyTextStyle.
--   2. PreviewLanguage hover (Localization do-block) — visual-only preview, no DB writes.
-- Returns currentFont if already compatible (caller can use this to detect "no swap needed").
-- Returns nil if no compatible font found anywhere in the 3-tier fallback chain
-- (caller should leave font alone — RefreshLanguageWarning will surface the issue).
-- Three-tier fallback:
--   1. LocaleAwareDefaultFont (Blizzard-shipped STANDARD_TEXT_FONT, hijack-guarded).
--   2. ARIALN (Blizzard ships Latin+Cyrillic universally — saves cross-locale
--      Russian users from needing an LSM addon for clean rendering).
--   3. Client-shipped/LSM scan (catches CJK / installed Cyrillic fonts).

-- Caller must set the account-wide forceLocale + run CacheSettings BEFORE calling.
local function MaybeAutoSwitchFont()
    local db = addon.dbRuntime.GetActiveSettings()
    local writableDB = addon.dbRuntime.GetWritableSettings(false)
    local active = ResolveActiveLocale()
    local req    = LOCALE_GLYPH_REQ[active] or GLYPH_LATIN
    local cur    = GetFontDB()

    if FontSupports(cur, req) then
        local saved = GetSavedAutoFontDB()
        if writableDB and type(db.fontBeforeAutoSwitch) ~= "nil" and not saved then
            writableDB.fontBeforeAutoSwitch = nil
        end
        if saved and not SameFontPath(saved, cur) and FontSupports(saved, req) then
            local applied, effectiveFont = addon.fontRuntime.applyCommittedTextStyle(
                saved, GetNumberDB("fontSize"), false, false)
            if applied then
                cur = effectiveFont
                if writableDB then writableDB.fontBeforeAutoSwitch = nil end
            end
        end
        if not SameFontPath(cur, addon.fontRuntime.currentPath()) then
            local applied, effectiveFont = addon.fontRuntime.applyCommittedTextStyle(
                cur, GetNumberDB("fontSize"), false, false)
            if applied then cur = effectiveFont end
        end
        ApplyConfigFont(ResolveConfigFont(active))
        return cur
    end

    local fallback = FindCompatibleFont(cur, req)
    if fallback and not SameFontPath(fallback, cur) then
        local saved = GetSavedAutoFontDB() or cur
        local applied, effectiveFont = addon.fontRuntime.applyCommittedTextStyle(
            fallback, GetNumberDB("fontSize"), false, false)
        if applied then
            cur = effectiveFont
            if writableDB then writableDB.fontBeforeAutoSwitch = saved end
        end
    end
    ApplyConfigFont(ResolveConfigFont(active))
    return cur
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
    if addon.panelEditRuntime.Refresh then addon.panelEditRuntime.Refresh() end
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
    local ratingStr = string.format("|cff%s%d|r", rc, rating)
    if IsDualColMode() then
        if type(pct) == "number" then
            return ratingStr .. " |cff808080|||r", FmtColorPct(pc, pct)
        end
        return ratingStr .. " |cff808080|||r", ""
    elseif cached.showRating then
        return ratingStr, ""
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
-- WHY hidden labelStyle pushes an empty label, not no row: render buckets use
-- label/rating/value array parity for row count; JoinLabelsCol hides the whole
-- label column later while the enabled Item Level values remain visible.
local function PushItemLevelRow(labels, ratings, values)
    if not cached.itemLevelOverall or not cached.itemLevelEquipped then return end
    local labelStr = GetStyledLabelText("ItemLevel", cached.labelStyle)
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
    local label = ""
    if labelStr ~= "" then
        label = string.format("|cff%s%s|r", itemLevelColor, labelStr)
    end
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
            local ratingDisplay, targetRating
            local ratingRead = false
            local visible = shouldShow(def.showKey, val, cached.hideZeroOffensive)
            if cached.showRating then
                ratingDisplay, targetRating = SAFE_NUM.ReadRatingValue(GetCombatRating, def.ratingCR)
                ratingRead = true
                local ratingVisible = shouldShow(def.showKey .. "Rating", ratingDisplay, cached.hideZeroOffensive)
                visible = visible or ratingVisible
            end
            if visible then
                if (cached.showRating or needTargetRating) and not ratingRead then
                    ratingDisplay, targetRating = SAFE_NUM.ReadRatingValue(GetCombatRating, def.ratingCR)
                end
                local rating = cached.showRating and (ratingDisplay or 0) or 0
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

    -- Versatility: dual-source (rating bonus + flat). Cache clean exact totals. A
    -- secret component may render live only when the other clean component is zero;
    -- otherwise retain the last complete total instead of showing a partial value.
    if cached.showVersatility then
        local versFromRating = safeCall(GetCombatRatingBonus, CR_VERSATILITY_DAMAGE_DONE)
        local versFlat       = safeCall(GetVersatilityBonus,  CR_VERSATILITY_DAMAGE_DONE)
        local versDisplay = cached.versTotal
        local versClean
        local versRatingDisplay
        local targetVersRating
        -- WARNING: must check operands for secret state before arithmetic. Rating
        -- may be read for either the visible rating column or target-hover metadata;
        -- percent cache can still refresh independently.
        local ratingIsSecret = issecretvalue(versFromRating)
        local flatIsSecret = issecretvalue(versFlat)
        local ratingIsClean = not ratingIsSecret and SAFE_NUM.IsCleanFiniteNumber(versFromRating)
        local flatIsClean = not flatIsSecret and SAFE_NUM.IsCleanFiniteNumber(versFlat)
        if ratingIsClean and flatIsClean then
            cached.versTotal = versFromRating + versFlat
            versDisplay = cached.versTotal
            versClean = cached.versTotal
        -- A secret component is the complete total only when its clean counterpart
        -- is exactly zero. Otherwise keep the last clean total (or cold unknown)
        -- instead of presenting one non-zero component as full Versatility.
        elseif ratingIsSecret and flatIsClean and versFlat == 0 then
            versDisplay = versFromRating
        elseif flatIsSecret and ratingIsClean and versFromRating == 0 then
            versDisplay = versFlat
        end
        if cached.showRating or needTargetRating then
            versRatingDisplay, targetVersRating = SAFE_NUM.ReadRatingValue(GetCombatRating, CR_VERSATILITY_DAMAGE_DONE)
            if targetVersRating then
                cached.versTotalRating = targetVersRating
            end
        end
        local versVisible = shouldShow("showVersatility", versDisplay, cached.hideZeroOffensive)
        if cached.showRating then
            local versRatingVisible = shouldShow("showVersatilityRating", versRatingDisplay, cached.hideZeroOffensive)
            versVisible = versVisible or versRatingVisible
        end
        if versVisible then
            local versStr = cs.versatility
            local rating = cached.showRating and (versRatingDisplay or cached.versTotalRating or 0) or 0
            local vRatStr, vValStr = FmtRatingPct(rating, versDisplay, versStr)
            if targetRows then
                targetRows[#targetRows + 1] = addon.archonTargets.BuildMeta("versatility", targetVersRating, CR_VERSATILITY_DAMAGE_DONE, versClean, "versatility") or false
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
            local ratingDisplay
            local ratingRead = false
            local visible = shouldShow(def.showKey, val, cached.hideZeroTertiary)
            if needRating then
                ratingDisplay = SAFE_NUM.ReadRatingValue(GetCombatRating, def.ratingCR)
                ratingRead = true
                local ratingVisible = shouldShow(def.showKey .. "Rating", ratingDisplay, cached.hideZeroTertiary)
                visible = visible or ratingVisible
            end
            if visible then
                if needRating and not ratingRead then
                    ratingDisplay = SAFE_NUM.ReadRatingValue(GetCombatRating, def.ratingCR)
                end
                local rating = needRating and (ratingDisplay or 0) or 0
                local statColor = cs[def.colorKey]
                local rStr, vStr = FmtRatingPct(rating, val, statColor)
                PushRow(labels, ratings, values,
                    FormatLabel(statColor, def.label),
                    rStr, vStr)
            end
        end
    end

    -- Legacy Speed key: GetSpeed returns rating-derived %, GetUnitSpeed gives Movement yps.
    -- Match Blizzard's paper-doll Movement stat: choose ground/swim/flight by
    -- current movement state instead of maxing every available mode.
    if cached.showSpeed then
        local _, run, flight, swim = GetUnitSpeed("player")
        -- WARNING: 12.x retail returns secrets from GetUnitSpeed in combat → arithmetic
        -- triggers numeric conversion taint. Recompute OOC, reuse cached value in combat.
        if not (issecretvalue(run) or issecretvalue(flight) or issecretvalue(swim))
            and (run == nil or SAFE_NUM.IsCleanFiniteNumber(run))
            and (flight == nil or SAFE_NUM.IsCleanFiniteNumber(flight))
            and (swim == nil or SAFE_NUM.IsCleanFiniteNumber(swim)) then
            local runPct = ((run or 0) / 7) * 100
            local flightPct = ((flight or 0) / 7) * 100
            local swimPct = ((swim or 0) / 7) * 100
            local swimming = IsSwimming("player")
            local speedPct = runPct
            if swimming then
                speedPct = swimPct
            elseif IsFlying("player") then
                speedPct = flightPct
            end
            -- Blizzard keeps the swim value while falling out of water so Movement
            -- does not flicker to ground speed during the jump/fall transition.
            if IsFalling("player") then
                if cached.speedWasSwimming then speedPct = swimPct end
            else
                cached.speedWasSwimming = swimming
            end
            cached.speedPct = speedPct
        end
        local speed = cached.speedPct
        local speedRatingDisplay = needRating and SAFE_NUM.ReadRatingValue(GetCombatRating, CR_SPEED) or nil
        local speedRating = needRating and (speedRatingDisplay or 0) or 0
        local speedVisible = shouldShow("showSpeed", speed, cached.hideZeroTertiary)
        if needRating then
            local speedRatingVisible = shouldShow("showSpeedRating", speedRatingDisplay, cached.hideZeroTertiary)
            speedVisible = speedVisible or speedRatingVisible
        end
        if speedVisible then
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
            if IsRenderablePercentValue(val) and shouldShow(def.showKey, val, cached.hideZeroDefensive) then
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
        if shouldShow("showArmor", cached.armorDR, cached.hideZeroDefensive) then
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
    if not cached.showRepairCost then return "", nil end
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
    if cached.repairCostComplete ~= true or not IsCleanNonNegativeNumber(cached.repairCost) then
        return "?", repairLabelStr
    end
    if cached.repairCost <= 0 then return "", nil end
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

    -- Armor refresh is unnecessary when either the master defensive block or the
    -- Armor sub-row is hidden. Keep the API chain out of the recurring ticker then.
    if not InCombatLockdown() and cached.showDefensive and cached.showArmor then
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

function addon:RunUpdateStatsSafe()
    local ok, err = pcall(UpdateStats)
    if not ok then
        cached.updateErrorCount = (cached.updateErrorCount or 0) + 1
        if issecretvalue(err) then
            cached.lastUpdateError = "<secret>"
        elseif type(err) == "string" then
            cached.lastUpdateError = err
        else
            cached.lastUpdateError = "<non-string error>"
        end
    end
    return ok
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
        addon:RunUpdateStatsSafe()
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
        -- First-run carry-forward happens at PEW so the source SavedVariables globals
        -- are populated regardless of addon load order. The field-driven importer only
        -- runs against an empty StatsPro DB; established settings are never overwritten
        -- without the explicit `/statspro import` confirmation path.
        addon.legacyImport.ImportFreshIfAvailable()
        MigrateDB()
        addon.dbRuntime.Refresh()
        -- Resolve the character/spec profile before the first cache/style/position
        -- pass so the account-default profile never flashes on login.
        addon.profileRuntime.RequestResolution(true)
        addon.fontRuntime.repairSavedPaths()
        CacheSettings()
        if RefreshPersistentLocalization then RefreshPersistentLocalization() end
        -- WHY here: forceLocale is migrated + cached.activeLabels resolved; if active
        -- locale needs glyphs db.font lacks, auto-switch BEFORE the
        -- ApplyTextStyleToAllPanels call below so the FontStrings load with the
        -- correct font on the very first frame (no `?` boxes for one session).
        local runtimeFont = MaybeAutoSwitchFont()
        LoadAllPositions()
        SetAllPanelsLockState(GetBoolDB("isLocked"))
        SetAllPanelsScale(GetNumberDB("scale"))
        -- Panel:New deliberately bootstraps with a verified client font and never
        -- touches saved custom media at file scope. Apply the migrated/repaired
        -- runtime choice only after every SavedVariable and media registration is
        -- available; future-schema DBs keep that effective choice out of storage.
        addon.fontRuntime.applyCommittedTextStyle(
            runtimeFont or GetFontDB(), GetNumberDB("fontSize"), false, true)
        -- WHY re-apply textAlpha at PEW: Panel:New runs at file scope before CacheSettings,
        -- so cached.textAlpha is nil at FontString creation. This propagates the user's
        -- saved alpha to FontStrings on the first frame.
        ApplyTextAlphaToAllPanels(cached.textAlpha)
        addon.readabilityConfig.applyPanelBackgroundAlphaToAllPanels(cached.panelBackgroundAlpha)
        isLoaded = true
    else
        addon.profileRuntime.RequestResolution(false)
    end
    -- WHY: UpdateStats handles Show/Hide based on cached.isVisible + line content.
    addon.durabilityRuntime.MarkDirty()
    itemLevelDirty = true
    addon:RunUpdateStatsSafe()
end

-- WHY: Armor/DR refresh runs inline in UpdateStats out-of-combat (cheap), so we
-- don't need specialization/trait/level handlers. PLAYER_REGEN_ENABLED remains
-- useful for retrying repair costs that were secret while combat-restricted.
-- WHY MERCHANT_SHOW marks dirty: repairCost can surface after the old cached scan
-- settled as unknown, and opening a vendor does not necessarily fire a durability event.
-- The handler only flips the dirty flag; the OnUpdate path still coalesces the scan.
-- WHY: PLAYER_LOGOUT fires before SavedVariables are written to disk. Re-saving
-- positions here is a belt-and-suspenders backup: OnMouseUp already saves on drop,
-- but if the user reloads/quits via a path that bypasses our drag handler (rare),
-- this guarantees the latest GetPoint() is what hits disk.
local function OnPlayerLogout()
    addon.dbRuntime.Refresh()
    if addon.dbRuntime.readOnly then return end
    if addon.profileRuntime.pendingResolution and addon.profileRuntime.activeGUID == nil then return end
    local settings = addon.dbRuntime.activeSettings
    if addon.dbRuntime.IsCleanTable(settings) then
        mainPanel:SavePositionTo(settings)
        defensivePanel:SavePositionTo(settings)
    end
end

local EVENT_HANDLERS = {
    PLAYER_ENTERING_WORLD       = OnPlayerEnteringWorld,
    PLAYER_LOGOUT               = OnPlayerLogout,
    PLAYER_SPECIALIZATION_CHANGED = function(unit)
        if not addon.dbRuntime.IsCleanType(unit, "string") or unit ~= "player" then return end
        addon.profileRuntime.RequestResolution(false)
    end,
    UPDATE_INVENTORY_DURABILITY = function() addon.durabilityRuntime.MarkDirty() end,
    PLAYER_EQUIPMENT_CHANGED    = function() addon.durabilityRuntime.MarkDirty(); itemLevelDirty = true end,
    BAG_UPDATE_DELAYED          = function() itemLevelDirty = true end,
    -- WHY: bag/equipment events can precede Blizzard's asynchronous average-iLvl
    -- recompute. This authoritative follow-up reopens the cache for the coalesced ticker.
    PLAYER_AVG_ITEM_LEVEL_UPDATE = function() itemLevelDirty = true end,
    MERCHANT_SHOW               = function() addon.durabilityRuntime.MarkDirty() end,
    -- WHY: lock state is stored in cached.isLocked and read by OnDragStart. Mouse stays
    -- enabled permanently so right-click Settings works even while locked; Panel:Lock /
    -- Panel:Unlock are no-op stubs kept behind this semantic wrapper.
    PLAYER_REGEN_ENABLED        = function()
        addon.profileRuntime.ResolvePending()
        SetAllPanelsLockState(GetBoolDB("isLocked"))
        -- The event is authoritative even if InCombatLockdown() lags by one frame.
        addon.panelEditRuntime.Refresh(false)
        if cached.showRepairCost and cached.repairCostComplete == false then
            addon.durabilityRuntime.MarkDirty()
        end
        addon.profileUI.RefreshSafe()
    end,
    PLAYER_REGEN_DISABLED       = function()
        addon.appearancePresets.ForceCancelPreview()
        addon.panelEditRuntime.Refresh(true)
        addon.profileUI.RefreshSafe()
    end,
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
-- to dodge the FRIZQT-on-CJK rendering trap
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
    local entry = { fs = fs, size = size, flags = flags }
    local resolvedFont, effectiveFlags
    if addon.fontRuntime.configFontValidated then
        resolvedFont, effectiveFlags = addon.fontRuntime.resolveUsableFlags(currentConfigFont, size, flags)
    else
        resolvedFont, effectiveFlags = addon.fontRuntime.resolveFlags(currentConfigFont, size, flags)
    end
    if resolvedFont and addon.fontRuntime.setRegionFont(fs, resolvedFont, size, effectiveFlags) then
        currentConfigFont = resolvedFont
        addon.fontRuntime.configFontValidated = true
        entry.appliedFont = resolvedFont
        entry.appliedSize = size
        entry.appliedFlags = effectiveFlags
        tinsert(localizedConfigFonts, entry)
        return true
    end

    tinsert(localizedConfigFonts, entry)
    local active = ResolveActiveLocale()
    local req = LOCALE_GLYPH_REQ[active] or GLYPH_LATIN
    local fallback = FindCompatibleFont(addon.fontRuntime.safeDefaultPath(), req)
        or addon.fontRuntime.safeDefaultPath()
    return ApplyConfigFont(fallback, true)
end

-- Called from MaybeAutoSwitchFont and PreviewLanguage/CancelLanguagePreview. Idempotent
-- fast-path skips work when currentConfigFont already matches (covers PEW + back-to-
-- default-locale scenarios). WHY no `local`: assigns the forward-decl'd upvalue.
ApplyConfigFont = function(font, force)
    if not force and SameFontPath(font, currentConfigFont) then return true, currentConfigFont end
    local usable = addon.fontRuntime.usablePath(font)
    if not usable then return false end
    if #localizedConfigFonts == 0 then
        currentConfigFont = usable
        addon.fontRuntime.configFontValidated = true
        return true, usable
    end

    local plans, previousText = {}, {}
    for i, e in ipairs(localizedConfigFonts) do
        local resolvedFont, effectiveFlags = addon.fontRuntime.resolveUsableFlags(usable, e.size, e.flags)
        if not resolvedFont then return false end
        plans[i] = { font = resolvedFont, flags = effectiveFlags }
        previousText[i] = e.fs:GetText()
    end

    for i, e in ipairs(localizedConfigFonts) do
        local plan = plans[i]
        if not addon.fontRuntime.setRegionFont(e.fs, plan.font, e.size, plan.flags) then
            for restoreIndex = 1, i do
                local old = localizedConfigFonts[restoreIndex]
                if old.appliedFont then
                    addon.fontRuntime.setRegionFont(
                        old.fs, old.appliedFont, old.appliedSize, old.appliedFlags)
                end
                if previousText[restoreIndex] ~= nil then
                    old.fs:SetText(previousText[restoreIndex])
                end
            end
            return false
        end
        if previousText[i] ~= nil then e.fs:SetText(previousText[i]) end
    end

    currentConfigFont = plans[1].font
    addon.fontRuntime.configFontValidated = true
    for i, e in ipairs(localizedConfigFonts) do
        e.appliedFont = plans[i].font
        e.appliedSize = e.size
        e.appliedFlags = plans[i].flags
    end
    return true, currentConfigFont
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
-- a CompactLabel transform that keeps short disambiguators where needed. Menu items
-- keep the full label form for disambiguation when picking. Font names from SharedMedia
-- can occasionally overflow at 100px — accepted: rare, names truncate to "Long Name..." and
-- the user can hover the dropdown for full text via Blizzard's tooltip.

-- Single source of truth for "DB color or fallback to default". This read path is
-- deliberately pure: opening Settings under a newer schema must not lazily create a
-- colors table and thereby mutate data owned by the newer addon version.
local function GetColor(statName)
    local db = addon.dbRuntime.GetActiveSettings()
    local colors = type(db.colors) == "table" and db.colors or {}
    colors = addon.appearancePresets.ResolveValue("colors", colors)
    local r, g, b = NormalizeColor(colors[statName], defaults.colors[statName])
    return { r = r, g = g, b = b }
end

-- WHY forward-decl: CreateCheckbox / CursorSection / CreateConfigSlider / CreateTabButton
-- below all register a setter via PushLocalizedLabel, but the function body lives further
-- down in the file (it depends on localizedConfigLabels declared lower). Upvalue resolution
-- is at call time — assignment happens before any helper is invoked from OpenConfigMenu.
local PushLocalizedLabel

local function CreateCheckbox(parent, name, label, dbKey, x, y, onChange, textWidth)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    if addon.__statsproSmoke == true then
        cb.statsProDBKey = dbKey
        cb.statsProDBType = "boolean"
    end
    cb:SetPoint("TOPLEFT", x, y)
    cb:SetSize(22, 22)
    local text = _G[name .. "Text"]
    PushLocalizedLabel(function() text:SetText(L(label)) end)
    RegisterConfigFont(text, CONFIG_FONT_SIZE)
    -- textWidth: 200 default for plain checkboxes; pass 140 for "checkbox + inline color"
    -- rows (CreateCheckboxColor overrides the bound width to actual text width post-call).
    text:SetWidth(textWidth or addon.settingsDesign.tokens.geometry.checkboxLabelWidth)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    text:SetMaxLines(1)
    cb:SetChecked(GetBoolDB(dbKey))
    addon.settingsDesign.StyleCheckbox(cb, text)
    cb:SetScript("OnClick", function(self)
        if not addon.appearancePresets.BeforeManualEdit(dbKey) then
            self:SetChecked(GetBoolDB(dbKey))
            return
        end
        local db = addon.dbRuntime.GetWritableSettings(true, dbKey)
        if not db then
            self:SetChecked(GetBoolDB(dbKey))
            return
        end
        local previous = db[dbKey]
        db[dbKey] = self:GetChecked()
        if previous ~= db[dbKey] and addon.appearancePresets.allowlist[dbKey] then
            addon.appearancePresets.MarkCustom(db)
        end
        CacheSettings()
        if onChange then onChange(self:GetChecked()) end
        addon:RunUpdateStatsSafe()
    end)
    PushRefresher(function()
        cb:SetChecked(GetBoolDB(dbKey))
        addon.settingsDesign.RefreshControl(cb)
    end)
    return cb, text
end

-- Toggle a checkbox's enabled state with matching label dim. Used by dependent-toggle
-- greying patterns (split routing gated on Split mode; Leech/Avoidance/Movement gated on
-- Show Tertiary Stats master) to make the dependency visible.
local function SetCheckboxEnabled(cb, enabled, reasonKey)
    if not cb then return end
    addon.settingsDesign.SetControlEnabled(cb, enabled, reasonKey)
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
    if session and session.btn then
        session.btn.statsProActive = false
        addon.settingsDesign.RefreshControl(session.btn)
    end
end

function COLOR_PICKER_STATE.OwnsFrame(session)
    if not session or not ColorPickerFrame then return false end
    -- Callback identity is the first ownership boundary. Avoid reading arbitrary
    -- foreign extraInfo unless the singleton still carries both StatsPro callbacks.
    local callbackOK, callbacksOwn = pcall(function()
        return ColorPickerFrame.swatchFunc == session.swatchFunc
            and ColorPickerFrame.cancelFunc == session.cancelFunc
    end)
    if not callbackOK or callbacksOwn ~= true then return false end
    if type(ColorPickerFrame.GetExtraInfo) ~= "function" then return true end

    local infoOK, extraInfo = pcall(ColorPickerFrame.GetExtraInfo, ColorPickerFrame)
    if not infoOK then return false end
    local secretOK, secret = pcall(issecretvalue, extraInfo)
    if not secretOK or secret then return false end
    local compareOK, tokenMatches = pcall(function() return extraInfo == session end)
    return compareOK and tokenMatches == true
end

function COLOR_PICKER_STATE.RestoreSnapshot(session)
    if session and session.cancelFunc then
        session.cancelFunc()
    else
        COLOR_PICKER_STATE.Clear(session)
    end
end

function COLOR_PICKER_STATE.OnOkayPreClick()
    local session = COLOR_PICKER_STATE.active
    if session and session.acceptBoundary and COLOR_PICKER_STATE.OwnsFrame(session) then
        if session.acceptFunc then session.acceptFunc() end
        session.accepted = true
    end
end

function COLOR_PICKER_STATE.OnOkayPostClick()
    local session = COLOR_PICKER_STATE.active
    if session and session.accepted and COLOR_PICKER_STATE.OwnsFrame(session)
        and ColorPickerFrame:IsShown() then
        -- Blizzard normally hides during OnClick. If it did not, do not leave an
        -- acceptance marker that could turn a later raw Hide into a false commit.
        session.accepted = false
    end
end

function COLOR_PICKER_STATE.OnFrameHide()
    local session = COLOR_PICKER_STATE.active
    if not session then return end
    local ownsFrame = COLOR_PICKER_STATE.OwnsFrame(session)
    if session.accepted and ownsFrame then
        COLOR_PICKER_STATE.Clear(session)
    elseif not ownsFrame or session.acceptBoundary then
        -- Normal Cancel/outside/Escape paths already call cancelFunc before Hide and
        -- clear active. Reaching OnHide unresolved means a raw Hide or foreign takeover.
        COLOR_PICKER_STATE.RestoreSnapshot(session)
    else
        -- Capability fallback: without a proven pre-OK boundary, preserve the prior
        -- clear-only behavior so a valid OK click is never rolled back.
        COLOR_PICKER_STATE.Clear(session)
    end
end

function COLOR_PICKER_STATE.OnFrameSetup()
    local session = COLOR_PICKER_STATE.active
    if session and not COLOR_PICKER_STATE.OwnsFrame(session) then
        -- Another addon replaced the singleton callbacks without hiding it. Restore
        -- only StatsPro's preview; never call the foreign cancelFunc or hide its frame.
        COLOR_PICKER_STATE.RestoreSnapshot(session)
    end
end

function COLOR_PICKER_STATE.EnsureFrameHook()
    if ColorPickerFrame and type(ColorPickerFrame.HookScript) == "function"
        and not COLOR_PICKER_STATE.hideHooked then
        local ok = pcall(ColorPickerFrame.HookScript, ColorPickerFrame,
            "OnHide", COLOR_PICKER_STATE.OnFrameHide)
        if ok then COLOR_PICKER_STATE.hideHooked = true end
    end

    local footer = ColorPickerFrame and ColorPickerFrame.Footer
    local okayButton = footer and footer.OkayButton
    if okayButton and type(okayButton.HookScript) == "function"
        and not COLOR_PICKER_STATE.acceptHooked then
        -- Blizzard's OK OnClick calls swatchFunc and then Hide. PreClick is the only
        -- stable point that distinguishes that accepted Hide from a raw Hide.
        local ok = pcall(okayButton.HookScript, okayButton,
            "PreClick", COLOR_PICKER_STATE.OnOkayPreClick)
        if ok then
            COLOR_PICKER_STATE.acceptHooked = true
            pcall(okayButton.HookScript, okayButton,
                "PostClick", COLOR_PICKER_STATE.OnOkayPostClick)
        end
    end

    if ColorPickerFrame and type(ColorPickerFrame.SetupColorPickerAndShow) == "function"
        and type(_G.hooksecurefunc) == "function" and not COLOR_PICKER_STATE.setupHooked then
        local ok = pcall(_G.hooksecurefunc, ColorPickerFrame,
            "SetupColorPickerAndShow", COLOR_PICKER_STATE.OnFrameSetup)
        if ok then COLOR_PICKER_STATE.setupHooked = true end
    end
end

function COLOR_PICKER_STATE.Close()
    local session = COLOR_PICKER_STATE.active
    if not session then return end
    if not ColorPickerFrame or not ColorPickerFrame:IsShown() then
        COLOR_PICKER_STATE.Clear(session)
        return
    end
    local ownsFrame = COLOR_PICKER_STATE.OwnsFrame(session)
    COLOR_PICKER_STATE.RestoreSnapshot(session)
    if ownsFrame then
        ColorPickerFrame:Hide()
    end
end
StatsProCloseColorPicker = COLOR_PICKER_STATE.Close

local function OpenColorPicker(btn, statName)
    if not addon.appearancePresets.BeforeManualEdit("colors") then return end
    local db = addon.dbRuntime.GetWritableSettings(true)
    if not db then return end
    COLOR_PICKER_STATE.EnsureFrameHook()
    COLOR_PICKER_STATE.Close()
    -- The Blizzard picker is a shared singleton. Do not overwrite a foreign
    -- session that is already visible; its owner must resolve it first.
    if ColorPickerFrame and ColorPickerFrame:IsShown() then return end
    -- WHY: capture "uses default" state so cancel can restore exactly that — writing
    -- the resolved-default tuple back would convert unset → explicit-default in DB
    -- (visible only between cancel and the next /reload, but the invariant is correct).
    if type(db.colors) ~= "table" then db.colors = {} end
    local hadExplicitColor = IsCompleteColor(db.colors[statName])
    local current = GetColor(statName)
    local snapshot = { r = current.r, g = current.g, b = current.b }

    COLOR_PICKER_STATE.token = COLOR_PICKER_STATE.token + 1
    local session = {
        token = COLOR_PICKER_STATE.token,
        btn = btn,
        statName = statName,
        hadExplicitColor = hadExplicitColor,
        snapshot = snapshot,
        generation = addon.dbRuntime.generation,
        accepted = false,
        acceptBoundary = COLOR_PICKER_STATE.hideHooked == true
            and COLOR_PICKER_STATE.acceptHooked == true,
        changed = false,
    }

    local function OnColorSelect()
        if not COLOR_PICKER_STATE.IsActive(session) then return end
        local writableDB = addon.dbRuntime.GetWritableSettings(true)
        if not writableDB or session.generation ~= addon.dbRuntime.generation then
            local persisted = GetColor(statName)
            addon.settingsDesign.SetSwatchColor(btn, persisted.r, persisted.g, persisted.b)
            return
        end
        if type(writableDB.colors) ~= "table" then writableDB.colors = {} end
        local r, g, b = ColorPickerFrame:GetColorRGB()
        session.changed = r ~= snapshot.r or g ~= snapshot.g or b ~= snapshot.b
        addon.settingsDesign.SetSwatchColor(btn, r, g, b)
        writableDB.colors[statName] = { r = r, g = g, b = b }
        CacheSettings()
        addon:RunUpdateStatsSafe()
    end
    local function OnCancel()
        if not COLOR_PICKER_STATE.IsActive(session) then return end
        local writableDB = addon.dbRuntime.GetWritableSettings(true)
        if writableDB and session.generation == addon.dbRuntime.generation then
            if type(writableDB.colors) ~= "table" then writableDB.colors = {} end
            addon.settingsDesign.SetSwatchColor(btn, snapshot.r, snapshot.g, snapshot.b)
            writableDB.colors[statName] = hadExplicitColor
                and { r = snapshot.r, g = snapshot.g, b = snapshot.b } or nil
        else
            local persisted = GetColor(statName)
            addon.settingsDesign.SetSwatchColor(btn, persisted.r, persisted.g, persisted.b)
        end
        if not addon.profileRuntime.suppressIntermediateRefresh then
            CacheSettings()
            addon:RunUpdateStatsSafe()
        end
        COLOR_PICKER_STATE.Clear(session)
    end
    session.swatchFunc = OnColorSelect
    session.cancelFunc = OnCancel
    session.acceptFunc = function()
        if not session.changed or session.generation ~= addon.dbRuntime.generation then return end
        local writableDB = addon.dbRuntime.GetWritableSettings(false)
        if writableDB then addon.appearancePresets.MarkCustom(writableDB) end
    end
    ColorPickerFrame:SetupColorPickerAndShow({
        r = snapshot.r, g = snapshot.g, b = snapshot.b,
        opacity = 1, hasOpacity = false,
        swatchFunc = OnColorSelect,
        cancelFunc = OnCancel,
        extraInfo = session,
    })
    COLOR_PICKER_STATE.active = session
    btn.statsProActive = true
    addon.settingsDesign.RefreshControl(btn)
end

-- Compact color swatch (no "Color:" label). Used for inline-with-checkbox placement
-- and section-header shared colors.
local function CreateColorSwatch(parent, statName, x, y)
    local btn = CreateFrame("Button", nil, parent)
    if addon.__statsproSmoke == true then
        btn.statsProColorKey = statName
    end
    btn:SetPoint("TOPLEFT", x, y)
    local geometry = addon.settingsDesign.tokens.geometry
    btn:SetSize(geometry.swatchSize, geometry.swatchSize)
    local surface = addon.settingsDesign.CreateTextureSurface(btn, "raised")
    surface:SetAllPoints(btn)
    btn.statsProSurface = surface
    local well = btn:CreateTexture(nil, "ARTWORK")
    well:SetPoint("CENTER")
    well:SetSize(geometry.swatchWellWidth, geometry.swatchWellHeight)
    btn.statsProColorWell = well
    local initialColor = GetColor(statName)
    addon.settingsDesign.SetSwatchColor(btn, initialColor.r, initialColor.g, initialColor.b)
    addon.settingsDesign.StyleSwatch(btn)
    btn:SetScript("OnClick", function(self)
        if self:IsEnabled() then OpenColorPicker(self, statName) end
    end)
    PushRefresher(function()
        local c = GetColor(statName)
        addon.settingsDesign.SetSwatchColor(btn, c.r, c.g, c.b)
        addon.settingsDesign.RefreshControl(btn)
    end)
    return btn
end

-- WHY swatch anchored to text:RIGHT (not absolute x): the swatch hugs the actual rendered
-- label end with CONFIG_SWATCH_GAP — works for any locale (en "Show Avoidance" ≠ ru "Уворот"
-- pixel widths). For groups of rows that should form a vertical column of swatches, call
-- AlignSwatchColumn(rows) post-creation — it normalizes all texts to the group's max
-- GetStringWidth so swatches line up at the same x relative to column start.
local function CreateCheckboxColor(parent, name, label, dbKey, colorKey, x, y, onChange)
    local cb, text = CreateCheckbox(parent, name, label, dbKey, x, y, onChange,
        addon.settingsDesign.tokens.geometry.checkboxColorLabelWidth)
    local swatch
    if colorKey then
        -- Override the 140-bound width with actual text rendering width — swatch needs
        -- to hug the text end, not the right edge of the 140px reservation. Cap the
        -- width so verbose localized labels clip instead of pushing into the next column.
        text.statsProMaxWidth = 160
        text:SetWidth(math.min(text:GetStringWidth(), text.statsProMaxWidth))
        swatch = CreateColorSwatch(parent, colorKey, 0, 0)
        swatch:ClearAllPoints()
        swatch:SetPoint("LEFT", text, "RIGHT", CONFIG_SWATCH_GAP, 0)
        cb.statsProSwatch = swatch
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
        local maxTextWidth = row.maxTextWidth or row.text.statsProMaxWidth
        if maxTextWidth and w > maxTextWidth then w = maxTextWidth end
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

addon.panelEditRuntime.Refresh = function(combatOverride)
    local combat = combatOverride
    if type(combat) ~= "boolean" then
        combat = addon.profileRuntime.ReadCombatState()
    end
    local show = addon.panelEditRuntime.requested == true
        and cached.isLocked == false
        and combat == false
    if show and not addon.dbRuntime.GetWritableSettings(false) then show = false end
    mainPanel:SetEditAffordanceVisible(show)
    defensivePanel:SetEditAffordanceVisible(show)
end

-- The Settings shell uses one explicit visual vocabulary.  Keep this runtime-only:
-- profile data and preview/commit semantics stay owned by their existing modules.
-- WHY table methods instead of more locals: this file is close to Lua 5.1's local and
-- closure limits, and T2-85 can reuse the same roles without duplicating literals.
addon.settingsDesign = {
    tokens = {
        colors = {
            window = { 0.018, 0.022, 0.020, 0.96 },
            raised = { 0.030, 0.038, 0.034, 0.97 },
            profile = { 0.050, 0.064, 0.057, 0.92 },
            viewport = { 0.014, 0.018, 0.016, 0.78 },
            section = { 0.050, 0.064, 0.057, 0.72 },
            borderStrong = { 0.24, 0.28, 0.26, 0.85 },
            borderSoft = { 0.22, 0.25, 0.23, 0.38 },
            separator = { 0.42, 0.46, 0.44, 0.28 },
            accent = { 0.10, 0.82, 0.48, 1 },
            accentMuted = { 0.10, 0.82, 0.48, 0.28 },
            textPrimary = { 0.92, 0.94, 0.93, 1 },
            textSecondary = { 0.70, 0.74, 0.72, 1 },
            textMuted = { 0.49, 0.54, 0.51, 1 },
            textDisabled = { 0.38, 0.41, 0.40, 1 },
            warning = { 1, 0.68, 0.22, 1 },
            danger = { 0.86, 0.28, 0.25, 1 },
            hover = { 0.10, 0.13, 0.115, 0.92 },
            pressed = { 0.10, 0.82, 0.48, 0.12 },
            rowHover = { 1, 1, 1, 0.045 },
            rowPressed = { 1, 1, 1, 0.075 },
            selected = { 0.10, 0.82, 0.48, 0.16 },
            track = { 0.22, 0.25, 0.23, 0.62 },
        },
        typography = {
            title = { size = 16, flags = "OUTLINE", color = "textPrimary" },
            metadata = { size = 11, color = "textSecondary" },
            profile = { size = 12, color = "textPrimary" },
            tab = { size = 13, flags = "OUTLINE", color = "textSecondary" },
            section = { size = 12, flags = "OUTLINE", color = "textPrimary" },
            button = { size = 12, color = "textPrimary" },
            body = { size = 12, color = "textPrimary" },
            value = { size = 12, flags = "OUTLINE", color = "textPrimary" },
            controlMetadata = { size = 10, color = "textSecondary" },
            warning = { size = 11, color = "warning" },
            error = { size = 11, color = "danger" },
        },
        spacing = { xxs = 2, xs = 4, sm = 8, md = 12, lg = 16, xl = 24 },
        geometry = {
            windowWidth = 500, minHeight = 260, maxHeight = 600,
            parentHeightRatio = 0.90, outerInset = 12,
            titleSurfaceInset = 5, titleSurfaceHeight = 35, titleHeight = 40,
            titleTextInset = 16, titleTextTop = 11,
            profileInset = 14, profileTop = 44, profileHeight = 48,
            profileFieldInset = 68, profileFieldWidth = 286, manageWidth = 100,
            tabInset = 18, tabTop = 100, tabHeight = 28, tabGap = 4, tabWidth = 152,
            viewportInset = 12, viewportTop = 136, viewportBottom = 62,
            scrollLeft = 16, scrollRight = 32, scrollTop = 140, scrollBottom = 66,
            contentWidth = 450,
            footerSurfaceInset = 5, footerSurfaceHeight = 51, footerHeight = 56,
            footerButtonInset = 18, footerButtonBottom = 14,
            resetButtonWidth = 240, closeButtonWidth = 100,
            shellButtonHeight = 28, minHitTarget = 24,
            sectionHeaderHeight = 22, scrollbarGutter = 16,
            scrollbarTrackWidth = 4, scrollbarArrowInset = 18,
            controlRowHeight = 28, controlHitTarget = 24,
            checkboxLabelWidth = 200, checkboxColorLabelWidth = 140,
            swatchSize = 24, swatchWellWidth = 18, swatchWellHeight = 14,
            sliderHeight = 24, sliderWidth = 420, sliderTrackHeight = 4,
            dropdownWidth = 180, dropdownLabelMaxWidth = 210,
            actionWidth = 292, actionHeight = 26,
            listRowHeight = 26, fontRowHeight = 24, warningHeight = 40,
        },
    },
    components = {
        surfaces = {
            window = { color = "window", border = "borderStrong", ornate = true },
            raised = { color = "raised", border = "borderSoft" },
            profile = { color = "profile", border = "borderSoft" },
            viewport = { color = "viewport", border = "borderSoft" },
            section = { color = "section", border = "borderSoft" },
        },
        buttons = {
            field = {
                normal = { bg = "raised", border = "borderSoft", text = "textPrimary" },
                hover = { bg = "hover", border = "borderStrong", text = "textPrimary" },
                pressed = { bg = "pressed", border = "accentMuted", text = "textPrimary" },
                disabled = { bg = "raised", border = "borderSoft", text = "textDisabled" },
            },
            primary = {
                normal = { bg = "raised", border = "accentMuted", text = "textPrimary" },
                hover = { bg = "hover", border = "accent", text = "textPrimary" },
                pressed = { bg = "pressed", border = "accent", text = "textPrimary" },
                disabled = { bg = "raised", border = "borderSoft", text = "textDisabled" },
            },
            destructive = {
                normal = { bg = "raised", border = "borderSoft", text = "textSecondary" },
                hover = { bg = "pressed", border = "danger", text = "danger" },
                pressed = { bg = "pressed", border = "danger", text = "textPrimary" },
                disabled = { bg = "raised", border = "borderSoft", text = "textDisabled" },
            },
        },
    },
}

function addon.settingsDesign.Color(name)
    return addon.settingsDesign.tokens.colors[name]
end

function addon.settingsDesign.SetRegionColor(region, colorName)
    local color = addon.settingsDesign.Color(colorName)
    if color then region:SetTextColor(color[1], color[2], color[3], color[4]) end
end

function addon.settingsDesign.ApplyTextRole(region, roleName)
    local role = addon.settingsDesign.tokens.typography[roleName]
    if not role then return end
    RegisterConfigFont(region, role.size, role.flags)
    addon.settingsDesign.SetRegionColor(region, role.color)
    region.statsProTextRole = roleName
end

function addon.settingsDesign.ApplySurface(frame, roleName)
    local role = addon.settingsDesign.components.surfaces[roleName]
    if not role then return end
    frame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = role.ornate and "Interface\\DialogFrame\\UI-DialogBox-Border"
            or "Interface\\Buttons\\WHITE8X8",
        tile = true,
        tileSize = 16,
        edgeSize = role.ornate and 16 or 1,
        insets = role.ornate
            and { left = 5, right = 5, top = 5, bottom = 5 }
            or { left = 1, right = 1, top = 1, bottom = 1 },
    })
    local bg = addon.settingsDesign.Color(role.color)
    local border = addon.settingsDesign.Color(role.border)
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
    frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
    frame.statsProSurfaceRole = roleName
end

-- Decorative shell layers must stay parent-owned regions. A child Frame backdrop
-- inherits a higher frame level and can cover OVERLAY FontStrings owned by its parent.
function addon.settingsDesign.CreateTextureSurface(parent, roleName)
    local role = addon.settingsDesign.components.surfaces[roleName]
    if not role then error("Unknown Settings surface role: " .. tostring(roleName)) end
    local background = parent:CreateTexture(nil, "BACKGROUND")
    local bg = addon.settingsDesign.Color(role.color)
    background:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    background.statsProSurfaceRole = roleName
    local border = addon.settingsDesign.Color(role.border)
    local top = parent:CreateTexture(nil, "BORDER")
    top:SetPoint("TOPLEFT", background, "TOPLEFT", 0, 0)
    top:SetPoint("TOPRIGHT", background, "TOPRIGHT", 0, 0)
    top:SetHeight(1)
    top:SetColorTexture(border[1], border[2], border[3], border[4])
    local bottom = parent:CreateTexture(nil, "BORDER")
    bottom:SetPoint("BOTTOMLEFT", background, "BOTTOMLEFT", 0, 0)
    bottom:SetPoint("BOTTOMRIGHT", background, "BOTTOMRIGHT", 0, 0)
    bottom:SetHeight(1)
    bottom:SetColorTexture(border[1], border[2], border[3], border[4])
    local left = parent:CreateTexture(nil, "BORDER")
    left:SetPoint("TOPLEFT", background, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", background, "BOTTOMLEFT", 0, 0)
    left:SetWidth(1)
    left:SetColorTexture(border[1], border[2], border[3], border[4])
    local right = parent:CreateTexture(nil, "BORDER")
    right:SetPoint("TOPRIGHT", background, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", background, "BOTTOMRIGHT", 0, 0)
    right:SetWidth(1)
    right:SetColorTexture(border[1], border[2], border[3], border[4])
    background.statsProBorders = { top, bottom, left, right }
    return background
end

function addon.settingsDesign.SetTextureSurfaceBorder(surface, colorName)
    local color = addon.settingsDesign.Color(colorName)
    if not surface or not color then return end
    for _, border in ipairs(surface.statsProBorders or {}) do
        border:SetColorTexture(color[1], color[2], color[3], color[4])
    end
    surface.statsProBorderRole = colorName
end

function addon.settingsDesign.SetTextureSurfaceColor(surface, colorName, alpha)
    local color = addon.settingsDesign.Color(colorName)
    if not surface or not color then return end
    surface:SetColorTexture(color[1], color[2], color[3], alpha or color[4])
    surface.statsProColorRole = colorName
end

function addon.settingsDesign.RegisterControl(control, kind)
    control.statsProControlKind = kind
    if addon.__statsproSmoke == true then
        addon.settingsDesign.testControls = addon.settingsDesign.testControls or {}
        tinsert(addon.settingsDesign.testControls, control)
    end
end

function addon.settingsDesign.IsControlEnabled(control)
    return type(control.IsEnabled) ~= "function" or control:IsEnabled()
end

function addon.settingsDesign.ShowControlTooltip(control)
    local provider = control.statsProTooltipProvider
    if type(provider) ~= "function" then return end
    local title, detail = provider(control)
    if not title or title == "" then return end
    GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
    GameTooltip:AddLine(title, 1, 1, 1)
    if detail and detail ~= "" then GameTooltip:AddLine(detail, 0.72, 0.77, 0.75) end
    GameTooltip:Show()
end

function addon.settingsDesign.HideControlTooltip(control)
    if type(GameTooltip.GetOwner) ~= "function" or GameTooltip:GetOwner() == control then
        GameTooltip:Hide()
    end
end

function addon.settingsDesign.AttachTooltip(control, provider)
    control.statsProTooltipProvider = provider
    if not control.statsProTooltipHooksAttached then
        control:HookScript("OnEnter", addon.settingsDesign.ShowControlTooltip)
        control:HookScript("OnLeave", addon.settingsDesign.HideControlTooltip)
        control:HookScript("OnHide", addon.settingsDesign.HideControlTooltip)
        control.statsProTooltipHooksAttached = true
    end
end

function addon.settingsDesign.DisabledControlTooltip(control)
    if addon.settingsDesign.IsControlEnabled(control) then return nil end
    local blockers = control.statsProControlBlockers
    local blocker = blockers and (blockers.schema or blockers.context or blockers.dependency)
    if not blocker then return nil end
    if blocker.mode == "requires" then
        return string.format(L("Requires %s."), L(blocker.key))
    end
    return L(blocker.key)
end

function addon.settingsDesign.ControlTextTooltip(control)
    local blockedTitle, blockedDetail = addon.settingsDesign.DisabledControlTooltip(control)
    if blockedTitle then return blockedTitle, blockedDetail end
    local textRegion = control.statsProText
    if not textRegion then return nil end
    local constrainedWidth = textRegion:GetWidth()
    if not constrainedWidth or constrainedWidth <= 0 then return nil end
    textRegion:SetWidth(10000)
    local naturalWidth = textRegion:GetStringWidth()
    textRegion:SetWidth(constrainedWidth)
    if naturalWidth > constrainedWidth then return textRegion:GetText() end
    return nil
end

function addon.settingsDesign.RefreshControl(control)
    local kind = control.statsProControlKind
    local enabled = addon.settingsDesign.IsControlEnabled(control)
    local hovered = control.statsProHovered == true and enabled
    local pressed = control.statsProPressed == true and enabled

    if kind == "checkbox" then
        local checked = control:GetChecked() == true
        local bgRole = pressed and "rowPressed" or (hovered and "rowHover"
            or (checked and "selected" or "raised"))
        local bgAlpha = not enabled and 0 or (not hovered and not pressed and not checked and 0
            or addon.settingsDesign.Color(bgRole)[4])
        addon.settingsDesign.SetTextureSurfaceColor(control.statsProStateTexture, bgRole, bgAlpha)
        addon.settingsDesign.SetRegionColor(
            control.statsProText, enabled and "textPrimary" or "textDisabled")
        local normalColor = addon.settingsDesign.Color(enabled and "borderStrong" or "textDisabled")
        if control.statsProNormalTexture then
            control.statsProNormalTexture:SetVertexColor(
                normalColor[1], normalColor[2], normalColor[3], enabled and 0.82 or 0.35)
        end
        local checkColor = addon.settingsDesign.Color(enabled and "accent" or "textDisabled")
        if control.statsProCheckedTexture then
            control.statsProCheckedTexture:SetVertexColor(
                checkColor[1], checkColor[2], checkColor[3], enabled and 0.92 or 0.35)
        end
        if control.statsProDisabledCheckedTexture then
            control.statsProDisabledCheckedTexture:SetVertexColor(
                checkColor[1], checkColor[2], checkColor[3], 0.35)
        end
    elseif kind == "swatch" then
        local borderRole = not enabled and "textDisabled"
            or (control.statsProActive and "accent"
                or (pressed and "accent" or (hovered and "borderStrong" or "borderSoft")))
        addon.settingsDesign.SetTextureSurfaceBorder(control.statsProSurface, borderRole)
        control:SetAlpha(enabled and 1 or 0.35)
    elseif kind == "slider" then
        local thumbRole = not enabled and "textDisabled"
            or (pressed and "accent" or (hovered and "textPrimary" or "textMuted"))
        local thumbColor = addon.settingsDesign.Color(thumbRole)
        if control.statsProThumb then
            control.statsProThumb:SetVertexColor(
                thumbColor[1], thumbColor[2], thumbColor[3], enabled and 0.86 or 0.35)
        end
        addon.settingsDesign.SetRegionColor(
            control.statsProLabel, enabled and "textPrimary" or "textDisabled")
        addon.settingsDesign.SetRegionColor(
            control.statsProValueText, enabled and "textPrimary" or "textDisabled")
        addon.settingsDesign.SetRegionColor(
            control.statsProLowText, enabled and "textSecondary" or "textDisabled")
        addon.settingsDesign.SetRegionColor(
            control.statsProHighText, enabled and "textSecondary" or "textDisabled")
        if control.statsProTrack then
            local track = addon.settingsDesign.Color(enabled and "track" or "textDisabled")
            control.statsProTrack:SetColorTexture(
                track[1], track[2], track[3], enabled and track[4] or 0.24)
        end
    elseif kind == "dropdown" then
        local open = control.statsProActive == true
            or UIDROPDOWNMENU_OPEN_MENU == control.statsProDropdown
        local bgRole = pressed and "pressed" or (hovered and "hover" or "raised")
        local borderRole = not enabled and "textDisabled"
            or ((open or pressed) and "accent" or (hovered and "borderStrong" or "borderSoft"))
        addon.settingsDesign.SetTextureSurfaceColor(control.statsProSurface, bgRole,
            enabled and addon.settingsDesign.Color(bgRole)[4] or 0.35)
        addon.settingsDesign.SetTextureSurfaceBorder(control.statsProSurface, borderRole)
        addon.settingsDesign.SetRegionColor(
            control.statsProText, enabled and "textPrimary" or "textDisabled")
        control:SetAlpha(enabled and 1 or 0.45)
        control.statsProOpen = open
    elseif kind == "listRow" then
        local bgRole = pressed and "rowPressed" or (hovered and "rowHover"
            or (control.statsProSelected and "selected" or "raised"))
        local alpha = not enabled and 0 or (not hovered and not pressed
            and not control.statsProSelected and 0 or addon.settingsDesign.Color(bgRole)[4])
        addon.settingsDesign.SetTextureSurfaceColor(control.statsProStateTexture, bgRole, alpha)
        addon.settingsDesign.SetRegionColor(control.statsProText,
            not enabled and "textDisabled"
                or ((hovered or pressed or control.statsProSelected) and "textPrimary"
                    or "textSecondary"))
    elseif kind == "editBox" then
        local borderRole = control.statsProInvalid and "danger"
            or (control.statsProFocused and "accent" or "borderSoft")
        addon.settingsDesign.SetTextureSurfaceBorder(control.statsProSurface, borderRole)
    end
    control.statsProControlState = not enabled and "disabled"
        or (pressed and "pressed" or (hovered and "hover"
            or (control.statsProSelected and "selected" or "normal")))
end

function addon.settingsDesign.OnControlEnter(control)
    control.statsProHovered = true
    addon.settingsDesign.RefreshControl(control)
end

function addon.settingsDesign.OnControlLeave(control)
    control.statsProHovered = false
    control.statsProPressed = false
    addon.settingsDesign.RefreshControl(control)
end

function addon.settingsDesign.OnControlDown(control)
    if addon.settingsDesign.IsControlEnabled(control) then control.statsProPressed = true end
    addon.settingsDesign.RefreshControl(control)
end

function addon.settingsDesign.OnControlUp(control)
    control.statsProPressed = false
    addon.settingsDesign.RefreshControl(control)
end

function addon.settingsDesign.OnControlDisabled(control)
    control.statsProHovered = false
    control.statsProPressed = false
    addon.settingsDesign.HideControlTooltip(control)
    addon.settingsDesign.RefreshControl(control)
end

function addon.settingsDesign.HookControl(control)
    control:HookScript("OnEnter", addon.settingsDesign.OnControlEnter)
    control:HookScript("OnLeave", addon.settingsDesign.OnControlLeave)
    control:HookScript("OnMouseDown", addon.settingsDesign.OnControlDown)
    control:HookScript("OnMouseUp", addon.settingsDesign.OnControlUp)
    control:HookScript("OnEnable", addon.settingsDesign.RefreshControl)
    control:HookScript("OnDisable", addon.settingsDesign.OnControlDisabled)
end

function addon.settingsDesign.RefreshEnabledState(control)
    local blockers = control.statsProControlBlockers
    local blocked = type(blockers) == "table" and next(blockers) ~= nil
    if blocked then control:Disable() else control:Enable() end
    if control.statsProControlKind == "button" then
        addon.settingsDesign.RefreshShellButton(control)
    else
        addon.settingsDesign.RefreshControl(control)
    end
end

function addon.settingsDesign.SetControlBlocked(control, source, blocked, mode, key)
    if not control then return end
    control.statsProControlBlockers = control.statsProControlBlockers or {}
    control.statsProControlBlockers[source] = blocked and { mode = mode, key = key } or nil
    addon.settingsDesign.RefreshEnabledState(control)
    if control.statsProSwatch then
        addon.settingsDesign.SetControlBlocked(
            control.statsProSwatch, source, blocked, mode, key)
    end
end

function addon.settingsDesign.RegisterMutationControl(control)
    control.statsProMutatesSettings = true
    addon.settingsDesign.mutationControls = addon.settingsDesign.mutationControls or {}
    tinsert(addon.settingsDesign.mutationControls, control)
    addon.settingsDesign.AttachTooltip(control, addon.settingsDesign.ControlTextTooltip)
end

function addon.settingsDesign.RefreshMutationControls()
    addon.dbRuntime.Refresh()
    local schemaBlocked = addon.dbRuntime.readOnly == true
    local contextBlocked = addon.profileRuntime.BlocksUserWrites() == true
    for _, control in ipairs(addon.settingsDesign.mutationControls or {}) do
        addon.settingsDesign.SetControlBlocked(control, "schema", schemaBlocked,
            "message", "Compatibility mode - profiles are read-only.")
        addon.settingsDesign.SetControlBlocked(control, "context", contextBlocked,
            "message", "Waiting for a safe profile context.")
    end
end

function addon.settingsDesign.SetControlEnabled(control, enabled, reasonKey)
    if not control then return end
    control.statsProDisabledReasonKey = enabled and nil or reasonKey
    addon.settingsDesign.SetControlBlocked(
        control, "dependency", not enabled, "requires", reasonKey)
end

function addon.settingsDesign.StyleCheckbox(control, text)
    local geometry = addon.settingsDesign.tokens.geometry
    control:SetSize(geometry.controlHitTarget, geometry.controlHitTarget)
    addon.settingsDesign.ApplyTextRole(text, "body")
    local state = control:CreateTexture(nil, "BACKGROUND")
    state:SetAllPoints(control)
    control.statsProStateTexture = state
    control.statsProText = text
    control.statsProNormalTexture = type(control.GetNormalTexture) == "function"
        and control:GetNormalTexture() or nil
    control.statsProCheckedTexture = type(control.GetCheckedTexture) == "function"
        and control:GetCheckedTexture() or nil
    control.statsProDisabledCheckedTexture = type(control.GetDisabledCheckedTexture) == "function"
        and control:GetDisabledCheckedTexture() or nil
    local highlight = type(control.GetHighlightTexture) == "function"
        and control:GetHighlightTexture() or nil
    if highlight then highlight:SetAlpha(0) end
    for _, texture in pairs({ control.statsProNormalTexture, control.statsProCheckedTexture,
        control.statsProDisabledCheckedTexture }) do
        if texture and type(texture.SetDesaturated) == "function" then texture:SetDesaturated(true) end
    end
    addon.settingsDesign.RegisterControl(control, "checkbox")
    addon.settingsDesign.RegisterMutationControl(control)
    addon.settingsDesign.HookControl(control)
    control:HookScript("OnClick", addon.settingsDesign.RefreshControl)
    addon.settingsDesign.RefreshControl(control)
end

function addon.settingsDesign.SetSwatchColor(control, r, g, b)
    if control and control.statsProColorWell then
        control.statsProColorWell:SetColorTexture(r, g, b, 1)
        control.statsProDisplayedColor = { r = r, g = g, b = b }
    end
end

function addon.settingsDesign.StyleSwatch(control)
    addon.settingsDesign.RegisterControl(control, "swatch")
    addon.settingsDesign.RegisterMutationControl(control)
    addon.settingsDesign.HookControl(control)
    addon.settingsDesign.RefreshControl(control)
end

function addon.settingsDesign.StyleSlider(slider, label, valueText, lowText, highText)
    local geometry = addon.settingsDesign.tokens.geometry
    slider:SetSize(geometry.sliderWidth, geometry.sliderHeight)
    addon.settingsDesign.ApplyTextRole(label, "body")
    addon.settingsDesign.ApplyTextRole(valueText, "value")
    addon.settingsDesign.ApplyTextRole(lowText, "controlMetadata")
    addon.settingsDesign.ApplyTextRole(highText, "controlMetadata")
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT", 0, 0)
    track:SetPoint("RIGHT", 0, 0)
    track:SetHeight(geometry.sliderTrackHeight)
    slider.statsProTrack = track
    slider.statsProThumb = type(slider.GetThumbTexture) == "function"
        and slider:GetThumbTexture() or nil
    local name = slider:GetName()
    for _, suffix in ipairs({ "Left", "Middle", "Right" }) do
        local texture = name and _G[name .. suffix]
        if texture then texture:SetAlpha(0) end
    end
    slider.statsProLabel = label
    slider.statsProValueText = valueText
    slider.statsProLowText = lowText
    slider.statsProHighText = highText
    addon.settingsDesign.RegisterControl(slider, "slider")
    addon.settingsDesign.RegisterMutationControl(slider)
    addon.settingsDesign.HookControl(slider)
    addon.settingsDesign.RefreshControl(slider)
end

function addon.settingsDesign.StyleDropdown(dropdown, label)
    local geometry = addon.settingsDesign.tokens.geometry
    local name = dropdown:GetName()
    local button = dropdown.Button or (name and _G[name .. "Button"])
    local text = name and _G[name .. "Text"] or nil
    if not button or not text then return end
    local surface = addon.settingsDesign.CreateTextureSurface(dropdown, "raised")
    surface:SetPoint("TOPLEFT", 16, -4)
    surface:SetPoint("BOTTOMRIGHT", -8, 4)
    addon.settingsDesign.ApplyTextRole(label, "body")
    addon.settingsDesign.ApplyTextRole(text, "body")
    text:SetWidth(geometry.dropdownWidth - 32)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    text:SetMaxLines(1)
    button:SetSize(geometry.controlHitTarget, geometry.controlRowHeight)
    for _, suffix in ipairs({ "Left", "Middle", "Right" }) do
        local texture = name and _G[name .. suffix]
        if texture then texture:SetAlpha(0) end
    end
    for _, texture in pairs({
        type(button.GetNormalTexture) == "function" and button:GetNormalTexture(),
        type(button.GetHighlightTexture) == "function" and button:GetHighlightTexture(),
        type(button.GetPushedTexture) == "function" and button:GetPushedTexture(),
        type(button.GetDisabledTexture) == "function" and button:GetDisabledTexture(),
    }) do
        if texture and type(texture.SetDesaturated) == "function" then texture:SetDesaturated(true) end
    end
    button.statsProDropdown = dropdown
    button.statsProSurface = surface
    button.statsProText = text
    dropdown.statsProTrigger = button
    dropdown.statsProLabel = label
    addon.settingsDesign.dropdownTriggers = addon.settingsDesign.dropdownTriggers or {}
    tinsert(addon.settingsDesign.dropdownTriggers, button)
    if DropDownList1 and not addon.settingsDesign.dropdownCloseHooked then
        DropDownList1:HookScript("OnHide", function()
            for _, trigger in ipairs(addon.settingsDesign.dropdownTriggers or {}) do
                addon.settingsDesign.RefreshControl(trigger)
            end
        end)
        addon.settingsDesign.dropdownCloseHooked = true
    end
    addon.settingsDesign.RegisterControl(button, "dropdown")
    addon.settingsDesign.RegisterMutationControl(button)
    addon.settingsDesign.HookControl(button)
    button:HookScript("OnClick", addon.settingsDesign.RefreshControl)
    addon.settingsDesign.AttachTooltip(button, addon.settingsDesign.ControlTextTooltip)
    addon.settingsDesign.RefreshControl(button)
end

function addon.settingsDesign.StyleListRow(row, text)
    local state = row.statsProStateTexture or row.background
    if not state then
        state = row:CreateTexture(nil, "BACKGROUND")
        state:SetAllPoints(row)
    end
    row.statsProStateTexture = state
    row.statsProText = text
    addon.settingsDesign.ApplyTextRole(text, "controlMetadata")
    addon.settingsDesign.RegisterControl(row, "listRow")
    addon.settingsDesign.HookControl(row)
    addon.settingsDesign.AttachTooltip(row, addon.settingsDesign.ControlTextTooltip)
    addon.settingsDesign.RefreshControl(row)
end

function addon.settingsDesign.SetListRowSelected(row, selected)
    row.statsProSelected = selected == true
    addon.settingsDesign.RefreshControl(row)
end

function addon.settingsDesign.StyleStatusText(text, roleName)
    addon.settingsDesign.ApplyTextRole(text, roleName or "controlMetadata")
    text.statsProStatusRole = roleName or "controlMetadata"
end

function addon.settingsDesign.StyleWarning(parent, text, roleName)
    local role = roleName or "warning"
    addon.settingsDesign.ApplyTextRole(text, role)
    local surface = addon.settingsDesign.CreateTextureSurface(parent, "raised")
    surface:SetPoint("TOPLEFT", text, "TOPLEFT", -8, 6)
    surface:SetPoint("BOTTOMRIGHT", text, "BOTTOMRIGHT", 8, -6)
    local rail = parent:CreateTexture(nil, "ARTWORK")
    rail:SetPoint("TOPLEFT", surface, "TOPLEFT", 0, 0)
    rail:SetPoint("BOTTOMLEFT", surface, "BOTTOMLEFT", 0, 0)
    rail:SetWidth(2)
    local color = addon.settingsDesign.Color(role == "error" and "danger" or "warning")
    rail:SetColorTexture(color[1], color[2], color[3], color[4])
    text.statsProWarningSurface = surface
    text.statsProWarningRail = rail
    addon.settingsDesign.SetWarningVisible(text, false)
end

function addon.settingsDesign.SetWarningVisible(text, visible)
    if not text then return end
    if text.statsProWarningSurface then
        if visible then text.statsProWarningSurface:Show()
        else text.statsProWarningSurface:Hide() end
        for _, border in ipairs(text.statsProWarningSurface.statsProBorders or {}) do
            if visible then border:Show() else border:Hide() end
        end
    end
    if text.statsProWarningRail then
        if visible then text.statsProWarningRail:Show()
        else text.statsProWarningRail:Hide() end
    end
end

function addon.settingsDesign.StyleEditBox(editBox)
    local surface = addon.settingsDesign.CreateTextureSurface(editBox, "raised")
    surface:SetAllPoints(editBox)
    editBox.statsProSurface = surface
    local name = editBox:GetName()
    for _, suffix in ipairs({ "Left", "Middle", "Right" }) do
        local texture = name and _G[name .. suffix]
        if texture then texture:SetAlpha(0) end
    end
    addon.settingsDesign.RegisterControl(editBox, "editBox")
    editBox:HookScript("OnEditFocusGained", function(box)
        box.statsProFocused = true
        addon.settingsDesign.RefreshControl(box)
    end)
    editBox:HookScript("OnEditFocusLost", function(box)
        box.statsProFocused = false
        addon.settingsDesign.RefreshControl(box)
    end)
    addon.settingsDesign.RefreshControl(editBox)
end

function addon.settingsDesign.ApplySeparator(texture)
    local color = addon.settingsDesign.Color("separator")
    texture:SetColorTexture(color[1], color[2], color[3], color[4])
    texture.statsProColorRole = "separator"
end

function addon.settingsDesign.RefreshShellButton(button)
    local role = addon.settingsDesign.components.buttons[button.statsProButtonRole]
    if not role then return end
    local state
    if not button:IsEnabled() then
        state = "disabled"
    elseif button.statsProPressed then
        state = "pressed"
    elseif button.statsProHovered then
        state = "hover"
    else
        state = "normal"
    end
    local style = role[state]
    local bg = addon.settingsDesign.Color(style.bg)
    local border = addon.settingsDesign.Color(style.border)
    button:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
    button:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
    if button.statsProText then
        addon.settingsDesign.SetRegionColor(button.statsProText, style.text)
    end
    button.statsProButtonState = state
end

function addon.settingsDesign.OnButtonEnter(button)
    button.statsProHovered = true
    addon.settingsDesign.RefreshShellButton(button)
end

function addon.settingsDesign.OnButtonLeave(button)
    button.statsProHovered = false
    button.statsProPressed = false
    addon.settingsDesign.RefreshShellButton(button)
end

function addon.settingsDesign.OnButtonDown(button)
    button.statsProPressed = true
    addon.settingsDesign.RefreshShellButton(button)
end

function addon.settingsDesign.OnButtonUp(button)
    button.statsProPressed = false
    addon.settingsDesign.RefreshShellButton(button)
end

function addon.settingsDesign.OnButtonDisabled(button)
    button.statsProHovered = false
    button.statsProPressed = false
    addon.settingsDesign.RefreshShellButton(button)
end

function addon.settingsDesign.CreateShellButton(parent, name, roleName, textRole)
    local button = CreateFrame("Button", name, parent, "BackdropTemplate")
    addon.settingsDesign.ApplySurface(button, "raised")
    local text = button:CreateFontString(nil, "OVERLAY")
    addon.settingsDesign.ApplyTextRole(text, textRole or "button")
    text:SetPoint("LEFT", addon.settingsDesign.tokens.spacing.sm, 0)
    text:SetPoint("RIGHT", -addon.settingsDesign.tokens.spacing.sm, 0)
    text:SetJustifyH("CENTER")
    text:SetWordWrap(false)
    text:SetMaxLines(1)
    button:SetFontString(text)
    button.statsProText = text
    button.statsProButtonRole = roleName or "field"
    button:SetScript("OnEnter", addon.settingsDesign.OnButtonEnter)
    button:SetScript("OnLeave", addon.settingsDesign.OnButtonLeave)
    button:SetScript("OnMouseDown", addon.settingsDesign.OnButtonDown)
    button:SetScript("OnMouseUp", addon.settingsDesign.OnButtonUp)
    button:HookScript("OnEnable", addon.settingsDesign.RefreshShellButton)
    button:HookScript("OnDisable", addon.settingsDesign.OnButtonDisabled)
    addon.settingsDesign.RegisterControl(button, "button")
    addon.settingsDesign.AttachTooltip(button, addon.settingsDesign.ControlTextTooltip)
    addon.settingsDesign.RefreshShellButton(button)
    return button
end

function addon.settingsDesign.RefreshTab(button)
    local selected = button.statsProSelected == true
    local pressed = button.statsProPressed == true
    local hovered = button.statsProHovered == true
    local fill = addon.settingsDesign.Color(pressed and "pressed"
        or (hovered and "hover" or (selected and "accentMuted" or "raised")))
    local fillAlpha = selected and not pressed and not hovered and fill[4]
        or (not selected and not pressed and not hovered and 0 or fill[4])
    button.statsProFill:SetColorTexture(fill[1], fill[2], fill[3], fillAlpha)
    if selected then button.statsProSelectedLine:Show() else button.statsProSelectedLine:Hide() end
    addon.settingsDesign.SetRegionColor(button.statsProText,
        (selected or hovered or pressed) and "textPrimary" or "textSecondary")
    button.statsProTabState = selected and "selected"
        or (pressed and "pressed" or (hovered and "hover" or "normal"))
end

function addon.settingsDesign.SetTabSelected(button, selected)
    button.statsProSelected = selected == true
    addon.settingsDesign.RefreshTab(button)
end

function addon.settingsDesign.CreateTab(parent, label)
    local button = CreateFrame("Button", nil, parent)
    local fill = button:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints(button)
    button.statsProFill = fill
    local line = button:CreateTexture(nil, "ARTWORK")
    line:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT",
        addon.settingsDesign.tokens.spacing.md, 0)
    line:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT",
        -addon.settingsDesign.tokens.spacing.md, 0)
    line:SetHeight(2)
    local accent = addon.settingsDesign.Color("accent")
    line:SetColorTexture(accent[1], accent[2], accent[3], accent[4])
    line:Hide()
    button.statsProSelectedLine = line
    local text = button:CreateFontString(nil, "OVERLAY")
    addon.settingsDesign.ApplyTextRole(text, "tab")
    text:SetPoint("CENTER", 0, 1)
    PushLocalizedLabel(function() text:SetText(L(label)) end)
    button.statsProText = text
    button:SetScript("OnEnter", addon.settingsDesign.OnButtonEnter)
    button:SetScript("OnLeave", addon.settingsDesign.OnButtonLeave)
    button:SetScript("OnMouseDown", addon.settingsDesign.OnButtonDown)
    button:SetScript("OnMouseUp", addon.settingsDesign.OnButtonUp)
    button:HookScript("OnEnter", addon.settingsDesign.RefreshTab)
    button:HookScript("OnLeave", addon.settingsDesign.RefreshTab)
    button:HookScript("OnMouseDown", addon.settingsDesign.RefreshTab)
    button:HookScript("OnMouseUp", addon.settingsDesign.RefreshTab)
    addon.settingsDesign.RefreshTab(button)
    return button
end

function addon.settingsDesign.RefreshScrollThumb(scrollBar)
    local thumb = scrollBar.statsProThumb
    if not thumb then return end
    local color = addon.settingsDesign.Color(
        (scrollBar.statsProHovered or scrollBar.statsProPressed) and "accent" or "textMuted")
    thumb:SetVertexColor(color[1], color[2], color[3],
        (scrollBar.statsProHovered or scrollBar.statsProPressed) and 0.78 or 0.62)
end

function addon.settingsDesign.OnScrollEnter(scrollBar)
    scrollBar.statsProHovered = true
    addon.settingsDesign.RefreshScrollThumb(scrollBar)
end

function addon.settingsDesign.OnScrollLeave(scrollBar)
    scrollBar.statsProHovered = false
    scrollBar.statsProPressed = false
    addon.settingsDesign.RefreshScrollThumb(scrollBar)
end

function addon.settingsDesign.OnScrollDown(scrollBar)
    scrollBar.statsProPressed = true
    addon.settingsDesign.RefreshScrollThumb(scrollBar)
end

function addon.settingsDesign.OnScrollUp(scrollBar)
    scrollBar.statsProPressed = false
    addon.settingsDesign.RefreshScrollThumb(scrollBar)
end

function addon.settingsDesign.StyleScrollButton(button)
    if not button then return end
    local muted = addon.settingsDesign.Color("textMuted")
    local accent = addon.settingsDesign.Color("accent")
    local normal = type(button.GetNormalTexture) == "function" and button:GetNormalTexture()
    local highlight = type(button.GetHighlightTexture) == "function" and button:GetHighlightTexture()
    local pushed = type(button.GetPushedTexture) == "function" and button:GetPushedTexture()
    local disabled = type(button.GetDisabledTexture) == "function" and button:GetDisabledTexture()
    for _, texture in pairs({ normal, highlight, pushed, disabled }) do
        if texture and type(texture.SetDesaturated) == "function" then texture:SetDesaturated(true) end
    end
    if normal then normal:SetVertexColor(muted[1], muted[2], muted[3], 0.62) end
    if highlight then highlight:SetVertexColor(accent[1], accent[2], accent[3], 0.82) end
    if pushed then pushed:SetVertexColor(accent[1], accent[2], accent[3], 0.92) end
    if disabled then disabled:SetVertexColor(muted[1], muted[2], muted[3], 0.24) end
    button:SetAlpha(1)
    button.statsProScrollbarButtonStyled = true
end

function addon.settingsDesign.StyleScrollFrame(scrollFrame)
    local frameName = scrollFrame:GetName()
    local scrollBar = scrollFrame.ScrollBar
        or (frameName and _G[frameName .. "ScrollBar"])
    if not scrollBar then return end
    local thumb = scrollBar.ThumbTexture
        or (type(scrollBar.GetThumbTexture) == "function" and scrollBar:GetThumbTexture())
    scrollBar.statsProThumb = thumb
    scrollBar:HookScript("OnEnter", addon.settingsDesign.OnScrollEnter)
    scrollBar:HookScript("OnLeave", addon.settingsDesign.OnScrollLeave)
    scrollBar:HookScript("OnMouseDown", addon.settingsDesign.OnScrollDown)
    scrollBar:HookScript("OnMouseUp", addon.settingsDesign.OnScrollUp)
    addon.settingsDesign.RefreshScrollThumb(scrollBar)
    local up = scrollBar.ScrollUpButton
        or (frameName and _G[frameName .. "ScrollBarScrollUpButton"])
    local down = scrollBar.ScrollDownButton
        or (frameName and _G[frameName .. "ScrollBarScrollDownButton"])
    addon.settingsDesign.StyleScrollButton(up)
    addon.settingsDesign.StyleScrollButton(down)
    local track = scrollFrame:CreateTexture(nil, "BACKGROUND")
    local geometry = addon.settingsDesign.tokens.geometry
    track:SetPoint("TOP", scrollBar, "TOP", 0, -geometry.scrollbarArrowInset)
    track:SetPoint("BOTTOM", scrollBar, "BOTTOM", 0, geometry.scrollbarArrowInset)
    track:SetWidth(geometry.scrollbarTrackWidth)
    local trackColor = addon.settingsDesign.Color("borderSoft")
    track:SetColorTexture(trackColor[1], trackColor[2], trackColor[3], 0.48)
    track.statsProColorRole = "scrollbarTrack"
    scrollFrame.statsProScrollTrack = track
    scrollFrame.statsProScrollbarStyled = true
end

addon.panelEditRuntime.SetRequested = function(requested)
    addon.panelEditRuntime.requested = requested == true
    addon.panelEditRuntime.Refresh()
end
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
-- CursorSection: localized casing is preserved; a calm inset band carries hierarchy
-- without forcing every heading through the accent color.
local function CursorSection(c, label)
    local band = CreateFrame("Frame", nil, c.parent, "BackdropTemplate")
    band:SetPoint("TOPLEFT", c.parent, "TOPLEFT", c.padX, c.y + 4)
    band:SetPoint("TOPRIGHT", c.parent, "TOPRIGHT", -c.padX, c.y + 4)
    band:SetHeight(addon.settingsDesign.tokens.geometry.sectionHeaderHeight)
    band:EnableMouse(false)
    addon.settingsDesign.ApplySurface(band, "section")
    local hdr = band:CreateFontString(nil, "OVERLAY")
    addon.settingsDesign.ApplyTextRole(hdr, "section")
    hdr:SetPoint("LEFT", 8, 0)
    hdr:SetPoint("RIGHT", -8, 0)
    hdr:SetJustifyH("LEFT")
    hdr:SetWordWrap(false)
    hdr:SetMaxLines(1)
    PushLocalizedLabel(function() hdr:SetText(L(label)) end)
    c.parent.statsProSections = c.parent.statsProSections or {}
    tinsert(c.parent.statsProSections, { key = label, surface = band, text = hdr, y = c.y })
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
    if addon.__statsproSmoke == true then
        slider.statsProDBKey = dbKey
        slider.statsProDBType = "number"
    end
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
    addon.settingsDesign.StyleSlider(
        slider, lbl, _G[name .. "Text"], _G[name .. "Low"], _G[name .. "High"])

    local reverting = false
    slider:SetScript("OnValueChanged", function(self, value)
        if reverting then return end
        if not addon.appearancePresets.BeforeManualEdit(dbKey) then
            local current = NUMBER_SETTING_META[dbKey]
                and GetNumberDB(dbKey) or GetDB(dbKey)
            reverting = true
            self:SetValue(current)
            reverting = false
            _G[self:GetName() .. "Text"]:SetText(string.format(valueFmt, current))
            return
        end
        local previous = NUMBER_SETTING_META[dbKey] and GetNumberDB(dbKey) or GetDB(dbKey)
        local normalized = NUMBER_SETTING_META[dbKey] and NormalizeNumberSetting(dbKey, value) or value
        local db = addon.dbRuntime.GetWritableSettings(true, dbKey)
        if not db then
            reverting = true
            self:SetValue(previous)
            reverting = false
            _G[self:GetName() .. "Text"]:SetText(string.format(valueFmt, previous))
            return
        end
        _G[self:GetName() .. "Text"]:SetText(string.format(valueFmt, normalized))
        db[dbKey] = normalized
        local accepted = onChange and onChange(normalized, previous)
        if accepted == false then
            db[dbKey] = previous
            reverting = true
            self:SetValue(previous)
            reverting = false
            _G[self:GetName() .. "Text"]:SetText(string.format(valueFmt, previous))
        elseif normalized ~= previous and addon.appearancePresets.allowlist[dbKey] then
            addon.appearancePresets.MarkCustom(db)
        end
    end)

    PushRefresher(function()
        local v = NUMBER_SETTING_META[dbKey] and GetNumberDB(dbKey) or GetDB(dbKey)
        reverting = true
        slider:SetValue(v)
        reverting = false
        _G[slider:GetName() .. "Text"]:SetText(string.format(valueFmt, v))
        addon.settingsDesign.RefreshControl(slider)
    end)

    cd.y = sliderY - 50
    return slider
end

function addon.appearancePresets.ValuesEqual(left, right, seen)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    seen = seen or {}
    if seen[left] == right then return true end
    seen[left] = right
    for key, value in pairs(left) do
        if not addon.appearancePresets.ValuesEqual(value, right[key], seen) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

function addon.appearancePresets.Clone(value)
    local copied, ok = addon.dbRuntime.CloneSerializable(value)
    if not ok then return nil end
    return copied
end

function addon.appearancePresets.CapturePayload(settings)
    local payload = {}
    for key in pairs(addon.appearancePresets.allowlist) do
        local value = settings and rawget(settings, key) or nil
        if value == nil then value = defaults[key] end
        payload[key] = addon.appearancePresets.Clone(value)
        if payload[key] == nil and value ~= nil then return nil end
    end
    return payload
end

function addon.appearancePresets.ResolveValue(key, persisted)
    local session = addon.appearancePresets.session
    if session and addon.appearancePresets.allowlist[key]
        and session.candidate and session.candidate[key] ~= nil then
        return session.candidate[key]
    end
    return persisted
end

function addon.appearancePresets.CurrentID(settings)
    settings = settings or addon.dbRuntime.GetActiveSettings()
    local marker = settings and rawget(settings, "appearancePresetID") or nil
    local definition = addon.appearancePresets.definitions[marker]
    if not definition then return "custom" end
    local payload = addon.appearancePresets.CapturePayload(settings)
    local expected = addon.appearancePresets.Clone(definition)
    if expected then expected.label = nil end
    if payload and expected and addon.appearancePresets.ValuesEqual(payload, expected) then
        return marker
    end
    return "custom"
end

function addon.appearancePresets.MarkCustom(settings)
    settings = settings or addon.dbRuntime.GetWritableSettings(false)
    if settings then
        settings.appearancePresetID = "custom"
        addon.appearancePresets.RefreshUI()
    end
end

function addon.appearancePresets.ApplyRuntime()
    if (addon.appearancePresets.testRuntimeFailureCount or 0) > 0 then
        addon.appearancePresets.testRuntimeFailureCount =
            addon.appearancePresets.testRuntimeFailureCount - 1
        return false
    end
    CacheSettings()
    local applied = ApplyTextStyleToAllPanels(
        addon.fontRuntime.currentPath(), GetNumberDB("fontSize"), false)
    if not applied then return false end
    ApplyTextAlphaToAllPanels(cached.textAlpha)
    addon.readabilityConfig.applyPanelBackgroundAlphaToAllPanels(
        cached.panelBackgroundAlpha)
    ReflowAllPanels()
    for _, refresh in ipairs(configRefreshers) do
        local ok = pcall(refresh)
        if not ok then PrintMsg("Settings control refresh failed.") end
    end
    return addon:RunUpdateStatsSafe()
end

function addon.appearancePresets.RestoreCommittedRuntime()
    local session = addon.appearancePresets.session
    addon.appearancePresets.session = nil
    if addon.appearancePresets.ApplyRuntime() then return true end
    addon.appearancePresets.session = session
    addon.appearancePresets.ApplyRuntime()
    return false
end

function addon.appearancePresets.SessionIsCurrent(session, ignoreGeneration)
    if not session then return false end
    local root = addon.dbRuntime.Refresh()
    if ignoreGeneration then
        local expected = session.expected
        if not rawequal(root, expected.rootRef)
            or not rawequal(root.profiles, expected.profilesRef)
            or not rawequal(root.roleTemplates, expected.roleTemplatesRef)
            or not rawequal(root.profiles[session.profileID], expected.profileRef) then
            return false
        end
    elseif not addon.profileOps.CheckExpected(root, session.expected) then
        return false
    end
    local profile = root.profiles and root.profiles[session.profileID]
    if not profile or not addon.dbRuntime.IsCleanTable(profile.settings)
        or not rawequal(profile.settings, session.settingsRef) then return false end
    local payload = addon.appearancePresets.CapturePayload(profile.settings)
    return payload ~= nil
        and rawget(profile.settings, "appearancePresetID") == session.baselineMarker
        and addon.appearancePresets.ValuesEqual(payload, session.baseline)
end

function addon.appearancePresets.RefreshUI()
    local ui = addon.appearancePresets.ui
    if not ui then return end
    local session = addon.appearancePresets.session
    local currentID = addon.appearancePresets.CurrentID()
    local displayID = session and session.presetID or currentID
    local definition = addon.appearancePresets.definitions[displayID]
    local displayLabel = definition and L(definition.label) or L("Custom")
    if session then
        ui.status:SetText(string.format(L("Previewing: %s"), displayLabel))
    else
        ui.status:SetText(L("Preset:") .. " " .. displayLabel)
    end
    for presetID, button in pairs(ui.buttons) do
        addon.settingsDesign.SetListRowSelected(button, presetID == displayID)
        button.statsProActive = session and presetID == displayID or false
        addon.settingsDesign.RefreshControl(button)
    end
    if session then
        ui.apply:Show()
        ui.cancel:Show()
        local root = addon.dbRuntime.Refresh()
        local counts = addon.profileOps.CountReferences(root,
            addon.dbRuntime.activeProfileID)
        if counts.total > 1 then
            ui.warning:SetText(string.format(L(
                "This profile is shared by %d specs and %d other references. Applying changes all of them."),
                counts.specs, counts.total - counts.specs))
            addon.settingsDesign.SetWarningVisible(ui.warning, true)
        else
            ui.warning:SetText("")
            addon.settingsDesign.SetWarningVisible(ui.warning, false)
        end
    else
        ui.apply:Hide()
        ui.cancel:Hide()
        ui.warning:SetText("")
        addon.settingsDesign.SetWarningVisible(ui.warning, false)
    end
end

function addon.appearancePresets.CancelPreview(silent)
    if not addon.appearancePresets.session then return false end
    if not addon.appearancePresets.RestoreCommittedRuntime() then
        addon.appearancePresets.RefreshUI()
        return false, "restore-failed"
    end
    addon.appearancePresets.RefreshUI()
    if not silent then addon.profileUI.RefreshSafe() end
    return true
end

function addon.appearancePresets.StartPreview(presetID)
    local definition = addon.appearancePresets.definitions[presetID]
    if not definition then return false, "invalid-preset" end
    local currentID = addon.appearancePresets.CurrentID()
    if addon.appearancePresets.session and currentID == presetID then
        local cancelled, reason = addon.appearancePresets.CancelPreview()
        return cancelled, cancelled and "cancelled" or reason
    end
    if not addon.appearancePresets.session and currentID == presetID then
        return false, "no-change"
    end
    if not addon.profileRuntime.CloseOwnedSettingsModals() then
        return false, "close-failed"
    end
    local root, reason = addon.profileOps.Gate(nil, false)
    if not root then return false, reason end
    local profileID = addon.dbRuntime.activeProfileID
    local profile = root.profiles and root.profiles[profileID]
    if not profile or not addon.dbRuntime.IsCleanTable(profile.settings) then
        return false, "missing-profile"
    end
    local candidate = addon.appearancePresets.Clone(definition)
    local baseline = addon.appearancePresets.CapturePayload(profile.settings)
    if not candidate or not baseline then return false, "clone-failed" end
    candidate.label = nil
    addon.appearancePresets.session = {
        presetID = presetID,
        candidate = candidate,
        baseline = baseline,
        expected = addon.profileUI.CaptureExpected(nil, nil, profileID),
        profileID = profileID,
        settingsRef = profile.settings,
        baselineMarker = rawget(profile.settings, "appearancePresetID"),
    }
    addon.appearancePresets.session.expected.settingsRef = profile.settings
    if not addon.appearancePresets.ApplyRuntime() then
        local restored = addon.appearancePresets.RestoreCommittedRuntime()
        addon.appearancePresets.RefreshUI()
        return false, restored and "preview-failed" or "restore-failed"
    end
    addon.appearancePresets.RefreshUI()
    addon.profileUI.RefreshSafe()
    return true
end

function addon.appearancePresets.ApplyPreview()
    local session = addon.appearancePresets.session
    if not session then return false, "no-preview" end
    if not addon.appearancePresets.SessionIsCurrent(session) then
        local cancelled, reason = addon.appearancePresets.CancelPreview(true)
        addon.appearancePresets.RefreshUI()
        return false, cancelled and "stale" or reason
    end
    local presetID, profileID = session.presetID, session.profileID
    local candidate = addon.appearancePresets.Clone(session.candidate)
    local expected = session.expected
    if not candidate then return false, "clone-failed" end
    if not addon.appearancePresets.RestoreCommittedRuntime() then
        addon.appearancePresets.RefreshUI()
        return false, "restore-failed"
    end
    local ok, result = addon.profileOps.Execute(expected, function(root)
        local profile = root.profiles[profileID]
        if not profile or not addon.dbRuntime.IsCleanTable(profile.settings) then
            return nil, "missing-profile"
        end
        local settings = addon.appearancePresets.Clone(profile.settings)
        if not settings then return nil, "clone-failed" end
        for key in pairs(addon.appearancePresets.allowlist) do
            settings[key] = addon.appearancePresets.Clone(candidate[key])
            if settings[key] == nil and candidate[key] ~= nil then
                return nil, "clone-failed"
            end
        end
        settings.appearancePresetID = presetID
        local changedProfile = addon.profileRuntime.ShallowCopy(profile)
        changedProfile.settings = settings
        local profiles = addon.profileRuntime.ShallowCopy(root.profiles)
        profiles[profileID] = changedProfile
        local transaction = addon.profileOps.NewTransaction(root)
        transaction.profiles = profiles
        return transaction, { reapply = true, activeProfileID = profileID }, profileID
    end)
    local retryable = result == "validate-failed" or result == "commit-failed"
        or result == "apply-failed"
    if not ok and retryable
        and addon.appearancePresets.SessionIsCurrent(session, true) then
        addon.appearancePresets.session = session
        if not addon.appearancePresets.ApplyRuntime() then
            addon.appearancePresets.ForceCancelPreview()
            result = "preview-resume-failed"
        end
    end
    addon.appearancePresets.RefreshUI()
    return ok, result
end

function addon.appearancePresets.BeforeManualEdit(key)
    if addon.appearancePresets.allowlist[key]
        and addon.appearancePresets.session then
        return addon.appearancePresets.CancelPreview(true) == true
    end
    return true
end

function addon.appearancePresets.ForceCancelPreview()
    if not addon.appearancePresets.session then return true end
    addon.appearancePresets.session = nil
    if addon.appearancePresets.ApplyRuntime() then
        addon.appearancePresets.RefreshUI()
        return true
    end
    -- A close/combat transition cannot leave a hidden retry UI with candidate
    -- overrides active. Retry committed runtime once, then hand recovery to the
    -- existing profile reapply coordinator if the client boundary is still unsafe.
    if addon.appearancePresets.ApplyRuntime() then
        addon.appearancePresets.RefreshUI()
        return true
    end
    addon.profileRuntime.forceReapply = true
    addon.profileRuntime.forceReapplyRetryCount = 0
    addon.profileRuntime.pendingResolution = true
    addon.profileRuntime.RequestResolution(false)
    addon.appearancePresets.RefreshUI()
    return false
end

-- Footer Reset and /ss reset share the same confirmed, transactional active-profile
-- operation. The implementation lives on addon.resetRuntime to avoid another broad
-- closure in this near-limit Lua 5.1 chunk.
local function ResetToDefaults()
    return addon.resetRuntime.Request()
end

addon.profileRuntime.closeOwnedSettingsModals = function()
    if addon.appearancePresets and addon.appearancePresets.session
        and type(addon.appearancePresets.CancelPreview) == "function" then
        local restored = addon.appearancePresets.CancelPreview(true)
        if not restored then error("appearance preview restore failed") end
    end
    if type(addon.profileUI.CloseOperationDialog) == "function" then
        addon.profileUI.CloseOperationDialog()
    end
    if type(addon.profileRuntime.cancelLanguagePreview) == "function" then
        addon.profileRuntime.cancelLanguagePreview()
    end
    local openMenu = _G.UIDROPDOWNMENU_OPEN_MENU
    local menuName
    if openMenu and type(openMenu.GetName) == "function" then
        local ok, value = pcall(openMenu.GetName, openMenu)
        if ok and addon.dbRuntime.IsCleanType(value, "string") then menuName = value end
    end
    if menuName and menuName:match("^StatsPro") then CloseDropDownMenus() end
    if type(addon.profileRuntime.cancelFontPreview) == "function" then
        addon.profileRuntime.cancelFontPreview()
    end
    if _G.StatsProFontPicker and _G.StatsProFontPicker:IsShown() then
        _G.StatsProFontPicker:Hide()
    end
    COLOR_PICKER_STATE.Close()
    if addon.legacyImport.pending then
        if type(_G.StaticPopup_Hide) == "function" then
            pcall(_G.StaticPopup_Hide, "STATSPRO_IMPORT_SWIFTSTATS")
        end
        addon.legacyImport.CancelPending()
    end
    if addon.resetRuntime.pending then
        if type(_G.StaticPopup_Hide) == "function" then
            pcall(_G.StaticPopup_Hide, "STATSPRO_RESET_ACTIVE_PROFILE")
        end
        addon.resetRuntime.CancelPending()
    end
    if addon.wipeRuntime.pending then
        if type(_G.StaticPopup_Hide) == "function" then
            pcall(_G.StaticPopup_Hide, "STATSPRO_WIPE_ALL_DATA")
        end
        addon.wipeRuntime.CancelPending()
    end
end

function addon.legacyImport.CloseOwnedSettingsModals()
    addon.profileRuntime.closeOwnedSettingsModals()
end

addon.profileRuntime.applyActiveSettings = function()
    CacheSettings()
    if RefreshPersistentLocalization then
        local localized = pcall(RefreshPersistentLocalization)
        if not localized then PrintMsg("Launcher localization refresh failed.") end
    end
    local runtimeFont = MaybeAutoSwitchFont()
    local applied = addon.fontRuntime.applyCommittedTextStyle(
        runtimeFont or GetFontDB(), GetNumberDB("fontSize"), false, true)
    if not applied then error("profile font apply failed") end
    ApplyTextAlphaToAllPanels(cached.textAlpha)
    addon.readabilityConfig.applyPanelBackgroundAlphaToAllPanels(cached.panelBackgroundAlpha)
    LoadAllPositions()
    SetAllPanelsLockState(GetBoolDB("isLocked"))
    SetAllPanelsScale(GetNumberDB("scale"))
    addon.durabilityRuntime.MarkDirty()
    itemLevelDirty = true
    local comparison = addon.archonTargets.comparisonCache
    comparison.generation = comparison.generation + 1
    comparison.classToken = nil
    comparison.specKey = nil
    comparison.snapshotKey = nil
    comparison.entries = {}

    if #configRefreshers > 0 then
        for _, refresh in ipairs(configRefreshers) do
            local ok = pcall(refresh)
            if not ok then PrintMsg("Settings control refresh failed.") end
        end
        local localized = pcall(RefreshConfigLocalization)
        if not localized then PrintMsg("Settings localization refresh failed.") end
        addon.profileRuntime.configRefreshCount = addon.profileRuntime.configRefreshCount + 1
    end
    timeSinceLastUpdate = 0
    if not addon:RunUpdateStatsSafe() then error("profile render failed") end
    addon.profileRuntime.applyCount = addon.profileRuntime.applyCount + 1
end

function addon.legacyImport.AcceptPending()
    local pending = addon.legacyImport.pending
    addon.legacyImport.pending = nil
    if not pending then return end
    local ok, result = addon.profileOps.ImportAndAssign(
        pending.settings, pending.expected)
    if ok and type(result) == "table"
        and addon.dbRuntime.IsCleanType(result.name, "string") then
        PrintMsg(string.format(
            L("SwiftStats settings imported into new profile \"%s\"."), result.name))
        return
    end
    if result == "combat" or result == "read-only" or result == "pending"
        or result == "busy" or result == "unsafe-context" or result == "stale" then
        PrintMsg(addon.profileUI.OperationErrorText(result))
    else
        PrintMsg(L("SwiftStats import failed; profiles and assignments were preserved."))
    end
end

function addon.legacyImport.CancelPending()
    addon.legacyImport.pending = nil
end

_G.StaticPopupDialogs["STATSPRO_IMPORT_SWIFTSTATS"] = {
    text = "",
    button1 = "",
    button2 = _G.CANCEL,
    OnAccept = addon.legacyImport.AcceptPending,
    OnCancel = addon.legacyImport.CancelPending,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    exclusive = true,
    preferredIndex = 3,
}

function addon.legacyImport.Request()
    addon.legacyImport.pending = nil
    if not addon.profileRuntime.CloseOwnedSettingsModals() then
        PrintMsg(L("SwiftStats import failed; profiles and assignments were preserved."))
        return
    end
    local root, gateReason = addon.profileOps.Gate(nil, false)
    if not root then
        if gateReason == "combat" then
            PrintMsg(L("SwiftStats import is unavailable during combat. Try again after combat."))
        else
            PrintMsg(addon.profileUI.OperationErrorText(gateReason))
        end
        return
    end
    local candidate, status = addon.legacyImport.FindCandidate()
    if not candidate then
        if status == "missing" then
            PrintMsg(L("SwiftStats settings not loaded. Enable SwiftStats for one login, /reload, then run /statspro import again."))
        elseif status == "future" then
            PrintMsg(L("These settings use a newer schema and cannot be imported by this StatsPro version."))
        else
            PrintMsg(L("SwiftStats has no supported settings to import."))
        end
        return
    end
    local candidateValid, _, _, candidateSettings =
        addon.dbRuntime.ValidateRegistry(candidate)
    local guid = addon.profileRuntime.activeGUID
    local specID = addon.profileRuntime.activeSpecID
    local activeProfileID = addon.dbRuntime.activeProfileID
    if not candidateValid or not addon.dbRuntime.IsCleanTable(candidateSettings)
        or not addon.dbRuntime.IsCleanType(guid, "string") or guid == ""
        or not addon.dbRuntime.IsCleanType(specID, "number")
        or not addon.dbRuntime.IsCleanType(activeProfileID, "string") then
        PrintMsg(L("SwiftStats import failed; profiles and assignments were preserved."))
        return
    end
    addon.legacyImport.pending = {
        settings = candidateSettings,
        expected = addon.profileUI.CaptureExpected(guid, specID, activeProfileID),
    }
    local definition = _G.StaticPopupDialogs["STATSPRO_IMPORT_SWIFTSTATS"]
    definition.text = L("Import compatible SwiftStats settings into a new profile for the current character and specialization? Existing profiles, other assignments, account settings, and SwiftStats data will stay unchanged.")
    definition.button1 = L("Import")
    definition.button2 = _G.CANCEL
    local ok, popup = pcall(_G.StaticPopup_Show, "STATSPRO_IMPORT_SWIFTSTATS")
    if not ok or not popup then
        addon.legacyImport.pending = nil
        PrintMsg(L("SwiftStats import failed; profiles and assignments were preserved."))
    end
end

function addon.resetRuntime.AcceptPending()
    local pending = addon.resetRuntime.pending
    addon.resetRuntime.pending = nil
    if not pending then return end
    local ok, result = addon.profileOps.ResetCurrent(
        pending.profileID, pending.expected)
    if ok then
        PrintMsg(L("Settings reset to defaults"))
    else
        PrintMsg(addon.profileUI.OperationErrorText(result))
    end
end

function addon.resetRuntime.CancelPending()
    addon.resetRuntime.pending = nil
end

_G.StaticPopupDialogs["STATSPRO_RESET_ACTIVE_PROFILE"] = {
    text = "",
    button1 = "",
    button2 = _G.CANCEL,
    OnAccept = addon.resetRuntime.AcceptPending,
    OnCancel = addon.resetRuntime.CancelPending,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    exclusive = true,
    preferredIndex = 3,
}

function addon.resetRuntime.Request()
    addon.resetRuntime.pending = nil
    if not addon.profileRuntime.CloseOwnedSettingsModals() then return false end
    local root, gateReason = addon.profileOps.Gate(nil, false)
    if not root then
        PrintMsg(addon.profileUI.OperationErrorText(gateReason))
        return false
    end
    local profileID = addon.dbRuntime.activeProfileID
    local profile = profileID and root.profiles[profileID] or nil
    local guid = addon.profileRuntime.activeGUID
    local specID = addon.profileRuntime.activeSpecID
    if not profile or not addon.dbRuntime.IsCleanType(guid, "string")
        or not addon.dbRuntime.IsCleanType(specID, "number") then
        PrintMsg(addon.profileUI.OperationErrorText("missing-context"))
        return false
    end
    local references = addon.profileOps.CountReferences(root, profileID)
    local otherReferences = references.characterDefaults
        + references.accountDefault + references.roleTemplates
    addon.resetRuntime.pending = {
        profileID = profileID,
        expected = addon.profileUI.CaptureExpected(guid, specID, profileID),
    }
    local definition = _G.StaticPopupDialogs["STATSPRO_RESET_ACTIVE_PROFILE"]
    definition.text = string.format(
        L("Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."),
        profile.name, references.specs, otherReferences)
    definition.button1 = L("Confirm")
    definition.button2 = _G.CANCEL
    local ok, popup = pcall(_G.StaticPopup_Show, "STATSPRO_RESET_ACTIVE_PROFILE")
    if not ok or not popup then
        addon.resetRuntime.pending = nil
        PrintMsg(addon.profileUI.OperationErrorText("open-failed"))
        return false
    end
    return true
end

function addon.wipeRuntime.AcceptPending()
    local pending = addon.wipeRuntime.pending
    addon.wipeRuntime.pending = nil
    if not pending then return end
    local ok, result = addon.profileOps.FullWipe(pending.expected)
    if ok then
        PrintMsg(L("All StatsPro data reset to defaults."))
    else
        PrintMsg(addon.profileUI.OperationErrorText(result))
    end
end

function addon.wipeRuntime.CancelPending()
    addon.wipeRuntime.pending = nil
end

_G.StaticPopupDialogs["STATSPRO_WIPE_ALL_DATA"] = {
    text = "",
    button1 = "",
    button2 = _G.CANCEL,
    OnAccept = addon.wipeRuntime.AcceptPending,
    OnCancel = addon.wipeRuntime.CancelPending,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    exclusive = true,
    preferredIndex = 3,
}

function addon.wipeRuntime.Request()
    addon.wipeRuntime.pending = nil
    if not addon.profileRuntime.CloseOwnedSettingsModals() then return false end
    local root, gateReason = addon.profileOps.Gate(nil, false)
    if not root then
        PrintMsg(addon.profileUI.OperationErrorText(gateReason))
        return false
    end
    local profileID = addon.dbRuntime.activeProfileID
    local guid = addon.profileRuntime.activeGUID
    local specID = addon.profileRuntime.activeSpecID
    if not addon.dbRuntime.IsCleanType(profileID, "string")
        or not addon.dbRuntime.IsCleanType(guid, "string")
        or not addon.dbRuntime.IsCleanType(specID, "number") then
        PrintMsg(addon.profileUI.OperationErrorText("missing-context"))
        return false
    end
    addon.wipeRuntime.pending = {
        expected = addon.profileUI.CaptureExpected(guid, specID, profileID),
    }
    local definition = _G.StaticPopupDialogs["STATSPRO_WIPE_ALL_DATA"]
    definition.text = L("Reset all StatsPro data? This permanently removes every profile, character and specialization assignment, role template, account setting, and saved position. SwiftStats data will stay unchanged.")
    definition.button1 = L("Confirm")
    definition.button2 = _G.CANCEL
    local ok, popup = pcall(_G.StaticPopup_Show, "STATSPRO_WIPE_ALL_DATA")
    if not ok or not popup then
        addon.wipeRuntime.pending = nil
        PrintMsg(addon.profileUI.OperationErrorText("open-failed"))
        return false
    end
    return true
end

function addon.archonTargets.GetTargetSnapshotDropdownValue()
    return addon.archonTargets.NormalizeSnapshotKey(GetDB("targetSnapshot"))
end

function addon.archonTargets.SelectTargetSnapshotDropdownValue(value, opt, dropdown)
    local db = addon.dbRuntime.GetWritableSettings(true)
    if not db then
        CloseDropDownMenus()
        return false
    end
    db.targetSnapshot = addon.archonTargets.NormalizeSnapshotKey(value)
    CacheSettings()
    UIDropDownMenu_SetText(dropdown, L(opt.label))
    CloseDropDownMenus()
    addon:RunUpdateStatsSafe()
end
-- WARNING: OpenConfigMenu is already near Lua 5.1's 60-upvalue function limit.
-- Keep these as global bridge references instead of local upvalues inside the builder.
_G.StatsProTargetSnapshotDropdownOptions = addon.archonTargets.snapshotOptions
_G.StatsProGetTargetSnapshotDropdownValue = addon.archonTargets.GetTargetSnapshotDropdownValue
_G.StatsProSelectTargetSnapshotDropdownValue = addon.archonTargets.SelectTargetSnapshotDropdownValue

function addon.profileUI.FormatSpecName(specID, explicitName)
    if addon.dbRuntime.IsCleanType(explicitName, "string") and explicitName ~= "" then
        return explicitName
    end
    return string.format(L("Spec %d"), specID)
end

function addon.profileUI.FindProfile(model, profileID)
    for _, profile in ipairs(model and model.profiles or {}) do
        if profile.profileID == profileID then return profile end
    end
    return nil
end

function addon.profileUI.GetAssignedProfileID(model, character, spec)
    if spec then return spec.profileID end
    return character and (character.defaultProfileID or model.accountDefaultProfileID) or nil
end

function addon.profileUI.ContextLabel(character, spec)
    if not character then return "" end
    if spec then
        return character.displayName .. " / "
            .. addon.profileUI.FormatSpecName(spec.specID, spec.specName)
    end
    return character.displayName .. " / " .. L("Character default")
end

function addon.profileUI.RoleLabel(role)
    if role == "TANK" then return L("Tank") end
    if role == "HEALER" then return L("Healer") end
    if role == "DAMAGER" then return L("Damage") end
    return role or ""
end

function addon.profileUI.RoleTemplateChoices(model)
    local choices = {}
    for _, role in ipairs(addon.profileOps.roleOrder) do
        local template = model and model.roleTemplates and model.roleTemplates[role] or nil
        choices[#choices + 1] = {
            kind = "role",
            role = role,
            profileID = template and template.profileID or nil,
            label = addon.profileUI.RoleLabel(role) .. " - "
                .. (template and template.profileName or ""),
        }
    end
    return choices
end

function addon.profileUI.CaptureExpected(guid, specID, profileID)
    local root = addon.dbRuntime.Refresh()
    local expected = {
        rootRef = root,
        generation = addon.dbRuntime.generation,
        activeProfileID = addon.dbRuntime.activeProfileID,
        profilesRef = root.profiles,
        roleTemplatesRef = root.roleTemplates,
    }
    if profileID and root.profiles and root.profiles[profileID] then
        expected.profileID = profileID
        expected.profileRef = root.profiles[profileID]
    end
    if guid then
        expected.guid = guid
        expected.specID = specID
        expected.assignmentID = addon.profileOps.ResolveAssignment(root, guid, specID)
        expected.characterRef = root.characters and root.characters[guid] or nil
    end
    return expected
end

function addon.profileUI.OperationErrorText(reason)
    if reason == "invalid-name" then return L("Enter a valid profile name.") end
    if reason == "name-too-long" then
        return string.format(L("Profile names can contain at most %d characters."),
            addon.profileOps.maxNameCodepoints)
    end
    if reason == "duplicate-name" then return L("A profile with this name already exists.") end
    if reason == "stale" then return L("Profiles changed; review and try again.") end
    if reason == "combat" then return L("Profile changes are unavailable during combat.") end
    if reason == "read-only" then return L("Compatibility mode - profiles are read-only.") end
    if reason == "pending" or reason == "busy" or reason == "unsafe-context" then
        return L("Waiting for a safe profile context.")
    end
    if reason == "last-profile" then return L("The last profile cannot be deleted.") end
    if reason == "replacement-required" then return L("Choose a replacement profile.") end
    if reason == "current-character" then return L("The current character cannot be forgotten.") end
    if reason == "same-profile" or reason == "same-context" or reason == "no-change" then
        return L("Nothing changed.")
    end
    return L("Profile operation failed. Review the selection and try again.")
end

function addon.profileUI.RemoveSpecialFrame(frameName)
    for index = #UISpecialFrames, 1, -1 do
        if UISpecialFrames[index] == frameName then
            tremove(UISpecialFrames, index)
        end
    end
end

function addon.profileUI.CancelSpecialFrameRestore(frameName)
    local tokens = addon.profileUI.specialFrameRestoreTokens
    if type(tokens) ~= "table" then
        tokens = {}
        addon.profileUI.specialFrameRestoreTokens = tokens
    end
    tokens[frameName] = (tokens[frameName] or 0) + 1
    return tokens[frameName]
end

function addon.profileUI.PushSpecialFrame(frameName)
    addon.profileUI.CancelSpecialFrameRestore(frameName)
    addon.profileUI.RemoveSpecialFrame(frameName)
    tinsert(UISpecialFrames, frameName)
end

function addon.profileUI.DeferSpecialFrameRestore(frameName, shouldRestore)
    addon.profileUI.RemoveSpecialFrame(frameName)
    local token = addon.profileUI.CancelSpecialFrameRestore(frameName)
    C_Timer.After(0, function()
        local tokens = addon.profileUI.specialFrameRestoreTokens
        if type(tokens) ~= "table" or tokens[frameName] ~= token then return end
        if type(shouldRestore) ~= "function" or shouldRestore() ~= true then return end
        addon.profileUI.PushSpecialFrame(frameName)
    end)
end

function addon.profileUI.BuildOperationUI(manager)
    local ui = addon.profileUI
    local actionScroll = CreateFrame(
        "ScrollFrame", "StatsProProfileActionsScroll", manager, "UIPanelScrollFrameTemplate")
    actionScroll:SetPoint("TOPLEFT", 258, -176)
    actionScroll:SetPoint("BOTTOMRIGHT", -34, 88)
    local actionChild = CreateFrame("Frame", nil, actionScroll)
    actionChild:SetSize(318, 590)
    actionScroll:SetScrollChild(actionChild)

    local managedLabel = actionChild:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(managedLabel, 11, "OUTLINE")
    managedLabel:SetPoint("TOPLEFT", 8, -4)
    PushLocalizedLabel(function() managedLabel:SetText(L("Profile to manage:")) end)

    local profileSelector = addon.settingsDesign.CreateShellButton(
        actionChild, "StatsProManagedProfileButton", "field")
    profileSelector:SetPoint("TOPLEFT", 6, -22)
    profileSelector:SetSize(addon.settingsDesign.tokens.geometry.actionWidth,
        addon.settingsDesign.tokens.geometry.controlHitTarget)

    local managedImpact = actionChild:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(managedImpact, 10)
    managedImpact:SetPoint("TOPLEFT", 8, -50)
    managedImpact:SetPoint("TOPRIGHT", -12, -50)
    managedImpact:SetJustifyH("LEFT")
    addon.settingsDesign.StyleStatusText(managedImpact)

    local operationStatus = actionChild:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(operationStatus, 10)
    operationStatus:SetPoint("TOPLEFT", 8, -70)
    operationStatus:SetPoint("TOPRIGHT", -12, -70)
    operationStatus:SetJustifyH("LEFT")
    operationStatus:SetWordWrap(true)
    operationStatus:SetMaxLines(2)
    addon.settingsDesign.StyleStatusText(operationStatus)

    local function createAction(name, labelKey, y, roleName)
        local button = addon.settingsDesign.CreateShellButton(
            actionChild, name, roleName or "field")
        button:SetPoint("TOPLEFT", 6, y)
        button:SetSize(addon.settingsDesign.tokens.geometry.actionWidth,
            addon.settingsDesign.tokens.geometry.actionHeight)
        PushLocalizedLabel(function() button:SetText(L(labelKey)) end)
        return button
    end

    local assignButton = createAction(
        "StatsProProfileAssignButton", "Assign to selected context", -104, "primary")
    local newButton = createAction(
        "StatsProProfileNewButton", "New from defaults...", -132)
    local duplicateButton = createAction(
        "StatsProProfileDuplicateButton", "Duplicate profile...", -160)
    local renameButton = createAction(
        "StatsProProfileRenameButton", "Rename profile...", -188)
    local copyButton = createAction(
        "StatsProProfileCopyButton", "Copy settings to assigned profile...", -216)
    local swapButton = createAction(
        "StatsProProfileSwapButton", "Swap assignments...", -244)
    local resetButton = createAction(
        "StatsProProfileResetButton", "Reset active profile...", -272, "destructive")
    local deleteButton = createAction(
        "StatsProProfileDeleteButton", "Delete profile...", -300, "destructive")
    local forgetButton = createAction(
        "StatsProProfileForgetButton", "Forget character...", -328, "destructive")

    local selectedCharacterTitle = actionChild:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(selectedCharacterTitle, 11, "OUTLINE")
    selectedCharacterTitle:SetPoint("TOPLEFT", 8, -366)
    PushLocalizedLabel(function()
        selectedCharacterTitle:SetText(L("Selected character"))
    end)

    local selectedCharacterSummary = actionChild:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(selectedCharacterSummary, 10)
    selectedCharacterSummary:SetPoint("TOPLEFT", 8, -384)
    selectedCharacterSummary:SetPoint("TOPRIGHT", -12, -384)
    selectedCharacterSummary:SetJustifyH("LEFT")
    selectedCharacterSummary:SetWordWrap(false)
    selectedCharacterSummary:SetMaxLines(1)
    addon.settingsDesign.StyleStatusText(selectedCharacterSummary)

    local useAllSpecsButton = createAction(
        "StatsProProfileUseAllSpecsButton", "Use profile for all known specs...", -406)
    local independentButton = createAction(
        "StatsProProfileMakeIndependentButton", "Make shared specs independent...", -434)

    local futureContextsTitle = actionChild:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(futureContextsTitle, 11, "OUTLINE")
    futureContextsTitle:SetPoint("TOPLEFT", 8, -470)
    PushLocalizedLabel(function()
        futureContextsTitle:SetText(L("Future new contexts"))
    end)

    local roleTemplateSummary = {}
    for index, role in ipairs(addon.profileOps.roleOrder) do
        local line = actionChild:CreateFontString(nil, "OVERLAY")
        RegisterConfigFont(line, 10)
        line:SetPoint("TOPLEFT", 8, -472 - (index * 18))
        line:SetPoint("TOPRIGHT", -12, -472 - (index * 18))
        line:SetJustifyH("LEFT")
        line:SetWordWrap(false)
        line:SetMaxLines(1)
        addon.settingsDesign.StyleStatusText(line)
        roleTemplateSummary[role] = line
    end

    local roleTemplateButton = createAction(
        "StatsProProfileRoleTemplateButton", "Set future role template...", -550)

    local blocker = CreateFrame("Frame", "StatsProProfileOperationBlocker", UIParent)
    blocker:SetAllPoints(UIParent)
    blocker:EnableMouse(true)
    blocker:SetFrameStrata("DIALOG")
    blocker:SetFrameLevel(manager:GetFrameLevel() + 9)
    blocker:Hide()

    local dialog = CreateFrame(
        "Frame", "StatsProProfileOperationDialog", manager, "BackdropTemplate")
    dialog:SetPoint("CENTER", manager, "CENTER", 0, 0)
    dialog:SetSize(440, 340)
    addon.settingsDesign.ApplySurface(dialog, "window")
    dialog:EnableMouse(true)
    dialog:SetFrameStrata("DIALOG")
    dialog:SetFrameLevel(manager:GetFrameLevel() + 10)
    dialog:SetClampedToScreen(true)

    local dialogTitle = dialog:CreateFontString(nil, "OVERLAY")
    addon.settingsDesign.ApplyTextRole(dialogTitle, "title")
    dialogTitle:SetPoint("TOPLEFT", 18, -16)
    dialogTitle:SetPoint("TOPRIGHT", -42, -16)
    dialogTitle:SetJustifyH("LEFT")

    local dialogLine = dialog:CreateTexture(nil, "ARTWORK")
    dialogLine:SetPoint("TOPLEFT", 14, -42)
    dialogLine:SetPoint("TOPRIGHT", -14, -42)
    dialogLine:SetHeight(1)
    addon.settingsDesign.ApplySeparator(dialogLine)

    local dialogClose = CreateFrame("Button", nil, dialog, "UIPanelCloseButton")
    dialogClose:SetPoint("TOPRIGHT", -4, -4)

    local dialogMessage = dialog:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(dialogMessage, 12)
    addon.settingsDesign.SetRegionColor(dialogMessage, "textPrimary")
    dialogMessage:SetPoint("TOPLEFT", 20, -54)
    dialogMessage:SetPoint("TOPRIGHT", -20, -54)
    dialogMessage:SetJustifyH("LEFT")
    dialogMessage:SetJustifyV("TOP")
    dialogMessage:SetWordWrap(true)
    dialogMessage:SetMaxLines(12)

    local nameInput = CreateFrame(
        "EditBox", "StatsProProfileNameInput", dialog, "InputBoxTemplate")
    nameInput:SetPoint("TOPLEFT", 22, -92)
    nameInput:SetPoint("TOPRIGHT", -22, -92)
    nameInput:SetHeight(28)
    nameInput:SetAutoFocus(false)
    nameInput:SetMaxLetters(160)
    addon.settingsDesign.StyleEditBox(nameInput)

    local nameValidation = dialog:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(nameValidation, 11)
    nameValidation:SetPoint("TOPLEFT", 22, -126)
    nameValidation:SetPoint("TOPRIGHT", -22, -126)
    nameValidation:SetJustifyH("LEFT")
    nameValidation:SetWordWrap(true)
    nameValidation:SetMaxLines(2)
    addon.settingsDesign.SetRegionColor(nameValidation, "danger")

    local choiceScroll = CreateFrame(
        "ScrollFrame", "StatsProProfileChoiceScroll", dialog, "UIPanelScrollFrameTemplate")
    choiceScroll:SetPoint("TOPLEFT", 18, -52)
    choiceScroll:SetPoint("BOTTOMRIGHT", -38, 52)
    local choiceChild = CreateFrame("Frame", nil, choiceScroll)
    choiceChild:SetSize(376, 1)
    choiceScroll:SetScrollChild(choiceChild)

    local primaryButton = addon.settingsDesign.CreateShellButton(
        dialog, "StatsProProfileOperationConfirmButton", "primary")
    primaryButton:SetPoint("BOTTOMRIGHT", -126, 18)
    primaryButton:SetSize(112, 26)
    PushLocalizedLabel(function() primaryButton:SetText(L("Confirm")) end)

    local cancelButton = addon.settingsDesign.CreateShellButton(
        dialog, "StatsProProfileOperationCancelButton", "field")
    cancelButton:SetPoint("BOTTOMRIGHT", -16, 18)
    cancelButton:SetSize(102, 26)
    cancelButton:SetText(_G.CANCEL)

    ui.actionScroll = actionScroll
    ui.actionChild = actionChild
    ui.managedLabel = managedLabel
    ui.profileSelector = profileSelector
    ui.managedImpact = managedImpact
    ui.operationStatus = operationStatus
    ui.actionButtons = {
        assign = assignButton,
        create = newButton,
        duplicate = duplicateButton,
        rename = renameButton,
        copy = copyButton,
        swap = swapButton,
        reset = resetButton,
        delete = deleteButton,
        forget = forgetButton,
        useAllSpecs = useAllSpecsButton,
        independent = independentButton,
        roleTemplate = roleTemplateButton,
    }
    ui.selectedCharacterTitle = selectedCharacterTitle
    ui.selectedCharacterSummary = selectedCharacterSummary
    ui.futureContextsTitle = futureContextsTitle
    ui.roleTemplateSummary = roleTemplateSummary
    ui.operationDialog = dialog
    ui.operationBlocker = blocker
    ui.operationDialogTitle = dialogTitle
    ui.operationDialogMessage = dialogMessage
    ui.nameInput = nameInput
    ui.nameValidation = nameValidation
    ui.choiceScroll = choiceScroll
    ui.choiceChild = choiceChild
    ui.choiceRows = {}
    ui.operationPrimaryButton = primaryButton
    ui.operationCancelButton = cancelButton

    function ui.SetOperationStatus(message, failed)
        ui.lastOperationStatus = message or ""
        operationStatus:SetText(ui.lastOperationStatus)
        addon.settingsDesign.SetRegionColor(
            operationStatus, failed and "danger" or "accent")
    end

    function ui.CloseOperationDialog()
        if type(nameInput.ClearFocus) == "function" then nameInput:ClearFocus() end
        if dialog:IsShown() then dialog:Hide() end
        blocker:Hide()
    end

    function ui.ShowDialogBase(title)
        dialogTitle:SetText(title)
        dialogMessage:SetText("")
        nameValidation:SetText("")
        nameInput:Hide()
        nameValidation:Hide()
        choiceScroll:Hide()
        primaryButton:Show()
        primaryButton:Enable()
        primaryButton.statsProButtonRole = "primary"
        addon.settingsDesign.RefreshShellButton(primaryButton)
        ui.CancelSpecialFrameRestore("StatsProProfileManager")
        ui.RemoveSpecialFrame("StatsProProfileManager")
        ui.PushSpecialFrame("StatsProProfileOperationDialog")
        blocker:Show()
        dialog:Show()
    end

    function ui.RefreshNameValidation()
        local pending = ui.pendingAction
        if not pending or pending.mode ~= "name" then return end
        local root = addon.dbRuntime.Refresh()
        if addon.dbRuntime.readOnly or not addon.dbRuntime.registryReady
            or not addon.dbRuntime.IsCleanTable(root.profiles) then
            pending.normalizedName = nil
            pending.nameStatus = "read-only"
            nameValidation:SetText(ui.OperationErrorText("read-only"))
            primaryButton:Disable()
            nameInput.statsProInvalid = true
            addon.settingsDesign.RefreshControl(nameInput)
            return
        end
        local exceptID = pending.kind == "rename" and pending.profileID or nil
        local normalized, status = addon.profileOps.ValidateName(
            nameInput:GetText(), root.profiles, exceptID)
        pending.normalizedName = normalized
        pending.nameStatus = status
        if normalized then
            nameValidation:SetText("")
            primaryButton:Enable()
            nameInput.statsProInvalid = false
        else
            nameValidation:SetText(addon.profileUI.OperationErrorText(status))
            primaryButton:Disable()
            nameInput.statsProInvalid = true
        end
        addon.settingsDesign.RefreshControl(nameInput)
    end

    function ui.ShowNameDialog(kind, title, initialName, profileID, expected)
        ui.pendingAction = {
            mode = "name", kind = kind, profileID = profileID, expected = expected,
        }
        ui.ShowDialogBase(title)
        nameInput:Show()
        nameValidation:Show()
        nameInput:SetText(initialName or "")
        if type(nameInput.SetFocus) == "function" then nameInput:SetFocus() end
        if type(nameInput.HighlightText) == "function" then nameInput:HighlightText() end
        ui.RefreshNameValidation()
    end

    function ui.ShowConfirmation(kind, title, message, payload, expected)
        ui.pendingAction = {
            mode = "confirm", kind = kind, payload = payload, expected = expected,
        }
        ui.ShowDialogBase(title)
        primaryButton.statsProButtonRole = (kind == "reset" or kind == "delete"
            or kind == "forget") and "destructive" or "primary"
        addon.settingsDesign.RefreshShellButton(primaryButton)
        dialogMessage:SetText(message)
    end

    function ui.EnsureChoiceRow(index)
        local row = ui.choiceRows[index]
        if row then return row end
        row = CreateFrame("Button", nil, choiceChild)
        row:SetSize(372, 26)
        local text = row:CreateFontString(nil, "OVERLAY")
        RegisterConfigFont(text, 11)
        text:SetPoint("LEFT", 8, 0)
        text:SetPoint("RIGHT", -8, 0)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        row.text = text
        addon.settingsDesign.StyleListRow(row, text)
        row:SetScript("OnClick", function(button)
            if button.choiceData then ui.HandleChoice(button.choiceData) end
        end)
        ui.choiceRows[index] = row
        return row
    end

    function ui.PopulateChoices(choices)
        local y = -2
        for index, choice in ipairs(choices) do
            local row = ui.EnsureChoiceRow(index)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, y)
            row.choiceData = choice
            row.text:SetText(choice.label)
            row:Show()
            y = y - 28
        end
        for index = #choices + 1, #ui.choiceRows do ui.choiceRows[index]:Hide() end
        choiceChild:SetHeight(math.max(1, -y + 2))
        choiceScroll:SetVerticalScroll(0)
    end

    function ui.ShowChoices(kind, title, choices, payload, expected)
        ui.pendingAction = {
            mode = "choice", kind = kind, payload = payload, expected = expected,
        }
        ui.ShowDialogBase(title)
        primaryButton:Hide()
        choiceScroll:Show()
        ui.PopulateChoices(choices)
    end

    function ui.ProfileChoices(model, excludedProfileID)
        local choices = {}
        for _, profile in ipairs(model.profiles or {}) do
            if profile.profileID ~= excludedProfileID then
                local suffix = profile.references.total == 0 and "  [" .. L("Unused") .. "]" or ""
                choices[#choices + 1] = {
                    kind = "profile", profileID = profile.profileID,
                    label = profile.name .. suffix,
                }
            end
        end
        return choices
    end

    function ui.ContextChoices(model, excludedGUID, excludedSpecID)
        local choices = {}
        for _, character in ipairs(model.characters or {}) do
            if character.guid ~= excludedGUID or excludedSpecID ~= nil then
                choices[#choices + 1] = {
                    kind = "context", guid = character.guid, specID = nil,
                    label = ui.ContextLabel(character, nil),
                }
            end
            for _, spec in ipairs(character.specs) do
                if character.guid ~= excludedGUID or spec.specID ~= excludedSpecID then
                    choices[#choices + 1] = {
                        kind = "context", guid = character.guid, specID = spec.specID,
                        label = ui.ContextLabel(character, spec),
                    }
                end
            end
        end
        return choices
    end

    function ui.CopyScopeChoices()
        return {
            { kind = "scope", scope = "all", label = L("All settings") },
            { kind = "scope", scope = "stats", label = L("Stat and gear settings") },
            { kind = "scope", scope = "layout", label = L("Layout settings") },
            { kind = "scope", scope = "appearance", label = L("Appearance settings") },
        }
    end

    function ui.HandleOperationResult(ok, result, selectResult)
        if ok then
            if selectResult and type(result) == "string" then ui.selectedProfileID = result end
            ui.SetOperationStatus(L("Profile changes saved."), false)
            ui.CloseOperationDialog()
            ui.RefreshSafe()
            return true
        end
        ui.SetOperationStatus(ui.OperationErrorText(result), true)
        ui.CloseOperationDialog()
        ui.RefreshSafe()
        return false
    end

    function ui.ReferenceImpact(profile)
        local refs = profile and profile.references or {
            specs = 0, characterDefaults = 0, accountDefault = 0, roleTemplates = 0,
        }
        local other = refs.characterDefaults + refs.accountDefault + refs.roleTemplates
        return refs.specs, other
    end

    function ui.HandleChoice(choice)
        local pending = ui.pendingAction
        if not pending or pending.mode ~= "choice" then return end
        local model = ui.currentModel or ui.BuildViewModel()
        if pending.kind == "select-profile" then
            ui.selectedProfileID = choice.profileID
            ui.CloseOperationDialog()
            ui.RefreshSafe()
            return
        end
        if pending.kind == "assign-profile" then
            local payload = pending.payload
            local ok, result = addon.profileOps.Assign(
                payload.guid, payload.specID, choice.profileID, pending.expected)
            ui.selectedProfileID = choice.profileID
            ui.HandleOperationResult(ok, result, false)
            return
        end
        if pending.kind == "role-template" then
            local payload = pending.payload
            local profile = ui.FindProfile(model, payload.profileID)
            local template = model.roleTemplates and model.roleTemplates[choice.role] or nil
            if not profile or not template or not addon.profileOps.roleKeys[choice.role] then
                ui.HandleOperationResult(false, "stale", false)
                return
            end
            if template.profileID == profile.profileID then
                ui.HandleOperationResult(false, "no-change", false)
                return
            end
            local messageKey
            if choice.role == "TANK" then
                messageKey = "Use \"%s\" as the source for future Tank contexts? Existing assignments will not change; each new context receives an independent copy."
            elseif choice.role == "HEALER" then
                messageKey = "Use \"%s\" as the source for future Healer contexts? Existing assignments will not change; each new context receives an independent copy."
            else
                messageKey = "Use \"%s\" as the source for future Damage contexts? Existing assignments will not change; each new context receives an independent copy."
            end
            ui.ShowConfirmation("set-role-template", L("Set future role template..."),
                string.format(L(messageKey), profile.name), {
                    role = choice.role,
                    profileID = profile.profileID,
                }, pending.expected)
            return
        end
        if pending.kind == "copy-scope" then
            local payload = pending.payload
            local source = ui.FindProfile(model, payload.sourceProfileID)
            local target = ui.FindProfile(model, payload.targetProfileID)
            if not source or not target or not addon.profileOps.copyScopeKeys[choice.scope]
                and choice.scope ~= "all" then
                ui.HandleOperationResult(false, "stale", false)
                return
            end
            local specs, other = ui.ReferenceImpact(target)
            local message = string.format(
                L("Copy %s from \"%s\" to \"%s\"? This changes %d assigned specs and %d other references."),
                choice.label, source.name, target.name, specs, other)
            ui.ShowConfirmation("copy", L("Copy settings to assigned profile..."), message, {
                sourceProfileID = source.profileID,
                targetProfileID = target.profileID,
                scope = choice.scope,
            }, pending.expected)
            return
        end
        if pending.kind == "delete-replacement" then
            local payload = pending.payload
            local profile = ui.FindProfile(model, payload.profileID)
            local replacement = ui.FindProfile(model, choice.profileID)
            if not profile or not replacement then
                ui.HandleOperationResult(false, "stale", false)
                return
            end
            local specs, other = ui.ReferenceImpact(profile)
            local message = string.format(
                L("Delete profile \"%s\" and replace all references with \"%s\"? This affects %d assigned specs and %d other references."),
                profile.name, replacement.name, specs, other)
            ui.ShowConfirmation("delete", L("Delete profile..."), message, {
                profileID = profile.profileID,
                replacementProfileID = replacement.profileID,
            }, pending.expected)
            return
        end
        if pending.kind == "swap-context" then
            local payload = pending.payload
            local leftLabel = payload.label
            local rightLabel = choice.label
            local message = string.format(
                L("Swap \"%s\" and \"%s\"? Their profile settings stay unchanged."),
                leftLabel, rightLabel)
            ui.ShowConfirmation("swap", L("Swap assignments..."), message, {
                left = { guid = payload.guid, specID = payload.specID },
                right = { guid = choice.guid, specID = choice.specID },
            }, pending.expected)
        end
    end

    function ui.RunPendingAction()
        local pending = ui.pendingAction
        if not pending then return end
        if pending.mode == "name" then
            ui.RefreshNameValidation()
            local name = pending.normalizedName
            if not name then return end
            if pending.kind == "create" then
                local ok, result = addon.profileOps.Create(name, pending.expected)
                ui.HandleOperationResult(ok, result, true)
            elseif pending.kind == "duplicate" then
                local ok, result = addon.profileOps.Duplicate(
                    pending.profileID, name, pending.expected)
                ui.HandleOperationResult(ok, result, true)
            elseif pending.kind == "rename" then
                local model = ui.currentModel or ui.BuildViewModel()
                local profile = ui.FindProfile(model, pending.profileID)
                if not profile then ui.HandleOperationResult(false, "stale", false); return end
                if profile.references.total > 1 then
                    local specs, other = ui.ReferenceImpact(profile)
                    local message = string.format(
                        L("Rename shared profile \"%s\" to \"%s\"? This affects %d assigned specs and %d other references."),
                        profile.name, name, specs, other)
                    ui.ShowConfirmation("rename", L("Rename profile..."), message, {
                        profileID = pending.profileID, name = name,
                    }, pending.expected)
                else
                    local ok, result = addon.profileOps.Rename(
                        pending.profileID, name, pending.expected)
                    ui.HandleOperationResult(ok, result, false)
                end
            end
            return
        end
        if pending.mode ~= "confirm" then return end
        local payload = pending.payload or {}
        local ok, result
        if pending.kind == "rename" then
            ok, result = addon.profileOps.Rename(
                payload.profileID, payload.name, pending.expected)
        elseif pending.kind == "copy" then
            ok, result = addon.profileOps.CopySettings(
                payload.sourceProfileID, payload.targetProfileID,
                payload.scope, pending.expected)
        elseif pending.kind == "swap" then
            ok, result = addon.profileOps.Swap(payload.left, payload.right, pending.expected)
        elseif pending.kind == "reset" then
            ok, result = addon.profileOps.ResetCurrent(
                payload.activeProfileID, pending.expected)
        elseif pending.kind == "delete" then
            ok, result = addon.profileOps.DeleteWithReplacement(
                payload.profileID, payload.replacementProfileID, pending.expected)
            if ok then ui.selectedProfileID = payload.replacementProfileID end
        elseif pending.kind == "forget" then
            ok, result = addon.profileOps.ForgetCharacter(payload.guid, pending.expected)
            if ok then ui.selectedGUID, ui.selectedSpecID, ui.selectedProfileID = nil, nil, nil end
        elseif pending.kind == "use-profile-for-specs" then
            ok, result = addon.profileOps.UseProfileForKnownSpecs(
                payload.guid, payload.profileID, pending.expected)
            if ok then ui.selectedProfileID = payload.profileID end
        elseif pending.kind == "make-specs-independent" then
            ok, result = addon.profileOps.MakeKnownSpecsIndependent(
                payload.guid, pending.expected)
            if ok and type(result) == "table" and type(result.assignments) == "table" then
                local preferredSpecID = payload.selectedSpecID
                if not preferredSpecID and payload.guid == addon.profileRuntime.activeGUID then
                    preferredSpecID = addon.profileRuntime.activeSpecID
                end
                ui.selectedProfileID = result.assignments[preferredSpecID]
                    or ui.selectedProfileID
            end
        elseif pending.kind == "set-role-template" then
            ok, result = addon.profileOps.SetRoleTemplate(
                payload.role, payload.profileID, pending.expected)
        end
        ui.HandleOperationResult(ok, result, false)
    end

    function ui.RefreshOperationControls(model, character, spec, managedProfile)
        local assignedProfileID = ui.GetAssignedProfileID(model, character, spec)
        local assignedProfile = ui.FindProfile(model, assignedProfileID)
        ui.selectedAssignedProfileID = assignedProfileID
        ui.selectedCharacterModel = character
        ui.selectedSpecModel = spec
        ui.selectedManagedProfile = managedProfile
        profileSelector:SetText(managedProfile and managedProfile.name or L("Choose a profile"))
        if managedProfile then
            local specs, other = ui.ReferenceImpact(managedProfile)
            if managedProfile.references.total == 0 then
                managedImpact:SetText(L("Unused profile"))
            else
                managedImpact:SetText(string.format(
                    L("%d assigned specs, %d other references"), specs, other))
            end
        else
            managedImpact:SetText("")
        end
        operationStatus:SetText(ui.lastOperationStatus or "")

        if character then
            selectedCharacterSummary:SetText(string.format(
                L("%s - %d known specs"), character.displayName,
                character.knownSpecCount or #(character.specs or {})))
        else
            selectedCharacterSummary:SetText("")
        end
        for _, role in ipairs(addon.profileOps.roleOrder) do
            local template = model.roleTemplates and model.roleTemplates[role] or nil
            local formatKey = role == "TANK" and "Tank: %s"
                or role == "HEALER" and "Healer: %s" or "Damage: %s"
            roleTemplateSummary[role]:SetText(template
                and string.format(L(formatKey), template.profileName) or "")
        end

        if #(model.profiles or {}) > 0 then profileSelector:Enable() else profileSelector:Disable() end
        local mutable = model.canMutate == true
        local hasContext = character ~= nil and assignedProfile ~= nil
        local hasManaged = managedProfile ~= nil
        if mutable and hasContext and hasManaged and managedProfile.profileID ~= assignedProfileID then
            assignButton:Enable()
        else assignButton:Disable() end
        if mutable then newButton:Enable() else newButton:Disable() end
        if mutable and hasManaged then duplicateButton:Enable(); renameButton:Enable()
        else duplicateButton:Disable(); renameButton:Disable() end
        if mutable and hasManaged and hasContext and managedProfile.profileID ~= assignedProfileID then
            copyButton:Enable()
        else copyButton:Disable() end
        if mutable and hasContext and #ui.ContextChoices(model, character.guid, spec and spec.specID) > 0 then
            swapButton:Enable()
        else swapButton:Disable() end
        if mutable and model.activeProfileID then resetButton:Enable() else resetButton:Disable() end
        if mutable and hasManaged and #model.profiles > 1 then deleteButton:Enable()
        else deleteButton:Disable() end
        if mutable and character and not character.isCurrent then forgetButton:Enable()
        else forgetButton:Disable() end
        local knownSpecCount = character and (character.knownSpecCount or #(character.specs or {})) or 0
        local allUseManaged = knownSpecCount > 0 and hasManaged
        if allUseManaged then
            for _, knownSpec in ipairs(character.specs) do
                if knownSpec.profileID ~= managedProfile.profileID then
                    allUseManaged = false
                    break
                end
            end
        end
        if mutable and character and hasManaged and knownSpecCount > 0 and not allUseManaged then
            useAllSpecsButton:Enable()
        else useAllSpecsButton:Disable() end
        if mutable and character and (character.sharedSpecCount or 0) > 0 then
            independentButton:Enable()
        else independentButton:Disable() end
        if mutable and hasManaged then roleTemplateButton:Enable()
        else roleTemplateButton:Disable() end

        if dialog:IsShown() and (not mutable
            or not addon.profileOps.CheckExpected(addon.dbRuntime.Refresh(),
                ui.pendingAction and ui.pendingAction.expected)) then
            dialog:Hide()
        end
    end

    profileSelector:SetScript("OnClick", function()
        local model = ui.currentModel or ui.BuildViewModel()
        ui.ShowChoices("select-profile", L("Choose a profile"),
            ui.ProfileChoices(model), nil, ui.CaptureExpected())
    end)

    assignButton:SetScript("OnClick", function()
        local character, spec, profile =
            ui.selectedCharacterModel, ui.selectedSpecModel, ui.selectedManagedProfile
        if not character or not profile then return end
        local expected = ui.CaptureExpected(
            character.guid, spec and spec.specID, profile.profileID)
        local ok, result = addon.profileOps.Assign(
            character.guid, spec and spec.specID, profile.profileID, expected)
        ui.HandleOperationResult(ok, result, false)
    end)

    newButton:SetScript("OnClick", function()
        ui.ShowNameDialog("create", L("New from defaults..."), L("New Profile"), nil,
            ui.CaptureExpected())
    end)

    duplicateButton:SetScript("OnClick", function()
        local profile = ui.selectedManagedProfile
        if not profile then return end
        ui.ShowNameDialog("duplicate", L("Duplicate profile..."),
            string.format(L("%s Copy"), profile.name), profile.profileID,
            ui.CaptureExpected(nil, nil, profile.profileID))
    end)

    renameButton:SetScript("OnClick", function()
        local profile = ui.selectedManagedProfile
        if not profile then return end
        ui.ShowNameDialog("rename", L("Rename profile..."), profile.name,
            profile.profileID, ui.CaptureExpected(nil, nil, profile.profileID))
    end)

    copyButton:SetScript("OnClick", function()
        local model = ui.currentModel or ui.BuildViewModel()
        local source = ui.selectedManagedProfile
        local target = ui.FindProfile(model, ui.selectedAssignedProfileID)
        if not source or not target or source.profileID == target.profileID then return end
        ui.ShowChoices("copy-scope", L("Choose settings to copy"),
            ui.CopyScopeChoices(), {
            sourceProfileID = source.profileID, targetProfileID = target.profileID,
        }, ui.CaptureExpected(
            ui.selectedGUID, ui.selectedSpecID, target.profileID))
    end)

    swapButton:SetScript("OnClick", function()
        local model = ui.currentModel or ui.BuildViewModel()
        local character, spec = ui.selectedCharacterModel, ui.selectedSpecModel
        if not character then return end
        local payload = {
            guid = character.guid, specID = spec and spec.specID,
            label = ui.ContextLabel(character, spec),
        }
        ui.ShowChoices("swap-context", L("Choose a context"),
            ui.ContextChoices(model, payload.guid, payload.specID), payload,
            ui.CaptureExpected(payload.guid, payload.specID))
    end)

    resetButton:SetScript("OnClick", function()
        local model = ui.currentModel or ui.BuildViewModel()
        local profile = ui.FindProfile(model, model.activeProfileID)
        if not profile then return end
        local specs, other = ui.ReferenceImpact(profile)
        local message = string.format(
            L("Reset active profile \"%s\" to defaults? This changes %d assigned specs and %d other references."),
            profile.name, specs, other)
        ui.ShowConfirmation("reset", L("Reset active profile..."), message, {
            activeProfileID = profile.profileID,
        }, ui.CaptureExpected(nil, nil, profile.profileID))
    end)

    deleteButton:SetScript("OnClick", function()
        local model = ui.currentModel or ui.BuildViewModel()
        local profile = ui.selectedManagedProfile
        if not profile then return end
        local expected = ui.CaptureExpected(nil, nil, profile.profileID)
        if profile.references.total == 0 then
            ui.ShowConfirmation("delete", L("Delete profile..."),
                string.format(L("Delete unused profile \"%s\"?"), profile.name), {
                    profileID = profile.profileID, replacementProfileID = nil,
                }, expected)
        else
            ui.ShowChoices("delete-replacement", L("Choose a replacement profile"),
                ui.ProfileChoices(model, profile.profileID), {
                    profileID = profile.profileID,
                }, expected)
        end
    end)

    forgetButton:SetScript("OnClick", function()
        local character = ui.selectedCharacterModel
        if not character then return end
        local message = string.format(
            L("Forget \"%s\"? Its character record will be removed, but profile settings will be kept."),
            character.displayName)
        ui.ShowConfirmation("forget", L("Forget character..."), message, {
            guid = character.guid,
        }, ui.CaptureExpected(character.guid, ui.selectedSpecID))
    end)

    useAllSpecsButton:SetScript("OnClick", function()
        local character = ui.selectedCharacterModel
        local profile = ui.selectedManagedProfile
        if not character or not profile or (character.knownSpecCount or 0) == 0 then return end
        local message = string.format(
            L("Use \"%s\" for all %d known specs of \"%s\"? Existing profiles and settings will be kept."),
            profile.name, character.knownSpecCount, character.displayName)
        ui.ShowConfirmation("use-profile-for-specs",
            L("Use profile for all known specs..."), message, {
                guid = character.guid,
                profileID = profile.profileID,
            }, ui.CaptureExpected(character.guid, nil, profile.profileID))
    end)

    independentButton:SetScript("OnClick", function()
        local character = ui.selectedCharacterModel
        if not character or (character.sharedSpecCount or 0) == 0 then return end
        local message = string.format(
            L("Make %d shared specs of \"%s\" independent? Each affected spec receives a separate copy; existing profiles stay unchanged."),
            character.sharedSpecCount, character.displayName)
        ui.ShowConfirmation("make-specs-independent",
            L("Make shared specs independent..."), message, {
                guid = character.guid,
                selectedSpecID = ui.selectedSpecID,
            }, ui.CaptureExpected(character.guid, nil))
    end)

    roleTemplateButton:SetScript("OnClick", function()
        local model = ui.currentModel or ui.BuildViewModel()
        local profile = ui.selectedManagedProfile
        if not profile then return end
        ui.ShowChoices("role-template", L("Choose a role"),
            ui.RoleTemplateChoices(model), {
                profileID = profile.profileID,
            }, ui.CaptureExpected(nil, nil, profile.profileID))
    end)

    nameInput:SetScript("OnTextChanged", ui.RefreshNameValidation)
    nameInput:SetScript("OnEnterPressed", ui.RunPendingAction)
    nameInput:SetScript("OnEscapePressed", ui.CloseOperationDialog)
    primaryButton:SetScript("OnClick", ui.RunPendingAction)
    cancelButton:SetScript("OnClick", ui.CloseOperationDialog)
    dialogClose:SetScript("OnClick", ui.CloseOperationDialog)
    dialog:SetScript("OnHide", function()
        blocker:Hide()
        ui.pendingAction = nil
        ui.RemoveSpecialFrame("StatsProProfileOperationDialog")
        -- WARNING: Blizzard iterates the live UISpecialFrames table while handling
        -- Escape. Re-inserting Manager synchronously here can make the same iteration
        -- hide Manager and Settings too. Restore it on the next tick after the iterator
        -- has finished, guarded against a meanwhile-hidden or reopened dialog.
        if manager:IsShown() then
            ui.DeferSpecialFrameRestore("StatsProProfileManager", function()
                return manager:IsShown() and not dialog:IsShown()
            end)
        else
            ui.CancelSpecialFrameRestore("StatsProProfileManager")
            ui.RemoveSpecialFrame("StatsProProfileManager")
        end
    end)
    dialog:Hide()
end

function addon.profileUI.BuildSettingsUI(owner)
    local ui = addon.profileUI
    local geometry = addon.settingsDesign.tokens.geometry
    local header = CreateFrame("Frame", "StatsProProfileHeader", owner, "BackdropTemplate")
    header:SetPoint("TOPLEFT", geometry.profileInset, -geometry.profileTop)
    header:SetPoint("TOPRIGHT", -geometry.profileInset, -geometry.profileTop)
    header:SetHeight(geometry.profileHeight)
    addon.settingsDesign.ApplySurface(header, "profile")
    local profileRail = header:CreateTexture(nil, "ARTWORK")
    profileRail:SetPoint("TOPLEFT", 0, -1)
    profileRail:SetPoint("BOTTOMLEFT", 0, 1)
    profileRail:SetWidth(2)
    local accent = addon.settingsDesign.Color("accent")
    profileRail:SetColorTexture(accent[1], accent[2], accent[3], 0.55)
    header.statsProRail = profileRail

    local profileLabel = header:CreateFontString(nil, "OVERLAY")
    addon.settingsDesign.ApplyTextRole(profileLabel, "metadata")
    profileLabel:SetPoint("TOPLEFT", 10, -8)
    profileLabel:SetWidth(50)
    profileLabel:SetJustifyH("LEFT")
    PushLocalizedLabel(function() profileLabel:SetText(L("Profile:")) end)

    local profileButton = addon.settingsDesign.CreateShellButton(
        header, "StatsProActiveProfileButton", "field", "profile")
    profileButton:SetPoint("TOPLEFT", geometry.profileFieldInset, -5)
    profileButton:SetSize(geometry.profileFieldWidth, geometry.minHitTarget)

    local manageButton = addon.settingsDesign.CreateShellButton(
        header, "StatsProManageProfilesButton", "field")
    manageButton:SetPoint("TOPRIGHT", -8, -5)
    manageButton:SetSize(geometry.manageWidth, geometry.minHitTarget)
    PushLocalizedLabel(function() manageButton:SetText(L("Manage")) end)

    local subtitle = header:CreateFontString(nil, "OVERLAY")
    addon.settingsDesign.ApplyTextRole(subtitle, "metadata")
    subtitle:SetPoint("BOTTOMLEFT", 10, 7)
    subtitle:SetPoint("BOTTOMRIGHT", -10, 7)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetWordWrap(false)
    subtitle:SetMaxLines(1)

    local manager = CreateFrame(
        "Frame", "StatsProProfileManager", UIParent, "BackdropTemplate")
    manager:SetPoint("CENTER")
    addon.settingsDesign.ApplySurface(manager, "window")
    manager:EnableMouse(true)
    manager:SetMovable(true)
    manager:RegisterForDrag("LeftButton")
    manager:SetScript("OnDragStart", manager.StartMoving)
    manager:SetScript("OnDragStop", manager.StopMovingOrSizing)
    manager:SetClampedToScreen(true)
    manager:SetFrameStrata("DIALOG")
    manager:SetFrameLevel((owner:GetFrameLevel() or 100) + 20)
    manager:Hide()

    function ui.ApplyManagerSize()
        local width = math.max(430, math.min(620, UIParent:GetWidth() * 0.9))
        local height = math.max(300, math.min(440, UIParent:GetHeight() * 0.85))
        manager:SetSize(width, height)
    end
    ui.ApplyManagerSize()
    manager:HookScript("OnShow", function()
        ui.ApplyManagerSize()
        ui.CancelSpecialFrameRestore("StatsProConfigFrame")
        ui.RemoveSpecialFrame("StatsProConfigFrame")
        ui.PushSpecialFrame("StatsProProfileManager")
        ui.RefreshSafe()
    end)

    local managerTitle = manager:CreateFontString(nil, "OVERLAY")
    addon.settingsDesign.ApplyTextRole(managerTitle, "title")
    managerTitle:SetPoint("TOP", 0, -14)
    PushLocalizedLabel(function() managerTitle:SetText(L("Profile Manager")) end)

    local managerCloseX = CreateFrame("Button", nil, manager, "UIPanelCloseButton")
    managerCloseX:SetPoint("TOPRIGHT", -4, -4)

    local managerLine = manager:CreateTexture(nil, "ARTWORK")
    managerLine:SetPoint("TOPLEFT", 14, -42)
    managerLine:SetPoint("TOPRIGHT", -14, -42)
    managerLine:SetHeight(1)
    addon.settingsDesign.ApplySeparator(managerLine)

    local divider = manager:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", 248, -52)
    divider:SetPoint("BOTTOMLEFT", 248, 52)
    divider:SetWidth(1)
    addon.settingsDesign.ApplySeparator(divider)

    local listSurface = addon.settingsDesign.CreateTextureSurface(manager, "viewport")
    listSurface:SetPoint("TOPLEFT", 12, -48)
    listSurface:SetPoint("BOTTOMLEFT", 12, 50)
    listSurface:SetWidth(230)

    local detailSurface = addon.settingsDesign.CreateTextureSurface(manager, "raised")
    detailSurface:SetPoint("TOPLEFT", 252, -48)
    detailSurface:SetPoint("BOTTOMRIGHT", -12, 50)

    local listTitle = manager:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(listTitle, 12, "OUTLINE")
    listTitle:SetPoint("TOPLEFT", 20, -54)
    PushLocalizedLabel(function() listTitle:SetText(L("Character")) end)

    local listScroll = CreateFrame(
        "ScrollFrame", "StatsProProfileManagerScroll", manager, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", 16, -76)
    listScroll:SetPoint("BOTTOMLEFT", 16, 54)
    listScroll:SetWidth(212)
    local listChild = CreateFrame("Frame", nil, listScroll)
    listChild:SetSize(190, 1)
    listScroll:SetScrollChild(listChild)

    local emptyText = listChild:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(emptyText, 12)
    emptyText:SetPoint("TOPLEFT", 6, -8)
    emptyText:SetWidth(178)
    emptyText:SetJustifyH("LEFT")
    addon.settingsDesign.SetRegionColor(emptyText, "textMuted")

    local detailCharacter = manager:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(detailCharacter, 16, "OUTLINE")
    detailCharacter:SetPoint("TOPLEFT", 266, -58)
    detailCharacter:SetPoint("TOPRIGHT", -20, -58)
    detailCharacter:SetJustifyH("LEFT")

    local detailContext = manager:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(detailContext, 12)
    detailContext:SetPoint("TOPLEFT", detailCharacter, "BOTTOMLEFT", 0, -8)
    detailContext:SetPoint("TOPRIGHT", detailCharacter, "BOTTOMRIGHT", 0, -8)
    detailContext:SetJustifyH("LEFT")
    addon.settingsDesign.SetRegionColor(detailContext, "textSecondary")

    local assignedLabel = manager:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(assignedLabel, 12, "OUTLINE")
    assignedLabel:SetPoint("TOPLEFT", detailContext, "BOTTOMLEFT", 0, -24)
    PushLocalizedLabel(function() assignedLabel:SetText(L("Assigned profile:")) end)

    local detailProfile = manager:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(detailProfile, 15, "OUTLINE")
    detailProfile:SetPoint("TOPLEFT", assignedLabel, "BOTTOMLEFT", 0, -8)
    detailProfile:SetPoint("TOPRIGHT", manager, "TOPRIGHT", -20, -138)
    detailProfile:SetJustifyH("LEFT")
    addon.settingsDesign.SetRegionColor(detailProfile, "accent")

    local detailSharing = manager:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(detailSharing, 12)
    detailSharing:SetPoint("TOPLEFT", detailProfile, "BOTTOMLEFT", 0, -10)
    detailSharing:SetPoint("TOPRIGHT", -20, 0)
    detailSharing:SetJustifyH("LEFT")
    addon.settingsDesign.SetRegionColor(detailSharing, "textSecondary")

    local detailNotice = manager:CreateFontString(nil, "OVERLAY")
    RegisterConfigFont(detailNotice, 12)
    detailNotice:SetPoint("BOTTOMLEFT", 266, 64)
    detailNotice:SetPoint("BOTTOMRIGHT", -20, 64)
    detailNotice:SetJustifyH("LEFT")
    detailNotice:SetJustifyV("BOTTOM")
    detailNotice:SetWordWrap(true)
    detailNotice:SetMaxLines(2)
    addon.settingsDesign.SetRegionColor(detailNotice, "warning")

    local managerClose = addon.settingsDesign.CreateShellButton(manager, nil, "primary")
    managerClose:SetPoint("BOTTOMRIGHT", -18, 18)
    managerClose:SetSize(addon.settingsDesign.tokens.geometry.closeButtonWidth,
        addon.settingsDesign.tokens.geometry.shellButtonHeight)
    managerClose:SetScript("OnClick", function() manager:Hide() end)
    PushLocalizedLabel(function() managerClose:SetText(L("Close")) end)

    ui.header = header
    ui.headerLabel = profileLabel
    ui.headerProfileButton = profileButton
    ui.headerSubtitle = subtitle
    ui.manageButton = manageButton
    ui.manager = manager
    ui.managerListSurface = listSurface
    ui.managerDetailSurface = detailSurface
    ui.managerTitle = managerTitle
    ui.managerRows = {}
    ui.managerListChild = listChild
    ui.managerEmptyText = emptyText
    ui.detailCharacter = detailCharacter
    ui.detailContext = detailContext
    ui.detailProfile = detailProfile
    ui.detailSharing = detailSharing
    ui.detailNotice = detailNotice
    ui.BuildOperationUI(manager)

    manager:HookScript("OnHide", function()
        ui.CloseOperationDialog()
        ui.RemoveSpecialFrame("StatsProProfileManager")
        -- See the dialog OnHide warning: restoring Settings synchronously can make one
        -- Escape close every visible StatsPro layer during Blizzard's live-table walk.
        if owner:IsShown() then
            ui.DeferSpecialFrameRestore("StatsProConfigFrame", function()
                return owner:IsShown() and not manager:IsShown()
            end)
        else
            ui.CancelSpecialFrameRestore("StatsProConfigFrame")
            ui.RemoveSpecialFrame("StatsProConfigFrame")
        end
    end)

    function ui.EnsureManagerRow(index)
        local row = ui.managerRows[index]
        if row then return row end
        row = CreateFrame("Button", nil, listChild)
        row:SetSize(188, addon.settingsDesign.tokens.geometry.listRowHeight)
        local background = row:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints(row)
        background:SetColorTexture(1, 1, 1, 0)
        local text = row:CreateFontString(nil, "OVERLAY")
        RegisterConfigFont(text, 11)
        text:SetPoint("LEFT", 6, 0)
        local badge = row:CreateFontString(nil, "OVERLAY")
        RegisterConfigFont(badge, 10, "OUTLINE")
        badge:SetPoint("RIGHT", -6, 0)
        badge:SetWidth(70)
        badge:SetJustifyH("RIGHT")
        badge:SetTextColor(0, 1, 0.5, 1)
        text:SetPoint("RIGHT", badge, "LEFT", -4, 0)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        text:SetMaxLines(1)
        row.background = background
        row.text = text
        row.badge = badge
        addon.settingsDesign.StyleListRow(row, text)
        row:SetScript("OnClick", function(button)
            local context = button.profileContext
            if not context then return end
            ui.selectedGUID = context.guid
            ui.selectedSpecID = context.specID
            ui.selectedProfileID = nil
            ui.RefreshSafe()
        end)
        ui.managerRows[index] = row
        return row
    end

    function ui.RefreshAll()
        local model = ui.BuildViewModel()
        ui.currentModel = model
        ui.refreshCount = ui.refreshCount + 1

        profileButton:SetText(model.activeProfileName or L("Account default profile"))
        if model.readOnly then
            subtitle:SetText(L("Compatibility mode - profiles are read-only."))
            addon.settingsDesign.SetRegionColor(subtitle, "warning")
        elseif model.pending then
            subtitle:SetText(L("Switch pending until combat ends"))
            addon.settingsDesign.SetRegionColor(subtitle, "warning")
        elseif model.activeSharedCount > 1 then
            subtitle:SetText(string.format(L("Shared by %d specs"), model.activeSharedCount))
            addon.settingsDesign.SetRegionColor(subtitle, "textSecondary")
        elseif model.activeGUID and model.activeSpecID then
            local displayName = model.activeDisplayName or "Character"
            local specName = ui.FormatSpecName(model.activeSpecID, model.activeSpecName)
            subtitle:SetText(string.format(L("Automatic - %s / %s"), displayName, specName))
            addon.settingsDesign.SetRegionColor(subtitle, "textSecondary")
        else
            subtitle:SetText(L("Account default profile"))
            addon.settingsDesign.SetRegionColor(subtitle, "textSecondary")
        end

        local selectedCharacter, selectedSpec
        for _, character in ipairs(model.characters) do
            if character.guid == ui.selectedGUID then
                selectedCharacter = character
                if ui.selectedSpecID ~= nil then
                    for _, spec in ipairs(character.specs) do
                        if spec.specID == ui.selectedSpecID then selectedSpec = spec; break end
                    end
                end
                break
            end
        end
        if not selectedCharacter then
            selectedCharacter = model.characters[1]
            ui.selectedGUID = selectedCharacter and selectedCharacter.guid or nil
            ui.selectedSpecID = selectedCharacter and model.activeGUID == selectedCharacter.guid
                and model.activeSpecID or nil
            if selectedCharacter and ui.selectedSpecID then
                for _, spec in ipairs(selectedCharacter.specs) do
                    if spec.specID == ui.selectedSpecID then selectedSpec = spec; break end
                end
            end
        elseif ui.selectedSpecID ~= nil and not selectedSpec then
            ui.selectedSpecID = nil
        end

        local assignedProfileID = ui.GetAssignedProfileID(model, selectedCharacter, selectedSpec)
        if not ui.FindProfile(model, ui.selectedProfileID) then
            ui.selectedProfileID = assignedProfileID or model.activeProfileID
        end
        local managedProfile = ui.FindProfile(model, ui.selectedProfileID)

        local rowIndex, y = 0, -2
        for _, character in ipairs(model.characters) do
            rowIndex = rowIndex + 1
            local row = ui.EnsureManagerRow(rowIndex)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, y)
            row.profileContext = { guid = character.guid, specID = nil }
            row.text:SetText(character.displayName)
            row.badge:SetText(character.isCurrent and L("Current") or "")
            local selected = character.guid == ui.selectedGUID and ui.selectedSpecID == nil
            addon.settingsDesign.SetListRowSelected(row, selected)
            row:Show()
            y = y - 26
            for _, spec in ipairs(character.specs) do
                rowIndex = rowIndex + 1
                row = ui.EnsureManagerRow(rowIndex)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", 0, y)
                row.profileContext = { guid = character.guid, specID = spec.specID }
                row.text:SetText("   " .. ui.FormatSpecName(spec.specID, spec.specName))
                row.badge:SetText(spec.isActive and L("Active") or "")
                selected = character.guid == ui.selectedGUID and ui.selectedSpecID == spec.specID
            addon.settingsDesign.SetListRowSelected(row, selected)
                row:Show()
                y = y - addon.settingsDesign.tokens.geometry.listRowHeight
            end
            y = y - 4
        end
        for index = rowIndex + 1, #ui.managerRows do ui.managerRows[index]:Hide() end
        listChild:SetHeight(math.max(1, -y + 4))
        emptyText:SetText(#model.characters == 0 and L("No visited characters") or "")

        if selectedCharacter then
            detailCharacter:SetText(selectedCharacter.displayName)
            if selectedSpec then
                detailContext:SetText(ui.FormatSpecName(selectedSpec.specID, selectedSpec.specName))
                detailProfile:SetText(selectedSpec.profileName)
                detailSharing:SetText(selectedSpec.sharedCount > 1
                    and string.format(L("Shared by %d specs"), selectedSpec.sharedCount)
                    or L("Independent"))
            else
                detailContext:SetText(L("Character default"))
                detailProfile:SetText(selectedCharacter.defaultProfileName or L("Account default profile"))
                detailSharing:SetText(selectedCharacter.defaultSharedCount > 1
                    and string.format(L("Shared by %d specs"), selectedCharacter.defaultSharedCount)
                    or L("Independent"))
            end
        else
            detailCharacter:SetText(L("No visited characters"))
            detailContext:SetText("")
            detailProfile:SetText(model.activeProfileName or L("Account default profile"))
            detailSharing:SetText("")
        end

        if model.readOnly then
            detailNotice:SetText(L("Compatibility mode - profiles are read-only."))
        elseif model.combat == true then
            detailNotice:SetText(L("Profile changes are unavailable during combat."))
        elseif model.pending or model.combat == nil then
            detailNotice:SetText(L("Waiting for a safe profile context."))
        else
            detailNotice:SetText("")
        end
        if model.canMutate and model.activeGUID and model.activeSpecID then
            profileButton:Enable()
        else
            profileButton:Disable()
        end
        ui.RefreshOperationControls(model, selectedCharacter, selectedSpec, managedProfile)
    end
    ui.refreshAll = ui.RefreshAll

    function ui.OpenManager(selectActive)
        if addon.appearancePresets.session
            and not addon.appearancePresets.CancelPreview(true) then return end
        if selectActive then
            ui.selectedGUID = addon.profileRuntime.activeGUID
            ui.selectedSpecID = addon.profileRuntime.activeSpecID
            ui.selectedProfileID = addon.dbRuntime.activeProfileID
        end
        ui.RefreshSafe()
        manager:Show()
    end

    local function ToggleManager()
        if manager:IsShown() then
            manager:Hide()
            return
        end
        ui.OpenManager(true)
    end
    profileButton:SetScript("OnClick", function()
        local model = ui.BuildViewModel()
        if not model.canMutate or not model.activeGUID or not model.activeSpecID then return end
        ui.OpenManager(true)
        model = ui.currentModel or ui.BuildViewModel()
        ui.ShowChoices("assign-profile", L("Choose a profile"),
            ui.ProfileChoices(model), {
                guid = model.activeGUID,
                specID = model.activeSpecID,
            }, ui.CaptureExpected(model.activeGUID, model.activeSpecID))
    end)
    manageButton:SetScript("OnClick", ToggleManager)

    function ui.HideManager()
        if manager:IsShown() then manager:Hide() end
    end

    owner.profileHeader = header
    owner.profileManager = manager
    PushLocalizedLabel(function() ui.RefreshSafe() end)
    PushRefresher(ui.RefreshSafe)
    return header, manager
end

function addon:OpenConfigMenu()
    -- Settings remains inspectable under a future schema, but the shared write gate
    -- explains once per session why every mutating control is read-only.
    self.dbRuntime.GetWritableSettings(true)
    if configFrame then
        if configFrame:IsShown() then
            configFrame:Hide()
        else
            configFrame:Show()
            -- Always reopen on the first tab (Stats) — predictable UX, matches initial open.
            if configFrame.SwitchToTab then configFrame.SwitchToTab(1) end
            self.profileUI.RefreshSafe()
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
        UIDropDownMenu_SetWidth(dropdown, addon.settingsDesign.tokens.geometry.dropdownWidth)
        UIDropDownMenu_JustifyText(dropdown, "LEFT")
        addon.settingsDesign.StyleDropdown(dropdown, label)

        local function ResolveOption(value)
            for _, opt in ipairs(options) do
                if opt.value == value then return opt end
            end
            return options[1]
        end

        local function RefreshDropdownText()
            label:SetText(L(labelKey))
            UIDropDownMenu_SetText(dropdown, L(ResolveOption(getValue()).label))
            addon.settingsDesign.RefreshControl(dropdown.statsProTrigger)
        end

        UIDropDownMenu_Initialize(dropdown, function()
            local current = ResolveOption(getValue())
            for _, opt in ipairs(options) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = L(opt.label)
                info.value = opt.value
                info.checked = (current.value == opt.value)
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
            maxTextWidth = addon.settingsDesign.tokens.geometry.dropdownLabelMaxWidth,
            dropdownX_base = cursor.padX, dropdownY = rowY + CONFIG_DROPDOWN_Y_OFFSET, dropdownParent = parent,
        })
        cursor.y = rowY - 30
        return dropdown, label
    end

    --[[ ===== Frame ===== ]]
    configFrame = CreateFrame("Frame", "StatsProConfigFrame", UIParent, "BackdropTemplate")
    local shellGeometry = self.settingsDesign.tokens.geometry
    local configFrameWidth = shellGeometry.windowWidth

    -- WARNING: cap by parent so footer (Reset/Close at BOTTOM y=14) stays on-screen.
    -- The 260px floor leaves a positive viewport after the 140px header and 66px footer.
    local function ApplyConfigFrameSize()
        local maxH = math.max(shellGeometry.minHeight,
            math.min(shellGeometry.maxHeight, UIParent:GetHeight() * shellGeometry.parentHeightRatio))
        configFrame:SetSize(configFrameWidth, maxH)
    end
    ApplyConfigFrameSize()

    configFrame:SetPoint("CENTER")
    self.settingsDesign.ApplySurface(configFrame, "window")
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
        self.profileUI.PushSpecialFrame("StatsProConfigFrame")
        configSpecialFrameRegistered = true
    end

    configFrame:HookScript("OnShow", function()
        ApplyConfigFrameSize()
        self.panelEditRuntime.SetRequested(true)
        if not self.profileUI.manager or not self.profileUI.manager:IsShown() then
            self.profileUI.PushSpecialFrame("StatsProConfigFrame")
        end
    end)

    -- Auto-close font picker + Blizzard dropdown lists when Settings UI hides (e.g., /ss
    -- toggle, click X, Esc). Both are parented to UIParent (NOT configFrame) so neither
    -- auto-hides via parent — without these calls Esc-while-langDropdown-open leaves an
    -- orphan dropdown list above (and a stale langPreview state until user clicks elsewhere
    -- to trigger DropDownList1:OnHide → CancelLanguagePreview).
    configFrame:HookScript("OnHide", function()
        self.panelEditRuntime.SetRequested(false)
        self.appearancePresets.ForceCancelPreview()
        CloseDropDownMenus()  -- closes any active Blizzard dropdown; fires its OnHide → CancelLanguagePreview
        if StatsProCloseColorPicker then StatsProCloseColorPicker() end
        if _G.StatsProFontPicker and _G.StatsProFontPicker:IsShown() then
            _G.StatsProFontPicker:Hide()
        end
        self.profileUI.HideManager()
    end)

    --[[ ===== Header (title + X) ===== ]]
    local titleSurface = self.settingsDesign.CreateTextureSurface(configFrame, "raised")
    titleSurface:SetPoint("TOPLEFT", shellGeometry.titleSurfaceInset,
        -shellGeometry.titleSurfaceInset)
    titleSurface:SetPoint("TOPRIGHT", -shellGeometry.titleSurfaceInset,
        -shellGeometry.titleSurfaceInset)
    titleSurface:SetHeight(shellGeometry.titleSurfaceHeight)

    local title = configFrame:CreateFontString(nil, "OVERLAY")
    self.settingsDesign.ApplyTextRole(title, "title")
    title:SetPoint("TOPLEFT", shellGeometry.titleTextInset, -shellGeometry.titleTextTop)
    title:SetText("StatsPro")
    self.settingsDesign.SetRegionColor(title, "accent")

    local titleMetadata = configFrame:CreateFontString(nil, "OVERLAY")
    self.settingsDesign.ApplyTextRole(titleMetadata, "metadata")
    titleMetadata:SetPoint("LEFT", title, "RIGHT", 8, 0)
    PushLocalizedLabel(function()
        titleMetadata:SetText(L("Settings") .. "  v" .. ADDON_VERSION)
    end)

    local closeX = CreateFrame("Button", nil, configFrame, "UIPanelCloseButton")
    closeX:SetPoint("TOPRIGHT", -4, -4)

    -- Header separator
    local headerLine = configFrame:CreateTexture(nil, "ARTWORK")
    headerLine:SetPoint("TOPLEFT", shellGeometry.outerInset, -shellGeometry.titleHeight)
    headerLine:SetPoint("TOPRIGHT", -shellGeometry.outerInset, -shellGeometry.titleHeight)
    headerLine:SetHeight(1)
    self.settingsDesign.ApplySeparator(headerLine)

    self.profileUI.BuildSettingsUI(configFrame)

    --[[ ===== Tab strip (custom, top-anchored, underline-active style) ===== ]]
    local TAB_HEIGHT = shellGeometry.tabHeight
    local tabStrip = CreateFrame("Frame", nil, configFrame)
    tabStrip:SetPoint("TOPLEFT", shellGeometry.tabInset, -shellGeometry.tabTop)
    tabStrip:SetPoint("TOPRIGHT", -shellGeometry.tabInset, -shellGeometry.tabTop)
    tabStrip:SetHeight(TAB_HEIGHT)
    tabStrip.statsProSurfaceRole = "tabStrip"

    -- Separator below tab strip
    local tabsLine = configFrame:CreateTexture(nil, "ARTWORK")
    tabsLine:SetPoint("TOPLEFT", shellGeometry.outerInset,
        -(shellGeometry.tabTop + shellGeometry.tabHeight + shellGeometry.tabGap))
    tabsLine:SetPoint("TOPRIGHT", -shellGeometry.outerInset,
        -(shellGeometry.tabTop + shellGeometry.tabHeight + shellGeometry.tabGap))
    tabsLine:SetHeight(1)
    self.settingsDesign.ApplySeparator(tabsLine)

    --[[ ===== Footer (Reset + Close) ===== ]]
    local footerSurface = self.settingsDesign.CreateTextureSurface(configFrame, "raised")
    footerSurface:SetPoint("BOTTOMLEFT", shellGeometry.footerSurfaceInset,
        shellGeometry.footerSurfaceInset)
    footerSurface:SetPoint("BOTTOMRIGHT", -shellGeometry.footerSurfaceInset,
        shellGeometry.footerSurfaceInset)
    footerSurface:SetHeight(shellGeometry.footerSurfaceHeight)

    local footerLine = configFrame:CreateTexture(nil, "ARTWORK")
    footerLine:SetPoint("BOTTOMLEFT", shellGeometry.outerInset, shellGeometry.footerHeight)
    footerLine:SetPoint("BOTTOMRIGHT", -shellGeometry.outerInset, shellGeometry.footerHeight)
    footerLine:SetHeight(1)
    self.settingsDesign.ApplySeparator(footerLine)

    local resetBtn = self.settingsDesign.CreateShellButton(configFrame, nil, "destructive")
    resetBtn:SetPoint("BOTTOMLEFT", shellGeometry.footerButtonInset,
        shellGeometry.footerButtonBottom)
    resetBtn:SetSize(shellGeometry.resetButtonWidth, shellGeometry.shellButtonHeight)
    PushLocalizedLabel(function() resetBtn:SetText(L("Reset active profile...")) end)
    self.settingsDesign.RegisterMutationControl(resetBtn)

    local closeBtn = self.settingsDesign.CreateShellButton(configFrame, nil, "primary")
    closeBtn:SetPoint("BOTTOMRIGHT", -shellGeometry.footerButtonInset,
        shellGeometry.footerButtonBottom)
    closeBtn:SetSize(shellGeometry.closeButtonWidth, shellGeometry.shellButtonHeight)
    PushLocalizedLabel(function() closeBtn:SetText(L("Close")) end)
    closeBtn:SetScript("OnClick", function() configFrame:Hide() end)

    --[[ ===== ScrollFrame for tab content ===== ]]
    local viewportSurface = self.settingsDesign.CreateTextureSurface(configFrame, "viewport")
    viewportSurface:SetPoint("TOPLEFT", shellGeometry.viewportInset, -shellGeometry.viewportTop)
    viewportSurface:SetPoint("BOTTOMRIGHT", -shellGeometry.viewportInset,
        shellGeometry.viewportBottom)

    local scrollFrame = CreateFrame("ScrollFrame", "StatsProConfigScroll", configFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", shellGeometry.scrollLeft, -shellGeometry.scrollTop)
    scrollFrame:SetPoint("BOTTOMRIGHT", -shellGeometry.scrollRight,
        shellGeometry.scrollBottom)
    self.settingsDesign.StyleScrollFrame(scrollFrame)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    -- SYNC: the 16px left / 32px right anchors reserve the template scrollbar gutter;
    -- the 450px child keeps a 2px inset inside that viewport. Explicit width avoids construction-time
    -- GetWidth ambiguity and gives every tab a stable 450px content surface.
    local scrollChildWidth = shellGeometry.contentWidth
    scrollChild:SetSize(scrollChildWidth, 1)  -- height set per active tab
    scrollFrame:SetScrollChild(scrollChild)

    -- Tab content frames (children of scrollChild). Tab order: content toggles (Stats),
    -- layout/routing, then appearance (typography / localization). Variable
    -- `displayTab` backs the UI tab labelled "Appearance" (see `names` array below).
    local displayTab   = CreateFrame("Frame", nil, scrollChild)
    local statsTab     = CreateFrame("Frame", nil, scrollChild)
    local layoutTab    = CreateFrame("Frame", nil, scrollChild)
    if self.__statsproSmoke == true then configFrame.appearanceTab = displayTab end
    local tabContents  = { statsTab, layoutTab, displayTab }
    if self.__statsproSmoke == true then configFrame.tabContents = tabContents end
    for _, tab in ipairs(tabContents) do
        tab:SetPoint("TOPLEFT", 0, 0)
        tab:SetPoint("TOPRIGHT", 0, 0)
        tab:Hide()
    end

    --[[ ===== Tab buttons (custom, with underline indicator) ===== ]]
    local tabButtons = {}

    local function SwitchToTab(idx)
        configFrame.activeTabIndex = idx
        for i, content in ipairs(tabContents) do
            if i == idx then
                content:Show()
                if content.contentHeight then
                    scrollChild:SetHeight(content.contentHeight)
                end
                self.settingsDesign.SetTabSelected(tabButtons[i], true)
            else
                content:Hide()
                self.settingsDesign.SetTabSelected(tabButtons[i], false)
            end
        end
        scrollFrame:SetVerticalScroll(0)
    end
    configFrame.SwitchToTab = SwitchToTab

    do
        local names = { "Stats", "Layout", "Appearance" }
        for i, name in ipairs(names) do
            local btn = self.settingsDesign.CreateTab(tabStrip, name)
            btn:SetSize(shellGeometry.tabWidth, TAB_HEIGHT)
            if i == 1 then
                btn:SetPoint("LEFT", tabStrip, "LEFT", 0, 0)
            else
                btn:SetPoint("LEFT", tabButtons[i - 1], "RIGHT", shellGeometry.tabGap, 0)
            end
            btn:SetScript("OnClick", function() SwitchToTab(i) end)
            tabButtons[i] = btn
        end
    end

    if self.__statsproSmoke == true then
        configFrame.tabStrip = tabStrip
        configFrame.tabButtons = tabButtons
        configFrame.settingsShell = {
            titleSurface = titleSurface,
            title = title,
            titleMetadata = titleMetadata,
            profileHeader = configFrame.profileHeader,
            tabStrip = tabStrip,
            viewport = viewportSurface,
            scroll = scrollFrame,
            scrollChild = scrollChild,
            footer = footerSurface,
            resetButton = resetBtn,
            closeButton = closeBtn,
        }
    end

    --[[ ===== LAYOUT TAB ===== ]]
    local cd = NewCursor(layoutTab, 12, -8)
    local splitBlockChecks = {}
    local function ApplySplitBlockChecksEnabled()
        local enabled = GetDB("displayMode") == "split"
        for _, cb in ipairs(splitBlockChecks) do
            SetCheckboxEnabled(cb, enabled, "Split")
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
                local db = self.dbRuntime.GetWritableSettings(true)
                if not db then
                    CloseDropDownMenus()
                    return false
                end
                db.displayMode = value
                CacheSettings()
                UIDropDownMenu_SetText(dropdown, L(opt.label))
                ApplySplitBlockChecksEnabled()
                CloseDropDownMenus()
                addon:RunUpdateStatsSafe()
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
                local db = self.dbRuntime.GetWritableSettings(true)
                if not db then
                    CloseDropDownMenus()
                    return false
                end
                db.labelStyle = value
                CacheSettings()
                UIDropDownMenu_SetText(dropdown, L(opt.label))
                CloseDropDownMenus()
                addon:RunUpdateStatsSafe()
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

    CursorSection(cd, "Appearance Presets")
    do
        local presetUI = { buttons = {} }
        local status = displayTab:CreateFontString(nil, "OVERLAY")
        self.settingsDesign.ApplyTextRole(status, "body")
        status:SetPoint("TOPLEFT", cd.padX, cd.y)
        status:SetSize(426, 20)
        status:SetJustifyH("LEFT")
        presetUI.status = status
        cd.y = cd.y - 26

        for index, presetID in ipairs(self.appearancePresets.order) do
            local definition = self.appearancePresets.definitions[presetID]
            local button = CreateFrame("Button", "StatsProAppearancePreset"
                .. presetID:gsub("[^%w]", ""), displayTab)
            local column = (index - 1) % 2
            local row = math.floor((index - 1) / 2)
            button:SetPoint("TOPLEFT", cd.padX + column * 217, cd.y - row * 40)
            button:SetSize(209, 36)
            local label = button:CreateFontString(nil, "OVERLAY")
            self.settingsDesign.ApplyTextRole(label, "body")
            label:SetPoint("LEFT", 10, 0)
            label:SetPoint("RIGHT", -10, 0)
            label:SetJustifyH("LEFT")
            label:SetWordWrap(false)
            label:SetMaxLines(1)
            PushLocalizedLabel(function() label:SetText(L(definition.label)) end)
            self.settingsDesign.StyleListRow(button, label)
            self.settingsDesign.RegisterMutationControl(button)
            button:SetScript("OnClick", function()
                local ok, reason = self.appearancePresets.StartPreview(presetID)
                if not ok then PrintMsg(self.profileUI.OperationErrorText(reason)) end
            end)
            presetUI.buttons[presetID] = button
        end
        cd.y = cd.y - 120

        local note = displayTab:CreateFontString(nil, "OVERLAY")
        self.settingsDesign.ApplyTextRole(note, "metadata")
        note:SetPoint("TOPLEFT", cd.padX, cd.y)
        note:SetSize(426, 52)
        note:SetJustifyH("LEFT")
        note:SetJustifyV("TOP")
        note:SetWordWrap(true)
        PushLocalizedLabel(function()
            note:SetText(L("Presets change font size, opacity, outline, panel background, HUD colors, and color behavior. They keep font face, layout, visible stats, scale, language, and refresh rate."))
        end)
        presetUI.note = note
        cd.y = cd.y - 58

        local warning = displayTab:CreateFontString(nil, "OVERLAY")
        warning:SetPoint("TOPLEFT", cd.padX, cd.y)
        warning:SetSize(426, 36)
        warning:SetJustifyH("LEFT")
        warning:SetJustifyV("TOP")
        warning:SetWordWrap(true)
        self.settingsDesign.StyleWarning(displayTab, warning, "warning")
        self.settingsDesign.SetWarningVisible(warning, false)
        presetUI.warning = warning
        cd.y = cd.y - 42

        local cancel = self.settingsDesign.CreateShellButton(displayTab, nil, "field")
        cancel:SetPoint("TOPRIGHT", -140, cd.y)
        cancel:SetSize(160, 28)
        PushLocalizedLabel(function() cancel:SetText(L("Cancel preview")) end)
        cancel:SetScript("OnClick", function() self.appearancePresets.CancelPreview() end)
        presetUI.cancel = cancel

        local apply = self.settingsDesign.CreateShellButton(displayTab, nil, "primary")
        apply:SetPoint("TOPRIGHT", -12, cd.y)
        apply:SetSize(120, 28)
        PushLocalizedLabel(function() apply:SetText(L("Apply")) end)
        self.settingsDesign.RegisterMutationControl(apply)
        apply:SetScript("OnClick", function()
            local ok, reason = self.appearancePresets.ApplyPreview()
            if not ok then PrintMsg(self.profileUI.OperationErrorText(reason)) end
        end)
        presetUI.apply = apply
        cd.y = cd.y - 36

        self.appearancePresets.ui = presetUI
        self.appearancePresets.RefreshUI()
        PushRefresher(self.appearancePresets.RefreshUI)
    end

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
                    local path = type(name) == "string" and addon.fontRuntime.rawLSMPath(name) or nil
                    local usable = addon.fontRuntime.usableCatalogPath(path)
                    if usable then
                        list[#list + 1] = {
                            name = name,
                            path = usable,
                            sortKey = name:lower(),
                        }
                    end
                end
            else
                list = {}
                local clientLocale = GetLocale()
                for _, f in ipairs(BLIZZARD_SHIPPED_FONTS) do
                    if not f.locale or f.locale == clientLocale then
                        local usable = addon.fontRuntime.usableCatalogPath(f.path)
                        if usable then
                            list[#list + 1] = {
                                name = f.name,
                                path = usable,
                                sortKey = f.name:lower(),
                            }
                        end
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
        UIDropDownMenu_SetWidth(fontDropdown, addon.settingsDesign.tokens.geometry.dropdownWidth)
        UIDropDownMenu_JustifyText(fontDropdown, "LEFT")
        addon.settingsDesign.StyleDropdown(fontDropdown, fontLabel)
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
            local applied, effectiveFont = ApplyTextStyleToAllPanels(path, GetNumberDB("fontSize"))
            if not applied then return false end
            previewedPath = effectiveFont
            ReflowAllPanels()
            return true
        end
        -- WHY unconditional restore (no `previewedPath~=nil` gate): preview-state
        -- tracking can desync against panel-applied state via three paths — OnLeave-timer
        -- racing PickFont's nil-write, SetFont silent-fallback poisoning ApplyStyle's
        -- appliedFont cache, and Frame:Hide → child OnLeave event ordering. Force the
        -- restore so a poisoned appliedFont cache cannot leave the HUD stuck on the
        -- last hovered preview when the picker closes without a font pick.
        local function CancelFontPreview()
            previewedPath = nil
            if self.profileRuntime.suppressIntermediateRefresh then return end
            self.fontRuntime.applyCommittedTextStyle(
                self.fontRuntime.currentPath(), GetNumberDB("fontSize"), true, true)
            ReflowAllPanels()
        end
        self.profileRuntime.cancelFontPreview = CancelFontPreview
        local function PickFont(f)
            if not self.fontRuntime.canMutateDB(true) then return false end
            local applied = self.fontRuntime.applyCommittedTextStyle(
                f.path, GetNumberDB("fontSize"), false, false)
            if not applied then return false end
            self.fontRuntime.clearSavedAutoFont()  -- explicit user pick clears auto-switch memory
            ReflowAllPanels()
            previewedPath = nil  -- preview is now committed; OnHide force-syncs to DB.font
            UIDropDownMenu_SetText(fontDropdown, CurrentFontName())
            CloseDropDownMenus()  -- defensive; no-op when no Blizzard dropdown is open
            RefreshLanguageWarning()  -- new font may not cover active locale's glyphs
            return true
        end
        self.profileRuntime.previewFont = PreviewFont
        UIDropDownMenu_SetWidth(fontDropdown, addon.settingsDesign.tokens.geometry.dropdownWidth)
        UIDropDownMenu_JustifyText(fontDropdown, "LEFT")
        -- NOTE: UIDropDownMenu_Initialize is intentionally NOT called — Blizzard's default
        -- popup is replaced by a custom multi-column picker (see Block B below). Without
        -- Initialize, the template's default OnClick would open an empty DropDownList1, but
        -- Block E overrides Button:OnClick to open our picker instead.

        --[[ ===== Custom multi-column font picker ===== ]]
        -- Geometry constants — tweak here, do NOT inline magic numbers at call sites.
        local FONT_PICKER_COLS         = 3
        local FONT_PICKER_BTN_W        = 160      -- ~25 char names fit at CONFIG_FONT 12pt
        local FONT_PICKER_BTN_H        = addon.settingsDesign.tokens.geometry.fontRowHeight
        local FONT_PICKER_PAD          = 8
        local FONT_PICKER_SCROLLBAR_W  = 22
        local FONT_PICKER_VISIBLE_ROWS = 14
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
            if fontDropdown and fontDropdown.statsProTrigger then
                fontDropdown.statsProTrigger.statsProActive = false
                addon.settingsDesign.RefreshControl(fontDropdown.statsProTrigger)
            end
        end

        local function BuildFontPickerFrame()
            -- Picker frame inherits the same restrained shell surface while keeping its
            -- independent DIALOG level and click-catcher ownership.
            fontPickerFrame = CreateFrame("Frame", "StatsProFontPicker", UIParent, "BackdropTemplate")
            fontPickerFrame:SetSize(FONT_PICKER_FRAME_W, FONT_PICKER_FRAME_H)
            fontPickerFrame:SetFrameStrata("DIALOG")
            -- Initial frame level; ShowFontPicker re-applies on each show in case configFrame's
            -- level shifted (e.g., Blizzard Settings API re-parented configFrame between sessions).
            fontPickerFrame:SetFrameLevel((configFrame and configFrame:GetFrameLevel() or 100) + 50)
            fontPickerFrame:SetClampedToScreen(true)
            self.settingsDesign.ApplySurface(fontPickerFrame, "window")
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

            local pickerSurface = self.settingsDesign.CreateTextureSurface(fontPickerFrame, "viewport")
            pickerSurface:SetPoint("TOPLEFT", FONT_PICKER_PAD - 2, -(FONT_PICKER_PAD - 2))
            pickerSurface:SetPoint("BOTTOMRIGHT",
                -(FONT_PICKER_PAD + FONT_PICKER_SCROLLBAR_W - 2), FONT_PICKER_PAD - 2)
            fontPickerFrame.statsProViewport = pickerSurface

            -- ScrollFrame — UIPanelScrollFrameTemplate matches configFrame's existing scroll pattern.
            fontPickerScroll = CreateFrame("ScrollFrame", "StatsProFontPickerScroll", fontPickerFrame, "UIPanelScrollFrameTemplate")
            fontPickerScroll:SetPoint("TOPLEFT", FONT_PICKER_PAD, -FONT_PICKER_PAD)
            fontPickerScroll:SetPoint("BOTTOMRIGHT", -(FONT_PICKER_PAD + FONT_PICKER_SCROLLBAR_W), FONT_PICKER_PAD)
            self.settingsDesign.StyleScrollFrame(fontPickerScroll)

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
                if fontDropdown and fontDropdown.statsProTrigger then
                    fontDropdown.statsProTrigger.statsProActive = false
                    addon.settingsDesign.RefreshControl(fontDropdown.statsProTrigger)
                end
                CancelFontPreview()
            end)

            -- Esc-to-close. UISpecialFrames pops top-most special frame on Esc — picker added
            -- AFTER configFrame so picker closes first.
            tinsert(UISpecialFrames, "StatsProFontPicker")
        end

        local function PopulateFontPicker()
            local fonts = BuildFontsList()
            local currentPath = self.fontRuntime.currentPath()
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

                    btn.text = btn:CreateFontString(nil, "OVERLAY")
                    RegisterConfigFont(btn.text, CONFIG_FONT_SIZE)
                    btn.text:SetPoint("LEFT", 6, 0)
                    btn.text:SetPoint("RIGHT", -4, 0)
                    btn.text:SetJustifyH("LEFT")
                    -- WHY no-wrap: long font names (>25 char) would wrap to a 2nd line, breaking
                    -- the row-height grid. Single-line overflow visually clipped by FontString.
                    btn.text:SetWordWrap(false)
                    btn.text:SetMaxLines(1)
                    addon.settingsDesign.StyleListRow(btn, btn.text)

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
                    addon.settingsDesign.SetListRowSelected(btn, true)
                    currentRow = row
                else
                    addon.settingsDesign.SetListRowSelected(btn, false)
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
            if fontDropdown.statsProTrigger then
                fontDropdown.statsProTrigger.statsProActive = true
                addon.settingsDesign.RefreshControl(fontDropdown.statsProTrigger)
            end
        end

        local function ToggleFontPicker()
            if fontPickerFrame and fontPickerFrame:IsShown() then
                HideFontPicker()
            else
                ShowFontPicker()
            end
        end

        CurrentFontName = function()
            local current = self.fontRuntime.currentPath()
            for _, f in ipairs(BuildFontsList()) do
                if SameFontPath(f.path, current) then return f.name end
            end
            return addon.fontRuntime.catalogName(current)
        end
        self.fontRuntime.refreshCaption = function()
            if fontDropdown and CurrentFontName then
                UIDropDownMenu_SetText(fontDropdown, CurrentFontName())
            end
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
            maxTextWidth = addon.settingsDesign.tokens.geometry.dropdownLabelMaxWidth,
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
            local applied = self.fontRuntime.applyCommittedTextStyle(
                self.fontRuntime.currentPath(), GetNumberDB("fontSize"), false, true)
            if applied then ReflowAllPanels() end
            return applied
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
            local cur = addon.NormalizeOutputLocale(GetLocale())
            local o = FindLangOption(cur)
            return string.format(L("Auto (current: %s)"), StripParenSuffix((o and o.label) or cur))
        end

        -- CompactLabel: short form for the dropdown's collapsed current-text field, sized
        -- for the 100px body while keeping locale variants distinguishable.
        local function CompactLabel(opt)
            if opt.value == "auto" then
                local cur = addon.NormalizeOutputLocale(GetLocale())
                local o = FindLangOption(cur)
                return (o and (o.compactLabel or StripParenSuffix(o.label))) or cur
            end
            return opt.compactLabel or StripParenSuffix(opt.label)
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
            local locale = (value == "auto")
                and addon.NormalizeOutputLocale(GetLocale()) or value
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
            -- WHY currentPath() (committed) and not the currently-rendered preview font:
            -- consecutive hovers must each evaluate against the BASELINE, otherwise hover
            -- ru→ARIALN→hover de would compare ARIALN(Latin-OK) and skip restoring FRIZQT.
            local req      = LOCALE_GLYPH_REQ[locale] or GLYPH_LATIN
            local cur      = self.fontRuntime.currentPath()
            local fallback = FindCompatibleFont(cur, req)
            if fallback and not SameFontPath(fallback, cur) then
                local applied = ApplyTextStyleToAllPanels(fallback, GetNumberDB("fontSize"))
                if applied then langPreviewSwappedFnt = true end
            elseif langPreviewSwappedFnt then
                -- Previous hover swapped to fallback; this hover doesn't need to. Force
                -- the restore for the same cache-drift class as picker/dropdown cancel.
                local restored = ApplyTextStyleToAllPanels(cur, GetNumberDB("fontSize"), true)
                if restored then langPreviewSwappedFnt = false end
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
            addon:RunUpdateStatsSafe()
        end

        -- WHY re-resolve from DB instead of stored baseline: mirrors font picker's OnHide
        -- pattern. Commit path overwrote forceLocale + cleared the flag, so this is a no-op
        -- post-commit; close-without-pick path restores to baseline (=current forceLocale).
        local function CancelLanguagePreview()
            if not langPreviewActive then return end
            if self.profileRuntime.suppressIntermediateRefresh then
                langPreviewActive = false
                langPreviewSwappedFnt = false
                langPreviewLocale = nil
                return
            end
            local active = ResolveActiveLocale()
            cached.activeLabels = LABELS_BY_LOCALE[active] or LABELS_BY_LOCALE.enUS
            cached.activeLabelsLocale = LABELS_BY_LOCALE[active] and active or "enUS"
            if langPreviewSwappedFnt then
                local restored = self.fontRuntime.applyCommittedTextStyle(
                    self.fontRuntime.currentPath(), GetNumberDB("fontSize"), true, true)
                if restored then langPreviewSwappedFnt = false end
            end
            langPreviewActive = false
            langPreviewLocale = nil  -- next preview must always run a fresh apply
            -- Restore settings-UI font for the COMMITTED locale (mirrors stat-panel restore
            -- above): hover-ruRU-then-cancel on enUS must put our CreateFontStrings back to
            -- the enUS-baseline CONFIG_FONT, otherwise they'd stay on ARIALN unnecessarily.
            ApplyConfigFont(ResolveConfigFont(active))
            RefreshConfigLocalization()
            addon:RunUpdateStatsSafe()
        end
        self.profileRuntime.previewLanguage = PreviewLanguage
        self.profileRuntime.cancelLanguagePreview = CancelLanguagePreview

        local langDropdown = CreateFrame("Frame", "StatsProLanguageDropdown", displayTab, "UIDropDownMenuTemplate")
        -- Placeholder anchor; AlignSwatchColumn re-anchors at column x = cd.padX + maxLabelW + CONFIG_DROPDOWN_GAP after the Appearance-tab dropdown rows build.
        langDropdown:SetPoint("TOPLEFT", cd.padX + 100, rowY + CONFIG_DROPDOWN_Y_OFFSET)
        UIDropDownMenu_SetWidth(langDropdown, addon.settingsDesign.tokens.geometry.dropdownWidth)
        UIDropDownMenu_JustifyText(langDropdown, "LEFT")
        addon.settingsDesign.StyleDropdown(langDropdown, langLabel)
        UIDropDownMenu_Initialize(langDropdown, function()
            local current = (FindLangOption(GetDB("forceLocale")) or LANGUAGE_OPTIONS[1]).value
            for _, opt in ipairs(LANGUAGE_OPTIONS) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = DisplayLabel(opt)
                info.value = opt.value
                info.checked = (current == opt.value)
                info.func = function()
                    local db = self.dbRuntime.GetWritableSettings(true, "forceLocale")
                    if not db then
                        CloseDropDownMenus()
                        CancelLanguagePreview()
                        return false
                    end
                    -- Commit supersedes any in-flight hover preview. MaybeAutoSwitchFont
                    -- is the authoritative font owner from this point on.
                    db.forceLocale = opt.value
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
                        local restored = self.fontRuntime.applyCommittedTextStyle(
                            self.fontRuntime.currentPath(), GetNumberDB("fontSize"), true, true)
                        if restored then langPreviewSwappedFnt = false end
                    end
                    langPreviewActive     = false
                    -- WHY: auto-switch may have changed db.font; PushRefresher only fires on Reset.
                    UIDropDownMenu_SetText(fontDropdown, CurrentFontName())
                    UIDropDownMenu_SetText(langDropdown, CompactLabel(opt))
                    CloseDropDownMenus()
                    RefreshLanguageWarning()
                    RefreshConfigLocalization()
                    addon:RunUpdateStatsSafe()
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
        local langWarnHeight = addon.settingsDesign.tokens.geometry.warningHeight
        RegisterConfigFont(langWarn, 11)
        langWarn:SetPoint("TOPLEFT", cd.padX, cd.y)
        langWarn:SetWidth(scrollChildWidth - (cd.padX * 2))
        langWarn:SetHeight(langWarnHeight)
        langWarn:SetJustifyH("LEFT")
        langWarn:SetJustifyV("TOP")
        langWarn:SetWordWrap(true)
        langWarn:SetMaxLines(2)
        langWarn:SetText("")
        addon.settingsDesign.StyleWarning(displayTab, langWarn, "warning")
        if self.__statsproSmoke == true then configFrame.languageWarning = langWarn end

        -- Assignment to file-scope upvalue declared in section 15 prelude (NOT a global).
        RefreshLanguageWarning = function()
            local active = ResolveActiveLocale()
            local req    = LOCALE_GLYPH_REQ[active] or GLYPH_LATIN
            if FontSupports(self.fontRuntime.currentPath(), req) then
                langWarn:SetText("")
                addon.settingsDesign.SetWarningVisible(langWarn, false)
            else
                langWarn:SetText(string.format(L(
                    "|cffffaa44⚠|r Font may not render %s glyphs. Pick a SharedMedia font with proper coverage."
                ), req))
                addon.settingsDesign.SetWarningVisible(langWarn, true)
            end
        end
        -- WHY register as localized: warning text changes on language switch (req glyph
        -- tag stays raw — it's a script name, not a translatable phrase). Setter replays
        -- from RefreshConfigLocalization so wording tracks active locale; RefreshLanguageWarning
        -- is also called from the language dropdown's commit handler for the immediate recheck.
        PushLocalizedLabel(function() RefreshLanguageWarning() end)
        -- WHY fixed two-line reservation: localized warnings wrap inside the padded
        -- scroll content. Avoid GetStringHeight arithmetic because the measurement can
        -- become secret-tainted when the active text contains restricted glyph data.
        CursorAdvance(cd, langWarnHeight)

        -- Reset button: re-syncs both dropdown SetText and warning state.
        PushRefresher(function()
            UIDropDownMenu_SetText(langDropdown, CurrentLabel())
            RefreshLanguageWarning()
        end)

        tinsert(displayDropdownRows, {
            text = langLabel, dropdown = langDropdown,
            maxTextWidth = addon.settingsDesign.tokens.geometry.dropdownLabelMaxWidth,
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
            SetCheckboxEnabled(critCb,    masterOn, "Show Offensive Stats")
            SetCheckboxEnabled(hasteCb,   masterOn, "Show Offensive Stats")
            SetCheckboxEnabled(masteryCb, masterOn, "Show Offensive Stats")
            SetCheckboxEnabled(versCb,    masterOn, "Show Offensive Stats")
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
            SetCheckboxEnabled(leechCb,     masterOn, "Show Tertiary Stats")
            SetCheckboxEnabled(avoidanceCb, masterOn, "Show Tertiary Stats")
            SetCheckboxEnabled(speedCb,     masterOn, "Show Tertiary Stats")
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
            SetCheckboxEnabled(dodgeCb, masterOn, "Show Defensive Stats")
            SetCheckboxEnabled(parryCb, masterOn, "Show Defensive Stats")
            SetCheckboxEnabled(blockCb, masterOn, "Show Defensive Stats")
            SetCheckboxEnabled(armorCb, masterOn, "Show Defensive Stats")
            SetCheckboxEnabled(staggerCb, masterOn, "Show Defensive Stats")
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
            function() addon.durabilityRuntime.MarkDirty() end)
        rightRows[#rightRows + 1] = { text = txt, swatch = sw }
        AlignSwatchColumn(leftRows)
        AlignSwatchColumn(rightRows)
        cs.y = rowY - 26
        CreateCheckbox(statsTab, "StatsProRepairCostCheck", "Show Repair Cost", "showRepairCost", cs.padX, cs.y,
            function() addon.durabilityRuntime.MarkDirty() end)
        CursorAdvance(cs, 22)
        CreateCheckbox(statsTab, "StatsProAutoColorCheck",
            "Auto Color by Threshold", "useAutoColorDurability", cs.padX, cs.y)
        CursorAdvance(cs, 22)
        -- WHY: onChange forces recompute via dirty flag; otherwise display stays stale
        -- until the next equipment event (which may be far off).
        -- WHY: this is a full-width row with no right-column peer. The normal 200px
        -- checkbox bound truncates longer translations; 400px still fits the 450px
        -- scroll child after the 12px row padding and 22px checkbox chrome.
        CreateCheckbox(statsTab, "StatsProWorstDurCheck",
            "Use Worst Slot (instead of average)", "useWorstDurability", cs.padX, cs.y,
            function() addon.durabilityRuntime.MarkDirty() end, 400)
        CursorAdvance(cs, 22)
    end

    statsTab.contentHeight = CursorUsed(cs)
    statsTab:SetHeight(statsTab.contentHeight)

    --[[ ===== Reset action (in-place widget refresh, no frame rebuild) ===== ]]
    resetBtn:SetScript("OnClick", function() ResetToDefaults() end)

    --[[ ===== Initial state ===== ]]
    self.settingsDesign.RefreshMutationControls()
    SwitchToTab(1)
    -- CreateFrame starts shown, before the OnShow hook above exists. Explicitly seed
    -- the first-open state; later opens are handled by the hook.
    self.panelEditRuntime.SetRequested(true)
end

-- Self-serve diagnostics: dump runtime state to chat for bug reports. Each group is
-- a separate PrintMsg so restricted values cannot poison unrelated diagnostic lines.
function addon:PrintDebugDump()
    addon.dbRuntime.Refresh()
    PrintMsg(string.format("debug v%s  dbVer %s/%d  dbMode=%s  isLoaded=%s  durDirty=%s  mem=%dKB",
        ADDON_VERSION,
        addon.dbRuntime.versionDisplay,
        CURRENT_DB_VERSION,
        addon.dbRuntime.readOnly and ("read-only/" .. addon.dbRuntime.mode) or "current",
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
    local savedFont = GetSavedAutoFontDB()
    local activeSettings = addon.dbRuntime.readOnly
        and addon.dbRuntime.activeSettings or addon.dbRuntime.GetActiveSettings()
    local savedFontText = savedFont
        or (type(activeSettings.fontBeforeAutoSwitch) == "nil" and "nil" or "<unavailable>")
    PrintMsg(string.format("font: path=%s glyphReq=%s supports=%s saved=%s",
        tostring(addon.fontRuntime.currentPath() or "?"),
        req,
        tostring(FontSupports(addon.fontRuntime.currentPath(), req)),
        savedFontText))

    PrintMsg(string.format("show stats: off=%s tert=%s defensive=%s dur=%s repair=%s cost=%s complete=%s mainStat=%s liveMainId=%s stamina=%s itemLevel=%s %s/%s",
        tostring(cached.showOffensive),
        tostring(cached.showTertiary), tostring(cached.showDefensive), tostring(cached.showDurability),
        tostring(cached.showRepairCost), SAFE_NUM.DumpNumber(cached.repairCost, "%d", "?"),
        tostring(cached.repairCostComplete),
        tostring(cached.showMainStat), tostring(GetCurrentMainStatId()), tostring(cached.showStamina),
        tostring(cached.showItemLevel), tostring(cached.itemLevelEquipped or "?"), tostring(cached.itemLevelOverall or "?")))

    PrintMsg(string.format("subs off: crit=%s haste=%s mastery=%s vers=%s",
        tostring(cached.showCrit), tostring(cached.showHaste), tostring(cached.showMastery), tostring(cached.showVersatility)))

    PrintMsg(string.format("subs: leech=%s avoid=%s speed=%s | dodge=%s parry=%s block=%s armor=%s stagger=%s",
        tostring(cached.showLeech), tostring(cached.showAvoidance), tostring(cached.showSpeed),
        tostring(cached.showDodge), tostring(cached.showParry), tostring(cached.showBlock),
        tostring(cached.showArmor), tostring(cached.showStagger)))

    -- Panel positions: nil-guard (DB may be partial in pre-PEW edge cases)
    local function PosLine(label, p, rp, x, y, fallbackY)
        if not p then return label..": <unset>" end
        local point = NormalizeAnchorPoint(p, "CENTER")
        local relativePoint = NormalizeAnchorPoint(rp, point)
        local xOfs = NormalizePositionOffset(x, 0)
        local yOfs = NormalizePositionOffset(y, fallbackY or 0)
        return string.format("%s: %s/%s  %+.0f/%+.0f", label, point, relativePoint, xOfs, yOfs)
    end
    PrintMsg(PosLine("main",      GetDB("point"),           GetDB("relativePoint"),           GetDB("xOfs"),           GetDB("yOfs"),           defaults.yOfs))
    PrintMsg(PosLine("side",      GetDB("defensive_point"), GetDB("defensive_relativePoint"), GetDB("defensive_xOfs"), GetDB("defensive_yOfs"), defaults.defensive_yOfs))
end

local function PrintDebugPerf()
    PrintMsg(string.format("debug perf: mem=%dKB updates=%d refresh=%.2fs elapsed=%.2fs",
        math.floor(collectgarbage("count")),
        updateCount,
        cached.updateInterval or GetNumberDB("updateInterval"),
        timeSinceLastUpdate or 0))
    PrintMsg(string.format("debug perf: updateErrors=%d lastError=%s",
        cached.updateErrorCount or 0,
        cached.lastUpdateError or "<none>"))
    PrintMsg(string.format("debug perf: visible=%s mode=%s mainShown=%s sideShown=%s",
        tostring(cached.isVisible),
        tostring(cached.displayMode),
        tostring(mainPanel:IsShown()),
        tostring(defensivePanel:IsShown())))
    PrintMsg(string.format("debug perf: dirty durability=%s itemLevel=%s repairCost=%s complete=%s durability=%.1f",
        tostring(durabilityDirty),
        tostring(itemLevelDirty),
        SAFE_NUM.DumpNumber(cached.repairCost, "%d", "?"),
        tostring(cached.repairCostComplete),
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

function addon.DebugStatCall(fn, fmt, ...)
    if type(fn) ~= "function" then return "missing" end
    local ok, value = pcall(fn, ...)
    if not ok then return "error" end
    if issecretvalue(value) then return "secret" end
    if SAFE_NUM.IsCleanFiniteNumber(value) then return string.format(fmt or "%.2f", value) end
    if value == nil then return "nil" end
    return type(value)
end

function addon:PrintDebugLiveStats()
    PrintMsg(string.format("debug live: updateErrors=%d lastError=%s",
        cached.updateErrorCount or 0,
        cached.lastUpdateError or "<none>"))
    PrintMsg(string.format("debug live crit: best=%s melee=%s ranged=%s rating=%s",
        addon.DebugStatCall(addon.GetBestCritChance, "%.2f"),
        addon.DebugStatCall(GetCritChance, "%.2f"),
        addon.DebugStatCall(GetRangedCritChance, "%.2f"),
        addon.DebugStatCall(GetCombatRating, "%d", CR_CRIT_MELEE)))
    local spellSchoolValues = {}
    for school = 2, addon.GetMaxSpellSchool() do
        spellSchoolValues[#spellSchoolValues + 1] = string.format(
            "%d=%s", school, addon.DebugStatCall(GetSpellCritChance, "%.2f", school))
    end
    PrintMsg("debug live crit schools: " .. table.concat(spellSchoolValues, " "))
    PrintMsg(string.format("debug live haste: percent=%s rating=%s bonus=%s",
        addon.DebugStatCall(GetHaste, "%.2f"),
        addon.DebugStatCall(GetCombatRating, "%d", CR_HASTE_MELEE),
        addon.DebugStatCall(GetCombatRatingBonus, "%.2f", CR_HASTE_MELEE)))
    PrintMsg(string.format("debug live mastery: effect=%s rating=%s bonus=%s",
        addon.DebugStatCall(GetMasteryEffect, "%.2f"),
        addon.DebugStatCall(GetCombatRating, "%d", CR_MASTERY),
        addon.DebugStatCall(GetCombatRatingBonus, "%.2f", CR_MASTERY)))
    PrintMsg(string.format("debug live vers: ratingBonus=%s flat=%s rating=%s cachedTotal=%s cachedRating=%s",
        addon.DebugStatCall(GetCombatRatingBonus, "%.2f", CR_VERSATILITY_DAMAGE_DONE),
        addon.DebugStatCall(GetVersatilityBonus, "%.2f", CR_VERSATILITY_DAMAGE_DONE),
        addon.DebugStatCall(GetCombatRating, "%d", CR_VERSATILITY_DAMAGE_DONE),
        SAFE_NUM.DumpNumber(cached.versTotal, "%.2f", "?"),
        SAFE_NUM.DumpNumber(cached.versTotalRating, "%d", "?")))
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
        dbCompatibilityState = function()
            addon.dbRuntime.Refresh()
            return {
                readOnly = addon.dbRuntime.readOnly,
                mode = addon.dbRuntime.mode,
                version = addon.dbRuntime.version,
                warned = addon.dbRuntime.warned,
                generation = addon.dbRuntime.generation,
            }
        end,
        dbValidationCount = function() return addon.dbRuntime.validationCount end,
        profileState = function()
            local root = addon.dbRuntime.Refresh()
            return {
                root = root,
                account = addon.dbRuntime.activeAccount,
                settings = addon.dbRuntime.activeSettings,
                profileID = addon.dbRuntime.activeProfileID,
                profiles = root.profiles,
                roleTemplates = root.roleTemplates,
                characters = root.characters,
                generation = addon.dbRuntime.generation,
            }
        end,
        profileRuntimeState = function()
            local runtime = addon.profileRuntime
            return {
                activeGUID = runtime.activeGUID,
                activeSpecID = runtime.activeSpecID,
                activeDisplayName = runtime.activeDisplayName,
                activeSpecName = runtime.activeSpecName,
                forceReapply = runtime.forceReapply,
                pendingResolution = runtime.pendingResolution,
                scheduled = runtime.scheduledToken ~= nil,
                activationCount = runtime.activationCount,
                applyCount = runtime.applyCount,
                configRefreshCount = runtime.configRefreshCount,
                structuralCommitCount = runtime.structuralCommitCount,
                contextReadCount = runtime.contextReadCount,
                updateCount = updateCount,
            }
        end,
        appearancePresets = {
            order = function() return CopyTable(addon.appearancePresets.order) end,
            definitions = function() return CopyTable(addon.appearancePresets.definitions) end,
            allowlist = function() return CopyTable(addon.appearancePresets.allowlist) end,
            currentID = addon.appearancePresets.CurrentID,
            startPreview = addon.appearancePresets.StartPreview,
            cancelPreview = addon.appearancePresets.CancelPreview,
            applyPreview = addon.appearancePresets.ApplyPreview,
            markCustom = addon.appearancePresets.MarkCustom,
            setRuntimeFailureCount = function(count)
                addon.appearancePresets.testRuntimeFailureCount = count or 0
            end,
            state = function()
                local session = addon.appearancePresets.session
                return {
                    active = session ~= nil,
                    presetID = session and session.presetID or nil,
                    candidate = session and CopyTable(session.candidate) or nil,
                    baseline = session and CopyTable(session.baseline) or nil,
                }
            end,
        },
        profileViewModel = addon.profileUI.BuildViewModel,
        profileOps = {
            validateName = addon.profileOps.ValidateName,
            countReferences = addon.profileOps.CountReferences,
            create = addon.profileOps.Create,
            duplicate = addon.profileOps.Duplicate,
            rename = addon.profileOps.Rename,
            copySettings = addon.profileOps.CopySettings,
            assign = addon.profileOps.Assign,
            useProfileForKnownSpecs = addon.profileOps.UseProfileForKnownSpecs,
            makeKnownSpecsIndependent = addon.profileOps.MakeKnownSpecsIndependent,
            setRoleTemplate = addon.profileOps.SetRoleTemplate,
            swap = addon.profileOps.Swap,
            resetCurrent = addon.profileOps.ResetCurrent,
            importAndAssign = addon.profileOps.ImportAndAssign,
            fullWipe = addon.profileOps.FullWipe,
            deleteWithReplacement = addon.profileOps.DeleteWithReplacement,
            forgetCharacter = addon.profileOps.ForgetCharacter,
            setFailureStage = function(stage) addon.profileOps.testFailureStage = stage end,
            setTransitioning = function(value) addon.profileRuntime.transitioning = value == true end,
            state = function()
                return {
                    inProgress = addon.profileOps.inProgress,
                    operationCount = addon.profileOps.operationCount,
                    maxNameCodepoints = addon.profileOps.maxNameCodepoints,
                }
            end,
        },
        destructivePromptState = function()
            return {
                importPending = addon.legacyImport.pending ~= nil,
                resetPending = addon.resetRuntime.pending ~= nil,
                wipePending = addon.wipeRuntime.pending ~= nil,
            }
        end,
        profileUIState = function()
            local ui = addon.profileUI
            local rows = {}
            for index, row in ipairs(ui.managerRows or {}) do
                rows[index] = {
                    shown = row:IsShown(),
                    text = row.text:GetText(),
                    badge = row.badge:GetText(),
                    context = row.profileContext and CopyTable(row.profileContext) or nil,
                }
            end
            local choices = {}
            for index, row in ipairs(ui.choiceRows or {}) do
                choices[index] = {
                    shown = row:IsShown(),
                    text = row.text:GetText(),
                    data = row.choiceData and CopyTable(row.choiceData) or nil,
                }
            end
            local actions = {}
            for key, button in pairs(ui.actionButtons or {}) do
                actions[key] = {
                    enabled = button:IsEnabled(),
                    text = button:GetText(),
                }
            end
            return {
                refreshCount = ui.refreshCount,
                selectedGUID = ui.selectedGUID,
                selectedSpecID = ui.selectedSpecID,
                selectedProfileID = ui.selectedProfileID,
                selectedAssignedProfileID = ui.selectedAssignedProfileID,
                headerProfile = ui.headerProfileButton and ui.headerProfileButton:GetText() or nil,
                headerProfileEnabled = ui.headerProfileButton
                    and ui.headerProfileButton:IsEnabled() or false,
                headerLabel = ui.headerLabel and ui.headerLabel:GetText() or nil,
                headerSubtitle = ui.headerSubtitle and ui.headerSubtitle:GetText() or nil,
                headerSubtitleColor = ui.headerSubtitle and ui.headerSubtitle.textColor
                    and CopyTable(ui.headerSubtitle.textColor) or nil,
                managerShown = ui.manager and ui.manager:IsShown() or false,
                managerFrameStrata = ui.manager and ui.manager:GetFrameStrata() or nil,
                managerListSurfaceRole = ui.managerListSurface
                    and ui.managerListSurface.statsProSurfaceRole or nil,
                managerListSurfaceParentOwned = ui.managerListSurface
                    and ui.managerListSurface:GetParent() == ui.manager or false,
                managerDetailSurfaceRole = ui.managerDetailSurface
                    and ui.managerDetailSurface.statsProSurfaceRole or nil,
                managerDetailSurfaceParentOwned = ui.managerDetailSurface
                    and ui.managerDetailSurface:GetParent() == ui.manager or false,
                managerTitle = ui.managerTitle and ui.managerTitle:GetText() or nil,
                rows = rows,
                detailCharacter = ui.detailCharacter and ui.detailCharacter:GetText() or nil,
                detailContext = ui.detailContext and ui.detailContext:GetText() or nil,
                detailProfile = ui.detailProfile and ui.detailProfile:GetText() or nil,
                detailSharing = ui.detailSharing and ui.detailSharing:GetText() or nil,
                detailNotice = ui.detailNotice and ui.detailNotice:GetText() or nil,
                managedProfile = ui.profileSelector and ui.profileSelector:GetText() or nil,
                managedProfileEnabled = ui.profileSelector and ui.profileSelector:IsEnabled() or false,
                managedImpact = ui.managedImpact and ui.managedImpact:GetText() or nil,
                selectedCharacterSummary = ui.selectedCharacterSummary
                    and ui.selectedCharacterSummary:GetText() or nil,
                roleTemplateSummary = ui.roleTemplateSummary and {
                    TANK = ui.roleTemplateSummary.TANK:GetText(),
                    HEALER = ui.roleTemplateSummary.HEALER:GetText(),
                    DAMAGER = ui.roleTemplateSummary.DAMAGER:GetText(),
                } or nil,
                operationStatus = ui.operationStatus and ui.operationStatus:GetText() or nil,
                actions = actions,
                operationDialogShown = ui.operationDialog and ui.operationDialog:IsShown() or false,
                operationBlockerShown = ui.operationBlocker
                    and ui.operationBlocker:IsShown() or false,
                operationBlockerLevel = ui.operationBlocker
                    and ui.operationBlocker:GetFrameLevel() or nil,
                operationDialogStrata = ui.operationDialog
                    and ui.operationDialog:GetFrameStrata() or nil,
                operationDialogLevel = ui.operationDialog
                    and ui.operationDialog:GetFrameLevel() or nil,
                operationDialogTitle = ui.operationDialogTitle
                    and ui.operationDialogTitle:GetText() or nil,
                operationDialogMessage = ui.operationDialogMessage
                    and ui.operationDialogMessage:GetText() or nil,
                operationMode = ui.pendingAction and ui.pendingAction.mode or nil,
                operationKind = ui.pendingAction and ui.pendingAction.kind or nil,
                nameInput = ui.nameInput and ui.nameInput:GetText() or nil,
                nameValidation = ui.nameValidation and ui.nameValidation:GetText() or nil,
                operationConfirmEnabled = ui.operationPrimaryButton
                    and ui.operationPrimaryButton:IsEnabled() or false,
                choices = choices,
            }
        end,
        previewFontForSmoke = function(path)
            return addon.profileRuntime.previewFont(path)
        end,
        previewLanguageForSmoke = function(locale)
            return addon.profileRuntime.previewLanguage(locale)
        end,
        addConfigRefresherForSmoke = function(refresh)
            PushRefresher(refresh)
        end,
        addPersistentLocalizedLabelForSmoke = function(refresh)
            tinsert(localizedPersistentLabels, refresh)
        end,
        cachedUpdateInterval = function() return cached.updateInterval end,
        cachedTextAlpha = function() return cached.textAlpha end,
        cachedPanelBackgroundAlpha = function() return cached.panelBackgroundAlpha end,
        cachedAppearanceState = function()
            return {
                fontSize = mainPanel.appliedSize,
                textAlpha = cached.textAlpha,
                panelBackgroundAlpha = cached.panelBackgroundAlpha,
                textOutlineStyle = cached.textOutlineStyle,
                matchValueColorToStat = cached.matchValueColorToStat,
                useAutoColorDurability = cached.useAutoColorDurability,
                colorStrings = CopyTable(cached.colorStrings),
            }
        end,
        cachedTargetSnapshot = function() return cached.targetSnapshot end,
        currentRelease = function() return CURRENT_RELEASE end,
        addonVersion = function() return ADDON_VERSION end,
        copyDefaults = function() return CopyTable(defaults) end,
        registrySnapshot = function()
            return {
                cachedBoolKeys = CopyTable(CACHED_BOOL_KEYS),
                accountSettingKeys = CopyTable(addon.dbRuntime.accountSettingKeys),
                numberSettingMeta = CopyTable(NUMBER_SETTING_META),
                languageOptions = CopyTable(LANGUAGE_OPTIONS),
                localeGlyphReq = CopyTable(LOCALE_GLYPH_REQ),
                labelsByLocale = CopyTable(LABELS_BY_LOCALE),
            }
        end,
        settingsDesignSnapshot = function()
            return CopyTable(addon.settingsDesign.tokens)
        end,
        settingsControlState = function()
            local controls = {}
            for index, control in ipairs(addon.settingsDesign.testControls or {}) do
                local border = control.statsProSurface
                    and control.statsProSurface.statsProBorders
                    and control.statsProSurface.statsProBorders[1] or nil
                controls[index] = {
                    kind = control.statsProControlKind,
                    name = control:GetName(),
                    enabled = addon.settingsDesign.IsControlEnabled(control),
                    state = control.statsProControlState or control.statsProButtonState,
                    width = control:GetWidth(),
                    height = control:GetHeight(),
                    role = control.statsProButtonRole,
                    disabledReasonKey = control.statsProDisabledReasonKey,
                    mutatesSettings = control.statsProMutatesSettings == true,
                    selected = control.statsProSelected == true,
                    fill = control.statsProStateTexture
                        and CopyTable(control.statsProStateTexture.colorTexture) or nil,
                    border = border and CopyTable(border.colorTexture) or nil,
                    textColor = control.statsProText
                        and CopyTable(control.statsProText.textColor) or nil,
                }
            end
            return controls
        end,
        setSettingsContextBlockedForSmoke = function(blocked)
            addon.profileRuntime.pendingResolution = blocked == true
            addon.profileRuntime.scheduledToken = nil
            addon.settingsDesign.RefreshMutationControls()
        end,
        settingsShellState = function()
            if not configFrame then return nil end
            local sections = {}
            for tabIndex, tab in ipairs(configFrame.tabContents or {}) do
                sections[tabIndex] = {}
                for sectionIndex, section in ipairs(tab.statsProSections or {}) do
                    sections[tabIndex][sectionIndex] = {
                        key = section.key,
                        surface = section.surface,
                        text = section.text,
                        y = section.y,
                    }
                end
            end
            return {
                shell = configFrame.settingsShell,
                tabs = configFrame.tabButtons,
                sections = sections,
            }
        end,
        migrateDB = MigrateDB,
        cacheSettings = CacheSettings,
        getDB = GetDB,
        getBoolDB = GetBoolDB,
        getNumberDB = GetNumberDB,
        getColor = GetColor,
        normalizeNumberSetting = NormalizeNumberSetting,
        fontPathKey = FontPathKey,
        sameFontPath = SameFontPath,
        isBlizzardFontPath = IsBlizzardFontPath,
        fontSupports = FontSupports,
        findCompatibleFont = FindCompatibleFont,
        getFontDB = GetFontDB,
        usableFontPath = addon.fontRuntime.usablePath,
        safeDefaultFontPath = addon.fontRuntime.safeDefaultPath,
        currentRuntimeFontPath = addon.fontRuntime.currentPath,
        repairSavedFontPaths = addon.fontRuntime.repairSavedPaths,
        applyCommittedTextStyle = addon.fontRuntime.applyCommittedTextStyle,
        applyConfigFont = ApplyConfigFont,
        formatRepairCost = FormatRepairCost,
        refreshDurabilityCache = RefreshDurabilityCache,
        durabilityState = function()
            return {
                durabilityValue = cached.durabilityValue,
                repairCost = cached.repairCost,
                repairCostComplete = cached.repairCostComplete,
                dirty = durabilityDirty,
                retryScheduled = addon.durabilityRuntime.scheduledGeneration
                    == addon.durabilityRuntime.generation,
            }
        end,
        itemLevelState = function()
            return {
                overall = cached.itemLevelOverall,
                equipped = cached.itemLevelEquipped,
                dirty = itemLevelDirty,
            }
        end,
        versatilityState = function()
            return {
                total = cached.versTotal,
                rating = cached.versTotalRating,
                percentVisible = cached.cleanRowVisibility.showVersatility,
                ratingVisible = cached.cleanRowVisibility.showVersatilityRating,
            }
        end,
        normalizeColor = NormalizeColor,
        rgbToHex = RGBToHex,
        getArchonTargetSnapshot = addon.archonTargets.GetSnapshot,
        buildArchonTargetMeta = addon.archonTargets.BuildMeta,
        archonComparisonCache = function() return CopyTable(addon.archonTargets.comparisonCache) end,
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
                mainAppliedFontFlags = mainPanel.appliedFontFlags,
                mainLabelFont = mainPanel.labelText.font,
                mainLabelSize = mainPanel.labelText.fontSize,
                mainLabelFlags = mainPanel.labelText.fontFlags,
                mainRatingFont = mainPanel.ratingText.font,
                mainRatingFlags = mainPanel.ratingText.fontFlags,
                mainValueFont = mainPanel.valueText.font,
                mainValueFlags = mainPanel.valueText.fontFlags,
                mainRepairFont = mainPanel.repairText.font,
                mainRepairFlags = mainPanel.repairText.fontFlags,
                mainRepairLabelFont = mainPanel.repairLabelText.font,
                mainRepairLabelFlags = mainPanel.repairLabelText.fontFlags,
                sideAppliedFont = defensivePanel.appliedFont,
                sideAppliedSize = defensivePanel.appliedSize,
                sideAppliedTextOutlineStyle = defensivePanel.appliedTextOutlineStyle,
                sideAppliedFontFlags = defensivePanel.appliedFontFlags,
                sideLabelFont = defensivePanel.labelText.font,
                sideLabelSize = defensivePanel.labelText.fontSize,
                sideLabelFlags = defensivePanel.labelText.fontFlags,
                sideRatingFont = defensivePanel.ratingText.font,
                sideRatingFlags = defensivePanel.ratingText.fontFlags,
                sideValueFont = defensivePanel.valueText.font,
                sideValueFlags = defensivePanel.valueText.fontFlags,
                sideRepairFont = defensivePanel.repairText.font,
                sideRepairFlags = defensivePanel.repairText.fontFlags,
                sideRepairLabelFont = defensivePanel.repairLabelText.font,
                sideRepairLabelFlags = defensivePanel.repairLabelText.fontFlags,
            }
        end,
        configFontState = function()
            local entries = {}
            for i, entry in ipairs(localizedConfigFonts) do
                entries[i] = {
                    requestedFlags = entry.flags,
                    appliedFont = entry.appliedFont,
                    appliedSize = entry.appliedSize,
                    appliedFlags = entry.appliedFlags,
                    actualFont = entry.fs.font,
                    actualSize = entry.fs.fontSize,
                    actualFlags = entry.fs.fontFlags,
                    actualText = entry.fs:GetText(),
                }
            end
            return { currentFont = currentConfigFont, entries = entries }
        end,
        panelVisualState = function()
            local firstOverlay = mainPanel.tooltipOverlays and mainPanel.tooltipOverlays[1] or nil
            local secondOverlay = mainPanel.tooltipOverlays and mainPanel.tooltipOverlays[2] or nil
            return {
                textOutlineStyle = cached.textOutlineStyle,
                mainShown = mainPanel:IsShown(),
                mainFrameWidth = mainPanel.frame:GetWidth(),
                mainFrameHeight = mainPanel.frame:GetHeight(),
                mainLastLineH = mainPanel.lastLineH,
                mainCachedLabelW = mainPanel.cachedLabelW,
                mainCachedRatingW = mainPanel.cachedRatingW,
                mainCachedValueW = mainPanel.cachedValueW,
                mainCachedLabelH = mainPanel.cachedLabelH,
                mainCachedRatingH = mainPanel.cachedRatingH,
                mainCachedValueH = mainPanel.cachedValueH,
                mainCachedRepairW = mainPanel.cachedRepairW,
                mainCachedRepairLabelW = mainPanel.cachedRepairLabelW,
                mainRenderedLabelW = mainPanel.lastRenderedLabelW,
                mainRenderedRatingW = mainPanel.lastRenderedRatingW,
                mainRenderedValueW = mainPanel.lastRenderedValueW,
                mainRenderedRepairW = mainPanel.lastRenderedRepairW,
                mainLabelText = mainPanel.labelText:GetText(),
                mainLabelAlpha = mainPanel.labelText:GetAlpha(),
                mainRatingAlpha = mainPanel.ratingText:GetAlpha(),
                mainValueAlpha = mainPanel.valueText:GetAlpha(),
                mainRatingText = mainPanel.ratingText:GetText(),
                mainValueText = mainPanel.valueText:GetText(),
                mainRatingPoints = mainPanel.ratingText.points,
                mainValuePoints = mainPanel.valueText.points,
                mainBackgroundAlpha = mainPanel.frame.backdropColor and mainPanel.frame.backdropColor.a or nil,
                mainBackgroundTextureAlpha = mainPanel.backgroundTexture and mainPanel.backgroundTexture.colorTexture and mainPanel.backgroundTexture.colorTexture.a or nil,
                mainBackgroundTexturePoints = mainPanel.backgroundTexture and mainPanel.backgroundTexture.points or nil,
                mainRepairPoints = mainPanel.repairText.points,
                mainRepairLabelPoints = mainPanel.repairLabelText.points,
                mainRepairShown = mainPanel.repairText:IsShown(),
                mainRepairLabelShown = mainPanel.repairLabelText:IsShown(),
                mainRepairLabelWidth = mainPanel.repairLabelText:GetWidth(),
                mainFirstOverlayHeight = firstOverlay and firstOverlay:GetHeight() or nil,
                mainFirstOverlayPoints = firstOverlay and firstOverlay.points or nil,
                mainSecondOverlayHeight = secondOverlay and secondOverlay:GetHeight() or nil,
                mainSecondOverlayPoints = secondOverlay and secondOverlay.points or nil,
                mainLabelFlags = mainPanel.labelText.fontFlags,
                mainRatingFlags = mainPanel.ratingText.fontFlags,
                mainValueFlags = mainPanel.valueText.fontFlags,
                mainRepairFlags = mainPanel.repairText.fontFlags,
                mainRepairLabelFlags = mainPanel.repairLabelText.fontFlags,
                sideShown = defensivePanel:IsShown(),
                sideFrameWidth = defensivePanel.frame:GetWidth(),
                sideFrameHeight = defensivePanel.frame:GetHeight(),
                sideLastLineH = defensivePanel.lastLineH,
                sideCachedLabelW = defensivePanel.cachedLabelW,
                sideCachedRatingW = defensivePanel.cachedRatingW,
                sideCachedValueW = defensivePanel.cachedValueW,
                sideCachedLabelH = defensivePanel.cachedLabelH,
                sideCachedRatingH = defensivePanel.cachedRatingH,
                sideCachedValueH = defensivePanel.cachedValueH,
                sideCachedRepairW = defensivePanel.cachedRepairW,
                sideCachedRepairLabelW = defensivePanel.cachedRepairLabelW,
                sideRenderedLabelW = defensivePanel.lastRenderedLabelW,
                sideRenderedRatingW = defensivePanel.lastRenderedRatingW,
                sideRenderedValueW = defensivePanel.lastRenderedValueW,
                sideRenderedRepairW = defensivePanel.lastRenderedRepairW,
                sideLabelText = defensivePanel.labelText:GetText(),
                sideRatingText = defensivePanel.ratingText:GetText(),
                sideValueText = defensivePanel.valueText:GetText(),
                sideRatingPoints = defensivePanel.ratingText.points,
                sideValuePoints = defensivePanel.valueText.points,
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
        panelEditAffordanceState = function()
            local function Snapshot(panel)
                local border = panel.editOutline.backdropBorderColor
                local handleBorder = panel.editHandle.backdropBorderColor
                return {
                    shown = panel.editOutline:IsShown(),
                    visible = type(panel.editOutline.IsVisible) ~= "function"
                        or panel.editOutline:IsVisible(),
                    parentIsUIParent = panel.editOutline:GetParent() == UIParent,
                    outlineMouseEnabled = panel.editOutline.mouseEnabled == true,
                    handleMouseEnabled = panel.editHandle.mouseEnabled == true,
                    borderAlpha = border and border.a or nil,
                    handleBorderAlpha = handleBorder and handleBorder.a or nil,
                    dragging = panel.editDragging == true,
                    outlinePoints = CopyTable(panel.editOutline.points or {}),
                    frameShown = panel.frame:IsShown(),
                    frameWidth = panel.frame:GetWidth(),
                    frameHeight = panel.frame:GetHeight(),
                    startMovingCalls = rawget(panel.frame, "startMovingCalls") or 0,
                    stopMovingCalls = rawget(panel.frame, "stopMovingCalls") or 0,
                }
            end
            return {
                requested = addon.panelEditRuntime.requested == true,
                configShown = configFrame and configFrame:IsShown() or false,
                locked = cached.isLocked,
                combat = addon.profileRuntime.ReadCombatState(),
                main = Snapshot(mainPanel),
                side = Snapshot(defensivePanel),
            }
        end,
        firePanelEditHandleForSmoke = function(panelName, scriptName, ...)
            local panel = panelName == "side" and defensivePanel or mainPanel
            local script = panel.editHandle.scripts and panel.editHandle.scripts[scriptName]
            if script then script(panel.editHandle, ...) end
        end,
        renderMainPanelForSmoke = function(labelStr, ratingStr, valueStr, lineCount, repairStr, repairLabelStr, targetRows)
            mainPanel:SetTextSafe(labelStr, ratingStr, valueStr, lineCount, repairStr, repairLabelStr, targetRows)
        end,
        setPanelMeasurementOverride = function(panelName, column, width, height)
            local panel = panelName == "side" and defensivePanel or mainPanel
            local fs = ({
                label = panel.labelText,
                rating = panel.ratingText,
                value = panel.valueText,
                repair = panel.repairText,
                repairLabel = panel.repairLabelText,
            })[column]
            if fs then
                fs.statsProWidthOverride = width
                fs.statsProHeightOverride = height
            end
        end,
        setMainPanelStringHeightMultiplier = function(column, multiplier)
            local fs = ({ label = mainPanel.labelText, rating = mainPanel.ratingText, value = mainPanel.valueText })[column]
            if fs then fs.statsProStringHeightMultiplier = multiplier end
        end,
        mainPanelTooltipState = function()
            return {
                overlayCount = #(mainPanel.tooltipOverlays or {}),
                firstShown = mainPanel.tooltipOverlays[1] and mainPanel.tooltipOverlays[1]:IsShown() or false,
                secondShown = mainPanel.tooltipOverlays[2] and mainPanel.tooltipOverlays[2]:IsShown() or false,
                lastTargetRows = mainPanel.lastTargetRows,
            }
        end,
        panelTooltipState = function(panelName)
            local panel = panelName == "side" and defensivePanel or mainPanel
            local shown, hasOnEnter = {}, {}
            for i, overlay in ipairs(panel.tooltipOverlays or {}) do
                shown[i] = overlay:IsShown()
                hasOnEnter[i] = type(overlay.scripts and overlay.scripts.OnEnter) == "function"
            end
            return {
                overlayCount = #(panel.tooltipOverlays or {}),
                shown = shown,
                hasOnEnter = hasOnEnter,
                lastTargetRows = panel.lastTargetRows,
                wasDragging = panel.frame.wasDragging == true,
                startMovingCalls = rawget(panel.frame, "startMovingCalls") or 0,
                stopMovingCalls = rawget(panel.frame, "stopMovingCalls") or 0,
            }
        end,
        fireMainPanelTooltipOverlayForSmoke = function(index, scriptName, ...)
            local overlay = mainPanel.tooltipOverlays and mainPanel.tooltipOverlays[index]
            local script = overlay and overlay.scripts and overlay.scripts[scriptName]
            if script then script(overlay, ...) end
        end,
        firePanelTooltipOverlayForSmoke = function(panelName, index, scriptName, ...)
            local panel = panelName == "side" and defensivePanel or mainPanel
            local overlay = panel.tooltipOverlays and panel.tooltipOverlays[index]
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
    launcherDesc:SetText(L("Stats and gear HUD: item level, durability, repair cost and Archon stat targets. Click below to open the full settings window."))
end)

if addon.__test then
    addon.__test.launcherDescriptionText = function() return launcherDesc:GetText() end
end

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
    if not addon.profileRuntime.CloseOwnedSettingsModals() then return false end
    local db = addon.dbRuntime.GetWritableSettings(true)
    if not db then
        local cb = _G["StatsProVisibleCheck"]
        if cb then cb:SetChecked(GetBoolDB("isVisible")) end
        return false
    end
    db.isVisible = visible
    CacheSettings()
    addon:RunUpdateStatsSafe()
    -- WHY: master Visible checkbox in config menu may be open; sync its state.
    local cb = _G["StatsProVisibleCheck"]
    if cb then cb:SetChecked(visible) end
    return true
end
SlashCmdList["STATSPRO"] = function(msg)
    local input = (msg or ""):lower()
    local arg, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
    arg = arg or ""
    rest = rest or ""
    if arg == "show" then
        if SetVisible(true) then PrintMsg(L("Stats panel shown")) end
    elseif arg == "hide" then
        if SetVisible(false) then PrintMsg(L("Stats panel hidden")) end
    elseif arg == "toggle" then
        local newState = not GetBoolDB("isVisible")
        if SetVisible(newState) then
            PrintMsg(L(newState and "Stats panel shown" or "Stats panel hidden"))
        end
    elseif arg == "reset" then
        if rest == "all" then
            addon.wipeRuntime.Request()
        else
            ResetToDefaults()
        end
    elseif arg == "wipe" then
        addon.wipeRuntime.Request()
    elseif arg == "import" then
        addon.legacyImport.Request()
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
        elseif debugArg == "live" then
            addon:PrintDebugLiveStats()
        elseif debugArg == "bucket" then
            PrintDebugBucketDump()
        else
            addon:PrintDebugDump()
        end
    elseif arg == "help" or arg == "?" then
        PrintMsg(L("Commands: /ss or /statspro (config), /ss show, /ss hide, /ss toggle, /ss reset, /statspro import, /ss debug, /ss help"))
    else
        addon:OpenConfigMenu()
    end
end
